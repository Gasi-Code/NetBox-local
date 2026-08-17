"""Imports a NetBox API export into the local read-only NetBox instance.

Reads the JSON directory produced by Sync-NetBoxExport.ps1 and rebuilds the
local database from it. The entire local dataset is replaced on every run: this
instance is a replica, never an authority, so there is nothing worth merging.

Why this works without reversing ~150 API serializers
-----------------------------------------------------
NetBox's REST output is regular enough that three rules cover almost every
field:

    {"id": 613, "url": ..., "display": ...}   nested object  -> <field>_id = 613
    {"value": "active", "label": "Active"}    choice         -> "active"
    url / display / display_url / _depth ...  read-only      -> dropped

Primary keys are preserved. The local database is empty before an import, so
there are no collisions, and keeping the original IDs means every foreign key in
the export stays valid without a translation table.

Objects are written with bulk_create, which does not fire signals. The three
derived structures NetBox would otherwise maintain through those signals are
rebuilt explicitly afterwards: MPTT trees, cable paths, and the search index.

Usage:
    python Import-NetBoxExport.py <export-directory> [--dry-run]

<export-directory> is either the folder holding manifest.json, or its JSON
subdirectory.
"""

import argparse
import json
import os
import sys
from collections import defaultdict

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "netbox.settings")

import django  # noqa: E402

django.setup()

from django.apps import apps  # noqa: E402
from django.db import connection, transaction  # noqa: E402
from django.db.models import (  # noqa: E402
    AutoField,
    BigAutoField,
    FileField,
    ForeignKey,
    ManyToManyField,
    OneToOneField,
)

# Fields NetBox adds for API consumers that have no counterpart on the model.
READ_ONLY_FIELDS = {
    "url",
    "display",
    "display_url",
    "natural_slug",
    "_depth",
    "_occupied",
    "device_count",
    "rack_count",
    "site_count",
    "prefix_count",
    "vlan_count",
    "ipaddress_count",
    "member_count",
    "circuit_count",
    "cluster_count",
    "virtualmachine_count",
    "tenant_count",
    "asn_count",
    "aggregate_count",
    "utilization",
    "children",
    "depth",
    "notes_url",
    # Tag assignments arrive as their own endpoint (extras/tagged-objects), which
    # maps onto the TaggedItem through-model. Setting them from the object side
    # as well would duplicate the work and fight over the same rows.
    "tags",
}


# Models that must never be imported, and why.
#
# ContentType (exposed by NetBox as core.ObjectType) is maintained by Django
# itself and is already correct after migrate. Worse, its primary keys differ
# between installations: they are assigned in migration order, not by content.
# Deleting or overwriting the local table would break every generic foreign key
# in the database.
SKIPPED_MODELS = {
    "contenttypes.ContentType",
    "core.ObjectType",
}

# Models that are deliberately absent from the export for security reasons, and
# whose rows therefore do not exist locally. Unlike ContentType above, these
# cannot be referenced: a foreign key pointing at them is cleared, because the
# alternative is a constraint violation at COMMIT.
#
# Object ownership (users.Owner) is the practical case - it resolves to a user
# or a group, and neither is exported to a device that travels.
UNAVAILABLE_MODELS = {
    "users.Owner",
    "users.OwnerGroup",
    "users.User",
    "users.Group",
    "auth.User",
    "auth.Group",
}


# Export field names that differ from the model field they belong to. Only
# consulted when the exported name has no direct counterpart on the model.
FIELD_ALIASES = {
    "object_type": "content_type",
}


class ImportAborted(Exception):
    """Raised to unwind the transaction after the first genuine failure."""


def log(message):
    print(message, flush=True)


