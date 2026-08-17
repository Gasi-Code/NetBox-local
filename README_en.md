# NetBox Local

*German version: [README_de.md](README_de.md)*

A complete NetBox instance that runs offline on a Windows emergency notebook. It
holds a copy of your production NetBox data and exists so that people can still
look things up during an outage, when the central server is unreachable.

This is **not a rebuild**: it runs the real NetBox software with the real
interface. Everything is bundled into one directory — no Docker, no WSL, no
administrator rights, and no internet connection while it is in use.

---

## Contents

1. [How it works](#1-how-it-works)
2. [Everyday use](#2-everyday-use)
3. [Setting up a notebook](#3-setting-up-a-notebook)
4. [Configuration](#4-configuration)
5. [The export from NetBox](#5-the-export-from-netbox)
6. [The import into the local instance](#6-the-import-into-the-local-instance)
7. [Building the bundle](#7-building-the-bundle)
8. [Troubleshooting](#8-troubleshooting)
9. [Operations and maintenance](#9-operations-and-maintenance)
10. [Directory layout](#10-directory-layout)

---

## 1. How it works

Two separate processes that never need to run at the same time:

```
NORMAL OPERATION (daily, unattended)

   Production NetBox                    Emergency notebook
   ┌───────────────┐                    ┌────────────────────────┐
   │ netbox.…      │  REST API (HTTPS)  │ Task Scheduler, 17:00  │
   │ ~120 endpoints│ ─────────────────► │ Sync-NetBoxExport      │
   └───────────────┘   read-only        │        ↓               │
                                        │ C:\Sync-Daten\…        │
                                        │   Monday.zip … Sunday  │
                                        └────────────────────────┘

DURING AN OUTAGE (one double-click)

   ┌────────────────────────────────────────────────────────────┐
   │  Desktop icon "NetBox Local"                               │
   │        ↓                                                   │
   │  start PostgreSQL + Garnet + web server                    │
   │        ↓                                                   │
   │  load the newest export (replaces the previous dataset)    │
   │        ↓                                                   │
   │  browser opens http://127.0.0.1:8001/                      │
   └────────────────────────────────────────────────────────────┘
```

So the export runs **while everything is healthy**. During an outage only what
is already on disk gets loaded.

### The components

| Component | Version | Purpose |
|---|---|---|
| NetBox | 4.5.9 | the application itself |
| PostgreSQL | 17.5 | database, inside the user profile |
| Microsoft Garnet | 2.1.4 | Redis replacement (NetBox will not start without one) |
| .NET runtime | 10.0.11 | required by Garnet |
| Python | 3.13.15 embeddable | no installer, no admin rights |
| waitress | 3.0.2 | web server (gunicorn does not run on Windows) |
| WhiteNoise | 6.12.0 | serves CSS and JavaScript |

All services listen on `127.0.0.1` only. There is no access from outside and no
firewall exception is needed.

---

## 2. Everyday use

### Starting

Double-click **NetBox Local** on the desktop.

A console window opens and shows the progress:

```
  NetBox Local
  ------------

==> Starting services
    OK   Services running (port 8001)
    Dataset date : 2026-08-17 13:11 (0.1 days old)
==> Loading dataset (the previous one is replaced)
    OK    dcim.Device                                     1044
    OK    ipam.IPAddress                                  6259
    …
    Objects imported   : 11953
    Errors             : none
==> Checking login account
  Ready.
  Address  : http://127.0.0.1:8001/
  Username : admin
  Password : ………
```

The browser opens by itself. **The window may be closed** — NetBox Local keeps
running. The first start takes longer because the database is created; after
that, expect two to four minutes.

### Logging in

The username and password appear in the console window and are also stored in:

```
%LOCALAPPDATA%\NetBoxLocal\secrets\admin-password.txt
```

### Stopping

`src\launcher\Stop-NetBoxLocal.cmd` — or `Ctrl+C` in the start window if it is
still open.

PostgreSQL is shut down in an orderly fashion (`PostgreSQL shut down cleanly`).
That is not cosmetic: a database service that was killed has to restore its
consistency on the next start, which delays exactly the moment when speed
matters.

If the window is simply closed, PostgreSQL and Garnet keep running. That is
harmless; the next start detects them and reuses them.

### Things to know

> **Every start replaces the entire dataset.**
> Anything deleted in the production NetBox disappears here too. Local edits are
> lost on the next start — this instance is a copy, not a place to keep data.

> **Watch the dataset date.**
> If it is older than eight days, a red warning block appears. That almost
> always means the daily synchronisation has stopped running.

---

## 3. Setting up a notebook

### Requirements

- Windows 10 or 11, 64-bit
- roughly 2 GB of free disk space
- administrator rights are **not** required
- network access to the production NetBox — only for the daily export

### Step 1 — Install

Use the installer package:

```
dist\installer\NetBox Local 1.0.0.msi
```

A double-click is enough. **No administrator rights are required** — it installs
into `%LOCALAPPDATA%\Programs\NetBox Local` and creates the desktop icon and the
Start menu entries itself.

For unattended rollout through a software management system:

```powershell
msiexec /i "NetBox Local 1.0.0.msi" /qn /l*v install.log
```

Uninstall through *Settings → Apps*, or:

```powershell
msiexec /x "NetBox Local 1.0.0.msi" /qn
```

The database and credentials under `%LOCALAPPDATA%\NetBoxLocal` survive an
uninstall, so reinstalling picks up the previous dataset. Delete that directory
by hand for a clean slate.

> The package is currently **not signed**, so Windows SmartScreen warns on first
> launch. A company code-signing certificate fixes that:
> ```powershell
> signtool sign /f cert.pfx /p PASSWORD /fd SHA256 /t http://timestamp.digicert.com "NetBox Local 1.0.0.msi"
> ```

**Without the installer:** copy the `NetBox Local - Final` directory onto the
notebook and run `src\launcher\Install-DesktopShortcut.ps1` once. Functionally
identical, just without an entry in *Apps & features*.

### Step 2 — Adjust the configuration

Open `config\NetBoxLocal.json` and check at least:

```jsonc
"webUser": { "username": "admin", "password": "", "readOnly": true },
"import":  { "syncRoot": "C:\\Sync-Daten\\NetBoxLocal" }
```

See [Configuration](#4-configuration).

### Step 3 — Set up the export

Open `src\export\Sync-NetBoxExport.ps1` and fill in at the top:

```powershell
$NetBoxServer = "https://netbox.example.com/"
$APIKey       = "<token with read permissions only>"
```

> **The token must not have write permissions.** In NetBox under
> *Admin → API Tokens*, clear the *Write enabled* checkbox. A notebook can be
> lost; a write-capable token inside it would be full access to your production
> NetBox.

Then register the scheduled task:

```powershell
cd C:\NetBoxLocal\src\export
.\Register-SyncTask.ps1 -Uhrzeit "17:00"
```

With several notebooks, stagger the times (17:00, 17:15, 17:30 …) so they do not
hit the server simultaneously.

Test it once:

```powershell
Start-ScheduledTask -TaskName "NetBox-Gesamtexport"
```

Then check `C:\Sync-Daten\NetBoxLocal` — a weekday archive such as `Monday.zip`
must appear.

### Step 4 — Create the desktop icon

```powershell
cd C:\NetBoxLocal\src\launcher
.\Install-DesktopShortcut.ps1
```

For every user of the device (requires administrator rights):

```powershell
.\Install-DesktopShortcut.ps1 -AllUsers
```

### Step 5 — First run

Double-click the new icon. The first start creates the database and takes a few
minutes.

---

## 4. Configuration

Everything adjustable lives in **`config\NetBoxLocal.json`**. Changes take
effect on the next start.

### `webUser` — login account

```jsonc
"webUser": {
  "username": "admin",
  "password": "",
  "readOnly": true
}
```

| Field | Meaning |
|---|---|
| `username` | login name for the interface |
| `password` | Empty = one is generated on first start and stored in `secrets\admin-password.txt`. Set = enforced on every start, which is convenient for a single shared password across notebooks |
| `readOnly` | `true` = the account only gets read permissions. NetBox then hides every edit control; the interface is otherwise identical |

**`readOnly` defaults to `true`.** Without it, someone can change entries during
an outage that silently vanish on the next start — and while they are visible,
they may well be mistaken for real data.

The mode has been verified against a running instance. With `readOnly: true`:

| Action | Result |
|---|---|
| Reading pages and lists | allowed |
| Edit and delete controls | not rendered |
| Opening an edit form directly | 403 |
| Submitting a change or deletion | 403 |
| Writing through the REST API | 403 |

It is implemented as a non-superuser account belonging to a group that holds
`view` permission on every object type. A superuser would bypass all permission
checks — which is why hiding the buttons alone is not enough.

To switch, change the value and restart; the account is adjusted on every start.

### `import` — data source

```jsonc
"import": {
  "syncRoot": "C:\\Sync-Daten\\NetBoxLocal",
  "autoImportOnStart": true,
  "maxAgeWarningDays": 8
}
```

| Field | Meaning |
|---|---|
| `syncRoot` | where the export stores its weekday archives |
| `autoImportOnStart` | `false` = do not load anything on start, just open |
| `maxAgeWarningDays` | age at which the prominent warning appears |

### `ports` — network ports

```jsonc
"ports": { "postgres": 55432, "garnet": 56379, "web": 8001 }
```

Only change these if another application already uses them. All are bound to
`127.0.0.1`.

### `paths` and `browser`

```jsonc
"paths":   { "dataRoot": "" },
"browser": { "openOnStart": true }
```

Leave `dataRoot` empty for `%LOCALAPPDATA%\NetBoxLocal`, which holds the
database, the logs and the credentials.

---

## 5. The export from NetBox

`src\export\Sync-NetBoxExport.ps1`, run by the Windows Task Scheduler.

### What it does

1. Discovers every list endpoint of the API at runtime — so new models are
   picked up after a NetBox upgrade
2. Fetches each endpoint page by page (ordered by ID, so concurrent edits cannot
   shift records between pages)
3. Writes one JSON and one CSV file per endpoint
4. Produces `manifest.json` with timestamp, NetBox version, object counts and
   any failed endpoints
5. Computes SHA256 checksums
6. Packs everything into `<Weekday>.zip`, keeping seven days of history
7. Reports success to monitoring — **only on a fully complete run**

### Deliberately excluded endpoints

21 endpoints are never exported; each carries its reason in the script:

| Endpoint | Reason |
|---|---|
| `users/tokens` | contains API tokens in clear text |
| `users/users`, `users/groups`, `users/permissions` | access control, personal data |
| `core/object-changes` | full changelog, often millions of rows |
| `core/data-files` | contains file contents |
| various user-scoped ones | bookmarks, filters, notifications |

### Checking the result

`status.txt` in the target directory holds one line per weekday:

```
Monday: 2026.08.17 17:00:12 - ERFOLGREICH (12173 Objekte, Datei: Monday.zip)
```

Inside the archive, `manifest.json` reads:

```jsonc
{
  "status": "complete",          // or "partial"
  "exportTime": "2026-08-17T17:00:12.1234567+02:00",
  "netBoxVersion": "4.5.9",
  "endpointsExported": 126,
  "failedEndpoints": { },
  "objectCounts": { "dcim_devices": 1044 }
}
```

`status: partial` means individual endpoints failed, usually because the token
lacks read permission for them. Their names are listed under `failedEndpoints`.

---

## 6. The import into the local instance

Normally this happens automatically on start. Manually:

```
src\import\Import-NetBoxExport.cmd
```

Without an argument it picks the newest export. You can also drag an export
folder onto the file, or pass it:

```
Import-NetBoxExport.cmd "D:\path\to\Monday"
```

Analyse without writing anything:

```powershell
cd dist\bundle\netbox\netbox
..\..\python\python.exe ..\..\..\..\src\import\Import-NetBoxExport.py "D:\path" --dry-run
```

### How it proceeds

The whole import runs in **one transaction**. If anything fails, the previous
dataset stays fully intact.

1. Check the version in `manifest.json` against the local NetBox — a differing
   minor version aborts the run
2. Delete all objects
3. Insert the records, **preserving their original IDs**
4. Clear references pointing at objects that were not imported
5. Reset the primary key sequences
6. Rebuild MPTT trees, cable paths and the search index

### What is not imported

| Object | Reason |
|---|---|
| Object types (`core.ObjectType`) | managed by Django, IDs differ per installation |
| Users, groups, ownership | not part of the export |
| Image files | only the metadata is exported, not the files |
| Plugin objects (e.g. Slurpit) | the plugin is not installed locally |

### Exit codes

| Code | Meaning |
|---|---|
| 0 | success |
| 1 | export directory not found |
| 2 | version mismatch between export and local NetBox |
| 3 | import failed, database unchanged |

---

## 7. Building the bundle

Only needed when `dist\bundle` is missing or the NetBox version has to change.
Requires internet access, about 400 MB of downloads and roughly 4 GB free.

```powershell
cd C:\NetBoxLocal
.\build\fetch-components.ps1 -PinHashes    # download components and pin hashes
.\build\build-bundle.ps1                   # assemble the bundle
```

A running instance is shut down by the build itself before `dist\bundle` is
rebuilt — open files would otherwise break the rebuild halfway through.

### Changing the NetBox version

The local version **must** match production, otherwise the import aborts.

In `build\components.json`:

```jsonc
"netboxVersion": "4.5.9",
{ "name": "netbox", "version": "4.5.9",
  "url": "https://github.com/netbox-community/netbox/archive/refs/tags/v4.5.9.tar.gz",
  "sha256": "" }
```

Clear `sha256` so the new hash is recorded on the next run. Then run both build
steps again and create the database from scratch:

```powershell
.\src\launcher\Start-NetBoxServices.ps1 -Init -NoServe
```

> `-Init` deletes the local database along with its credentials. Both are
> recreated on the next regular start.

The version in use is recorded in `manifest.json` under `netBoxVersion`.

---

## 8. Troubleshooting

Logs live in `%LOCALAPPDATA%\NetBoxLocal\logs`.

### "Port 55432 is already in use"

An earlier instance is still running.

```
src\launcher\Stop-NetBoxLocal.cmd
```

The start deliberately refuses here: connecting to whatever owns that port would
mean silently reading from a foreign database.

### The start hangs at "PostgreSQL: start"

After an unclean shutdown — a flat battery, for instance — PostgreSQL restores
its consistency first. The launcher waits up to five minutes and reports
`Database is recovering from an unclean shutdown`. Just wait.

### "Static Media Failure" in the browser

`whitenoise` is missing from the bundle:

```powershell
dist\bundle\python\python.exe -m pip install whitenoise==6.12.0
```

Running `build-bundle.ps1` again fixes it permanently.

### "ERROR: version mismatch"

The export and the local NetBox differ in their minor version. See
[Changing the NetBox version](#changing-the-netbox-version). The abort is
intentional: fields differ between minor versions, and importing anyway would
silently lose data.

### The export reports `status: partial`

Individual endpoints answered with **403** — the API token is not allowed to
read them. Their names are in `manifest.json` under `failedEndpoints`. Extend
the read permissions of the token's user in NetBox under *Admin → Permissions*.

No code change is needed: both the export and the import work generically, so
those endpoints flow through as soon as the permissions are in place.

### The dataset is too old

Check whether the scheduled task is running:

```powershell
Get-ScheduledTask -TaskName "NetBox-Gesamtexport" | Get-ScheduledTaskInfo
```

Then look at `status.txt` and the service log in
`C:\Sync-Skripte\Sync-NetBoxExport`.

### The console window closes immediately

Always use the `.cmd` files, never the `.ps1` directly. The `.cmd` variant keeps
the window open so messages stay readable.

### Edits are still possible despite `readOnly: true`

The account is reconfigured on every start. Check that the value really is
`true` in `config\NetBoxLocal.json` and that the start reports
`User 'admin' updated (read-only)`. An account previously created as a superuser
is demoted automatically.

Note that the restriction covers the web interface and the REST API. Anyone with
direct access to the PostgreSQL database can bypass it — deliberately so,
because the import needs exactly that path.

---

## 9. Operations and maintenance

### Check regularly

| What | How often | Where |
|---|---|---|
| Is the export running? | weekly | `status.txt`, monitoring |
| Is `status` equal to `complete`? | weekly | `manifest.json` |
| Does the NetBox version still match? | after every upgrade | `manifest.json` vs `components.json` |
| Does the instance start and open? | quarterly | test run on one notebook |

The most likely failure is a **silent stop of the synchronisation**: it works
for months, breaks unnoticed, and during an outage someone reads stale data.
That is why the export only reports success to monitoring on `complete`, and why
the launcher warns about an old dataset.

### After a NetBox upgrade

1. Enter the new version in `components.json`, clear `sha256`
2. Run `fetch-components.ps1 -PinHashes` and `build-bundle.ps1`
3. Run `Start-NetBoxServices.ps1 -Init -NoServe`
4. Test with a current export
5. Distribute the bundle to the notebooks

### Security

- The API token must have read permissions only
- The export contains no tokens, users or password hashes
- The notebooks should be BitLocker-encrypted — the export contains the full
  network documentation
- All local services are bound to `127.0.0.1`

### Licences

NetBox is Apache 2.0, Garnet and the .NET runtime are MIT, PostgreSQL uses the
PostgreSQL licence, Python is PSF-2.0. An overview ships in
`dist\bundle\LICENSES\COMPONENTS.txt`. Distribution inside the company is
covered by these terms.

---

## 10. Directory layout

```
NetBoxLocal\
├─ assets\
│  └─ netbox-local.ico            icon for the desktop shortcut
├─ build\
│  ├─ components.json             pinned components with SHA256
│  ├─ fetch-components.ps1        download and extract
│  └─ build-bundle.ps1            assemble into dist\bundle
├─ config\
│  └─ NetBoxLocal.json            ► the only configuration file
├─ dist\bundle\                   the runnable bundle (~600 MB)
│  ├─ python\  netbox\  pgsql\  garnet\  dotnet\
├─ src\
│  ├─ export\
│  │  ├─ Sync-NetBoxExport.ps1    API export, daily via Task Scheduler
│  │  └─ Register-SyncTask.ps1    registers the scheduled task
│  ├─ import\
│  │  ├─ Import-NetBoxExport.py   the import itself
│  │  └─ Import-NetBoxExport.cmd  ► import by double-click
│  └─ launcher\
│     ├─ NetBoxLocal.cmd          ► target of the desktop shortcut
│     ├─ Start-NetBoxLocal.ps1    start, load, open
│     ├─ Start-NetBoxServices.ps1 services only
│     ├─ Stop-NetBoxLocal.cmd     ► shut down
│     ├─ Install-DesktopShortcut.ps1
│     ├─ netboxlocal_wsgi.py      WSGI wrapper serving static files
│     └─ ensure_user.py           creates the login account
├─ PLAN.md                        project plan with phases and risks
├─ PHASE0-RESULTS.md              feasibility results
├─ README_de.md                   German documentation
└─ README_en.md                   this document
```

Mutable data lives outside the project:

```
%LOCALAPPDATA%\NetBoxLocal\
├─ pgdata\      PostgreSQL database
├─ logs\        log files
└─ secrets\     passwords, generated automatically

C:\Sync-Daten\NetBoxLocal\
├─ Monday.zip … Sunday.zip        seven-day rotation
└─ status.txt                     result per weekday
```
