<#
.SYNOPSIS
    Stops and unregisters the BuildEmailWatcherWorker Scheduled Task.
#>

$ErrorActionPreference = 'Stop'

$RepoRoot = 'C:\git\SL-C'
$Profile  = Get-Content (Join-Path $RepoRoot 'profile.json') -Raw | ConvertFrom-Json
$TaskName = if ($Profile.worker.taskName) { $Profile.worker.taskName } else { 'BuildEmailWatcherWorker' }

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $task) {
    Write-Host "Scheduled Task '$TaskName' is not registered -- nothing to do."
    return
}

Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
Write-Host "Scheduled Task '$TaskName' stopped and removed."
