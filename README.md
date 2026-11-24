# ctop

**`top` for your AI coding agents.** Every Claude session on your computer, live in one terminal
window: Claude Code (CLI and VS Code), GitHub Copilot in VS Code (its chats and its Claude agent), the
GitHub Copilot CLI, and Cline. Which one is waiting on you, what each is doing, what it's costing, and
how long before its prompt cache goes cold. (Claude Code's background sessions show with `-All`.)

```text
  ctop  14:02:11                                                          4 sessions  ·  3 working  ·  1 idle  ·  1 subagents

NAME            TITLE              STATE     CACHE  RECACHE  TURN    CTX  CMP  LAST ACTION                MODEL          COST
--------------  -----------------  --------  -----  -------  ----  -----  ---  -------------------------  ----------  -------
billing         Migrate to the v2  waiting      3m      $10   57m   640K    3  asks: Drop the old         fable-5-2    $48.75
                API                                                /967K       invoices table?                         Σ$51.00
  └ Explore     Find every caller  thinking    55m    $0.31    1m    78K       Grep "chargeCustomer"      sonnet-5-5    $2.25
api-server      Fix flaky auth     working     52m    $1.84    4m   230K    1  Bash npm test -- auth      opus-5-5     $12.40
cpcli-3f2a91c0  Review prompt.md   working       -        -    2m    96K       view prompt.md             fable-5-2     $3.20
docs-site       Rewrite the intro  idle       cold    $2.10         262K       text: Here's the new …     opus-5-5      $6.20
```

*An illustration: your sessions, and which columns fit your window, will differ.* Read it in five
seconds: **billing** is waiting for your answer to a question (on screen it's red, and sorted to the
top), its cache goes cold in about 3 minutes, and missing that costs about $10 to write its context back.
**docs-site** has already gone cold. The `cpcli-` row is a GitHub Copilot CLI job.

## Why it's worth your time

You run agents in several VS Code windows and a couple of terminals. Each one, on its own, is easy to
lose track of. ctop puts them all on one screen and points at the ones that need you.

- **No agent sits waiting for you unnoticed.** A session blocked on you, by a question or a
  permission prompt, turns red, whichever window or terminal it's in; when Claude Code reports it as
  waiting, it also jumps to the top. LAST ACTION shows the question (`asks:`).
- **Reply before the cache goes cold, and save the re-write.** The prompt cache lasts 5 minutes or 1
  hour. After that, your next message pays to write the whole context back into the cache.
  **CACHE** estimates the minutes left, reading from the transcript which cache each call wrote and
  timing it as the Claude Code extension for VS Code does (Claude Code sessions only), and
  **RECACHE** says what missing it costs: a 640K-token context on Fable 5.2, at the 1-hour cache-write
  price, is about $10 each time.
- **See the money while it's being spent.** COST per session at API list price, with the session's
  whole tree (its subagents, and sessions it launched) summed under it (`Σ`), and RATE in dollars an hour. A runaway fan-out of subagents shows up as it
  happens.
- **See compaction coming.** CTX is the context size; the figure under it (`/967K`) is about where
  Claude Code will compact it, from the model and the settings ctop can see. CMP counts compactions.
- **Find any session again.** Closed sessions are logged with their titles and resume commands (`x`).
  `y` copies a session's resume command (`claude --resume`, or `copilot --resume`); `n` copies a contact you can paste into another
  Claude session, so that one can message it.
- **It costs nothing to watch.** ctop reads files on your computer and makes no model calls, so it uses
  no tokens. It's one PowerShell script: no service, no install step, nothing to configure.

## Try it now

You need PowerShell: PowerShell 7 (`pwsh`), or Windows PowerShell 5.1, which every Windows has.

**Windows:**

```powershell
git clone https://github.com/jlenzkes/ctop.git
pwsh -ExecutionPolicy Bypass -File .\ctop\ctop.ps1
```

(With only Windows PowerShell 5.1, use `powershell` in place of `pwsh`. `-ExecutionPolicy Bypass` is
there because the script isn't signed; to run it without that, `Unblock-File` it once: see
[the execution policy](#windows-the-execution-policy).)

**Linux** ([install PowerShell 7 first](#linux-installing-powershell)):

```bash
git clone https://github.com/jlenzkes/ctop.git
pwsh ./ctop/ctop.ps1
```

**macOS** is untested: the process-table code is written for Linux.

The first start reads the whole transcript of each session it lists; later starts pick up where it
left off, from what it saved. With nothing running, it says so. To update: `git pull` in the
`ctop` folder.

Then: **`↑` `↓`** pick a session, **`Enter`** opens peek (everything about it, live), **`h`** is the
full help, **`q`** quits. On Windows the mouse works too: click a row, double-click to peek, and rest
the pointer on any cell to see its whole value and what the column means.

To start it as `ctop` from anywhere, add this to your PowerShell profile (`$PROFILE`; `powershell` in
place of `pwsh` for 5.1):

```powershell
function ctop { pwsh -NoProfile -ExecutionPolicy Bypass -File C:\path\to\ctop\ctop.ps1 @args }
```

## Reading the screen

The columns that matter most:

| Column | What it tells you |
|---|---|
| **STATE** | `working` (a tool call is running), `thinking` (the model is generating), `idle` (its turn is over: your move), `waiting` (blocked mid-turn on you: a question or a permission prompt; red), `awaiting` (waiting on its own subagent or background job, not on you), `polling` (a wait loop), `error`, `gone` (closed). `working` also turns red after 2 minutes when nothing is running behind the call: usually a permission prompt. |
| **CACHE** | Estimated minutes until the prompt cache expires; `cold` once it has, or after a compaction; `-` when unknown. Yellow near the end. Claude Code sessions. |
| **RECACHE** | Estimated cost of writing the whole context back into the cache once it is cold, at the cache-write price. The next turn's new input and output come on top. |
| **TURN** | How long the current turn has run. Yellow at 10 minutes, red at 30. |
| **CTX** / **CMP** | Context size in thousands of tokens, with the estimated auto-compact point under it (Claude Code rows); compactions so far. |
| **LAST ACTION** | The newest tool call and its main argument, the start of the last reply (`text:`), a question for you (`asks:`), or a subagent's report (`handback:`). |
| **COST** | Spend at API list price, per session; `Σ` sums the session with its subagents and the sessions it launched. Yellow at $100. |

Subagents are listed under the session that started them (`└ Explore`), with their own STATE and COST.
A narrow window hides the least important columns (the strip says how many); peek always shows
everything. The rest (BRANCH, CWD, AGE, PID, CPU, MEM, TURNS, TOOLS, KIND, VIA, RATE, the ACTIVITY
sparkline) are described under `h`, and in the box the mouse shows over each cell.

**Peek** (`Enter`) is a live page for one session: its whole title and last action, every question it
asked you with its choices, the next turn's cost with the cache warm and cold, the cost broken down,
its compactions, its background jobs with their CPU, and how to resume it.

## What it watches

| Agent | VIA | Where ctop reads it |
|---|---|---|
| **Claude Code**, CLI or VS Code extension | `cli`, `vscode` | `claude agents --json`, or the session registry `~/.claude/sessions/` when there's no `claude` command; transcripts under `~/.claude/projects/` |
| **GitHub Copilot's Claude agent** in VS Code | `sdk` | the same: it runs Claude Code underneath |
| **GitHub Copilot chats** in VS Code (any model, your own Claude API key included) | `copilot` | VS Code's chat files |
| **GitHub Copilot CLI**: `copilot`, `copilot -p` runs, VS Code's Copilot CLI agent | `copilot-cli` | `~/.copilot/session-state/` |
| **Cline**, VS Code extension or `cline` command | `cline` | `~/.cline/data/sessions/` |

None of them needs the others. ctop runs on a computer with only VS Code and Copilot installed, and
nothing from Anthropic. [What it reads for each](#what-it-reads-for-each-agent) has the details.

## Can you trust it?

- **It only reads.** It never writes to an agent's files, and ctop itself makes no network calls; with
  `claude` installed it runs `claude agents --json` for the list of sessions. The files it writes are its
  own, in the config folder: a cache, the closed-sessions log, and two small helpers it compiles from
  its own C# source on first use ([Files it writes](#files-it-writes)); `-ClosedLog` and `CTOP_TRACE` can
  put a log elsewhere.
- **It runs as two processes:** a second, hidden PowerShell process (the same script) does the reading,
  so a slow read never holds up the keys ([Two processes](#two-processes)).
- **It spends nothing.** No model calls, no tokens.
- **COST is an estimate at API list price**, from each turn's token counts: the same basis as `/usage`,
  not your plan's bill. A Cline session's COST is the figure Cline records.
- **The transcript format isn't documented.** Columns that come from transcripts (STATE details, LAST
  ACTION, CTX, COST, CACHE) are read defensively and show `-` when something changes, but an agent's
  update can still break one. [Caveats](#caveats) has the rest.

Everything below is reference.

---

## Reference

### Usage

```powershell
./ctop.ps1                      # interactive sessions, default settings
./ctop.ps1 -All                 # background sessions too
./ctop.ps1 -Sort cache          # the cache closest to going cold first
./ctop.ps1 -Sort cost -Compact  # most expensive first, essential columns only
./ctop.ps1 -Keep 1d             # also list sessions that closed in the last day
./ctop.ps1 -Snapshot -MaxWidth 160 > ctop.txt   # one frame, as text
./ctop.ps1 -Version
```

`Get-Help ./ctop.ps1 -Full` prints the parameter reference. Release notes are in [CHANGELOG.md](CHANGELOG.md).

### Parameters

| Parameter         | Default            | Description |
|-------------------|--------------------|-------------|
| `-Tick`           | `250`              | Display refresh period in ms. Adjust at runtime with `[` / `]`. |
| `-RosterInterval` | `2`                | Seconds between `claude agents --json` polls. The poll is asynchronous and never blocks the display. A poll still running after max(5 s, 5 × this) is stopped and counted as failed; the last roster stays on screen. |
| `-NoSubagents`    |                    | Start with subagent rows hidden (their transcripts are still read, for STATE and the tree's cost). Toggle with `s`. |
| `-Compact`        |                    | Essential columns only, whatever the window width. Toggle with `c`. |
| `-Sort`           | `activity`         | `activity`, `roster`, `start`, `cost`, `ctx` or `cache` (soonest to go cold first). Cycle with `o`. |
| `-Layout`         | `wrap`             | `wrap` (long cells wrap inside their column) or `truncate`. Toggle with `v`. |
| `-WrapLines`      | `2`                | Maximum lines a wrapped cell may use. |
| `-MaxWidth`       | `0`                | Cap the table width in columns. `0` = the whole window. |
| `-Keep`           | `15m`              | How long gone sessions and stopped subagents stay listed (see [Keep window](#keep-window)). Minutes, or `45m`, `2h`, `1d12h`, `1w`; `0` = drop at once; `inf` = forever. Adjust at runtime with `+` / `-`. Alias: `-Linger`. |
| `-HighlightModel` | `fable\|mythos`    | Regex. Matching MODEL cells are shown in magenta, so a session on an unintended model stands out. |
| `-ClosedLog`      | `<config>/ctop-closed.jsonl` | Where sessions that leave the roster are logged. View with `x`. |
| `-SelectBg`       | `48;5;238`         | ANSI SGR parameters for the selected row's background. Try `48;5;254` on a light theme, or `7` for inverse video. |
| `-NoColor`        |                    | Disable ANSI colors. |
| `-All`            |                    | Include background sessions (`kind == "background"`). |
| `-NoMouse`        |                    | Windows: leave the mouse to the terminal (see [Mouse](#mouse)). |
| `-PricingFile`    |                    | A JSON price table in place of the built-in one (see [Pricing](#pricing)). |
| `-InProcess`      |                    | Run as one process instead of a display process plus a worker (see [Two processes](#two-processes)). |
| `-Snapshot`       |                    | Print one frame as plain text and exit: every session listed, no colors. It saves no scan cache, closed-log entries or helper DLLs (it may clear stale cache temp files, and `CTOP_TRACE` still writes). Width: `-MaxWidth`, else the window's, else 200. |
| `-Version`        |                    | Print the version and exit. |

An unknown or misspelled flag, or a value with no flag (`./ctop.ps1 500`), is an error that names it.
ctop does not start.

Environment: `CTOP_TRACE=<file>` appends startup timings to that file: each process (display, worker)
writes a line as it reaches each phase, from the script running to the first frame with sessions in it.
Use it to see where a slow start goes. It also records the errors ctop otherwise swallows (it reads
files that other programs are writing, and treats a failed read as "not there yet"): each distinct one
once, with the script line it happened on, so a column stuck at `-` can be traced to a cause.

### Keys

| Key                  | Action |
|----------------------|--------|
| `↑` `↓` `PgUp` `PgDn` `Home` `End` | Move the selection |
| `Enter` / `Space`    | Peek: a live detail screen for the selected session (`↑` `↓` switch session, `Esc` closes) |
| `t`                  | Copy the selected row's transcript path (see [Copying](#copying)) |
| `y`                  | Copy its resume command (`claude --resume <id>`, `copilot --resume <id>`) |
| `n`                  | Copy its contact, to reach it from another Claude session (see [Contacts](#contacts)) |
| `d`                  | Copy its session ID (a subagent: its agent ID) |
| `o`                  | Cycle sort: activity, roster, start, cost, ctx, cache |
| `v`                  | Toggle layout: wrap / truncate |
| `c`                  | Toggle compact columns |
| `s`                  | Toggle subagent rows |
| `g`                  | Toggle gone / cleared rows |
| `x`                  | Closed-sessions log, newest first, with resume commands |
| `r`                  | Poll the roster now |
| `+` / `-`            | Widen / narrow the keep window |
| `[` / `]`            | Slower / faster refresh |
| `h`                  | Help: every column, every STATE, the colors, and how to read them |
| `q`                  | Quit (or close peek) |

### Mouse

On Windows, ctop turns on console mouse input while it runs: click a row to select it, click it again or
double-click to peek, scroll with the wheel, and click footer items. Rest the pointer on a cell and a
box opens under it with the cell's whole value and what the column means; it closes when the pointer
leaves the cell or a key is pressed. QuickEdit is switched off for the duration, so hold **Shift** while
dragging to select text. The console mode is restored on exit. Use `-NoMouse` to keep the terminal's
own mouse behavior.

### Copying

On Windows, `t`, `y`, `n` and `d` use the system clipboard. On Linux they send the text to your terminal
with the OSC 52 escape sequence, which copies it on the machine you are looking at, over SSH too. Most
modern terminals accept it; inside tmux it needs `set -g set-clipboard on` (tmux's default, `external`,
ignores it from applications). With a display and `xclip` installed, the system clipboard is set as
well. (PowerShell's own `Set-Clipboard` on Linux needs `xclip`; without it, it keeps the text inside the
PowerShell process and still reports success, so ctop doesn't rely on it.)

### Contacts

`n` copies the selected session's contact: its name and `@` address, session ID, kind, state, working
directory, machine, transcript path, and its `claude attach` command (background sessions) or
`claude --resume` command (sessions that are gone). Paste it into another Claude Code session on the
same machine and ask it to message that session: Claude Code's own cross-session messaging delivers it,
by name ([docs](https://code.claude.com/docs/en/cross-session-messaging)). ctop itself sends nothing. A
session without a name has no address; give it one with `/rename`. A subagent's contact points at its
parent session.

### Keep window

One setting decides how long rows that are no longer live stay on screen: gone sessions (dimmed,
`gone 5m`) and stopped subagents. `+` and `-` step through

```text
0 · 15m · 30m · 45m · 1h · 2h · 4h · 8h · 12h · 1d · 2d · 3d · 7d · 14d · 30d · ∞
```

and the current value is shown as `keep` on the status strip and in the footer. `0` drops them at once;
`∞` keeps everything. A working subagent is always listed, and a thinking one for at least 15 minutes.

Gone sessions from earlier runs are read from the closed-sessions log at startup, so a window of a day
or more shows yesterday's sessions too, most recently gone first. Claude Code deletes transcripts older
than `cleanupPeriodDays` (30 by default); peek says so for a session whose transcript is gone, since it
can no longer be resumed. A long history loads in slices, newest first, so live sessions show at once;
the strip reads `gone 120/300` until it is all in. Only the rows on screen are refreshed each frame, so
a long history costs about what one screenful does.

`-SubagentWindow` (seconds) is deprecated but still accepted; its `0` means forever.

### Pricing

COST, RATE and RECACHE use a built-in table of API list prices (Claude Code rows, Copilot CLI rows, and
Copilot chats on your own API key). Peek's PRICES line says where they come from. To use other rates,
pass `-PricingFile` a JSON array, in match order (the first row whose `Match` regex fits the model id, and whose `MaxPrompt` if any, wins),
of rates in dollars per million tokens:

```json
[
  { "Match": "opus-5-5",   "In": 4, "W5": 5,   "W1h": 8, "Read": 0.2, "Out": 20 },
  { "Match": "sonnet-5-5", "In": 2, "W5": 2.5, "W1h": 4, "Read": 0.1, "Out": 10 },
  { "Match": "haiku-5-5",  "MaxPrompt": 100000, "In": 0.1, "W5": 0.125, "W1h": 0.2, "Read": 0.01, "Out": 0.5 }
]
```

`In` / `Out` are input and output tokens, `Read` cache reads, `W5` / `W1h` 5-minute and 1-hour cache
writes; every one is required. `MaxPrompt`, optional, limits a row to requests of at most that many
prompt tokens (for tiered prices). The file replaces the built-in table: replies from a model it doesn't
match add nothing to COST (a session with only those shows `-`). Restart ctop after editing the file; it then recomputes the totals saved at the old rates.

### What it reads for each agent

- **Claude Code** (CLI or VS Code extension). With `claude` on `PATH`, ctop runs `claude agents --json`;
  without it, ctop reads the registry `~/.claude/sessions/` itself. Each row is filled in from the
  session's transcript under `~/.claude/projects/` and the OS process table.
- **GitHub Copilot's Claude agent** (Claude, in the chat's list of harnesses). It runs Claude Code
  through the Claude Agent SDK, which registers each session and writes its transcript as the CLI does.
  VIA reads `sdk`. Tested on Windows with nothing from Anthropic installed.
- **GitHub Copilot chats** (any model, a Claude API key included). ctop reads VS Code's chat files,
  `User/workspaceStorage/<id>/chatSessions/` and `User/globalStorage/emptyWindowChatSessions/`. A chat
  counts as live while VS Code runs and it was written in the last hour, or is still unanswered and was
  written in the last 7 days. VS Code saves a chat about once a minute, so a finished reply can show as
  working for up to a minute. COST is in dollars: Copilot credits at $0.01 each, or, for a chat on your
  own API key, its tokens at the model's API price; peek shows both, and says when the file records only
  part of the usage (often only each turn's last model call). There is no PID: the chat runs inside VS
  Code. The format was read from VS Code's source and checked against real chats (Windows, PowerShell 7).
- **GitHub Copilot CLI**: the `copilot` command (interactive, or `copilot -p` runs, such as Claude jobs on
  your own Anthropic key), and VS Code's Copilot CLI agent, which runs the same runtime. ctop reads each
  session's folder, `~/.copilot/session-state/<id>/` (or under `COPILOT_HOME`): `events.jsonl` and
  `workspace.yaml`. A session is live while a process holds its `inuse.<pid>.lock`, and gone at its
  `session.shutdown` (or its log's last write, if it was killed). These sessions are listed whatever their
  KIND (a `copilot -p` run is `headless`), without `-All`. COST is each model call's tokens at the model's
  API price: the CLI records a cost of 0 for a call on your own key; peek says when some calls had no
  price. A question the CLI asks you (`ask_user`) shows as `waiting`. `y` copies `copilot --resume <id>`.
  CPU and MEM are blank. Tested on Windows with CLI 1.0.114.
- **Cline** (its VS Code extension or its `cline` command). ctop reads Cline's own session files
  (`~/.cline/data/sessions/`); no SQLite or `cline` command is needed. COST is what Cline records; CPU
  and MEM are blank, because in VS Code a Cline session's process is the window's extension host; `y`
  has no resume command to copy.

### Two processes

By default ctop starts a second, hidden PowerShell process (the same script) that reads transcripts, the
roster and the process table, so a slow read never holds up the keyboard. Use `-InProcess` to run as
one; ctop falls back to one process by itself if the worker can't start, stops, or sends something it
can't read. The worker costs some startup: about 0.5 s more to the first frame in the Linux container
this was measured in. If a frame is more than 5 s late, the footer says how old the screen is.

### Files it writes

By default in the Claude config directory: `$env:CLAUDE_CONFIG_DIR` if set, otherwise `~/.claude`. ctop
doesn't create that folder: without it, nothing is kept between runs. `-ClosedLog` and `CTOP_TRACE` write
where you point them.

| File                       | Purpose |
|----------------------------|---------|
| `ctop-scancache.json`      | Running totals per transcript, so a restart doesn't rescan every file from the start |
| `ctop-closed.jsonl`        | The closed-sessions log (`x`), also the source of gone rows from earlier runs. Path set by `-ClosedLog` |
| `ctop-con-<hash>-<runtime>.dll` | Windows only: the compiled console-input helper used for mouse support (compiled in memory instead when there is no config folder) |
| `ctop-json-<hash>-<runtime>.dll` | The compiled transcript reader (`core` and .NET's major version, e.g. `core10`, for PowerShell 7; `desktop` for 5.1) |

The cache and the DLLs are rebuilt as needed and can be deleted at any time. Deleting
`ctop-closed.jsonl` clears the closed-sessions history.

### Linux: installing PowerShell

These are the commands CI uses (PowerShell 7.6.10, the 7.6 LTS line):

```bash
# Ubuntu / Debian
curl -sSLf -o /tmp/pwsh.deb https://github.com/PowerShell/PowerShell/releases/download/v7.6.10/powershell_7.6.10-1.deb_amd64.deb
sudo apt-get install -y /tmp/pwsh.deb
```

```bash
# RHEL 9 and rebuilds (AlmaLinux, Rocky), Fedora
sudo dnf install -y https://packages.microsoft.com/rhel/9/prod/Packages/p/powershell-7.6.10-1.rh.x86_64.rpm
```

Microsoft's install docs have pages, with support lists, for Ubuntu, Debian and RHEL, and also document
package repositories for each, which keep PowerShell updated. They have none for Fedora; the RHEL 9
package installs and runs there all the same (Fedora 44 in CI). **Fedora 45 is untested:** it ships
OpenSSL 4 only (`libssl.so.4`), which PowerShell 7.6 could not use to install Pester.

On Linux the process table comes from `ps -ww -eo pid,ppid,etimes,…` (procps) and `/proc/<pid>/stat`;
without `ps`, ctop still runs but can't see background jobs.

### Windows: the execution policy

`ctop.ps1` is not signed. On Windows, PowerShell's execution policy can refuse to run it:

- **Windows PowerShell 5.1** defaults to `Restricted` on client editions, which runs no scripts at all.
- **PowerShell 7** defaults to `RemoteSigned`. It runs scripts written on the computer, but not unsigned scripts
  Windows marked as downloaded from the internet (a browser download, an email attachment).
- An administrator may have set a stricter policy, such as `AllSigned`.

`-ExecutionPolicy Bypass`, as in [Try it now](#try-it-now), applies only to that PowerShell session and
the ones it starts. If the only problem is the downloaded-file mark, you can remove it once instead:

```powershell
Unblock-File C:\path\to\ctop\ctop.ps1
```

A policy set by Group Policy overrides `-ExecutionPolicy`. Then ask whoever manages the computer. ctop
starts its own worker process with `-ExecutionPolicy Bypass` on Windows, so you only need it for the
first launch. On Linux and macOS PowerShell does not enforce execution policies ("Enforcement of these
policies only occurs on Windows platforms": [about_Execution_Policies][ep]).

[ep]: https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_execution_policies

### Caveats

- The roster fields come from `claude agents --json`, which is
  [documented](https://code.claude.com/docs/en/agent-view). The transcript JSONL format is **not**
  documented. The columns ctop takes from transcripts are read defensively and show `-` if the format
  changes, but a Claude Code update can still break them.
- The Copilot CLI's event log is not documented; its folder layout is (`copilot help config`). ctop reads
  the events as CLI 1.0.114 wrote them on the author's machine, and skips an event it does not know.
- Cline's session files are not documented either. ctop reads them as Cline's source writes them
  (`cline/cline` at `a6507a6`; the field names were checked against a real session on Windows), and a
  field it can't find shows `-`.
- Text from sessions (titles, paths, tool arguments) is drawn with control characters and escape
  sequences removed, so a title can't move the cursor or set the clipboard. Widths are measured in
  terminal cells, so CJK, emoji and accented names line up. ctop's width table counts CJK, Hangul,
  fullwidth forms, the main emoji blocks and flags as two cells and combining marks as none; symbols
  that some terminals draw wide (U+2600–27BF) count as one, and a terminal that disagrees about a
  character's width will shift that row. On Windows PowerShell 5.1 a flag counts as four.
- A roster poll that hangs is stopped with what it started: `Kill(entireProcessTree)` on PowerShell 7,
  and on Windows PowerShell 5.1 every process descended from it by parent process id. On Linux a
  process that outlives `claude` and keeps its output open is no longer `claude`'s child and is not
  stopped; ctop drops that poll and polls again all the same.
- Known problems left in place on purpose, each with its source and a possible fix, are in
  [docs/deferred.md](docs/deferred.md).

### Tested on

**CI** ([workflow](.github/workflows/ci.yml)), on pushes and pull requests (a notes-only commit may skip
it): the Pester unit tests (a few apply to one operating system only), and, where tmux is available, the 41
integration tests, which drive the real ctop in tmux against a fake `claude` and a 300-session history:
sessions coming and going, a hung roster poll, hostile session text, wide characters, titles in
non-Latin scripts, and the worker process (busy, and killed). A job that expects the integration tests
fails if any of them is skipped (`tests/Run-Tests.ps1`).

| Platform | PowerShell | Unit | End to end |
|---|---|---|---|
| Windows Server 2025 (GitHub `windows-latest`) | Windows PowerShell 5.1 | ✅ | not run (needs tmux) |
| Windows Server 2025 (GitHub `windows-latest`) | 7.6.10 | ✅ | not run (needs tmux) |
| Ubuntu 24.04 (GitHub `ubuntu-latest`) | 7.6.10 | ✅ | ✅ |
| Ubuntu 22.04 (container) | 7.6.10 | ✅ | ✅ |
| Ubuntu 22.04 (container) | 7.7.0 | ✅ | ✅ |
| Debian 12 (container) | 7.6.10 | ✅ | ✅ |
| RHEL 9 (UBI 9 container) | 7.6.10 | ✅ | not run: UBI's repositories have no tmux |
| AlmaLinux 9 (container) | 7.6.10 | ✅ | ✅ |
| Rocky Linux 9 (container) | 7.6.10 | ✅ | ✅ |
| Fedora 44 (container) | 7.6.10 | ✅ | ✅ |

Each job prints the PowerShell version it ran and runs `-Version`; the jobs on GitHub's own runners also
check that the script parses, and the two PowerShell 7 ones run PSScriptAnalyzer. The Ubuntu 24.04 job runs
`tests/Compare-Versions.ps1` against `main`: the same inputs through both versions, failing if this
one fails a check.

**On real sessions:** the author's daily use on Windows with PowerShell 7, real Copilot chats and real
Copilot CLI sessions on Windows. By hand in an Ubuntu 24.04 container: the roster, transcripts and subagent rows,
background jobs, peek, the keep window, a failed `claude agents --json`, and copying through OSC 52 into
tmux.

**Not tested**

- **Windows PowerShell 5.1, interactively.** Only the unit tests, parsing and `-Version` have run on
  5.1. From reading the code: 5.1 has no ThreadJob module by default, so the process table is read
  inline by whichever process builds the frames (the worker, by default, so keys still respond). The
  mouse is untested on 5.1.
- **The terminal UI on Windows in CI.** GitHub's Windows runners have no console to drive it.
- **VS Code sessions on Linux.**
- **macOS.** The process-table code is written for Linux `ps` and `/proc`.

### Development

Tests use [Pester](https://pester.dev) 5.9.1:

```powershell
Install-Module Pester -RequiredVersion 5.9.1 -Scope CurrentUser
./tests/Run-Tests.ps1                     # everything; fails if the integration tests are skipped
./tests/Run-Tests.ps1 -Integration Skip   # unit tests only (Windows, or no tmux)
./tests/Compare-Versions.ps1              # main's ctop and this one, side by side (Linux, tmux)
```

- **Unit tests**, `tests/*.Tests.ps1`: they load ctop's functions without running it
  (`tests/Import-Ctop.ps1`), so they need no `claude` and no terminal. `Snapshot.Tests.ps1` and
  `Cli.Tests.ps1` run ctop as a process against a fake `claude`, output to pipes, so they run on
  Windows CI too.
- **Integration tests**, `tests/Integration.Tests.ps1` (tag `Integration`): the real ctop in tmux, on a
  private tmux server (`tmux -L`), so your own sessions and options are left alone. They check that keys
  are never dropped, that a frame is built inside the 250 ms tick at the median, that off-screen history
  is nearly free, and that live sessions show before the history has loaded. Linux, with `tmux`.
- `Run-Tests.ps1` is what CI runs. It prints how many unit and integration tests passed, failed and were
  skipped.

`.ps1` files are UTF-8 **with** a byte-order mark: Windows PowerShell 5.1 reads a file without one as
ANSI and can't parse ctop's non-ASCII characters. `.editorconfig` asks editors to keep it, and
`tests/Encoding.Tests.ps1` fails if one goes missing. To run the analyzer locally:

```powershell
Install-Module PSScriptAnalyzer -Scope CurrentUser
Invoke-ScriptAnalyzer -Path ./ctop.ps1 -Settings ./PSScriptAnalyzerSettings.psd1
```

### Versioning

ctop uses calendar versioning: `YYYY.MM.DD.N`, the build date followed by that day's build number. The
version is shown on the status strip, the help screen and any crash message. When cutting a build,
update `$script:CtopVersion`, the `VERSION` line in `.NOTES`, and add the build's entry at the top of
`CHANGELOG.md`; CI checks that all three name the same build.

## License

[MIT](LICENSE)