def build_object_type_translation(json_dir):
    """Maps exported ContentType IDs onto the local ones.

    Generic relations - image attachments, tagged items, contact assignments -
    store a content type ID alongside an object ID. Those IDs are per-database,
    so importing them verbatim would point each record at whatever model
    happens to occupy that ID locally. The pair (app_label, model) is stable and
    is used as the bridge.
    """
    from django.contrib.contenttypes.models import ContentType

    path = os.path.join(json_dir, "core_object-types.json")
    if not os.path.isfile(path):
        return {}

    with open(path, "r", encoding="utf-8") as handle:
        content = handle.read().strip()

    if not content:
        return {}

    local = {
        (ct.app_label, ct.model): ct.pk
        for ct in ContentType.objects.all()
    }

    # Two key shapes are stored side by side because NetBox uses both. List
    # endpoints such as core/object-types identify a type by numeric ID, while
    # generic relations (object_type, termination_type) carry the natural key
    # "app_label.model" - which, unlike an ID, is stable across installations.
    translation = {
        f"{app_label}.{model}": pk for (app_label, model), pk in local.items()
    }

    missing = []

    for record in json.loads(content):
        key = (record.get("app_label"), record.get("model"))
        local_id = local.get(key)
        if local_id is None:
            missing.append(f"{key[0]}.{key[1]}")
            continue
        translation[record["id"]] = local_id

    if missing:
        log(
            f"    WARN  {len(missing)} object types from the export do not exist locally: "
            + ", ".join(missing[:6])
            + (" ..." if len(missing) > 6 else "")
        )

    return translation


def build_endpoint_model_map():
    """Maps '<app>_<endpoint>' to a Django model via NetBox's API routers.

    Deriving this from the live URL configuration rather than a hand-written
    table means a NetBox upgrade cannot silently desynchronise it.
    """
    from django.urls import get_resolver

    mapping = {}

    def walk(patterns, prefix=""):
        for p in patterns:
            pattern = str(getattr(p, "pattern", ""))
            if hasattr(p, "url_patterns"):
                walk(p.url_patterns, prefix + pattern)
                continue

            callback = getattr(p, "callback", None)
            cls = getattr(callback, "cls", None)
            if cls is None:
                continue

            queryset = getattr(cls, "queryset", None)
            if queryset is None:
                continue

            full = (prefix + pattern).replace("^", "").replace("$", "")
            parts = full.strip("/").split("/")
            if len(parts) != 3 or parts[0] != "api":
                continue

            mapping.setdefault(parts[1] + "_" + parts[2], queryset.model)

    walk(get_resolver().url_patterns)
    return mapping


def scalarise(value):
    """Reduces a NetBox API value to what the model field expects."""
    if isinstance(value, dict):
        # Choice fields are rendered as {"value": ..., "label": ...}.
        if "value" in value and "label" in value:
            return value["value"]
        # Related objects carry their primary key.
        if "id" in value:
            return value["id"]
    return value


