<#
.SYNOPSIS
    Stops and removes the BuildEmailWatcher NSSM service.
.NOTES
    Requires nssm.exe on PATH. Run as Administrator.
#>

$ErrorActionPreference = 'Stop'
$ServiceName = 'BuildEmailWatcher'
$Nssm        = 'nssm'

& $Nssm stop $ServiceName
if ($LASTEXITCODE -ne 0) {
    Write-Warning "nssm stop exited with code $LASTEXITCODE (service may already be stopped) -- continuing to remove."
}
& $Nssm remove $ServiceName confirm
if ($LASTEXITCODE -ne 0) {
    throw "nssm remove failed with exit code $LASTEXITCODE"
}
Write-Host "Service '$ServiceName' removed."
