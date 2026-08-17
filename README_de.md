# NetBox Local

*English version: [README_en.md](README_en.md)* · *Schnelleinstieg: [QUICKSTART.md](QUICKSTART.md)*

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

Der Browser öffnet sich automatisch. Das Fenster bleibt als Bedienkonsole offen (siehe *Beenden*). Der erste Start dauert länger (Datenbank wird
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

Das Startfenster bleibt als kleine Konsole offen und kennt vier Befehle:
`/stop` (herunterfahren), `/open` (Oberfläche öffnen), `/status` (laufende
Dienste) und `/exit` (Fenster schliessen, NetBox Local weiterlaufen lassen).

Wird das Fenster einfach weggeklickt, laufen PostgreSQL und Garnet weiter. Das
ist unkritisch; der nächste Start erkennt das und nutzt sie weiter.

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
dist\installer\NetBox Local 1.5.0.msi
```

Doppelklick genügt. **Es sind keine Adminrechte nötig** — installiert wird nach
`%LOCALAPPDATA%\Programs\NetBox Local`. Desktop-Symbol und Startmenü-Einträge
legt der Installer selbst an.

Für die unbeaufsichtigte Verteilung über eine Softwareverwaltung:

```powershell
msiexec /i "NetBox Local 1.5.0.msi" /qn /l*v install.log
```

Deinstallieren über *Einstellungen → Apps* oder:

```powershell
msiexec /x "NetBox Local 1.5.0.msi" /qn
```

Dabei bleiben Datenbank und Zugangsdaten unter `%LOCALAPPDATA%\NetBoxLocal`
erhalten — eine Neuinstallation findet den vorherigen Stand wieder. Wer restlos
aufräumen will, löscht dieses Verzeichnis von Hand.

> Das Paket ist derzeit **nicht signiert**. Windows SmartScreen warnt deshalb
> beim ersten Start. Mit einem Firmen-Codesigning-Zertifikat lässt sich das
> beheben:
> ```powershell
> signtool sign /f zertifikat.pfx /p PASSWORT /fd SHA256 /t http://timestamp.digicert.com "NetBox Local 1.5.0.msi"
> ```

**Alternative ohne Installer:** Das Verzeichnis `NetBox Local - Final` einfach
auf das Notebook kopieren und `src\launcher\Install-DesktopShortcut.ps1`
einmal ausführen. Funktional gleichwertig, nur ohne Eintrag in *Programme und
Features*.

### Schritt 2 — Konfiguration anpassen

`config\NetBoxLocal.json` öffnen und mindestens prüfen:

```jsonc
"webUser": { "mode": "readonly", "username": "admin", "password": "" },
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

Danach den Taskplaner-Eintrag anlegen (bei der Installation über die `.msi`
geschieht das bereits automatisch mit den dort gewählten Tagen und Zeiten):

```powershell
cd C:\NetBoxLocal\src\export
.\Register-SyncTask.ps1 -Time "17:00"                # täglich
.\Register-SyncTask.ps1 -Days weekdays -Time "07:45" # Mo–Fr
.\Register-SyncTask.ps1 -Days weekly -Time "23:00"   # nur montags
```

Diese Aufgabe läuft **eigenständig** — NetBox Local muss dafür nie gestartet
sein. Genau darauf kommt es an: Im Störungsfall ist die produktive NetBox nicht
mehr erreichbar, die Daten müssen also vorher geholt worden sein.

Bei mehreren Notebooks die Zeiten staffeln (17:00, 17:15, 17:30 …), damit sie
den Server nicht gleichzeitig belasten.

Einmal testen:

```powershell
Start-ScheduledTask -TaskName "NetBox Local export"
.\Register-SyncTask.ps1 -Status
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
  "mode": "readonly",
  "username": "admin",
  "password": "",
  "readOnlyUsername": "viewer",
  "readOnlyPassword": ""
}
```

| Feld | Bedeutung |
|---|---|
| `mode` | `readonly`, `superuser` oder `both` — siehe Tabelle unten |
| `username` | Anmeldename des Hauptkontos |
| `password` | Leer = beim ersten Start wird eines erzeugt und in `secretsadmin-password.txt` abgelegt. Eingetragen = wird bei jedem Start durchgesetzt |
| `readOnlyUsername` | zweites Konto, nur bei `mode: both` |
| `readOnlyPassword` | dessen Kennwort |

Die drei Modi:

| `mode` | Wirkung |
|---|---|
| `readonly` | Ein Konto mit reinen Leserechten. NetBox blendet alle Bearbeiten-Schaltflächen aus. **Vorgabe**, empfohlen für Notfallnotebooks |
| `superuser` | Ein Konto mit Vollzugriff. Für NetBox Local als eigenständige lokale NetBox, ohne Docker oder VM |
| `both` | Beide Konten nebeneinander |

`readonly` ist die Vorgabe. Ohne sie kann jemand im Störfall Einträge ändern,
die beim nächsten Start kommentarlos verschwinden — und solange sie sichtbar
sind, hält man sie womöglich für echt.

Der Modus wurde gegen die laufende Instanz geprüft. Mit `readonly` gilt:

| Zugriff | Ergebnis |
|---|---|
| Seiten und Listen lesen | erlaubt |
| Bearbeiten- und Löschen-Schaltflächen | erscheinen nicht |
| Bearbeiten-Formular direkt aufrufen | 403 |
| Änderung oder Löschung absenden | 403 |
| Schreiben über die REST-API | 403 |

Umgesetzt über ein Konto ohne Superuser-Recht in einer Gruppe mit
ausschließlich `view`-Berechtigung auf alle Objekttypen. Ein Superuser würde
jede Rechteprüfung umgehen — Schaltflächen auszublenden genügt nicht.

Zum Umschalten den Wert ändern und neu starten; die Konten werden bei jedem
Start entsprechend gesetzt.

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

Zuerst nachsehen, was der Taskplaner meldet:

```powershell
cd "$env:LOCALAPPDATA\Programs\NetBox Local\src\export"
.\Register-SyncTask.ps1 -Status
```

Die Ausgabe zeigt Zeitplan, Konto, letzten Lauf und dessen Ergebnis. `result 0`
heißt erfolgreich, alles andere nicht.

| Befund | Bedeutung |
|---|---|
| `No task 'NetBox Local export' is registered` | Es gibt keinen Zeitplan. Mit `.\Register-SyncTask.ps1` anlegen. |
| `Runs while you are signed in` | Der Task läuft nur bei angemeldetem Benutzer (siehe unten). |
| `Last run` liegt lange zurück | Das Gerät war zur geplanten Zeit aus. Der Lauf wird beim nächsten Einschalten nachgeholt. |
| `result` ist nicht 0 | Der Export selbst ist gescheitert — `status.txt` im Sync-Ordner lesen. |

`status.txt` enthält für jeden Wochentag eine Zeile mit Zeitstempel und
Ergebnis, etwa:

```
Monday: 2026.08.17 23:44:11 - ERROR: Export incomplete: 2 of 121 endpoints failed (extras_scripts, plugins_installed-plugins).
Tuesday: 2026.08.18 01:25:28 - ERROR: No NetBox API token is configured.
```

### Der Sync läuft nur, wenn ich angemeldet bin

Der Installer versucht zuerst, den Task als **S4U** anzulegen — dann läuft er
unabhängig davon, ob jemand angemeldet ist, und ohne dass ein Kennwort
gespeichert wird. S4U setzt das Recht *Als Stapelverarbeitungsauftrag anmelden*
voraus, das verwaltete Geräte nicht immer vergeben. Ist es nicht vorhanden,
weicht der Installer auf **Interactive** aus: der Task läuft nur bei
angemeldetem Benutzer, verpasste Läufe werden aber bei der nächsten Anmeldung
nachgeholt.

Für ein Notfallnotebook, an dem sich täglich jemand anmeldet, reicht das. Soll
der Export auch ohne Anmeldung laufen, gibt es zwei Wege:

```powershell
# Dienstkonto mit Kennwort (Kennwort geht nie über die Kommandozeile)
.\Register-SyncTask.ps1 -User "DOMAIN\svc-netboxsync"

# oder als SYSTEM - siehe Warnung
.\Register-SyncTask.ps1 -AsSystem
```

> **Zu `-AsSystem`:** der API-Token steht im Klartext in
> `Sync-NetBoxExport.ps1`. Läuft der Task als SYSTEM, ist die Datei für jeden
> lokalen Administrator lesbar. Nur mit einem reinen Lese-Token verwenden.

### Zeitplan ändern

Ohne Neuinstallation:

```powershell
cd "$env:LOCALAPPDATA\Programs\NetBox Local\src\export"
.\Register-SyncTask.ps1 -Days weekdays -Time "07:45"
```

`-Days` akzeptiert `daily`, `weekdays` (Mo–Fr) und `weekly` (nur montags). Das
Skript ersetzt den bestehenden Eintrag, statt einen zweiten daneben anzulegen —
zwei Aufgaben, die gleichzeitig Vollexporte ziehen, fallen niemandem auf, bis
der Server sich meldet.

Entfernen mit `.\Register-SyncTask.ps1 -Remove`. Danach wird der lokale
Datenstand nicht mehr automatisch aufgefrischt.

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
│  │  └─ Register-SyncTask.ps1    legt den Taskplaner-Eintrag an bzw. aendert ihn
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
