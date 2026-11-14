# Prompt-cache countdown Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A CACHE column (minutes left, `cold`, `-`) that replaces IDLE on ctop's main table, with a `cache` sort and a peek line giving the next turn's cost warm and cold, using the VS Code extension's own rule.

**Architecture:** `Update-Scan` already reads every usage line incrementally. It gains the cache anchor, TTL, re-cache size and compaction mark, which the scan cache persists. A pure function `Get-CacheState` applies the extension's rule at draw time, so the countdown moves every frame without reading files. Rows carry the state in `_Cache` and the text in `CACHE`.

**Tech Stack:** PowerShell (Windows PowerShell 5.1 and PowerShell 7), Pester 5.9.1.

**Spec:** `docs/superpowers/specs/2026-11-13-cache-countdown-design.md`

## Global Constraints

- The rule is the extension's (`anthropic.claude-code-2.1.323`, `webview/index.js`): `5m` = 300000 ms, `1h` = 3600000 ms; left = `min(ttl, anchor + ttl - now)`; warm shows `ceil(left / 60000)` minutes.
- It runs on Windows PowerShell 5.1 and PowerShell 7: no `??`, no `?.`, no 7-only .NET overloads. Parse timestamps with `[DateTimeOffset]::Parse(..., [Globalization.CultureInfo]::InvariantCulture)`.
- The build is 2026.11.13.3: `$script:CtopVersion`, the `.NOTES` `VERSION` line and a new `CHANGELOG.md` entry, all three (a test checks they agree).
- `$script:ScanVer` goes from 4 to 5, so cached scans without the new fields are rescanned.
- IDLE stays computed on every row (`$r.IDLE`). STATE's red rule (ctop.ps1 `Cell-Color` 'STATE', `Minutes $r.IDLE`) and peek still use it. Only its table column goes.

## Review Focus

1. **A future-stamped anchor** (clock skew): left is capped at the TTL, so the cell shows `60m`, never `61m`. Test it in Task 1.
2. **A newer usage line with no cache use**, such as a synthetic message with all-zero usage, after a 1-hour one: the TTL becomes unknown and the cell shows `-`, as the extension does. Test it in Task 1.
3. **A non-US culture:** the anchor parses under `de-DE`. Test it in Task 1.
4. **A gone Claude session keeps counting down:** `Update-GoneRow` refreshes CACHE as it does IDLE. Test it in Task 2.
5. **A warm row whose minutes change between frames is redrawn:** the row is marked `_Dirty`, as IDLE's refresh already does. Test it in Task 2.

---

### Task 1: Scan the cache fields and decide warm or cold

**Files:**
- Modify: `ctop.ps1`:
  - `$script:ScanVer` (line ~681);
  - `New-ScanState` (~831);
  - `Update-Scan`'s compact-boundary branch (~890) and usage branch (~936);
  - the handoff in `Get-LastAction` (~1152, after `$out.CacheW = ...`);
  - the `$out` initialisers at ~986, ~1731 and ~2033: add the new keys there with empty values.
- Test: `tests/Cache.Tests.ps1` (new).

**Interfaces:**
- Produces new scan-state and `_Act` fields:
  - `CacheAnchor`: an ISO-8601 string, or `''`;
  - `CacheAnchorId`: the anchor message's id, or `''`;
  - `CacheTtl`: `'1h'`, `'5m'` or `''`;
  - `RecacheTok`: a `[long]`, 0 when unknown;
  - `CacheCompactAt`: an ISO string, or `''`.
- Produces `Get-CacheState($act, [datetime]$now)`, which returns a hashtable:
  - `Kind`: `'warm'`, `'cold'` or `'unknown'`;
  - `Reason`: `'expired'` or `'compacted'`, for cold;
  - `Ttl`: `'1h'` or `'5m'`;
  - `MsLeft`, `MinutesLeft` and `IdleMs`, as `[double]`;
  - `RecacheTokens`, as `[long]`.
- Produces `Format-CacheCell($state)`, which returns a `[string]`: `'43m'`, `'cold'` or `'-'`.

Per usage line, with that line's `timestamp` and message `id`, `Update-Scan` sets the fields as follows:
- **The same message (`id -eq CacheAnchorId`):** keeps its `CacheAnchor`. Otherwise `CacheAnchor = timestamp` and `CacheAnchorId = id`.
- **The TTL:** if `cache_read + cache_creation > 0`, then:
  - `'1h'` when `ephemeral_1h_input_tokens > 0`;
  - otherwise `'5m'` when `ephemeral_5m_input_tokens > 0`;
  - otherwise the previous `CacheTtl`.

  With no cache use, the TTL becomes `''`.
- **The re-cache size:** `RecacheTok = input + cache_read + cache_creation`.
- **A compact-boundary line** sets `CacheCompactAt = timestamp`.
- **A later usage line** clears `CacheCompactAt` unless it is the same message or its timestamp is `<=` `CacheCompactAt`.

