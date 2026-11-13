# ctop changelog

Calendar versioning: `YYYY.MM.DD.N`, the build date, then that day's build number. Newest first.

## 2026.11.13.2 — more from cxtop

- the files ctop reads are opened so that their owners can still rename or delete them meanwhile:
  transcripts, session files, Cline and Copilot files, and git's `HEAD` (git renames `HEAD.lock` over it).
  Before, a rename or delete by Claude Code, VS Code or git failed on Windows for as long as ctop held the
  file (seen in a test with a held handle; not seen happening to those programs)
- `-HighlightModel` must be a valid regular expression and `-SelectBg` an SGR code (digits and `;`); ctop
  refuses others at the start, naming the flag. A bad pattern used to stop ctop at its first session row
- the scan cache is written to a temporary file and renamed over the old one, so a kill mid-save no longer
  leaves a truncated cache that makes ctop rescan everything

## 2026.11.13.1 — keys that stopped ctop

- pressing Shift, Ctrl, Alt, Caps Lock, Num Lock or Scroll Lock on its own no longer stops ctop on Windows
  with the mouse on ("Cannot convert value "18" to type "System.ConsoleKey""): the console reports those
  keys by codes .NET's ConsoleKey has no name for. A key with no name keeps its character; one with neither
  is dropped. The digits typed while composing a character with Alt and the number pad are no longer read
  as commands, and the character they compose arrives as typed. Ported from cxtop 2026.11.06.1 and .2.
- Alt and Ctrl chords no longer act as commands (Alt+q quit ctop). AltGr text still works: AltGr+9 on a
  German keyboard types `]` and shortens the tick, as `]` does.

## 2026.11.10.7 — Sol's round 6

- peek's note on turns with usage on a model ctop has no price for counts each turn once: a turn on a
  priced and an unpriced model read as two ("1 of 2 turns" for one turn)

## 2026.11.10.6 — Sol's round 5

- a Copilot chat's token price uses each turn's whole usage per model where VS Code records it
  (`modelTotals`: every model call of the turn, subagents too, with cached tokens at the cache-read
  price). Where it doesn't, VS Code records only the turn's last model call's input, and peek now calls the
  price partial instead of an upper estimate; it also says how many turns ran on a model with no price
- LAST ACTION leaves out the model's thinking: a thinking part stored as text was joined into the reply
- a gone chat that VS Code moved shows its new folder and file, even when the copy has the same content
  and write time as the original

## 2026.11.10.5 — a chat VS Code moved

