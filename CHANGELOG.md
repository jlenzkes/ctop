# ctop changelog

Calendar versioning: `YYYY.MM.DD.N`, the build date, then that day's build number. Newest first.

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
