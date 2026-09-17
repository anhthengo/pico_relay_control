<#
.SYNOPSIS
    Long-running orchestrator loop for the NSSM service. Runs as LocalSystem
    and NEVER invokes Copilot CLI directly -- LocalSystem has no user
    profile, GitHub/Copilot auth cache, or Graph/workiq credentials, so a
    direct invocation always fails with "No authentication information
    found" regardless of executable path. Instead, each cycle drops a job
    file into a local file-based queue and waits for the credentialed user
    worker (see Start-Worker.ps1, run under a Scheduled Task as the logged-in
    user) to pick it up, run Copilot, and write back a result file.

.NOTES
    This script is intended to be run BY NSSM as the service's managed
    process (see Install-Service.ps1). It must stay in the foreground
    (no & background launch) for NSSM to track/restart it correctly.
#>

$ErrorActionPreference = 'Stop'

$RepoRoot = 'C:\git\SL-C'
$Profile  = Get-Content (Join-Path $RepoRoot 'profile.json') -Raw | ConvertFrom-Json

$LogDir       = Join-Path $RepoRoot $Profile.paths.logsDir
$PollInterval = [TimeSpan]::FromHours($Profile.schedule.pollIntervalHours)
$LogMaxBytes  = if ($Profile.paths.logMaxBytes) { $Profile.paths.logMaxBytes } else { 10MB }
# Ceiling on waiting for the worker to pick up AND complete one job -- keeps
# a stuck/offline worker from blocking the service loop forever.
$CycleTimeoutMinutes = if ($Profile.schedule.cycleTimeoutMinutes) { $Profile.schedule.cycleTimeoutMinutes } else { 120 }
# After this many CONSECUTIVE genuine job failures/timeouts, exit non-zero
# instead of retrying in-process -- this is what actually engages NSSM's
# restart backoff for a persistent problem. A stale/missing worker heartbeat
# does NOT count toward this (see below) -- that's an expected, recoverable
# "user not logged in yet" state, not a service-level failure.
$MaxConsecutiveFailures = if ($Profile.schedule.maxConsecutiveFailures) { $Profile.schedule.maxConsecutiveFailures } else { 5 }

$JobsDir       = Join-Path $RepoRoot $Profile.worker.jobsDir
$PendingDir    = Join-Path $JobsDir 'pending'
$CompletedDir  = Join-Path $JobsDir 'completed'
$HeartbeatPath = Join-Path $JobsDir 'worker-heartbeat.json'
$HeartbeatMaxAgeSeconds = if ($Profile.worker.heartbeatMaxAgeSeconds) { $Profile.worker.heartbeatMaxAgeSeconds } else { 120 }
$JobPollIntervalSeconds = if ($Profile.worker.jobPollIntervalSeconds) { $Profile.worker.jobPollIntervalSeconds } else { 5 }
$CompletedJobMaxAgeHours = if ($Profile.worker.completedJobMaxAgeHours) { $Profile.worker.completedJobMaxAgeHours } else { 24 }

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
New-Item -ItemType Directory -Force -Path $PendingDir | Out-Null
New-Item -ItemType Directory -Force -Path $CompletedDir | Out-Null

# Roll a log file to <name>.log.1 once it exceeds $LogMaxBytes, so
# watcher.log doesn't grow unbounded -- NSSM's own AppRotate* settings
# (configured in Install-Service.ps1) only rotate the wrapper process's
# stdout/stderr, NOT this script-managed log file.
function Invoke-LogRotation {
    param([string]$Path)
    if ((Test-Path $Path) -and (Get-Item $Path).Length -gt $LogMaxBytes) {
        $rolled = "$Path.1"
        Remove-Item $rolled -ErrorAction SilentlyContinue
        Rename-Item $Path $rolled
    }
}

function Write-Log {
    param([string]$Message)
    $logPath = Join-Path $LogDir 'watcher.log'
    Invoke-LogRotation -Path $logPath
    $line = "[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $Message
    Write-Host $line
    # Explicit -Encoding utf8 (NOT Tee-Object, which has no -Encoding
    # parameter in Windows PowerShell 5.1 and defaults to UTF-16/Unicode) --
    # this service is intentionally launched via powershell.exe (Windows
    # PowerShell 5.1; see Install-Service.ps1's pwsh-alias-stub rejection).
    Add-Content -Path $logPath -Value $line -Encoding utf8
}

Write-Log "Watcher service starting (orchestrator-only; job queue at $JobsDir). Poll interval: $PollInterval"

$consecutiveFailures = 0

