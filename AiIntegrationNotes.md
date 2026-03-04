# AI Integration Notes — ServerSafeReboot

## Executive Summary

This document captures the development activity for the **ServerSafeReboot** project, a detection-and-remediation script pair for need-based Windows server reboots. The work was conducted collaboratively between a systems engineer and GitHub Copilot (Claude Opus 4.6) in VS Code over a single chat session on March 2–4, 2026.

**What was accomplished:** A pre-existing script pair was significantly reworked. A noisy detection check (PendingFileRenameOperations) was replaced with a calendar-day uptime threshold, a registry-based marker mechanism was introduced to pass data between scripts, shutdown error handling was added, logging was hardened, and comprehensive documentation was produced. The scripts are ready for deployment as an Intune Proactive Remediation or MECM Configuration Baseline.

**AI contribution:** The AI assisted with code analysis, architecture decisions, implementation, code review, bug identification, Windows internals knowledge, deployment strategy, commit message authoring, and documentation. The human retained decision authority throughout — the AI proposed, the human approved or corrected.

**Key efficiency observation:** The AI made one factual error during the session (misidentifying shutdown.exe exit code 1115 as common when 1190 is the actual code returned). The human caught this through testing and corrected the AI, which updated its guidance immediately. This highlights that **AI output must be validated through testing**, particularly for OS-level behavior claims.

## Detailed Session Log

### Phase 1: Analysis and Planning (March 2)

1. **Script explanation** — The AI was asked to explain the detection script. It provided a structured breakdown of all three registry checks, the compliance output model ($true/$false with exit codes), and correctly identified the script as suited for Intune/MECM detection.

2. **File Rename Operations risk assessment** — The human asked whether the PendingFileRenameOperations check would cause daily reboots. The AI explained that this registry value is persistently populated by routine processes (AV updates, installers, temp cleanup) and recommended removing it from a daily-cadence script. This was the catalyst for the feature branch work.

3. **Deployment strategy discussion** — The AI was asked about MECM deployment options. It recommended a Configuration Baseline with a Configuration Item using the script pair, with daily evaluation and maintenance window enforcement. Alternatives (Task Sequence, Package/Program, Run Scripts) were evaluated and dismissed with rationale.

### Phase 2: Implementation (March 4)

4. **Feature branch: `rework-file-rename-as-threshold`** — The human created the branch and added an `$UptimeThresholdDays` parameter. The AI was directed to:
   - Remove the PendingFileRenameOperations check from both scripts
   - Add a calendar-day uptime comparison using `Win32_OperatingSystem.LastBootUpTime`
   - Use `.Date` (midnight truncation) on both the boot date and today's date so that same-weekday comparisons work as expected (Wednesday to Wednesday = 7 days)

5. **Registry marker mechanism** — The AI proposed and implemented a registry key at `HKLM:\SOFTWARE\ServerSafeReboot` to pass uptime threshold data from the detection script to the remediation script. This solved the problem of parameters not being passable between Intune script pairs. The marker stores `UptimeThresholdDays` (DWord), `UptimeDays` (DWord), and `LastBootDate` (String). The detection script creates/updates the marker when the threshold is breached and cleans it up when uptime is below threshold. The remediation script reads, logs, and deletes the marker.

6. **First commit message** authored by AI, covering the file-rename-to-threshold rework.

### Phase 3: Hardening and Review (March 4)

7. **Admin requirement analysis** — The AI identified that the CBS registry path (`Component Based Servicing`) requires admin/SYSTEM read access. Without elevation, `Test-Path` silently returns `$false`, masking a real pending reboot. The other checks (SecurityUpdate registry, CIM uptime query) work without elevation.

8. **Intune compatibility review** — The AI evaluated both scripts against Intune Proactive Remediation requirements and identified multiple issues:
   - `$Message` parameter was being overwritten in a foreach loop (Medium severity — wrong text in shutdown comment)
   - `$Logger.Close()` was never called (Low — last log entries could be lost)
   - No `exit 0` in remediation script (Low — exit code leakage)
   - No guard against empty `$pendingReasons` (identified later, still open)

9. **LogWriter.IsOpen flag** — The human asked how to check if the logger was still open. The AI proposed adding a `[bool]$IsOpen` field to the LogWriter class, toggled in `Open()` and `Close()`, making `Close()` idempotent. This was implemented by the human. A fallback `if ($Logger.IsOpen) { $Logger.Close() }` was added after the ShouldProcess block for the `-WhatIf` testing path.

