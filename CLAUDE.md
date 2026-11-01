# ctop: notes for Claude

## How to report

- Name guesses and inference as such, in contrast with deterministic proof. Every factual claim is:
  - **verified**: say how (source file at a commit, a command and its output, a test seen red then green);
  - **inference**: say from what;
  - **unverified / a guess**: say what would settle it.
- Never state a negative ("there is no X") as fact without having looked.
- Don't turn one data point into a requirement. Write "tested on X", and say what is untested.

## Pending work: sessions from other agents

**Decision (user, 2026-11-01): ctop supports exactly three agents:**
- **Claude Code:** the CLI and its VS Code extension.
- **GitHub Copilot, built into VS Code:** its chats, including on Claude models or a Claude API key, and its Claude agent.
- **Cline.**

Not Roo Code (shut down), Zoo Code, Kilo Code, Continue or others. The probe (`tools/Probe-AgentSources.ps1`) still reports Roo/Zoo folders as research; ctop does not read them.

Findings so far, each labelled verified, inference or unverified: `docs/research/other-agents.md`.

**Requirement:** assume nothing from Anthropic is installed: no `claude` CLI, no standalone Claude Code, no Claude Code extension. A user may install only VS Code and configure Copilot with a Claude API key. ctop must start and work there; today it stops if `claude` is missing (`ctop.ps1`, `Get-Command claude -ErrorAction Stop`).

**Done on the user's machine (with Claude Code installed), 2026-11-01:**
- Copilot chats on Claude.
- A Cline task on Claude: its manifest status is live.
- VS Code's Claude agent: it registers in `~/.claude/sessions/` with `entrypoint` `sdk-ts`, writes a transcript in `~/.claude/projects/`, and is listed by `claude agents --json`.

Details in `docs/research/other-agents.md`.

**Done on a VS Code-only VM** (Windows 10, Windows PowerShell 5.1, no `claude`, no `~/.claude` before), 2026-11-01:
- Copilot chat on Claude: chats are in `globalStorage/emptyWindowChatSessions/` when no folder is open; Pending, then Complete about a minute later.
- VS Code's Claude agent: it creates `~/.claude/sessions/<pid>.json` (`entrypoint` `sdk-ts`, live status including `waiting`) and a transcript in `~/.claude/projects/`. Signed out of GitHub, it needed `"chat.agentHost.allowSignedOutWhenUsable": true`.

**Research is done; code can start.** First step: ctop starts without `claude` and reads `~/.claude/sessions/*.json` itself.

## Next PR: flaky tests seen in CI (2026-11-01: PR #2, push run 41330600708 for c144eb6)

Same code passed in the other run, so these are flakes, not a code problem; the failed jobs were re-run. **Addressed on this branch:** the timing test now checks the median of 7 gaps (still 416 ms, red, with the bug put back); `Start-Ctop` now prints what tmux says when the pane size is not reported (the cause itself is still unknown).
- **`tests/Worker.Tests.ps1`, 'starts a frame every tick…' (Windows PowerShell 5.1):** asserts the *maximum* gap between frame starts is under 330 ms; one gap was 354 ms. The bug it guards gives ~416 ms. Fix: assert the median gap (and print the max).
- **`tests/Integration.Tests.ps1`, `Start-Ctop` (ubuntu:22.04), in the '300 gone rows' test:** `tmux display -p '#{pane_width}x#{pane_height}'` returned nothing for 5 s, so the test never started. Cause unknown; the log does not capture tmux's own output. First step: capture tmux's stderr and server state when this happens.
- **CI cost:** don't run CI on a push whose code is already known to build (e.g. notes only): put `[skip ci]` in the commit message, check that no run started, cancel one that did.

