# Build Email Watcher

Watches for a new build-notification email, runs `test.ps1` against that
build, and replies to the thread with a results report - running unattended
as a Windows service.

## How it works

1. **NSSM service** (`BuildEmailWatcher`) runs `scripts\Watch-BuildEmail.ps1`
   continuously. It auto-starts on boot and restarts itself if it crashes.
2. Every **4 hours**, the loop script invokes the Copilot CLI headlessly:
   ```
   copilot -p "..." --agent build-email-watcher --add-dir C:\git\SL-C --allow-all-tools --context long_context
   ```
3. The `build-email-watcher` agent (`.github\agents\build-email-watcher.agent.md`)
   does one pass:
   - Search mail for a thread matching the configured subject pattern + `to:` address.
   - Compare the build ID in that thread to `state\last_processed_build.json`.
   - If new: run `scripts\test.ps1`, build a report, reply to the thread,
     then update the state file.
   - If not new: no-op.

## Layout

| Path | Purpose |
|---|---|
| `profile.json` | **Edit this first.** All environment-specific settings: program name, test title, email subject pattern/recipient, build-ID regex, test script path/args, relay-test hardware config (`relayTest` -- COM port set once at setup, rest standardized), SAM debug log verification config (`samLog` -- COM port set once at setup, message filters, export path), reply mode, poll interval, paths, and the report template. |
| `.github\agents\build-email-watcher.agent.md` | Agent instructions - reads `profile.json` and follows this procedure (search mail, extract build ID, run test, build report, reply, update state). |
| `scripts\test.ps1` | Runs the relay toggle test via `host_control.py` (`profile.json` -> `relayTest`) and confirms device-side charger initiation via `Read-SamLog.ps1` (`profile.json` -> `samLog`). Path is configurable via `profile.json` -> `test.scriptPath` (defaults to `scripts/test.ps1`). |
| `scripts\Watch-BuildEmail.ps1` | The NSSM-managed long-running loop (check -> sleep `profile.json` -> `schedule.pollIntervalHours` -> repeat). |
| `scripts\Install-Service.ps1` | Installs/configures the NSSM service (auto-start, restart-on-crash, log rotation). |
| `scripts\Uninstall-Service.ps1` | Stops and removes the service. |
| `state\last_processed_build.json` | Tracks the last build ID/message already handled, so "new" is well-defined. Path configurable via `profile.json` -> `paths.stateFile`. |
| `runs\<build-id>\` | Archived raw test output + generated report per build (created at run time). Directory configurable via `profile.json` -> `paths.runsDir`. |
| `logs\` | Service and Copilot CLI invocation logs (created at run time). Directory configurable via `profile.json` -> `paths.logsDir`. |

## Setup checklist

0. Install/enable the `automation-helper` plugin (from the `AgencySkills`
   marketplace) so the `/draft-build-report-email` skill it depends on is
   available to the agent.
1. Edit `profile.json`:
   - `programName`, `testTitle`
   - `email.subjectPattern`, `email.toAddress`, `email.buildIdRegex`
   - `test.scriptPath`, `test.argumentsTemplate`, `test.timeoutMinutes`
   - `relayTest.comPort` -- **set this once, during initial setup, and
     leave it untouched afterward.** Everything else in `relayTest`
     (`controlScriptPath`, `pythonExe`, `toggleDurationSeconds`,
     `toggleLoops`) is a fixed standard value for this test and does not
     need to change per-run or on service auto-recovery.
   - `samLog.comPort` -- likewise set once during initial setup (the SAM
     debug port, distinct from the relay's COM port) and left untouched.
   - `samLog.samExportPath` -- path to the `SAM_EXPORT.xml` matching the
     firmware under test (update when the firmware changes).
   - `reply.replyAll`
   - `schedule.pollIntervalHours` (default 4)
   - `reportTemplate` sections, if you want a different report layout
2. `scripts\test.ps1` drives the relay toggle test via `host_control.py`
   (`profile.json` -> `relayTest`) -- each loop calls `toggle` to flip the
   relay, waits `toggleDurationSeconds`, then calls `status` to verify the
   relay actually reports the expected new state before continuing. It
   also checks the SAM debug log (streamed live by `Read-SamLog.ps1`,
   `profile.json` -> `samLog`) for the device's own confirmation: after a
   relay-ON toggle it polls (up to `chargerConnectTimeoutSeconds`) for a
   message matching `samLog.connectMessageFilters` (default: `surflink:
   Connected`), and after a relay-OFF toggle it polls (up to
   `chargerDisconnectTimeoutSeconds`) for `samLog.disconnectMessageFilters`
   (default: `surflink: Disconnected`) -- confirming the device itself
   detected the charger connect/disconnect, not just that the relay
   physically flipped. A poll (rather than a single immediate check) is
   needed because the device logs a chatty identify/negotiate or teardown
   sequence before the confirming message appears. Exits non-zero if any
   toggle/status call fails, reports an unexpected state, or the expected
   SAM log message doesn't appear within its timeout. The SL:/Power SS:
   chatter for each toggle is saved under
   `runs\<build-id>\sam-chatter\` -- the first successful connect/
   disconnect is kept as a `reference-*.log` baseline, and every failed
   attempt's chatter is saved as `loop-<n>-*-FAILED.log`, so the reporting
   agent can diff a failure against known-good chatter instead of only
   seeing "no match found."
3. Ensure `nssm.exe` is installed and on `PATH`.
4. Ensure the account the service runs as is signed in / has valid mail
   MCP credentials for headless Copilot CLI use (test manually first with
   `copilot -p ... --agent build-email-watcher --allow-all-tools` in an
   interactive shell before wiring up the service).
5. Run `scripts\Install-Service.ps1` as Administrator. It will prompt once
   for the relay and SAM-debug COM ports if they're still unset in
   `profile.json`, then save them -- subsequent installs/repairs won't
   re-prompt.
6. Verify: `nssm status BuildEmailWatcher`, tail `logs\watcher.log`.

## Safety notes

- This automation **always drafts, never auto-sends** -- replies go
  through `/draft-build-report-email`, which is unconditionally draft-only
  regardless of any config value. Review and send drafts manually until
  you've validated a few cycles end-to-end.
- The agent only marks a build as processed *after* a successful reply, so
  a transient failure safely retries on the next 4-hour cycle instead of
  silently skipping a build.
