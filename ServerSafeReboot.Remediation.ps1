<#
.SYNOPSIS
    Remediates a pending server reboot by restarting the computer.

.DESCRIPTION
    Checks for pending reboot conditions (Security Updates, CBS repairs,
    and an uptime threshold marker written by ServerSafeReboot.Detection.ps1),
    logs the reasons, writes an Application event log entry, and initiates
    a restart via shutdown.exe with a configurable delay. The delay allows
    an active user to see the notification and optionally abort with
    shutdown /a.

    Exit code 0 is returned when the shutdown is scheduled successfully
    or a shutdown is already in progress. Exit code 1 is returned on
    failure (access denied, unexpected error).

.PARAMETER DelaySeconds
    Seconds to wait before the restart begins. During this window the
    pending shutdown is visible to logged-in users and can be cancelled
    with shutdown /a. Default is 90.

.PARAMETER LogDirectory
    Directory for the log file. Defaults to the TEMP environment variable.
    If a custom path is specified, ensure the directory exists.

.PARAMETER LogFileName
    Name of the log file. Defaults to the script's own base name with a
    .log extension (e.g. ServerSafeReboot.Remediation.log).

.PARAMETER EventLogName
    Windows Event Log to write entries to. Default is Application.

.PARAMETER EventLogSource
    Source name used when writing event log entries. Default is
    ServerSafeReboot. The source is created automatically if it does
    not already exist.

.NOTES
    This script should run elevated (as SYSTEM or an Administrator)
    to ensure access to the CBS registry key and shutdown privileges.

    Logs are written to a rotating text file and to the Windows
    Application event log under the ServerSafeReboot source.

    The uptime threshold marker at HKLM:\SOFTWARE\ServerSafeReboot is
    consumed and cleared by this script after reading.

.LINK
    https://github.com/david-steimle-usps/ServerSafeReboot
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(HelpMessage = 'Seconds to delay before restart. Users can run shutdown /a to cancel during this window.')]
    [uint32]$DelaySeconds = 90,
    [Parameter(HelpMessage = 'Directory for the log file. Defaults to TEMP. Ensure the directory exists if overriding.')]
    [string]$LogDirectory = $env:TEMP,
    [Parameter(HelpMessage = 'Log file name. Defaults to the script base name with a .log extension.')]
    [string]$LogFileName = "$(([System.IO.FileInfo]$MyInvocation.MyCommand.Path).BaseName).log",
    [Parameter(HelpMessage = 'Windows Event Log name to write entries to.')]
    [string]$EventLogName = 'Application',
    [Parameter(HelpMessage = 'Event log source name. Created automatically if it does not exist.')]
    [string]$EventLogSource = 'ServerSafeReboot'
)

#region Logger

$LogFile = [System.IO.FileInfo]$(Join-Path -Path $LogDirectory -ChildPath $LogFileName)

class LogWriter {
    [System.IO.StreamWriter]$Writer
    [string]$Path
    [long]$MaxBytes = 10MB
    [int]$MaxBackups = 2
    [string]$EventLogName = 'Application'
    [string]$EventSource = 'ServerSafeReboot'
    [int]$InfoEventId = 1000
    [int]$WarnEventId = 2000
    [int]$ErrorEventId = 3000
    [bool]$IsOpen = $false

    LogWriter([string]$Path) {
        $this.Path = $Path
    }

    LogWriter([string]$Path, [string]$EventLogName, [string]$EventSource) {
        $this.Path = $Path
        $this.EventLogName = $EventLogName
        $this.EventSource = $EventSource
    }

    [void] Rotate() {
        $fileInfo = [System.IO.FileInfo]$this.Path
        if (-not $fileInfo.Exists -or $fileInfo.Length -lt $this.MaxBytes) { return }

        $dir      = $fileInfo.DirectoryName
        $baseName = $fileInfo.BaseName
        $ext      = $fileInfo.Extension
        $date     = Get-Date -Format 'yyyy-MM-dd'

        $newName = '{0}-{1}{2}' -f $baseName, $date, $ext
        $newPath = Join-Path $dir $newName

        $counter = 1
        while ([System.IO.File]::Exists($newPath)) {
            $newName = '{0}-{1}-{2}{3}' -f $baseName, $date, $counter, $ext
            $newPath = Join-Path $dir $newName
            $counter++
        }

        [System.IO.File]::Move($this.Path, $newPath)

        Get-ChildItem -Path $dir -Filter ('{0}-*{1}' -f $baseName, $ext) |
            Sort-Object -Property LastWriteTime -Descending |
            Select-Object -Skip $this.MaxBackups |
            ForEach-Object { [System.IO.File]::Delete($PSItem.FullName) }
    }

