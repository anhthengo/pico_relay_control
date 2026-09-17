<#
.SYNOPSIS
    Runs the smart-charger relay toggle test via host_control.py (flips the
    relay with `toggle`, verifies the physical relay state via `status`),
    and confirms the device itself initiated/tore down charging by tailing
    the SAM debug log (via Read-SamLog.ps1) for a matching "surflink:
    Connected" / "surflink: Disconnected" message after each toggle -- not
    just that the relay flipped.

.PARAMETER BuildId
    The build identifier extracted from the build-notification email.

.NOTES
    Must exit 0 on overall success and non-zero on overall failure so the
    watcher agent can tell pass from fail.

    host_control.py's port/duration/loops and Read-SamLog.ps1's port/export
    path are the standard values from profile.json -> relayTest / samLog.
    Only the two comPort values vary per machine (prompted once during
    setup by Install-Service.ps1) -- everything else stays fixed across
    runs/auto-recovery.

    Each host_control.py invocation is a single one-shot command (toggle /
    status) with no interactive console session required -- no "toggle on"
    prompt to send like the older SL.exe tool -- so each call can be driven
    straightforwardly and its exit code/output checked directly.

    `toggle` flips the relay relative to whatever state it's currently in
    (there is no separate on/off command) -- so the expected post-toggle
    state is tracked locally (starting from an initial `status` read) and
    flipped in lockstep with each `toggle` call, rather than assumed from
    the loop index.

    Read-SamLog.ps1 is launched ONCE for the whole test run (not per
    toggle) and left tailing the SAM debug port to a log file. After each
    toggle+dwell the script polls that file (for up to
    chargerConnectTimeoutSeconds/chargerDisconnectTimeoutSeconds) for a
    line matching samLog.connectMessageFilters (relay ON) or
    samLog.disconnectMessageFilters (relay OFF) -- there is a chatty
    identify/negotiate (or teardown) sequence before the confirming
    message appears, so a single immediate check right after the toggle is
    not sufficient. This confirms the device's own firmware saw the
    charger connect/disconnect, which the relay toggling itself +
    host_control.py's status readback cannot prove.

    Every toggle's SL:/Power SS: chatter (matching $DiagnosticLinePattern)
    is saved under runs\<buildId>\sam-chatter\: the FIRST successful
    connect/disconnect is kept as reference-connect.log /
    reference-disconnect.log (known-good baseline), and every failed
    connect/disconnect's chatter is saved as loop-<n>-connect-FAILED.log /
    loop-<n>-disconnect-FAILED.log. The report-writing agent can diff a
    failure's chatter against the reference file to spot what's missing
    or different, rather than only seeing "no match found."
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$BuildId
)

$ErrorActionPreference = 'Stop'

$RepoRoot = 'C:\git\SL-C'
$Profile  = Get-Content (Join-Path $RepoRoot 'profile.json') -Raw | ConvertFrom-Json
$Relay    = $Profile.relayTest
$SamLog   = $Profile.samLog

if (-not $Relay.comPort -or $Relay.comPort -like 'REPLACE_ME*') {
    Write-Error "profile.json -> relayTest.comPort is not configured. Set it once during setup (see README) before running tests."
    exit 1
}
if (-not (Test-Path $Relay.controlScriptPath)) {
    Write-Error "host_control.py not found at profile.json -> relayTest.controlScriptPath ('$($Relay.controlScriptPath)')."
    exit 1
}
if (-not $SamLog.comPort -or $SamLog.comPort -like 'REPLACE_ME*') {
    Write-Error "profile.json -> samLog.comPort is not configured. Set it once during setup (see README) before running tests."
    exit 1
}
if (-not $SamLog.samExportPath -or $SamLog.samExportPath -like 'REPLACE_ME*') {
    Write-Error "profile.json -> samLog.samExportPath is not configured. Set it to the SAM_EXPORT.xml matching the firmware under test."
    exit 1
}
if (-not (Test-Path $SamLog.scriptPath)) {
    Write-Error "Read-SamLog.ps1 not found at profile.json -> samLog.scriptPath ('$($SamLog.scriptPath)')."
    exit 1
}
if (-not (Test-Path $SamLog.samExportPath)) {
    Write-Error "SAM export not found at profile.json -> samLog.samExportPath ('$($SamLog.samExportPath)')."
    exit 1
}

