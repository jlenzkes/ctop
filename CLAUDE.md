# ctop: notes for Claude

## How to report

- Name guesses and inference as such, in contrast with deterministic proof. Every factual claim is:
  - **verified**: say how (source file at a commit, a command and its output, a test seen red then green);
  - **inference**: say from what;
  - **unverified / a guess**: say what would settle it.
- Never state a negative ("there is no X") as fact without having looked.
- Don't turn one data point into a requirement. Write "tested on X", and say what is untested.

## Pending work: sessions from other agents (VS Code's built-in Copilot, Cline, Roo)

Findings so far, each labelled verified, inference or unverified: `docs/research/other-agents.md`.

**Requirement:** assume nothing from Anthropic is installed: no `claude` CLI, no standalone Claude Code, no Claude Code extension. A user may install only VS Code and configure Copilot with a Claude API key. ctop must start and work there; today it stops if `claude` is missing (`ctop.ps1`, `Get-Command claude -ErrorAction Stop`).

**When this work resumes, start with:** one Claude agent chat in VS Code, on a VS Code-only machine as well as one with Claude Code. Then check whether it appears in `claude agents --json` and `~/.claude/sessions/`, and whether its transcript is in `~/.claude/projects/`. Also run one Cline task and check `~/.cline/data/db/sessions.db`. Do this before writing code.

## Next PR: flaky tests seen in CI (2026-11-01, PR #2 push run 41330604496's sibling, run 41330600708)

Same code passed in the other run, so these are flakes, not a code problem; the failed jobs were re-run.
- **`tests/Worker.Tests.ps1`, 'starts a frame every tick…' (Windows PowerShell 5.1):** asserts the *maximum* gap between frame starts is under 330 ms; one gap was 354 ms. The bug it guards gives ~416 ms. Fix: assert the median gap (and print the max).
- **`tests/Integration.Tests.ps1`, `Start-Ctop` (ubuntu:22.04), in the '300 gone rows' test:** `tmux display -p '#{pane_width}x#{pane_height}'` returned nothing for 5 s, so the test never started. Cause unknown; the log does not capture tmux's own output. First step: capture tmux's stderr and server state when this happens.
- **CI cost:** don't run CI on a push whose code is already known to build (e.g. notes only): put `[skip ci]` in the commit message, check that no run started, cancel one that did.