def prepare_record(model, record, object_type_translation=None):
    """Splits one exported record into concrete field values and M2M values."""
    from django.contrib.contenttypes.models import ContentType

    concrete = {}
    deferred_m2m = {}

    # Only real database columns and many-to-many fields can be assigned.
    # get_fields() would also hand back GenericForeignKeys (which expect a model
    # instance, not an ID) and reverse relations such as Interface.mac_addresses
    # (which reject direct assignment outright). The generic relations are
    # already covered by their concrete *_type_id / *_id companions.
    fields_by_name = {field.name: field for field in model._meta.concrete_fields}
    for field in model._meta.many_to_many:
        fields_by_name[field.name] = field

    for key, value in record.items():
        if key in READ_ONLY_FIELDS:
            continue

        field = fields_by_name.get(key)

        # django-taggit names its generic relation 'content_type', while the
        # NetBox API reports it as 'object_type' like everywhere else.
        if field is None and key in FIELD_ALIASES:
            key = FIELD_ALIASES[key]
            field = fields_by_name.get(key)

        if field is None:
            continue

        # Relations into models that were never imported cannot be satisfied.
        if field.related_model is not None and (
            field.related_model._meta.label in UNAVAILABLE_MODELS
        ):
            continue

        if isinstance(field, ManyToManyField):
            # Handled after the objects exist. NetBox exports the through
            # tables (tagged-objects, cable-terminations) as endpoints of their
            # own, so most relations arrive that way anyway.
            if isinstance(value, list) and value:
                related = [scalarise(v) for v in value]

                if object_type_translation and issubclass(
                    field.related_model, ContentType
                ):
                    # Object types contributed by plugins that are not installed
                    # locally simply have no counterpart. Dropping them keeps the
                    # remaining assignments intact.
                    related = [
                        object_type_translation[v]
                        for v in related
                        if v in object_type_translation
                    ]

                if related:
                    deferred_m2m[key] = related
            continue

        # A null in the export for a NOT NULL column means "the API does not
        # expose this field", not "store NULL here". Setting it explicitly would
        # override the model default and violate the constraint - dcim.Cable's
        # 'profile' is one such field.
        if value is None and not getattr(field, "null", True):
            continue

        # Image and file fields hold a path relative to MEDIA_ROOT, but the API
        # returns an absolute URL that does not fit the column. The media files
        # themselves are not part of any export either, so a path here would
        # only produce broken image placeholders.
        if isinstance(field, FileField):
            concrete[key] = ""
            continue

        if isinstance(field, (ForeignKey, OneToOneField)):
            target = scalarise(value)

            # Content type references are the one kind of ID that is not
            # portable between databases and has to be translated.
            if (
                object_type_translation
                and target is not None
                and issubclass(field.related_model, ContentType)
            ):
                translated = object_type_translation.get(target)
                if translated is None:
                    # Typically an object type belonging to a plugin that is not
                    # installed locally. If the column allows it, the reference
                    # is dropped; otherwise the record cannot be represented.
                    if field.null:
                        target = None
                    else:
                        raise ValueError(
                            f"Object type ID {target} has no local counterpart "
                            f"(field {field.name} is not optional)"
                        )
                else:
                    target = translated

            concrete[field.attname] = target
            continue

        if isinstance(value, list):
            # Array fields (for example ASN lists) pass through as-is.
            concrete[key] = [scalarise(v) for v in value]
            continue

        concrete[key] = scalarise(value)

    # MPTT keeps its tree bookkeeping in NOT NULL columns that are normally
    # filled during save(). bulk_create bypasses that, so they are seeded with
    # placeholders here and the real values are computed by the rebuild step
    # once every node exists. The API never exports them - it exposes the
    # derived '_depth' instead.
    for tree_field in ("lft", "rght", "tree_id", "level"):
        if tree_field in fields_by_name and tree_field not in concrete:
            concrete[tree_field] = 0

    return concrete, deferred_m2m


def dependency_sorted(models):
    """Orders models so that referenced models are created first.

    Django declares its foreign keys as DEFERRABLE INITIALLY DEFERRED, so this
    is not strictly required inside a transaction. It still keeps self-parent
    chains and MPTT models in a sane order and makes failures easier to read.
    """
    graph = {m: set() for m in models}

    for model in models:
        for field in model._meta.get_fields():
            if isinstance(field, (ForeignKey, OneToOneField)):
                target = field.related_model
                if target in graph and target is not model:
                    graph[model].add(target)

    ordered = []
    seen = set()
    visiting = set()

    def visit(model):
        if model in seen:
            return
        if model in visiting:
            # A cycle: order within it does not matter thanks to deferred
            # constraints.
            return
        visiting.add(model)
        for dependency in graph[model]:
            visit(dependency)
        visiting.discard(model)
        seen.add(model)
        ordered.append(model)

    for model in models:
        visit(model)

    return ordered


