<#
.SYNOPSIS
    Installs and configures the BuildEmailWatcher NSSM service:
    auto-start on boot, restart on failure, and log redirection.

.NOTES
    Requires nssm.exe on PATH (or edit $Nssm below). Run as Administrator.
#>

$ErrorActionPreference = 'Stop'

$ServiceName = 'BuildEmailWatcher'
$Nssm        = 'nssm'  # or full path to nssm.exe
$RepoRoot    = 'C:\git\SL-C'
$Profile     = Get-Content (Join-Path $RepoRoot 'profile.json') -Raw | ConvertFrom-Json

# Get-Command's null-conditional (?.) requires PowerShell 7+; use an
# explicit check so this also works under Windows PowerShell 5.1.
# Reject a `pwsh` resolved from %LOCALAPPDATA%\Microsoft\WindowsApps -- that
# is a per-user "app execution alias" reparse-point stub (created even when
# PowerShell 7 was never actually installed, e.g. only made available via the
# Store), and it does not work for services/LocalSystem: the stub silently
# fails to launch anything, leaving NSSM's START control reporting
# SERVICE_STOPPED with zero output, since the real script never even starts.
# Only trust a `pwsh` that resolves to a real, non-WindowsApps install.
$PwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
if ($PwshCmd -and $PwshCmd.Source -notlike '*\WindowsApps\*') {
    $PwshExe = $PwshCmd.Source
} else {
    $PwshExe = (Get-Command powershell).Source
}
$ScriptPath  = Join-Path $RepoRoot 'scripts\Watch-BuildEmail.ps1'
# Read logsDir from profile.json rather than hardcoding -- Watch-BuildEmail.ps1
# reads the same value, and a mismatch would silently split service logs
# from watcher/copilot-output logs into two different directories.
$LogDir      = Join-Path $RepoRoot $Profile.paths.logsDir

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

# One-time setup prompts: comPort for the relay control tool and comPort
# for the SAM debug logger are the only hardware values that vary per
# machine -- everything else in relayTest/samLog is a fixed standard
# value (see README). Prompt only if still a REPLACE_ME placeholder, so
# reinstalling/repairing the service never re-prompts or clobbers a value
# that's already been set.
$profilePath   = Join-Path $RepoRoot 'profile.json'
$profileDirty  = $false

if ($Profile.relayTest.comPort -like 'REPLACE_ME*') {
    $relayComPort = Read-Host "Enter the COM port for the relay control device (e.g. COM5)"
    $Profile.relayTest.comPort = $relayComPort
    $profileDirty = $true
}
if ($Profile.samLog.comPort -like 'REPLACE_ME*') {
    $samComPort = Read-Host "Enter the COM port for the SAM debug logger (e.g. COM8)"
    $Profile.samLog.comPort = $samComPort
    $profileDirty = $true
}
if ($profileDirty) {
    $Profile | ConvertTo-Json -Depth 10 | Set-Content -Path $profilePath -Encoding utf8
    Write-Host "Saved COM port setting(s) to profile.json."
}

# nssm.exe returns a non-zero exit code on failure but PowerShell's
# $ErrorActionPreference does not turn a failed *native* command into a
# terminating error -- without this check, a failed `nssm install` would
# fall through to every subsequent `nssm set` silently failing too, ending
# in a misleading "installed" success message. Wrap every NSSM call.
function Invoke-Nssm {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$NssmArgs)
    & $Nssm @NssmArgs
    if ($LASTEXITCODE -ne 0) {
        throw "nssm $($NssmArgs -join ' ') failed with exit code $LASTEXITCODE"
    }
}

Invoke-Nssm install $ServiceName $PwshExe "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""

# Apply a real service identity BEFORE any start -- leaving the NSSM
# default (LocalSystem) in place would mean the service's first execution
# runs unauthenticated (see nssm-reference.md Section 1.5 in the
# automation-helper plugin).
if ($Profile.service.accountName) {
    if (-not $Profile.service.accountPasswordEnvVar) {
        throw "profile.json sets service.accountName but not service.accountPasswordEnvVar -- the password must be supplied via an environment variable, never hardcoded in profile.json or this script."
    }
    $accountPassword = [Environment]::GetEnvironmentVariable($Profile.service.accountPasswordEnvVar)
    if (-not $accountPassword) {
        throw "Environment variable '$($Profile.service.accountPasswordEnvVar)' (named by service.accountPasswordEnvVar) is not set -- cannot configure the service account without it."
    }
    Invoke-Nssm set $ServiceName ObjectName $Profile.service.accountName $accountPassword
    Remove-Variable accountPassword
}

# Auto-start on boot is driven by profile.json (service.autoStartOnBoot)
# rather than always forced, so this honors whatever the user chose. Never
# auto-start if no service account has been configured -- an immediate
# start at this point would run as the NSSM default (LocalSystem).
if ($Profile.service.autoStartOnBoot -and -not $Profile.service.accountName) {
    Write-Warning "service.autoStartOnBoot is true but service.accountName is not set -- skipping auto-start and immediate start. Set a real service account in profile.json, or start the service yourself if the LocalSystem default is intentional."
}
if ($Profile.service.accountName) {
    if ($Profile.service.autoStartOnBoot) {
        Invoke-Nssm set $ServiceName Start SERVICE_AUTO_START
    } else {
        Invoke-Nssm set $ServiceName Start SERVICE_DEMAND_START
    }
} else {
    Invoke-Nssm set $ServiceName Start SERVICE_DEMAND_START
}

# Restart on crash/unexpected exit (throttle so a fast-crash loop backs off).
Invoke-Nssm set $ServiceName AppExit Default Restart
Invoke-Nssm set $ServiceName AppRestartDelay 15000
Invoke-Nssm set $ServiceName AppThrottle 15000

# Redirect NSSM's own stdout/stderr capture (separate from the script's own
# logging in Watch-BuildEmail.ps1) with rotation so logs don't grow forever.
# Note: this rotates ONLY service-stdout.log/service-stderr.log -- the
# watcher.log/copilot-output.log files are rotated independently by
# Watch-BuildEmail.ps1 itself using paths.logMaxBytes.
Invoke-Nssm set $ServiceName AppStdout (Join-Path $LogDir 'service-stdout.log')
Invoke-Nssm set $ServiceName AppStderr (Join-Path $LogDir 'service-stderr.log')
Invoke-Nssm set $ServiceName AppRotateFiles 1
Invoke-Nssm set $ServiceName AppRotateOnline 1
Invoke-Nssm set $ServiceName AppRotateBytes 10485760   # 10 MB

Invoke-Nssm set $ServiceName AppDirectory $RepoRoot

Write-Host "Service '$ServiceName' installed (auto-start: $($Profile.service.autoStartOnBoot), account: $(if ($Profile.service.accountName) { $Profile.service.accountName } else { '(NSSM default, e.g. LocalSystem)' }))."
if ($Profile.service.autoStartOnBoot -and $Profile.service.accountName) {
    Write-Host "Starting it now..."
    Invoke-Nssm start $ServiceName
} elseif ($Profile.service.autoStartOnBoot) {
    Write-Host "Not starting automatically because no service account is configured -- start manually once you've reviewed the account: nssm start $ServiceName"
} else {
    Write-Host "Auto-start is disabled per profile.json -- start manually with: nssm start $ServiceName"
}

Write-Host "Done. Check status with: nssm status $ServiceName"