function Invoke-RelayControl {
    param([string]$Command)
    $outFile = "$env:TEMP\relay-$Command-$PID-out.txt"
    $errFile = "$env:TEMP\relay-$Command-$PID-err.txt"
    # Quote path-bearing args -- Start-Process -ArgumentList doesn't
    # auto-quote values containing spaces in Windows PowerShell 5.1.
    $proc = Start-Process -FilePath $Relay.pythonExe -ArgumentList @(
        "`"$($Relay.controlScriptPath)`""
        $Relay.comPort
        $Command
    ) -NoNewWindow -PassThru -Wait -RedirectStandardOutput $outFile -RedirectStandardError $errFile

    $stdout = Get-Content $outFile -Raw -ErrorAction SilentlyContinue
    $stderr = Get-Content $errFile -Raw -ErrorAction SilentlyContinue
    Remove-Item $outFile, $errFile -ErrorAction SilentlyContinue

    [PSCustomObject]@{
        ExitCode = $proc.ExitCode
        Output   = "$stdout$stderr".Trim()
    }
}

function Get-RelayState {
    param([string]$StatusOutput)
    if ($StatusOutput -match 'RELAY (ON|OFF)') { return $Matches[1] }
    return $null
}

# Read-SamLog.ps1 refuses to write to a log file that already exists, so
# use a fresh per-run path under the runs dir for this build.
$runDir      = Join-Path (Join-Path $RepoRoot $Profile.paths.runsDir) $BuildId
# Build IDs containing bracket characters (e.g. "[1064_BAA] ...") are
# treated as wildcard patterns by -Path on most path cmdlets, so create
# the directory via .NET, which always treats the path literally.
[System.IO.Directory]::CreateDirectory($runDir) | Out-Null
$samLogPath  = Join-Path $runDir 'sam.log'

Write-Host "==> Starting SAM debug logger on $($SamLog.comPort) -> $samLogPath"
# Windows PowerShell 5.1's Start-Process -ArgumentList just joins array
# elements with spaces -- it does NOT auto-quote values containing spaces
# (unlike pwsh 7+'s ProcessStartInfo.ArgumentList). $samLogPath is derived
# from the build ID, which can contain spaces, so every value-bearing
# argument must be manually double-quoted or a build ID with spaces
# splits into multiple positional args and Read-SamLog.ps1 fails to parse.
$samLogProc = Start-Process -FilePath $SamLog.powershellExe -ArgumentList @(
    '-NoProfile'
    '-ExecutionPolicy', 'Bypass'
    '-File', "`"$($SamLog.scriptPath)`""
    '-ComPort', $SamLog.comPort
    '-SamExportPath', "`"$($SamLog.samExportPath)`""
    '-LogPath', "`"$samLogPath`""
) -NoNewWindow -PassThru

# Give Read-SamLog.ps1 a moment to open the port and start writing before
# the first toggle, so a message logged immediately after toggle #1 isn't
# missed by a logger that hasn't attached yet.
Start-Sleep -Seconds ([int]$SamLog.startupWaitSeconds)
if ($samLogProc.HasExited) {
    Write-Error "Read-SamLog.ps1 exited immediately (exit code $($samLogProc.ExitCode)) -- check the SAM debug COM port and export path in profile.json."
    exit 1
}

# Tracks how much of sam.log has already been scanned, so each toggle only
# checks lines added since the previous check rather than re-matching
# (and potentially double-counting) earlier output.
$samLogLinesSeen = 0

# Matches the "<timestamp> <uptime> [LEVEL] SL: ..." / "... Power SS: ..."
# line shapes the device emits -- these are the lines worth surfacing as
# diagnostic context on a timeout, since they're the ones directly related
# to the Surflink state machine and power-source status reporting (as
# opposed to unrelated firmware chatter also present in the log). Actual
# line shape: "2026-09-16 19:57:34.834 -07:00 15675.845205 [INFO] SL: ...".
# (A previous, differently-shaped pattern never matched this format at all
# -- every chatter file silently said "no SL:/Power SS: lines seen" even
# when the raw sam.log clearly had them.)
$DiagnosticLinePattern = '\[[A-Za-z]+\]\s*(SL|Power SS):'

# Each SAM log line starts with a parseable local timestamp
# ("yyyy-MM-dd HH:mm:ss.fff -07:00 ..."); used to trim saved chatter down
# to the seconds immediately relevant to a toggle instead of the whole
# (up to chargerConnect/DisconnectTimeoutSeconds-long) polling window.
$SamLogTimestampPattern = '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})'

function Get-SamLogLineTimestamp {
    param([string]$Line)
    if ($Line -match $SamLogTimestampPattern) {
        try { return [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss.fff', $null) } catch { return $null }
    }
    return $null
}

function Limit-ToTrailingWindow {
    # Keeps only the lines within $WindowSeconds of the LAST timestamped
    # line -- i.e. the chatter immediately preceding the match/timeout,
    # which is what's diagnostically relevant, rather than the full
    # (potentially tens-of-seconds-long) polling window. Keeps this small
    # deliberately: these lines get read into an LLM agent's own context
    # later when writing the report, and an unbounded chatter dump was
    # observed to bloat that turn enough to risk a context compaction.
    param([string[]]$Lines, [int]$WindowSeconds = 3)
    if (-not $Lines -or $Lines.Count -eq 0) { return $Lines }
    $timestamps = $Lines | ForEach-Object { Get-SamLogLineTimestamp $_ }
    $lastTimestamp = ($timestamps | Where-Object { $_ } | Select-Object -Last 1)
    if (-not $lastTimestamp) { return $Lines }
    $cutoff = $lastTimestamp.AddSeconds(-$WindowSeconds)
    $result = @()
    for ($idx = 0; $idx -lt $Lines.Count; $idx++) {
        $ts = $timestamps[$idx]
        if (-not $ts -or $ts -ge $cutoff) { $result += $Lines[$idx] }
    }
    return $result
}

function Get-NewSamLogLines {
    # Returns all newly-seen lines (since the last call) as an array (may
    # be empty), advancing $script:samLogLinesSeen so a caller polling in
    # a loop never re-scans the same lines twice.
    $lines = Get-Content -LiteralPath $samLogPath -ErrorAction SilentlyContinue
    if (-not $lines -or $lines.Count -le $script:samLogLinesSeen) { return @() }
    $newLines = $lines[$script:samLogLinesSeen..($lines.Count - 1)]
    $script:samLogLinesSeen = $lines.Count
    return $newLines
}

function Wait-ForSamLogMessage {
    # The device goes through a chatty identify/negotiate (on relay-ON) or
    # teardown (on relay-OFF) sequence before logging the confirming
    # message (e.g. "surflink: Connected" / "surflink: Disconnected"), so a
    # single immediate check after the toggle is not enough -- poll for up
    # to TimeoutSeconds, checking newly-appended log lines as they arrive.
    #
    # Success is ONLY a line matching $Filters (the exact Connected/
    # Disconnected confirmation). On timeout/failure, returns the SL:/
    # Power SS: lines seen during the window as diagnostic context, since
    # those are what a human would need to see to tell why the device
    # didn't confirm the toggle.
    #
    # NOTE on matchMode 'all': the required filters (e.g. "surflink:
    # Connected", "SurflinkDeviceState::ConnectedAsConsumer", "Charger:
    # Consumer Power connected") are emitted by the device as SEPARATE SAM
    # log lines, not all on one line. So "all" matching is done by tracking
    # which filters have been satisfied by ANY line seen so far in the
    # window, not by requiring a single line to contain every filter --
    # the latter would never match and would always time out.
    param([string[]]$Filters, [int]$TimeoutSeconds)
    $seenLines = [System.Collections.Generic.List[string]]::new()
    $matchedLines = @{}
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        foreach ($line in (Get-NewSamLogLines)) {
            $seenLines.Add($line)
            foreach ($filter in $Filters) {
                if (-not $matchedLines.ContainsKey($filter) -and $line -imatch [regex]::Escape($filter)) {
                    $matchedLines[$filter] = $line
                }
            }
            $isMatch = if ($SamLog.matchMode -eq 'any') {
                $matchedLines.Count -gt 0
            } else {
                $matchedLines.Count -eq $Filters.Count
            }
            if ($isMatch) {
                $diagnosticLines = Limit-ToTrailingWindow -Lines ($seenLines | Where-Object { $_ -match $DiagnosticLinePattern })
                $summaryLine = ($Filters | ForEach-Object { $matchedLines[$_] } | Where-Object { $_ }) -join ' | '
                return [PSCustomObject]@{ Matched = $true; Line = $summaryLine; DiagnosticLines = $diagnosticLines }
            }
        }
        if ((Get-Date) -ge $deadline) { break }
        Start-Sleep -Milliseconds 250
    }
    $diagnosticLines = Limit-ToTrailingWindow -Lines ($seenLines | Where-Object { $_ -match $DiagnosticLinePattern })
    return [PSCustomObject]@{ Matched = $false; Line = $null; DiagnosticLines = $diagnosticLines }
}

try {
    Write-Host "==> Running relay toggle test for build $BuildId"
    Write-Host "==> host_control.py on $($Relay.comPort), $($Relay.toggleLoops) toggles, $($Relay.toggleDurationSeconds)s dwell"
    Write-Host "==> Verifying device-side charger messages -- connect: $($SamLog.connectMessageFilters -join ', ') (timeout $($SamLog.chargerConnectTimeoutSeconds)s), disconnect: $($SamLog.disconnectMessageFilters -join ', ') (timeout $($SamLog.chargerDisconnectTimeoutSeconds)s), mode: $($SamLog.matchMode)"

    $failures = @()

    # Reference ("known-good") SL:/Power SS: chatter captured on the FIRST
    # successful connect and disconnect -- saved to disk so the report-
    # writing agent can diff a later failure's chatter against what a
    # normal, working toggle actually looks like. Only the first of each
    # is kept (repeat successes aren't reference material, just noise).
    $referenceConnectSaved    = $false
    $referenceDisconnectSaved = $false
    $chatterDir = Join-Path $runDir 'sam-chatter'
    [System.IO.Directory]::CreateDirectory($chatterDir) | Out-Null

    function Save-SamChatter {
        param([string]$FileName, [string[]]$Lines)
        $path = Join-Path $chatterDir $FileName
        if (-not $Lines -or $Lines.Count -eq 0) {
            Set-Content -LiteralPath $path -Value '(no SL:/Power SS: lines seen)'
        } else {
            Set-Content -LiteralPath $path -Value $Lines
        }
        return $path
    }

    # Establish the starting state so each toggle's expected result is known
    # in advance -- `toggle` flips relative to current state, it doesn't set
    # an absolute on/off.
    $initialStatus = Invoke-RelayControl -Command 'status'
    Write-Host $initialStatus.Output
    if ($initialStatus.ExitCode -ne 0) {
        Write-Error "Initial 'status' command exited $($initialStatus.ExitCode): $($initialStatus.Output)"
        exit 1
    }
    $currentState = Get-RelayState -StatusOutput $initialStatus.Output
    if (-not $currentState) {
        Write-Error "Could not parse relay state from initial status output: $($initialStatus.Output)"
        exit 1
    }

    # Consume any SAM log lines accumulated before the first toggle so
    # they aren't mistaken for evidence of a real charger-init event.
    Get-NewSamLogLines | Out-Null

    for ($i = 1; $i -le [int]$Relay.toggleLoops; $i++) {
        $expectedState = if ($currentState -eq 'ON') { 'OFF' } else { 'ON' }
        Write-Host "[Loop $i/$($Relay.toggleLoops)] Toggling relay ($currentState -> $expectedState)"

        $toggleResult = Invoke-RelayControl -Command 'toggle'
        Write-Host $toggleResult.Output
        if ($toggleResult.ExitCode -ne 0) {
            $failures += "Loop ${i}: 'toggle' command exited $($toggleResult.ExitCode): $($toggleResult.Output)"
            continue
        }

        Start-Sleep -Seconds ([int]$Relay.toggleDurationSeconds)

        # Verify the relay actually changed state, not just that the command
        # returned 0 -- a status call that doesn't show the expected state
        # means the relay didn't respond to the toggle.
        $statusResult = Invoke-RelayControl -Command 'status'
        Write-Host $statusResult.Output
        if ($statusResult.ExitCode -ne 0) {
            $failures += "Loop ${i}: 'status' command exited $($statusResult.ExitCode): $($statusResult.Output)"
            continue
        }
        $observedState = Get-RelayState -StatusOutput $statusResult.Output
        if ($observedState -ne $expectedState) {
            $failures += "Loop ${i}: expected 'RELAY $expectedState' after toggle, got: $($statusResult.Output)"
            # Resync to whatever the relay actually reports, so a single missed
            # toggle doesn't cascade into every subsequent loop being flagged.
            if ($observedState) { $currentState = $observedState }
        } else {
            $currentState = $observedState
        }

        # Confirm the device itself saw the charger connect/disconnect --
        # not just that the relay physically flipped. Success is strictly
        # the exact "surflink: Connected"/"Disconnected" confirmation;
        # on a timeout, surface the SL:/Power SS: lines seen in that
        # window as diagnostic context for why the device didn't confirm.
        if ($observedState -eq 'ON') {
            $waitResult = Wait-ForSamLogMessage -Filters $SamLog.connectMessageFilters -TimeoutSeconds ([int]$SamLog.chargerConnectTimeoutSeconds)
            if (-not $waitResult.Matched) {
                $diagText = if ($waitResult.DiagnosticLines.Count -gt 0) { ($waitResult.DiagnosticLines -join "`n    ") } else { '(no SL:/Power SS: lines seen)' }
                $chatterPath = Save-SamChatter -FileName "loop-$i-connect-FAILED.log" -Lines $waitResult.DiagnosticLines
                $failures += "Loop ${i}: relay reported ON, but no SAM log message matching $($SamLog.connectMessageFilters -join ' + ') was seen within $($SamLog.chargerConnectTimeoutSeconds)s -- device may not have detected/initiated charging. Chatter saved to $chatterPath.`n    $diagText"
            } else {
                Write-Host "  SAM log confirmed connect: $($waitResult.Line)"
                if (-not $referenceConnectSaved) {
                    Save-SamChatter -FileName 'reference-connect.log' -Lines $waitResult.DiagnosticLines | Out-Null
                    $referenceConnectSaved = $true
                }
            }
        } else {
            $waitResult = Wait-ForSamLogMessage -Filters $SamLog.disconnectMessageFilters -TimeoutSeconds ([int]$SamLog.chargerDisconnectTimeoutSeconds)
            if (-not $waitResult.Matched) {
                $diagText = if ($waitResult.DiagnosticLines.Count -gt 0) { ($waitResult.DiagnosticLines -join "`n    ") } else { '(no SL:/Power SS: lines seen)' }
                $chatterPath = Save-SamChatter -FileName "loop-$i-disconnect-FAILED.log" -Lines $waitResult.DiagnosticLines
                $failures += "Loop ${i}: relay reported OFF, but no SAM log message matching $($SamLog.disconnectMessageFilters -join ' + ') was seen within $($SamLog.chargerDisconnectTimeoutSeconds)s -- device may not have detected the charger disconnect. Chatter saved to $chatterPath.`n    $diagText"
            } else {
                Write-Host "  SAM log confirmed disconnect: $($waitResult.Line)"
                if (-not $referenceDisconnectSaved) {
                    Save-SamChatter -FileName 'reference-disconnect.log' -Lines $waitResult.DiagnosticLines | Out-Null
                    $referenceDisconnectSaved = $true
                }
            }
        }
    }

    if ($failures.Count -gt 0) {
        Write-Host "==> Relay toggle test FAILED for build $BuildId ($($failures.Count) of $($Relay.toggleLoops) loops had problems)"
        $failures | ForEach-Object { Write-Host "  - $_" }
        Write-Host "==> SAM log chatter saved under $chatterDir -- compare reference-connect.log/reference-disconnect.log (known-good) against the loop-*-FAILED.log files when writing the report."
        exit 1
    }

    Write-Host "==> Relay toggle test PASSED for build $BuildId ($($Relay.toggleLoops) toggles, relay state and device-side connect/disconnect messages both verified)"
    Write-Host "==> Reference SAM log chatter saved under $chatterDir (reference-connect.log / reference-disconnect.log)"
    exit 0
}
finally {
    # Read-SamLog.ps1 is a long-running foreground listener with no
    # natural end -- always stop it when the test finishes (pass or
    # fail) so it doesn't keep holding the SAM debug port open.
    if ($samLogProc -and -not $samLogProc.HasExited) {
        Write-Host "==> Stopping SAM debug logger (PID $($samLogProc.Id))"
        Stop-Process -Id $samLogProc.Id -Force -ErrorAction SilentlyContinue
    }
}