10. **$Message parameter removal** — Through discussion, the AI and human determined the `$Message` parameter served no purpose (never used before being overwritten, and Intune can't pass arguments). The human removed it from the param block and hardcoded the shutdown comment string.

11. **DelaySeconds changed to 90** — The human set the default to 90 seconds to give active users time to see the shutdown notification and optionally run `shutdown /a` to defer. The AI confirmed this works as expected and noted that `shutdown /a` requires admin privileges.

12. **Shutdown exit code handling** — The AI proposed capturing `$LASTEXITCODE` after `shutdown.exe` and using a `switch` statement to handle known codes.

    **Error identified and corrected by the human:** The AI initially listed exit code 1115 (`ERROR_SHUTDOWN_IS_SCHEDULED`) as a likely response when a shutdown is already pending. The human tested this scenario and consistently received 1190 (`ERROR_SHUTDOWN_IN_PROGRESS`) instead. The AI corrected its guidance, dropping 1115 from the switch and treating 1190 as the success case (goal already achieved).

    Final exit code mapping:
    - `0` → success → script exits `0`
    - `1190` → shutdown already in progress → script exits `0`
    - `5` → access denied → script exits `1`
    - `default` → unknown → script exits `1`

13. **Exit code testing guidance** — The AI provided instructions for testing each exit code:
    - 1190: Schedule a shutdown, then request another
    - 5: Remove Users from the "Shut down the system" Local Security Policy, then attempt shutdown from a non-elevated session
    - The AI explained UAC token filtering (admin accounts get a filtered standard-user token in non-elevated processes)

14. **Log filename derived from script name** — The hardcoded `WindowsUpdateCleanupRemediation.log` was replaced with `$MyInvocation.MyCommand.Path` basename resolution.

15. **PowerShell switch statement behavior** — The human asked about the need for `break` in the switch. The AI confirmed PowerShell switch does not fall through (unlike C-family languages), so `break` is unnecessary when matching a scalar value.

16. **Context-based help updates** — Both scripts received updated comment-based help:
    - Detection: `.PARAMETER UptimeThresholdDays` added, `.NOTES` updated to document registry marker behavior and clarify "no file logging"
    - Remediation: `.DESCRIPTION` rewritten to reflect shutdown.exe flow, `.PARAMETER` blocks added for all five parameters, `.NOTES` updated with elevation requirement and logging details, `HelpMessage` attributes rewritten for brevity

17. **.LINK usage at runtime** — The AI showed how to retrieve the `.LINK` URI from within the script via `((Get-Help $MyInvocation.MyCommand.Path).relatedLinks.navigationLink).uri`. The human added this to the log masthead as a `MoreInfo` field.

18. **README.md** — The AI wrote comprehensive documentation covering the project overview, detection logic, remediation workflow, log file location, event log queries, and reference links.

19. **Second and third commit messages** authored by AI for the hardening work and README respectively.

### Phase 4: Final Fixes (March 4)

20. **Empty `$pendingReasons` guard** — Added a guard that fires when no pending reasons are found. The guard queries `Win32_OperatingSystem.LastBootUpTime`, logs the last boot time to both the text log and a Warning event, and exits `0`. This covers the unlikely scenario where the system was rebooted between detection and remediation. The loop variable was also renamed from `$Message` to `$logEntry` to eliminate the earlier overwrite issue cleanly.

21. **Merged to main** — Feature branch `rework-file-rename-as-threshold` was merged to main.

## Lessons Learned

1. **AI excels at structural analysis** — Identifying the $Message overwrite, missing Close() calls, and exit code leakage across multiple code paths. These are the kinds of bugs that are easy to miss in manual review.

2. **AI claims about OS behavior must be tested** — The exit code 1115 vs 1190 error demonstrates that AI knowledge about specific Windows behavior can be outdated or imprecise. Always validate with actual testing on target OS versions.

3. **AI is effective as a sounding board for architecture** — The registry marker mechanism, the calendar-day comparison approach, and the Intune/MECM deployment strategy all emerged from back-and-forth discussion where the human set requirements and the AI proposed solutions.

4. **Commit messages benefit from AI drafting** — The AI produced detailed, well-structured commit messages that accurately reflected the changes. Minor formatting preferences (line width) were respected.

5. **The human must drive** — The AI proposed removing the file rename check entirely; the human decided to replace it with the uptime threshold. The AI proposed specific exit code mappings; the human corrected them from testing. Decision authority stayed with the engineer throughout.

6. **Context window management matters** — At 85% context usage, the session is approaching its limit. For long development sessions, consider starting new chats at natural breakpoints (e.g., after a commit) and providing a brief summary of prior decisions to the new session.

## Tools and Environment

- **Editor:** VS Code
- **AI Assistant:** GitHub Copilot (Claude Opus 4.6)
- **OS (development):** Windows
- **Target OS:** Windows Server / Windows 11 23H2 (testing)
- **Deployment targets:** Intune Proactive Remediations, MECM Configuration Baselines
- **Source control:** Git, feature branch workflow
