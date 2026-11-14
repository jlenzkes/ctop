# Deferred bugs and limitations

Known problems that were found, judged not worth fixing yet, and left in place on purpose. Each entry
says where it came from, where it is, what happens, why it was deferred, and what would fix it. Line
numbers are at `49a06e9` (build 2026.11.02.3).

Flaky tests are listed separately in `CLAUDE.md` ("Flaky tests seen in CI").

## Behaviour

### D1. A kept registry session shows a frozen status while its entry stays unreadable
- **Source:** Sol, PR #5 round 2, question 3 (`SOL_PR5_ROUND2_FINDINGS.md`).
- **Where:** `Get-RegistryRoster`, `ctop.ps1:1570`. This only applies without the `claude` command.
- **What happens:** while a session's `~/.claude/sessions/<pid>.json` can't be read and its process still runs, ctop keeps the last roster's entry for it. Its STATE stays whatever it was last read as, for as long as the file stays unreadable, not just a few seconds. Process liveness is still checked on every poll.
- **Why deferred:** Sol judged it acceptable. Dropping the session instead logged a false "closed" line, which was the P2 bug this replaced.
- **Possible fix:** cap how long a kept entry lasts (say 30 s), or mark its row as unreadable in peek.

### D2. A snapshot doesn't say when a Cline file could not be read
- **Source:** Sol, PR #5 round 2, "Other observations".
- **Where:** the snapshot note, `ctop.ps1:3988`; failed reads in `Read-ClineManifests` (1645) and `Read-ClineMessages`.
- **What happens:** `-Snapshot` notes only files left for later because of the per-frame read limit. A manifest that can't be read or parsed is left out silently. A conversation that can't be read shows its last good read, which in a fresh snapshot process is nothing, so the row has empty cost and tokens with no note.
- **Why deferred:** Sol asked for no new snapshot retry. The changelog wording was narrowed to match what the note covers.
- **Possible fix:** count the cache entries marked `Failed`, and print "note: N Cline file(s) could not be read".

### D3. The probe skips very long transcript lines without counting them
- **Source:** Sol, PR #5 round 2, question 4.
- **Where:** `Get-LineMeta`, `tools/Probe-AgentSources.ps1:83`.
- **What happens:** lines over 262,144 characters (.NET string length, not bytes) are not parsed, so their `entrypoint`, `version`, `userType` and `type` are not counted. The report doesn't say how many lines were skipped.
- **Why deferred:** the probe is a research tool, and its counts are samples (the first 2,000 lines of the newest transcripts), not totals.
- **Possible fix:** count skipped lines and print the count beside the metadata.

### D4. `CTOP_TRACE` loses swallowed errors when over 256 land between two frames
- **Source:** Sol, PRs #3/#4 audit, "Additional targeted checks" (`FINDINGS.md`).
- **Where:** `Write-SwallowedErrors`, `ctop.ps1:160`.
- **What happens:** PowerShell keeps only the newest `$MaximumErrorCount` (256) errors. If more arrive between two calls, the oldest are gone before ctop reads them. Sol generated 300 and 44 were lost. Nothing in the trace says errors were missed.
- **Why deferred:** no finding resulted. A burst that large between two frames would itself be unusual, and the trace is a diagnostic.
- **Possible fix:** when the remembered mark is no longer in `$Error`, write "errors may have been missed" to the trace.

### D5. Liveness is a heuristic, not proof of process identity
- **Source:** Sol, PRs #3/#4 audit, "Additional targeted checks".
- **Where:** `Test-ProcessSince`, `ctop.ps1:1555`. It is used for Claude registry entries and Cline sessions.
- **What happens:** an entry counts as live while its pid names a process that started no later than the session plus 5 s. A start time that can't be read also counts as live. A pid reused by a process started within those 5 s, or one whose start time is hidden, is taken for the session.
- **Why deferred:** Sol judged these conservative heuristics.
- **Possible fix (inference, not checked):** Claude Code's registry entries carry a `procStart` field (seen in the probe's field list). Comparing that to the process's real start time could replace the 5 s window for Claude sessions. What `procStart` holds, and in what format, has not been checked.

