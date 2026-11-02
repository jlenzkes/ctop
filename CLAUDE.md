# ctop: notes for Claude

## How to report

- Name guesses and inference as such, in contrast with deterministic proof. Every factual claim is:
  - **verified**: say how (source file at a commit, a command and its output, a test seen red then green);
  - **inference**: say from what;
  - **unverified / a guess**: say what would settle it.
- Never state a negative ("there is no X") as fact without having looked.
- Don't turn one data point into a requirement. Write "tested on X", and say what is untested.

## Builds

- Release notes go in `CHANGELOG.md` (newest first). A build bumps `$script:CtopVersion`, the `VERSION` line in `.NOTES`, and adds its `CHANGELOG.md` entry; a test checks all three agree.

## Pending work: sessions from other agents

**Decision (user, 2026-11-01): ctop supports exactly three agents:**
- **Claude Code:** the CLI and its VS Code extension.
- **GitHub Copilot, built into VS Code:** its chats, including on Claude models or a Claude API key, and its Claude agent.
- **Cline.**

Not Roo Code (shut down), Zoo Code, Kilo Code, Continue or others. The probe (`tools/Probe-AgentSources.ps1`) still reports Roo/Zoo folders as research; ctop does not read them.

Findings so far, each labelled verified, inference or unverified: `docs/research/other-agents.md`.

**Requirement:** assume nothing from Anthropic is installed: no `claude` CLI, no standalone Claude Code, no Claude Code extension. A user may install only VS Code and configure Copilot with a Claude API key. ctop must start and work there. **Step 1 (build 2026.11.01.4) does this:** without `claude`, ctop reads `~/.claude/sessions/*.json` itself, and a VIA column shows `cli` / `vscode` / `sdk`.

**Done on the user's machine (with Claude Code installed), 2026-11-01:**
- Copilot chats on Claude.
- A Cline task on Claude: its manifest status is live.
- VS Code's Claude agent: it registers in `~/.claude/sessions/` with `entrypoint` `sdk-ts`, writes a transcript in `~/.claude/projects/`, and is listed by `claude agents --json`.

Details in `docs/research/other-agents.md`.

**Done on a VS Code-only VM** (Windows 10, Windows PowerShell 5.1, no `claude`, no `~/.claude` before), 2026-11-01:
- Copilot chat on Claude: chats are in `globalStorage/emptyWindowChatSessions/` when no folder is open; Pending, then Complete about a minute later.
- VS Code's Claude agent: it creates `~/.claude/sessions/<pid>.json` (`entrypoint` `sdk-ts`, live status including `waiting`) and a transcript in `~/.claude/projects/`. Signed out of GitHub, it needed `"chat.agentHost.allowSignedOutWhenUsable": true`.

**Research is done. Code:**
- **Step 1, done (PR #3, merged):** ctop starts without `claude` and reads `~/.claude/sessions/*.json` itself; the VIA column.
- **Step 2, done (build 2026.11.02.1, branch `claude/dazzling-cerf-yiwl4o`):** Cline sessions from `<sessions>/<id>/<id>.json` and `<id>.messages.json`; VIA `cline`. The messages file's field names were checked on the user's machine on 2026-11-02 (sixth probe run). Still open: whether the manifest's `metadata.totalCost` matches the summed `metrics.cost`, and the cost's unit.
- **Review fixes (build 2026.11.02.2, same branch and PR as step 2):** from Cline's review of 2026.11.01.3, the user chose three: release notes moved to `CHANGELOG.md`; `CTOP_TRACE` also records swallowed errors; peek's PRICES line says where prices come from. Not done: narrowing the global `$ErrorActionPreference = 'SilentlyContinue'`.
- **Sol's audit of PRs #3/#4 (2026-11-02, range `5690a9f..ebd3c7a`):** six findings (five P2, one P3), all fixed in build 2026.11.02.3: probe nested-field leak, stale ended Cline accounting, malformed-manifest starvation, incomplete snapshots, false registry closures, VIA lost after restart. Sol's files: `FINDINGS.md`, `REVIEW.md` (uploads).
- **Step 3, next:** Copilot chats, from VS Code's chat files.

Each step gets its own PR. Step 1 shared one with the probe and these notes.

## Flaky tests seen in CI (2026-11-01: PR #2, push run 41330600708 for c144eb6)

Same code passed in the other run, so these are flakes, not a code problem; the failed jobs were re-run. **Addressed in PR #3:** the timing test now checks the median of 7 gaps (still 416 ms, red, with the bug put back); `Start-Ctop` now prints what tmux says when the pane size is not reported (the cause itself is still unknown).
- **`tests/Worker.Tests.ps1`, 'starts a frame every tick…' (Windows PowerShell 5.1):** asserts the *maximum* gap between frame starts is under 330 ms; one gap was 354 ms. The bug it guards gives ~416 ms. Fix: assert the median gap (and print the max).
- **`tests/Integration.Tests.ps1`, `Start-Ctop` (ubuntu:22.04), in the '300 gone rows' test:** `tmux display -p '#{pane_width}x#{pane_height}'` returned nothing for 5 s, so the test never started. Cause unknown; the log does not capture tmux's own output. First step: capture tmux's stderr and server state when this happens.
- **2026-11-02, run 80 (`f1973da`), ubuntu:22.04, `Integration.Tests.ps1` 'lists the whole history at keep ∞':** it waits 30 s for all 300 gone rows, and the screen showed 266/300, with frames at 242 ms. The same code passed this job in run 78 (`39fee48` differs only in `tests/Trace.Tests.ps1` and README.md; ctop.ps1 is the same). Inference: the runner was slow, and the 30 s wait is tight. Not yet fixed.
- **2026-11-02, local (this container), `Integration.Tests.ps1` 'cost about what ASCII titles do':** Chinese median 41 ms against a limit of 38, set from an ASCII median of 23 ms, the lowest seen here (26–38 ms in earlier runs). It passed on both reruns straight after. The title-width code was not changed. Inference: a limit taken from one fast ASCII median is noisy.
- **CI cost:** don't run CI on a push whose code is already known to build (e.g. notes only): put `[skip ci]` in the commit message, check that no run started, cancel one that did.

