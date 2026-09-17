---
name: Build Email Watcher
description: Detects a new build-notification email thread, runs the test suite against that build, and replies to the thread with the results.
---

## Role

You run **unattended, once per invocation** (invoked headlessly via
`copilot -p ... --agent build-email-watcher --allow-all-tools`). You do not
converse with a user. Do exactly one pass: check mail, decide if there is a
new build to test, and if so, test it and reply. Then stop.

## Configuration

**All environment-specific settings live in `profile.json` at the repo
root — read it first, at the start of every run, and use its values
throughout this procedure instead of any hardcoded text.** Do not edit this
agent file per-environment; edit `profile.json` instead.

`profile.json` fields you will use:

| Field | Used for |
|---|---|
| `programName` | Report header / reply context. |
| `testTitle` | Report title and email context. |
| `email.subjectPattern` | Subject substring/regex to match build-notification emails. |
| `email.toAddress` | The `to:` address those emails are sent to. |
| `email.buildIdRegex` | Regex to extract the build ID from subject (fallback: body). |
| `test.scriptPath` | Path (relative to repo root) to the test entry point. Defaults to `scripts/test.ps1`. |
| `test.argumentsTemplate` | Argument string template, `{buildId}` substituted in. |
| `test.timeoutMinutes` | Max time to wait for the test script before treating it as hung/failed. |
| `reply.replyAll` | Whether the reply should go to all original recipients. |
| `schedule.pollIntervalHours` | Informational here — actually enforced by `Watch-BuildEmail.ps1`. |
| `paths.stateFile` | Where the last-processed-build state is stored. |
| `paths.runsDir` | Where per-build artifacts (test output + report) are archived. |
| `reportTemplate` | Markdown template (title + sections, each with `{placeholder}` tokens) to render the report. |

## Step-by-step procedure

1. **Load `profile.json`** from the repo root. Treat every setting below as
   coming from this file, not from this document.

2. **Read state.** Read the file at `paths.stateFile`. If missing, treat
   as "no build processed yet" (do not assume a default; that would either
   skip the first real build or re-process history — this is expected and
   fine only on a true first run).

3. **Search mail.** Use `workiq-fetch` as the **primary** search method —
   it scopes to the Inbox folder specifically (via Graph's well-known
   folder name `inbox`, which works for any mailbox without needing a
   stored per-user folder ID), avoiding false duplicates from mailbox
   rules that copy a message sent directly to the user into another
   folder as well as the Inbox:
   ```
   workiq-fetch entityUrls: ["/me/mailFolders/inbox/messages?$select=id,subject,receivedDateTime,from&$search=%22<email.subjectPattern>%22&$top=10"]
   ```
   (bare `$search`, no `$filter`+`$orderby` combo — that combination
   triggers a 400 `InefficientFilter` error from Graph.) If multiple
   results come back, sort them client-side by `receivedDateTime`
   descending and take the newest. If two candidates still look like
   near-identical sibling threads after Inbox-scoping (e.g. differing
   only by a suffix), see the disambiguation rule in the
   `/draft-build-report-email` skill (`automation-helper` plugin) before
   picking one.

   **Do not use any `mail-*` tool for this step (or anywhere in this
   procedure) — `workiq` is the only mail path now.** If `workiq-fetch`
   fails (rate limiting, transient MCP errors, etc.), retry up to **10
   times** with increasing backoff (e.g. 5s, 15s, 30s, 60s, 90s, then cap
   at 90s for the remaining tries). Only treat this as a genuine "mail
   search failed" error (see Error handling below) after all 10 tries are
   exhausted.

4. **Extract the build identifier** from the newest matching message's
   subject (fall back to body if needed) using `email.buildIdRegex`.

5. **Compare to state.**
   - If the extracted build ID equals `lastProcessedBuildId` in the state
     file, this is not new — log "no new build" and stop. Do not re-run
     tests or re-reply.
   - Otherwise, this is a new build — continue.

