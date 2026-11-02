# ctop

A `top`-style live view, in the terminal, of the Claude sessions running on your computer: GitHub
Copilot in VS Code (its chats and its Claude agent), [Claude Code](https://code.claude.com) (its VS Code
extension and its CLI), and [Cline](https://github.com/cline/cline).

ctop takes the list of sessions from Claude Code: from `claude agents --json`, or, without a `claude`
command, from the session registry Claude Code keeps under `~/.claude/sessions/`. Copilot's Claude
agent runs Claude Code underneath, so its sessions are there too. Copilot's own chats come from VS
Code's chat files, and Cline's from Cline's session files. Each row is filled in from local sources: the session's transcript under `~/.claude/projects/`, and the OS process table. It shows,
for every session and each of its subagents:

- **what it's doing now**: working, thinking, idle, awaiting an agent or a background job,
  waiting on you, error
- **how long**: time on the current turn, time since the transcript was last written to, and an
  activity sparkline
- **what it last did**: newest tool call and its main argument, or the start of its last reply
- **what it's costing**: context size, compactions, model, and spend at API list price, per
  session and summed over the whole session tree
- **where it is**: working directory, git branch and worktree, PID, CPU and memory

Everything is read locally. ctop makes no model calls and uses no tokens.

## Requirements

- **PowerShell**: PowerShell 7 (`pwsh`) or Windows PowerShell 5.1. See [Tested on](#tested-on) for
  which versions have been run, and how far.
- **Two processes**: by default ctop starts a second, hidden PowerShell process (the same script) that
  reads transcripts, the roster and the process table, so a slow read never holds up the keyboard. Use
  `-InProcess` to run as one; ctop falls back to one process by itself if the worker can't start, stops,
  or sends something it can't read. The worker costs some startup: about 0.5 s more to the first frame
  in the Linux container this was measured in. If a frame is more than 5 s late, the footer says how old
  the screen is.
- **Sessions to show**, from any of these:
  - **GitHub Copilot in VS Code:**
    - **Its chats** (any model, a Claude API key included). VIA reads `copilot`. ctop reads VS Code's chat
      files, `User/workspaceStorage/<id>/chatSessions/` and `User/globalStorage/emptyWindowChatSessions/`.
      A chat counts as live while VS Code runs and it was written in the last hour or is still unanswered.
      VS Code saves a chat about once a minute, so a finished reply can show as working for up to a
      minute. COST is in Copilot credits (`cr`), not dollars; there is no PID, as the chat runs inside VS
      Code. The file format was read from VS Code's source; ctop has not yet run against a real chat file.
    - **Its Claude agent** (Claude, in the chat's list of harnesses). It runs Claude Code through the
      Claude Agent SDK, which registers each session and writes its transcript like the CLI does. VIA
      reads `sdk`. Tested on Windows with nothing from Anthropic installed.
  - **Claude Code**, its VS Code extension or its CLI. VIA reads `vscode` for the extension. With `claude` on
    `PATH`, ctop runs `claude agents --json`; without it, ctop reads the registry itself.
  - **Cline** (its VS Code extension or its `cline` command). VIA reads `cline`. ctop reads Cline's own
    session files (`~/.cline/data/sessions/`); no SQLite or `cline` command is needed. COST is what
    Cline records; CPU and MEM are blank, because in VS Code a Cline session's process is the window's
    extension host; `y` has no resume command to copy.
- **Operating system**: Windows, or Linux in the Debian and Fedora / RHEL families. On Linux the
  process table comes from `ps -ww -eo pid,ppid,etimes,…` (procps) and `/proc/<pid>/stat`; without
  `ps`, ctop still runs but can't see background jobs. macOS is untested: the process-table code is
  written for Linux `ps` and `/proc`.

## Install

On Linux, install PowerShell 7 first. These are the commands CI uses (PowerShell 7.6.9):

```bash
# Ubuntu / Debian
curl -sSLf -o /tmp/pwsh.deb https://github.com/PowerShell/PowerShell/releases/download/v7.6.9/powershell_7.6.9-1.deb_amd64.deb
sudo apt-get install -y /tmp/pwsh.deb
```

```bash
# RHEL 9 and rebuilds (AlmaLinux, Rocky), Fedora
sudo dnf install -y https://packages.microsoft.com/rhel/9/prod/Packages/p/powershell-7.6.9-1.rh.x86_64.rpm
```

Microsoft's install docs have pages, with support lists, for Ubuntu, Debian and RHEL; I found none
for Fedora. The RHEL 9 package installs and runs there all the same (Fedora 44 in CI). Microsoft also documents package
repositories for each distribution, which keep PowerShell updated.

Then clone the repository and run the script:

```bash
git clone https://github.com/jlenzkes/ctop.git
```

```bash
pwsh ./ctop/ctop.ps1
```

To start it as `ctop` from any directory, add an alias to your PowerShell profile (`$PROFILE`):

```powershell
Set-Alias ctop /path/to/ctop/ctop.ps1
```

#### Windows: the execution policy

`ctop.ps1` is not signed. On Windows, PowerShell's execution policy can refuse to run it:

- **Windows PowerShell 5.1** defaults to `Restricted` on client editions, which runs no scripts at all.
- **PowerShell 7** defaults to `RemoteSigned`. It runs scripts written on the computer, but not unsigned scripts
  Windows marked as downloaded from the internet (a browser download, an email attachment).
- An administrator may have set a stricter policy, such as `AllSigned`.

To run it anyway without changing any setting, start it with `-ExecutionPolicy Bypass`. This applies only to that
PowerShell session and the PowerShell sessions it starts:

```powershell
pwsh -ExecutionPolicy Bypass -File C:\path\to\ctop\ctop.ps1
```

As a `ctop` command in your profile:

```powershell
function ctop { pwsh -NoProfile -ExecutionPolicy Bypass -File C:\path\to\ctop\ctop.ps1 @args }
```

If the only problem is the downloaded-file mark, you can remove it once instead, and keep using `Set-Alias`:

```powershell
Unblock-File C:\path\to\ctop\ctop.ps1
```

A policy set by Group Policy overrides `-ExecutionPolicy`. Then ask whoever manages the computer.
ctop starts its own worker process with `-ExecutionPolicy Bypass` on Windows, so you only need it for the first launch.

On Linux and macOS, PowerShell does not enforce execution policies, so none of this applies. Microsoft's
documentation says "Enforcement of these policies only occurs on Windows platforms". On Linux with PowerShell 7.6.9,
`pwsh -ExecutionPolicy Restricted -File` still ran a script. Source: [about_Execution_Policies][ep].

[ep]: https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_execution_policies

## Usage

```powershell
./ctop.ps1                      # interactive sessions, default settings
./ctop.ps1 -All                 # include background sessions too
./ctop.ps1 -Sort cost -Compact  # most expensive first, essential columns only
./ctop.ps1 -NoSubagents -Keep 1d      # also list sessions that closed in the last day
./ctop.ps1 -Snapshot -MaxWidth 160 > ctop.txt   # one frame, as text
./ctop.ps1 -Version
```

Press `h` while it runs for the full help: every column, every STATE, the colors, and how to read
them. `Get-Help ./ctop.ps1 -Full` prints the parameter reference. Release notes are in [CHANGELOG.md](CHANGELOG.md).

### Parameters

| Parameter         | Default            | Description |
|-------------------|--------------------|-------------|
| `-Tick`           | `250`              | Display refresh period in ms. Adjust at runtime with `[` / `]`. |
| `-RosterInterval` | `2`                | Seconds between `claude agents --json` polls. The poll is asynchronous and never blocks the display. A poll still running after max(5 s, 5 × this) is stopped and counted as failed; the last roster stays on screen. |
| `-NoSubagents`    |                    | Don't scan for or show subagent rows. Toggle with `s`. |
| `-Compact`        |                    | Essential columns only, whatever the window width. Toggle with `c`. |
| `-Sort`           | `activity`         | `activity`, `roster`, `start`, `cost` or `ctx`. Cycle with `o`. |
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
| `-InProcess`      |                    | Run as one process instead of a display process plus a worker (see [Requirements](#requirements)). |
| `-Snapshot`       |                    | Print one frame as plain text and exit: every session listed, no colors, nothing written. Width: `-MaxWidth`, else the window's, else 200. |
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
| `y`                  | Copy its `claude --resume <id>` command |
| `n`                  | Copy its contact, to reach it from another Claude session (see [Contacts](#contacts)) |
| `d`                  | Copy its session ID (a subagent: its agent ID) |
| `o`                  | Cycle sort: activity, roster, start, cost, ctx |
| `v`                  | Toggle layout: wrap / truncate |
| `c`                  | Toggle compact columns |
| `s`                  | Toggle subagent rows |
| `g`                  | Toggle gone / cleared rows |
| `x`                  | Closed-sessions log, newest first, with resume commands |
| `r`                  | Poll the roster now |
| `+` / `-`            | Widen / narrow the keep window |
| `[` / `]`            | Slower / faster refresh |
| `h`                  | Help |
| `q`                  | Quit (or close peek) |

### Copying

On Windows, `t` and `y` use the system clipboard. On Linux they send the text to your terminal with the
OSC 52 escape sequence, which copies it on the machine you are looking at, over SSH too. Most modern
terminals accept it; inside tmux it needs `set -g set-clipboard on` (tmux's default, `external`, ignores
it from applications). With a display and `xclip` installed, the system clipboard is set as well.
(PowerShell's own `Set-Clipboard` on Linux needs `xclip`; without it, it keeps the text inside the
PowerShell process and still reports success, so ctop doesn't rely on it.)

### Contacts

`n` copies the selected session's contact: its name and `@` address, session ID, kind, state, working
directory, machine, transcript path, and its `claude attach` command (background sessions) or
`claude --resume` command (sessions that are gone). Paste it into another Claude Code session on the
same machine and ask it to message that session: Claude Code's own cross-session messaging delivers it,
by name ([docs](https://code.claude.com/docs/en/cross-session-messaging)). ctop itself sends nothing. A
session without a name has no address; give it one with `/rename`. A subagent's contact points at its
parent session. `d` copies just the session ID.

### Mouse

On Windows, ctop turns on console mouse input while it runs: click a row to select it, click it
again or double-click to peek, scroll with the wheel, and click footer items. QuickEdit is
switched off for the duration, so hold **Shift** while dragging to select text. The console
mode is restored on exit. Use `-NoMouse` to keep the terminal's own mouse behavior.

### Keep window

One setting decides how long rows that are no longer live stay on screen: gone sessions (dimmed,
`gone 5m`) and stopped subagents. `+` and `-` step through

```
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

The old `-SubagentWindow` (seconds) still works, and its `0` keeps its old meaning (forever).

## Tested on

What has actually been run, as of build `2026.11.02.3`. Anything not listed here is untested.

**CI** ([workflow](.github/workflows/ci.yml)), on every push. *Unit*: the Pester unit tests (430, less those
that cannot apply: Linux skips the two Windows process tests; Windows skips the two that need a
case-sensitive filesystem; Windows PowerShell 5.1 also skips the flag-width test: 428, 428 and 427 run).
They include the worker run as a real process, the display against a worker that misbehaves, `-Snapshot`
and the command line run as processes, on Windows PowerShell 5.1 too.
*End to end*: the integration tests (41), which drive the real ctop in tmux against a fake `claude`
and a 300-session history, sessions coming and going, a hung roster poll, hostile session text, wide
characters, titles in non-Latin scripts, and the worker process (busy, and killed). Each job fails if a test it is meant to run was skipped (`tests/Run-Tests.ps1`).

| Platform | PowerShell | Unit | End to end |
|---|---|---|---|
| Windows Server 2025 (GitHub `windows-latest`) | Windows PowerShell 5.1.26100.33648 | ✅ | not run (needs tmux) |
| Windows Server 2025 (GitHub `windows-latest`) | 7.6.7 or 7.6.9 (whichever the runner image has) | ✅ | not run (needs tmux) |
| Ubuntu 24.04 (GitHub `ubuntu-latest`) | 7.6.9 | ✅ | ✅ |
| Ubuntu 22.04.5 (container) | 7.6.9 | ✅ | ✅ tmux 3.2a |
| Debian 12 bookworm (container) | 7.6.9 | ✅ | ✅ tmux 3.3a |
| RHEL 9.8 (UBI 9 container) | 7.6.9 | ✅ | not run: UBI's repositories have no tmux |
| AlmaLinux 9.8, a RHEL 9 rebuild (container) | 7.6.9 | ✅ | ✅ tmux 3.2a |
| Rocky Linux 9.8, a RHEL 9 rebuild (container) | 7.6.9 | ✅ | ✅ tmux 3.2a |
| Fedora 44 (container) | 7.6.9 | ✅ | ✅ tmux 3.8 |

Each job also checks that the script parses and that `-Version` runs. The two PowerShell 7 jobs on
GitHub's own runners (Windows, Ubuntu 24.04) also run PSScriptAnalyzer. The Ubuntu 24.04 job also runs
`tests/Compare-Versions.ps1` against `main`: the same inputs through both versions, failing if this one
fails a check.

**By hand**, with a live Claude Code session (Claude Code 2.1.314, PowerShell 7.6.9, Ubuntu 24.04 in
a container): the roster, transcripts and subagent rows, background jobs (a running `sleep` shown as
`polling`), peek, the keep window (`+` / `-`, history from the closed log), a failed
`claude agents --json` keeping the last roster, and `t` / `y` copying through OSC 52 into tmux's
clipboard (with `set-clipboard on`).

**Reported by the author**: Windows with PowerShell 7.6.9, in daily use.

**Not tested**

- **Windows PowerShell 5.1, interactively.** Only the unit tests, parsing and `-Version` have run on 5.1. From reading the code:
  - **Process table:** 5.1 has no ThreadJob module by default, so the process table is read on the display thread every roster poll, which may make the display stutter.
  - **Mouse:** untested on 5.1.
- **The terminal UI on Windows in CI.** GitHub's Windows runners have no console to drive it.
- **VS Code sessions on Linux.**
- **macOS.**
- **Interactive use on the Linux distributions above, beyond the integration tests.**

### Pricing

COST uses a built-in table of API list prices. To use other rates, pass `-PricingFile` a JSON array,
in match order (the first `Match` regex that fits the model id wins), of rates in dollars per million
tokens:

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
match add nothing to COST (a session with only those shows `-`). Editing the file recomputes cached costs.

## Files it writes

All in the Claude config directory: `$env:CLAUDE_CONFIG_DIR` if set, otherwise `~/.claude`.

| File                       | Purpose |
|----------------------------|---------|
| `ctop-scancache.json`      | Running totals per transcript, so a restart doesn't rescan every file from the start |
| `ctop-closed.jsonl`        | The closed-sessions log (`x`), also the source of gone rows from earlier runs. Path set by `-ClosedLog` |
| `ctop-con-<hash>.dll`      | Windows only: the compiled console-input helper used for mouse support |

The cache and the DLL are rebuilt as needed and can be deleted at any time. Deleting
`ctop-closed.jsonl` clears the closed-sessions history.

## Caveats

- The roster fields come from `claude agents --json`, which is
  [documented](https://code.claude.com/docs/en/agent-view). The transcript JSONL format is
  **not** documented. The columns ctop takes from transcripts (STATE details, LAST ACTION, CTX,
  COST, and others) are read defensively and show `-` if the format changes, but a Claude Code
  update can still break them.
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
- COST is computed at API list price from per-turn token usage, the same basis as `/usage`. It
  is not your plan's billing. A Cline session's COST is the cost Cline itself records for each reply.
- Cline's session files are not documented either. ctop reads them as Cline's source writes them
  (`cline/cline` at `a6507a6`; the field names were checked against a real session on Windows), and a
  field it can't find shows `-`.

## Versioning

ctop uses calendar versioning: `YYYY.MM.DD.N`, the build date followed by that day's build number.
The version is shown on the instrument strip, the help screen and any crash message.

Release notes are in [CHANGELOG.md](CHANGELOG.md). When cutting a build, update `$script:CtopVersion`,
the `VERSION` line in `.NOTES`, and add the build's entry at the top of `CHANGELOG.md`. CI checks that
all three name the same build.

## Development

Tests use [Pester](https://pester.dev) 5:

- `tests/Keep.Tests.ps1`, `Display.Tests.ps1`, `Transcript.Tests.ps1`, `Clipboard.Tests.ps1`,
  `Encoding.Tests.ps1`, `Rows.Tests.ps1`, `Contact.Tests.ps1`, `Pricing.Tests.ps1`, `Worker.Tests.ps1`
  (keys, the worker run as a real process, and the display against a worker that misbehaves),
  `Process.Tests.ps1` (its process tests run on Windows only): unit tests. They load the functions from
  `ctop.ps1` without running it (`tests/Import-Ctop.ps1`), so they need no `claude` and no terminal.
- `tests/Snapshot.Tests.ps1` and `Cli.Tests.ps1`: run ctop as a process against a fake `claude` (a shell
  script, or a `.cmd` on Windows), output to pipes: `-Snapshot`, and which command lines it refuses. No
  terminal, so they run on every CI job, Windows included.
- `tests/Probe.Tests.ps1`: `tools/Probe-AgentSources.ps1` (below) against fixtures for every agent, with
  a planted string in every prompt, reply and title that must not appear in its report.
- `tests/Integration.Tests.ps1` (tag `Integration`): drives the real ctop in tmux against a fake
  `claude` and a 300-session history, checking that keys are never dropped, that building a frame (the
  `frame` figure on the strip: building only, not drawing it or sending it from the worker) takes under
  the 250 ms tick at the median while the clock on screen keeps moving, that off-screen history is nearly free, that a row scrolled into view shows its current age,
  and that the live sessions show before the history has loaded; also sessions coming and going, a hung
  roster poll, hostile session text, wide characters, titles in non-Latin scripts, a transcript that
  moves, and a clean exit. Linux, with `tmux`; they run on a private tmux server (`tmux -L`), so your
  own sessions and options are left alone.

```powershell
Install-Module Pester -RequiredVersion 5.9.1 -Scope CurrentUser
./tests/Run-Tests.ps1                     # everything; fails if the integration tests are skipped
./tests/Run-Tests.ps1 -Integration Skip   # unit tests only (Windows, or no tmux)
./tests/Compare-Versions.ps1              # main's ctop and this one, side by side (Linux, tmux)
```

`tools/Probe-AgentSources.ps1` reports what the coding agents that can run Claude leave on a computer:
VS Code's Copilot (its chats and its Claude agent), Claude Code, Cline, and Roo Code and its fork Zoo Code. It is research for
showing their sessions in ctop. For Cline's conversation files it prints only counts and field names. It reads only, and prints where each agent's files are, how many and how
recent, their field names, and values that say nothing about your work (ids, status, model, token counts,
times), never prompts, replies, titles or command lines. Run it while an agent is working:

```powershell
pwsh -File ./tools/Probe-AgentSources.ps1 -OutFile probe.txt
```

`Run-Tests.ps1` is what CI runs. It prints how many unit and integration tests passed, failed and were
skipped, and fails a job that expects the integration tests but didn't run them.

The [CI workflow](.github/workflows/ci.yml) runs the platforms in [Tested on](#tested-on). It checks
that the script parses and that `-Version` works (and matches `.NOTES`), runs
[PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer) for error-level findings, and runs
the tests: unit tests everywhere, integration tests wherever tmux is available.

`.ps1` files are UTF-8 **with** a byte-order mark: Windows PowerShell 5.1 reads a file without one as
ANSI and can't parse ctop's non-ASCII characters. `.editorconfig` asks editors to keep it, and
`tests/Encoding.Tests.ps1` fails if one goes missing. To run the analyzer locally:

```powershell
Install-Module PSScriptAnalyzer -Scope CurrentUser
Invoke-ScriptAnalyzer -Path ./ctop.ps1 -Settings ./PSScriptAnalyzerSettings.psd1
```

## License

[MIT](LICENSE)
