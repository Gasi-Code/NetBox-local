# NetBox Local

A complete NetBox instance that runs offline on Windows — no Docker, no WSL, no
administrator rights.

It was built for emergency notebooks: when the central NetBox is unreachable,
this holds a copy of the data and looks exactly like the real thing, because it
*is* the real thing. It also works as a standalone local NetBox for anyone who
would rather not run a container or a Linux VM.

**Documentation:** [English](README_en.md) · [Deutsch](README_de.md)

---

## What it does

```
NORMAL OPERATION (daily, unattended)

   Production NetBox                    Windows notebook
   ┌───────────────┐                    ┌────────────────────────┐
   │ ~120 endpoints│  REST API, HTTPS   │ Task Scheduler, 17:00  │
   │               │ ─────────────────► │ Sync-NetBoxExport      │
   └───────────────┘   read-only        │        ↓               │
                                        │ Monday.zip … Sunday    │
                                        └────────────────────────┘

DURING AN OUTAGE (one double-click)

   start PostgreSQL + Garnet + web server
        ↓
   load the newest export (replaces the previous dataset)
        ↓
   browser opens http://127.0.0.1:8001/
```

## Highlights

- **Real NetBox**, not a rebuild — same interface, same features
- **Self-contained**: NetBox, PostgreSQL, Garnet, .NET runtime and Python in one
  directory, installed per user
- **Three access modes**: read-only replica, full-access standalone instance, or
  both accounts side by side
- **Lossless import** of a complete API export, including MPTT trees, generic
  relations, cable paths and the search index
- **MSI installer** with an access-mode dialog, no administrator rights required

## Requirements

Windows 10 or 11, 64-bit, about 2 GB of free disk space. Network access to the
production NetBox is needed only for the daily export, never while looking
things up.

## Getting started

Install the MSI from the releases page, or build everything from source:

```powershell
.\build\fetch-components.ps1 -PinHashes   # download components (~400 MB)
.\build\build-bundle.ps1                  # assemble dist\bundle
.\installer\Build-Installer.ps1           # produce the MSI
```

Then set up the export and the desktop shortcut as described in
[README_en.md](README_en.md).

## Repository layout

| Path | Contents |
|---|---|
| `build/` | component manifest with pinned SHA256 checksums, fetch and assembly scripts |
| `config/` | `NetBoxLocal.json` — the single configuration file |
| `installer/` | WiX definitions, build and signing scripts |
| `src/export/` | API export, run daily by the Task Scheduler |
| `src/import/` | import of an export into the local instance |
| `src/launcher/` | start, stop, account setup, desktop shortcut |
| `assets/` | application icon |

The runnable bundle is **not** in this repository. It is roughly 620 MB of
third-party software and is reproduced byte for byte by the build scripts, which
pin every component to a verified checksum.

## Status

Working and tested end to end: bundle build, API export, import of a real
dataset (about 12,000 objects), read-only enforcement, MSI installation and
uninstallation.

Not done yet: the MSI is unsigned, so Windows SmartScreen warns on first launch.
`installer/Sign-Installer.ps1` is ready for a code signing certificate.

## Licence

[MIT](LICENSE) for the scripts and documentation in this repository. The bundled
components keep their own licences; none of them are redistributed here.

NetBox is a trademark of NetBox Labs. This project is not affiliated with or
endorsed by NetBox Labs.
