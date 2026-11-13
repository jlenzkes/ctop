# Prompt-cache countdown in ctop: design

Status: approved by the user 2026-11-13 ("enact all recommendations").

## Why

The Claude Code extension for VS Code shows how long a session's prompt cache stays warm (a clock and
"43m" under the prompt box). The user wants the same for every session in ctop, subagents included. The
user's subagents now write 1-hour caches (`subagentPromptCacheTtl: "1h"` in `~/.claude/settings.json`;
transcripts show 5-minute writes up to 2026-11-11 and 1-hour writes on 2026-11-13). What the user does with
the countdown: (c) both decide which session to get back to before its cache goes cold, and see what going
cold would cost (user, 2026-11-13: "enact your recs").

## Goals

- A CACHE column on the main table: minutes left while warm, `cold` once expired, `-` when unknown.
- The same rule as the VS Code extension, so the two never disagree.
- Peek shows the cache state in full and what the next turn would pay warm and cold.
- Subagent rows get their own countdown, from their own transcripts.

## Non-goals

- Keeping caches warm (sending anything to a session).
- Copilot and Cline rows: their files record no cache lifetime (inference from the formats read so far);
  they show `-`.

## Anti-goals

- A countdown that disagrees with the extension for the same session.

## The rule (read in the extension, `anthropic.claude-code-2.1.323`, `webview/index.js`)

- **Anchor:** the time of the last assistant message: the request time when known, else its receive time,
  else its `timestamp`. ctop has only the transcript, so it uses `timestamp`. Entries of one message (same
  message id) keep the first anchor.
- **TTL:** if that message used the cache (`cache_read_input_tokens + cache_creation_input_tokens > 0`):
  `1h` when `cache_creation.ephemeral_1h_input_tokens > 0`, else `5m` when `ephemeral_5m_input_tokens > 0`,
  else the TTL carried from the previous message. A message with no cache use leaves the TTL unknown.
- **Left:** `min(ttl, anchor + ttl - now)`. Warm while above 0, shown as `ceil(left / 60 s)` minutes.
  Otherwise cold ("likely expired"), with the idle time.
- **Compaction:** after a compact, cold ("does not cover the compacted conversation") until the next message.
- **Re-cache size:** the last message's `input_tokens + cache_read_input_tokens + cache_creation_input_tokens`.

## Design

- **Column:** CACHE replaces IDLE on the main table. IDLE stays in peek, where it already is. The values are
  `43m`, `cold` and `-`. They're yellow in the last 5 minutes of a 1-hour cache and the last minute of a
  5-minute one, and `cold` is dimmed. `-Compact`'s essential columns swap IDLE for CACHE. STATE's
  "working + idle 2 min turns red" rule still reads the idle time, which is still computed.
- **Live:** ctop stores the anchor and TTL per row; the minutes are worked out at draw time, so the
  countdown moves every frame with no extra file reads.
- **Sort:** `o` gains `cache`: soonest to go cold first, then cold, then unknown.
- **Peek:** a CACHE line, for example `warm, 43 min left (1h, last call 14:02:11) · next turn ≈ $0.07 warm,
  $1.32 cold (220k tokens)`. Warm is the re-cache size at the cache-read price. Cold is the same size at the
  cache-write price for that TTL (1h: 2× input, 5m: 1.25× input). Both are estimates: they leave out the new
  message itself.
- **Gone sessions:** the countdown is shown too. A session resumed with `claude --resume` within its TTL may
  still hit the cache (inference, not verified).
- **Help and README:** describe CACHE and the `cache` sort.

## Approaches considered

- **Match the extension's rule, from the transcripts (chosen):** the only way the two always agree.
- **ctop's own rule (for example, anchored on the file's write time):** cheaper, but the file is also
  written for tool results and hooks, so it would drift from the extension.

## Left to the builder

- Where the anchor and TTL are kept in the scan state (alongside the CTX tokens `Update-Scan` already reads),
  and the scan-cache version bump that adding them needs.
- Colour names to match the existing palette.
