# Synchronisation des vollstaendigen NetBox-Bestandes
#
# Erweiterung: Ausweitung von 18 IPAM-Endpunkten auf den vollstaendigen
#              NetBox-Bestand (~120 Endpunkte), Endpunkt-Discovery zur
#              Laufzeit, Fehlertoleranz je Endpunkt.
#
# Runs unattended on emergency notebooks and pulls a complete read-only copy of
# NetBox into a rotating set of daily ZIP archives.
#
# Key differences from the IPAM-only predecessor:
#   - endpoints are discovered from the live API instead of being hard-coded,
#     so a NetBox upgrade that adds models does not silently skip them
#   - a failing endpoint no longer aborts the whole run; the manifest records
#     status 'partial' and names what failed
#   - security-sensitive and worthless endpoints are excluded by name, with the
#     reason spelled out next to each one

# ---------------------------------------------------------------------------
# Konfiguration
# ---------------------------------------------------------------------------

$NetBoxServer        = "https://netbox.example.com/"
$APIKey              = "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
$AuthorizationScheme = "Token"

$global:SkriptPath     = "C:\Sync-Skripte\Sync-NetBoxExport"
$ServiceLogFile        = "$global:SkriptPath\Sync-NetBoxExport_Service.log"
$global:LocalSyncPath  = "C:\Sync-Daten\NetBoxLocal"

$TimeoutSekunden = 300
$Seitengroesse   = 500
$MaxVersuche     = 3

$PushURL = ""

# Endpoints that must never end up in an export archive, and why. Emergency
# notebooks travel and get lost; anything in this list would turn a lost device
# into a NetBox compromise or would bloat the archive without helping anyone
# during an outage.
$AusgeschlosseneEndpunkte = [ordered]@{
    "api/users/tokens/"                = "SICHERHEIT: liefert API-Tokens im Klartext. Ein verlorenes Notebook waere damit ein Vollzugriff auf die produktive NetBox."
    "api/users/users/"                 = "SICHERHEIT: personenbezogene Benutzerdaten, im Stoerfall ohne Nutzen."
    "api/users/permissions/"           = "SICHERHEIT: Zugriffssteuerung der Produktivinstanz."
    "api/users/groups/"                = "SICHERHEIT: Zugriffssteuerung der Produktivinstanz."
    "api/users/config/"                = "Benutzerspezifische UI-Einstellungen, kein Bestandsdatum."

    "api/core/object-changes/"         = "VOLUMEN: vollstaendiges Changelog, haeufig Millionen Zeilen. Im Stoerfall wertlos."
    "api/core/jobs/"                   = "Laufzeitzustand der Hintergrundjobs, kein Bestandsdatum."
    "api/core/background-queues/"      = "Laufzeitzustand RQ."
    "api/core/background-tasks/"       = "Laufzeitzustand RQ."
    "api/core/background-workers/"     = "Laufzeitzustand RQ."
    "api/core/data-files/"             = "VOLUMEN: enthaelt Dateiinhalte synchronisierter Datenquellen."

    "api/extras/scripts/"              = "Skriptdefinitionen; antwortet ohne hinterlegte Dateien mit Fehlern."
    "api/extras/dashboard/"            = "Kein Listen-Endpunkt, liefert das Dashboard des aufrufenden Benutzers."
    "api/extras/notifications/"        = "Benutzerspezifisch."
    "api/extras/subscriptions/"        = "Benutzerspezifisch."
    "api/extras/bookmarks/"            = "Benutzerspezifisch."
    "api/extras/saved-filters/"        = "Benutzerspezifisch."
    "api/extras/table-configs/"        = "Benutzerspezifisch."

    "api/dcim/connected-device/"       = "Kein Listen-Endpunkt; erfordert die Parameter peer_device und peer_interface."
    "api/schema/redoc/"                = "HTML-Dokumentationsseite, kein JSON."
    "api/schema/swagger-ui/"           = "HTML-Dokumentationsseite, kein JSON."
}