`Get-CacheState`, which mirrors the extension's `ej()`:
- **Compaction first:** `CacheCompactAt` set → cold, reason `compacted`.
- **Then the anchor and TTL:** no anchor or no TTL → unknown.
- **Otherwise:** warm while `MsLeft > 0`, else cold with reason `expired` and `IdleMs = now - anchor`.

- [ ] **Step 1: Write the failing tests** in `tests/Cache.Tests.ps1`. Dot-source `Import-Ctop.ps1`. Build transcripts in `$TestDrive` from JSON lines and run `Update-Scan (Get-Item $f) 'k'` with `$script:ScanCache = @{}` and `$script:Pricing` from `Get-DefaultPricing`, or whatever the existing transcript tests use: copy their `BeforeAll`. Tests:
  - `'takes 1h from a call that wrote a 1-hour cache'`: one assistant line with `"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}` at `2026-11-13T12:00:00.000Z` → `CacheTtl -eq '1h'`, `RecacheTok -eq 1203`, and `CacheAnchor` parses to that instant.
  - `'carries the TTL over a call that only read the cache'`: a 1h line, then a line with `cache_read_input_tokens` > 0 and `cache_creation_input_tokens` 0 → `'1h'`.
  - `'forgets the TTL after a call with no cache use'` (Review Focus 2): a 1h line, then a line with all-zero usage → `CacheTtl -eq ''`, and `Get-CacheState` gives `Kind -eq 'unknown'`.
  - `'keeps the first anchor across lines of one message'`: two lines with the same `"id":"msg_1"` and timestamps 12:00:00 and 12:00:30 → anchor 12:00:00.
  - `'is cold after a compaction until the next call'`: a 1h line, then `{"type":"system","subtype":"compact_boundary",...,"timestamp":"...12:05..."}` → `Kind 'cold'`, `Reason 'compacted'`. Then a new message at 12:06 → warm.
  - `Get-CacheState` table tests on hand-built `$act` hashtables, with `$now` = anchor + offset:

    | TTL | offset | Kind | MinutesLeft or Reason |
    |---|---|---|---|
    | 1h | 17 min 1 s | warm | 43 |
    | 1h | 59 min 59.5 s | warm | 1 |
    | 1h | 60 min | cold | expired, `IdleMs` 3600000 |
    | 5m | 1 min | warm | 4 |
    | 1h | −5 min (Review Focus 1) | warm | 60 |
  - `'parses the anchor under de-DE'` (Review Focus 3): set `[Threading.Thread]::CurrentThread.CurrentCulture = 'de-DE'` in a try/finally → still warm 43.
  - `Format-CacheCell`: warm 43 → `'43m'`; cold → `'cold'`; unknown → `'-'`.

- [ ] **Step 2: Run them and see them fail**

  Run: `pwsh -NoProfile -c 'Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester tests/Cache.Tests.ps1 -Output Detailed'`. Expected: FAIL (`Get-CacheState` is not recognized; `CacheTtl` is `$null`).

- [ ] **Step 3: Implement** the fields, `Get-CacheState` and `Format-CacheCell` as specified above. Bump `ScanVer` to 5. Parse `ephemeral_5m_input_tokens` explicitly with a regex, as the line already does for 1h.

- [ ] **Step 4: Run Cache, Transcript and Snapshot tests on both runtimes.**

  Run them on pwsh, and on `powershell` with `$env:PSModulePath` prefixed by `C:\Users\jlenzkes\Documents\PowerShell\Modules`. Expected: PASS.

- [ ] **Step 5: Commit** `Cache countdown: scan anchor/TTL and the extension's warm/cold rule`

### Task 2: The CACHE column, colours, sort and live refresh

**Files:**
- Modify: `ctop.ps1`:
  - the column table (~3366–3387): remove `IDLE`, add `@{ Name = 'CACHE'; Fixed = 5; Align = 'R'; Priority = 85 }` in IDLE's place;
  - `Build-Rows`' Claude-row (~3095) and subagent-row (~3011) literals: add `CACHE` and `_Cache`;
  - `Update-GoneRow`'s Claude branch (~2913);
  - `New-ClineRow` and `New-CopilotRow`: `CACHE = '-'`, `_Cache = $null`;
  - `Cell-Color` (~3325);
  - `$script:SortModes` and the `Sort-Rows` key switch (~3182–3198);
  - the `-Sort` `ValidateSet` (~123).
- Test: `tests/Cache.Tests.ps1` (append), plus the existing `Rows` and `Display` tests.

**Interfaces:**
- Consumes `Get-CacheState` and `Format-CacheCell` from Task 1.
- Produces `$r._Cache`, the state hashtable or `$null`, and `$r.CACHE`, a string. The sort mode is named `'cache'`.

