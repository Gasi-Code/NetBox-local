# Exports the complete NetBox dataset over the REST API
#
# Extended from an IPAM-only export to the complete NetBox dataset
#              (~120 endpoints), with endpoint discovery at runtime and
#              per-endpoint fault tolerance.
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
# Configuration
# ---------------------------------------------------------------------------

$NetBoxServer        = "https://netbox.example.com/"
$APIKey              = "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
$AuthorizationScheme = "Token"

$global:ScriptPath     = "C:\Sync-Skripte\Sync-NetBoxExport"
$ServiceLogFile        = "$global:ScriptPath\Sync-NetBoxExport_Service.log"
$global:LocalSyncPath  = "C:\Sync-Daten\NetBoxLocal"

$TimeoutSeconds = 300
$PageSize   = 500
$MaxAttempts     = 3

$PushURL = ""

# Endpoints that must never end up in an export archive, and why. Emergency
# notebooks travel and get lost; anything in this list would turn a lost device
# into a NetBox compromise or would bloat the archive without helping anyone
# during an outage.
$ExcludedEndpoints = [ordered]@{
    "api/users/tokens/"                = "SECURITY: returns API tokens in clear text. A lost notebook would grant full access to the production NetBox."
    "api/users/users/"                 = "SECURITY: personal user data, of no use during an outage."
    "api/users/permissions/"           = "SECURITY: access control of the production instance."
    "api/users/groups/"                = "SECURITY: access control of the production instance."
    "api/users/config/"                = "Per-user interface settings, not inventory data."

    "api/core/object-changes/"         = "VOLUME: the full changelog, often millions of rows. Useless during an outage."
    "api/core/jobs/"                   = "Runtime state of background jobs, not inventory data."
    "api/core/background-queues/"      = "RQ runtime state."
    "api/core/background-tasks/"       = "RQ runtime state."
    "api/core/background-workers/"     = "RQ runtime state."
    "api/core/data-files/"             = "VOLUME: contains the file contents of synchronised data sources."

    "api/extras/scripts/"              = "Script definitions; errors out when no script files are present."
    "api/extras/scripts/upload/"       = "Upload endpoint, POST only. Answers GET with 405 by design."
    "api/extras/dashboard/"            = "Not a list endpoint; returns the calling user's dashboard."
    "api/extras/notifications/"        = "Per-user data."
    "api/extras/subscriptions/"        = "Per-user data."
    "api/extras/bookmarks/"            = "Per-user data."
    "api/extras/saved-filters/"        = "Per-user data."
    "api/extras/table-configs/"        = "Per-user data."

    "api/plugins/installed-plugins/"   = "Returns a bare list rather than a paginated result, and describes the server's plugins rather than the network."

    "api/dcim/connected-device/"       = "Not a list endpoint; requires the peer_device and peer_interface parameters."
    "api/schema/redoc/"                = "HTML documentation page, not JSON."
    "api/schema/swagger-ui/"           = "HTML documentation page, not JSON."
}

# Query parameters applied per endpoint. NetBox renders config contexts into
# every device and virtual machine record, which multiplies the export size for
# data that is already exported once via extras/config-contexts.
$EndpointParameters = [ordered]@{
    "api/dcim/devices/"                    = "exclude=config_context"
    "api/virtualization/virtual-machines/" = "exclude=config_context"
}

