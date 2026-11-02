# Other agents that run Claude: what ctop could read

Research for a possible later PR: show sessions from VS Code's built-in Copilot (which can run
Claude), Cline, and Roo Code alongside Claude Code's. Nothing here is implemented yet.

Every claim is labelled:
- **verified**: read in source at the named commit, or a command run, as stated;
- **inference**: reasoned from something verified, and says from what;
- **unverified**: not checked yet; says what would settle it.

Sources were read on 2026-11-01:
- `microsoft/vscode` at `1306698` (2026-10-31).
- `cline/cline` at `a6507a6` (2026-10-30).
- `RooCodeInc/Roo-Code`, `main` branch, one file.

## Requirement: nothing from Anthropic may be assumed installed

From the user, 2026-11-01. Someone may install only VS Code on a new computer, configure Copilot with a Claude (Anthropic) API key, and start there. So ctop must not assume:
- the Claude Code CLI (`claude`);
- standalone Claude Code, or the Claude Code VS Code extension;
- `~/.claude/sessions` or `claude agents --json`.

What follows from that:

**Verified** (`ctop.ps1:1323`, `$script:ClaudeCmd = (Get-Command claude -ErrorAction Stop).Source`): ctop today **stops at startup** if `claude` isn't on PATH. On a VS Code-only machine it would not start at all. Claude Code has to become one optional source among several.

**Verified** (`claudeAgentSdkService.ts`, `ClaudeSdkPackage` via `this._downloader`): VS Code's Claude agent **downloads the Claude Agent SDK itself**. It does not need a separately installed Claude Code.

