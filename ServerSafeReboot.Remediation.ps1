<#
.SYNOPSIS
    Remediates a pending server reboot by restarting the computer.

.DESCRIPTION
    Initiates a graceful restart of the local computer to complete any
    pending operations (Security Updates, CBS repairs, or uptime threshold breach).

.NOTES
    Run ServerSafeReboot.Detection.ps1 first to confirm a reboot is required
    before invoking this remediation script.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$Message = 'ServerSafeReboot: Restarting to apply pending changes.',
    [Parameter()]
    [uint32]$DelaySeconds = 0,
    [Parameter(HelpMessage = "The directory for the log file. The default uses environmental variables which have a high likelihood of existing. If you want to use another directory it is advised you add code to assure directory existence.")]
    [string]$LogDirectory = $env:TEMP,
    [Parameter(HelpMessage = "The file to log to. It will be placed in the directory defined above.")]
    [string]$LogFileName = "WindowsUpdateCleanupRemediation.log",
    [Parameter(HelpMessage = "The name of the Windows Event Log to write to.")]
    [string]$EventLogName = 'Application',
    [Parameter(HelpMessage = "The event log source name to use when writing events.")]
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
        $this.Writer.Close()
        $this.Writer.Dispose()
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
    $Message = "Reboot triggered for reason: $reason"
    Write-Verbose $Message
    $Logger.Write($Message)
}

if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Restart-Computer ($Message)")) {
    $eventMessage = "ServerSafeReboot: Reboot initiated by this script. Pending reasons: $($pendingReasons -join ', ')"
    $Logger.WriteInfoEvent($eventMessage)
    $Message = "Restart-Computer -Force -Timeout $DelaySeconds"
    $Logger.Write($Message)
    Write-Verbose $Message
    Restart-Computer -Force -Timeout $DelaySeconds
}
 