# Query parameters applied per endpoint. NetBox renders config contexts into
# every device and virtual machine record, which multiplies the export size for
# data that is already exported once via extras/config-contexts.
$EndpunktParameter = [ordered]@{
    "api/dcim/devices/"                    = "exclude=config_context"
    "api/virtualization/virtual-machines/" = "exclude=config_context"
}

# Fallback list, used only when endpoint discovery fails. Mirrors the endpoints
# of NetBox 4.6.8 minus the exclusions above.
$FallbackEndpunkte = @(
    "api/circuits/circuit-group-assignments/", "api/circuits/circuit-groups/",
    "api/circuits/circuit-terminations/", "api/circuits/circuit-types/",
    "api/circuits/circuits/", "api/circuits/provider-accounts/",
    "api/circuits/provider-networks/", "api/circuits/providers/",
    "api/circuits/virtual-circuit-terminations/", "api/circuits/virtual-circuit-types/",
    "api/circuits/virtual-circuits/",
    "api/core/data-sources/", "api/core/object-types/",
    "api/dcim/cable-bundles/", "api/dcim/cable-terminations/", "api/dcim/cables/",
    "api/dcim/console-port-templates/", "api/dcim/console-ports/",
    "api/dcim/console-server-port-templates/", "api/dcim/console-server-ports/",
    "api/dcim/device-bay-templates/", "api/dcim/device-bays/", "api/dcim/device-roles/",
    "api/dcim/device-types/", "api/dcim/devices/", "api/dcim/front-port-templates/",
    "api/dcim/front-ports/", "api/dcim/interface-templates/", "api/dcim/interfaces/",
    "api/dcim/inventory-item-roles/", "api/dcim/inventory-item-templates/",
    "api/dcim/inventory-items/", "api/dcim/locations/", "api/dcim/mac-addresses/",
    "api/dcim/manufacturers/", "api/dcim/module-bay-templates/", "api/dcim/module-bays/",
    "api/dcim/module-type-profiles/", "api/dcim/module-types/", "api/dcim/modules/",
    "api/dcim/platforms/", "api/dcim/power-feeds/", "api/dcim/power-outlet-templates/",
    "api/dcim/power-outlets/", "api/dcim/power-panels/", "api/dcim/power-port-templates/",
    "api/dcim/power-ports/", "api/dcim/rack-groups/", "api/dcim/rack-reservations/",
    "api/dcim/rack-roles/", "api/dcim/rack-types/", "api/dcim/racks/",
    "api/dcim/rear-port-templates/", "api/dcim/rear-ports/", "api/dcim/regions/",
    "api/dcim/site-groups/", "api/dcim/sites/", "api/dcim/virtual-chassis/",
    "api/dcim/virtual-device-contexts/",
    "api/extras/config-context-profiles/", "api/extras/config-contexts/",
    "api/extras/config-templates/", "api/extras/custom-field-choice-sets/",
    "api/extras/custom-fields/", "api/extras/custom-links/", "api/extras/event-rules/",
    "api/extras/export-templates/", "api/extras/image-attachments/",
    "api/extras/journal-entries/", "api/extras/notification-groups/",
    "api/extras/tagged-objects/", "api/extras/tags/", "api/extras/webhooks/",
    "api/ipam/aggregates/", "api/ipam/asn-ranges/", "api/ipam/asns/",
    "api/ipam/fhrp-group-assignments/", "api/ipam/fhrp-groups/",
    "api/ipam/ip-addresses/", "api/ipam/ip-ranges/", "api/ipam/prefixes/",
    "api/ipam/rirs/", "api/ipam/roles/", "api/ipam/route-targets/",
    "api/ipam/service-templates/", "api/ipam/services/", "api/ipam/vlan-groups/",
    "api/ipam/vlan-translation-policies/", "api/ipam/vlan-translation-rules/",
    "api/ipam/vlans/", "api/ipam/vrfs/",
    "api/plugins/installed-plugins/",
    "api/tenancy/contact-assignments/", "api/tenancy/contact-groups/",
    "api/tenancy/contact-roles/", "api/tenancy/contacts/", "api/tenancy/tenant-groups/",
    "api/tenancy/tenants/",
    "api/users/owner-groups/", "api/users/owners/",
    "api/virtualization/cluster-groups/", "api/virtualization/cluster-types/",
    "api/virtualization/clusters/", "api/virtualization/interfaces/",
    "api/virtualization/virtual-disks/", "api/virtualization/virtual-machine-types/",
    "api/virtualization/virtual-machines/",
    "api/vpn/ike-policies/", "api/vpn/ike-proposals/", "api/vpn/ipsec-policies/",
    "api/vpn/ipsec-profiles/", "api/vpn/ipsec-proposals/", "api/vpn/l2vpn-terminations/",
    "api/vpn/l2vpns/", "api/vpn/tunnel-groups/", "api/vpn/tunnel-terminations/",
    "api/vpn/tunnels/",
    "api/wireless/wireless-lan-groups/", "api/wireless/wireless-lans/",
    "api/wireless/wireless-links/"
)

