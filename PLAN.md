# Plan: NetBoxLocal — Offline Read-Only NetBox für Notfallnotebooks

**Status**: Entwurf, wartet auf Bestätigung
**Komplexität**: Groß (~26–41 Personentage initial, 2–5 Tage pro NetBox-Upgrade danach)

## Ziel

Eine lokal auf Windows-Notfallnotebooks installierbare NetBox-Instanz, die

- optisch und funktional **identisch** zur produktiven NetBox ist (keine Nachbildung),
- **alle** NetBox-Objekttypen enthält (DCIM, IPAM, Circuits, Tenancy, Verkabelung inkl. Traces, Custom Fields, Config Contexts),
- **nicht editierbar** ist — kein Schreibpfad für Benutzer,
- ihren Datenstand im Normalbetrieb selbstständig per Task Scheduler aktualisiert,
- als **MSI/EXE ohne Voraussetzungen** installierbar ist (kein Docker, kein WSL, keine Adminrechte).

## Architekturentscheidung

Die Kombination *pixelgenau* + *alle Objekte* + *keine Voraussetzungen* lässt genau eine Architektur zu:
**echte NetBox, vollständig gebündelt, native Windows-Prozesse, per-User-Installation.**

```
NetBoxLocal.exe (Launcher/Tray)
  |- postgres.exe        (portable PostgreSQL, Datenverzeichnis in %LOCALAPPDATA%)
  |- redis-server.exe    (BSD-Fork, siehe Risiko R2)
  |- waitress-serve      (WSGI, ersetzt gunicorn - gunicorn laeuft nicht auf Windows)
  |    `- NetBox (Django) auf embedded Python 3.12
  `- Browser -> http://127.0.0.1:8001
```

Verworfene Alternativen:

| Alternative | Warum verworfen |
|---|---|
| Eigener Read-Only-Viewer im NetBox-Look | Anforderung ist *pixelgenau identisch*, nicht *ähnlich* |
| NetBox in WSL2 (Rootfs per `wsl --import`) | Setzt WSL2, Virtualisierung und Adminrechte voraus — explizit ausgeschlossen |
| NetBox in Docker Desktop | Gleiche Begründung |
| SQLite statt PostgreSQL | Unmöglich. NetBox nutzt `django.contrib.postgres` (ArrayField, SearchVector, JSONB) |

## Datenpfad: pg_dump statt REST-API

**Entscheidung: verlustfreier DB-Dump, ausgeliefert über HTTPS.**

Die REST-API wurde als Quelle geprüft und verworfen. Sie liefert nicht:

- `CablePath` — den denormalisierten Trace-Cache. Ohne ihn sind Kabel-Traces und `connected_endpoints` leer.
- MPTT-Baumfelder (`lft`, `rght`, `tree_id`, `level`) für Regions, SiteGroups, Locations, TenantGroups, ContactGroups, InventoryItems.
- `ContentType`-IDs, die alle GenericForeignKeys auflösen (Cable-Terminations, Tags, Custom-Field-Werte, Contact-Assignments, Journal, Images). IDs unterscheiden sich zwischen Installationen.
- `CachedValue` — den Suchindex von NetBox 4. Globale Suche wäre leer.
- ObjectChange-Historie, gerenderte Config Contexts, Users/Permissions.

Zusätzlich sind API-Serializer keine Modellfelder (`display`, `url`, `_depth`, Brief-Repräsentationen). Ein API-Loader müsste ~150 Serializer rückwärts abbilden und bei jedem NetBox-Minor-Release nachgezogen werden.

**Umgesetzter Kompromiss** — behält den sauberen HTTP-Pull, den die API attraktiv macht:

```
NetBox-Host                              Notfallnotebook
-----------                              ---------------
Cronjob (taeglich)                       Task Scheduler (taeglich)
  pg_dump -Fc --exclude-table-data=...     1. GET /export/netbox-latest.pgc (Bearer-Token)
  -> gzip -> /var/www/export/              2. SHA256 + Versionsheader pruefen
  -> SHA256-Datei + Versionsmanifest       3. pg_restore in Staging-DB
  -> nginx: token-geschuetzte HTTPS-URL    4. Smoke-Test auf Staging
                                           5. Atomarer Switch (DB-Rename)
                                           6. reindex + mptt rebuild
```