def reset_sequences(models):
    """Realigns primary key sequences after inserting explicit IDs.

    Without this the next insert would reuse an ID that already exists. The
    instance is read-only, so nothing should ever insert again - but leaving a
    loaded gun lying around is not a design.
    """
    with connection.cursor() as cursor:
        for model in models:
            pk = model._meta.pk
            if not isinstance(pk, (AutoField, BigAutoField)):
                continue
            table = connection.ops.quote_name(model._meta.db_table)
            column = connection.ops.quote_name(pk.column)
            cursor.execute(
                "SELECT setval("
                "  pg_get_serial_sequence(%s, %s),"
                "  COALESCE((SELECT MAX({col}) FROM {tbl}), 1)"
                ")".format(col=column, tbl=table),
                [model._meta.db_table, pk.column],
            )


def nullify_dangling_references(models):
    """Clears optional foreign keys whose target was not imported.

    An API export is never guaranteed to be referentially closed: endpoints the
    token cannot read return 403, objects are created between page requests, and
    a device may well point at an IP address that never made it into the files.
    Django defers its constraint checks to COMMIT, so a single dangling
    reference would otherwise discard the entire import at the last moment.

    Only nullable columns are cleared. A dangling mandatory reference means the
    record genuinely cannot exist locally and is reported instead of hidden.
    """
    repaired = []

    with connection.cursor() as cursor:
        for model in models:
            table = connection.ops.quote_name(model._meta.db_table)

            for field in model._meta.get_fields():
                if not isinstance(field, (ForeignKey, OneToOneField)):
                    continue
                if not field.null:
                    continue

                target = field.related_model
                if target is None or target._meta.label in SKIPPED_MODELS:
                    continue

                column = connection.ops.quote_name(field.column)
                target_table = connection.ops.quote_name(target._meta.db_table)
                target_column = connection.ops.quote_name(target._meta.pk.column)

                cursor.execute(
                    f"UPDATE {table} SET {column} = NULL "
                    f"WHERE {column} IS NOT NULL AND NOT EXISTS ("
                    f"  SELECT 1 FROM {target_table} AS t "
                    f"  WHERE t.{target_column} = {table}.{column}"
                    f")"
                )

                if cursor.rowcount:
                    repaired.append((model._meta.label, field.name, cursor.rowcount))

    return repaired


def rebuild_derived_structures():
    """Recreates everything bulk_create skipped by not firing signals."""

    # --- MPTT trees --------------------------------------------------------
    rebuilt = []
    for model in apps.get_models():
        manager = getattr(model, "objects", None)
        if manager is not None and hasattr(manager, "rebuild"):
            try:
                manager.rebuild()
                rebuilt.append(model.__name__)
            except Exception as exc:  # pragma: no cover - diagnostic only
                log(f"    WARN  MPTT rebuild for {model.__name__} failed: {exc}")
    if rebuilt:
        log(f"    OK    MPTT trees rebuilt: {', '.join(sorted(rebuilt))}")

    # --- Cable paths -------------------------------------------------------
    # Trace information is a denormalised cache that lives only in the local
    # database; it is not part of any API export.
    try:
        from django.core.management import call_command

        from dcim.models import Cable, CablePath

        # NetBox ships trace_paths for exactly this purpose. Rebuilding the
        # cache by hand is guesswork against internal signal helpers whose
        # signature changes between releases.
        CablePath.objects.all().delete()
        call_command("trace_paths", force=True, no_input=True, verbosity=0)

        log(
            f"    OK    Cable paths recomputed "
            f"({Cable.objects.count()} cables, {CablePath.objects.count()} paths)"
        )
    except Exception as exc:
        log(f"    WARN  Could not recompute cable paths: {exc}")

    # --- Search index ------------------------------------------------------
    try:
        from django.core.management import call_command

        call_command("reindex", verbosity=0)
        log("    OK    Search index rebuilt")
    except Exception as exc:
        log(f"    WARN  Could not rebuild search index: {exc}")