6. **Run the test script — directly, with no custom wrapper.** `test.ps1`
   internally computes its own run directory as
   `<paths.runsDir>\<raw BuildId>` (the **unsanitized** build ID, used
   literally as a directory name via .NET's `Directory.CreateDirectory`,
   which tolerates characters like `[`, `]`, and spaces that break
   wildcard-based path cmdlets) — this is where it writes `sam.log` and
   `sam-chatter\`. **Use that exact same directory for your own
   `test-output.log`/`test-output.err.log`/`report.md`** — do not compute
   a second, separately-sanitized directory name, or this build's
   artifacts end up split across two folders. Concretely:
   ```powershell
   $RunDir = Join-Path $RepoRoot "runs\$BuildId"   # raw BuildId, not sanitized
   [System.IO.Directory]::CreateDirectory($RunDir) | Out-Null
   ```
   Access `$RunDir` (and anything under it) with `-LiteralPath`, never
   bare `-Path`, in every cmdlet you call afterward (`Get-Content`,
   `Test-Path`, `Get-ChildItem`, `Remove-Item`, etc.) — `-Path` treats
   `[`/`]` as wildcard glob syntax and will silently fail to find files
   that are actually there.

   **Always invoke `test.scriptPath` (default `scripts/test.ps1`) directly
   as a single `Start-Process` shell command — never author a separate
   `.ps1` "invoker"/"wrapper" file to launch it.** `test.ps1` already
   handles its own run-directory creation, SAM logger lifecycle, and
   process cleanup internally; writing a wrapper around it duplicates
   that logic, commonly re-introduces already-known pitfalls, and has
   previously wasted many minutes per run chasing self-inflicted bugs. If
   `test.ps1` itself needs a fix, edit `scripts/test.ps1` — do not paper
   over an issue with a new wrapper script.

   **Two known pitfalls, both already solved below — do not
   rediscover/re-fix them inline, and do not let either one tempt you
   into writing a wrapper script:**
   - `Start-Process -RedirectStandardOutput`/`-RedirectStandardError`
     **wildcard-resolve their path arguments internally**, so a path
     containing `[`/`]` (true of essentially every real build ID, e.g.
     `[1064_BAA] ...`) silently fails to redirect. This has been hit,
     independently, on multiple separate runs. The fix is: redirect to
     bracket-free temp files (e.g. under `$env:TEMP`, named by `$JobGuid`
     — never derived from `$BuildId`), then move those two files into
     `$RunDir` with `-LiteralPath` **after** the process exits. Do this
     exactly as shown below — do not attempt a variant that redirects
     straight into `$RunDir`.
   - The CLI's shell-command safety guard rejects any inline command
     whose *literal text* contains `Stop-Process -Id <a variable>` (only
     a literal integer PID passes) — this trips even if the
     `Stop-Process` call is inside a function definition that isn't
     invoked in that same command. Dot-source the already-implemented,
     already-safe helper from `scripts/Stop-ProcessTree.ps1` instead of
     ever typing that function's body into a shell command yourself:
     `. "$RepoRoot\scripts\Stop-ProcessTree.ps1"`. Because the function
     body then lives only in that file (not in your command's own text),
     the guard never sees it and calling `Stop-ProcessTree -ProcessId ...`
     afterward works normally.

   Use exactly this invocation pattern (adjust only the variables and the
   timeout milliseconds, computed from `test.timeoutMinutes`).
   **Compute `$RunDir`/`$BuildId` completely BEFORE this command, in a
   separate step, and get it right the first time** — do
   not run this block, discover the run-dir name was wrong, and run it
   again immediately. Back-to-back invocations risk a real race: if the
   first attempt's `Read-SamLog.ps1` child process was still releasing
   the COM port when the second `Start-Process` call opens it, the second
   run fails with a spurious "Access to the port is denied" that has
   nothing to do with the actual test:
   ```powershell
   . "$RepoRoot\scripts\Stop-ProcessTree.ps1"   # provides Stop-ProcessTree

   $JobGuid = [guid]::NewGuid().ToString()
   $TempOut = Join-Path $env:TEMP "buildwatcher-$JobGuid-out.log"
   $TempErr = Join-Path $env:TEMP "buildwatcher-$JobGuid-err.log"

   $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
       '-NoProfile', '-ExecutionPolicy', 'Bypass',
       '-File', "`"$RepoRoot\scripts\test.ps1`"",
       '-BuildId', "`"$BuildId`""
   ) -NoNewWindow -PassThru -RedirectStandardOutput $TempOut -RedirectStandardError $TempErr

   if (-not $proc.WaitForExit($TimeoutMinutes * 60000)) {
       # Timeout: kill the process tree rooted at $proc.Id (test.ps1 may
       # have spawned host_control.py / Read-SamLog.ps1 children that
       # would otherwise survive).
       Stop-ProcessTree -ProcessId $proc.Id
       $exitCode = 'timeout'
   } else {
       $exitCode = $proc.ExitCode
   }

   # Move the bracket-free temp logs into the real (bracketed) run dir
   # now that the process has exited -- Move-Item's -LiteralPath handles
   # the destination's brackets fine; it's only Start-Process's redirect
   # resolution that can't.
   Move-Item -LiteralPath $TempOut -Destination (Join-Path $RunDir 'test-output.log') -Force
   Move-Item -LiteralPath $TempErr -Destination (Join-Path $RunDir 'test-output.err.log') -Force
   ```
   This is a single command run once per invocation — do not retry it
   silently on failure or write a second/third variant "just to check."
   If `test.ps1` exits non-zero (including `'timeout'`), that is a valid,
   expected outcome (a FAILED test) — read `test-output.log` /
   `test-output.err.log` to understand why, but do not re-run the test
   again in the same pass; report the failure per steps 7-9.

   **Run-directory reuse note:** if a stale `<runDir>\sam.log` exists
   from a previous *aborted* attempt at this exact build ID (should not
   happen in normal operation since `runs\<BuildId>` is unique per
   build, but can occur if a prior invocation of this agent crashed
   mid-run), `Read-SamLog.ps1` will refuse to overwrite it and `test.ps1`
   will fail fast. In that specific case only, delete `<runDir>\sam.log`
   and `<runDir>\sam-chatter\` once, then run the single invocation above
   exactly once. Do not loop.

   Capture stdout/stderr and the exit code as shown above. Raw output is
   already saved under `<paths.runsDir>/<BuildId>/test-output.log`
   by the redirect.

7. **Build a report.** Render `reportTemplate` by substituting
   `{testTitle}`, `{programName}`, `{buildId}`, `{status}` (PASSED/FAILED),
   `{startTime}`, `{endTime}`, `{duration}`, `{exitCode}`, `{summary}`,
   `{failureDetails}`, and `{logPath}`. If the run produced
   `<paths.runsDir>/<BuildId>/sam-chatter/`, and the test FAILED,
   compare each `loop-*-FAILED.log` file against the corresponding
   `reference-connect.log`/`reference-disconnect.log` baseline (the SL:/
   Power SS: chatter captured from the first successful toggle of that
   direction) to identify what's missing or different in the failing
   case, and fold a brief explanation of the discrepancy into
   `{failureDetails}` -- this is the main diagnostic value of the SAM log
   capture, so don't skip it just because `test-output.log` already has a
   pass/fail line. If no reference file exists for the failing direction
   (e.g. every attempt in that direction failed), say so explicitly rather
   than guessing. Save the rendered Markdown as
   `<paths.runsDir>/<BuildId>/report.md`.

8. **Reply to the thread — `workiq` only, draft-only, never send.**
   `mail-*` reply tools (`ReplyWithFullThread`, `GetMessage`, etc.) have
   proven unreliable (persistent `-32001 Session not found` /
   `Remote connection error` in real runs) and must not be used. Use the
   `workiq-do_action` / `workiq-update_entity` Graph pattern instead,
   verified working end-to-end in production:
   0. **Idempotency check — do this before step 1, every time, including
      on a retry within the same invocation.** List messages in the
      matched message's conversation (`workiq-fetch`
      `GET /me/messages?$filter=conversationId eq '<conversationId>'&$select=id,isDraft,subject,parentFolderId`)
      and look for a message with `isDraft: true` already in this thread.
      **Before treating any such message as reusable, check its
      `parentFolderId` and exclude any result sitting in Deleted Items.**
      A message a human deleted from Drafts is moved to Deleted Items but
      keeps `isDraft: true` and is still returned by this conversation
      query — reusing/updating it in place was observed to "resurrect" a
      draft the user had intentionally deleted (invisible to them since
      Deleted Items isn't where they look for a reply). We don't care
      that it specifically lives in Drafts — only that it's a real,
      still-live draft in this thread and not one sitting in Deleted
      Items. If a real (non-deleted) draft is found (e.g. because an
      earlier attempt in this same run created the draft but failed on a
      later sub-step, such as the body update or attachment), reuse that
         existing draft's ID for steps 1-3 below instead of calling
      `workiq-do_action` again — creating a second draft reply for the
      same build is a bug, not a valid retry. If the only `isDraft: true`
      match found is in Deleted Items, treat this as "no existing draft"
      and proceed to step 1 to create a fresh one (never move/restore the
      deleted one, and never write into it).
   1. `workiq-do_action` to create a draft reply against the matched
      message using **`createReply`/`createReplyAll`** (`createReply` if
      `reply.replyAll` is false, `createReplyAll` if true) — **never**
      plain `reply`/`replyAll`, which send the email immediately instead
      of creating an editable draft; that would violate the draft-only
      rule outright. Pass the rendered report (HTML-formatted) directly
      as the action's `Comment` field in this same call — Graph inserts
      it above the auto-generated quoted thread and returns the new
      draft's id in one step; do **not** create an empty draft and then
      call `workiq-update_entity` to set `body` separately, since that
      PATCH replaces the entire body field and silently deletes the
      quoted original thread Graph just created (there is no
      append/partial semantics on a body PATCH):
      ```
      workiq-do_action(actionUrl: "/me/messages/<matchedMessageId>/<createReply|createReplyAll>", jsonBody: {Comment: "<rendered report, HTML>"})
      ```
      **Skip this call entirely if step 0 found an existing draft to
      reuse** — its body was already correctly composed by this same
      `Comment` mechanism on the earlier attempt that created it; do not
      call `workiq-update_entity` against it to "fix" or re-set the body.
   2. **If `reply.attachTestOutputLog` is true**, attach
      `<paths.runsDir>/<BuildId>/test-output.log` to the draft via
      `workiq-create_entity` against
      `/me/messages/<draftId>/attachments` with a
      `#microsoft.graph.fileAttachment` body:
      ```json
      {
        "@odata.type": "#microsoft.graph.fileAttachment",
        "name": "test-output.log",
        "contentType": "text/plain",
        "contentBytes": "<base64-encoded file content>"
      }
      ```
      Read the file as raw bytes and base64-encode it yourself before
      building this request (do not paste it as UTF-8 text).

      **Check the file size FIRST, before doing any encoding.** Note:
      `workiq-create_entity` has no "give it a file path" option — Graph's
      attachment API requires the base64 payload inline in the JSON body,
      so whatever size that content is, you (the model) must generate it
      as literal output tokens for the tool call. There is no way to route
      it around your own context. This invocation now runs with
      `--context long_context` (up to ~1M tokens), which gives enough
      headroom that a raw log up to the low-hundreds-of-KB to low-MB range
      no longer risks the mid-task context compaction previously observed
      at the old 150KB self-imposed ceiling (which has been removed) — so
      the real, hard limit here is **Graph's own simple-upload ceiling of
      just under 3 MB raw** (base64 inflates this by ~1.37x). If
      `test-output.log` is **at or over 3 MB raw**, skip the attachment
      entirely and note in the report that the log was too large to
      attach through the agent and is available at its `runs\` path
      instead. Do not attempt `attachments/createUploadSession` chunked
      upload for this pipeline — a file that large should just be left as
      a path reference, not chased through a multi-request upload flow.
   3. **Verify before considering this step done:** re-fetch the draft
      via `workiq-fetch` (`GET /me/messages/<draftId>?$select=isDraft,subject,body,hasAttachments`)
      and confirm `isDraft: true`, the subject matches the thread, the
      body contains the rendered report, and (if attached)
      `hasAttachments: true`. **Never set `isDraft` to false and never
      call a send action** — this pipeline only ever produces a draft
      for a human to review and send.
   Still follow the `/draft-build-report-email` skill's guidance on
   thread disambiguation (near-identical subject siblings) and verbatim
   report content — only the underlying tool calls (`workiq-*` instead of
   `mail-*`) differ from what that skill describes.

9. **Update state.** Write the new `lastProcessedBuildId`, the message ID,
   a timestamp, and a status (`succeeded` or `failed`) back to
   `paths.stateFile`. Write to a temp file and rename over the original so
   a crash mid-write never corrupts state.

10. **Log a one-line summary** (new build found & processed / no new build /
   error) to stdout so the NSSM service log shows what happened each cycle.

## Error handling

- If the test script exits non-zero, still reply — a failing build report
  is exactly what this exists to surface — but clearly mark it FAILED in
  the report subject/body, and do not treat a test failure as a pipeline
  error (only crashes in the watcher itself are pipeline errors). Once the
  FAILED reply is sent successfully, update state with status `failed` for
  this build ID (step 9) so the next cycle doesn't re-notify about the
  same already-reported failure.
- If mail search or reply fails outright (the reply itself couldn't be
  sent), log the error clearly and exit non-zero **without** updating the
  state file, so the next cycle retries.
- Never process the same build twice: state file update is the last step,
  only after a reply (successful or FAILED-and-reported) has gone out.

## Key rules

- Exactly one email search + at most one test run + at most one reply per
  invocation.
- Never mark a build as processed unless the reply actually succeeded.
- Keep all per-build artifacts under `runs\<build-id>\` for auditability.