Ein fehlgeschlagener Import darf die vorhandene lokale Instanz nie beschädigen — daher Staging-DB und atomarer Switch.

## Read-Only-Durchsetzung (5 Ebenen)

NetBox hat **keinen** globalen Read-Only-Schalter. Die Durchsetzung ist geschichtet; Ebene 3 ist die eigentliche Absicherung, der Rest ist Kosmetik und Tiefenverteidigung.

| # | Ebene | Wirkung |
|---|---|---|
| 1 | NetBox-User nur mit `view`-Permissions, kein Superuser | UI blendet Add/Edit/Delete-Buttons aus → sieht native aus |
| 2 | Auto-Login per Middleware, `LOGIN_REQUIRED=True` | Kein Passwort im Störfall nötig |
| 3 | **PostgreSQL-Rolle mit `SELECT`-only** auf alle NetBox-Tabellen; `INSERT/UPDATE/DELETE` nur auf `django_session` | Harte Grenze. Auch API und Shell können nicht schreiben |
| 4 | Middleware blockt alle HTTP-Methoden außer GET/HEAD/OPTIONS; `/admin/` entfernt | Schließt API-Schreibpfade |
| 5 | Importer nutzt eigene, privilegierte DB-Rolle; Credential nicht in der Web-App-Config | Trennung Lese- und Schreibpfad |

Django braucht Schreibrechte auf `django_session` — deshalb die Ausnahme in Ebene 3. Das ist die einzige beschreibbare Tabelle.

## Phasen

### Phase 0 — Technischer Spike (3–5 Tage) · **Kill-Gate**

Der Plan lebt oder stirbt hier. Nichts weiter bauen, bevor das steht.

| Task | Verifikation |
|---|---|
| NetBox auf nativem Windows starten, embedded Python 3.12 | Dashboard, Device-Detail, IPAM-Prefix-Liste, Rack-Elevation, Kabel-Trace laden fehlerfrei |
| `gunicorn` → `waitress` ersetzen | Alle Seiten inkl. statischer Assets laden |
| Portables PostgreSQL: `initdb` nach `%LOCALAPPDATA%` ohne Adminrechte | Cluster startet als normaler User |
| Redis auf Windows evaluieren (R2) | NetBox startet, Cache funktioniert, keine 500er |
| `pg_restore` eines Produktions-Dumps in das gebündelte Postgres | Objektzahlen stimmen mit Quelle überein |
| `manage.py reindex` + MPTT-Rebuild nach Restore | Globale Suche und Baumhierarchien korrekt |

**Abbruchkriterien:** Scheitert Redis oder der native Windows-Start → Rückfall auf gebündeltes WSL2-Rootfs (setzt Adminrechte voraus, Anforderung muss neu verhandelt werden) oder auf einen eigenen Read-Only-Viewer.

### Phase 1 — Bundle bauen (8–12 Tage)

- Reproduzierbarer Build: embedded Python + venv, alle Wheels vendored und gepinnt (`--require-hashes`)
- Portable PostgreSQL-Binaries einbinden, `initdb`/Start/Stop-Automatik
- Redis-Binary einbinden, minimale Config, Loopback-only
- `collectstatic` zur Build-Zeit
- `configuration.py` für den Offline-Betrieb: `ALLOWED_HOSTS=['127.0.0.1','localhost']`, `DEBUG=False`, generierter `SECRET_KEY` pro Installation, Housekeeping deaktiviert
- Launcher/Tray-Anwendung: startet die drei Prozesse in Abhängigkeitsreihenfolge, Health-Wait, Browser öffnen, sauberes Herunterfahren, Logrotation
- Portkollisionen behandeln (dynamische Portwahl, Anzeige im Tray)

### Phase 2 — Export- und Sync-Kette (4–6 Tage)