### D6. The cache can be fooled by a write that keeps both length and write time
- **Source:** Sol, PR #5 round 2, question 1.
- **Where:** `Test-ClineFresh`, `ctop.ps1:1640`. This also applies to the transcript caches that key on length and write time.
- **What happens:** a file version is identified by its length and last write time. A writer that changes the content but keeps both would not be noticed.
- **Also for Copilot chats (Sol, step 3 round 4):** the SHA-256 prefix check (build 2026.11.10.3) runs only once the file's length or write time has changed, so it does not cover this case: a content change that keeps both still shows the old state.
- **Why deferred:** ordinary writes change one or the other. Sol tested a same-length write racing a read on Windows (Node's `fs.writeFileSync`), and the next read recovered.
- **Possible fix:** none planned.

### D7. The retry after a locked file is "after 5 s", not "at 5 s"
- **Source:** Sol, PR #5 round 2, question 2.
- **Where:** `$script:ClineRetrySec`, `ctop.ps1:1639`.
- **What happens:** a file that couldn't be opened becomes eligible again after 5 s. The retry itself happens at the next roster update, so recovery can take up to 5 s plus `-RosterInterval`.
- **Why deferred:** working as designed; recorded so the "5 s" isn't read as exact.

### D8. `$ErrorActionPreference = 'SilentlyContinue'` is still global
- **Source:** Cline's review of build 2026.11.01.3.
- **Where:** `ctop.ps1:189`.
- **What happens:** every cmdlet error in ctop is silent unless code checks for it. `CTOP_TRACE` now records them (build 2026.11.02.2), but by default nothing is shown.
- **Why deferred:** of that review's points, you chose three to fix, and this wasn't one of them.
- **Possible fix:** set `SilentlyContinue` only around the reads that expect to fail (files mid-write, processes gone), and keep the default elsewhere.

### D9. Copilot chats: "live" is a heuristic
- **Source:** step 3's design (build 2026.11.02.4).
- **Where:** `Update-CopilotRoster` and `New-CopilotRow`.
- **What happens:**
  - VS Code doesn't say which chats are open. ctop counts a chat as live while VS Code runs and the chat was written in the last hour or is unfinished.
  - An unanswered chat is looked for 7 days back (user, 2026-11-10; build 2026.11.10.2). One abandoned within that time, say in a VS Code that crashed, shows as `stalled` or `waiting` until it is answered, cancelled or deleted in VS Code, or until it is 7 days old. Inference, not checked: cancelling it in VS Code marks it finished.
  - A Pending request with no write for 10 min shows as `stalled`.
  - VS Code saves about once a minute, so a finished reply can show as working for up to a minute.
  - On macOS, VS Code's process is not looked for, so it always counts as running.
- **Why deferred:** nothing more exact is on disk.
- **Possible fix:** none planned. The macOS check needs a real Mac.

### D10. A cached gone Cline or Copilot row stops recording activity
- **Source:** Sol, step 3 audit, "Other conclusions" (`SOL_STEP3_BACKBRIEF.md`).
- **Where:** `Build-Rows`, the loop over `ClineRows` and `CopilotRows`.
- **What happens:** a gone row reused from the cache doesn't add activity samples, so its activity column stops moving, and a Cline row's RATE isn't refreshed.
- **Why deferred:** Sol judged these lower-impact display details. The session is gone, so there is little activity to show.
- **Possible fix:** add a sample for reused rows, as Claude's gone rows do (`Add-Sample`).

### D11. New gone agent rows have no minimum build per frame
- **Source:** Sol, step 3 audit, "Other conclusions".
- **Where:** `Build-Rows`, `GoneBuildMs`.
- **What happens:** rows not yet built wait while the frame's build budget is spent. A row whose content changed shows its old version until a frame has time (build 2026.11.02.5); a new one isn't shown until then. Under budget pressure that never eases, a row could wait indefinitely. Sol's checks with up to 4,000 cached rows made progress; no permanent drop was reproduced.
- **Why deferred:** not seen in practice.
- **Possible fix:** build at least one row per frame, as the roster readers read at least one file per call.

### D12. Fedora 45 is untested: PowerShell 7.6.9 cannot install Pester there
- **Source:** CI run 86, attempt 5 (2026-11-09): `fedora:latest` became Fedora 45.
- **Where:** not in ctop: PowerShell itself. CI's Fedora job is pinned to `fedora:44`.
- **What happens:** `./ctop.ps1 -Version` ran and printed the version; then `Install-Module Pester` aborted with "No usable version of libssl was found" (exit 134), so no test ran. Fedora 45's image has `openssl-libs-4.0.3` and only `libssl.so.4` (checked in a `fedora:45` container). Inference: PowerShell 7.6.9's .NET looks for OpenSSL 3 or older, and needs it for network use. Whether ctop itself works there (it makes no network calls) is untested.
- **Why deferred:** not ctop's code; the CI job needs Pester, which needs the network.
- **Possible fix:** move CI back to `fedora:latest` once a PowerShell release, or a Fedora OpenSSL 3 compatibility package, works there. Neither has been checked.

### D13. One large chat file is read in one go
- **Source:** Sol, step 3 round 2, F3 (`SOL_STEP3_ROUND2_VALIDATION.md`): one 28.8 MB chat took 2.1 s in a single roster call on either runtime.
- **Where:** `Read-CopilotChat` (the whole file is parsed at once); called from `Update-CopilotRoster`, which `Invoke-Frame` calls.
- **What happens:** the per-call budget is checked between files, so a single large chat in the window or the 7-day horizon delays that frame for as long as its read takes. The strip's `copilot` cell can't move during it; the frontend shows the screen's age once a frame is 5 s late. Keys still work in the default two-process mode.
- **Why deferred:** the user chose a 7-day horizon plus a progress cell over a background reader (2026-11-10).
- **Possible fix:** read Copilot chats on a background thread (a runspace, since `Start-ThreadJob` may be missing on 5.1), and remember finished chats between runs.

### D14. The `copilot` progress cell counts attempted reads, not unique bytes
- **Source:** Sol, step 3 round 3 (`SOL_STEP3_ROUND3_VALIDATION.md`), "Accounting limits".
- **Where:** `Update-CopilotRoster` (the end, where `$script:CopilotScan` is kept) and `Format-CopilotScan`.
- **What happens:**
  - A file read again counts again, and can grow the total.
  - A read that failed on a lock still counts as done. The cell can go before that file's retry is due.
  - A file that shrank or was deleted keeps the total at its high point, so the cell can go before 100%.
  - Sol found no overflow, no total that drops during a catch-up, and no cell that stays after the reading is done.
- **Why deferred:** Sol judged these display limits within the chosen F3 scope.
- **Possible fix:** count each file version once, by path, length and write time, and leave failed reads out of the done count.

### D15. The CACHE countdown can differ from the extension's by about a second

- **Source:** the pre-audit of the cache countdown, round 2 (2026-11-13), reading the extension's `webview/index.js` (2.1.323).
- **Where:** `Update-Scan` (compact boundary, user and assistant lines) and `Get-CacheState`.
- **What happens:**
  - The extension also marks compaction from a user entry with `isCompactSummary`; ctop only from the `compact_boundary` entry. Claude Code writes both together, about a second apart.
  - While a session is live, the extension times each call by when its window received it; ctop has only the transcript's timestamps.
  - Either can move a minute boundary or the moment the cache goes cold by about a second.
- **Why deferred:** a second is below what the minute cell can show. 80 of 80 real transcripts agreed on anchor, TTL, compaction and tokens with a re-implementation of the extension's rule.
- **Possible fix:** take the compaction time from whichever of the two entries comes first. The live receive time can't be read from disk.

## Not yet checked (not bugs)

- **Cline's `cost`:** that it is in dollars is inference. Whether it equals the manifest's `metadata.totalCost` is unverified. A probe run that prints both would settle it.
- **The `cli` VIA label:** never seen from a real terminal `claude` session.
- **This build on a real Cline session:** ctop itself has not run against one, only its fixtures and the probe.