    [void] Open() {
        $this.Rotate()
        $this.Writer = [System.IO.StreamWriter]::new($this.Path, $true)
        $this.IsOpen = $true
    }

    [void] Write([string]$Message) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fffff"
        $this.Writer.WriteLine("$timestamp $Message")
        $this.Writer.Flush()
    }

    [void] Caption([string]$Message) {
        $this.Writer.WriteLine($Message)
        $this.Writer.Flush()
    }

    [void] Close() {
        if ($this.IsOpen) {
            $this.Writer.Close()
            $this.Writer.Dispose()
            $this.IsOpen = $false
        }
    }

    [void] EnsureEventSource() {
        if (-not [System.Diagnostics.EventLog]::SourceExists($this.EventSource)) {
            try {
                [System.Diagnostics.EventLog]::CreateEventSource($this.EventSource, $this.EventLogName)
            } catch {
                $this.Write("WARNING: Unable to create event log source '$($this.EventSource)': $_")
            }
        }
    }

    [void] WriteInfoEvent([string]$Message) {
        $this.EnsureEventSource()
        try {
            [System.Diagnostics.EventLog]::WriteEntry($this.EventSource, $Message, [System.Diagnostics.EventLogEntryType]::Information, $this.InfoEventId)
        } catch {
            $this.Write("WARNING: Unable to write Information event: $_")
        }
        $this.InfoEventId++
    }

    [void] WriteWarnEvent([string]$Message) {
        $this.EnsureEventSource()
        try {
            [System.Diagnostics.EventLog]::WriteEntry($this.EventSource, $Message, [System.Diagnostics.EventLogEntryType]::Warning, $this.WarnEventId)
        } catch {
            $this.Write("WARNING: Unable to write Warning event: $_")
        }
        $this.WarnEventId++
    }

    [void] WriteErrorEvent([string]$Message) {
        $this.EnsureEventSource()
        try {
            [System.Diagnostics.EventLog]::WriteEntry($this.EventSource, $Message, [System.Diagnostics.EventLogEntryType]::Error, $this.ErrorEventId)
        } catch {
            $this.Write("WARNING: Unable to write Error event: $_")
        }
        $this.ErrorEventId++
    }
}

Write-Verbose "[LogWriter] -as [type] is $(try{[LogWriter] -as [type];$true}catch{$false})"

$Logger = [LogWriter]::new($LogFile.FullName, $EventLogName, $EventLogSource)
Write-Verbose $LogFile.FullName
$Logger.Open()

$Bar = '#'*80

$Masthead = New-Object -TypeName psobject
$Masthead | Add-Member -MemberType NoteProperty -Name 'Endpoint' -Value $([System.Net.Dns]::GetHostEntry('').HostName)
$Masthead | Add-Member -MemberType NoteProperty -Name 'Effort' -Value $LogFile.BaseName
$Masthead | Add-Member -MemberType NoteProperty -Name 'ThisLog' -Value $LogFile.FullName
$Masthead | Add-Member -MemberType ScriptProperty -Name 'RemoteLog' -Value { "\\$($this.Endpoint)\$($this.ThisLog -replace ':','$')" }
$Masthead | Add-Member -MemberType NoteProperty -Name 'ScriptSource' -Value $PSScriptRoot
$Masthead | Add-Member -MemberType NoteProperty -Name 'DateTime' -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $([System.TimeZoneInfo]::Local.Id)"
$Masthead | Add-Member -MemberType NoteProperty -Name 'MoreInfo' -Value "$(((Get-Help $MyInvocation.MyCommand.Path).relatedLinks.navigationLink).uri)"

$MastheadText = ($Masthead | Format-List | Out-String).Trim()