- Exportskript auf dem NetBox-Host: `pg_dump -Fc`, **sanitisiert** (siehe Phase 3, Task S1), Kompression, SHA256, Versionsmanifest (NetBox-Version + Schema-Migrationsstand)
- Auslieferung über HTTPS mit Bearer-Token, nur lesbar
- Importer auf dem Notebook: Download, Integritätsprüfung, **Versions-Gate** (Dump-Migrationsstand muss zur gebündelten NetBox-Version passen — sonst Abbruch mit klarer Meldung), Restore in Staging-DB, Smoke-Test, atomarer Switch, `reindex`, MPTT-Rebuild
- Task-Scheduler-Eintrag (per-User, kein Admin), Retry-Verhalten, "letzter erfolgreicher Stand"-Anzeige
- **Sichtbare Datenstandsanzeige in der UI** (Banner via `BANNER_TOP`): Datum des letzten Imports. Ein veralteter Stand, der wie ein aktueller aussieht, ist im Störfall gefährlicher als kein Stand.

### Phase 3 — Härtung (3–5 Tage)

- **S1**: Sanitisierung im Export — `--exclude-table-data` für `users_token`, `users_user`, `core_objectchange`; Review aller Custom Fields und Config Contexts auf Secrets
- DB-Rollenmodell (Ebene 3 und 5 oben) inkl. Migrations-Hook, damit neue Tabellen automatisch nur Leserechte erhalten
- Read-Only-Middleware (Ebene 4), Admin-URLs entfernen
- Auto-Login-Middleware (Ebene 2)
- Negativtests: Schreibversuch über UI, über `/api/`, über `nbshell` — alle müssen scheitern
- Verschlüsselung des Datenverzeichnisses prüfen (BitLocker-Abhängigkeit dokumentieren)

### Phase 4 — Installer (5–8 Tage)

- **Per-User-Installation** nach `%LOCALAPPDATA%\NetBoxLocal` — vermeidet Adminrechte vollständig
- WiX (MSI, `InstallScope=perUser`) oder Inno Setup (EXE). Inno ist für diesen Fall deutlich weniger Reibung; MSI nur wenn die Softwareverteilung es zwingend verlangt
- Erstlauf: `initdb`, Rollen anlegen, Migrationen, Scheduler-Task registrieren
- Deinstallation: Prozesse stoppen, Datenverzeichnis auf Nachfrage entfernen
- Signierung mit Firmen-Codesigning-Zertifikat (sonst SmartScreen-Warnung auf jedem Notebook)
- Größenerwartung: ~250–400 MB Installer, ~800 MB–1,2 GB installiert

### Phase 5 — Rollout und Betrieb (3–5 Tage)

- Pilot auf 2 Notebooks, 2 Wochen Beobachtung
- Runbook: "NetBox ist weg — was tue ich?" (eine Seite, ausgedruckt im Notfallordner)
- Betriebsdoku: Upgrade-Prozess bei NetBox-Version-Sprung, Monitoring der Sync-Kette (ein stiller Sync-Ausfall ist der wahrscheinlichste Fehlerfall)
- Lizenz-Compliance: NetBox ist Apache-2.0 — `LICENSE` und `NOTICE` mitliefern, PostgreSQL- und Redis-Lizenzen beilegen. NetBox-Marke nur intern verwenden, keine Weitergabe außerhalb des Unternehmens

## Risiken

