READ-SAMLOG QUICK START

Use Windows PowerShell 5.1 (powershell.exe), not PowerShell 7 (pwsh.exe).
The logger is standalone, but this distributed script is NOT digitally signed.

IF WINDOWS REPORTS "IS NOT DIGITALLY SIGNED"

In the Windows PowerShell window where you will run it, check:

    Get-ExecutionPolicy
    Get-ExecutionPolicy -List

If the effective policy is RemoteSigned, review the script and verify that you
trust its source before unblocking that specific file. For the reported folder:

    Unblock-File -LiteralPath '<script location>\Read-SamLog.ps1' -Confirm

Replace the path if you extracted it somewhere else. Run the command in the
console, not inside another unsigned script. This removes the download marker;
it does not change execution policy or create a signature.

If the effective policy is AllSigned, ask the author/IT for an organization-
trusted Authenticode-signed copy. Unblock-File cannot satisfy AllSigned.
If it is Restricted, or organizational controls still block the script, use IT's
approved deployment process. Do not bypass or weaken managed execution policies.
The script cannot fix a policy block because Windows checks it before execution.

RUN THE LOGGER

Change to the extracted directory. Replace 42 and the export path with your
SAM debug COM port and the export matching the firmware running on the device:

    .\Read-SamLog.ps1 -ComPort 42 -SamExportPath 'C:\Firmware\SAM_EXPORT.xml'

Optional file logging (the log file must not already exist):

    .\Read-SamLog.ps1 -ComPort 42 -SamExportPath 'C:\Firmware\SAM_EXPORT.xml' -LogPath '.\sam.log'

Defaults: 3,000,000 baud, 8N1. Stop with Ctrl+C to close the port and log files.
Defmt messages show [INFO], [ERROR], [WARN], [DEBUG], or [TRACE] before their
message text when the firmware supplies a level.

After replacing/updating Read-SamLog.ps1, open a new Windows PowerShell window
so that its embedded decoder types are reloaded.
See README.md for parameters, export compatibility, and policy guidance.