def main():
    parser = argparse.ArgumentParser(
        description="Imports a NetBox API export into the local instance."
    )
    parser.add_argument(
        "export_dir",
        help="Directory containing manifest.json, or its JSON subfolder",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Analyse only, write nothing to the database.",
    )
    args = parser.parse_args()

    export_dir = os.path.abspath(args.export_dir)
    json_dir = export_dir
    if os.path.isdir(os.path.join(export_dir, "JSON")):
        json_dir = os.path.join(export_dir, "JSON")

    if not os.path.isdir(json_dir):
        log(f"ERROR: directory not found: {json_dir}")
        return 1

    # --- Manifest ----------------------------------------------------------
    manifest_path = os.path.join(os.path.dirname(json_dir), "manifest.json")
    manifest = {}
    if os.path.isfile(manifest_path):
        with open(manifest_path, "r", encoding="utf-8") as handle:
            manifest = json.load(handle)

    log("=== NetBox import ===")
    log(f"    Source          : {json_dir}")

    if manifest:
        log(f"    Export time     : {manifest.get('exportTime')}")
        log(f"    Source version  : {manifest.get('netBoxVersion')}")
        log(f"    Export status   : {manifest.get('status')}")

        source_version = str(manifest.get("netBoxVersion") or "")

        from netbox.settings import VERSION as local_version

        local_major_minor = ".".join(str(local_version).split(".")[:2])
        source_major_minor = ".".join(source_version.split(".")[:2])

        source_major = source_major_minor.split(".")[0] if source_major_minor else ""
        local_major = local_major_minor.split(".")[0]

        if source_major and source_major != local_major:
            # A major release renames tables and drops models outright. Nothing
            # sensible can be salvaged from that, so this stays a hard stop.
            log("")
            log(f"ERROR: incompatible versions. The export came from NetBox {source_version},")
            log(f"        this instance is NetBox {local_version}.")
            log("        Major versions differ - models and tables are not comparable.")
            log("        Build the bundle for the matching NetBox version:")
            log(f"        .\\build\\Set-NetBoxVersion.ps1 -Version {source_version}")
            return 2

        if source_major_minor and source_major_minor != local_major_minor:
            # Minor releases add and remove individual fields. The import maps
            # by name and skips whatever the local model does not have, so the
            # data still lands - just without anything the local NetBox has no
            # column for. Verified by importing a 4.6.8 export into 4.5.9:
            # 23 models, 72 objects, no errors.
            log("")
            log(f"    NOTE: the export is from NetBox {source_version}, this instance is {local_version}.")
            log("          Fields that exist only in the other version are skipped;")
            log("          everything else is imported normally. Build a matching")
            log("          bundle if you need those fields:")
            log(f"          .\\build\\Set-NetBoxVersion.ps1 -Version {source_version}")
            log("")

        if manifest.get("status") != "complete":
            failed = manifest.get("failedEndpoints") or {}
            log("")
            log(f"    WARNING: export is incomplete ({len(failed)} endpoints failed).")
            for name in list(failed)[:10]:
                log(f"             - {name}")
            log("    The import continues, but the affected data is missing.")

    # --- Dateien einlesen --------------------------------------------------
    endpoint_models = build_endpoint_model_map()

    object_type_translation = build_object_type_translation(json_dir)

    files = sorted(f for f in os.listdir(json_dir) if f.endswith(".json"))
    datasets = {}
    unmapped = []
    empty = []
    skipped = []

    for filename in files:
        name = filename[:-5]
        model = endpoint_models.get(name)

        if model is None:
            unmapped.append(name)
            continue

        if model._meta.label in SKIPPED_MODELS or model._meta.label in UNAVAILABLE_MODELS:
            skipped.append(name)
            continue

        with open(os.path.join(json_dir, filename), "r", encoding="utf-8") as handle:
            content = handle.read().strip()

        records = json.loads(content) if content else []
        if isinstance(records, dict):
            records = [records]

        if not records:
            empty.append(name)
            continue

        datasets[model] = datasets.get(model, []) + records

    log("")
    log(f"    Files           : {len(files)}")
    log(f"    Mapped          : {len(datasets)} models with data")
    log(f"    Empty           : {len(empty)}")
    log(f"    Object type map : {len(object_type_translation)} Eintraege")
    if skipped:
        log(f"    Deliberately skipped: {', '.join(skipped)} (managed by Django)")
    if unmapped:
        preview = ", ".join(unmapped[:8])
        suffix = " ..." if len(unmapped) > 8 else ""
        log(f"    Unmapped        : {len(unmapped)} ({preview}{suffix})")

    total_records = sum(len(v) for v in datasets.values())
    log(f"    Objects total   : {total_records}")

    if args.dry_run:
        log("")
        log("=== Dry run, nothing is written ===")
        for model, records in sorted(datasets.items(), key=lambda kv: -len(kv[1])):
            log(f"    {model._meta.label:<44} {len(records):>7}")
        return 0

    models_in_order = dependency_sorted(list(datasets.keys()))

    # --- Import ------------------------------------------------------------
    log("")
    log("=== Importing ===")

    created_total = 0
    failures = defaultdict(list)

    try:
        run_import(models_in_order, datasets, object_type_translation, failures)
    except ImportAborted as aborted:
        log("")
        log(f"    Import aborted at {aborted}. Nothing was written.")
        log("    The database is unchanged (transaction rolled back).")
        return 3

    log("")
    log("=== Derived structures ===")
    rebuild_derived_structures()

    # --- Ergebnis ----------------------------------------------------------
    log("")
    log("=== Result ===")

    imported = sum(len(v) for v in datasets.values())
    log(f"    Objects imported   : {imported}")

    if failures:
        log(f"    Models with errors : {len(failures)}")
        for label, messages in list(failures.items())[:10]:
            log(f"      {label}: {len(messages)} Errors")
            for message in messages[:3]:
                log(f"        {message[:150]}")
        return 3

    log("    Errors             : none")
    return 0


