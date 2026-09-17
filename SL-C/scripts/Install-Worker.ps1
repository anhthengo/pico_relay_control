<#
.SYNOPSIS
    Registers the BuildEmailWatcherWorker Scheduled Task: runs
    Start-Worker.ps1 as the currently logged-in user (LogonType Interactive),
    triggered at logon, so it has that user's full profile and
    GitHub/Copilot/Graph credentials -- the LocalSystem NSSM service
    (Watch-BuildEmail.ps1) delegates all Copilot invocations to this worker
    via a local file-based job queue instead of running Copilot itself.

.NOTES
    Run this as the SAME user who should own the worker's credentials (i.e.
    your own interactive session), NOT elevated as a different account.
    Run as Administrator only if required by policy to register scheduled
    tasks -- Register-ScheduledTask itself does not require elevation for a
    task that runs as the calling user.
#>

$ErrorActionPreference = 'Stop'

$RepoRoot   = 'C:\git\SL-C'
$Profile    = Get-Content (Join-Path $RepoRoot 'profile.json') -Raw | ConvertFrom-Json
$TaskName   = if ($Profile.worker.taskName) { $Profile.worker.taskName } else { 'BuildEmailWatcherWorker' }
$ScriptPath = Join-Path $RepoRoot 'scripts\Start-Worker.ps1'

# Reject a `pwsh` resolved from %LOCALAPPDATA%\Microsoft\WindowsApps -- that
# is a per-user "app execution alias" reparse-point stub that can fail to
# launch anything even for the interactive user in some configurations (see
# Install-Service.ps1's identical check). Only trust a real, non-WindowsApps
# pwsh install.
$PwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
if ($PwshCmd -and $PwshCmd.Source -notlike '*\WindowsApps\*') {
    $PwshExe = $PwshCmd.Source
} else {
    $PwshExe = (Get-Command powershell).Source
}

$UserId = [Security.Principal.WindowsIdentity]::GetCurrent().Name

$action = New-ScheduledTaskAction `
    -Execute $PwshExe `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $UserId

$principal = New-ScheduledTaskPrincipal `
    -UserId $UserId `
    -LogonType Interactive `
    -RunLevel Limited

# ExecutionTimeLimit defaults to 3 days for a Scheduled Task -- since this
# worker is meant to run indefinitely (like the NSSM service), an unset
# limit here would silently have Task Scheduler kill it after 72 hours with
# no error in our own logs. TimeSpan.Zero means "no limit".
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero)

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description "Credentialed worker: invokes Copilot CLI for BuildEmailWatcher jobs, as $UserId" `
    -Force | Out-Null

Write-Host "Scheduled Task '$TaskName' registered for $UserId (AtLogOn, Interactive logon, no execution time limit)."

# Start it now for the CURRENT session -- AtLogOn only fires on a future
# logon, so without this the worker would not actually run until the next
# time this user logs in.
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 2
$info = Get-ScheduledTaskInfo -TaskName $TaskName
Write-Host "Task last run result: $($info.LastTaskResult) (0 or 267009/STILL_ACTIVE both indicate a running/started task)."
Write-Host "Check status with: Get-ScheduledTask -TaskName $TaskName | Select-Object State"
Write-Host "Tail logs with: Get-Content '$(Join-Path $RepoRoot $Profile.paths.logsDir)\worker.log' -Tail 30 -Wait"