**Inference:** its transcripts still land in `~/.claude/projects` (the SDK's CLI writes them), but with no `claude` command there is no `claude agents --json` roster.
- So these sessions must be found without the roster: from the transcripts, from the process table (`AI_AGENT=github_copilot_vscode_agent`), or from VS Code's own records.
- That they still land in `~/.claude/projects` is unverified until the first step below.

**Verified** (`extensions/copilot/src/extension/byok/vscode-node/anthropicProvider.ts`): Copilot has a bring-your-own-key **Anthropic** provider.
- **Inference:** chats on such a model are ordinary Copilot chats, stored in `chatSessions` like any other (the provider supplies the model; the chat service stores the session).
- **Unverified:** that the stored `modelId` names the Claude model, and what `copilotCredits` holds when you pay Anthropic directly, if anything.

## First step when this work resumes

Do this on a machine with **only VS Code**: no `claude` command, no Claude Code, no Claude Code extension, as well as on a machine that has them.

Run **one Claude agent chat in VS Code**, then check two things while it is open:
- whether it appears in `claude agents --json` and in `~/.claude/sessions/`;
- whether its transcript is in `~/.claude/projects/`.

Also run **one Cline task** and check `~/.cline/data/db/sessions.db`.

These are the two facts the source reading could not settle.

**How:** run `tools/Probe-AgentSources.ps1 -OutFile probe.txt` on each machine, once while the chat or task is working and once after it has finished, and bring back both reports. It prints only shape and safe values (see its help), so the reports can be shared as they are.

**Verified** (the probe run in this cloud container, 2026-11-01): Claude Code's own Bash tool sets `AI_AGENT=claude-code_2-1-316_agent` on the processes it runs, together with `CLAUDECODE=1` and `CLAUDE_CODE_ENTRYPOINT`. The transcript lines of this session carry `entrypoint` `remote`, `userType` `external` and `version`. So `AI_AGENT` tells a Claude Code process from one VS Code's agent started (`github_copilot_vscode_agent`), and `entrypoint` should tell an SDK-written transcript from a CLI one. Which `entrypoint` value the SDK writes is unverified until the probe runs next to a Claude agent chat.

## First probe run (the user's Windows machine, 2026-11-01)

Probe 2026.11.01.1 on Windows (NT 10.0.26300), PowerShell 7.6.9, run while a Copilot chat was working (18:43:44Z) and after (18:44:21Z). The machine has Claude Code, its VS Code extension and the `cline` CLI installed, so it is **not** the VS Code-only case; that case is still to run.

**Verified** (from the two reports):
- **Copilot chat with the user's Anthropic key:**
  - It is an ordinary Copilot chat: `Code\User\workspaceStorage\<id>\chatSessions\<id>.jsonl`.
  - Its model id names the Claude model and the key's provider: `"anthropic/Anthropic/claude-opus-5-5"`.
  - The session's first log entry had 0 requests. The request was added (`kind 2` on `requests`) when it was sent: the file changed at 18:43:43, one second before the probe.
  - Tokens and the response (`kind 1` on `requests/*/promptTokens`, `completionTokens`, `response`, …) were written by 18:43:59.
  - 22 s later, no `modelState` had been written for it.
  - Older chats on the same machine do get `modelState` 1 (Complete) written later.
- **No Claude Code trace:** no Claude Code transcript or live-session entry changed during the chat (newest transcript 17:54:07Z). So this run says nothing about VS Code's Claude agent; it was Copilot's own chat.
- **Claude Code's VS Code extension** writes `entrypoint` `claude-vscode`, in its live-session entries (`~/.claude/sessions/<pid>.json`) and in its transcript lines.
- **Transcript line types:** that machine's transcripts also have `api-request`, `api-request-blob`, `api-request-shape`, `ai-title`, `file-history-delta`, `teleported-from`. Some lines carry `version` `1.0` and `userType` `unknown`.
- **Windows processes:** four `claude.exe` processes with one parent. The probe can't read another process's environment on Windows, so the `AI_AGENT` marker is Linux-only as a signal there.
- **Cline:**
  - `~\.cline\data\db\sessions.db` exists, with no `-wal` file at the time.
  - `sqlite3` is not installed, so the database was not read.
  - The newest three session manifests are all `status` `failed`, `exit_code` 1, `source` `vscode`. That matches Cline's dead-session reconciler marking sessions whose process has gone.
  - Their `provider` is `openai-compatible` (`gemini-3.1-pro-preview`), so none of them used Claude.
- **Older Cline extension** (`globalStorage\saoudrizwan.claude-dev`): one task folder holding only `settings.json`.

**Verified** (source, `apps/cli/src/commands/history.ts`): `cline history --json --limit <n>` prints the session list as JSON. Where the `cline` CLI is installed, ctop can read Cline sessions without SQLite, the way it reads `claude agents --json`.

**Inference:**
- **Copilot completion state:** it reaches the file later than the response, plausibly at VS Code's one-minute storage flush. So a reader would see "working" for up to about a minute after a reply finishes.
- **To measure:** the probe's `-WatchSeconds` mode (2026.11.01.2) times each change.

**Probe bugs this run exposed** (fixed in 2026.11.01.2):
- Cline dates printed as `(object)`, because PowerShell 7 reads ISO strings as dates.
- A request's state was not shown when the request was added rather than set.

## Second probe run (same machine, 2026-11-01, probe 2026.11.01.2)

A second request in the same Copilot chat. Snapshots at 18:59:05Z (working) and 18:59:59Z (done); watch mode not used.

**Verified:**
- **The request was written when sent.** It was sent at 18:59:03.308 (its `timestamp`). It was in the file as a pushed request with `modelState` `0 Pending` by 18:59:04, about 1 s later.
- **`1 Complete` was in the file by 19:00:00**, 57 s after sending. How long after the reply really finished is not known; `-WatchSeconds` measures it.
- **Request fields:**
  - All of them: `agent`, `modeInfo`, `modelConfiguration`, `modelId`, `modelState`, `requestId`, `response`, `responseId`, `responseTimestamp`, `timeSpentWaiting`, `timestamp`, `variableData`, `codeCitations`, `contentReferences`, `hiddenFromTranscript`, `message`.
  - Once finished, also: `completionTokens`, `promptTokens`, `promptTokenDetails`, `outputBuffer`, `elapsedMs`, `result`, `followups`.
- **Cancellations and context size are recorded:** an older chat has a request with `modelState` `2 Cancelled` and `promptTokens` 139025.
- **`cline history --json` works on that machine** (PowerShell 7.6.9). It gave 3 rows, the same sessions as the manifests, with camelCase fields: `sessionId`, `source`, `pid`, `status`, `provider`, `model`, `startedAt`, `endedAt`, `exitCode`, `interactive`, `isSubagent`, `updatedAt`, plus `prompt`, `metadata`, `cwd`, `workspaceRoot`, `messagesPath`.

**Database companion files** (SQLite in WAL mode creates `sessions.db-wal` and `sessions.db-shm` whenever a program opens the database):
- **Verified** (the user's terminal output): the probe ran at 18:59:05 and 18:59:59 only. The 18:59:05 run listed `-wal` and `-shm` dated 18:56:03, then ran `cline history`. The 18:59:59 run listed `-wal` dated 18:59:11.
- **Inference:** the probe's `cline history` call touched `-wal` at 18:59:11. So reading Cline through its CLI is not side-effect free on disk; the probe's help says so.
- **Unexplained:** what opened the database at 18:56:03, three minutes before either run. The user did not open Cline.
- **Verified** (the user ran `code --list-extensions`): the Cline extension `saoudrizwan.claude-dev` is installed on that machine.
- **Verified** (`apps/vscode/package.json` at `a6507a6`, version 4.1.26): it activates on `onStartupFinished`. So it runs in every VS Code window, whether or not its panel is opened.
- **Verified** (the user's Resource Monitor, Associated Handles, search `sessions.db`, about 19:30Z): two `Code.exe` processes, PIDs 52584 and 31248, hold `sessions.db`, `sessions.db-wal` and `sessions.db-shm` open.
  - No running process's command line contains "cline".
  - No running process started between 18:55:30Z and 18:56:30Z.
  - So an already-running VS Code process (the Cline extension inside it) opened the database at 18:56:03.
  - At 18:43Z the files did not exist, so the extension does not keep the database open all the time: it opened it at some later moment.
- **Verified** (the user's `Get-CimInstance Win32_Process` output): both PIDs are VS Code extension hosts. Each has `--type=utility --utility-sub-type=node.mojom.NodeService`, and both have the same parent, 39412, VS Code's main process.
  - **31248** started 2026-10-30 21:25:26 local (2026-10-31T04:25:26Z).
  - **52584** started 2026-11-01 09:55:58 local (16:55:58Z).
  - So the database was opened at 18:56:03Z by an extension host that had already been running for hours. Cline does not open it when it starts.
- **A coincidence, not explained:** 18:56:03Z is 2 h 5 s after 52584 started. A two-hour timer in the extension is a guess. A search of Cline's file names found no reconciler, sweeper or heartbeat module, and the code was not read further.
- **For ctop** (inference): an extension host holding `sessions.db` open is a sign Cline is active in VS Code, but not the only one. The live status still has to come from the database (`cline history --json`, or `sqlite3` where installed).
- **Earlier guess, now verified:** the extension opened the database at 18:56:03. It was running then, and its source has a dead-session reconciler that opens the database. Unverified.
- **To settle it:** compare `Get-Item ~\.cline\data\db\sessions.db-*` before and 30 s after "Developer: Reload Window".
- **For ctop** (inference): wherever VS Code runs with Cline installed, Cline is running. A Cline session's `pid` should then name a live process while VS Code is open.

**Still open:** a Cline task (none ran); VS Code's own Claude agent; the VS Code-only machine; the exact lag of Copilot's completion state.

## Third probe run: a Cline task on Claude (same machine, 2026-11-01, probe 2026.11.01.3)

The watch ran 19:42:07–19:45:12Z while the user gave Cline a small task.

**Verified** (`probe-cline.txt`):
- **The new Cline session** `1793562129035_phf3k`: `source` `vscode`, `provider` `anthropic`, `model` `claude-sonnet-5`, `pid` 53504.
  - It started at 19:42:09.114Z. `cline history --json` and its manifest both said `status` `running`.
  - The database's `-wal` grew to 20.1 KB at 19:42:09.
  - Its folder holds `<id>.json` (the manifest) and `<id>.messages.json`.
- **The manifest's status is live:** the watch saw `status="running"` at 19:42:16 and `status="idle"` at 19:42:24, with the same pid. So the installed extension rewrites the manifest when the status changes.
  - **Correction:** this contradicts the reading of `persistence-service.ts` at `a6507a6` (status changes only in the database). Either the installed extension differs from `main` at that commit, or another code path writes the manifest. **Tested on** that machine's installed version, not identified.
  - **For ctop:** Cline's live status can be read from the JSON manifests, with no SQLite and no `cline` CLI.
  - **To check:** how quickly a change reaches the manifest. The watch reads Cline manifests every 3 s, so this run shows only that it took under about 8 s.
- **Verified** (the user's `Win32_Process` output): `pid` 53504 is a VS Code extension host (`Code.exe --type=utility --utility-sub-type=node.mojom.NodeService`).
  - Its parent is 39412, VS Code's main process, as for 52584 and 31248.
  - It started 2026-10-31 09:41:27 local, a third VS Code window.
  - It was not among the processes holding `sessions.db` before the task, so each window's Cline opens the database when it needs it.
  - **So a Cline session's `pid` is the extension host of the VS Code window it runs in.** That process lives as long as the window, so a live pid means "the window is open", not "working". The `status` field says which.
- **Copilot chat, the user's screenshot at 11:47 local (19:47Z):**
  - The chat view has tabs **Chat**, **Cline**, **Claude Code** and **Codex**.
  - In the Chat tab, a session titled "ctop.ps1 purpose and relevance": mode **Agent**, model **Claude Haiku 4.5**, "Max 179K", target "Local", "Completed 6 steps in 13s".
  - That is the new chat file `04143839-….jsonl` (19:45:01Z).
  - **Inference:** this is Copilot's own agent mode on a Claude model, not VS Code's separate Claude agent (agent host). It ran in the Chat tab, with Copilot's model picker, and no Claude Code transcript appeared.
  - **Verified** (the user's screenshots, 11:56 local): VS Code's Claude agent is offered.
    - Where: the session-target button at the bottom left of the Chat view ("Local") opens a list of harnesses: **Local**, **Cloud** (sign in), **Copilot**, **Codex**, **Claude**, and "Learn about harnesses…".
    - Choosing **Claude** shows "Download the Claude Agent. To use the Claude Agent, we need to download the Claude Agent SDK" with a **Download** button. The input reads "Chat with Claude", "No models available", and the footer shows "Claude" and "Ask Before Edits".
    - This matches the source: the SDK is fetched by VS Code (`claudeAgentSdkService.ts`), not taken from an installed Claude Code.
    - **Verified** (the user's screenshot, 11:58 local, after the SDK download and a VS Code restart): the panel then reads "Choose how you want to use Claude. Sign in to GitHub to use GitHub Copilot models or reload the configuration if you have set up Claude elsewhere". "No models available"; clicking "reload the configuration" changed nothing.
    - **Verified** (`claudeTransportMode.ts` at `1306698`): the agent runs in one of two modes. **proxy**: through Copilot, needs a GitHub sign-in, preferred when signed in. **native**: the user's own Claude credentials, no GitHub.
      - Native mode is used only when the SDK's `accountInfo()` reports a credential: a `tokenSource` other than `none`, an `apiKeySource`, or a third-party `apiProvider` (Bedrock, Vertex, a gateway).
      - The file says a `claude login` credential can be invisible to the environment and to `~/.claude/settings.json`, so only the SDK's own report counts.
    - **Verified** (the user's screenshots): dismissing the "customization needs an update" notice (Review Migrations → Ignore, for the `@remote-ssh` chat participant) did not change the panel.
      - The Claude Code extension on the same machine is signed in with a subscription: its Account & Usage panel shows "Weekly (7 day)" and "Fable limit" bars, and its model picker offers Opus 5.5, Fable 5.1, Sonnet 5.5 and Haiku 5.5.
      - So a working Claude Code subscription login was not seen by VS Code's Claude agent as a credential. Why is unknown.
    - **Inference:** "reload the configuration" asks the SDK again, and on that machine it still reports no credential. Copilot's own Anthropic key (in VS Code's secret storage) is not one of the credentials the SDK looks for.
    - The new-session menu (top right, the `+` dropdown) offers New Chat, New Chat Editor, New Chat Window and **New Copilot CLI Session**; it does not list Claude. Copilot CLI sessions are another harness, not looked at.
- **No VS Code Claude agent transcript appeared:** the Claude Code transcripts that changed during the watch were all from the user's own Claude Code extension session (`entrypoint` `claude-vscode`, project `c--dev-src-genai-mil`, with subagents).
- **Copilot during the watch:**
  - At 19:44:01 and 19:44:30 the existing chat recorded only `inputState` changes (`selectedModel`, `inputText`, `selections`), i.e. typing and choosing a model.
  - At 19:45:01 a new chat file `04143839-….jsonl` appeared: 158 KB, written as one `kind 0` entry already holding 1 request.
  - The watch ended 11 s later. What that chat was (Copilot or the Claude agent) is not known from the report.
- **Probe gap:** for a new file written as one `kind 0` entry, the watch prints only the request count, not the model or state. To fix.

## Fourth probe run: VS Code's Claude agent (same machine, 2026-11-01, probe 2026.11.01.3)

The Claude agent (Local → **Claude**) ran in native mode on an Anthropic API key in VS Code's environment. Claude Code's subscription login was not accepted (see above). Watch 21:44:25–21:47:30Z.

**Verified** (`probe-claude-agent.txt` and the user's `claude agents --json` output):
- **It registers as a Claude Code live session:**
  - `~/.claude/sessions/45408.json` appeared at 21:45:28 with `kind` `interactive`, `entrypoint` **`sdk-ts`**, `status` `busy`.
  - It changed to `status` `idle` at 21:45:43.
- **It writes an ordinary Claude Code transcript** in `~/.claude/projects/c--dev-src-ctop/<id>.jsonl`, with `entrypoint` `sdk-ts` on its lines.
  - The file was already 206.2 KB at its first sighting, 377.1 KB 4 s later, 387.8 KB at the end.
- **`claude agents --json` lists it** while it is open: pid 45408, `kind` `interactive`, `status` `idle`. The `entrypoint` column came out empty, so that list does not say which harness a session came from; the registry file does.
- **So, where `claude` is installed, ctop already shows VS Code's Claude agent sessions**, with no change. To label them, read `entrypoint` from `~/.claude/sessions/<pid>.json`: `sdk-ts` for the agent, `claude-vscode` for the Claude Code extension, `cli` and others for the CLI (unverified for the CLI).
- **A closed VS Code window shows up in Cline as `failed`:** the Cline session `1793562129035_phf3k` (19:42:09Z) went to `failed`, `exit_code` 1, `ended_at` 21:22:28Z, which is when the user restarted VS Code. So Cline's `failed` with exit 1 includes "its window was closed"; ctop should show it as ended, not as an error.
- **A new Copilot chat file was not written until its first request had finished** (chat `04143839-….jsonl`, step 2's Copilot agent-mode chat):
  - Request sent at 19:44:37.963Z (`timestamp`); completed at 19:44:51.148Z (`modelState` `1 Complete`, `completedAt`).
  - The file first appeared at 19:45:00, as a single `kind 0` entry holding the finished request.
  - So for its whole first turn, this chat was invisible on disk. One instance; whether that is always so for a new chat is unverified.
  - Its `modelId` `anthropic/Anthropic/claude-haiku-4-5-20251001` shows it ran on the user's Anthropic key (Copilot's bring-your-own-key provider), not on Copilot's own Claude models. `promptTokens` 70660, `completionTokens` 702.

**Inference, for the VS Code-only machine:** the registry file and transcript are written by the SDK's own Claude Code process (`entrypoint` `sdk-ts`), not by an installed `claude`. So they should exist where `claude` is not installed, and ctop could read `~/.claude/sessions/*.json` directly instead of running `claude agents --json`. Unverified until the VS Code-only run.

## Fifth probe run: a VS Code-only VM (2026-11-01, probe 2026.11.01.3)

Windows 10 (NT 10.0.19045), Windows PowerShell 5.1.19041.6456. VS Code with Copilot on the user's Anthropic key; no `claude`, no Claude Code extension, no Cline, no node.

**Verified** (`probe-vm-before.txt`, `probe-vm-copilot.txt`):
- **The probe runs on Windows PowerShell 5.1 on a real machine,** not only in CI.
- **Nothing from Anthropic is present:** `claude` not found, `~\.claude` not found, `~\.cline` not found.
- **Copilot chats with no folder open are stored in `globalStorage\emptyWindowChatSessions\`,** as the source said.
- **The model is named:** Copilot chat on Claude via the user's key gives `modelId` `anthropic/Anthropic/claude-haiku-4-5-20251001`.
- **A new chat was visible while working** (`4033627a-….jsonl`):
  - The file existed, empty (0 requests), from 22:44:14.
  - At 22:44:34 the watch saw the request pushed with `modelState` `0 Pending`.
  - The next write came at 22:45:35, 61 s later: `modelState` `1 Complete`, tokens, `response`, `customTitle`, and a push of three requests, all Complete.
  - So during that minute the file said Pending.
  - This contradicts the one earlier instance where a new chat was not on disk until its first request finished. So "a new chat is invisible during its first request" is not always true.
- **An earlier chat on the VM** (`892a9c64-….jsonl`): requests at 22:39:10Z and 22:39:30Z, the second still Pending in the 22:44:21 snapshot.

**Inference:**
- While a request runs, Copilot writes the chat file about once a minute. The 61 s gap fits VS Code's 60 s storage flush. So ctop can show a Copilot chat as working, but "finished" may reach it up to about a minute late.
- How late, exactly, needs the reply's real end time, which the file does not hold until it is written.

**VS Code's Claude agent on the VM:** blocked so far.
- **Verified** (the user's screenshot): with `ANTHROPIC_API_KEY` set and VS Code restarted, the harness list showed **Claude** greyed, "No models available". **Copilot** and **Cloud** both showed "Sign in". Claude could not be selected, so its "Download the Claude Agent" prompt could not be reached.
- **Verified** (`claudeAgent.ts` at `1306698`, `_refreshModels`): models come from two places only.
  - **Copilot's models:** only when signed in to GitHub.
  - **Native models (the user's key):** only when the SDK is already on disk. The native attempt is skipped otherwise, because "that download is the user's explicit choice".
- **Verified, same file:** the download is offered by the agent's `AgentSdkSetupChannel`. No setting turning the Claude agent on or off was found in `agentHostEnablementService.ts`.
- **Inference:** a machine with only VS Code and an Anthropic key, and no GitHub sign-in, cannot start VS Code's Claude agent: no SDK, so no models, so no way to reach Download. On the user's main machine it was selectable before the download, plausibly because Copilot was signed in there (its harness list showed Copilot without "Sign in").
- **Way through, found by the user:** the setting `"chat.agentHost.allowSignedOutWhenUsable": true` in VS Code's `settings.json`.
  - With it, the Claude agent became usable signed out, on the Anthropic key.
  - **Verified** (`src/vs/platform/agentHost/common/agentHostCustomizationConfig.ts` at `1306698`): the key `allowSignedOutWhenUsable` exists, commented "Legacy wire key; remove once all supported hosts allow signed-out operation unconditionally". So it is a stopgap VS Code means to remove.
  - The full name `chat.agentHost.allowSignedOutWhenUsable` is from the user's working settings, not read in source.

### VS Code's Claude agent on the VS Code-only VM (probe 2026.11.01.3, watch 22:57:06–23:00:08Z)

**Verified** (`probe-vm-claude-agent.txt`):
- **Before:** `claude` not found and `~\.claude` not found.
- **During the task:**
  - `~\.claude\sessions\12748.json` appeared at 22:57:45 with `kind` `interactive`, `entrypoint` `sdk-ts`, `status` `busy`.
  - A transcript appeared in `~\.claude\projects\c--Users-<user>--copilot-chats-<uuid>\<id>.jsonl`, with `entrypoint` `sdk-ts` on its lines. The session's working folder is `~\.copilot-chats\<uuid>`, VS Code's folder for a chat with no folder open.
- **Its status changed live:** `busy` → `idle` (22:57:49) → `busy` (22:58:15) → `idle` (22:58:16) → `busy` (22:58:36) → **`waiting`** (22:58:37) → `busy` (22:58:40) → `idle` (22:58:42).
  - `waiting` fits a permission prompt (the harness ran with "Ask Before Edits"; inference).
  - ctop already maps `waiting` (`Resolve-State`, `ctop.ps1`).

**So, verified on a machine with nothing from Anthropic installed:** VS Code's Claude agent writes Claude Code's own live-session entry (`~/.claude/sessions/<pid>.json`) and transcript (`~/.claude/projects/`). ctop can find, label and follow these sessions by reading those files directly, with no `claude` command.

## VS Code's built-in Copilot

**Verified:** the standalone `microsoft/vscode-copilot-chat` repo is archived. Its README says "This project has been moved into the main VS Code repository". Copilot now lives in `microsoft/vscode` under `extensions/copilot`.

It reaches Claude in two different ways.

### 1. The Claude agent (`src/vs/platform/agentHost/node/claude/`)

**Verified.** It runs the Claude Agent SDK (`@anthropic-ai/claude-agent-sdk`), which starts the Claude Code CLI as a subprocess. From `CONTEXT.md`:
- "the SDK is the source of truth for session existence".
- "External Claude CLI sessions have no overlay DB".

Its own data is a separate "overlay" store that only adds fields, `ClaudeSessionMetadataStore`.

**Verified** (`claudeAgent.ts`):
- Line 991 refers to options "that read the user's real `~/.claude` config".
- It lists sessions via the SDK's `listSessions` and reads them via `getSessionMessages`.

**Verified** (`claudeSdkOptions.ts`, `buildSubprocessEnv`):
- **Proxy mode** (Copilot pays): the subprocess gets a sparse environment. That is `HOME`, `USERPROFILE`, `ELECTRON_RUN_AS_NODE=1` and `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1`, with no `CLAUDE_CONFIG_DIR`.
- **Proxy-mode routing:** `ANTHROPIC_BASE_URL` points at a local proxy that forwards to GitHub Copilot's API.
- **Native mode** (your own Anthropic key): the subprocess inherits the full environment.
- **Both modes:** set `AI_AGENT=github_copilot_vscode_agent`, on the subprocess and in `settings.env`.

**Inference:** the transcripts are ordinary Claude Code transcripts in `~/.claude/projects/`, which ctop already reads.
- This follows from the SDK being the source of truth and the CLI being given the real `HOME`.
- In proxy mode, a user's `CLAUDE_CONFIG_DIR` is not passed on, so they would land in the default `~/.claude` even if you use another one.

**Inference:** ctop could label these sessions "via VS Code / Copilot" from the `AI_AGENT` marker.
- On Linux it is readable in `/proc/<pid>/environ` for your own processes.
- On Windows, reading another process's environment is harder; the command line may be enough instead. That is unverified.

**Unverified:** whether an SDK-launched CLI registers itself in `~/.claude/sessions/<pid>.json`, and so in `claude agents --json`.
- This session's own entry says `entrypoint: remote`, so it doesn't tell us.
- Settle it with the first step above.

### 2. Copilot's own chat, with a Claude model selected

This is VS Code's chat format, not Claude Code's.

**Verified** (`src/vs/workbench/contrib/chat/common/model/chatSessionStore.ts`):
- Sessions are files at `<user data>/User/workspaceStorage/<workspaceId>/chatSessions/<id>.jsonl`, or `.json`. The `.jsonl` is a mutation log, used unless `chat.useLogSessionStorage` is false.
- Empty windows use `globalStorage/emptyWindowChatSessions`; there is also `globalStorage/transferredChatSessions`.
- The index is the storage key `chat.ChatSessionStore.index`.

**Verified** (`chatModel.ts`): each saved response has `modelState`:
- `Pending`, `NeedsInput`, or `Complete` / `Cancelled` / `Failed` with `completedAt`.
- So the file carries working / waiting-on-you / done.

**Verified** (`chatServiceImpl.ts`, `platform/storage/common/storage.ts`): the session is saved on:
- the storage service's `onWillSaveState`, whose `DEFAULT_FLUSH_INTERVAL = 60 * 1000` ("every minute");
- the model being disposed;
- a title change.

**Inference:** from those save points:
- the file's state can be up to about a minute behind;
- after a crash it can still read `Pending`, so ctop must also check that VS Code is running.

The chat runs inside VS Code's own process, with no subprocess of its own.

**Verified** (`chatSessionOperationLog.ts`, `requestSchema`): each saved request carries:
- `timestamp`, `modelId`, `modelState`;
- `promptTokens`, `completionTokens`, `contextUsage` (`currentTokens` / `tokenLimit`);
- `copilotCredits` and `sessionCopilotCredits`.

Cost is in **Copilot credits, not dollars** (`IChatUsage` in `chatService.ts`). Its comment says summing `copilotCredits` across responses "is only ever a lower bound on the session; prefer `sessionCopilotCredits`".

**Verified** (`objectMutationLog.ts`, `EntryKind`): the `.jsonl` is a mutation log, one JSON entry per line.
- The first entry is `{"kind":0,"v":<whole session>}`.
- Then `{"kind":1,"k":<path>,"v":…}` (set), `{"kind":2,"k":<path>,"v":[…],"i":n}` (push onto an array, cutting it at `i` first if given), and `{"kind":3,"k":<path>}` (delete).
- A path is a list of keys and array indexes.

**Inference:** ctop can rebuild the current session by replaying the entries in order, and can do it incrementally, from the last byte read, as it already does for Claude Code transcripts.

**Not looked at:** the Copilot CLI sessions VS Code also shows (`extensions/copilot/src/extension/chatSessions/copilotcli/`).

## Cline (the original; Roo Code is a fork)

**Verified:** the repo is now a monorepo:
- `apps/vscode` (the extension), `apps/cli` and `apps/cline-hub`;
- `sdk/packages/core` and `sdk/packages/shared`.

The extension creates sessions through `ClineCore` from `@cline/core` (`apps/vscode/src/sdk/cline-session-factory.ts`).

**Verified** (`sdk/packages/shared/src/storage/paths.ts`):
- The Cline dir is `$CLINE_DIR`, else `~/.cline`.
- The data dir is `<cline dir>/data`.
- Sessions are in `<data>/sessions`; the database dir is `$CLINE_DB_DATA_DIR`, else `<data>/db`.

**Verified** (`sdk/packages/core/src/services/storage/sqlite-session-store.ts`): the database is `<db dir>/sessions.db`, SQLite. The `sessions` table holds:
- `session_id`, `source`, `pid`;
- `started_at`, `ended_at`, `exit_code`;
- `status`, `interactive`, `provider`, `model`, `cwd`, `workspace_root`.

**Verified** (`sdk/packages/shared/src/session/records.ts`, `core/src/types/common.ts`): `status` is:
- `idle`: "available for input and no turn is executing";
- `running`: "A turn is actively executing";
- `pending`: queued or handed off;
- or an ended state.

So there is a live signal, close to what ctop gets from Claude Code, with a `pid` to check.

**Verified** (`sdk/packages/core/src/runtime/host/host.ts:66–88`): SQLite is tried first.
- If it cannot be opened, Cline falls back to a file backend (`FileSessionService`: `<sessions dir>/sessions.index.json`).
- It logs `session_backend_fallback`.

**Verified** (`session-manifest.ts`, `services/session-artifacts.ts`): each session also has a manifest. It holds `pid`, `status`, `started_at`, `ended_at`, `provider`, `model`, `cwd`, and `messages_path`.
- Paths: `<sessions dir>/<id>/<id>.json` (the manifest), `<id>.messages.json` and `<id>.compaction.json`.

**Verified** (`session/services/persistence-service.ts`, `updateSessionStatus`): a status change updates only the database row. The manifest is written:
- at creation;
- when the prompt or title changes, keeping the old status;
- when Cline marks a dead `running` session `failed`.

So **a manifest's `status` is not live**; the live status is only in `sessions.db`. A manifest's `pid` is still useful.

**Verified** (same file, `reconcileDeadRunningSession`): Cline itself marks a `running` session whose `pid` is no longer alive as `failed`.

**Verified** (`sdk/packages/shared/src/db/sqlite-db.ts:355`): the shared SQLite opener sets `PRAGMA journal_mode = WAL`. It uses `bun:sqlite` under Bun.
- **Inference:** `sessions.db` goes through that opener (the session store imports `@cline/shared/db`).
- So recent changes can sit in `sessions.db-wal`, and any reader must be a real SQLite engine. A hand-written file parser would miss them.

**Not found:** token use or cost in `session/stores/conversation-store.ts` or `session/services/message-builder.ts`. Where Cline keeps them is still open.

**Unverified:** that the VS Code extension really ends up on the SQLite backend on Windows, where it runs inside VS Code's extension host. Settle it with the first step above.

**Verified** (PowerShell 7.6.9 on Linux, this container): PowerShell cannot read SQLite out of the box.
- `Microsoft.Data.Sqlite` and `System.Data.SQLite` are not loaded.
- There is no `sqlite3` command here.
- So reading `sessions.db` from ctop needs a dependency, a small bundled reader, or the JSON fallback/manifests.

That is a design decision to make first.

**Not looked at:** the hub (`sdk/packages/core/src/hub/discovery/instance-lock.ts`), which might list running Cline processes.

## Which extensions are worth supporting (2026-11-01)

**Verified** (the projects' own repositories, read 2026-11-01):
- **Roo Code is shut down.** Its README: "The Roo Code Extension was shut down on May 15th", pointing to ZooCode ("a fork started by the Roo Code community") and Cline. Its last commit on `main` is that day (`b867ec9`, 2026-05-15).
- **Zoo Code** (`github.com/Zoo-Code-Org/Zoo-Code`) is the Roo fork its README describes.
  - **Identity:** extension `ZooCodeOrganization.zoo-code`, version 3.94.0 in `src/package.json`.
  - **Same task layout as Roo:** `src/utils/storage.ts` puts tasks in `<base>/tasks/<taskId>`. `src/shared/globalFileNames.ts` names `api_conversation_history.json`, `ui_messages.json`, `task_metadata.json` and `history_item.json`.
  - **One difference:** it has no `historyIndex: "_index.json"` entry, which Roo had.
- **Kilo Code:** extension `kilocode.Kilo-Code`; its README says VS Code, JetBrains and a CLI (`@kilocode/cli`). Its `src/package.json` is not where Roo's was, so its layout has changed. Its storage is not read yet.

**Secondary sources only** (blogs and roundups, with conflicting dates and methods; not checked against the VS Code Marketplace), on install counts:
- **GitHub Copilot Chat:** about 78.6M.
- **Claude Code's extension:** 22–27M.
- **OpenAI's Codex:** 12.6–15.1M.
- **Tabnine:** 9.6M.
- **Cline:** about 5M.
- **No independent count found:** Kilo Code, Zoo Code, Continue.

Sources:
- [Kimi.ai roundup](https://www.kimi.ai/resources/vscode-ai-extensions)
- [Kilo's own comparison](https://kilo.ai/articles/coding-agents-for-vscode) (a competitor's claims)
- [AI coding harness comparison, Oct 2026](https://tech.grahammiranda.com/ai-coding-harness-comparison)
- [Roo shutdown coverage](https://theaiagentindex.com/agents/roo-code)

**Inference:** by reach, the agents that run Claude in VS Code are:
- Copilot (built in, with Claude models or a Claude key);
- Claude Code's own extension (already what ctop reads);
- Cline, far ahead of the rest among open-source agents.

Zoo Code is a small community continuation, not mainstream by any count found. But it costs little once a Roo-layout reader exists, and that reader also covers old Roo data. OpenAI's Codex, Tabnine, Amazon Q and Gemini Code Assist are not known to run Claude (unverified); they'd be out of scope unless they do.

## Roo Code

**Verified** (`RooCodeInc/Roo-Code`, `src/shared/globalFileNames.ts` on `main`, 2026-11-01): per-task files are:
- `api_conversation_history.json`, `ui_messages.json`, `task_metadata.json`;
- `history_item.json`, and an `_index.json`.

**Verified** (`RooCodeInc/Roo-Code` at `b867ec9`, 2026-05-15, the newest commit on `main` when cloned on 2026-11-01):
- **Tasks:** `src/utils/storage.ts` puts them in `<base>/tasks/<taskId>/`. `<base>` is the extension's VS Code global storage, or the `customStoragePath` setting if set.
- **History:** `src/core/task-persistence/TaskHistoryStore.ts` keeps each task's history item at `tasks/<taskId>/history_item.json`, with an index at `tasks/_index.json` "as a cache for fast list reads at startup".
- **History item** (`packages/types/src/history.ts`): `id`, `ts`, `task`, `tokensIn`, `tokensOut`, `cacheWrites`, `cacheReads`, `totalCost`, `workspace`, `mode`, and `status` (`active` / `completed` / `delegated`). It has no `pid`.
- **Asks** (`packages/types/src/message.ts`): `ui_messages.json` holds Roo's messages. An `ask` message whose type is in `interactiveAsks` (`followup`, `command`, `tool`, `use_mcp_server`) is one that waits on you; there is also an `idleAsks` list.

**Inference:**
- The newest entry in `ui_messages.json` tells "waiting on you" (an interactive ask) from "working".
- `status: active` tells an open task from a finished one.
- With no `pid`, "is it still running" must come from VS Code running plus how recently the task's files changed.

**Unverified:**
- how often `ui_messages.json` and `history_item.json` are rewritten during a turn;
- the global storage folder name. The marketplace id in the README is `RooVeterinaryInc.roo-cline`; the folder is probably that, lowercased, but I haven't checked.

**Observation:** `main`'s newest commit was 2026-05-15, while Cline's was 2026-10-30. I haven't checked whether Roo is still maintained.

## A correction

An earlier reply said supporting these would mean "no live 'is it running?' signal". That was a guess, not a finding, and it was wrong:
- Cline stores `status` and `pid`.
- Copilot chat stores `modelState`.
- The Claude agent writes Claude Code transcripts.

## Decision: which agents ctop supports (user, 2026-11-01)

ctop supports **Claude Code** (the CLI and its VS Code extension), **GitHub Copilot built into VS Code** (its chats, on any Claude model or a Claude API key, and its Claude agent) and **Cline**. Nothing else: not Roo Code (shut down), Zoo Code, Kilo Code or Continue.

The Roo/Zoo findings above stay as research only. In the design below, the Roo step is dropped.

## Proposed design (a proposal, not decided)

**Precondition:** ctop starts and works with no `claude` command (see the requirement above). Every agent's reader is optional. With none of them present, ctop says what it looked for and where.

**Shape:** one row per session whatever made it, with an AGENT column (`claude`, `copilot`, `cline`, `roo`) and a key to cycle which agents are shown. Each agent is a reader that returns the same row fields ctop has now:
- id, name/title, STATE (working / waiting on you / idle / gone), pid if any, cwd, model;
- tokens, context, cost (with its unit), last action, start and update times;
- the file to peek at.

The existing Claude Code reader stays as it is.

**Per agent, cheapest first:**

1. **Copilot's Claude agent.** Probably nearly free: its transcripts are ordinary Claude Code transcripts (inference, above). The work is labelling them, from the `AI_AGENT=github_copilot_vscode_agent` marker on the CLI process (Linux: `/proc/<pid>/environ`; Windows: unverified how). Blocked on the first step: does it appear in `claude agents --json`?

2. **Copilot chat.**
   - Read `workspaceStorage/*/chatSessions/*.jsonl` (and `.json`) changed within the keep window, replaying the mutation log incrementally.
   - STATE comes from the newest request's `modelState`. Since the file can be up to about a minute behind, show its age, and treat `Pending` as gone if no VS Code process is running.
   - Cost is in Copilot credits, shown as such, never mixed into dollar totals.
   - **Unverified:** where VS Code's user data folder is on each OS. I believe Windows is `%APPDATA%\Code\User`, Linux `~/.config/Code/User`, macOS `~/Library/Application Support/Code/User`, plus Insiders/VSCodium variants. That is from memory; check the VS Code docs or source before relying on it.

3. **Roo.** *Dropped by the decision above; kept for the record.*
   - Read `tasks/_index.json` and each task's `history_item.json` (tokens, cost in dollars, `status`).
   - "Waiting on you" comes from the newest `ui_messages.json` entry.
   - "Alive" comes from VS Code running plus recent file changes, since there is no pid.

4. **Cline.** The richest source (`status` and `pid`), but its live status is only in WAL-mode SQLite, which PowerShell can't read by itself. Options:
   - a. Use the `sqlite3` command if it's on PATH, else fall back to (c). No new dependency for ctop.
   - b. Bundle or download `Microsoft.Data.Sqlite` with its native library. Full fidelity, but ctop stops being one self-contained file.
   - c. Manifests only: `pid` alive gives "open", and `<id>.messages.json` changes give "active". No running/idle split.

   **Recommendation:** (a) with (c) as the fallback, and say on screen which one is in use.

**Before any code:**
- Run the first step (above).
- Check where Cline keeps tokens and cost.
- Check VS Code's user data paths from the source.
- Capture one real file from each agent as a test fixture; until then, every reader is written against source reading only.
