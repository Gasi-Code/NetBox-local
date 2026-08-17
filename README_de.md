# NetBox Local

*English version: [README_en.md](README_en.md)*

Eine vollwertige NetBox-Instanz, die offline auf einem Windows-Notfallnotebook
läuft. Sie enthält eine Kopie eures produktiven NetBox-Bestandes und ist dafür
gedacht, im Störfall nachschlagen zu können, wenn der zentrale Server nicht
erreichbar ist.

Es ist **kein Nachbau**: Es läuft die echte NetBox-Software mit der echten
Oberfläche. Alles ist in einem Verzeichnis gebündelt — kein Docker, kein WSL,
keine Adminrechte, keine Internetverbindung im Betrieb.

---

## Inhalt

1. [Wie es funktioniert](#1-wie-es-funktioniert)
2. [Tägliche Verwendung](#2-tägliche-verwendung)
3. [Einrichtung eines Notebooks](#3-einrichtung-eines-notebooks)
4. [Konfiguration](#4-konfiguration)
5. [Der Export von NetBox](#5-der-export-von-netbox)
6. [Der Import in die lokale Instanz](#6-der-import-in-die-lokale-instanz)
7. [Bundle bauen](#7-bundle-bauen)
8. [Fehlersuche](#8-fehlersuche)
9. [Betrieb und Wartung](#9-betrieb-und-wartung)
10. [Verzeichnisaufbau](#10-verzeichnisaufbau)

---

## 1. Wie es funktioniert

Zwei getrennte Vorgänge, die nie gleichzeitig laufen müssen:

```
IM NORMALBETRIEB (täglich, unbeaufsichtigt)

   Produktive NetBox                    Notfallnotebook
   ┌───────────────┐                    ┌────────────────────────┐
   │ netbox.…      │  REST-API (HTTPS)  │ Taskplaner 17:00 Uhr   │
   │ ~120 Endpunkte│ ─────────────────► │ Sync-NetBoxExport      │
   └───────────────┘   nur lesend       │        ↓               │
                                        │ C:\Sync-Daten\…        │
                                        │   Monday.zip … Sunday  │
                                        └────────────────────────┘

IM STÖRFALL (per Doppelklick)

   ┌────────────────────────────────────────────────────────────┐
   │  Desktop-Symbol "NetBox Local"                             │
   │        ↓                                                   │
   │  PostgreSQL + Garnet + Webserver starten                   │
   │        ↓                                                   │
   │  neuesten Export einspielen (ersetzt den alten Stand)      │
   │        ↓                                                   │
   │  Browser öffnet http://127.0.0.1:8001/                     │
   └────────────────────────────────────────────────────────────┘
```

Der Export läuft also, **solange alles gesund ist**. Im Störfall wird nur noch
das eingespielt, was bereits lokal liegt.

### Die Bestandteile

| Komponente | Version | Aufgabe |
|---|---|---|
| NetBox | 4.5.9 | die Anwendung selbst |
| PostgreSQL | 17.5 | Datenbank, im Benutzerprofil |
| Microsoft Garnet | 2.1.4 | Redis-Ersatz (NetBox startet ohne nicht) |
| .NET Runtime | 10.0.11 | wird von Garnet benötigt |
| Python | 3.13.15 embeddable | kein Installer, kein Admin |
| waitress | 3.0.2 | Webserver (gunicorn läuft nicht auf Windows) |
| WhiteNoise | 6.12.0 | liefert CSS und JavaScript aus |

Alle Dienste lauschen ausschließlich auf `127.0.0.1`. Es gibt keinen Zugriff
von außen und keine Firewall-Ausnahme.

---

## 2. Tägliche Verwendung

### Starten

Doppelklick auf **NetBox Local** auf dem Desktop.

Es öffnet sich ein Konsolenfenster, das den Fortschritt zeigt:

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

Der Browser öffnet sich automatisch. **Das Fenster darf geschlossen werden** —
NetBox Local läuft weiter. Der erste Start dauert länger (Datenbank wird
angelegt), danach etwa zwei bis vier Minuten.

### Anmelden

Benutzername und Passwort stehen im Konsolenfenster und zusätzlich in:

```
%LOCALAPPDATA%\NetBoxLocal\secrets\admin-password.txt
```

### Beenden

`src\launcher\Stop-NetBoxLocal.cmd` — oder `Strg+C` im Startfenster, falls es
noch offen ist.

Dabei wird PostgreSQL geordnet heruntergefahren (`PostgreSQL shut down
cleanly`). Das ist kein Schönheitsdetail: Ein hart beendeter Datenbankdienst
muss beim nächsten Start erst seine Konsistenz wiederherstellen, was den Start
spürbar verzögert — ausgerechnet in dem Moment, in dem es schnell gehen soll.

Wird das Fenster nur weggeklickt, laufen PostgreSQL und Garnet weiter. Das ist
unkritisch; der nächste Start erkennt das und nutzt sie weiter.

### Wichtig zu wissen

> **Jeder Start ersetzt den kompletten Datenbestand.**
> Was in der produktiven NetBox gelöscht wurde, verschwindet auch hier. Lokal
> vorgenommene Änderungen gehen beim nächsten Start verloren — die Instanz ist
> eine Kopie, keine eigene Datenhaltung.

> **Achte auf das Datum des Datenstandes.**
> Ist er älter als acht Tage, erscheint ein rot umrandeter Warnblock. Das heißt
> fast immer: Die tägliche Synchronisation läuft nicht mehr.

---

## 3. Einrichtung eines Notebooks

### Voraussetzungen

- Windows 10 oder 11, 64 Bit
- ca. 2 GB freier Plattenplatz
- Adminrechte werden **nicht** benötigt
- Netzzugang zur produktiven NetBox — nur für den täglichen Export

### Schritt 1 — Installieren

Empfohlen ist das fertige Installationspaket:

```
dist\installer\NetBox Local 1.0.0.msi
```

Doppelklick genügt. **Es sind keine Adminrechte nötig** — installiert wird nach
`%LOCALAPPDATA%\Programs\NetBox Local`. Desktop-Symbol und Startmenü-Einträge
legt der Installer selbst an.

Für die unbeaufsichtigte Verteilung über eine Softwareverwaltung:

```powershell
msiexec /i "NetBox Local 1.0.0.msi" /qn /l*v install.log
```

Deinstallieren über *Einstellungen → Apps* oder:

```powershell
msiexec /x "NetBox Local 1.0.0.msi" /qn
```

Dabei bleiben Datenbank und Zugangsdaten unter `%LOCALAPPDATA%\NetBoxLocal`
erhalten — eine Neuinstallation findet den vorherigen Stand wieder. Wer restlos
aufräumen will, löscht dieses Verzeichnis von Hand.

> Das Paket ist derzeit **nicht signiert**. Windows SmartScreen warnt deshalb
> beim ersten Start. Mit einem Firmen-Codesigning-Zertifikat lässt sich das
> beheben:
> ```powershell
> signtool sign /f zertifikat.pfx /p PASSWORT /fd SHA256 /t http://timestamp.digicert.com "NetBox Local 1.0.0.msi"
> ```

**Alternative ohne Installer:** Das Verzeichnis `NetBox Local - Final` einfach
auf das Notebook kopieren und `src\launcher\Install-DesktopShortcut.ps1`
einmal ausführen. Funktional gleichwertig, nur ohne Eintrag in *Programme und
Features*.

### Schritt 2 — Konfiguration anpassen

`config\NetBoxLocal.json` öffnen und mindestens prüfen:

```jsonc
"webUser": { "username": "admin", "password": "", "readOnly": true },
"import":  { "syncRoot": "C:\\Sync-Daten\\NetBoxLocal" }
```

Siehe [Konfiguration](#4-konfiguration).

### Schritt 3 — Export einrichten

`src\export\Sync-NetBoxExport.ps1` öffnen und oben eintragen:

```powershell
$NetBoxServer = "https://netbox.example.de/"
$APIKey       = "<Token mit ausschliesslich Leserechten>"
```

> **Der Token darf keine Schreibrechte haben.** In NetBox unter
> *Admin → API Tokens* das Häkchen bei *Write enabled* entfernen. Ein Notebook
> kann verloren gehen; ein schreibfähiger Token darin wäre ein Vollzugriff auf
> eure produktive NetBox.

Danach den Taskplaner-Eintrag anlegen:

```powershell
cd C:\NetBoxLocal\src\export
.\Register-SyncTask.ps1 -Uhrzeit "17:00"
```

Bei mehreren Notebooks die Zeiten staffeln (17:00, 17:15, 17:30 …), damit sie
den Server nicht gleichzeitig belasten.

Einmal testen:

```powershell
Start-ScheduledTask -TaskName "NetBox-Gesamtexport"
```

Danach `C:\Sync-Daten\NetBoxLocal` prüfen — dort muss ein Wochentags-Archiv
liegen, etwa `Monday.zip`.

### Schritt 4 — Desktop-Symbol anlegen

```powershell
cd C:\NetBoxLocal\src\launcher
.\Install-DesktopShortcut.ps1
```

Für alle Benutzer des Geräts (erfordert Adminrechte):

```powershell
.\Install-DesktopShortcut.ps1 -AllUsers
```

### Schritt 5 — Erstlauf

Doppelklick auf das neue Symbol. Der erste Start legt die Datenbank an und
dauert einige Minuten.

---

## 4. Konfiguration

Alles Einstellbare steht in **`config\NetBoxLocal.json`**. Änderungen wirken
beim nächsten Start.

### `webUser` — Anmeldung

```jsonc
"webUser": {
  "username": "admin",
  "password": "",
  "readOnly": true
}
```

| Feld | Bedeutung |
|---|---|
| `username` | Anmeldename an der Oberfläche |
| `password` | Leer = beim ersten Start wird eines erzeugt und in `secrets\admin-password.txt` abgelegt. Eingetragen = wird bei jedem Start durchgesetzt, praktisch für ein einheitliches Passwort auf allen Notebooks |
| `readOnly` | `true` = der Benutzer erhält nur Leserechte. NetBox blendet dann sämtliche Bearbeiten-Schaltflächen aus; die Oberfläche sieht sonst identisch aus |

**`readOnly` steht ab Werk auf `true`.** Ohne diese Einstellung kann jemand im
Störfall Einträge ändern, die beim nächsten Start kommentarlos verschwinden —
und solange sie sichtbar sind, hält man sie womöglich für echt.

Der Modus wurde gegen die laufende Instanz geprüft. Mit `readOnly: true` gilt:

| Zugriff | Ergebnis |
|---|---|
| Seiten und Listen lesen | erlaubt |
| Bearbeiten- und Löschen-Schaltflächen | erscheinen nicht in der Oberfläche |
| Bearbeiten-Formular direkt aufrufen | 403 |
| Änderung oder Löschung absenden | 403 |
| Schreiben über die REST-API | 403 |

Umgesetzt ist das über einen Benutzer ohne Superuser-Recht, der einer Gruppe
mit ausschließlich `view`-Berechtigung auf alle Objekttypen angehört. Ein
Superuser würde jede Rechteprüfung umgehen — deshalb genügt es nicht, nur die
Schaltflächen auszublenden.

Zum Umschalten den Wert ändern und neu starten; der Zugang wird bei jedem Start
entsprechend angepasst.

### `import` — Datenquelle

```jsonc
"import": {
  "syncRoot": "C:\\Sync-Daten\\NetBoxLocal",
  "autoImportOnStart": true,
  "maxAgeWarningDays": 8
}
```

| Feld | Bedeutung |
|---|---|
| `syncRoot` | Ablage der Wochentags-Archive des Exports |
| `autoImportOnStart` | `false` = beim Start nichts einspielen, nur öffnen |
| `maxAgeWarningDays` | Ab diesem Alter erscheint die auffällige Warnung |

### `ports` — Netzwerkports

```jsonc
"ports": { "postgres": 55432, "garnet": 56379, "web": 8001 }
```

Nur ändern, wenn eine andere Anwendung diese Ports belegt. Alle sind auf
`127.0.0.1` beschränkt.

### `paths` und `browser`

```jsonc
"paths":   { "dataRoot": "" },
"browser": { "openOnStart": true }
```

`dataRoot` leer lassen für `%LOCALAPPDATA%\NetBoxLocal`. Dort liegen Datenbank,
Protokolle und Zugangsdaten.

---

## 5. Der Export von NetBox

`src\export\Sync-NetBoxExport.ps1`, ausgeführt vom Windows-Taskplaner.

### Was er tut

1. Ermittelt zur Laufzeit alle Listen-Endpunkte der API — so werden nach einem
   NetBox-Upgrade auch neue Modelle erfasst
2. Ruft jeden Endpunkt seitenweise ab (Ordnung nach ID, damit Änderungen während
   des Laufs keine Datensätze verschieben)
3. Schreibt je Endpunkt eine JSON- und eine CSV-Datei
4. Erzeugt `manifest.json` mit Zeitstempel, NetBox-Version, Objektzahlen und
   fehlgeschlagenen Endpunkten
5. Bildet SHA256-Prüfsummen
6. Packt alles nach `<Wochentag>.zip` — dadurch bleiben sieben Tage erhalten
7. Meldet Erfolg an die Überwachung, **nur bei vollständigem Lauf**

### Bewusst ausgeschlossene Endpunkte

21 Endpunkte werden nie exportiert; die Begründung steht jeweils im Skript:

| Endpunkt | Grund |
|---|---|
| `users/tokens` | enthält API-Tokens im Klartext |
| `users/users`, `users/groups`, `users/permissions` | Zugriffssteuerung, personenbezogen |
| `core/object-changes` | vollständiges Changelog, oft Millionen Zeilen |
| `core/data-files` | enthält Dateiinhalte |
| diverse benutzerbezogene | Lesezeichen, Filter, Benachrichtigungen |

### Ergebnis prüfen

`status.txt` im Zielverzeichnis zeigt pro Wochentag eine Zeile:

```
Monday: 2026.08.17 17:00:12 - ERFOLGREICH (12173 Objekte, Datei: Monday.zip)
```

Im Archiv steht in `manifest.json`:

```jsonc
{
  "status": "complete",          // oder "partial"
  "exportTime": "2026-08-17T17:00:12.1234567+02:00",
  "netBoxVersion": "4.5.9",
  "endpointsExported": 126,
  "failedEndpoints": { },
  "objectCounts": { "dcim_devices": 1044 }
}
```

`status: partial` bedeutet, dass einzelne Endpunkte fehlgeschlagen sind — meist
wegen fehlender Leserechte des Tokens. Die Namen stehen unter `failedEndpoints`.

---

## 6. Der Import in die lokale Instanz

Läuft normalerweise automatisch beim Start. Manuell:

```
src\import\Import-NetBoxExport.cmd
```

Ohne Argument wird der neueste Export genommen. Alternativ einen Exportordner
auf die Datei ziehen oder angeben:

```
Import-NetBoxExport.cmd "D:\Pfad\zum\Monday"
```

Nur analysieren, ohne zu schreiben:

```powershell
cd dist\bundle\netbox\netbox
..\..\python\python.exe ..\..\..\..\src\import\Import-NetBoxExport.py "D:\Pfad" --dry-run
```

### Ablauf

Der gesamte Import läuft in **einer Transaktion**. Schlägt etwas fehl, bleibt
der bisherige Stand vollständig erhalten.

1. Version aus `manifest.json` gegen die lokale NetBox prüfen — bei Abweichung
   in der Minor-Version wird abgebrochen
2. Alle Objekte löschen
3. Datensätze einfügen, **unter Beibehaltung der ursprünglichen IDs**
4. Verweise auf nicht importierte Objekte bereinigen
5. Primärschlüssel-Sequenzen zurücksetzen
6. MPTT-Bäume, Kabelpfade und Suchindex neu aufbauen

### Was nicht importiert wird

| Objekt | Grund |
|---|---|
| Objekttypen (`core.ObjectType`) | von Django verwaltet, IDs sind je Installation verschieden |
| Benutzer, Gruppen, Eigentümerschaft | nicht im Export enthalten |
| Bilddateien | nur die Metadaten sind im Export, nicht die Dateien selbst |
| Plugin-Objekte (z. B. Slurpit) | das Plugin ist lokal nicht installiert |

### Rückgabewerte

| Code | Bedeutung |
|---|---|
| 0 | erfolgreich |
| 1 | Exportverzeichnis nicht gefunden |
| 2 | Versionskonflikt zwischen Export und lokaler NetBox |
| 3 | Import fehlgeschlagen, Datenbank unverändert |

---

## 7. Bundle bauen

Nur nötig, wenn `dist\bundle` fehlt oder die NetBox-Version gewechselt werden
soll. Braucht Internetzugang, etwa 400 MB Download und ca. 4 GB freien Platz.

```powershell
cd C:\NetBoxLocal
.\build\fetch-components.ps1 -PinHashes    # Komponenten laden und Hashes festschreiben
.\build\build-bundle.ps1                   # Bundle zusammensetzen
```

Eine laufende Instanz wird vom Build selbst beendet, bevor `dist\bundle` neu
aufgebaut wird — offene Dateien blockieren den Neuaufbau sonst mittendrin.

### NetBox-Version wechseln

Die lokale Version **muss** zur produktiven passen. Der Importer bricht sonst ab.

In `build\components.json` anpassen:

```jsonc
"netboxVersion": "4.5.9",
{ "name": "netbox", "version": "4.5.9",
  "url": "https://github.com/netbox-community/netbox/archive/refs/tags/v4.5.9.tar.gz",
  "sha256": "" }
```

`sha256` leeren, damit der neue Hash beim nächsten Lauf ermittelt wird. Danach
beide Build-Schritte erneut ausführen und die Datenbank einmal frisch anlegen:

```powershell
.\src\launcher\Start-NetBoxServices.ps1 -Init -NoServe
```

> `-Init` löscht die lokale Datenbank samt Zugangsdaten. Beim nächsten regulären
> Start wird beides neu erzeugt.

Die eingesetzte Version steht in `manifest.json` unter `netBoxVersion`.

---

## 8. Fehlersuche

Protokolle liegen in `%LOCALAPPDATA%\NetBoxLocal\logs`.

### „Port 55432 is already in use"

Eine frühere Instanz läuft noch.

```
src\launcher\Stop-NetBoxLocal.cmd
```

Der Start bricht hier bewusst ab: Würde er sich mit dem fremden Port verbinden,
läse er unbemerkt aus einer anderen Datenbank.

### Der Start hängt bei „PostgreSQL: start"

Nach unsauberem Herunterfahren — etwa leerer Akku — stellt PostgreSQL zuerst
seine Konsistenz wieder her. Der Start wartet bis zu fünf Minuten und meldet
`Database is recovering from an unclean shutdown`. Einfach abwarten.

### „Static Media Failure" im Browser

`whitenoise` fehlt im Bundle:

```powershell
dist\bundle\python\python.exe -m pip install whitenoise==6.12.0
```

Dauerhaft behebt das ein erneuter `build-bundle.ps1`-Lauf.

### „ERROR: version mismatch"

Export und lokale NetBox unterscheiden sich in der Minor-Version. Siehe
[NetBox-Version wechseln](#netbox-version-wechseln). Der Abbruch ist Absicht:
Zwischen Minor-Versionen unterscheiden sich Felder, ein Import würde
stillschweigend Daten verlieren.

### Export meldet `status: partial`

Einzelne Endpunkte antworten mit **403** — der API-Token darf sie nicht lesen.
Die Namen stehen in `manifest.json` unter `failedEndpoints`. In NetBox unter
*Admin → Permissions* die Leserechte des Token-Benutzers erweitern.

### Datenstand ist zu alt

Prüfen, ob der Taskplaner-Eintrag läuft:

```powershell
Get-ScheduledTask -TaskName "NetBox-Gesamtexport" | Get-ScheduledTaskInfo
```

Dann `status.txt` und das Dienstprotokoll in
`C:\Sync-Skripte\Sync-NetBoxExport` ansehen.

### Das Konsolenfenster schließt sich sofort

Immer die `.cmd`-Dateien verwenden, nicht die `.ps1` direkt. Die `.cmd`-Variante
hält das Fenster offen, damit Meldungen lesbar bleiben.

### Änderungen sind trotz `readOnly: true` möglich

Der Zugang wird bei jedem Start neu gesetzt. Prüfen, ob wirklich `true` in
`config\NetBoxLocal.json` steht und ob der Start
`User 'admin' updated (read-only)` meldet. Ein zuvor als Superuser angelegtes
Konto wird dabei automatisch herabgestuft.

Wichtig: Die Sperre gilt für die Weboberfläche und die REST-API. Wer direkten
Zugriff auf die PostgreSQL-Datenbank hat, kann sie umgehen — das ist bewusst so,
weil genau dieser Weg für den Import gebraucht wird.

---

## 9. Betrieb und Wartung

### Regelmäßig prüfen

| Was | Wie oft | Wo |
|---|---|---|
| Läuft der Export? | wöchentlich | `status.txt`, Überwachung |
| Ist `status` gleich `complete`? | wöchentlich | `manifest.json` |
| Passt die NetBox-Version noch? | nach jedem Upgrade | `manifest.json` gegen `components.json` |
| Startet und öffnet die Instanz? | vierteljährlich | Probelauf auf einem Notebook |

Der wahrscheinlichste Ausfall ist ein **stiller Stillstand der
Synchronisation**: Es funktioniert monatelang, bricht unbemerkt ab, und im
Störfall schaut jemand auf veraltete Daten. Deshalb meldet der Export nur bei
`complete` an die Überwachung, und der Start warnt bei altem Datenstand.

### Nach einem NetBox-Upgrade

1. Neue Version in `components.json` eintragen, `sha256` leeren
2. `fetch-components.ps1 -PinHashes` und `build-bundle.ps1`
3. `Start-NetBoxServices.ps1 -Init -NoServe`
4. Probelauf mit einem aktuellen Export
5. Bundle auf die Notebooks verteilen

### Sicherheit

- Der API-Token muss ausschließlich Leserechte haben
- Der Export enthält keine Tokens, Benutzer oder Passwort-Hashes
- Die Notebooks sollten mit BitLocker verschlüsselt sein — der Export enthält
  die vollständige Netzdokumentation
- Alle lokalen Dienste sind auf `127.0.0.1` beschränkt

### Lizenzen

NetBox steht unter Apache 2.0, Garnet und die .NET-Runtime unter MIT,
PostgreSQL unter der PostgreSQL-Lizenz, Python unter PSF-2.0. Eine Übersicht
liegt in `dist\bundle\LICENSES\COMPONENTS.txt`. Die Weitergabe innerhalb des
Unternehmens ist damit abgedeckt.

---

## 10. Verzeichnisaufbau

```
NetBoxLocal\
├─ assets\
│  └─ netbox-local.ico            Symbol der Desktop-Verknüpfung
├─ build\
│  ├─ components.json             gepinnte Komponenten samt SHA256
│  ├─ fetch-components.ps1        Download und Entpacken
│  └─ build-bundle.ps1            Zusammenbau nach dist\bundle
├─ config\
│  └─ NetBoxLocal.json            ► einzige Konfigurationsdatei
├─ dist\bundle\                   das lauffähige Bundle (~600 MB)
│  ├─ python\  netbox\  pgsql\  garnet\  dotnet\
├─ src\
│  ├─ export\
│  │  ├─ Sync-NetBoxExport.ps1  Abruf der API, täglich per Taskplaner
│  │  └─ Register-SyncTask.ps1    richtet den Taskplaner-Eintrag ein
│  ├─ import\
│  │  ├─ Import-NetBoxExport.py   der eigentliche Import
│  │  └─ Import-NetBoxExport.cmd  ► Import per Doppelklick
│  └─ launcher\
│     ├─ NetBoxLocal.cmd          ► Ziel der Desktop-Verknüpfung
│     ├─ Start-NetBoxLocal.ps1    starten, einspielen, öffnen
│     ├─ Start-NetBoxServices.ps1    nur die Dienste
│     ├─ Stop-NetBoxLocal.cmd     ► beenden
│     ├─ Install-DesktopShortcut.ps1
│     ├─ netboxlocal_wsgi.py      WSGI mit Auslieferung statischer Dateien
│     └─ ensure_user.py           legt den Anmeldezugang an
├─ PLAN.md                        Projektplan mit Phasen und Risiken
├─ PHASE0-RESULTS.md              Ergebnisse der Machbarkeitsprüfung
├─ README_de.md                   dieses Dokument
└─ README_en.md                   englische Fassung
```

Veränderliche Daten liegen außerhalb des Projekts:

```
%LOCALAPPDATA%\NetBoxLocal\
├─ pgdata\      PostgreSQL-Datenbank
├─ logs\        Protokolle
└─ secrets\     Passwörter, automatisch erzeugt

C:\Sync-Daten\NetBoxLocal\
├─ Monday.zip … Sunday.zip        sieben Tage Rotation
└─ status.txt                     Ergebnis je Wochentag
```
