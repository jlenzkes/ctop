# Deferred bugs and limitations

Known problems left in place on purpose. Each entry says where it is, what happens, and what would fix it.

Flaky tests are listed in `CLAUDE.md`.

## Behaviour

### D1. A kept registry session shows a frozen status while its entry stays unreadable

- **Where:** `Get-RegistryRoster`. This only applies without the `claude` command.
- **What happens:** while a session's `~/.claude/sessions/<pid>.json` can't be read and its process still runs, ctop keeps the last roster's entry for it. Its STATE stays whatever it was last read as, for as long as the file stays unreadable, not just a few seconds. Process liveness is still checked on every poll.
- **Why kept:** dropping the session instead would log a false "closed" line.
- **Possible fix:** cap how long a kept entry lasts (say 30 s), or mark its row as unreadable in peek.

### D2. A snapshot doesn't say when a Cline file could not be read

- **Where:** the `-Snapshot` notes at the end of `ctop.ps1`; failed reads in `Read-ClineManifests` and `Read-ClineMessages`.
- **What happens:** `-Snapshot` notes only files left for later because of the per-frame read limit. A manifest that can't be read or parsed is left out silently. A conversation that can't be read shows its last good read, which in a fresh snapshot process is nothing, so the row has empty cost and tokens with no note.
- **Possible fix:** count the cache entries marked `Failed`, and print "note: N Cline file(s) could not be read".

### D3. `CTOP_TRACE` loses swallowed errors when over 256 land between two frames

- **Where:** `Write-SwallowedErrors`.
- **What happens:** PowerShell keeps only the newest `$MaximumErrorCount` (256) errors. If more arrive between two calls, the oldest are gone before ctop reads them: of 300 generated at once, 44 are lost. Nothing in the trace says errors were missed.
- **Why kept:** a burst that large between two frames would itself be unusual, and the trace is a diagnostic.
- **Possible fix:** when the remembered mark is no longer in `$Error`, write "errors may have been missed" to the trace.

### D4. Liveness is a heuristic, not proof of process identity

- **Where:** `Test-ProcessSince`. It is used for Claude registry entries and Cline sessions, and, with `-Verified`, for the Copilot CLI's locks.
- **What happens:** an entry counts as live while its pid names a process that started no later than the session plus 5 s, compared as instants. For registry entries and Cline sessions, a start time that can't be read also counts as live; for a Copilot CLI lock it does not. A process ctop may not open (another user's, a system one) has no readable start time: seen for pid 4 from an unelevated shell, on PowerShell 7.6.10 and Windows PowerShell 5.1. A pid reused by a process started within those 5 s, or one whose start time is hidden, is taken for the session. An elevated process of the same user is not one of these: an unelevated shell read its start time on both runtimes (2026-11-23).
- **Possible fix (inference, not checked):** Claude Code's registry entries carry a `procStart` field. Comparing that to the process's real start time could replace the 5 s window for Claude sessions. What `procStart` holds, and in what format, has not been checked.

### D5. The cache can be fooled by a write that keeps both length and write time

