"""Creates or updates the login accounts for the local NetBox instance.

Driven entirely by environment variables so the launcher can call it without
putting a password on a command line, where every process on the machine could
read it:

    NETBOXLOCAL_MODE          readonly | superuser | both
    NETBOXLOCAL_USERNAME      primary account
    NETBOXLOCAL_PASSWORD
    NETBOXLOCAL_RO_USERNAME   second, read-only account (mode "both" only)
    NETBOXLOCAL_RO_PASSWORD

The three modes exist because the same bundle serves two different purposes:

    readonly   a replica on an emergency notebook, where an accidental edit
               would silently vanish on the next import and might be mistaken
               for real data in the meantime
    superuser  a self-contained local NetBox for someone who does not want to
               run Docker or a Linux VM
    both       both accounts side by side

Running this repeatedly is safe. A password changed in config\\NetBoxLocal.json
therefore takes effect on the next start with no manual step, and switching
modes demotes or promotes the existing account rather than creating a new one.
"""

import os
import sys

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "netbox.settings")

import django  # noqa: E402

django.setup()

from django.contrib.auth import get_user_model  # noqa: E402

# NetBox subclasses Django's Group, and its own many-to-many relations point at
# that subclass. Using django.contrib.auth.models.Group here fails with
# "Field 'id' expected a number but got <Group: ...>".
from users.models import Group  # noqa: E402

READ_ONLY_GROUP = "NetBox Local read-only"

VALID_MODES = ("readonly", "superuser", "both")


def ensure_read_only_group():
    """Returns a group carrying view permission on every NetBox object type.

    NetBox hides its add/edit/delete controls when the user lacks the matching
    permission, so a view-only account renders exactly like the real thing minus
    the buttons - which is the point of a replica.
    """
    from core.models import ObjectType
    from users.models import ObjectPermission

    group, _ = Group.objects.get_or_create(name=READ_ONLY_GROUP)

    permission, created = ObjectPermission.objects.get_or_create(
        name=READ_ONLY_GROUP,
        defaults={"actions": ["view"], "enabled": True},
    )

    if not created:
        permission.actions = ["view"]
        permission.enabled = True
        permission.save()

    permission.groups.set([group])
    permission.object_types.set(ObjectType.objects.all())

    return group


def apply_account(username, password, read_only):
    """Creates or updates one account and returns a short status line."""
    User = get_user_model()

    user, created = User.objects.get_or_create(
        username=username,
        defaults={"email": f"{username}@localhost"},
    )

    user.set_password(password)
    user.is_active = True

    # A read-only account must not be a superuser: superusers bypass every
    # permission check, so the interface would still offer to edit.
    #
    # NetBox's user model has no is_staff field - assigning one would silently
    # create an attribute that is never persisted. is_superuser is the only
    # flag that matters here.
    user.is_superuser = not read_only
    user.save()

    if read_only:
        user.groups.set([ensure_read_only_group()])
        access = "read-only"
    else:
        user.groups.clear()
        access = "full access"

    action = "created" if created else "updated"
    return f"    OK   User '{username}' {action} ({access})"


def main():
    mode = (os.environ.get("NETBOXLOCAL_MODE") or "readonly").strip().lower()

    if mode not in VALID_MODES:
        print(f"ERROR: unknown mode '{mode}'. Expected one of: {', '.join(VALID_MODES)}.")
        return 1

    username = os.environ.get("NETBOXLOCAL_USERNAME", "admin")
    password = os.environ.get("NETBOXLOCAL_PASSWORD")

    if not password:
        print("ERROR: NETBOXLOCAL_PASSWORD is not set.")
        return 1

    results = []

    if mode == "readonly":
        results.append(apply_account(username, password, read_only=True))
    elif mode == "superuser":
        results.append(apply_account(username, password, read_only=False))
    else:
        ro_username = os.environ.get("NETBOXLOCAL_RO_USERNAME", "viewer")
        ro_password = os.environ.get("NETBOXLOCAL_RO_PASSWORD")

        if not ro_password:
            print("ERROR: NETBOXLOCAL_RO_PASSWORD is not set but mode is 'both'.")
            return 1

        if ro_username == username:
            print("ERROR: the read-only account must not have the same name as the primary one.")
            return 1

        results.append(apply_account(username, password, read_only=False))
        results.append(apply_account(ro_username, ro_password, read_only=True))

    for line in results:
        print(line)

    return 0


if __name__ == "__main__":
    sys.exit(main())
