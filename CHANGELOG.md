# ctop changelog

Calendar versioning: `YYYY.MM.DD.N`, the build date, then that day's build number. Newest first.

## 2026.11.23.24 — fixes from two code audits

- **`-Snapshot` lists every Copilot CLI session** in the keep window. It listed as many as it could read in 120 ms
  (2 of 137 on one machine), and its note spoke of rows it had not printed.
- **COST counts each reply once.** Claude Code writes a reply as several lines, and can write it again much later,
  copied whole or with every count 0. A reply whose lines had another reply's between them, or that came again, was
  counted again (14 of 4,542 real transcripts, 0.4% to 30% over), and a zeroed copy could undo a reply's cost.
  Checked against one charge per reply on 221 real transcripts: equal on every one. Saved scans are redone once.
- **A Copilot CLI question to you shows `waiting`** (its `ask_user` tool), not `working`.
- **A `claude` command that will not start** (uninstalled, or caught mid-update) no longer stops ctop: that poll
  reads Claude Code's session registry instead.
- **TURN and CMP are right after a restart on Windows PowerShell 5.1**: the turn start and last compaction it had
  saved came back off by the UTC offset.
- **`y` copies a Copilot CLI session's resume command** (`copilot --resume <id>`), peek shows it for an ended
  interactive session too, and `y` says so when a session has no resume command.
- **More footer items can be clicked**: `v truncate`, and each key of `t/y/n/d copy` and `+/- keep`.
- **A git submodule is no longer shown as a linked worktree** (`wt:`).
- **Session text cannot recolor peek or the closed-sessions list**: escape sequences in it are taken out.
- **Liveness compares times as instants**, so a Copilot CLI session is not shown gone across the autumn clock
  change, and a process whose start time cannot be read (one ctop may not open) is no longer taken for no process.

## 2026.11.23.23 — first build in this repository

ctop is `top` for AI coding agents: one PowerShell script that shows every Claude session on the computer, live, in
one terminal window. It reads files on the computer and makes no model calls, so watching costs no tokens.

- **The agents it watches** (VIA column): Claude Code, the CLI and the VS Code extension (`cli`, `vscode`); GitHub
  Copilot's Claude agent in VS Code (`sdk`); GitHub Copilot chats in VS Code, on any model or your own Claude API key
  (`copilot`); the GitHub Copilot CLI (`copilot-cli`); and Cline (`cline`). None needs the others: ctop runs with only
  VS Code and Copilot installed, and nothing from Anthropic. Claude Code's background sessions show with `-All`.
- **STATE** says what each session is doing: `working`, `thinking`, `idle`, `awaiting`, `polling`, `error`, `gone`,
  and `waiting` (blocked on you by a question or a permission prompt), shown in red.
- **CACHE** estimates the minutes before a Claude Code session's prompt cache goes cold, and **RECACHE** what writing
  the context back costs once it has.
- **CTX** is the context size, with the estimated auto-compact point under it; CMP counts compactions.
- **COST** is the spend at API list price, with `Σ` summing a session with its subagents and the sessions it
  launched, and **RATE** is dollars an hour; `-PricingFile` replaces the built-in price table.
- **LAST ACTION** shows the newest tool call, the start of the last reply, a question for you (`asks:`), or a
  subagent's report.
- **Peek** (`Enter`) is a live page for one session. On Windows the mouse selects rows and opens peek, and resting
  the pointer on a cell opens a box with its whole value and what the column means.
- **The keep window** (`+` / `-`, from `0` to `∞`) keeps closed sessions and stopped subagents on screen. Closed
  sessions are logged with their resume commands (`x`), and gone rows from earlier runs are read back from that log.
- **Contacts:** `n` copies a session's contact, to paste into another Claude Code session so it can message that
  one; `y`, `t` and `d` copy its resume command, transcript path and session ID.
- Runs on Windows and Linux (macOS is untested), on PowerShell 7 and Windows PowerShell 5.1.