# Fallback list, used only when endpoint discovery fails. Mirrors the endpoints
# of NetBox 4.6.8 minus the exclusions above.
$FallbackEndpoints = @(
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
# Helper functions
# ---------------------------------------------------------------------------

# Appends an entry to the service log
Function Write-ServiceLog {
    Param (
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )

    $logEntry = (
        (Get-Date -Format "yyyy.MM.dd HH:mm:ss") +
        " [" + $Level + "] - " +
        $Message +
        " (" + $env:COMPUTERNAME + ")"
    )

    $logEntry |
        Out-File `
            -Append `
            -FilePath $ServiceLogFile `
            -Encoding utf8 `
            -Force

    Write-Host $logEntry
}

# Joins the NetBox base address and an API path
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

# Writes text as UTF-8 without a BOM
Function Write-UTF8File {
    Param (
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content
    )

    $utf8Encoding = New-Object System.Text.UTF8Encoding($false)

    [System.IO.File]::WriteAllText(
        $Path,
        $Content,
        $utf8Encoding
    )
}

# Turns an API path into a file name
# "api/dcim/device-roles/" becomes "dcim_device-roles"
Function ConvertTo-EndpointName {
    Param (
        [Parameter(Mandatory = $true)]
        [string]$APIPath
    )

    $parts = $APIPath.Trim("/").Split("/")

    If ($parts.Length -ge 3) {
        # Every segment after "api" is kept. Taking only the first two used to
        # map "api/extras/scripts/" and "api/extras/scripts/upload/" onto the
        # same file name, so whichever ran second silently overwrote the other.
        Return ($parts[1..($parts.Length - 1)] -join "_")
    }

    Return ($parts[-1])
}

# Calls a NetBox endpoint, retrying on failure
Function Invoke-NetBoxGET {
    Param (
        [Parameter(Mandatory = $true)]
        [string]$URL,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    For ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Try {
            Return Invoke-RestMethod `
                -Uri $URL `
                -Method GET `
                -Headers $Headers `
                -TimeoutSec $TimeoutSeconds `
                -UseBasicParsing `
                -ErrorAction Stop
        }
        Catch {
            If ($attempt -ge $MaxAttempts) {
                Throw
            }

            # 4xx answers describe the request, not a glitch on the way: a 405
            # stays a 405 however often it is asked, and a 403 needs a
            # permission change. Retrying those only delays the export and
            # buries the real cause under repeated warnings. 408 and 429 are
            # the exceptions - both explicitly invite a second attempt.
            $status = $null
            If ($_.Exception.Response) {
                $status = [int]$_.Exception.Response.StatusCode
            }

            If ($status -ge 400 -and $status -lt 500 -and
                $status -ne 408 -and $status -ne 429) {
                Throw
            }

            $waitSeconds = [Math]::Pow(2, $attempt)

            Write-ServiceLog `
                -Level "WARN" `
                -Message (
                    "API call failed. Attempt " +
                    $attempt + " of " + $MaxAttempts +
                    ". Retrying in " + $waitSeconds +
                    " seconds. URL: " + $URL +
                    ". Error: " + $_.Exception.Message
                )

            Start-Sleep -Seconds $waitSeconds
        }
    }
}

# Discovers the list endpoints of the connected NetBox instance
#
# Discovery beats a hard-coded list: a NetBox upgrade that introduces new models
# would otherwise be exported incompletely without anyone noticing. The root
# document lists the applications, each application document lists its models.
Function Get-NetBoxEndpoints {
    Param (
        [Parameter(Mandatory = $true)]
        [string]$BaseURL,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    $found = New-Object System.Collections.ArrayList

    # Not every entry below /api/ is an application index. 'status' returns a
    # flat dictionary of version information, so treating its keys as model
    # names produces requests like api/status/django-version/ that 404.
    $NotApplications = @("status")

    $rootURL = Join-NetBoxURL -BaseURL $BaseURL -APIPath "api/"
    $root = Invoke-NetBoxGET -URL $rootURL -Headers $Headers

    ForEach ($App in $root.PSObject.Properties) {
        If ($NotApplications -contains $App.Name) { Continue }

        Try {
            $AppURL = Join-NetBoxURL -BaseURL $BaseURL -APIPath ("api/" + $App.Name + "/")
            $appDocument = Invoke-NetBoxGET -URL $AppURL -Headers $Headers
        }
        Catch {
            Continue
        }

        If ($null -eq $appDocument) { Continue }

        ForEach ($model in $appDocument.PSObject.Properties) {
            # An application index maps model names to their absolute URLs. A
            # value that is not a URL means this is a data document rather than
            # an index, and its keys are not endpoints.
            $value = [string]$model.Value

            If (-not ($value -match '^https?://')) { Continue }

            $path = "api/" + $App.Name + "/" + $model.Name + "/"
            [void]$found.Add($path)
        }
    }

    Return $found.ToArray()
}

# Retrieves every page of a NetBox list endpoint
Function Get-AllNetBoxObjects {
    Param (
        [Parameter(Mandatory = $true)]
        [string]$EndpointURL,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    If ($EndpointURL.Contains("?")) {
        $separator = "&"
    }
    Else {
        $separator = "?"
    }

    # Ordering by primary key makes pagination deterministic. Without it a
    # concurrent insert can shift rows between pages and silently duplicate or
    # skip records.
    $NextURL = (
        $EndpointURL +
        $separator +
        "limit=" + $PageSize +
        "&ordering=id"
    )

    $allObjects = New-Object System.Collections.ArrayList
    $expectedCount = $null

    While (-not [string]::IsNullOrWhiteSpace($NextURL)) {
        $response = Invoke-NetBoxGET `
            -URL $NextURL `
            -Headers $Headers

        If ($null -eq $response) {
            Throw (
                "The NetBox endpoint '" + $NextURL +
                "' returned no response."
            )
        }

        If ($null -eq $response.PSObject.Properties["results"]) {
            Throw (
                "Unexpected API format at '" + $NextURL +
                "'. The 'results' property is missing."
            )
        }

        If ($null -eq $response.PSObject.Properties["count"]) {
            Throw (
                "Unexpected API format at '" + $NextURL +
                "'. The 'count' property is missing."
            )
        }

        If ($null -eq $expectedCount) {
            $expectedCount = [int64]$response.count
        }

        ForEach ($object in @($response.results)) {
            [void]$allObjects.Add($object)
        }

        $NextURL = [string]$response.next
    }

    If ($null -eq $expectedCount) {
        Throw (
            "The object count could not be determined for endpoint '" +
            $EndpointURL + "'."
        )
    }

    # A mismatch used to abort the entire run. On a production NetBox that is
    # actively being edited during the export window this happens legitimately,
    # so it is now reported rather than fatal - the data is still usable, just
    # not a perfectly consistent snapshot.
    If ($allObjects.Count -ne $expectedCount) {
        Write-ServiceLog `
            -Level "WARN" `
            -Message (
                "Object count differs (data changed during the export?). " +
                "Expected: " + $expectedCount +
                "; received: " + $allObjects.Count +
                "; endpoint: " + $EndpointURL
            )
    }

    Return $allObjects.ToArray()
}

# Flattens nested NetBox objects for the CSV export
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

    ForEach ($object in $InputObjects) {
        $csvRow = [ordered]@{}

        ForEach ($property in $object.PSObject.Properties) {
            $value = $property.Value

            If ($null -eq $value) {
                $csvRow[$property.Name] = $null
            }
            ElseIf (
                ($value -is [string]) -or
                ($value -is [ValueType])
            ) {
                $csvRow[$property.Name] = $value
            }
            Else {
                $csvRow[$property.Name] = (
                    $value |
                        ConvertTo-Json `
                            -Depth 30 `
                            -Compress
                )
            }
        }

        [PSCustomObject]$csvRow
    }
}

# Returns the English weekday name, independent of locale
Function Get-NetBoxWeekday {
    Return (
        (Get-Date).ToString(
            "dddd",
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    )
}

# Returns the file name of the weekday rotation slot
Function Get-NetBoxRotationFileName {
    Return (Get-NetBoxWeekday) + ".zip"
}

# Updates the human-readable status line for one weekday in status.txt
Function Update-NetBoxStatusFile {
    Param (
        [Parameter(Mandatory = $true)]
        [string]$Weekday,

        [Parameter(Mandatory = $true)]
        [string]$StatusLine
    )

    $statusPath = Join-Path $global:LocalSyncPath "status.txt"

    $WeekdayeReihenfolge = @(
        "Monday", "Tuesday", "Wednesday", "Thursday",
        "Friday", "Saturday", "Sunday"
    )

    $entries = [ordered]@{}

    ForEach ($day in $WeekdayeReihenfolge) {
        $entries[$day] = $null
    }

    If (Test-Path -Path $statusPath) {
        ForEach ($line in (Get-Content -Path $statusPath -Encoding UTF8)) {
            If ($line -match '^(\w+):\s?(.*)$') {
                $day = $Matches[1]

                If ($entries.Contains($day)) {
                    $entries[$day] = $Matches[2]
                }
            }
        }
    }

    $entries[$Weekday] = $StatusLine

    $linen = ForEach ($day in $WeekdayeReihenfolge) {
        If ($null -ne $entries[$day]) {
            $day + ": " + $entries[$day]
        }
    }

    Write-UTF8File `
        -Path $statusPath `
        -Content ($linen -join "`r`n")
}

# Packs the staging directory and publishes it as a rotation slot
Function Publish-NetBoxExport {
    Param (
        [Parameter(Mandatory = $true)]
        [string]$StagingPath,

        [Parameter(Mandatory = $true)]
        [string]$TargetDirectory
    )

    $targetFileName = Get-NetBoxRotationFileName
    $targetPath = Join-Path $TargetDirectory $targetFileName

    $tempZipPath = Join-Path `
        $TargetDirectory `
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
        $tempZipPath,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $false
    )

    Move-Item `
        -Path $tempZipPath `
        -Destination $targetPath `
        -Force `
        -ErrorAction Stop
}

# ---------------------------------------------------------------------------
# Main flow
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
            Throw "No NetBox server is configured."
        }

        If ([string]::IsNullOrWhiteSpace($APIKey) -or
            ($APIKey -eq "NETBOX-API-TOKEN-HIER-EINTRAGEN") -or
            ($APIKey -match '^X+$')
        ) {
            Throw "No NetBox API token is configured."
        }

        $Headers = @{
            "Authorization" = ($AuthorizationScheme + " " + $APIKey)
            "Accept"        = "application/json"
            "User-Agent"    = ("Notfallnotebook-NetBoxComplete/" + $env:COMPUTERNAME)
        }

        New-Item -ItemType Directory -Path $JSONPath -Force | Out-Null
        New-Item -ItemType Directory -Path $CSVPath  -Force | Out-Null

        Write-ServiceLog -Message "Full NetBox export started."

        # --- Determine endpoints ---------------------------------------------

        $endpointSource = "discovery"

        Try {
            $discovered = @(
                Get-NetBoxEndpoints `
                    -BaseURL $NetBoxServer `
                    -Headers $Headers
            )

            If ($discovered.Count -lt 50) {
                Throw (
                    "Endpoint discovery returned only " + $discovered.Count +
                    " entries, which is implausibly few."
                )
            }
        }
        Catch {
            Write-ServiceLog `
                -Level "WARN" `
                -Message (
                    "Endpoint discovery failed; falling back to the static " +
                    "list. New NetBox models may therefore " +
                    "may therefore not be exported. Error: " +
                    $_.Exception.Message
                )

            $discovered = $FallbackEndpoints
            $endpointSource = "fallback"
        }

        $endpoints = New-Object System.Collections.ArrayList
        $skipped = New-Object System.Collections.ArrayList

        ForEach ($path in ($discovered | Sort-Object -Unique)) {
            If ($ExcludedEndpoints.Contains($path)) {
                [void]$skipped.Add($path)
            }
            Else {
                [void]$endpoints.Add($path)
            }
        }

        Write-ServiceLog `
            -Message (
                "Endpoints determined (" + $endpointSource + "): " +
                $endpoints.Count + " will be exported, " +
                $skipped.Count + " are deliberately excluded."
            )

        # Anything discovered that the fallback list does not know about is new
        # in this NetBox version and worth flagging.
        ForEach ($path in $endpoints) {
            If ($FallbackEndpoints -notcontains $path) {
                Write-ServiceLog `
                    -Level "WARN" `
                    -Message (
                        "New, previously unknown endpoint found: " + $path +
                        ". Check whether it is security-relevant."
                    )
            }
        }

        # --- Export ----------------------------------------------------------

        $objectCounts       = [ordered]@{}
        $failedEndpoints = [ordered]@{}
        $exportFiles        = New-Object System.Collections.ArrayList

        ForEach ($path in $endpoints) {
            $name = ConvertTo-EndpointName -APIPath $path

            $EndpointURL = Join-NetBoxURL `
                -BaseURL $NetBoxServer `
                -APIPath $path

            If ($EndpointParameters.Contains($path)) {
                $EndpointURL = $EndpointURL + "?" + $EndpointParameters[$path]
            }

            # A single broken endpoint must not destroy the whole run. With
            # ~120 endpoints the odds of one failing are no longer negligible,
            # and a partial export still beats no export during an outage.
            Try {
                Write-ServiceLog -Message ("Exporting '" + $name + "'.")

                $objects = @(
                    Get-AllNetBoxObjects `
                        -EndpointURL $EndpointURL `
                        -Headers $Headers
                )

                $objectCounts[$name] = $objects.Count

                $JSONFile = Join-Path $JSONPath ($name + ".json")
                $CSVFile  = Join-Path $CSVPath  ($name + ".csv")

                $jsonContent = ConvertTo-Json `
                    -InputObject $objects `
                    -Depth 50

                Write-UTF8File -Path $JSONFile -Content $jsonContent

                If ($objects.Count -gt 0) {
                    ConvertTo-NetBoxCSVObject `
                        -InputObjects $objects |
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

                [void]$exportFiles.Add($JSONFile)
                [void]$exportFiles.Add($CSVFile)

                Write-ServiceLog `
                    -Message (
                        "'" + $name + "' exported successfully (" +
                        $objects.Count + " objects)."
                    )
            }
            Catch {
                $failedEndpoints[$name] = $_.Exception.Message

                Write-ServiceLog `
                    -Level "ERROR" `
                    -Message (
                        "Endpoint '" + $name + "' failed; the export " +
                        "continues. Error: " + $_.Exception.Message
                    )
            }
        }

        # --- Manifest --------------------------------------------------------

        $netBoxVersion = $null

        Try {
            $statusUrl = Join-NetBoxURL `
                -BaseURL $NetBoxServer `
                -APIPath "api/status/"

            $netBoxStatus = Invoke-NetBoxGET `
                -URL $statusUrl `
                -Headers $Headers

            If ($null -ne $netBoxStatus.PSObject.Properties["netbox-version"]) {
                $netBoxVersion = $netBoxStatus."netbox-version"
            }
        }
        Catch {
            Write-ServiceLog `
                -Level "WARN" `
                -Message (
                    "The NetBox version could not be read. " +
                    "The export continues regardless."
                )
        }

        If ($failedEndpoints.Count -eq 0) {
            $overallStatus = "complete"
        }
        Else {
            $overallStatus = "partial"
        }

        $Manifest = [ordered]@{
            status            = $overallStatus
            exportTime        = (Get-Date).ToString("o")
            computerName      = $env:COMPUTERNAME
            netBoxVersion     = $netBoxVersion
            endpointSource    = $endpointSource
            endpointsExported = $endpoints.Count
            endpointsExcluded = @($skipped)
            failedEndpoints   = $failedEndpoints
            objectCounts      = $objectCounts
        }

        $manifestFile = Join-Path $StagingPath "manifest.json"

        Write-UTF8File `
            -Path $manifestFile `
            -Content ($Manifest | ConvertTo-Json -Depth 20)

        [void]$exportFiles.Add($manifestFile)

        # --- Pruefsummen -----------------------------------------------------

        $checksums = ForEach ($file in $exportFiles) {
            $hash = Get-FileHash -Path $file -Algorithm SHA256

            $relativePath = $file.Substring(
                $StagingPath.Length
            ).TrimStart([char]92)

            ($hash.Hash.ToLowerInvariant() + " *" + $relativePath)
        }

        Write-UTF8File `
            -Path (Join-Path $StagingPath "checksums.sha256") `
            -Content ($checksums -join "`r`n")

        # --- Veroeffentlichen ------------------------------------------------

        $targetFileName = Get-NetBoxRotationFileName

        Publish-NetBoxExport `
            -StagingPath $StagingPath `
            -TargetDirectory $global:LocalSyncPath

        Remove-Item `
            -Path $StagingPath `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue

        $totalObjectCount = (
            $objectCounts.Values | Measure-Object -Sum
        ).Sum

        Write-ServiceLog `
            -Message (
                "Full NetBox export finished (status: " + $overallStatus +
                "). Archive: " +
                (Join-Path $global:LocalSyncPath $targetFileName)
            )

        If ($overallStatus -eq "complete") {
            $statusText = " - SUCCESS ("
        }
        Else {
            $statusText = (
                " - PARTIAL (" + $failedEndpoints.Count +
                " endpoints failed, "
            )
        }

        Update-NetBoxStatusFile `
            -Weekday (Get-NetBoxWeekday) `
            -StatusLine (
                (Get-Date -Format "yyyy.MM.dd HH:mm:ss") +
                $statusText +
                $totalObjectCount +
                " objects, file: " + $targetFileName + ")"
            )

        # Monitoring is only pinged on a fully successful run. A partial export
        # must show up as a missed heartbeat, otherwise a slowly rotting export
        # stays green in the dashboard.
        If ((-not [string]::IsNullOrWhiteSpace($PushURL)) -and
            ($overallStatus -eq "complete")
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
                        "Export succeeded, monitoring push failed: " +
                        $_.Exception.Message
                    )
            }
        }

        If ($overallStatus -ne "complete") {
            Throw (
                "Export incomplete: " + $failedEndpoints.Count +
                " of " + $endpoints.Count + " endpoints failed (" +
                (($failedEndpoints.Keys) -join ", ") + ")."
            )
        }
    }
    Catch {
        Write-ServiceLog `
            -Level "ERROR" `
            -Message ("Full NetBox export failed: " + $_.Exception.Message)

        Try {
            Update-NetBoxStatusFile `
                -Weekday (Get-NetBoxWeekday) `
                -StatusLine (
                    (Get-Date -Format "yyyy.MM.dd HH:mm:ss") +
                    " - ERROR: " + $_.Exception.Message
                )
        }
        Catch {
            Write-ServiceLog `
                -Level "WARN" `
                -Message ("status.txt could not be updated: " + $_.Exception.Message)
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
# Entry point
# ---------------------------------------------------------------------------

New-Item -ItemType Directory -Path $global:ScriptPath    -Force | Out-Null
New-Item -ItemType Directory -Path $global:LocalSyncPath -Force | Out-Null

# Add TLS 1.2 rather than replacing what is enabled. Assigning it outright also
# switches off TLS 1.3 where the machine already had it, which breaks against a
# server that has dropped 1.2.
[Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# On a managed network the route to NetBox usually runs through an
# authenticating proxy. .NET reads the proxy address from the system settings
# but sends no credentials, so every request comes back 407 - and the retry
# loop then repeats it three times before failing with a message that never
# mentions a proxy. Handing it the signed-in user's credentials is what a
# browser on the same machine does.
try {
    $systemProxy = [Net.WebRequest]::GetSystemWebProxy()
    $systemProxy.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials
    [Net.WebRequest]::DefaultWebProxy = $systemProxy
}
catch { }

Invoke-NetBoxExport