| # | Risiko | Wahrsch. | Auswirkung | Gegenmaßnahme |
|---|---|---|---|---|
| R1 | NetBox läuft nativ auf Windows nicht sauber (unentdeckte POSIX-Abhängigkeit) | Mittel | Kritisch | Phase-0-Spike als Gate; Fallback WSL2-Rootfs oder eigener Viewer |
| R2 | **Redis auf Windows**: kein offizieller Build. Verfügbar sind ein unmaintainter BSD-Fork (Redis 5.0.14) oder Memurai (kommerziell, Weitergabe lizenzrechtlich problematisch) | Hoch | Hoch | Fork pinnen und mitliefern; parallel prüfen, ob NetBox mit `LocMemCache` und deaktivierten Background-Jobs ohne Redis lauffähig ist |
| R3 | `django-rq` benötigt `fork()` → **Worker läuft auf Windows nicht** | Hoch | Niedrig | Akzeptiert. Read-Only-Instanz braucht keine Background-Jobs; die Jobs-Seite bleibt leer. Dokumentieren |
| R4 | **Sync fällt still aus**, Nutzer sehen im Störfall alte Daten und merken es nicht | Hoch | Hoch | Datenstands-Banner in der UI (Phase 2); Alter-Schwelle → auffällige Warnung; zentrales Monitoring der Pull-Zugriffe |
| R5 | **Dump enthält Secrets** (API-Tokens, Passwort-Hashes) auf mobilen Geräten | Hoch | Hoch | Serverseitige Sanitisierung (Phase 3/S1); Festplattenverschlüsselung als Voraussetzung dokumentieren |
| R6 | NetBox-Version-Drift: Dump-Schema passt nicht zur gebündelten NetBox | Hoch | Mittel | Versionsmanifest und hartes Gate im Importer; Upgrade nur über neues Installationspaket |
| R7 | Schema-Migration bringt neue Tabellen, die versehentlich beschreibbar sind | Mittel | Mittel | `DEFAULT PRIVILEGES` auf Schema-Ebene, nicht pro Tabelle |
| R8 | Installer-Größe und SmartScreen blockieren Rollout | Mittel | Mittel | Codesigning; Auslieferung über Softwareverteilung statt Direktdownload |
| R9 | Dauerhafte Wartungslast unterschätzt | Hoch | Mittel | Explizit einplanen: 2–5 Tage pro NetBox-Upgrade. Upgrade-Kadenz bewusst niedrig halten |
| R10 | Portkollision oder Virenscanner blockiert die gebündelten Binaries | Mittel | Mittel | Dynamische Portwahl; Binaries vorab beim Endpoint-Schutz whitelisten lassen |

## Validierung

```powershell
# Phase 0
python -c "import netbox; print('ok')"
waitress-serve --port=8001 netbox.wsgi:application
# Alle Views manuell: Dashboard, Device-Detail, Rack-Elevation, Kabel-Trace, IPAM, Suche

# Phase 2 - Objektzahlen Quelle vs. lokal vergleichen
python manage.py shell -c "from dcim.models import Device, Cable; print(Device.objects.count(), Cable.objects.count())"
python manage.py shell -c "from dcim.models import CablePath; print(CablePath.objects.count())"

# Phase 3 - Negativtests, alle muessen fehlschlagen
curl -X POST http://127.0.0.1:8001/api/dcim/sites/ -H "Authorization: Token ..."
python manage.py shell -c "from dcim.models import Site; Site.objects.create(name='x', slug='x')"

# Phase 4
msiexec /i NetBoxLocal.msi /qn /l*v install.log   # als Nicht-Admin
```

## Offene Punkte

- NetBox-Version und Datenbankgröße der Quelle (bestimmt Dump-Größe und Installer-Dimensionierung)
- Anzahl der Notfallnotebooks
- Kommen die Notebooks im Normalbetrieb überhaupt ans Firmennetz? Wenn nein, bricht der Task-Scheduler-Pull und es braucht einen anderen Verteilweg
- Existiert ein Codesigning-Zertifikat?
- Ist Festplattenverschlüsselung auf den Notebooks aktiv?

## Abnahme

- [ ] Phase-0-Gate bestanden, alle NetBox-Views laden nativ auf Windows
- [ ] Installation als Nicht-Admin auf einem frischen Windows-11-Notebook erfolgreich
- [ ] Objektzahlen und Kabel-Traces stimmen mit der Quelle überein
- [ ] Alle fünf Read-Only-Ebenen aktiv, Negativtests scheitern durchgehend
- [ ] Dump enthält keine Tokens und keine Passwort-Hashes
- [ ] Sync läuft 14 Tage unbeaufsichtigt; Datenstand ist in der UI sichtbar
- [ ] Runbook liegt ausgedruckt im Notfallordner
