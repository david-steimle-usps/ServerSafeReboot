Removal
# General Information
Legacy PuTTY Removal

This script removes legacy versions of PuTTY that were not installed via MSI from the default location (C:\Program Files (x86)\PuTTY\). It deletes known PuTTY executables, removes the installation directory, and cleans up the system PATH. This script is intended to be run as a preparatory step prior to deploying PuTTY via MSI.

USPS

https://github.com/david-steimle-usps/puTTY-for-Deployment

# Software Center
Legacy PuTTY Removal

https://github.com/david-steimle-usps/puTTY-for-Deployment

This script removes legacy versions of PuTTY that were not installed via MSI from the default location (C:\Program Files (x86)\PuTTY\). It deletes known PuTTY executables, removes the installation directory, and cleans up the system PATH. This script is intended to be run as a preparatory step prior to deploying PuTTY via MSI.

## Deployment Type
### General
Legacy PuTTY Removal

This script removes legacy versions of PuTTY that were not installed via MSI from the default location (C:\Program Files (x86)\PuTTY\). It deletes known PuTTY executables, removes the installation directory, and cleans up the system PATH. This script is intended to be run as a preparatory step prior to deploying PuTTY via MSI.

### Programs

powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "LegacyPuTTYRemoval.ps1"

### Detection

```pwsh
<#
.SYNOPSIS
    MECM detection method for LegacyPuTTYRemoval.

.DESCRIPTION
    Returns output if the legacy PuTTY removal has been completed successfully
    (no legacy artifacts remain). Returns no output if any legacy artifact is
    still present, signaling MECM that the removal application needs to run.

    MECM detection logic:
      - Output = application is "installed" (removal completed)
      - No output = application is "not installed" (removal still needed)

.LINK
https://github.usps.gov/bz7yj0/puTTY-for-Deployment
#>

$LegacyFound = $false

# Check for legacy installation directory
$OldDirectory = [System.IO.DirectoryInfo]"C:\Program Files (x86)\PuTTY\"
if ($OldDirectory.Exists) {
    $LegacyFound = $true
}

# Check for legacy Start Menu entries
$OldStartMenu = [System.IO.DirectoryInfo]"C:\ProgramData\Microsoft\Windows\Start Menu\Programs\PuTTY"
if ($OldStartMenu.Exists) {
    $LegacyFound = $true
}

# Check for legacy desktop shortcut
$OldDesktopLink = [System.IO.FileInfo]"C:\Users\Public\Desktop\PuTTY.lnk"
if ($OldDesktopLink.Exists) {
    $LegacyFound = $true
}

# Check for legacy registry uninstall keys (32-bit and 64-bit)
$OldRegistryPaths = @(
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\PuTTY_is1",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PuTTY_is1"
)
$OldRegistryPaths | ForEach-Object {
    if (Test-Path $PSItem) {
        $LegacyFound = $true
    }
}

# Check for legacy PuTTY directory in system PATH
$machinePath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
$OldPathEntry = $OldDirectory.FullName.TrimEnd('\')
if ($machinePath -split ';' | Where-Object { $PSItem -eq $OldPathEntry -or $PSItem -eq $OldDirectory.FullName }) {
    $LegacyFound = $true
}

# MECM detection: output means "installed" (removal complete), no output means "not installed"
if (-not $LegacyFound) {
    Write-Host "Legacy PuTTY removal verified. No legacy artifacts detected."
}
```

-----
Install

## General
PuTTY release 0.83 (64-bit)

