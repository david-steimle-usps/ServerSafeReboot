# ServerSafeReboot

A detection-and-remediation script pair for rebooting Windows servers only when a genuine need exists. The scripts are designed to run as an **Intune Proactive Remediation** or an **MECM Configuration Baseline** on a daily schedule, ensuring servers stay patched and healthy without unnecessary restarts.

## Overview

Many environments reboot servers on a fixed schedule regardless of need, or never reboot them at all. Both extremes carry risk. ServerSafeReboot takes a **need-based** approach: a lightweight detection script evaluates whether a reboot is warranted, and a separate remediation script acts only when it is.

The scripts must run **elevated** (as SYSTEM or an Administrator) because the CBS registry key requires admin-level read access and `shutdown.exe` requires `SeShutdownPrivilege`.

## Detection

`ServerSafeReboot.Detection.ps1` checks three conditions:

| Check | Registry / Source | Trigger |
|---|---|---|
| **Security Update** | `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired` | Key exists after a Windows Update install |
| **CBS Repair** | `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending` | Key exists after an SFC or DISM repair |
| **Uptime Threshold** | `Win32_OperatingSystem.LastBootUpTime` | Calendar days since last boot >= `UptimeThresholdDays` (default 7) |

The uptime comparison uses **calendar dates only** (midnight to midnight) so a partial day from a mid-day reboot does not skew the count. If the server booted on Wednesday and today is the following Wednesday, that is 7 days and meets the default threshold.

When the uptime threshold is breached, the detection script writes a **registry marker** to `HKLM:\SOFTWARE\ServerSafeReboot` containing the threshold, actual uptime days, and last boot date. This marker allows the remediation script to log the threshold details without needing the parameter passed to it. The marker is cleared automatically when uptime drops below the threshold (i.e. after a reboot).

**Output:**

- **Compliant** (no reboot needed): outputs `$true`, exits with code `0`.
- **Non-compliant** (reboot needed): outputs `$false`, exits with code `1`.

All diagnostic output uses `Write-Verbose`. No file logging is performed by the detection script.

### Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `UptimeThresholdDays` | int | 7 | Calendar days of uptime before a reboot is required |

## Remediation

`ServerSafeReboot.Remediation.ps1` re-checks the same registry conditions as detection (plus the uptime marker), logs the reasons, and initiates a restart via `shutdown.exe`.

### Workflow

1. Opens a rotating text log and writes a masthead with endpoint name, log path, timestamp, and project URL.
2. Checks for pending SecurityUpdate, CBSRepair, and UptimeThreshold reasons.
3. Logs each reason to the text log and `Write-Verbose`.
4. Selects a shutdown reason code based on the highest-priority reason:
   - SecurityUpdate or CBSRepair &rarr; `P:2:17` (Planned: OS Security Fix)
   - UptimeThreshold only &rarr; `P:4:2` (Planned: Application Maintenance)
5. Writes an Information event to the Application event log.
6. Calls `shutdown.exe /r /t <DelaySeconds> /d <reason> /c <message>`.
7. Captures the `shutdown.exe` exit code and logs the result.

The default delay is **90 seconds**, giving any logged-in user time to see the notification and run `shutdown /a` to abort if needed (requires admin privileges).

### Exit code handling

| `shutdown.exe` exit code | Meaning | Script exits |
|---|---|---|
| 0 | Shutdown scheduled successfully | `0` (success) |
| 1190 | A shutdown is already in progress | `0` (success) |
| 5 | Access denied | `1` (failure) |
| Other | Unexpected error | `1` (failure) |

### Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `DelaySeconds` | uint32 | 90 | Seconds before restart; users can `shutdown /a` during this window |
| `LogDirectory` | string | `$env:TEMP` | Directory for the text log file |
| `LogFileName` | string | *script basename*.log | Log file name |
| `EventLogName` | string | Application | Windows Event Log to write to |
| `EventLogSource` | string | ServerSafeReboot | Event log source name (auto-created) |

## Finding the text log

The remediation script writes to a rotating log file. By default:

```
%TEMP%\ServerSafeReboot.Remediation.log
```

When run as SYSTEM (Intune/MECM), `%TEMP%` resolves to `C:\Windows\Temp`. The log can also be accessed via the UNC path shown in the log masthead:

```
\\<hostname>\C$\Windows\Temp\ServerSafeReboot.Remediation.log
```

Log rotation occurs when the file exceeds 10 MB. Up to 2 backup copies are retained.

## Finding event log entries

### Script events (Application log)

The remediation script writes entries under source **ServerSafeReboot** in the **Application** log. To retrieve the most recent entry:

```powershell
Get-WinEvent -FilterHashtable @{
    LogName      = 'Application'
    ProviderName = 'ServerSafeReboot'
} -MaxEvents 1 | Format-List TimeCreated, Id, Message
```

### OS shutdown record (System log)

Windows records every restart in the **System** log as Event ID **1074**. The entry includes the reason code from `shutdown.exe /d` and the `/c` comment text:

```powershell
Get-WinEvent -FilterHashtable @{
    LogName = 'System'
    Id      = 1074
} -MaxEvents 1 | Format-List TimeCreated, Id, Message
```

## References

- [Shutdown reason codes (Microsoft Learn)](https://learn.microsoft.com/en-us/windows/win32/shutdown/system-shutdown-reason-codes)
- [shutdown.exe command reference](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/shutdown)
- [Intune Proactive Remediations](https://learn.microsoft.com/en-us/mem/intune/fundamentals/remediations)
- [MECM Configuration Baselines](https://learn.microsoft.com/en-us/mem/configmgr/compliance/deploy-use/create-configuration-baselines)
