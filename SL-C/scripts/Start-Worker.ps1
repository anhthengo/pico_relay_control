<#
.SYNOPSIS
    Long-running credentialed worker loop. Runs under a Scheduled Task
    (see Install-Worker.ps1) as the interactively logged-on user, so it has
    that user's full profile, GitHub/Copilot auth cache, and Graph/workiq
    credentials -- unlike the LocalSystem NSSM service (Watch-BuildEmail.ps1),
    which cannot invoke Copilot directly for exactly that reason.

    Watches a local file-based job queue for work submitted by the service:
    picks up each job file from jobs\pending, invokes the Copilot CLI
    headlessly per the build-email-watcher agent instructions, and writes a
    result file to jobs\completed. Also writes a periodic heartbeat file so
    the service can detect whether this worker (and therefore the logged-in
    user session it depends on) is actually available.

.NOTES
    Intended to run continuously in the foreground under the Scheduled Task
    (no & background launch) so Task Scheduler can track/restart it.
    This process is the ONLY one in this pipeline that should ever touch
    Copilot/GitHub/Graph credentials -- keep credential-requiring logic here,
    not in Watch-BuildEmail.ps1.
#>

$ErrorActionPreference = 'Stop'

$RepoRoot = 'C:\git\SL-C'
$Profile  = Get-Content (Join-Path $RepoRoot 'profile.json') -Raw | ConvertFrom-Json

$LogDir = Join-Path $RepoRoot $Profile.paths.logsDir
$LogMaxBytes = if ($Profile.paths.logMaxBytes) { $Profile.paths.logMaxBytes } else { 10MB }

$JobsDir      = Join-Path $RepoRoot $Profile.worker.jobsDir
$PendingDir   = Join-Path $JobsDir 'pending'
$ProcessingDir = Join-Path $JobsDir 'processing'
$CompletedDir = Join-Path $JobsDir 'completed'
$HeartbeatPath = Join-Path $JobsDir 'worker-heartbeat.json'
$HeartbeatIntervalSeconds = if ($Profile.worker.heartbeatIntervalSeconds) { $Profile.worker.heartbeatIntervalSeconds } else { 30 }
$JobPollIntervalSeconds = if ($Profile.worker.jobPollIntervalSeconds) { $Profile.worker.jobPollIntervalSeconds } else { 5 }
# Reuse the same cycle timeout the service uses to wait for us, as the
# ceiling for how long we let a single `copilot` invocation run before we
# kill it -- keeps the two in sync without a second config value to drift.
$CycleTimeoutMinutes = if ($Profile.schedule.cycleTimeoutMinutes) { $Profile.schedule.cycleTimeoutMinutes } else { 120 }

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
New-Item -ItemType Directory -Force -Path $PendingDir | Out-Null
New-Item -ItemType Directory -Force -Path $ProcessingDir | Out-Null
New-Item -ItemType Directory -Force -Path $CompletedDir | Out-Null

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
    $logPath = Join-Path $LogDir 'worker.log'
    Invoke-LogRotation -Path $logPath
    $line = "[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $Message
    Write-Host $line
    Add-Content -Path $logPath -Value $line -Encoding utf8
}

# Resolve the Copilot CLI executable once, at startup. Prefer an explicit
# copilot.exePath from profile.json (avoids relying on this process's PATH,
# which for a Scheduled Task can differ subtly from an interactive shell's);
# fall back to bare 'copilot' (PATH lookup) if unset.
$CopilotExe = if ($Profile.copilot.exePath) { $Profile.copilot.exePath } else { 'copilot' }
if ($Profile.copilot.exePath -and -not (Test-Path -LiteralPath $Profile.copilot.exePath)) {
    Write-Log "WARNING: profile.json copilot.exePath '$($Profile.copilot.exePath)' does not exist on disk -- job invocations below will likely fail to launch."
}

Write-Log "Worker starting as $(whoami) (job queue at $JobsDir)."

