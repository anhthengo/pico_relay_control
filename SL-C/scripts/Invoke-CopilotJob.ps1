<#
.SYNOPSIS
    Thin wrapper that runs the Copilot CLI and re-exits with its exact
    $LASTEXITCODE.

.NOTES
    Exists because reading `[System.Diagnostics.Process].ExitCode` directly
    off a `copilot.exe` process launched via `Start-Process -PassThru` was
    observed to come back null/unreadable for real, long-running
    `--allow-all-tools --agent ...` invocations (even after `WaitForExit()`
    + `Refresh()`), despite the invocation completing all of its work
    correctly. Trivial/fast invocations (`--version`, `cmd.exe /c exit 0`)
    did NOT show this problem via the same Start-Process/.ExitCode pattern,
    so the issue appears specific to something about how copilot.exe exits
    after a long real session (e.g. an internal relaunch/supervisor
    mechanism), not the general approach.

    Wrapping the call in a plain powershell.exe host process sidesteps
    this: powershell.exe's own process exit is simple/standard, so
    Process.ExitCode read off *this* wrapper process (which explicitly
    forwards $LASTEXITCODE) has proven reliable, even though reading it off
    copilot.exe directly was not.
#>
param(
    [Parameter(Mandatory = $true)][string]$CopilotExe,
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$AgentName,
    [Parameter(Mandatory = $true)][string]$Prompt,
    [Parameter(Mandatory = $true)][string]$ExitCodeSentinelPath
)

# --context long_context requests the largest available context-window
# tier (up to ~1M tokens on models that support it) -- worth it here since
# this invocation gets a full report/log/test-output dump in one shot with
# no human able to /compact mid-run if it runs long.
& $CopilotExe -p $Prompt --agent $AgentName --add-dir $RepoRoot --allow-all-tools --context long_context
$ec = $LASTEXITCODE
# Belt-and-suspenders: even a plain powershell.exe wrapper process's own
# Process.ExitCode was observed to be unreadable (null after WaitForExit +
# Refresh) when launched from inside the Scheduled-Task worker context --
# something specific to that launching context, not to copilot.exe or to
# .NET's usual Process quirks. Writing the real exit code to a sentinel
# file from INSIDE this process (which definitely has an accurate
# $LASTEXITCODE) sidesteps that entirely; the caller reads this file
# instead of trusting Process.ExitCode.
Set-Content -LiteralPath $ExitCodeSentinelPath -Value $ec -Encoding utf8 -NoNewline
exit $ec