# Remove old completed-job result files so the queue directory doesn't grow
# unbounded -- results are consumed immediately by the cycle that submitted
# them, so anything left over this long is either from a timed-out cycle
# whose result arrived late, or leftover from a crash.
function Clear-StaleCompletedJobs {
    $cutoff = (Get-Date).AddHours(-$CompletedJobMaxAgeHours)
    Get-ChildItem -LiteralPath $CompletedDir -Filter '*.json' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        Remove-Item -ErrorAction SilentlyContinue
}

while ($true) {
    $cycleFailed = $false
    $countsTowardFailureLimit = $true
    try {
        Clear-StaleCompletedJobs

        # Check the worker's heartbeat BEFORE submitting a job -- submitting
        # into a queue nobody is watching would just silently time out every
        # cycle. A stale/missing heartbeat almost always means the
        # credentialed user is logged out (Start-Worker.ps1's Scheduled Task
        # only runs while that user session exists) -- this is an expected,
        # recoverable condition, not a service malfunction, so it must NOT
        # count toward $MaxConsecutiveFailures (that would eventually make
        # NSSM apply crash-backoff to a perfectly healthy service that's
        # just waiting for someone to log in).
        $heartbeatOk = $false
        if (Test-Path -LiteralPath $HeartbeatPath) {
            try {
                $heartbeat = Get-Content -LiteralPath $HeartbeatPath -Raw | ConvertFrom-Json
                $heartbeatAge = (Get-Date) - [datetime]$heartbeat.timestamp
                if ($heartbeatAge.TotalSeconds -le $HeartbeatMaxAgeSeconds) {
                    $heartbeatOk = $true
                }
            } catch {
                Write-Log "WARNING: could not parse worker heartbeat file: $($_.Exception.Message)"
            }
        }

        if (-not $heartbeatOk) {
            Write-Log "Worker heartbeat missing or stale (>$HeartbeatMaxAgeSeconds s old) -- credentialed worker appears offline (user may be logged out). Skipping this cycle without counting it as a failure."
            $countsTowardFailureLimit = $false
        } else {
            $jobId = [guid]::NewGuid().ToString()
            $jobPath = Join-Path $PendingDir "$jobId.json"
            $resultPath = Join-Path $CompletedDir "$jobId.json"

            $job = @{
                id          = $jobId
                requestedAt = (Get-Date).ToString('o')
            }
            # Write to a temp file then rename -- Start-Worker.ps1 watches
            # $PendingDir for whole files; a partially-written file it picks
            # up mid-write would fail to parse as JSON.
            $tempPath = "$jobPath.tmp"
            $job | ConvertTo-Json | Set-Content -LiteralPath $tempPath -Encoding utf8
            Rename-Item -LiteralPath $tempPath -NewName (Split-Path -Leaf $jobPath)

            Write-Log "Submitted job $jobId. Waiting up to $CycleTimeoutMinutes minutes for the worker to complete it..."

            $deadline = (Get-Date).AddMinutes($CycleTimeoutMinutes)
            $result = $null
            while ((Get-Date) -lt $deadline) {
                if (Test-Path -LiteralPath $resultPath) {
                    Start-Sleep -Milliseconds 250  # let the worker's writer fully flush/rename
                    try {
                        $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
                        break
                    } catch {
                        # Result file exists but isn't valid JSON yet (rare
                        # race with the worker's own write); keep polling.
                    }
                }
                Start-Sleep -Seconds $JobPollIntervalSeconds
            }

            if (-not $result) {
                Write-Log "ERROR: worker did not complete job $jobId within $CycleTimeoutMinutes minutes -- treating as a cycle failure. (If the worker finishes it late, the stale result will just age out of $CompletedDir.)"
                $cycleFailed = $true
            } elseif ($result.status -eq 'succeeded') {
                Write-Log "Cycle complete (job $jobId succeeded, exit code $($result.exitCode))."
                Remove-Item -LiteralPath $resultPath -ErrorAction SilentlyContinue
            } else {
                Write-Log "Job $jobId reported status '$($result.status)' (exit code $($result.exitCode)): $($result.message)"
                $cycleFailed = $true
                Remove-Item -LiteralPath $resultPath -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
        Write-Log "ERROR during watch cycle: $($_.Exception.Message)"
        $cycleFailed = $true
    }

    if ($cycleFailed -and $countsTowardFailureLimit) {
        $consecutiveFailures++
        if ($consecutiveFailures -ge $MaxConsecutiveFailures) {
            Write-Log "FATAL: $consecutiveFailures consecutive failed cycles -- exiting non-zero so NSSM applies its restart backoff instead of hot-looping in-process."
            exit 1
        }
    } elseif (-not $cycleFailed) {
        $consecutiveFailures = 0
    }

    Write-Log "Sleeping $PollInterval until next check."
    Start-Sleep -Seconds $PollInterval.TotalSeconds
}