# ---------------------------------------------------------------------------
# Hilfsfunktionen
# ---------------------------------------------------------------------------

# Schreibt einen Eintrag in das Service-Log
Function Write-ServiceLog {
    Param (
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )

    $LogEintrag = (
        (Get-Date -Format "yyyy.MM.dd HH:mm:ss") +
        " [" + $Level + "] - " +
        $Message +
        " (" + $env:COMPUTERNAME + ")"
    )

    $LogEintrag |
        Out-File `
            -Append `
            -FilePath $ServiceLogFile `
            -Encoding utf8 `
            -Force

    Write-Host $LogEintrag
}

# Verbindet die NetBox-Basisadresse und den API-Pfad
Function Join-NetBoxURL {
    Param (
        [Parameter(Mandatory = $true)]
        [string]$BaseURL,

        [Parameter(Mandatory = $true)]
        [string]$APIPath
    )

    Return (
        $BaseURL.TrimEnd("/") +
        "/" +
        $APIPath.TrimStart("/")
    )
}

# Speichert Text als UTF-8 ohne BOM
Function Write-UTF8File {
    Param (
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content
    )

    $UTF8Encoding = New-Object System.Text.UTF8Encoding($false)

    [System.IO.File]::WriteAllText(
        $Path,
        $Content,
        $UTF8Encoding
    )
}

# Wandelt einen API-Pfad in einen Dateinamen um
# "api/dcim/device-roles/" wird zu "dcim_device-roles"
Function ConvertTo-Endpunktname {
    Param (
        [Parameter(Mandatory = $true)]
        [string]$APIPath
    )

    $Teile = $APIPath.Trim("/").Split("/")

    If ($Teile.Length -ge 3) {
        Return ($Teile[1] + "_" + $Teile[2])
    }

    Return ($Teile[-1])
}