- a chat VS Code moved keeps one row, with the folder it moved to. Opening a folder copies every chat file
  into the folder's storage under the same name (the chat's id) and keeps the originals; a transfer to
  another window keeps the id too (VS Code's `chatSessionStore.ts`). ctop already listed one row per id,
  from the newest copy; a copy written at the same time as the original is now told apart by which was
  created later, then by a folder's copy over the empty window's
- the $0.01 price of a Copilot credit is now read from GitHub's billing docs ("1 AI credit = $0.01 USD")

## 2026.11.10.4 — from the first run on real Copilot chats (the user's machine, 2026-11-10)

- COST for a Copilot chat is in dollars: the Copilot credits it used at $0.01 each (GitHub's price per
  credit, from its billing docs via a web search), or, for a chat on your own API key, its tokens at the
  model's API price from ctop's price table (Claude models). That token figure is an upper estimate: the
  chat file doesn't say how many prompt tokens were cache reads. Peek shows the credits and the token
  price. The dollars also count in the cost sort and the session totals
- an unanswered chat is live only if it was written in the last 7 days, as documented: with the keep
  window at ∞, chats unanswered 24 to 84 days ago were listed as live (`waiting`, `stalled`); they are now
  gone rows
- LAST ACTION shows a reply's text from its last tool call on, its pieces joined. VS Code splits a reply
  around inline file references, and the last piece alone read like `** is a PowerShell`

## 2026.11.10.3 — Sol's round 3 of step 3: F2

- a Copilot chat file is taken as appended to only if it still starts with exactly the bytes read before
  (their SHA-256 matches); anything else is read from the start. Sol's case got past every earlier check: a
  rewrite exactly as long as what was read, ending in a newline, then a new line appended before ctop read
  again. Each change to a chat file now reads the whole file (65 to 115 ms for a 27 MB chat, PowerShell 7 on
  Linux); only what follows the old offset is parsed

## 2026.11.10.2 — Sol's round 2 of step 3: F3

- unanswered Copilot chats older than an hour are looked for in the last 7 days, not in every chat ever
  written: reading them all took 36 to 74 s on Sol's copy of 642 real chats (486 MB), and held up the
  screen for up to 6 s at a time. An older unanswered chat is listed once the keep window reaches it
- while ctop reads chat files it has left for later, the strip shows a `copilot` cell with the MB read so
  far, the total, and an estimate of the time left (`copilot 40/286MB ~25s`). The cell goes when the reading
  is done. A single large file is read in one go; if that takes over 5 s, the screen's age shows as usual

## 2026.11.10.1 — Sol's round 2 of step 3: F2

- a Copilot chat file that VS Code rewrote is read from the start whenever the byte before the point
  read up to is no longer a newline, or nothing follows it. Two rewrites were still taken for appends: one
  with no final newline whose old read point fell on a `{` inside it (Sol's case), and one exactly as
  long as what was read before

## 2026.11.02.5 — Sol's audit of step 3 (2026.11.02.4)

- a gone Cline session's or Copilot chat's row shows what its files say once they are read: a read left
  for a later frame, or one that failed (a locked file), showed the old cost and last action under the
  files' new times, and the row kept them after the read caught up
- a Copilot chat file that VS Code rewrote into one bigger entry with the same start is read from the
  start: it was taken for an append, failed, and its old summary stayed until the next write
- while VS Code runs, an unanswered Copilot chat older than an hour is listed from ctop's first poll (it
  was listed only if this ctop had read it before). Older chats are each read once, a few per poll, and
  a finished one is not read again until it changes

## 2026.11.02.4

- GitHub Copilot chats in VS Code are listed, with VIA `copilot`, read from VS Code's own chat files:
  `User/workspaceStorage/<id>/chatSessions/*.jsonl` and `globalStorage/emptyWindowChatSessions/` (a
  mutation log, replayed from where the last read stopped). STATE from the newest request: working
  (pending), waiting (needs your input), stalled (pending, no write for 10 min), idle, error. A chat is
  live while VS Code runs and it was written in the last hour or is unanswered; otherwise it is gone, for
  the keep window. COST is in Copilot credits, not dollars; CTX from the request's context usage; the
  folder from the workspace's `workspace.json`. VS Code's folder follows `VSCODE_PORTABLE` /
  `VSCODE_APPDATA` as VS Code does
- a window made smaller while a frame was being drawn no longer stops ctop ("SetCursorPosition … must be
  less than the console's buffer size", seen on Windows with 2026.11.01.3): the cursor stays inside the
  buffer, and the next frame redraws at the new size
- the agent probe (2026.11.02.3) names a Copilot reply's parts by kind and field names

## 2026.11.02.3 — Sol's audit of PRs #3 and #4 (2026.11.01.3 to 2026.11.02.2)

- an ended Cline session shows its final cost, tokens and last action: a conversation that changed after
  it was cached is read again (it showed what was cached while the session ran)
- a malformed Cline manifest or conversation is not parsed again until it changes, so one broken file can
  no longer use up every frame's reading time and keep older sessions from loading; a file that could not
  be opened is tried again after 5 s
- `-Snapshot` reads every Cline session before it prints (it printed after two frames' worth), and notes
  any file that was left for later. A file that cannot be read or parsed is not retried there: its row
  shows what was read of it before, or nothing
- without the `claude` command, a registry entry caught half-written no longer ends its session: while
  its process runs, the session stays listed (it was shown as gone and logged as closed)
- a gone session keeps its VIA label when ctop is restarted (the closed log had it; it was not read back)
- the agent probe (2026.11.02.2) reads a transcript line's `entrypoint`, `version` and `userType` only at
  its top level, as labels: fields of the same names inside a tool's input were printed

## 2026.11.02.2 — from a review of 2026.11.01.3

- release notes moved here from the script's `.NOTES` help section, which keeps the version line
- `CTOP_TRACE=<file>` also records the errors ctop swallows (it runs with `$ErrorActionPreference`
  SilentlyContinue and reads many files inside an empty `catch`): each distinct one once, with its
  script line, 200 at most a process. Errors already in your PowerShell's `$Error` are left out
- peek's PRICES line, and the help for COST, say where COST's prices come from: the built-in table and
  the date it was read (2026-10-20), or your `-PricingFile`

## 2026.11.02.1

- Cline sessions, read from Cline's own files: `~/.cline/data/sessions/<id>/<id>.json` (the manifest:
  status, pid, model, cwd, times) and `<id>.messages.json` (tokens, cost, the last action). No SQLite
  and no cline command needed. An open session counts while its pid (in VS Code, the window's
  extension host) runs and started no later than the session; ended ones stay for the keep window.
  VIA reads cline; peek, n and d work for them; y has no resume command to copy

## 2026.11.01.4

- runs without the claude command: VS Code alone (its built-in Claude agent) leaves none. ctop then
  reads Claude Code's live-session registry, `~/.claude/sessions/<pid>.json`, itself, keeping an
  entry only while its process runs and started no later than the session (a leftover file whose
  pid went to another process is dropped). With claude installed, `claude agents --json` stays the
  roster. Verified: VS Code's Claude agent writes that registry and a transcript, on a Windows
  machine with nothing from Anthropic installed
- VIA column: what a session runs in, from its registry entrypoint: cli, vscode (the Claude Code
  extension), sdk (the Claude Agent SDK: VS Code's own Claude agent, or another program on it)

## 2026.11.01.3 — the audit's second round

- a process-table read still running when ctop exits (a snapshot that gave up on a slow ps) is
  ended by ending its ps; ctop no longer ends the whole PowerShell process to stop it, which ended
  the PowerShell that ran it (& ./ctop.ps1 -Snapshot; the next command never ran)
- a question for you stays "asks:" when the reply's other calls are separate transcript lines (as
  Claude Code writes them) and one of them gets its result first; an answered question no longer
  outranks a newer call in the same reply
- CTOP_TRACE: one more phase, when the worker's process has started

## 2026.11.01.2 — the audit of the worker build (2026.11.01.1)

- t / y / n / d copy the session selected when the key was pressed, even if the selection moves
  before the worker's next frame comes in; a session gone by then is not copied, and the footer says so
- relative -PricingFile / -ClosedLog / -ConfigDir paths are made absolute, and the worker starts in
  PowerShell's current directory: a relative pricing path made the worker fail and ctop fall back
- -Snapshot waits (up to 10 s) for the process table, so a running job shows; if it is not in by
  then, the snapshot says so. A slow process read no longer holds the exit
- in one process (-InProcess), a tick counts from the start of the last frame, not its end
- n: no @address for a session without a name (it has none to message until you /rename it)
- "updating…" shows only when a key's own frame is late (it could show for an earlier key)
- a frame the display asked for and has not had for 5 s says so on the footer, counting up; a worker
  that sends something other than a frame is dropped, and ctop carries on in one process
- the worker starts before the rest of the script loads, and the first frame shows live sessions
  before it lists history: here ~0.3 s sooner. The worker still costs ~0.5 s here at startup; the
  ~2 s the audit measured on WSL is not reproduced here (CTOP_TRACE times each phase)
- a question for you stays "asks:" when another call made in the same reply gets its result first
  (the answer is matched to the question's call id)
- -PricingFile refuses an infinite rate (1e400)
- an unknown flag or a stray value is an error that names it: 500 was taken as -Tick
- `CTOP_TRACE=<file>`: append startup timings (process start to first frame) to that file

## 2026.11.01.1

- two processes: this one reads keys and draws; a hidden worker (the same script, -Worker) reads
  transcripts, the roster and the process table and builds frames. A slow frame no longer holds up
  keys: q quits at once while the first read of a ~70 MB transcript takes seconds (it waited for the
  whole frame before), and a key pressed meanwhile shows "updating…". If the worker cannot start or
  stops, ctop carries on in one process and says why. -InProcess runs as one process. From cxtop
- frame on the strip is now the time to build a frame; drawing is the display process's

## 2026.10.31.12

- -PricingFile: your own price table in place of the built-in one (JSON; every rate required; a bad
  file stops ctop with exit 2 and the reason). Cached costs are versioned by the file's content, so
  editing it recomputes them. From cxtop
- a scan cache priced by anything but the built-in table could not be read at all (the price version
  was cast to a number): it was silently dropped and every transcript rescanned

## 2026.10.31.11

- a session waiting on a question for you (AskUserQuestion) shows it: LAST ACTION reads asks: &lt;the
  question> (+N more), and peek lists each question with its header and numbered choices. Once a
  newer entry answers it, asked:. From cxtop's pending-question view; answer in that session

## 2026.10.31.10

- -Snapshot prints one frame as plain text and exits: every session listed, not a screenful; no
  colors or keys; nothing written (scan cache, closed log). For pipes, files and sharing. From cxtop.
  Without a console (a pipe) ctop had no window size to draw with: everything now asks one place
- the strip's "hidden N cols" ran into the next divider at two digits

## 2026.10.31.9

- n copies the selected session's contact (name and @address, session ID, kind, state, directory,
  machine, transcript, attach or resume command) to paste into another Claude session, which can
  message it by name with Claude Code's own messaging. ctop sends nothing. d copies the session ID
  (a subagent's agent ID). From cxtop's contact and ID keys

## 2026.10.31.8 — the validation's second round

- Windows PowerShell 5.1: stopping a poll could stop an unrelated process after a pid was reused
  (a parent id names whichever process had that pid). A child is followed only if it was created
  after its parent, and stopped only if its pid still names it
- a gone row is keyed on its transcript's path as well (a row could keep showing another file),
  and the key is taken before the row is built: a subagent write during the build was folded into
  the key but not into the cost, so the cost never caught up
- paths compare case-sensitively in every cache: on Linux a.jsonl and A.jsonl are two files
- a combining mark outside the BMP (a surrogate pair) is kept with its letter when text is cut
- a first prompt in Hebrew, Chinese, Russian and other scripts becomes the title: it needed three
  ASCII letters (such sessions read "(untitled)"), now three letters in a row of any script. Not
  every script has those: Hindi or Tamil, which write vowels as marks between letters, can still
  read "(untitled)". Cached scans are redone once (ScanVer 4)
- titles in Hebrew, Arabic, Armenian, Georgian, Chinese, Japanese, Korean and other scripts without
  combining marks are measured at the speed of ASCII: a screen of Hebrew titles took a frame from
  ~55 ms to ~175 ms
- tests: each view's clipboard check stands alone; a key counts as answered only when the strip
  and footer both show its effect; Build-Rows is tested directly

## 2026.10.31.7 — fixes from the audit's validation round

- LAST ACTION could show another transcript's last action: its cache checked size and time, not
  which file it was
- a transcript replaced by one whose start differed only in letter case once encoded (@ vs Z) read
  as the same file: the start is compared case-sensitively. A longer rewrite that keeps the first
  256 bytes still reads as an append (Claude Code only appends)
- a STATE with a +N subagent badge and wide text pushed the next columns out of line
- a wrapped path with wide characters could take more lines than -WrapLines
- LAST ACTION and a failed poll's reason are shortened without cutting a character in half (an
  emoji at the cut left half a surrogate pair)
- widths: the fast path covers only characters that are one cell on their own and never join the
  one before (a soft hyphen, Arabic number signs and bidi isolates were counted as one cell); a
  flag is two cells (four on Windows PowerShell 5.1, whose .NET splits the pair)
- a gone session's tree cost follows its subagent transcripts as they grow; a new subagent file
  of a gone session is found when its own transcript changes, or at the next start
- Windows PowerShell 5.1: a poll that hangs is stopped with everything it started (claude.cmd's
  node outlived its cmd.exe). Linux: a process that outlives claude and holds its output is not
  stopped (it is no longer claude's child); ctop still drops the poll and polls again
- tests: the integration tests run on a private tmux server and never touch yours; the clipboard
  test proves the terminal accepts OSC 52 before it trusts a clean result

## 2026.10.31.6 — fixes from an outside audit of the branch

- nothing live but history in the keep window: the history was not drawn (the table was skipped
  whenever no session was live), and peek / t / y could act on a row no longer shown
- ages of a day or more (1d4h) colored as fresh: the age parser ignored days
- background sessions from the closed log were listed without -All; they follow -All like live ones
- a session with an impossible startedAt stopped ctop; ages it can't read show as -
- a lone session whose row fits on one line was drawn as nothing (a one-line body)
- a roster poll that hangs is stopped after max(5 s, 5 × -RosterInterval) and counted as failed;
  the last roster stays on screen and the next poll starts. It used to block every later poll
- session text (titles, paths, tool arguments) can no longer send terminal commands: control
  characters and escape sequences other than colors are removed before drawing (an OSC 52 in a
  title could set your clipboard from peek or the closed log)
- a transcript that is replaced, cut short or moved is rescanned from the start; one that only
  grew is still read from where the last scan stopped
- a prompt that mentions tool_result counts as a turn again (it was taken for a tool result).
  Cached scan state is redone once (ScanVer 3)
- a gone session's TREE COST still counts its subagents (their part dropped to $0 once it left)
- columns line up with CJK and other wide characters, emoji and combining accents: widths,
  padding and cuts are measured in terminal cells, not string length, and a cut never splits
  a character
- frame in the help is the time of the whole last pass (roster, process harvest, cache save,
  build, draw); the cache save was left out
- a fatal error exits with code 1 and prints its message on stderr
- tests: the quit test fails a crash exit; the frame and key timing tests refuse a frozen or
  exited ctop; CI fails a job that claims to run the integration tests and skips them

## 2026.10.31.5

- Linux without the clear program (minimal Fedora / RHEL images): ctop stopped at once with "The
  expression after '&' …": PowerShell's Clear-Host runs clear. The screen is cleared with the same
  escape sequences instead
- Windows PowerShell 5.1 runs it again (unit tests pass there in CI): the file is UTF-8 with a BOM
  (5.1 read it as ANSI and could not parse it); no [Array]::Sort[T](…) generic-call syntax (7.3+);
  a session with exactly one subagent listed it again on 5.1; the scan cache loads on 5.1 too
  (it needed ConvertFrom-Json -AsHashtable, so every start rescanned every transcript); the mouse
  helper's file name no longer needs SHA256.HashData (.NET 5+), which turned the mouse off on 5.1

## 2026.10.31.4

- only rows on screen are refreshed and styled each frame: a gone row off screen costs next to nothing
  (300 gone rows now cost about what the visible screenful does: ~25–35 ms a frame, was ~140 ms).
  A row that scrolls into view is refreshed before that frame is drawn, so a visible age is never
  stale; whether a gone transcript changed is checked every 30 s for rows off screen
- gone rows sort with a .NET sort (newest gone first; ties by session id, so rows that left in the
  same poll never swap); in roster sort they follow that order too instead of their stale position.
  Title-bar counts are one pass over the rows

## 2026.10.31.3

- titles with quotes, newlines or non-ASCII read right: \" was shown literally (escapes were only
  undone when the text held a double backslash). Cached scan state is redone once (ScanVer 2)
- t / y on Linux: sent to the terminal as OSC 52 (and to xclip when there is a display). Set-Clipboard
  without xclip keeps the text inside pwsh and reports success, so "copied" was shown for nothing

## 2026.10.31.2

- keep window: one setting, -Keep (alias -Linger), for how long gone sessions and stopped subagents
  stay listed; + / - step 0 · 15m · 30m · 45m · 1h · 2h · 4h · 8h · 12h · 1d · 2d · 3d · 7d · 14d ·
  30d · ∞ at runtime, shown as keep on the strip and in the footer. 0 = drop at once and ∞ = forever,
  for both (-SubagentWindow still works; its 0 still means forever). Tick moved to [ / ]
- gone sessions from earlier runs are read back from the closed log (which now also records kind and
  the /clear successor), so a long window shows yesterday's sessions, newest gone first, with their
  logged title; peek says when Claude Code has deleted a transcript (cleanupPeriodDays) instead of
  offering a resume that cannot work
- keys are read every frame however long it took: a frame slower than the tick stopped ctop reading
  the keyboard at all, q included (seen with ~150 gone rows)
- faster with many rows (300 gone rows: ~1.6 s a frame → ~0.15 s): gone rows are built once and
  reused, sorting no longer scans every row per session, a history row's sparkline no longer changes
  (which re-rendered every row every 2 s), and history loads ~120 ms of rows per frame, newest first,
  so live sessions show at once (cold start with 300: 7.9 s → 1.4 s)
- ages past a day read 1d1h / 40d instead of 25h / 960h
- tests: Pester unit tests and an end-to-end test that drives ctop in tmux (tests/)

## 2026.10.31.1

- a failed `claude agents --json` poll (non-zero exit, no output, not a JSON array) keeps the last
  roster: it was read as an empty one, so every session flashed "gone" and was written to the
  closed log as closed. The strip shows poll FAILED×N; roster age counts from the last good poll

## 2026.10.27.1

- a new subagent reads thinking from its first second: its prompt can sit behind ~10 large setup
  attachments, past the 256 KB tail ctop read, which left STATE blank until the first reply

## 2026.10.21.5

- mouse (Windows): click selects, click again / double-click peeks, wheel moves, footer items
  click, a click closes peek. -NoMouse to keep the terminal's own mouse. Console mode restored on exit

## 2026.10.21.4

- a subagent whose .meta.json says "finished": true (and whose transcript hasn't grown since) is
  stopped, whatever its transcript's last lines suggest; sidecars are re-read when they change

## 2026.10.21.3

- Σ tree cost under a session's COST (session + all its subagents, listed or aged out, + sessions
  it launched); peek has the breakdown
- scrolling: a wrapped row cut by the window edge is left out instead of shown half

## 2026.10.21.2

- also while thinking: parallel Agent calls return one by one, so a parent waiting on the rest
  read "thinking"; with a live foreground agent it started, it now reads awaiting agent

## 2026.10.21.1

- a session or subagent whose open Agent / Task / Skill call is waiting on a live agent it
  started reads "awaiting agent" (cyan), not a red "working" that suggested waiting on you

## 2026.10.20.2

- sessions launched from another session's job (e.g. a script running claude -p) are drawn
  under that session, after its subagents, with their own subagents below them; peek shows
  LAUNCHED BY (launcher, job pid, command) and, on the launcher, LAUNCHED
- Linux: ps -ww, so long command lines aren't cut to the terminal width

## 2026.10.20.1

- prices re-read 2026-10-20: Opus 5.5 ($4 / $20, cache read $0.20; was priced as Opus 5 at
  $5 / $25 / $0.50, overstating it), Sonnet 5.5, Haiku 5.5 (tiered at 100k-token prompts).
  Cached cost totals from the old table are recomputed once.

## 2026.10.19.1

- a subagent that handed back and was then sent a new message (resumed) shows its live state,
  LAST ACTION "resumed · after handback: …"; it stayed "stopped"

## 2026.10.18.2

- startup no longer opens every cached transcript (27 s for 1,049 files on Windows): cache
  entries are checked on first use and forgotten after 2 days unused; the 60 s save no longer
  tests every path either

## 2026.10.18.1

- an agent stopped by Esc / TaskStop ("[Request interrupted by user]" as its last line) reads
  stopped (subagent) or idle (session), LAST ACTION "interrupted · was …"; it showed thinking

## 2026.10.06.2

- version moved from beside the clock (where it read as the current date) to "build" on line 2

## 2026.10.06.1

- subagent .meta.json is retried while missing or half-written (was cached as "none" forever,
  leaving a bare id and no title)
- job → agent attribution compares times in UTC (after a restart, cached call times came back
  as UTC and every job fell to the session)
