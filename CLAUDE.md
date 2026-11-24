# ctop: notes for Claude

ctop is one PowerShell script, `ctop.ps1`: a `top`-style monitor of the Claude sessions on a computer. README.md describes what it does; this file is how to work on it.

## How to report

- Name guesses and inference as such, in contrast with deterministic proof. Every factual claim is:
  - **verified**: say how (source file at a commit, a command and its output, a test seen red then green);
  - **inference**: say from what;
  - **unverified / a guess**: say what would settle it.
- Never state a negative ("there is no X") as fact without having looked.
- Don't turn one data point into a requirement. Write "tested on X", and say what is untested.

## Supported agents

ctop supports exactly these, and no others (not Roo Code, Zoo Code, Kilo Code, Continue or others):
- **Claude Code:** the CLI and its VS Code extension.
- **GitHub Copilot, built into VS Code:** its chats, including on Claude models or a Claude API key, and its Claude agent.
- **GitHub Copilot CLI:** the `copilot` command, its `copilot -p` runs, and VS Code's Copilot CLI agent.
- **Cline.**

**Requirement:** assume nothing from Anthropic is installed: no `claude` CLI, no standalone Claude Code, no Claude Code extension. A user may install only VS Code and configure Copilot with a Claude API key. ctop must start and work there.

Unanswered Copilot chats are looked for 7 days back, not forever: the owner's decision. Don't widen it without asking.

## Builds

- Release notes go in `CHANGELOG.md` (newest first). A build bumps `$script:CtopVersion`, the `VERSION` line in `.NOTES`, and adds its `CHANGELOG.md` entry; a test checks all three agree.

## Pull requests

- **Every time a PR is opened or reported on, state its merge status in plain words:** **ready to merge** (CI green and nothing else pending), or **not ready**, and what it waits on (CI still running, an audit, a fix). Put the same in a "Merge status" section of the PR description, and update it when the status changes. "I opened the PR" alone reads as "ready".
- **`main` is protected:** every change goes through a PR, admins included; no force-push, no deletion; no approving review required. Requiring CI to pass before a merge is planned. Once it is on, a PR whose last commit is `[skip ci]` cannot merge until a commit without it is pushed.
- **Stacked PRs:** a branch takes the one below it by merge, never rebase (a force-push is refused). Merge a stack with merge commits, not squash: a squashed PR leaves the next one holding its commits again. Merged branches are not deleted automatically, so GitHub does not retarget the next PR: change its base to `main` before merging it.

## Audits

Every PR is audited before it merges.

- **An audit continues only while its results are worth its cost.** The owner's words: "[The reviewer] likes to over-engineer and expand scope. It's remarkably useful, but needs constraints. ... audits can continue as long as there is value. IOW, is the results worth the cost? If not, stop, because we've lost the point." Before sending another round, weigh what the last round found (could real input reach it? would a user see it?) against another review run plus a repair round, and say which way it falls.
- **Cross-lineage:** what Claude wrote, a reader from another model family (GPT through Codex, or Gemini) reviews; what such a reader wrote, Claude reviews.
- **Every brief, to any reader, carries the *Finding weights* paragraph below, copied as it stands:** a finding HOLDS only when someone would decide differently because of it; otherwise it is a NOTE, and a pass whose findings are all NOTEs approves.
- **The bar is `main`:** a failing class holds a merge only when a user is worse off than on `main` (or nothing shows otherwise), or when the PR's own promise (its CHANGELOG entry, its commit message) fails. Anything else is a NOTE with a `docs/deferred.md` entry.
- **Three rounds, then stop.** A round is one returned one-pass review of a frozen head. From the second round on, each fix brief names the design flaw the fixes work around (or says there is none). At the limit with a class still holding: take out the part that will not settle, record it in `docs/deferred.md`, and give the rest one narrow last round. A further round is the owner's word, never the author's.
- **One Gemini review at a time, and it answers one narrow question, never a whole PR.** Two whole-PR reviews run together used up the Gemini quota before either finished.
- **A review round that is owed is written here, with where its report will land, until the report is back,** so a session that ends mid-review leaves the next one a handle.
  - **Owed now** (the owner's decision, 23 Nov 2026):
    1. After the PR from `audit/copilot-cli-state` merges: Astra (Codex), a design review of `ctop.ps1`, seeded with the static audit's architecture findings, proposing a refactor plan and writing no code. Report: the `final.md` of the job folder `C:\Users\jlenzkes\ctop-astra\design-r1\`.
- **Finding weights** (the paragraph each brief carries): "Weigh every finding by the decision it changes, regardless of edit size. Weigh it HOLDS when you can name who would decide what differently because of it as it stands: a wrong verdict, behavior or outcome for a user or maintainer, a false instruction, closure condition or claim a session would follow, or a promise that fails. A true finding is a NOTE when you can name no such decision, as with wording, placement, style or a citation that still lands on the passage it means. One word that reverses a claim is HOLDS. A finding you cannot weigh is HOLDS. Only a HOLDS finding is an objection, and a pass whose findings are all NOTEs approves. Each reader alone can re-weigh its own finding; the author may argue a finding's weight once."

## Known problems

Known problems left in place on purpose, each with where it came from, where it is, and what would fix it, are in `docs/deferred.md`, with what is not yet checked. Add to it when a problem is found and not fixed.

## Flaky tests

Each has failed once or a few times and passed on rerun, with no code change. When one fails: rerun the job, and add a line here if it is a new one.
- **`Integration.Tests.ps1`, 'lists the whole history at keep ∞':** waits 30 s for all 300 gone rows; a slow runner showed 266/300. Inference: the wait is tight. Fix: a longer wait.
- **`Integration.Tests.ps1`, 'costs about the same with 300 gone rows as with the screenful that is visible':** the 300-row median landed exactly on the limit, 1.5 × the screenful's median. Inference: a limit set from one noisy median. Fix: a margin that does not scale with one fast median.
- **`Process.Tests.ps1`, 'ends a hung parent and its child together' (Windows PowerShell 5.1):** the parent was still alive after the test's 500 ms wait. Cause not known.
- **`Cline.Tests.ps1`, 'counts a changed ended conversation as still to read when there is no time for it, and reads it on a later call' (PowerShell 7):** expected 2, got 1. Inference: the test's time budget is tight on a loaded machine.
- **`Copilot.Tests.ps1`, 'lists the chats VS Code has open lately as live, with their state' (Windows PowerShell 5.1):** COST `-` instead of `$1.50`. Cause not known.

## CI cost

Don't run CI on a push whose code is already known to build (notes only, for example): put `[skip ci]` in the commit message, check that no run started, and cancel one that did.