# Ruft einen NetBox-Endpunkt mit Wiederholungsversuchen ab
Function Invoke-NetBoxGET {
    Param (
        [Parameter(Mandatory = $true)]
        [string]$URL,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    For ($Versuch = 1; $Versuch -le $MaxVersuche; $Versuch++) {
        Try {
            Return Invoke-RestMethod `
                -Uri $URL `
                -Method GET `
                -Headers $Headers `
                -TimeoutSec $TimeoutSekunden `
                -UseBasicParsing `
                -ErrorAction Stop
        }
        Catch {
            If ($Versuch -ge $MaxVersuche) {
                Throw
            }

            $Wartezeit = [Math]::Pow(2, $Versuch)

            Write-ServiceLog `
                -Level "WARN" `
                -Message (
                    "API-Aufruf fehlgeschlagen. Versuch " +
                    $Versuch + " von " + $MaxVersuche +
                    ". Neuer Versuch in " + $Wartezeit +
                    " Sekunden. URL: " + $URL +
                    ". Fehler: " + $_.Exception.Message
                )

            Start-Sleep -Seconds $Wartezeit
        }
    }
}

# Ermittelt die Listen-Endpunkte der angebundenen NetBox-Instanz
#
# Discovery beats a hard-coded list: a NetBox upgrade that introduces new models
# would otherwise be exported incompletely without anyone noticing. The root
# document lists the applications, each application document lists its models.
Function Get-NetBoxEndpunkte {
    Param (
        [Parameter(Mandatory = $true)]
        [string]$BaseURL,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    $Gefunden = New-Object System.Collections.ArrayList

    # Not every entry below /api/ is an application index. 'status' returns a
    # flat dictionary of version information, so treating its keys as model
    # names produces requests like api/status/django-version/ that 404.
    $KeineAnwendungen = @("status")

    $WurzelURL = Join-NetBoxURL -BaseURL $BaseURL -APIPath "api/"
    $Wurzel = Invoke-NetBoxGET -URL $WurzelURL -Headers $Headers

    ForEach ($App in $Wurzel.PSObject.Properties) {
        If ($KeineAnwendungen -contains $App.Name) { Continue }

        Try {
            $AppURL = Join-NetBoxURL -BaseURL $BaseURL -APIPath ("api/" + $App.Name + "/")
            $AppDokument = Invoke-NetBoxGET -URL $AppURL -Headers $Headers
        }
        Catch {
            Continue
        }

        If ($null -eq $AppDokument) { Continue }

        ForEach ($Modell in $AppDokument.PSObject.Properties) {
            # An application index maps model names to their absolute URLs. A
            # value that is not a URL means this is a data document rather than
            # an index, and its keys are not endpoints.
            $Wert = [string]$Modell.Value

            If (-not ($Wert -match '^https?://')) { Continue }

            $Pfad = "api/" + $App.Name + "/" + $Modell.Name + "/"
            [void]$Gefunden.Add($Pfad)
        }
    }

    Return $Gefunden.ToArray()
}

# Ruft alle Seiten eines NetBox-Listenendpunkts ab
Function Get-AllNetBoxObjects {
    Param (
        [Parameter(Mandatory = $true)]
        [string]$EndpointURL,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    If ($EndpointURL.Contains("?")) {
        $Trennzeichen = "&"
    }
    Else {
        $Trennzeichen = "?"
    }

    # Ordering by primary key makes pagination deterministic. Without it a
    # concurrent insert can shift rows between pages and silently duplicate or
    # skip records.
    $NextURL = (
        $EndpointURL +
        $Trennzeichen +
        "limit=" + $Seitengroesse +
        "&ordering=id"
    )

    $AlleObjekte = New-Object System.Collections.ArrayList
    $ErwarteteAnzahl = $null

    While (-not [string]::IsNullOrWhiteSpace($NextURL)) {
        $Antwort = Invoke-NetBoxGET `
            -URL $NextURL `
            -Headers $Headers

        If ($null -eq $Antwort) {
            Throw (
                "Der NetBox-Endpunkt '" + $NextURL +
                "' hat keine Antwort geliefert."
            )
        }

        If ($null -eq $Antwort.PSObject.Properties["results"]) {
            Throw (
                "Unerwartetes API-Format bei '" + $NextURL +
                "'. Die Eigenschaft 'results' fehlt."
            )
        }

        If ($null -eq $Antwort.PSObject.Properties["count"]) {
            Throw (
                "Unerwartetes API-Format bei '" + $NextURL +
                "'. Die Eigenschaft 'count' fehlt."
            )
        }

        If ($null -eq $ErwarteteAnzahl) {
            $ErwarteteAnzahl = [int64]$Antwort.count
        }

        ForEach ($Objekt in @($Antwort.results)) {
            [void]$AlleObjekte.Add($Objekt)
        }

        $NextURL = [string]$Antwort.next
    }

    If ($null -eq $ErwarteteAnzahl) {
        Throw (
            "Die Objektanzahl konnte fuer den Endpunkt '" +
            $EndpointURL + "' nicht ermittelt werden."
        )
    }

    # A mismatch used to abort the entire run. On a production NetBox that is
    # actively being edited during the export window this happens legitimately,
    # so it is now reported rather than fatal - the data is still usable, just
    # not a perfectly consistent snapshot.
    If ($AlleObjekte.Count -ne $ErwarteteAnzahl) {
        Write-ServiceLog `
            -Level "WARN" `
            -Message (
                "Objektanzahl weicht ab (Datenaenderung waehrend des Exports?). " +
                "Erwartet: " + $ErwarteteAnzahl +
                "; erhalten: " + $AlleObjekte.Count +
                "; Endpunkt: " + $EndpointURL
            )
    }

    Return $AlleObjekte.ToArray()
}

# Bereitet verschachtelte NetBox-Objekte fuer den CSV-Export auf
#
# Nested objects are serialised as compact JSON inside the cell. Note that the
# resulting CSV is a human-readable view, NOT something NetBox can import again:
# a cell containing {"value":"active","label":"Active"} is rejected by NetBox's
# own bulk import, which expects the slug 'active'.
Function ConvertTo-NetBoxCSVObject {
    Param (
        [Parameter(Mandatory = $true)]
        [object[]]$InputObjects
    )

    ForEach ($Objekt in $InputObjects) {
        $CSVZeile = [ordered]@{}

        ForEach ($Eigenschaft in $Objekt.PSObject.Properties) {
            $Wert = $Eigenschaft.Value

            If ($null -eq $Wert) {
                $CSVZeile[$Eigenschaft.Name] = $null
            }
            ElseIf (
                ($Wert -is [string]) -or
                ($Wert -is [ValueType])
            ) {
                $CSVZeile[$Eigenschaft.Name] = $Wert
            }
            Else {
                $CSVZeile[$Eigenschaft.Name] = (
                    $Wert |
                        ConvertTo-Json `
                            -Depth 30 `
                            -Compress
                )
            }
        }

        [PSCustomObject]$CSVZeile
    }
}

# Ermittelt den englischen Wochentagsnamen (kulturunabhaengig)
Function Get-NetBoxWochentag {
    Return (
        (Get-Date).ToString(
            "dddd",
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    )
}

# Ermittelt den Dateinamen fuer den Wochentags-Rotationsslot
Function Get-NetBoxRotationDateiname {
    Return (Get-NetBoxWochentag) + ".zip"
}

# Aktualisiert die menschenlesbare Statuszeile eines Wochentags in status.txt
Function Update-NetBoxStatusDatei {
    Param (
        [Parameter(Mandatory = $true)]
        [string]$Wochentag,

        [Parameter(Mandatory = $true)]
        [string]$Statuszeile
    )

    $StatusPfad = Join-Path $global:LocalSyncPath "status.txt"

    $WochentageReihenfolge = @(
        "Monday", "Tuesday", "Wednesday", "Thursday",
        "Friday", "Saturday", "Sunday"
    )

    $Eintraege = [ordered]@{}

    ForEach ($Tag in $WochentageReihenfolge) {
        $Eintraege[$Tag] = $null
    }

    If (Test-Path -Path $StatusPfad) {
        ForEach ($Zeile in (Get-Content -Path $StatusPfad -Encoding UTF8)) {
            If ($Zeile -match '^(\w+):\s?(.*)$') {
                $Tag = $Matches[1]

                If ($Eintraege.Contains($Tag)) {
                    $Eintraege[$Tag] = $Matches[2]
                }
            }
        }
    }

    $Eintraege[$Wochentag] = $Statuszeile

    $Zeilen = ForEach ($Tag in $WochentageReihenfolge) {
        If ($null -ne $Eintraege[$Tag]) {
            $Tag + ": " + $Eintraege[$Tag]
        }
    }

    Write-UTF8File `
        -Path $StatusPfad `
        -Content ($Zeilen -join "`r`n")
}

# Packt das Staging-Verzeichnis und veroeffentlicht es als Rotationsslot
Function Publish-NetBoxExport {
    Param (
        [Parameter(Mandatory = $true)]
        [string]$StagingPath,

        [Parameter(Mandatory = $true)]
        [string]$ZielVerzeichnis
    )

    $ZielDateiname = Get-NetBoxRotationDateiname
    $ZielPfad = Join-Path $ZielVerzeichnis $ZielDateiname

    $TempZipPfad = Join-Path `
        $ZielVerzeichnis `
        (
            "staging-" +
            [Guid]::NewGuid().ToString("N") +
            ".zip"
        )

    # Compress-Archive is limited to 2 GB and is slow on many small files. The
    # full export is considerably larger than the IPAM-only one, so ZipFile is
    # used directly.
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $StagingPath,
        $TempZipPfad,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $false
    )

    Move-Item `
        -Path $TempZipPfad `
        -Destination $ZielPfad `
        -Force `
        -ErrorAction Stop
}

# ---------------------------------------------------------------------------
# Hauptablauf
# ---------------------------------------------------------------------------

Function Invoke-NetBoxExport {
    $StagingPath = Join-Path `
        $global:LocalSyncPath `
        (
            "staging-" +
            [Guid]::NewGuid().ToString("N")
        )

    $JSONPath = Join-Path $StagingPath "JSON"
    $CSVPath  = Join-Path $StagingPath "CSV"

    Try {
        If ([string]::IsNullOrWhiteSpace($NetBoxServer)) {
            Throw "In der Konfiguration wurde kein NetBox-Server eingetragen."
        }

        If ([string]::IsNullOrWhiteSpace($APIKey) -or
            ($APIKey -eq "NETBOX-API-TOKEN-HIER-EINTRAGEN") -or
            ($APIKey -match '^X+$')
        ) {
            Throw "In der Konfiguration wurde kein NetBox-API-Token eingetragen."
        }

        $Headers = @{
            "Authorization" = ($AuthorizationScheme + " " + $APIKey)
            "Accept"        = "application/json"
            "User-Agent"    = ("Notfallnotebook-NetBoxComplete/" + $env:COMPUTERNAME)
        }

        New-Item -ItemType Directory -Path $JSONPath -Force | Out-Null
        New-Item -ItemType Directory -Path $CSVPath  -Force | Out-Null

        Write-ServiceLog -Message "NetBox-Gesamtexport gestartet."

        # --- Endpunkte ermitteln ---------------------------------------------

        $EndpunktQuelle = "discovery"

        Try {
            $Entdeckt = @(
                Get-NetBoxEndpunkte `
                    -BaseURL $NetBoxServer `
                    -Headers $Headers
            )

            If ($Entdeckt.Count -lt 50) {
                Throw (
                    "Endpunkt-Discovery lieferte nur " + $Entdeckt.Count +
                    " Eintraege; das ist unplausibel wenig."
                )
            }
        }
        Catch {
            Write-ServiceLog `
                -Level "WARN" `
                -Message (
                    "Endpunkt-Discovery fehlgeschlagen, verwende die statische " +
                    "Fallback-Liste. Neue NetBox-Modelle werden dadurch " +
                    "moeglicherweise nicht exportiert. Fehler: " +
                    $_.Exception.Message
                )

            $Entdeckt = $FallbackEndpunkte
            $EndpunktQuelle = "fallback"
        }

        $Endpunkte = New-Object System.Collections.ArrayList
        $Uebersprungen = New-Object System.Collections.ArrayList

        ForEach ($Pfad in ($Entdeckt | Sort-Object -Unique)) {
            If ($AusgeschlosseneEndpunkte.Contains($Pfad)) {
                [void]$Uebersprungen.Add($Pfad)
            }
            Else {
                [void]$Endpunkte.Add($Pfad)
            }
        }

        Write-ServiceLog `
            -Message (
                "Endpunkte ermittelt (" + $EndpunktQuelle + "): " +
                $Endpunkte.Count + " werden exportiert, " +
                $Uebersprungen.Count + " sind bewusst ausgeschlossen."
            )

        # Anything discovered that the fallback list does not know about is new
        # in this NetBox version and worth flagging.
        ForEach ($Pfad in $Endpunkte) {
            If ($FallbackEndpunkte -notcontains $Pfad) {
                Write-ServiceLog `
                    -Level "WARN" `
                    -Message (
                        "Neuer, bisher unbekannter Endpunkt gefunden: " + $Pfad +
                        ". Bitte pruefen, ob er sicherheitsrelevant ist."
                    )
            }
        }

        # --- Export ----------------------------------------------------------

        $ObjektAnzahlen       = [ordered]@{}
        $FehlerhafteEndpunkte = [ordered]@{}
        $ExportDateien        = New-Object System.Collections.ArrayList

        ForEach ($Pfad in $Endpunkte) {
            $Name = ConvertTo-Endpunktname -APIPath $Pfad

            $EndpointURL = Join-NetBoxURL `
                -BaseURL $NetBoxServer `
                -APIPath $Pfad

            If ($EndpunktParameter.Contains($Pfad)) {
                $EndpointURL = $EndpointURL + "?" + $EndpunktParameter[$Pfad]
            }

            # A single broken endpoint must not destroy the whole run. With
            # ~120 endpoints the odds of one failing are no longer negligible,
            # and a partial export still beats no export during an outage.
            Try {
                Write-ServiceLog -Message ("Exportiere '" + $Name + "'.")

                $Objekte = @(
                    Get-AllNetBoxObjects `
                        -EndpointURL $EndpointURL `
                        -Headers $Headers
                )

                $ObjektAnzahlen[$Name] = $Objekte.Count

                $JSONFile = Join-Path $JSONPath ($Name + ".json")
                $CSVFile  = Join-Path $CSVPath  ($Name + ".csv")

                $JSONInhalt = ConvertTo-Json `
                    -InputObject $Objekte `
                    -Depth 50

                Write-UTF8File -Path $JSONFile -Content $JSONInhalt

                If ($Objekte.Count -gt 0) {
                    ConvertTo-NetBoxCSVObject `
                        -InputObjects $Objekte |
                        Export-Csv `
                            -Path $CSVFile `
                            -NoTypeInformation `
                            -Encoding UTF8 `
                            -Delimiter ";"
                }
                Else {
                    Write-UTF8File -Path $CSVFile -Content ""
                }

                $null = (
                    Get-Content -Path $JSONFile -Raw |
                        ConvertFrom-Json -ErrorAction Stop
                )

                [void]$ExportDateien.Add($JSONFile)
                [void]$ExportDateien.Add($CSVFile)

                Write-ServiceLog `
                    -Message (
                        "'" + $Name + "' erfolgreich exportiert (" +
                        $Objekte.Count + " Objekte)."
                    )
            }
            Catch {
                $FehlerhafteEndpunkte[$Name] = $_.Exception.Message

                Write-ServiceLog `
                    -Level "ERROR" `
                    -Message (
                        "Endpunkt '" + $Name + "' fehlgeschlagen, der Export " +
                        "wird fortgesetzt. Fehler: " + $_.Exception.Message
                    )
            }
        }

        # --- Manifest --------------------------------------------------------

        $NetBoxVersion = $null

        Try {
            $StatusURL = Join-NetBoxURL `
                -BaseURL $NetBoxServer `
                -APIPath "api/status/"

            $NetBoxStatus = Invoke-NetBoxGET `
                -URL $StatusURL `
                -Headers $Headers

            If ($null -ne $NetBoxStatus.PSObject.Properties["netbox-version"]) {
                $NetBoxVersion = $NetBoxStatus."netbox-version"
            }
        }
        Catch {
            Write-ServiceLog `
                -Level "WARN" `
                -Message (
                    "NetBox-Version konnte nicht gelesen werden. " +
                    "Der Export wird trotzdem fortgesetzt."
                )
        }

        If ($FehlerhafteEndpunkte.Count -eq 0) {
            $Gesamtstatus = "complete"
        }
        Else {
            $Gesamtstatus = "partial"
        }

        $Manifest = [ordered]@{
            status            = $Gesamtstatus
            exportTime        = (Get-Date).ToString("o")
            computerName      = $env:COMPUTERNAME
            netBoxVersion     = $NetBoxVersion
            endpointSource    = $EndpunktQuelle
            endpointsExported = $Endpunkte.Count
            endpointsExcluded = @($Uebersprungen)
            failedEndpoints   = $FehlerhafteEndpunkte
            objectCounts      = $ObjektAnzahlen
        }

        $ManifestFile = Join-Path $StagingPath "manifest.json"

        Write-UTF8File `
            -Path $ManifestFile `
            -Content ($Manifest | ConvertTo-Json -Depth 20)

        [void]$ExportDateien.Add($ManifestFile)

        # --- Pruefsummen -----------------------------------------------------

        $Pruefsummen = ForEach ($Datei in $ExportDateien) {
            $Hash = Get-FileHash -Path $Datei -Algorithm SHA256

            $RelativerPfad = $Datei.Substring(
                $StagingPath.Length
            ).TrimStart([char]92)

            ($Hash.Hash.ToLowerInvariant() + " *" + $RelativerPfad)
        }

        Write-UTF8File `
            -Path (Join-Path $StagingPath "checksums.sha256") `
            -Content ($Pruefsummen -join "`r`n")

        # --- Veroeffentlichen ------------------------------------------------

        $ZielDateiname = Get-NetBoxRotationDateiname

        Publish-NetBoxExport `
            -StagingPath $StagingPath `
            -ZielVerzeichnis $global:LocalSyncPath

        Remove-Item `
            -Path $StagingPath `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue

        $GesamtObjektanzahl = (
            $ObjektAnzahlen.Values | Measure-Object -Sum
        ).Sum

        Write-ServiceLog `
            -Message (
                "NetBox-Gesamtexport abgeschlossen (Status: " + $Gesamtstatus +
                "). Archivdatei: " +
                (Join-Path $global:LocalSyncPath $ZielDateiname)
            )

        If ($Gesamtstatus -eq "complete") {
            $StatusText = " - ERFOLGREICH ("
        }
        Else {
            $StatusText = (
                " - TEILWEISE (" + $FehlerhafteEndpunkte.Count +
                " Endpunkte fehlgeschlagen, "
            )
        }

        Update-NetBoxStatusDatei `
            -Wochentag (Get-NetBoxWochentag) `
            -Statuszeile (
                (Get-Date -Format "yyyy.MM.dd HH:mm:ss") +
                $StatusText +
                $GesamtObjektanzahl +
                " Objekte, Datei: " + $ZielDateiname + ")"
            )

        # Monitoring is only pinged on a fully successful run. A partial export
        # must show up as a missed heartbeat, otherwise a slowly rotting export
        # stays green in the dashboard.
        If ((-not [string]::IsNullOrWhiteSpace($PushURL)) -and
            ($Gesamtstatus -eq "complete")
        ) {
            Try {
                Invoke-WebRequest `
                    -Uri $PushURL `
                    -Method GET `
                    -UseBasicParsing `
                    -TimeoutSec 30 `
                    -ErrorAction Stop |
                    Out-Null
            }
            Catch {
                Write-ServiceLog `
                    -Level "WARN" `
                    -Message (
                        "Export erfolgreich, Monitoring-Push fehlgeschlagen: " +
                        $_.Exception.Message
                    )
            }
        }

        If ($Gesamtstatus -ne "complete") {
            Throw (
                "Export unvollstaendig: " + $FehlerhafteEndpunkte.Count +
                " von " + $Endpunkte.Count + " Endpunkten fehlgeschlagen (" +
                (($FehlerhafteEndpunkte.Keys) -join ", ") + ")."
            )
        }
    }
    Catch {
        Write-ServiceLog `
            -Level "ERROR" `
            -Message ("NetBox-Gesamtexport fehlgeschlagen: " + $_.Exception.Message)

        Try {
            Update-NetBoxStatusDatei `
                -Wochentag (Get-NetBoxWochentag) `
                -Statuszeile (
                    (Get-Date -Format "yyyy.MM.dd HH:mm:ss") +
                    " - FEHLER: " + $_.Exception.Message
                )
        }
        Catch {
            Write-ServiceLog `
                -Level "WARN" `
                -Message ("status.txt konnte nicht aktualisiert werden: " + $_.Exception.Message)
        }

        If (Test-Path -Path $StagingPath) {
            Remove-Item `
                -Path $StagingPath `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
        }

        Throw
    }
}

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------

New-Item -ItemType Directory -Path $global:SkriptPath    -Force | Out-Null
New-Item -ItemType Directory -Path $global:LocalSyncPath -Force | Out-Null

# TLS 1.2 fuer Windows PowerShell 5.1 aktivieren
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Invoke-NetBoxExport