$Logger.Caption($Bar)
$Logger.Caption($MastheadText)
$Logger.Caption($Bar)
$Logger.Caption('')

#endregion Logger

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

# Check: Uptime threshold marker left by Detection script
$uptimeMarkerPath = 'HKLM:\SOFTWARE\ServerSafeReboot'
if (Test-Path -Path $uptimeMarkerPath) {
    $markerProps     = Get-ItemProperty -Path $uptimeMarkerPath -ErrorAction SilentlyContinue
    $thresholdDays   = $markerProps.UptimeThresholdDays
    $actualDays      = $markerProps.UptimeDays
    $lastBoot        = $markerProps.LastBootDate
    $pendingReasons.Add('UptimeThreshold')
    $Logger.Write("Uptime threshold breached: $actualDays day(s) >= $thresholdDays day(s) threshold (last boot: $lastBoot).")

    # Clear the marker now that we have consumed it
    Remove-Item -Path $uptimeMarkerPath -Recurse -Force | Out-Null
}

foreach ($reason in $pendingReasons) {
    $logEntry = "Reboot triggered for reason: $reason"
    Write-Verbose $logEntry
    $Logger.Write($logEntry)
}

# Guard: if no reasons remain, the system may have been rebooted between detection and remediation
if ($pendingReasons.Count -eq 0) {
    $lastBootTime = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
    $Logger.Write("No pending reboot reasons found. Last boot time: $($lastBootTime.ToString('yyyy-MM-dd HH:mm:ss')). System may have been rebooted between detection and remediation.")
    $Logger.WriteWarnEvent("ServerSafeReboot remediation found no pending reasons. Last boot: $lastBootTime. Skipping reboot.")
    $Logger.Close()
    exit 0
}

$Message = 'ServerSafeReboot: Restarting to apply pending changes.'

# Select shutdown reason code based on highest-priority pending reason
# Priority: SecurityUpdate > CBSRepair > UptimeThreshold
if ($pendingReasons -contains 'SecurityUpdate') {
    $shutdownReasonCode = 'P:2:17'   # Planned – OS: Security Fix
} elseif ($pendingReasons -contains 'CBSRepair') {
    $shutdownReasonCode = 'P:2:17'   # Planned – OS: Security Fix
} else {
    $shutdownReasonCode = 'P:4:2'    # Planned – Application: Maintenance
}

if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, "shutdown.exe /r /t $DelaySeconds /d $shutdownReasonCode /c `"$Message`"")) {
    $eventMessage = "ServerSafeReboot: Reboot initiated by this scripted compliance. Pending reasons: $($pendingReasons -join ', ')"
    $Logger.WriteInfoEvent($eventMessage)
    $shutdownCmd = "shutdown.exe /r /t $DelaySeconds /d $shutdownReasonCode /c `"$Message`""
    $Logger.Write($shutdownCmd)
    Write-Verbose $shutdownCmd
    shutdown.exe /r /t $DelaySeconds /d $shutdownReasonCode /c "$Message" 2>&1
    $shutdownExitCode = $LASTEXITCODE

    switch ($shutdownExitCode) {
        0 {
            $Logger.Write('shutdown.exe completed successfully (exit code 0). Reboot scheduled.')
        }
        1190 {
            $Logger.Write('shutdown.exe: A shutdown is already in progress (exit code 1190). No action needed.')
            $Logger.WriteWarnEvent("shutdown.exe returned 1190: a shutdown was already in progress.")
        }
        5 {
            $Logger.Write('shutdown.exe: Access denied (exit code 5). Reboot was NOT scheduled.')
            $Logger.WriteErrorEvent("shutdown.exe returned 5: access denied. Verify the script runs as SYSTEM or an account with SeShutdownPrivilege.")
        }
        default {
            $Logger.Write("shutdown.exe: Unknown exit code $shutdownExitCode. Reboot may not have been scheduled.")
            $Logger.WriteErrorEvent("shutdown.exe returned unexpected exit code $shutdownExitCode.")
        }
    }

    $Logger.Close()

    if ($shutdownExitCode -eq 0 -or $shutdownExitCode -eq 1190) {
        exit 0
    } else {
        exit 1
    }
}

if ($Logger.IsOpen) { $Logger.Close() }