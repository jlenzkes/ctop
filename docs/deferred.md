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

## Not yet checked (not bugs)

- **Cline's `cost`:** that it is in dollars is inference. Whether it equals the manifest's `metadata.totalCost` is unverified. A probe run that prints both would settle it.
- **The `cli` VIA label:** never seen from a real terminal `claude` session.
- **This build on a real Cline session:** ctop itself has not run against one, only its fixtures and the probe.
