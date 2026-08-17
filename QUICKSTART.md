# NetBox Local — Quick Install

**[English](#english) · [Deutsch](#deutsch)**

---

<a name="english"></a>

# English

## Before you start: which of the two are you doing?

NetBox Local covers two quite different situations. Everything about the API is
**optional** and exists only for the first one.

| | **A — Mirror an existing NetBox** | **B — Standalone local NetBox** |
|---|---|---|
| You have | a self-hosted NetBox somewhere | nothing yet |
| You want | a copy on a notebook for outages | a local NetBox without Docker or a VM |
| Access mode | `read-only` | `superuser` |
| API settings | needed | **leave every field empty** |
| Data comes from | the daily export | you, typed into the interface |

If you are doing **B**, you can skip every field marked *(optional)* and be
finished in two minutes.

---

## Step 1 — Run the installer

Double-click **`NetBox Local 1.5.0.msi`**.

- No administrator rights are required.
- It installs into `%LOCALAPPDATA%\Programs\NetBox Local`.
- Windows SmartScreen will warn, because the package is not signed yet. Choose
  *More info → Run anyway*.

You will walk through five pages:

### Page 1 — Welcome
Nothing to do. *Next*.

### Page 2 — Licence agreement
MIT for this project, plus the licences of the bundled components (NetBox,
PostgreSQL, Garnet, .NET, Python). Accept and continue.

### Page 3 — Installation folder
The default is fine. Around 620 MB is needed.

### Page 4 — How will NetBox Local be used?

Pick one:

| Option | Meaning |
|---|---|
| **Read-only** | One account that can look at everything and change nothing. NetBox hides every edit button. Right for emergency notebooks: an accidental edit would silently disappear on the next import and might be believed in the meantime. |
| **Full access** | One account that can do everything — this is case **B** above, a proper local NetBox. |
| **Both** | Two accounts side by side. Log in as the read-only one day to day, as the full-access one when you really need to change something. |

Then:

- **User name** — default `admin`.
- **Password** — type one, or leave it empty and one is generated for you. Where
  to find it later: see Step 4.
- **Read-only account** — the two extra fields only appear when you picked
  *Both*. Default name `viewer`.

### Page 5 — Data source *(optional)*

**Doing B? Leave everything empty and continue.** The export stays switched off
and NetBox Local starts as an empty local instance.

Doing A? Fill in:

| Field | What it is | Example |
|---|---|---|
| **Exported data folder** *(optional)* | Where the export puts its archives, and where the launcher looks for them. | `C:\Sync-Daten\NetBoxLocal` |
| **NetBox server address** *(optional)* | Your production NetBox. Leaving this empty switches the automatic import off entirely. | `https://netbox.example.com/` |
| **API token** *(optional)* | A token for reading the API. | `a1b2c3d4…` |

> **The token must not have write permissions.** In NetBox under
> *Admin → API Tokens*, clear *Write enabled*. A notebook can be lost or stolen;
> a write-capable token inside one is full access to your production NetBox.

Below that, **when should the data be collected?**

| Option | Runs |
|---|---|
| **Every day** *(default)* | daily at the chosen time |
| **Monday to Friday** | working days only |
| **Mondays only** | once a week |

**At time** takes a 24-hour value such as `17:00`.

The installer registers this as a Windows scheduled task named
**NetBox Local export**. That task runs the export **on its own** — NetBox Local
never has to be started for the data to stay current. This matters more than it
looks: during an outage the production NetBox is unreachable, so the data has to
have been collected *before* it. If the notebook was switched off at the
scheduled time, the run is caught up the next time it is switched on.

With several emergency notebooks, stagger the times (17:00, 17:15, 17:30 …) so
they do not all pull a full export at once.

The schedule can be changed later without reinstalling:

```powershell
cd "$env:LOCALAPPDATA\Programs\NetBox Local\src\export"
.\Register-SyncTask.ps1 -Status                     # what is registered now
.\Register-SyncTask.ps1 -Days weekdays -Time "07:45"
```

Then *Install*. It takes a few minutes — 30,000 files are being written.

---

## Step 2 — First start

Double-click **NetBox Local** on the desktop.

A console window opens and reports what it is doing:

```
  NetBox Local
  ------------

==> Starting services
    OK   Services running (port 8001)
==> Checking login account
    OK   User 'admin' created (full access)

  Ready.
  Address  : http://127.0.0.1:8001/
  Username : admin
  Password : k7Rm2pQx9nTvB4Ls
```

The browser opens by itself. The first start takes longer than later ones,
because the database is created from scratch.

The window then stays open as a small console:

```
    /stop     shut NetBox Local down and close this window
    /open     open the web interface in a browser
    /status   show which services are running
    /exit     close this window, leave NetBox Local running
```

Type `/stop` to shut everything down properly. Simply closing the window leaves
PostgreSQL and Garnet running — harmless, but the next start will tell you the
port is already in use.

---

## Step 3 — Set up the export *(optional, case A only)*

Skip this entirely for case **B**.

If you filled in the server address during installation, the export script is
already configured **and already scheduled** — the installer registered the task
with the days and time you picked on page 5. Nothing further is required.

Check what was registered:

```powershell
cd "$env:LOCALAPPDATA\Programs\NetBox Local\src\export"
.\Register-SyncTask.ps1 -Status
```

Change it at any time:

```powershell
.\Register-SyncTask.ps1 -Days weekdays -Time "07:45"
```

With several notebooks, stagger the times — 17:00, 17:15, 17:30 — so they do not
all hit the server at once.

Test it once, without waiting for the schedule:

```powershell
Start-ScheduledTask -TaskName "NetBox Local export"
```

Then look in your data folder. A weekday archive such as `Monday.zip` must
appear. Inside it, `manifest.json` should say `"status": "complete"`.

`"status": "partial"` means some endpoints returned **403** — the token cannot
read them. Extend its permissions in NetBox under *Admin → Permissions*. No code
change is needed; the export and import both work generically, so those
endpoints start flowing as soon as the permissions exist.

From then on, every start of NetBox Local loads the newest export automatically.

---

## Step 4 — Passwords: finding, changing, resetting

### Where is my password?

It is printed at every start, and stored here:

```
%LOCALAPPDATA%\NetBoxLocal\secrets\admin-password.txt
%LOCALAPPDATA%\NetBoxLocal\secrets\viewer-password.txt     (mode "both" only)
```

### How do I change it?

Edit **one file**:

```
%LOCALAPPDATA%\Programs\NetBox Local\config\NetBoxLocal.json
```

```jsonc
"webUser": {
  "mode": "readonly",
  "username": "admin",
  "password": "MyNewPassword123",
  "readOnlyUsername": "viewer",
  "readOnlyPassword": ""
}
```

Save, start NetBox Local again — done. The accounts are reapplied on every
start, so no separate command is needed.

### How do I switch between read-only and full access?

Same file, the `mode` field:

| Value | Result |
|---|---|
| `"readonly"` | one account, editing blocked |
| `"superuser"` | one account, full access |
| `"both"` | both accounts |

An existing account is promoted or demoted accordingly — you do not end up with
leftovers.

### I forgot the password entirely

Set `"password": ""` in the configuration and delete
`%LOCALAPPDATA%\NetBoxLocal\secrets\admin-password.txt`. The next start
generates a new one and prints it.

---

## Everything the configuration file controls

`%LOCALAPPDATA%\Programs\NetBox Local\config\NetBoxLocal.json`

| Setting | Meaning | Default |
|---|---|---|
| `webUser.mode` | `readonly`, `superuser` or `both` | `readonly` |
| `webUser.username` | login name | `admin` |
| `webUser.password` | empty = generate one | empty |
| `webUser.readOnlyUsername` | second account, mode `both` only | `viewer` |
| `webUser.readOnlyPassword` | its password | empty |
| `import.syncRoot` | folder holding the export archives | `C:\Sync-Daten\NetBoxLocal` |
| `import.autoImportOnStart` | load the newest export on every start | `true` |
| `import.maxAgeWarningDays` | warn loudly when data is older than this | `8` |
| `ports.postgres` / `garnet` / `web` | all bound to `127.0.0.1` | `55432` / `56379` / `8001` |
| `paths.dataRoot` | database, logs, passwords | `%LOCALAPPDATA%\NetBoxLocal` |
| `browser.openOnStart` | open a browser after starting | `true` |

The export settings live at the top of
`src\export\Sync-NetBoxExport.ps1`: `$NetBoxServer`, `$APIKey`,
`$global:ScriptPath`, `$global:LocalSyncPath`.

---

## Common problems

**"Port 55432 is already in use"** — an earlier instance is still running. Type
`/stop` in its window, or run `src\launcher\Stop-NetBoxLocal.cmd`. The start
deliberately refuses rather than risk reading from a foreign database.

**Startup hangs at "PostgreSQL: start"** — the database is recovering from an
unclean shutdown, for instance after a flat battery. It waits up to five minutes
and says so. Just wait.

**Server error mentioning Redis** — the web server is running but Garnet is not.
Stop everything with `Stop-NetBoxLocal.cmd` and start again.

**"ERROR: version mismatch"** — the export came from a different NetBox minor
version than the bundle. This is intentional: fields differ between versions and
importing anyway would silently lose data. Rebuild the bundle for the matching
version.

**Console window closes instantly** — always use the `.cmd` files, never the
`.ps1` directly.

---
---

<a name="deutsch"></a>

# Deutsch

## Vorab: Welchen der beiden Fälle hast du?

NetBox Local deckt zwei recht verschiedene Situationen ab. Alles rund um die API
ist **optional** und betrifft nur den ersten Fall.

| | **A — Bestehende NetBox spiegeln** | **B — Eigenständige lokale NetBox** |
|---|---|---|
| Du hast | eine selbst gehostete NetBox | noch nichts |
| Du willst | eine Kopie auf dem Notebook für den Störfall | eine lokale NetBox ohne Docker oder VM |
| Zugriffsmodus | `read-only` | `superuser` |
| API-Angaben | erforderlich | **alle Felder leer lassen** |
| Daten kommen von | täglichem Export | dir, über die Oberfläche eingetragen |

Bei **B** kannst du jedes mit *(optional)* markierte Feld überspringen und bist
in zwei Minuten fertig.

---

## Schritt 1 — Installer ausführen

Doppelklick auf **`NetBox Local 1.5.0.msi`**.

- Es sind **keine Adminrechte** nötig.
- Installiert wird nach `%LOCALAPPDATA%\Programs\NetBox Local`.
- Windows SmartScreen warnt, weil das Paket noch nicht signiert ist. Über
  *Weitere Informationen → Trotzdem ausführen* fortfahren.

Es folgen fünf Seiten:

### Seite 1 — Willkommen
Nichts zu tun. *Weiter*.

### Seite 2 — Lizenzvereinbarung
MIT für dieses Projekt, dazu die Lizenzen der mitgelieferten Komponenten
(NetBox, PostgreSQL, Garnet, .NET, Python). Annehmen und weiter.

### Seite 3 — Installationsordner
Die Vorgabe passt. Es werden rund 620 MB benötigt.

### Seite 4 — Wie soll NetBox Local genutzt werden?

Eine Auswahl treffen:

| Option | Bedeutung |
|---|---|
| **Read-only** | Ein Konto, das alles sehen und nichts ändern kann. NetBox blendet sämtliche Bearbeiten-Schaltflächen aus. Richtig für Notfallnotebooks: Eine versehentliche Änderung verschwände beim nächsten Import kommentarlos — und würde bis dahin womöglich geglaubt. |
| **Full access** | Ein Konto mit Vollzugriff — das ist Fall **B**, eine richtige lokale NetBox. |
| **Both** | Zwei Konten nebeneinander. Im Alltag mit dem Lesekonto anmelden, mit dem Vollzugriffskonto nur, wenn wirklich etwas geändert werden muss. |

Weiter:

- **Benutzername** — Vorgabe `admin`.
- **Kennwort** — eintragen, oder leer lassen und eines erzeugen lassen. Wo es
  danach steht: siehe Schritt 4.
- **Read-only-Konto** — die zwei zusätzlichen Felder erscheinen nur bei *Both*.
  Vorgabename `viewer`.

### Seite 5 — Datenquelle *(optional)*

**Fall B? Alles leer lassen und weiter.** Der Export bleibt abgeschaltet und
NetBox Local startet als leere lokale Instanz.

Fall A? Eintragen:

| Feld | Was es ist | Beispiel |
|---|---|---|
| **Exported data folder** *(optional)* | Wohin der Export seine Archive legt und wo der Starter sie sucht. | `C:\Sync-Daten\NetBoxLocal` |
| **NetBox server address** *(optional)* | Eure produktive NetBox. Bleibt das Feld leer, wird der automatische Import komplett abgeschaltet. | `https://netbox.example.com/` |
| **API token** *(optional)* | Ein Token zum Lesen der API. | `a1b2c3d4…` |

> **Der Token darf keine Schreibrechte haben.** In NetBox unter
> *Admin → API Tokens* das Häkchen bei *Write enabled* entfernen. Ein Notebook
> kann verloren gehen oder gestohlen werden; ein schreibfähiger Token darin ist
> ein Vollzugriff auf eure produktive NetBox.

Darunter: **wann sollen die Daten geholt werden?**

| Option | Läuft |
|---|---|
| **Every day** *(Vorgabe)* | täglich zur gewählten Uhrzeit |
| **Monday to Friday** | nur an Werktagen |
| **Mondays only** | einmal pro Woche |

**At time** erwartet eine Uhrzeit im 24-Stunden-Format, etwa `17:00`.

Der Installer legt das als Windows-Aufgabe **NetBox Local export** an. Diese
Aufgabe führt den Export **eigenständig** aus — NetBox Local muss dafür nie
gestartet sein. Das ist wichtiger, als es aussieht: Im Störungsfall ist die
produktive NetBox nicht erreichbar, die Daten müssen also *vorher* geholt worden
sein. War das Notebook zur geplanten Zeit ausgeschaltet, wird der Lauf beim
nächsten Einschalten nachgeholt.

Bei mehreren Notfallnotebooks die Zeiten staffeln (17:00, 17:15, 17:30 …), damit
sie nicht alle gleichzeitig einen Vollexport ziehen.

Der Zeitplan lässt sich später ohne Neuinstallation ändern:

```powershell
cd "$env:LOCALAPPDATA\Programs\NetBox Local\src\export"
.\Register-SyncTask.ps1 -Status                     # was ist gerade eingestellt
.\Register-SyncTask.ps1 -Days weekdays -Time "07:45"
```

Dann *Installieren*. Das dauert einige Minuten — es werden 30.000 Dateien
geschrieben.

---

## Schritt 2 — Erster Start

Doppelklick auf **NetBox Local** auf dem Desktop.

Ein Konsolenfenster öffnet sich und berichtet, was passiert:

```
  NetBox Local
  ------------

==> Starting services
    OK   Services running (port 8001)
==> Checking login account
    OK   User 'admin' created (full access)

  Ready.
  Address  : http://127.0.0.1:8001/
  Username : admin
  Password : k7Rm2pQx9nTvB4Ls
```

Der Browser öffnet sich von selbst. Der erste Start dauert länger als spätere,
weil die Datenbank neu angelegt wird.

Das Fenster bleibt danach als kleine Konsole offen:

```
    /stop     shut NetBox Local down and close this window
    /open     open the web interface in a browser
    /status   show which services are running
    /exit     close this window, leave NetBox Local running
```

Mit `/stop` fährt alles sauber herunter. Wird das Fenster einfach geschlossen,
laufen PostgreSQL und Garnet weiter — harmlos, aber der nächste Start meldet
dann einen belegten Port.

---

## Schritt 3 — Export einrichten *(optional, nur Fall A)*

Für Fall **B** komplett überspringen.

Wenn du bei der Installation die Serveradresse eingetragen hast, ist das
Exportskript bereits konfiguriert **und bereits eingeplant** — der Installer hat
die Aufgabe mit den auf Seite 5 gewählten Tagen und Zeiten angelegt. Es ist
nichts weiter zu tun.

Nachsehen, was eingetragen wurde:

```powershell
cd "$env:LOCALAPPDATA\Programs\NetBox Local\src\export"
.\Register-SyncTask.ps1 -Status
```

Jederzeit ändern:

```powershell
.\Register-SyncTask.ps1 -Days weekdays -Time "07:45"
```

Bei mehreren Notebooks die Zeiten staffeln — 17:00, 17:15, 17:30 — damit sie den
Server nicht gleichzeitig treffen.

Einmal testen, ohne auf den Zeitplan zu warten:

```powershell
Start-ScheduledTask -TaskName "NetBox Local export"
```

Dann im Datenordner nachsehen. Dort muss ein Wochentags-Archiv wie `Monday.zip`
liegen. Darin sollte `manifest.json` `"status": "complete"` melden.

`"status": "partial"` heißt, dass einzelne Endpunkte mit **403** geantwortet
haben — der Token darf sie nicht lesen. Die Rechte in NetBox unter
*Admin → Permissions* erweitern. Eine Codeänderung ist nicht nötig; Export und
Import arbeiten generisch, die Daten fließen automatisch mit, sobald die Rechte
da sind.

Ab dann spielt jeder Start von NetBox Local den neuesten Export automatisch ein.

---

## Schritt 4 — Kennwörter: finden, ändern, zurücksetzen

### Wo steht mein Kennwort?

Es wird bei jedem Start ausgegeben und liegt hier:

```
%LOCALAPPDATA%\NetBoxLocal\secrets\admin-password.txt
%LOCALAPPDATA%\NetBoxLocal\secrets\viewer-password.txt     (nur bei "both")
```

### Wie ändere ich es?

**Eine einzige Datei** bearbeiten:

```
%LOCALAPPDATA%\Programs\NetBox Local\config\NetBoxLocal.json
```

```jsonc
"webUser": {
  "mode": "readonly",
  "username": "admin",
  "password": "MeinNeuesKennwort123",
  "readOnlyUsername": "viewer",
  "readOnlyPassword": ""
}
```

Speichern, NetBox Local neu starten — fertig. Die Konten werden bei jedem Start
neu gesetzt, ein zusätzlicher Befehl ist nicht nötig.

### Wie wechsle ich zwischen read-only und Vollzugriff?

Dieselbe Datei, Feld `mode`:

| Wert | Ergebnis |
|---|---|
| `"readonly"` | ein Konto, Bearbeiten gesperrt |
| `"superuser"` | ein Konto, Vollzugriff |
| `"both"` | beide Konten |

Ein vorhandenes Konto wird entsprechend hoch- oder herabgestuft — es bleiben
keine Reste zurück.

### Ich habe das Kennwort komplett vergessen

In der Konfiguration `"password": ""` setzen und
`%LOCALAPPDATA%\NetBoxLocal\secrets\admin-password.txt` löschen. Der nächste
Start erzeugt ein neues und gibt es aus.

---

## Alles, was die Konfigurationsdatei steuert

`%LOCALAPPDATA%\Programs\NetBox Local\config\NetBoxLocal.json`

| Einstellung | Bedeutung | Vorgabe |
|---|---|---|
| `webUser.mode` | `readonly`, `superuser` oder `both` | `readonly` |
| `webUser.username` | Anmeldename | `admin` |
| `webUser.password` | leer = wird erzeugt | leer |
| `webUser.readOnlyUsername` | zweites Konto, nur bei `both` | `viewer` |
| `webUser.readOnlyPassword` | dessen Kennwort | leer |
| `import.syncRoot` | Ordner mit den Export-Archiven | `C:\Sync-Daten\NetBoxLocal` |
| `import.autoImportOnStart` | neuesten Export bei jedem Start einspielen | `true` |
| `import.maxAgeWarningDays` | ab diesem Alter deutlich warnen | `8` |
| `ports.postgres` / `garnet` / `web` | alle auf `127.0.0.1` gebunden | `55432` / `56379` / `8001` |
| `paths.dataRoot` | Datenbank, Protokolle, Kennwörter | `%LOCALAPPDATA%\NetBoxLocal` |
| `browser.openOnStart` | nach dem Start Browser öffnen | `true` |

Die Export-Einstellungen stehen oben in
`src\export\Sync-NetBoxExport.ps1`: `$NetBoxServer`, `$APIKey`,
`$global:ScriptPath`, `$global:LocalSyncPath`.

---

## Häufige Probleme

**„Port 55432 is already in use"** — eine frühere Instanz läuft noch. In deren
Fenster `/stop` eingeben oder `src\launcher\Stop-NetBoxLocal.cmd` ausführen. Der
Start bricht bewusst ab, statt womöglich aus einer fremden Datenbank zu lesen.

**Start hängt bei „PostgreSQL: start"** — die Datenbank stellt nach einem
unsauberen Herunterfahren ihre Konsistenz wieder her, etwa nach leerem Akku. Sie
wartet bis zu fünf Minuten und sagt das auch. Einfach abwarten.

**Serverfehler mit Redis-Meldung** — der Webserver läuft, Garnet aber nicht. Mit
`Stop-NetBoxLocal.cmd` alles beenden und neu starten.

**„ERROR: version mismatch"** — der Export stammt aus einer anderen
NetBox-Minor-Version als das Bundle. Der Abbruch ist Absicht: Zwischen Versionen
unterscheiden sich Felder, ein Import würde stillschweigend Daten verlieren. Das
Bundle für die passende Version neu bauen.

**Konsolenfenster schließt sich sofort** — immer die `.cmd`-Dateien verwenden,
nie die `.ps1` direkt.