- **Where:** `Test-ClineFresh`. This also applies to the transcript caches that key on length and write time, and to Copilot chats: their SHA-256 prefix check runs only once the file's length or write time has changed.
- **What happens:** a file version is identified by its length and last write time. A writer that changes the content but keeps both is not noticed, and the old state still shows.
- **Why kept:** ordinary writes change one or the other. A same-length write racing a read on Windows (Node's `fs.writeFileSync`) recovers on the next read.
- **Possible fix:** none planned.

### D6. The retry after a locked file is "after 5 s", not "at 5 s"

- **Where:** `$script:ClineRetrySec`.
- **What happens:** a file that couldn't be opened becomes eligible again after 5 s. The retry itself happens at the next roster update, so recovery can take up to 5 s plus `-RosterInterval`.
- **Why kept:** working as designed; recorded so the "5 s" isn't read as exact.

### D7. `$ErrorActionPreference = 'SilentlyContinue'` is global

- **Where:** the script-level setting near the top of `ctop.ps1`.
- **What happens:** every cmdlet error in ctop is silent unless code checks for it. `CTOP_TRACE` records them, but by default nothing is shown.
- **Possible fix:** set `SilentlyContinue` only around the reads that expect to fail (files mid-write, processes gone), and keep the default elsewhere.

### D8. Copilot chats: "live" is a heuristic

- **Where:** `Update-CopilotRoster` and `New-CopilotRow`.
- **What happens:**
  - VS Code doesn't say which chats are open. ctop counts a chat as live while VS Code runs and the chat was written in the last hour or is unfinished.
  - An unanswered chat is looked for 7 days back. One abandoned within that time, say in a VS Code that crashed, shows as `stalled` or `waiting` until it is answered, cancelled or deleted in VS Code, or until it is 7 days old. Inference, not checked: cancelling it in VS Code marks it finished.
  - A Pending request with no write for 10 min shows as `stalled`.
  - VS Code saves about once a minute, so a finished reply can show as working for up to a minute.
  - On macOS, VS Code's process is not looked for, so it always counts as running.
- **Why kept:** nothing more exact is on disk.
- **Possible fix:** none planned. The macOS check needs a real Mac.

### D9. A cached gone Cline or Copilot row stops recording activity

- **Where:** `Build-Rows`, the loop over `ClineRows` and `CopilotRows`.
- **What happens:** a gone row reused from the cache doesn't add activity samples, so its activity column stops moving, and a Cline row's RATE isn't refreshed.
- **Why kept:** the session is gone, so there is little activity to show.
- **Possible fix:** add a sample for reused rows, as Claude's gone rows do (`Add-Sample`).

### D10. New gone agent rows have no minimum build per frame

- **Where:** `Build-Rows`, `GoneBuildMs`.
- **What happens:** rows not yet built wait while the frame's build budget is spent. A row whose content changed shows its old version until a frame has time; a new one isn't shown until then. Under budget pressure that never eases, a row could wait indefinitely. Checks with up to 4,000 cached rows made progress; no permanent drop has been reproduced.
- **Possible fix:** build at least one row per frame, as the roster readers read at least one file per call.

### D11. Fedora 45 is untested: PowerShell 7.6.9 cannot install Pester there

- **Where:** not in ctop: PowerShell itself. CI's Fedora job is pinned to `fedora:44`.
- **What happens:** `./ctop.ps1 -Version` runs and prints the version; then `Install-Module Pester` aborts with "No usable version of libssl was found" (exit 134), so no test runs. Fedora 45's image has `openssl-libs-4.0.3` and only `libssl.so.4` (checked in a `fedora:45` container). Inference: PowerShell 7.6.9's .NET looks for OpenSSL 3 or older, and needs it for network use. Whether ctop itself works there (it makes no network calls) is untested.
- **Why kept:** not ctop's code; the CI job needs Pester, which needs the network.
- **Possible fix:** move CI to `fedora:latest` once a PowerShell release, or a Fedora OpenSSL 3 compatibility package, works there. Neither has been checked.

### D12. One large chat file is read in one go

- **Where:** `Read-CopilotChat` (the whole file is parsed at once); called from `Update-CopilotRoster`, which `Invoke-Frame` calls.
- **What happens:** the per-call budget is checked between files, so a single large chat in the window or the 7-day horizon delays that frame for as long as its read takes: a 28.8 MB chat takes 2.1 s in one roster call on either runtime. The strip's `copilot` cell can't move during it; the frontend shows the screen's age once a frame is 5 s late. Keys still work in the default two-process mode.
- **Why kept:** the 7-day horizon and the strip's progress cell stand in for a background reader.
- **Possible fix:** read Copilot chats on a background thread (a runspace, since `Start-ThreadJob` may be missing on 5.1), and remember finished chats between runs.

### D13. The `copilot` progress cell counts attempted reads, not unique bytes

- **Where:** `Update-CopilotRoster` (the end, where `$script:CopilotScan` is kept) and `Format-CopilotScan`.
- **What happens:**
  - A file read again counts again, and can grow the total.
  - A read that failed on a lock still counts as done. The cell can go before that file's retry is due.
  - A file that shrank or was deleted keeps the total at its high point, so the cell can go before 100%.
  - No overflow, no total that drops during a catch-up, and no cell that stays after the reading is done has been found.
- **Possible fix:** count each file version once, by path, length and write time, and leave failed reads out of the done count.

### D14. The CACHE countdown can differ from the extension's by about a second

- **Where:** `Update-Scan` (compact boundary, user and assistant lines) and `Get-CacheState`.
- **What happens:**
  - The extension also marks compaction from a user entry with `isCompactSummary`; ctop only from the `compact_boundary` entry. Claude Code writes both together, about a second apart.
  - While a session is live, the extension times each call by when its window received it; ctop has only the transcript's timestamps.
  - Either can move a minute boundary or the moment the cache goes cold by about a second.
- **Why kept:** a second is below what the minute cell can show. 80 of 80 real transcripts agree on anchor, TTL, compaction and tokens with a re-implementation of the extension's rule (`webview/index.js`, extension 2.1.323).
- **Possible fix:** take the compaction time from whichever of the two entries comes first. The live receive time can't be read from disk.

### D15. Without a C# compiler, transcripts are read by a regex reader

- **Where:** `Get-EntryReader` and `Read-EntryRx` (with `Get-JsonRx`), used by `Update-Scan` only when `Import-JsonType` can't compile or load CtopJson.
- **What happens:** the regex reader skips a line shorter than 20 characters or naming none of the kinds read (a newer skipped entry still gives cwd and branch), and reads the lines Claude Code writes as CtopJson does: on 31,800 lines (4,800 real ones) it agrees on every real line. On a 45.6 MB transcript it takes 3.3 to 4.0 s on PowerShell 7 and 9.2 to 9.6 s on Windows PowerShell 5.1, where a field read costs more. It does not read as JSON.parse does:
  - keys written with escapes (`"\u0074ype"`) are not recognized, and numbers other than plain integers (`3.0`, `3e0`) count as 0;
  - a container written twice (a message, a usage, a content) keeps members of the first; a block's `type` or `name` written twice is read from the first;
  - some invalid lines are read: a trailing comma, a mismatched bracket, a bad escape, `+3`, a bareword;
  - on PowerShell 7, an escaped string that looks like a date (a timestamp with an escape in it) is turned into a date by `Unescape-Json`'s `ConvertFrom-Json`.
- **Why kept:** CtopJson compiles wherever PowerShell 7 runs (Roslyn ships with it) and on Windows PowerShell 5.1 (the .NET Framework's `csc`); the fallback is for a machine where even that is blocked. A transcript Claude Code writes holds none of the lines above.
- **Possible fix:** none planned; `CTOP_TRACE` says which reader a process uses.

### D16. A tool input holding `"type":"user"` can hide a pending question from LAST ACTION

- **Where:** `Get-LastAction`'s backward search for where the current turn starts: it tests whole lines with `Contains`, not the entry's own `type`.
- **What happens:** an unanswered AskUserQuestion is shown, but if a later tool call in the same message has `"type":"user"` anywhere in its input, the search takes that line for a user turn and the question disappears from LAST ACTION. The CACHE column is not affected.
- **Why kept:** no real transcript has been seen to hit it.
- **Possible fix:** classify turn boundaries by the entry's own fields, e.g. with CtopJson (`[CtopJson.Reader]::Read`).

### D17. The hover box stays up when the pointer leaves the window

- **Where:** `Read-Keys` keeps the last pointer position in `$view.Hover`; `Get-HoverBox` draws from it until a key press or a pointer move onto no cell.
- **What happens (inference from the code, not seen in a real console):** moving the pointer straight from a cell to outside the window leaves the box drawn, because the Windows console sends a mouse record only while the window has the keyboard focus and the pointer is inside it ("Mouse events are placed in a console's input buffer only when the console group has the keyboard focus and the cursor is within the borders of the console's window", learn.microsoft.com, MOUSE_EVENT_RECORD). ctop sees no departure. A key press, or the pointer coming back onto a gap, the header or the footer, closes it.
- **Why kept:** nothing ctop reads reports the departure. Focus events (FOCUS_EVENT_RECORD) are documented as "used internally and should be ignored", and a pointer can leave without the focus changing. A box that closes after a quiet interval would also close while the pointer rests on a cell, which is the hover's whole use.
- **Possible fix:** close the box when the console reports a focus change (covers a click into another window, not a pointer that only leaves), or poll the pointer's screen position (`GetCursorPos` against the console window's rectangle) on each tick while a box is up.

### D18. A Copilot CLI log rewritten with the same start, or appended to with no lock held, is missed

- **Where:** `Update-CopilotCliScan` (a log is taken for replaced only when it shrank, kept its length under a new write time, or its first 256 bytes differ), and `Update-CopilotCliRoster` (a folder with no lock whose log was last written before the keep window is not looked at again until the folder's own write time moves).
- **What happens:** measured as limits, on PowerShell 7.6.10 and Windows PowerShell 5.1:
  - a log rewritten to a longer one that starts with the same 256 bytes is read as an append: what was read from the old content stays (1 turn kept, 0 on a fresh read);
  - a session with no lock whose log was last written before the keep window, then appended to, stays unlisted until its folder's write time moves (a lock taken) or ctop starts again (0 rows, 1 on a fresh roster).
- **Why kept:** both rest on the reader's two assumptions: the CLI only appends to `events.jsonl`, and only a process holding the session's lock writes to it (inference: every writer seen holds one). Whether the CLI ever breaks either is unverified. Statting every old unlocked log each call is the cost the roster avoids.
- **Possible fix:** for the first, a hash of the bytes up to the offset, as the Copilot chat reader keeps, at the cost of reading the whole log on each change; for the second, stat old unlocked logs every few calls instead of never.

### D19. Copilot chats and Copilot CLI sessions are priced by the model id without `claude-`

- **Where:** the Copilot chat reader, where it calls `Get-Price` with `(($model -split '/')[-1]) -replace '^claude-', ''`; and `Update-CopilotCliScan`, which prices a `session.usage_record` by `Get-CopilotCliModel`, the same cut.
- **What happens:** `-PricingFile`'s `Match` is documented as a regex on the model id. Claude Code rows, CACHE included, are priced by the transcript's id (`claude-opus-5-5`); Copilot chat and Copilot CLI rows by the id cut down (`opus-5-5`). A rule anchored on `^claude-` prices the first, leaves Copilot chats at $0 with no word (read, not run), and leaves Copilot CLI calls unpriced, which its peek does say (run on PowerShell 7.6.10, 2026-11-23: cost 0, 1 call on a model with no price).
- **Why kept:** which id a Copilot rule should see (VS Code's `copilot/...` id, or Anthropic's) is still to be decided.
- **Possible fix:** match the rule against the id without the vendor prefix but with `claude-`, or try both forms; say in `-PricingFile`'s help which one Copilot rows use.

### D20. With `-InProcess`, every pointer move builds a frame at once

- **Where:** `Read-Keys` sets `$any` for every input record, a pointer move included, so `Invoke-InProcessLoop` leaves its tick and builds the next frame straight away.
- **What happens:** with `-InProcess` (not the default, which builds frames in the worker), moving the pointer keeps ctop building frames back to back, one per pass of the 20 ms wait, instead of one per tick. One pointer move makes `Read-Keys` return `keys` (checked with `Next-Input` replaced in a test script; not timed in a real console). The worker mode is not affected: a move asks the worker for nothing (`Rev` is not raised).
- **Why kept:** not measured as a cost.
- **Possible fix:** set `$any` only for input that is not a plain pointer move, so the hover box waits for the tick, as the comment in `Read-Keys` already says it does.

### D21. The table's cells let C1 control characters through

- **Where:** `Clean`, used by `Fit` and every table cell.
- **What happens:** a session's text holding U+0080-U+009F (U+009B is CSI, U+009D is OSC, in their 8-bit form) reaches the screen in a cell: U+009B and U+009D survive `Clean` on PowerShell 7 and 5.1 (checked at text level). What a physical terminal does with them, and whether it moves the grid, is not verified. The hover box removes C1 characters itself.
- **Why kept:** changing `Clean` changes every cell and the width tests around it.
- **Possible fix:** widen `Clean`'s class to `[\x00-\x1F\x7F-\x9F]` and drop the hover box's own C1 step.

### D22. CACHE reads one shape of time; the extension's Date.parse reads many more

- **Where:** `ConvertFrom-CacheTime`.
- **What ctop reads:** a whole date and time with seconds, an optional fraction of any length (cut to the millisecond, as V8 cuts it) and an explicit zone, `Z` or `+hh:mm` / `-hh:mm`, with nothing before or after it: `2026-11-13T12:00:00.000Z`. The date and time as written must exist, and so must the instant in UTC (years 1 to 9999). This is the shape Claude Code writes: every timestamp in a sample of 300 transcripts (150 main, 150 subagent; 200,100 lines, 159,656 timestamps), 2026-11-23, was `YYYY-MM-DDTHH:MM:SS.fffZ`. Anything else is no time: no anchor, request or compaction.
- **What happens:** the extension reads a transcript's times with JavaScript's `Date.parse`, and V8 reads more than ctop does: a date alone (`2026-11-13`, `2026-11`, `2026`, as UTC), no seconds (`12:00Z`), no zone (local time, including the hour a DST change folds or skips), lowercase `t` and `z`, a space for `T`, an offset without its colon (`+0100`), `24:00`, a day past the month's end (`2026-11-31`), six-digit and out-of-range years, a final newline, and its legacy forms (`Fri, 13 Nov 2026 12:00:00 GMT`, `2026/11/13 12:00`, `2026-1-13`, even `1`). A transcript with such a time gets a cache anchor or compaction from the extension and none from ctop. On a 721-case matrix against the extension's own functions (Node 24.22.1, V8 13.6), on both runtimes: 594 cases differ, every one of them a time V8 reads and ctop does not; no time is read by ctop and not by V8, and none is read by both at different instants.
- **Why kept:** no real transcript has been seen with another shape, and reading more of V8's grammar means matching its local-time rules, DST folds, normalisation and runtime differences exactly.
- **Possible fix:** when a real transcript shows another shape, add exactly that shape, with its V8 value as the test.

### D23. A fast mode call on a standard model id is priced at standard rates

- **Where:** `Update-Scan` (a transcript's calls), `Update-CopilotCliScan` (`session.usage_record`), and the price table, which matches on the model id alone.
- **What happens:** fast mode is asked for with `speed: "fast"` on the standard id (`claude-opus-5-5`, `claude-fable-5-2`) everywhere but Microsoft Foundry, which has its own `-fast` ids; the price table has fast rows only for those ids. A fast call on a standard id costs twice the standard rate (Fast Mode page, read 2026-11-23), and ctop counts it at the standard rate: half. Claude Code's transcripts do carry the speed: the API's `usage.speed` is in each call's `message.usage` (counted over one machine's `~/.claude/projects`, 2026-11-23: 492,604 `"speed":"standard"` and 37,266 `"speed":null`, no `"fast"`). Whether Copilot CLI's `usage_record` carries a speed is not checked. Older retired ids (`claude-opus-4-6-fast`, `claude-opus-4-7-fast`) still match their standard rows; the first now runs at standard speed and the second returns an error, and what either cost when it ran is not checked.
- **Why kept:** reading `usage.speed` means a new field in CtopJson and in the regex reader, and a scan version; no `fast` call has been seen in real logs.
- **Possible fix:** read `message.usage.speed`; when it is `fast`, price the call by the model's fast row (a `-fast` match on `<id>-fast`), and raise ScanVer and PriceVer.

### D24. A helper DLL published while a damaged one is moved aside can be left under a temporary name

- **Where:** `Import-HelperDll`, the branch for a damaged DLL (`$bad`): the DLL is renamed aside, compared there with the bytes read, then deleted or renamed back.
- **What happens:** if another ctop publishes a valid DLL between this one's read of the damaged DLL and its rename, the rename moves the valid one aside. Until it is renamed back, a lookup with no compiler finds no DLL; a ctop stopped between the two renames leaves the valid DLL under its `ctop-*-tmp-*` name, and `Remove-OldConDlls` deletes it 10 minutes later. Measured with the timing and the interruption injected and compilation disabled, on PowerShell 7.6.10 and Windows PowerShell 5.1: the canonical DLL absent, the valid image under the temporary name, and both lookups (during the gap and after) failing. How often a real process stops there is not estimated.
- **Why kept (an argument, not verified):** the harm needs a ctop with no compiler, but the DLL it would lose was published by a ctop of the same runtime on the same machine, which compiled it there; so that runtime has a compiler, and the loser compiles the DLL again on its next start. A machine whose compiler goes away between two ctop starts of the same runtime, or a config folder shared between machines, would break the argument.
- **Possible fix:** when the file renamed aside is not the damaged one, leave it where it lands as the published DLL (rename back only if the canonical name is still free, else load from the aside copy), and have a lookup that finds no DLL also look for a recent valid `ctop-*-tmp-*` before giving up.

### D25. In a reftable repository, BRANCH does not show git's branch

- **Where:** `Get-GitInfo`.
- **What happens:** a repository made with `git init --ref-format=reftable` keeps its refs in `.git/reftable/`, and its `.git/HEAD` is a stub, `ref: refs/heads/.invalid`, that git never uses (git's reftable documentation, "Layout"). Git 2.56.1 reports `main` there; ctop shows `-`, because the stub's name fails git's name rules (a part starting with `.`), measured on PowerShell 7.6.10 and Windows PowerShell 5.1. So a Copilot CLI row shows the branch its `workspace.yaml` recorded, a Claude Code row the transcript's `gitBranch`, and a Cline or Copilot chat row `-`; a gone Copilot CLI row there asks git again every roster poll (one read of HEAD).
- **Why kept:** reading a reftable means parsing its binary blocks (or running git).
- **Possible fix:** when `.git/reftable/tables.list` exists, read HEAD's record from the newest table it names (the reftable format's ref block), or run `git symbolic-ref --short HEAD` for such repositories only.

### D26. Copilot CLI STATE: cases no real log has shown

- **Where:** `Update-CopilotCliScan` and `Get-CopilotCliSummary`.
- **What happens:** each was run with a synthetic log on PowerShell 7.6.10 and Windows PowerShell 5.1 (2026-11-23); none occurs in the 146 real sessions of one Windows machine, replayed line by line through ctop's own reader:
  - a compaction outside any turn shows `idle`, since `session.compaction_start` is not read (all 42 real compactions ran inside a turn);
  - a line whose `data` has two keys differing only in letter case, or an empty key, is dropped whole on both runtimes, and one nested deeper than 100 on 5.1, so a permission asked there shows `thinking` (0 of 28,310 real lines);
  - a `copilot -p` run's permission check shows `waiting` until the CLI denies it unattended: real waits were a median 3 ms and at most 4.7 s;
  - `session.error` leaves a pending prompt open (`thinking`), and its message stays in peek after later turns succeed (all 12 real errors came after a turn ended; 1 session went on for 5 more prompts);
  - open tool, turn and permission ids are matched without letter case (no two real ids differ only in case);
  - a lock rewritten in place by a later process with the same pid is not seen until the folder changes;
  - `workspace.yaml`: a block value ends at a line of only spaces (no real file has a block value).
- **Why kept:** none is reached by what the CLI writes.
- **Possible fix:** read `session.compaction_start`; pick the state-bearing fields out of a line without parsing all of it; clear `Error` on the next prompt; use ordinal maps for the open ids.

### D27. A malformed number in an agent's file stops ctop

- **Where:** casts without a guard: Cline token counts (`Read-ClineMessages`) and manifest pid (`Update-ClineRoster`), a registry pid (`Test-RegistryLive`), `startedAt` in `Read-Roster`'s duplicate-pid tie-break, `closedAt` in the closed-sessions list, Copilot CLI token counts (`Update-CopilotCliScan`), and the quit path's last write to the worker.
- **What happens:** a value such as `"abc"` or `1e30` in one of those fields ends ctop with "stopped: RuntimeException" (run on both runtimes, 2026-11-23): ctop's one top-level `try` catches it, with no `try` around one session or one frame. No real file seen holds such a value: 178 Cline token counts, 45 manifests, 8,381 closed-log lines, 3,177 Copilot CLI usage records. The quit write fails only if the worker dies between the check and the write.
- **Why kept:** no writer produces such a value; the fix is the design change below. Related: D7.
- **Possible fix:** read each session inside its own `try`, so one bad file costs its row, not ctop.

### D28. LAST ACTION is not cut short for Cline, Copilot chats and the Copilot CLI

- **Where:** `Read-ClineMessages`, the Copilot chat reader, `Get-CopilotCliSummary`; Claude Code's reader cuts it to about 120 characters and keeps the whole text for peek and hover.
- **What happens:** what shows is the same (cells are cut to the column), but each row key holds the whole text. Copilot CLI's last reply is a median 4,089 characters and at most 28,373 (137 real sessions); measured, 1,000 keys of one row grew the heap by 8.2 MB at the median and 54.5 MB at the longest, so up to about 218 MB before the row cache is cleared at 4,000 keys (arithmetic from that measurement).
- **Why kept:** memory only, no wrong output.
- **Possible fix:** cut `Last` as Claude Code's reader does, keeping `LastFull` whole.

### D29. Long runs: caches grow, and settings files are re-checked for every folder ever seen

- **Where:** script caches keyed by session or file (`TailCache`, `MetaCache`, `SpawnerCache`, `SidecarCache`, `AllAgents`, `History`, `CompactSeen`, `ScanVerified`, `ClineMsgCache`, the in-memory `ScanCache`, `CeilingCache`), and `Sync-SettingsFiles`.
- **What happens:** measured on one machine's real transcripts (2026-11-23), about 78 KB of heap per transcript, about 3.5 MB a day at that machine's rate. `Sync-SettingsFiles` stats two settings files for every working folder seen, 2-5 ms each, at most every 5 s: about 25 ms per 5 s after a week, 120 ms after a month, at that machine's rate of new folders (arithmetic from those measurements).
- **Why kept:** slow; nothing wrong is shown.
- **Possible fix:** prune these caches against the listed sessions when the scan cache is saved, and check settings files only for listed sessions' folders.

### D30. Edge cases no real input reaches

Each was run on PowerShell 7.6.10 and Windows PowerShell 5.1 (2026-11-23); what real data was counted is in parentheses.

- A Claude Code transcript first seen empty keeps no head, so a longer file replacing it reads as an append, and the scan cache drops it at the next start (no real transcript is empty).
- A row nested four deep or more (a launched session holding a depth-3 subagent) is wider than NAME in a narrow window (real subagents nest at most 3 deep).
- COST cuts a session's own cost of $1,000 or more to `$1,234…`, and `Σ` cuts $99.995 to $99.999 (the highest real session cost was $552).
- The row cache keys rows without letter case, so a rename that changes only case shows the old case until another cell changes; path caches would collide on a case-sensitive file system for two folders differing only in case.
- A sidechain line in a main transcript sets the session's model (no real transcript has one; pricing is not affected).
- A copy key queued behind another waits up to one frame tick, 250 ms by default.
- `-Keep` above about 1.0e9 minutes stops ctop at start.
- A bad `-Keep` or `-PricingFile` starts a worker that rejects it and exits about 3 s later.
- A Copilot chat edit that pushes a `null` drops it (none of 4,848 real edits holds one).
- COST, Claude Code: a reply's later line that comes more than 8 replies after its last one is not counted, so
  a larger final output then would be lost; and a later copy of only an earlier block of a recent reply replaces
  its final usage (neither shape is in 4,582 real transcripts, counted 2026-11-23).
- The keep window compares local clock times: across the spring change to daylight time, a session that ended
  inside the window can count as an hour older and be left out, for every agent (run on both runtimes with a
  fixed clock; the same on `main`).
- `↑↓ select` and `PgUp/PgDn` in the footer are not clickable.
- When the `claude` command will not start and no session is found, the empty table still names
  `claude agents --json` as the source.

## Not yet checked (not bugs)

- **Cline's `cost`:** that it is in dollars is inference. Whether it equals the manifest's `metadata.totalCost` is unverified. A run that prints both would settle it.
- **The `cli` VIA label:** never seen from a real terminal `claude` session.
- **A Copilot chat that VS Code moves between workspaces:** not yet seen on a real machine; ctop keys chat rows on the chat's id across every chat folder, so a copy should show as one row.
- **A Copilot chat after File > Add Folder to Workspace:** its workspace is then an untitled multi-root workspace, whose `workspace.json` names a `.code-workspace` file rather than a folder, so CWD would show that file's path (inference, not run).
- **Copilot credits:** that VS Code's `copilotCredits` are GitHub AI credits at $0.01 each is inference; no chat that used credits has been seen.
- **The SHA-256 fallback under a FIPS policy:** tested only by an injected failure, not on a real FIPS-enabled Windows PowerShell 5.1.
