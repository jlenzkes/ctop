# ctop

A `top`-style live view of your running [Claude Code](https://code.claude.com) sessions, in the terminal.

ctop polls `claude agents --json` for the session roster, then fills in each row from local
sources: the session's transcript under `~/.claude/projects/`, and the OS process table. It shows,
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
- **Claude Code** on `PATH`, with the `claude agents --json` command. ctop stops with an error
  at startup if `claude` can't be found.
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

If you download the script as a file instead of cloning, Windows may block it under the
`RemoteSigned` execution policy. Unblock it once:

```powershell
Unblock-File ./ctop.ps1
```

## Usage

```powershell
./ctop.ps1                      # interactive sessions, default settings
./ctop.ps1 -All                 # include background sessions too
./ctop.ps1 -Sort cost -Compact  # most expensive first, essential columns only
./ctop.ps1 -NoSubagents -Keep 1d      # also list sessions that closed in the last day
./ctop.ps1 -Version
```

Press `h` while it runs for the full help: every column, every STATE, the colors, and how to read
them. `Get-Help ./ctop.ps1 -Full` prints the parameter reference and release notes.

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
| `-Version`        |                    | Print the version and exit. |

### Keys

| Key                  | Action |
|----------------------|--------|
| `↑` `↓` `PgUp` `PgDn` `Home` `End` | Move the selection |
| `Enter` / `Space`    | Peek: a live detail screen for the selected session (`↑` `↓` switch session, `Esc` closes) |
| `t`                  | Copy the selected row's transcript path (see [Copying](#copying)) |
| `y`                  | Copy its `claude --resume <id>` command |
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

What has actually been run, as of build `2026.10.31.5`. Anything not listed here is untested.

**CI** ([workflow](.github/workflows/ci.yml)), on every push. *Unit*: the Pester unit tests (157).
*End to end*: the integration tests (9), which drive the real ctop in tmux against a fake `claude`
and a 300-session history.

| Platform | PowerShell | Unit | End to end |
|---|---|---|---|
| Windows Server 2025 (GitHub `windows-latest`) | Windows PowerShell 5.1.26100 | ✅ | not run (needs tmux) |
| Windows Server 2025 (GitHub `windows-latest`) | 7.6.7 | ✅ | not run (needs tmux) |
| Ubuntu 24.04 (GitHub `ubuntu-latest`) | 7.6.9 | ✅ | ✅ |
| Ubuntu 22.04.5 (container) | 7.6.9 | ✅ | ✅ tmux 3.2a |
| Debian 12 bookworm (container) | 7.6.9 | ✅ | ✅ tmux 3.3a |
| RHEL 9.8 (UBI 9 container) | 7.6.9 | ✅ | not run: UBI's repositories have no tmux |
| AlmaLinux 9.8, a RHEL 9 rebuild (container) | 7.6.9 | ✅ | ✅ tmux 3.2a |
| Rocky Linux 9.8, a RHEL 9 rebuild (container) | 7.6.9 | ✅ | ✅ tmux 3.2a |
| Fedora 44 (container) | 7.6.9 | ✅ | ✅ tmux 3.8 |

Each job also checks that the script parses and that `-Version` runs. The two PowerShell 7 jobs on
GitHub's own runners (Windows, Ubuntu 24.04) also run PSScriptAnalyzer.

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
  terminal cells, so CJK, emoji and accented names line up; ctop's width table covers the common wide
  ranges, and a terminal that disagrees about a character's width will shift that row.
- COST is computed at API list price from per-turn token usage, the same basis as `/usage`. It
  is not your plan's billing.

## Versioning

ctop uses calendar versioning: `YYYY.MM.DD.N`, the build date followed by that day's build number.
The version is shown on the instrument strip, the help screen and any crash message.

Release notes are kept in the script's `.NOTES` help section. When cutting a build, update both
`$script:CtopVersion` and the `VERSION` line in `.NOTES`. CI checks that they match.

## Development

Tests use [Pester](https://pester.dev) 5:

- `tests/Keep.Tests.ps1`, `Display.Tests.ps1`, `Transcript.Tests.ps1`, `Clipboard.Tests.ps1`,
  `Encoding.Tests.ps1`: unit tests. They load the functions from `ctop.ps1` without running it
  (`tests/Import-Ctop.ps1`), so they need no `claude` and no terminal.
- `tests/Integration.Tests.ps1` (tag `Integration`): drives the real ctop in tmux against a fake
  `claude` and a 300-session history, checking that keys are never dropped, that frames stay within the
  tick, that off-screen history is nearly free, that a row scrolled into view shows its current age,
  and that the live sessions show before the history has loaded; also sessions coming and going, a hung
  roster poll, hostile session text, wide characters and a clean exit. Linux, with `tmux`.

```powershell
Install-Module Pester -RequiredVersion 5.9.1 -Scope CurrentUser
./tests/Run-Tests.ps1                     # everything; fails if the integration tests are skipped
./tests/Run-Tests.ps1 -Integration Skip   # unit tests only (Windows, or no tmux)
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
