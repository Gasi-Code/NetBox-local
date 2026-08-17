#Requires -Version 5.1
<#
.SYNOPSIS
  Signs the NetBox Local MSI with an Authenticode certificate.

.DESCRIPTION
  Signing is what stops Windows SmartScreen from warning about an unknown
  publisher, and it is the only way a recipient can tell that the package really
  came from you and was not modified on the way.

  What is needed, and what will not work:

    Works    a code signing certificate from a recognised CA (DigiCert,
             Sectigo, SSL.com and others). Since June 2023 the private key must
             live on a hardware token or in a cloud HSM, so the certificate
             usually appears in the Windows certificate store rather than as a
             .pfx file. Use -CertificateThumbprint in that case.

    Works    an internal CA certificate, if your organisation distributes its
             root certificate to all machines. Fine for internal rollout,
             useless for anyone outside.

    Does not a self-signed certificate. Windows still treats the publisher as
             untrusted, so SmartScreen keeps warning. It only helps for testing
             the signing process itself.

  An OV certificate builds SmartScreen reputation over time; an EV certificate
  is trusted immediately.

.PARAMETER CertificateThumbprint
  Thumbprint of a certificate in the Windows certificate store. Use this with a
  hardware token or HSM-backed certificate.

.PARAMETER CertificatePath
  Path to a .pfx file. The password is asked for interactively rather than
  passed as an argument, because command lines are readable by other processes.

.PARAMETER Verify
  Only check an existing signature, sign nothing.

.EXAMPLE
  .\Sign-Installer.ps1 -CertificateThumbprint A1B2C3...
  .\Sign-Installer.ps1 -CertificatePath .\codesign.pfx
  .\Sign-Installer.ps1 -Verify
#>
[CmdletBinding()]
param(
    [string]$MsiPath,
    [string]$CertificateThumbprint,
    [string]$CertificatePath,
    [string]$TimestampUrl = 'http://timestamp.digicert.com',
    [switch]$Verify
)

$ErrorActionPreference = 'Stop'

$InstallerDir = $PSScriptRoot
$RootDir      = Split-Path $InstallerDir -Parent

if (-not $MsiPath) {
    $newest = Get-ChildItem -Path (Join-Path $RootDir 'dist\installer') -Filter '*.msi' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($null -eq $newest) { throw 'No MSI found. Run Build-Installer.ps1 first.' }
    $MsiPath = $newest.FullName
}

if (-not (Test-Path $MsiPath)) { throw "MSI not found: $MsiPath" }

function Find-SignTool {
    $candidates = @()
    foreach ($base in @("${env:ProgramFiles(x86)}\Windows Kits\10\bin", "$env:ProgramFiles\Windows Kits\10\bin")) {
        if (Test-Path $base) {
            $candidates += Get-ChildItem -Path $base -Recurse -Filter 'signtool.exe' -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -match 'x64' }
        }
    }
    $inPath = Get-Command signtool.exe -ErrorAction SilentlyContinue
    if ($inPath) { return $inPath.Source }
    if ($candidates) { return ($candidates | Sort-Object FullName -Descending | Select-Object -First 1).FullName }
    return $null
}

$signtool = Find-SignTool

# --- Verify only -----------------------------------------------------------

if ($Verify) {
    $signature = Get-AuthenticodeSignature -FilePath $MsiPath

    Write-Host ''
    Write-Host "File   : $MsiPath"
    Write-Host "Status : $($signature.Status)"

    if ($signature.SignerCertificate) {
        Write-Host "Subject: $($signature.SignerCertificate.Subject)"
        Write-Host "Issuer : $($signature.SignerCertificate.Issuer)"
        Write-Host "Valid  : $($signature.SignerCertificate.NotBefore) - $($signature.SignerCertificate.NotAfter)"
    }
    else {
        Write-Host 'The package is not signed.' -ForegroundColor Yellow
        Write-Host 'Windows SmartScreen will warn about an unknown publisher.'
    }
    Write-Host ''
    return
}

# --- Sign ------------------------------------------------------------------

if (-not $CertificateThumbprint -and -not $CertificatePath) {
    Write-Host ''
    Write-Host 'No certificate given.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'Code signing certificates in your personal store:'
    Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue |
        Format-Table Thumbprint, Subject, NotAfter -AutoSize | Out-String | Write-Host
    Write-Host 'Then run:'
    Write-Host '  .\Sign-Installer.ps1 -CertificateThumbprint <thumbprint>'
    Write-Host '  .\Sign-Installer.ps1 -CertificatePath .\codesign.pfx'
    Write-Host ''
    return
}

if (-not $signtool) {
    throw @"
signtool.exe was not found. It ships with the Windows SDK:
  https://developer.microsoft.com/windows/downloads/windows-sdk/
Only the "Windows SDK Signing Tools" component is required.
"@
}

$arguments = @('sign', '/fd', 'SHA256', '/td', 'SHA256', '/tr', $TimestampUrl, '/v')

if ($CertificateThumbprint) {
    $arguments += @('/sha1', $CertificateThumbprint)
}
else {
    if (-not (Test-Path $CertificatePath)) { throw "Certificate not found: $CertificatePath" }
    # Asking interactively keeps the password out of the process list.
    $secure = Read-Host -AsSecureString "Password for $CertificatePath"
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
    $arguments += @('/f', $CertificatePath, '/p', $plain)
}

$arguments += $MsiPath

& $signtool @arguments
if ($LASTEXITCODE -ne 0) { throw "signtool failed with exit code $LASTEXITCODE" }

Write-Host ''
Write-Host 'Signed. Verifying:' -ForegroundColor Green
$signature = Get-AuthenticodeSignature -FilePath $MsiPath
Write-Host "  Status : $($signature.Status)"
Write-Host "  Subject: $($signature.SignerCertificate.Subject)"