def run_import(models_in_order, datasets, object_type_translation, failures):
    """Replaces the local dataset inside a single transaction."""
    with transaction.atomic():
        # Delete in reverse dependency order so that nothing references a row
        # that has already gone.
        for model in reversed(models_in_order):
            model.objects.all().delete()

        for model in models_in_order:
            records = datasets[model]
            instances = []
            deferred = []

            for record in records:
                try:
                    concrete, m2m = prepare_record(
                        model, record, object_type_translation
                    )
                    instances.append(model(**concrete))
                    if m2m:
                        deferred.append((record.get("id"), m2m))
                except Exception as exc:
                    failures[model._meta.label].append(f"id={record.get('id')}: {exc}")

            if instances:
                try:
                    model.objects.bulk_create(instances, batch_size=500)
                    log(f"    OK    {model._meta.label:<44} {len(instances):>7}")
                except Exception as exc:
                    # A failed statement poisons the transaction, so every
                    # later model would only report "you can't execute queries
                    # until the end of the atomic block". Stopping here keeps
                    # the actual cause as the last thing on screen.
                    failures[model._meta.label].append(str(exc))
                    log(f"    ERROR  {model._meta.label:<43} {exc}")
                    raise ImportAborted(model._meta.label) from exc

            for pk, relations in deferred:
                try:
                    instance = model.objects.get(pk=pk)
                    for field_name, values in relations.items():
                        getattr(instance, field_name).set(values)
                except Exception as exc:
                    failures[model._meta.label].append(f"M2M id={pk}: {exc}")

        repaired = nullify_dangling_references(models_in_order)

        if repaired:
            total = sum(count for _, _, count in repaired)
            log("")
            log(f"    {total} dangling references cleared (incomplete export):")
            for label, field_name, count in sorted(
                repaired, key=lambda r: -r[2]
            )[:12]:
                log(f"      {label}.{field_name}: {count}")

        reset_sequences(models_in_order)

    # Reporting and the rebuild of derived structures live in main(), which runs
    # them only after this transaction has committed.


if __name__ == "__main__":
    sys.exit(main())
