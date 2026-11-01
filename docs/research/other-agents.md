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

## First step when this work resumes

Run **one Claude agent chat in VS Code**, then check two things while it is open:
- whether it appears in `claude agents --json` and in `~/.claude/sessions/`;
- whether its transcript is in `~/.claude/projects/`.

Also run **one Cline task** and check `~/.cline/data/db/sessions.db`.

These are the two facts the source reading could not settle.

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

**Not looked at:** which fields hold the model name, token use and cost, and the `.jsonl` mutation-log format (`chatSessionOperationLog.ts`, `objectMutationLog.ts`).

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

**Verified** (`session-manifest.ts`): each session also has a manifest. It holds `pid`, `status`, `started_at`, `ended_at`, `provider`, `model`, `cwd`, and `messages_path`.

**Unverified:** that the VS Code extension really ends up on the SQLite backend on Windows, where it runs inside VS Code's extension host. Settle it with the first step above.

**Verified** (PowerShell 7.6.9 on Linux, this container): PowerShell cannot read SQLite out of the box.
- `Microsoft.Data.Sqlite` and `System.Data.SQLite` are not loaded.
- There is no `sqlite3` command here.
- So reading `sessions.db` from ctop needs a dependency, a small bundled reader, or the JSON fallback/manifests.

That is a design decision to make first.

**Not looked at:** token use and cost per session; the hub (`sdk/packages/core/src/hub/discovery/instance-lock.ts`).

## Roo Code

**Verified** (`RooCodeInc/Roo-Code`, `src/shared/globalFileNames.ts` on `main`, 2026-11-01): per-task files are:
- `api_conversation_history.json`, `ui_messages.json`, `task_metadata.json`;
- `history_item.json`, and an `_index.json`.

**Unverified:** where those files live, and whether Roo has a live "running" signal. Roo forked from Cline before Cline's rewrite above, so it may differ; that is an inference.

## A correction

An earlier reply said supporting these would mean "no live 'is it running?' signal". That was a guess, not a finding, and it was wrong:
- Cline stores `status` and `pid`.
- Copilot chat stores `modelState`.
- The Claude agent writes Claude Code transcripts.