How the rows get the values:
- **The value:** `Get-CacheState $act (Get-Date)` wherever IDLE is set for a Claude or subagent row, in `Build-Rows` and in `Update-GoneRow`, which already sets `_Dirty`.
- **Colour:** yellow while warm with `MsLeft <= 300000` on a 1h cache or `<= 60000` on a 5m one; `'dim'` when cold.
- **Sort key, ascending:**
  - warm → `MsLeft`;
  - cold → `1e12`;
  - unknown → `2e12`.

- [ ] **Step 1: Write the failing tests:**
  - `'shows CACHE, not IDLE, among the columns'`: find the column list's names and check they contain `CACHE` and not `IDLE`.
  - `'sorts warm rows soonest-first, then cold, then unknown'`: four rows with `_Cache` warm 10 min, warm 2 min, cold and unknown, plus whatever `Sort-Rows` needs (copy from `Rows.Tests.ps1`), with `$script:SortMode` set to the `'cache'` index → order 2 min, 10 min, cold, unknown.
  - `'colours the last 5 minutes of a 1-hour cache yellow and cold dim'`: `Cell-Color 'CACHE'` on rows with 4 min left (1h), 6 min left (1h), 40 s left (5m) and cold → yellow, '', yellow, dim.
  - `'counts down a gone session'` (Review Focus 4): a gone Claude row whose `_Act` has an anchor 20 min ago and TTL 1h. Run `Update-GoneRow` → `CACHE -eq '40m'` and `_Dirty`.
  - `'accepts -Sort cache'`: in `Cli.Tests.ps1`, `Invoke-Ctop @('-Version', '-Sort', 'cache')` exits 0.

- [ ] **Step 2: Run them and see them fail.**

- [ ] **Step 3: Implement.** Also update `Show-Help`'s column lines: replace the IDLE line (~3918) with `'  CACHE       T  prompt cache: minutes left while warm (yellow near the end), cold once expired, - unknown'`. Keep IDLE's description, but say it is shown in peek. Add `cache` where the help lists the `o` sort modes. In the `.SYNOPSIS`/`-Compact` help text (line 58), replace `IDLE` with `CACHE`.

- [ ] **Step 4: Run the whole unit suite on both runtimes:** `tests/Run-Tests.ps1 -Integration Skip`. Expected: 0 failed. Fix any existing test that named the IDLE column. Such a test pins the old layout, so update it rather than the code.

- [ ] **Step 5: Commit** `Cache countdown: CACHE column replaces IDLE; cache sort`

### Task 3: Peek line, docs, build

**Files:**
- Modify: `ctop.ps1`: the Claude peek (~3721, a new line after IDLE); the version lines.
- Modify: `CHANGELOG.md`, and `README.md` if it lists columns or sort modes.
- Test: `tests/Cache.Tests.ps1` (append).

**Interfaces:**
- Consumes `$r._Cache`, `$r._Act.Model` and `Get-Price`.
- Produces `Format-CachePeek($state, [string]$model)`, which returns a `[string]`: the text after `CACHE`.

The text, exactly:
- **Warm:** `warm, 43 min left (1h, last call 14:02:11) · next turn ≈ $0.07 warm, $1.32 cold (220K tokens)`.
  - The time is the anchor in local time.
  - Warm $ = `RecacheTokens * price.Read / 1e6`.
  - Cold $ = `RecacheTokens * (Ttl -eq '1h' ? price.W1h : price.W5) / 1e6`.
  - Both use 2 decimals.
  - Without a price, drop the `≈ …` costs and keep `(220K tokens)`.
- **Cold, expired:** `likely expired (idle 1h 12m) · next turn re-caches about 220K tokens ≈ $1.32`. The idle time is in the extension's format: `Nm` under an hour, `Nh Mm` under a day, `Nd Nh` beyond.
- **Cold, compacted:** `doesn't cover the compacted conversation: the next turn re-caches it`.
- **Unknown:** `unknown (no cache use recorded)`.

- [ ] **Step 1: Write the failing tests:** `Format-CachePeek` for warm (with a pricing entry whose Read = 0.5, W1h = 10 and W5 = 6.25, and 220000 tokens → `$0.11 warm, $2.20 cold (220K tokens)`), for warm with no price, for expired 72 min (→ `idle 1h 12m`), for compacted and for unknown.

- [ ] **Step 2: Run them and see them fail.**

- [ ] **Step 3: Implement.** Add the peek line `"  CACHE        $(Format-CachePeek $r._Cache $r._Act.Model)"` after the IDLE line. Bump to 2026.11.13.3. Write the CHANGELOG entry: what CACHE shows, that it follows the extension's rule, that IDLE moved to peek, the sort, and that the peek costs are estimates without the new message.

- [ ] **Step 4: Run the whole unit suite on both runtimes, and a real `ctop -Snapshot`.** Expected: 0 failed, and the snapshot header shows a CACHE column with values for live Claude rows.

- [ ] **Step 5: Commit, push, watch CI, and open the PR** with a "Merge status" section, not ready until Sol's audit. Its base is `claude/input-hardening` (PR #7) until #7 merges.
