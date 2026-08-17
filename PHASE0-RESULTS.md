# Phase 0 — Ergebnis: Kill-Gate **bestanden**

Datum: 2026-08-17 · Gegenstand: `PLAN.md`, Phase 0

## Kernergebnis

NetBox 4.6.8 läuft **nativ auf Windows**, ohne Docker, ohne WSL, ohne Adminrechte,
mit vollständig gebündeltem PostgreSQL, Redis-Ersatz und Python.

```
/login/   HTTP 200, 3391 bytes    NetBox-Login rendert
/api/     HTTP 403                korrekt (nicht angemeldet, LOGIN_REQUIRED)
migrate   Exit 0                  alle Migrationen durchgelaufen
collectstatic                     201 Dateien
```

## Verifizierte Komponenten

| Komponente | Version | Status |
|---|---|---|
| Python embeddable | 3.13.15 | läuft; höchste Version mit `embed-amd64`-Paket |
| NetBox | 4.6.8 | Migrationen + collectstatic + Login-Seite OK |
| PostgreSQL (EnterpriseDB) | 17.5 | Cluster in `%LOCALAPPDATA%`, ohne Adminrechte |
| Microsoft Garnet | 2.1.4 (`net10.0`) | Redis-Ersatz, alle 32 benötigten Kommandos |
| .NET Runtime | 10.0.11 | gebündelt, EOL 2028-11-14 |
| waitress | 3.0.2 | ersetzt gunicorn |

Bundle: **~600 MB** (528,8 MB vor .NET-Runtime, +76,7 MB Runtime).

## Gefundene Blocker und ihre Lösungen

### 1. `psycopg[c,pool]` baut auf Windows nicht
`psycopg-c` hat **null** `win_amd64`-Wheels und bräuchte libpq plus C-Compiler.
→ Ersetzt durch `psycopg[binary,pool]` (cp313-win_amd64-Wheel vorhanden).

### 2. Redis existiert auf Windows nicht mehr
Der im Plan vorgesehene `tporadowski/redis`-Fork steht auf **Redis 5.0.14.1, letztes
Release 2022-02-17**. NetBox-Doku: *"Support for Redis versions older than 6.0 is
deprecated and will be removed in NetBox v4.7."* Der Fork hatte also ein Ablaufdatum.
→ Ersetzt durch **Microsoft Garnet** (MIT, RESP2/RESP3, aktiv gepflegt).
Risiko R2 aus `PLAN.md` ist damit erledigt, nicht nur gemildert.

### 3. Garnet ist **nicht** self-contained
Das Asset `win-x64-based-readytorun.zip` ist framework-*based*, nicht self-contained.
`GarnetServer.exe` bricht ohne .NET 10 ab mit
`You must install or update .NET to run this application`.
→ .NET-Runtime 10.0.11 als sechste Komponente gebündelt, Anbindung über `DOTNET_ROOT`
und `DOTNET_MULTILEVEL_LOOKUP=0`. Damit bleibt „keine Voraussetzungen" erfüllt.

### 4. Zonky-PostgreSQL liefert keine Client-Tools
`io.zonky.test.postgres` enthält nur `initdb`, `pg_ctl`, `postgres` — es fehlen
`pg_restore`, `pg_dump`, `psql`, die der Importer zwingend braucht.
→ EnterpriseDB-Binaries (307 MB Download). `pgAdmin 4` allein ist 654 MB der
entpackten 829 MB; nach dem Trim auf `bin`/`lib`/`share` bleiben **131 MB**.

### 5. `pg_ctl -w start` blockiert unter Windows
Der gestartete `postgres.exe` erbt die stdio-Handles, `pg_ctl` kehrt erst zurück,
wenn alle geschlossen sind — was nie passiert.
→ `postgres.exe` wird direkt als eigener Prozess gestartet. Nebeneffekt: saubere PID
zum Beenden.

### 6. Embeddable Python ignoriert das Skriptverzeichnis
Eine `._pth`-Datei versetzt den Interpreter in den Isolated Mode: `sys.path` entsteht
ausschließlich daraus, `PYTHONPATH` und das Verzeichnis von `manage.py` werden
ignoriert. Django scheiterte mit `ModuleNotFoundError: No module named 'netbox'`.
→ `..\netbox\netbox` explizit in `python313._pth` eingetragen.

### 7. pip kann in Embeddable-Python keine sdists bauen
`BackendUnavailable: Cannot import 'setuptools.build_meta'` — die isolierte
Build-Umgebung erbt den kaputten `sys.path`. Betrifft genau ein Paket:
`django-pglocks==1.0.4` (4 kB, reines Python, kein Wheel).
→ `setuptools`+`wheel` lokal installieren, dann `--no-build-isolation`.

## Produktrelevanter Bug, im Launcher behoben

`Wait-ForPort` prüfte nur, **ob** ein Port offen ist, nicht **wessen** Port es ist.
Ein alter `postgres` auf einem früheren Cluster hielt Port 55432; der neue konnte
nicht binden, die Wartefunktion meldete trotzdem Erfolg — und NetBoxLocal verband
sich still mit der **fremden Datenbank**. In einem Notfallsystem hieße das:
falsche Daten, ohne jede Fehlermeldung.

→ Drei Korrekturen: `Assert-PortAvailable` bricht vor dem Start ab, wenn der Port
belegt ist; `Wait-ForPort` bekommt das Prozess-Handle und meldet sofort, wenn der
Prozess vorher stirbt; das Beenden läuft über die PID.

Das ist eine verschärfte Ausprägung von Risiko R10 in `PLAN.md`.

## Offene Punkte für Phase 1

- `LOGIN_REQUIRED` ist ab NetBox v5.0 entfernt (FutureWarning beim Start). Das
  Auto-Login-Konzept aus Phase 3 muss darauf vorbereitet sein.
- Python-Verzeichnis ist mit 263 MB unnötig groß: NetBox' `requirements.txt` zieht
  das komplette mkdocs-/mkdocs-material-Doku-Tooling mit. Trimmbar.
- Bundle-Rebuild scheitert, solange Prozesse Handles auf `dist\bundle` halten.
  Der Build braucht einen Stop-Schritt davor.
- Garnet-Kommandoabdeckung wurde gegen die Dokumentation geprüft, nicht zur
  Laufzeit. Ein Lasttest mit django-rq und django-redis steht aus.
- Bauhost-Disk war mit 98 % Belegung (19–23 GB frei) grenzwertig.

## Wie starten

```powershell
.\build\fetch-components.ps1 -PinHashes   # einmalig, ~400 MB Download
.\build\build-bundle.ps1                  # Bundle nach dist\bundle
.\src\launcher\Start-NetBoxServices.ps1      # Stack hoch, dann http://127.0.0.1:8001
```
