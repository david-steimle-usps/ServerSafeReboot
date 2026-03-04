<#
.SYNOPSIS
    Detects whether the server requires a reboot.

.DESCRIPTION
    Checks three conditions that indicate a pending reboot is required:
      - Security Update completion (WindowsUpdate RebootRequired registry key)
      - CBS repair finalization (Component Based Servicing RebootPending registry key)
      - Uptime threshold exceeded (last boot date is >= UptimeThresholdDays ago)

    Compliant  (no reboot needed) : outputs $true  and exits with code 0.
    Non-compliant (reboot needed) : outputs $false and exits with code 1.

.PARAMETER UptimeThresholdDays
    The number of calendar days of uptime after which a reboot is required.
    Comparison is date-based (midnight to midnight) so a partial day from
    a mid-day reboot does not skew the threshold. Default is 7.

.NOTES
    Screen output is limited to Write-Verbose.
    No file logging is performed.
    When the uptime threshold is breached, a registry marker is written to
    HKLM:\SOFTWARE\ServerSafeReboot so the remediation script can read
    the threshold details. The marker is cleared when uptime is below
    the threshold.

.LINK
    https://github.com/david-steimle-usps/ServerSafeReboot
#>
[CmdletBinding()]
param(
    [int]$UptimeThresholdDays = 7
)

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

# Check: Uptime threshold exceeded (calendar-day comparison)
$lastBootTime = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
$lastBootDate = $lastBootTime.Date          # midnight on the boot day
$todayDate    = (Get-Date).Date              # midnight today
$uptimeDays   = ($todayDate - $lastBootDate).Days

$uptimeMarkerPath = 'HKLM:\SOFTWARE\ServerSafeReboot'
if ($uptimeDays -ge $UptimeThresholdDays) {
    Write-Verbose "Reboot required: Uptime is $uptimeDays day(s), threshold is $UptimeThresholdDays day(s)."
    $rebootReasons.Add('UptimeThreshold')

    # Create a registry marker so the remediation script can read the threshold details
    if (-not (Test-Path -Path $uptimeMarkerPath)) {
        New-Item -Path $uptimeMarkerPath -Force | Out-Null
    }
    New-ItemProperty -Path $uptimeMarkerPath -Name 'UptimeThresholdDays' -Value $UptimeThresholdDays -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $uptimeMarkerPath -Name 'UptimeDays'          -Value $uptimeDays          -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $uptimeMarkerPath -Name 'LastBootDate'        -Value $lastBootDate.ToString('yyyy-MM-dd') -PropertyType String -Force | Out-Null
} else {
    # Clear stale marker if uptime is now below the threshold (e.g. after a recent reboot)
    if (Test-Path -Path $uptimeMarkerPath) {
        Remove-Item -Path $uptimeMarkerPath -Recurse -Force | Out-Null
    }
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
