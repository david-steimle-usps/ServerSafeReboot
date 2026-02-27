<#
.SYNOPSIS
    Remediates a pending server reboot by restarting the computer.

.DESCRIPTION
    Initiates a graceful restart of the local computer to complete any
    pending operations (Security Updates, CBS repairs, File Rename operations).

.NOTES
    Run ServerSafeReboot.Detection.ps1 first to confirm a reboot is required
    before invoking this remediation script.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$Message = 'ServerSafeReboot: Restarting to apply pending changes.',

    [Parameter()]
    [uint32]$DelaySeconds = 0
)

$pendingReasons = New-Object System.Collections.Generic.List[string]

# Collect reasons (mirrors Detection logic) to log what prompted the reboot
$securityUpdatePath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
if (Test-Path -Path $securityUpdatePath) {
    $pendingReasons.Add('SecurityUpdate')
}

$cbsPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
if (Test-Path -Path $cbsPath) {
    $pendingReasons.Add('CBSRepair')
}

$sessionManagerPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
$pendingRenames = (Get-ItemProperty -Path $sessionManagerPath -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue).PendingFileRenameOperations
if ($null -ne $pendingRenames -and @($pendingRenames).Count -gt 0) {
    $pendingReasons.Add('FileRenameOperations')
}

foreach ($reason in $pendingReasons) {
    Write-Verbose "Reboot triggered for reason: $reason"
}

if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Restart-Computer ($Message)")) {
    Restart-Computer -Force -Timeout $DelaySeconds
}