# Kill a process and its full descendant tree. Start-Process launches
# `copilot` directly, but `copilot` itself may spawn child processes (e.g.
# MCP servers, tool subprocesses); Stop-Process on just the parent PID can
# leave those orphaned and still running after a timeout-triggered kill.
# Shared with the build-email-watcher agent's own test.ps1 invocation (see
# scripts/Stop-ProcessTree.ps1) so there is one definition, not two that can
# drift apart.
. (Join-Path $RepoRoot 'scripts\Stop-ProcessTree.ps1')

function Write-Heartbeat {
    $heartbeat = @{ timestamp = (Get-Date).ToString('o'); pid = $PID }
    $tempPath = "$HeartbeatPath.tmp"
    $heartbeat | ConvertTo-Json | Set-Content -LiteralPath $tempPath -Encoding utf8
    Move-Item -LiteralPath $tempPath -Destination $HeartbeatPath -Force
}

function Invoke-BuildWatcherJob {
    param([string]$JobId)

    $cycleOutputPath = Join-Path $LogDir 'copilot-output.current.log'
    $cycleErrorPath  = "$cycleOutputPath.err"
    $persistentOutputPath = Join-Path $LogDir 'copilot-output.log'
    $persistentErrorPath  = "$persistentOutputPath.err"
    $exitCodeSentinelPath = Join-Path $LogDir "exitcode-$JobId.txt"
    Remove-Item -LiteralPath $exitCodeSentinelPath -ErrorAction SilentlyContinue

    # Headless, non-interactive Copilot CLI invocation, run via a plain
    # powershell.exe wrapper (Invoke-CopilotJob.ps1) rather than launching
    # copilot.exe directly. Exit code is read from a sentinel FILE the
    # wrapper writes from inside itself (using its own accurate
    # $LASTEXITCODE), not from Process.ExitCode on the $proc handle below
    # -- reading .ExitCode directly (even after WaitForExit()+Refresh(),
    # and even off a plain powershell.exe wrapper rather than copilot.exe
    # itself) was repeatedly observed to come back null/unreadable when
    # launched from inside this Scheduled-Task worker context, despite the
    # underlying work completing correctly. WaitForExit() below is still
    # used for blocking/timeout control, just not as the source of truth
    # for the exit code.
    $wrapperScript = Join-Path $RepoRoot 'scripts\Invoke-CopilotJob.ps1'
    $prompt = 'Check for a new build email and process it per the build-email-watcher agent instructions.'
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$wrapperScript`""
        '-CopilotExe', "`"$CopilotExe`""
        '-RepoRoot', "`"$RepoRoot`""
        '-AgentName', 'build-email-watcher'
        '-Prompt', "`"$prompt`""
        '-ExitCodeSentinelPath', "`"$exitCodeSentinelPath`""
    ) -NoNewWindow -PassThru `
      -RedirectStandardOutput $cycleOutputPath `
      -RedirectStandardError $cycleErrorPath

    $exited = $proc.WaitForExit($CycleTimeoutMinutes * 60 * 1000)
    if (-not $exited) {
        Write-Log "ERROR: copilot invocation for job $JobId exceeded $CycleTimeoutMinutes-minute timeout -- killing process tree rooted at $($proc.Id)."
        Stop-ProcessTree -ProcessId $proc.Id
        $status = 'timeout'
        $exitCode = $null
        $message = "copilot invocation exceeded $CycleTimeoutMinutes-minute timeout"
    } else {
        $exitCode = $null
        if (Test-Path -LiteralPath $exitCodeSentinelPath) {
            $sentinelText = (Get-Content -LiteralPath $exitCodeSentinelPath -Raw).Trim()
            $parsed = 0
            if ([int]::TryParse($sentinelText, [ref]$parsed)) { $exitCode = $parsed }
            Remove-Item -LiteralPath $exitCodeSentinelPath -ErrorAction SilentlyContinue
        }
        if ($null -eq $exitCode) {
            Write-Log "WARNING: Job ${JobId}: process exited but no readable exit-code sentinel file was found -- treating as failed rather than guessing success."
            $status = 'failed'
            $message = 'copilot process exited but its exit code could not be determined'
        } elseif ($exitCode -ne 0) {
            Write-Log "Job ${JobId}: copilot exited with code $exitCode (see copilot-output.log)"
            $status = 'failed'
            $message = "copilot exited with code $exitCode"
        } else {
            Write-Log "Job ${JobId}: copilot completed successfully."
            $status = 'succeeded'
            $message = $null
        }
    }

    # Append this cycle's snapshot into the persistent, rotated log, then
    # rotate BEFORE the next job can push it over the limit.
    if (Test-Path $cycleOutputPath) {
        Get-Content $cycleOutputPath -Raw | Add-Content -Path $persistentOutputPath
        Remove-Item $cycleOutputPath -ErrorAction SilentlyContinue
    }
    if (Test-Path $cycleErrorPath) {
        Get-Content $cycleErrorPath -Raw | Add-Content -Path $persistentErrorPath
        Remove-Item $cycleErrorPath -ErrorAction SilentlyContinue
    }
    Invoke-LogRotation -Path $persistentOutputPath
    Invoke-LogRotation -Path $persistentErrorPath

    return @{
        jobId    = $JobId
        status   = $status
        exitCode = $exitCode
        message  = $message
    }
}

$lastHeartbeat = [datetime]::MinValue

while ($true) {
    if (((Get-Date) - $lastHeartbeat).TotalSeconds -ge $HeartbeatIntervalSeconds) {
        try {
            Write-Heartbeat
            $lastHeartbeat = Get-Date
        } catch {
            Write-Log "WARNING: failed to write heartbeat: $($_.Exception.Message)"
        }
    }

    $pendingJobs = Get-ChildItem -LiteralPath $PendingDir -Filter '*.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime

    foreach ($jobFile in $pendingJobs) {
        $jobId = [System.IO.Path]::GetFileNameWithoutExtension($jobFile.Name)
        $processingPath = Join-Path $ProcessingDir $jobFile.Name
        try {
            # Atomic claim -- move out of $PendingDir so a second worker
            # instance (there shouldn't normally be one, but a Scheduled
            # Task restart racing an old instance's shutdown is possible)
            # can never double-process the same job.
            Move-Item -LiteralPath $jobFile.FullName -Destination $processingPath -ErrorAction Stop
        } catch {
            if (Test-Path -LiteralPath $jobFile.FullName) {
                # The source file is STILL there, so this wasn't a genuine
                # race with another worker claiming it first -- it's a real
                # error (bad path, permissions, etc). Log it instead of
                # silently retrying forever, which is what let a prior
                # Rename-Item/-Destination bug (invalid parameter -- fixed
                # to Move-Item) go unnoticed: the job just sat in $PendingDir
                # forever with no error anywhere.
                Write-Log "ERROR: failed to claim job $jobId (file still present in pending -- not a claim race): $($_.Exception.Message)"
            }
            continue  # otherwise: another worker instance claimed it first
        }

        Write-Log "Claimed job $jobId."
        try {
            $result = Invoke-BuildWatcherJob -JobId $jobId
        } catch {
            $result = @{ jobId = $jobId; status = 'error'; exitCode = $null; message = $_.Exception.Message }
            Write-Log "ERROR processing job $jobId : $($_.Exception.Message)"
        }

        $resultPath = Join-Path $CompletedDir "$jobId.json"
        $tempResultPath = "$resultPath.tmp"
        $result | ConvertTo-Json | Set-Content -LiteralPath $tempResultPath -Encoding utf8
        Move-Item -LiteralPath $tempResultPath -Destination $resultPath -Force
        Remove-Item -LiteralPath $processingPath -ErrorAction SilentlyContinue
    }

    Start-Sleep -Seconds $JobPollIntervalSeconds
}
