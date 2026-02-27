<#
.SYNOPSIS
    Detects whether the server requires a reboot.

.DESCRIPTION
    Checks three conditions that indicate a pending reboot is required:
      - Security Update completion (WindowsUpdate RebootRequired registry key)
      - CBS repair finalization (Component Based Servicing RebootPending registry key)
      - File Rename operations (PendingFileRenameOperations registry value)

    Compliant  (no reboot needed) : outputs $true  and exits with code 0.
    Non-compliant (reboot needed) : outputs $false and exits with code 1.

.NOTES
    Screen output is limited to Write-Verbose.
    No logging is performed.
#>
[CmdletBinding()]
param()

$rebootReasons = New-Object System.Collections.Generic.List[string]

# Check: Security Update reboot required
$securityUpdatePath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
if (Test-Path -Path $securityUpdatePath) {
    Write-Verbose 'Reboot required: Security Update completion pending.'
    $rebootReasons.Add('SecurityUpdate')
}

# Check: CBS repair reboot required
$cbsPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
if (Test-Path -Path $cbsPath) {
    Write-Verbose 'Reboot required: CBS repair finalization pending.'
    $rebootReasons.Add('CBSRepair')
}

# Check: File Rename Operations reboot required
$sessionManagerPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
$pendingRenames = (Get-ItemProperty -Path $sessionManagerPath -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue).PendingFileRenameOperations
if ($null -ne $pendingRenames -and @($pendingRenames).Count -gt 0) {
    Write-Verbose 'Reboot required: File Rename operations pending.'
    $rebootReasons.Add('FileRenameOperations')
}

if ($rebootReasons.Count -gt 0) {
    foreach ($reason in $rebootReasons) {
        Write-Verbose "Pending reboot reason: $reason"
    }
    # Non-compliant: reboot is needed
    $false
    exit 1
}

# Compliant: no reboot needed
$true
exit 0
