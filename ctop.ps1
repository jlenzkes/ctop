<#
.SYNOPSIS
  A top(1)-style live view of *interactive* Claude Code sessions.

.DESCRIPTION
  Polls `claude agents --json` every N seconds, keeps rows where kind == "interactive",
  and enriches each with:
    - CPU seconds and working-set MB from Get-Process (via the pid field)
    - last transcript activity, and what Claude was last doing, read from
      ~/.claude/projects/<project>/<sessionId>.jsonl
  Press q to quit, r to refresh now. Ctrl-C also works.

.PARAMETER SubagentWindow
  Seconds a STOPPED subagent stays listed after its last write (default 900 = 15 min; 0 = until
  its parent session goes away). A live subagent (working/thinking) is always listed regardless
  of how long its current tool call takes. Subagents have no process or PID; state is inferred
  from their transcript.

.PARAMETER Sort
  Initial sort mode: activity (default), roster, start, cost, ctx. Cycle at runtime with 'o'.

.PARAMETER Layout
  wrap (default): one row per session; a cell longer than its column wraps onto extra lines
  inside that column (up to -WrapLines), so columns stay aligned. truncate: single line, long
  cells cut with …. Toggle at runtime with 'v'.

.PARAMETER WrapLines
  Maximum lines a wrapped cell may use (default 2).

.PARAMETER MaxWidth
  Optional cap on table width in columns (default 0 = use the whole window). Set it if your
  window is wider than the monitor, so columns don't extend past the visible edge.

.PARAMETER Linger
  Minutes a session stays listed (dimmed, STATE "gone") after it disappears from the roster.
  Default 15. Peek a gone row for its title, cwd and resume command. Toggle with 'g'.

.PARAMETER HighlightModel
  Regex; MODEL cells matching it are shown in magenta so an unintended model stands out.
  Default 'fable|mythos'.

.PARAMETER ClosedLog
  Path of the closed-sessions log (JSONL). Default <config dir>/ctop-closed.jsonl. Every
  session that leaves the roster is appended with its name, title, id and cwd; 'x' shows it.

.PARAMETER SelectBg
  ANSI SGR parameters for the selected row's background (default '48;5;238', a dark gray that
  keeps cell colors readable on dark themes). Use e.g. '48;5;254' on a light theme, or '7' for
  plain inverse video.

.PARAMETER NoColor
  Disable ANSI colors (STATE, TURN, MODEL, sparkline, COST).

.PARAMETER Compact
  Show only the essential columns (NAME, STATE, TURN, IDLE, CTX, LAST ACTION, ACTIVITY, COST,
  BRANCH) regardless of window width. Toggle at runtime with 'c'.

.PARAMETER NoSubagents
  Don't scan for or show subagent rows. Toggle at runtime with 's'.

.PARAMETER Tick
  Display refresh period in milliseconds. Default 250. Each tick re-reads transcript tails
  and process stats for the sessions in the current roster (all local, cheap).

.PARAMETER RosterInterval
  Seconds between `claude agents --json` roster polls. Default 2. The poll runs
  asynchronously; the display never blocks on it, and repaints the instant it lands.

.PARAMETER All
  Include background sessions too (kind == "background").

.PARAMETER NoMouse
  Windows: don't take the mouse. By default ctop turns on console mouse input (and turns QuickEdit
  off while it runs) so you can click rows, double-click to peek, scroll with the wheel and click
  footer items; the terminal's own drag-to-select then needs Shift. The console mode is restored
  on exit.

.PARAMETER Version
  Print ctop's version and exit.

.NOTES
  VERSION 2026.10.27.1 — calendar versioning: YYYY.MM.DD of the build, then that day's build
  number. Shown as "build …" at the end of the instrument strip (line 2), on the help screen and
  on any crash message; -Version prints it.
  2026.10.27.1
    - a new subagent reads thinking from its first second: its prompt can sit behind ~10 large setup
      attachments, past the 256 KB tail ctop read, which left STATE blank until the first reply
  2026.10.21.5
    - mouse (Windows): click selects, click again / double-click peeks, wheel moves, footer items
      click, a click closes peek. -NoMouse to keep the terminal's own mouse. Console mode restored on exit
  2026.10.21.4
    - a subagent whose .meta.json says "finished": true (and whose transcript hasn't grown since) is
      stopped, whatever its transcript's last lines suggest; sidecars are re-read when they change
  2026.10.21.3
    - Σ tree cost under a session's COST (session + all its subagents, listed or aged out, + sessions
      it launched); peek has the breakdown
    - scrolling: a wrapped row cut by the window edge is left out instead of shown half
  2026.10.21.2
    - also while thinking: parallel Agent calls return one by one, so a parent waiting on the rest
      read "thinking"; with a live foreground agent it started, it now reads awaiting agent
  2026.10.21.1
    - a session or subagent whose open Agent / Task / Skill call is waiting on a live agent it
      started reads "awaiting agent" (cyan), not a red "working" that suggested waiting on you
  2026.10.20.2
    - sessions launched from another session's job (e.g. a script running claude -p) are drawn
      under that session, after its subagents, with their own subagents below them; peek shows
      LAUNCHED BY (launcher, job pid, command) and, on the launcher, LAUNCHED
    - Linux: ps -ww, so long command lines aren't cut to the terminal width
  2026.10.20.1
    - prices re-read 2026-10-20: Opus 5.5 ($4 / $20, cache read $0.20; was priced as Opus 5 at
      $5 / $25 / $0.50, overstating it), Sonnet 5.5, Haiku 5.5 (tiered at 100k-token prompts).
      Cached cost totals from the old table are recomputed once.
  2026.10.19.1
    - a subagent that handed back and was then sent a new message (resumed) shows its live state,
      LAST ACTION "resumed · after handback: …"; it stayed "stopped"
  2026.10.18.2
    - startup no longer opens every cached transcript (27 s for 1,049 files on Windows): cache
      entries are checked on first use and forgotten after 2 days unused; the 60 s save no longer
      tests every path either
  2026.10.18.1
    - an agent stopped by Esc / TaskStop ("[Request interrupted by user]" as its last line) reads
      stopped (subagent) or idle (session), LAST ACTION "interrupted · was …"; it showed thinking
  2026.10.06.2
    - version moved from beside the clock (where it read as the current date) to "build" on line 2
  2026.10.06.1
    - subagent .meta.json is retried while missing or half-written (was cached as "none" forever,
      leaving a bare id and no title)
    - job → agent attribution compares times in UTC (after a restart, cached call times came back
      as UTC and every job fell to the session)

  Documented fields of `claude agents --json` (code.claude.com/docs/en/agent-view, read 2026-09-07):
    cwd, kind, startedAt (Unix ms), pid, status, waitingFor, sessionId, name, id, state
  Transcript location is documented on code.claude.com/docs/en/claude-directory.
  The *internal* JSONL line shape (message.content[].type == "tool_use", .name, .input)
  is NOT officially documented; this script reads it defensively and degrades to "-".
#>
param(
  [int]$Tick = 250,
  [double]$RosterInterval = 2,
  [int]$SubagentWindow = 900,
  [switch]$NoSubagents,
  [switch]$Compact,
  [ValidateSet('activity','roster','start','cost','ctx')][string]$Sort = 'activity',
  [ValidateSet('wrap','truncate')][string]$Layout = 'wrap',
  [int]$WrapLines = 2,
  [int]$MaxWidth = 0,
  [int]$Linger = 15,
  [string]$HighlightModel = 'fable|mythos',
  [string]$SelectBg = '48;5;238',
  [string]$ClosedLog = '',
  [switch]$NoColor,
  [switch]$All,
  [switch]$NoMouse,
  [switch]$Version
)
$script:CtopVersion = '2026.10.27.1'   # YYYY.MM.DD.<build that day>; keep in step with .NOTES
if ($Version) { "ctop $script:CtopVersion"; return }

$ErrorActionPreference = 'SilentlyContinue'

# Respect CLAUDE_CONFIG_DIR (documented) — otherwise ~/.claude
$ConfigDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
$ProjectsDir = Join-Path $ConfigDir 'projects'

# Caches so a 1s refresh stays cheap with a large projects/ tree:
#   $TranscriptIndex : sessionId -> newest transcript FileInfo (rebuilt every roster poll)
#   $ScanCache  : sessionId -> byte offset + running totals (incremental transcript scan)
$script:TranscriptIndex = @{}
$script:TailCache  = @{}   # sessionId -> @{ Length; Write; Result }  (skip re-parse if file unchanged)

function Get-Age([long]$unixMs) {
  $start = [DateTimeOffset]::FromUnixTimeMilliseconds($unixMs).LocalDateTime
  $span = (Get-Date) - $start
  if ($span.TotalHours -ge 1) { '{0}h{1:00}m' -f [int][math]::Floor($span.TotalHours), $span.Minutes }
  else { '{0}m{1:00}s' -f $span.Minutes, $span.Seconds }
}

function Get-Since($t) {
  if ($null -eq $t -or "$t" -eq '') { return '-' }
  try { $t = [datetime]$t } catch { return '-' }
  $span = (Get-Date) - $t
  if ($span.Ticks -lt 0) { $span = [timespan]::Zero }   # clock skew / future-stamped entries
  if ($span.TotalHours -ge 1)   { '{0}h' -f [int][math]::Floor($span.TotalHours) }
  elseif ($span.TotalMinutes -ge 1) { '{0}m' -f [int][math]::Floor($span.TotalMinutes) }
  else { '{0}s' -f [int]$span.TotalSeconds }
}

# ---- frame writer -----------------------------------------------------------
# Redraw in place (home cursor + overwrite + pad) instead of Clear-Host: no blink.
# Lines may be strings or @{ Text; Fg; Bg; Inverse }. $Footer is pinned to the last row.
# Never writes the last column (w-1) so the terminal cannot auto-wrap.
# Cells may carry ANSI SGR color codes (see Paint); padding and truncation use visible length.
$script:AnsiRx = [regex]'\x1b\[[0-9;]*m'
function Strip-Ansi([string]$t) { $script:AnsiRx.Replace($t, '') }
function Truncate-Ansi([string]$t, [int]$n) {
  $sb = [Text.StringBuilder]::new(); $vis = 0; $i = 0
  while ($i -lt $t.Length -and $vis -lt $n) {
    if ($t[$i] -eq [char]27) {
      $m = $script:AnsiRx.Match($t, $i)
      if ($m.Success -and $m.Index -eq $i) { [void]$sb.Append($m.Value); $i += $m.Length; continue }
    }
    [void]$sb.Append($t[$i]); $vis++; $i++
  }
  [void]$sb.Append("$([char]27)[0m")
  return $sb.ToString()
}
function Write-Frame([object[]]$lines, [string]$Footer = '') {
  $w = [Console]::WindowWidth
  $h = [Console]::WindowHeight
  $E = [char]27
  $fg0 = [Console]::ForegroundColor; $bg0 = [Console]::BackgroundColor
  [Console]::SetCursorPosition(0, 0)
  $n = 0
  foreach ($item in $lines) {
    if ($n -ge $h - 1) { break }
    $text = if ($item -is [string]) { $item } else { [string]$item.Text }
    $styled = ($item -isnot [string]) -and ($item.Inverse -or $item.Select -or $item.Fg -or $item.Bg)
    # the selected row keeps its cell colors (tinted background); inverse/dim styles replace them
    $keepCells = $script:Color -and ($item -isnot [string]) -and $item.Select
    if ((-not $keepCells -and $styled) -or -not $script:Color) { $text = Strip-Ansi $text }
    $vis = (Strip-Ansi $text).Length
    if ($vis -gt $w - 1) { $text = if ($script:Color) { Truncate-Ansi $text ($w - 1) } else { (Strip-Ansi $text).Substring(0, $w - 1) }; $vis = $w - 1 }
    $text += ' ' * ($w - 1 - $vis)
    if ($styled) {
      if ($script:Color) {
        # one path for all styling: VT escapes (mixing the Console color API with VT codes
        # leaves stale attributes on Windows)
        $pre = ''
        if ($item.Inverse) { $pre += "$E[7m" }
        if ($item.Select) {
          $pre += "$E[${SelectBg}m"
          # every cell reset (ESC[0m) would drop the background: re-apply it after each one
          $text = $text -replace '\x1b\[0m', "$E[0m$E[${SelectBg}m"
        }
        if ($item.Fg -eq 'DarkGray') { $pre += "$E[90m" } elseif ($item.Fg) { $pre += "$E[3$([array]::IndexOf(@('Black','DarkRed','DarkGreen','DarkYellow','DarkBlue','DarkMagenta','DarkCyan','Gray'), [string]$item.Fg))m" }
        [Console]::Write($pre + $text + "$E[0m")
      } else {
        if ($item.Inverse -or $item.Select) { [Console]::ForegroundColor = $bg0; [Console]::BackgroundColor = $fg0 }
        if ($item.Fg) { [Console]::ForegroundColor = $item.Fg }
        if ($item.Bg) { [Console]::BackgroundColor = $item.Bg }
        [Console]::Write($text)
        [Console]::ForegroundColor = $fg0; [Console]::BackgroundColor = $bg0
      }
    } else {
      [Console]::Write($text)
    }
    if ($n -lt $h - 2) { [Console]::Write("`n") }
    $n++
  }
  $blank = ' ' * ($w - 1)
  # cursor is at the start of the line after the last written one: blank it, then move down
  while ($n -lt $h - 1) { [Console]::Write($blank); if ($n -lt $h - 2) { [Console]::Write("`n") }; $n++ }
  # footer on the last row; stop one column short so the terminal doesn't scroll
  [Console]::SetCursorPosition(0, $h - 1)
  $f = $Footer
  if (-not $script:Color) { $f = Strip-Ansi $f }
  $fv = (Strip-Ansi $f).Length
  if ($fv -gt $w - 1) { $f = if ($script:Color) { (Truncate-Ansi $f ($w - 1)) + "$E[90m" } else { (Strip-Ansi $f).Substring(0, $w - 1) }; $fv = $w - 1 }
  $pad = ' ' * ($w - 1 - $fv)
  if ($script:Color) { [Console]::Write("$E[90m" + $f + $pad + "$E[0m") }
  else { [Console]::ForegroundColor = 'DarkGray'; [Console]::Write($f + $pad); [Console]::ForegroundColor = $fg0 }
  [Console]::SetCursorPosition(0, 0)
}

# Fixed-width instrument cell: "label value" padded to $width, so values can change
# length without the strip shifting.
function Cell([string]$label, [string]$value, [int]$width) {
  ("$label $value").PadRight($width)
}

# Normalize a path for comparison and lookup. A session launched from Git Bash / MSYS stamps
# its cwd as /c/dev/src/x (Cygwin: /cygdrive/c/dev/src/x); on Windows that is C:\dev\src\x.
function Normalize-Path([string]$p) {
  if (-not $p) { return '' }
  if ($IsWindows -or $env:OS -eq 'Windows_NT') {
    if ($p -match '^/cygdrive/([a-zA-Z])(/.*)?$') { $p = $Matches[1].ToUpper() + ':' + $Matches[2] }
    elseif ($p -match '^/([a-zA-Z])(/.*)?$')     { $p = $Matches[1].ToUpper() + ':' + $Matches[2] }
    $p = $p.Replace('/', [string][char]92)
    if ($p -match '^[a-zA-Z]:$') { $p += [char]92 }
  }
  return $p.TrimEnd([char]92, [char]47)
}

# Transcript index: one scan of projects/*/*.jsonl per roster poll, newest file per session
# id. A session that enters a git worktree is re-recorded under a different project dir
# (docs: "the transcript follows"), so we must NOT pin a path once found — always take the
# most recently written match.
function Update-TranscriptIndex {
  $idx = @{}
  Get-ChildItem -Path $ProjectsDir -Directory | ForEach-Object {
    Get-ChildItem -Path $_.FullName -Filter '*.jsonl' -File | ForEach-Object {
      $id = $_.BaseName
      $cur = $idx[$id]
      if (-not $cur -or $_.LastWriteTimeUtc -gt $cur.LastWriteTimeUtc) { $idx[$id] = $_ }
    }
  }
  $script:TranscriptIndex = $idx
}

function Find-Transcript([string]$sessionId) {
  if (-not $sessionId) { return $null }
  $f = $script:TranscriptIndex[$sessionId]
  if ($f) { $f.Refresh(); if ($f.Exists) { return $f } }
  return $null
}

# Session titles, in the order the VS Code picker uses (verified against real transcripts):
#   custom-title (rename) > ai-title (generated) > summary record > first SendMessage summary
#   (peer sessions that only ever talked to another session) > first human prompt.
# Both title records live in the session's own transcript; the incremental scanner captures them.
# A sessions-index.json next to the transcripts is honored if present (not seen on Windows).
$script:IndexCache = @{}    # dir -> @{ Write; Map }
function Get-SessionTitle([string]$sessionId, [System.IO.FileInfo]$file) {
  if ($file) {
    $ip = Join-Path $file.DirectoryName 'sessions-index.json'
    if (Test-Path -LiteralPath $ip) {
      $fi = Get-Item -LiteralPath $ip
      $c = $script:IndexCache[$ip]
      if (-not $c -or $c.Write -ne $fi.LastWriteTimeUtc) {
        $map = @{}
        try {
          $j = Get-Content -LiteralPath $ip -Raw | ConvertFrom-Json
          $entries = if ($j -is [array]) { $j } elseif ($j.sessions) { $j.sessions } elseif ($j.entries) { $j.entries } else { @($j) }
          foreach ($e in $entries) {
            $id = $e.sessionId; if (-not $id) { $id = $e.id }
            if (-not $id) { continue }
            $t = $null
            foreach ($k in 'title','summary','displayName','customTitle','firstPrompt') { if ($e.$k) { $t = [string]$e.$k; break } }
            if ($t) { $map[[string]$id] = $t }
          }
        } catch {}
        $c = @{ Write = $fi.LastWriteTimeUtc; Map = $map }
        $script:IndexCache[$ip] = $c
      }
      if ($c.Map[$sessionId]) { return $c.Map[$sessionId] }
    }
  }
  $sc = $script:ScanCache[$sessionId]
  if ($sc) {
    if ($sc.Title)   { return $sc.Title }     # custom-title: a rename — the picker prefers it (verified 2026-09-11)
    if ($sc.AiTitle) { return $sc.AiTitle }   # ai-title: generated, rewritten every turn
    if ($sc.Summary)    { return $sc.Summary }
    if ($sc.MsgSummary) { return $sc.MsgSummary }   # subject of its FIRST SendMessage — what the picker shows for peer sessions
    if ($sc.First)      { return $sc.First }
  }
  return ''
}

# Which agent spawned this one? The meta's toolUseId is the id of the Agent tool call that
# launched it; that id occurs in the spawner's transcript. Search the sibling agent files
# (depth >= 2 only); no hit means the session itself is the spawner. Cached per agent file.
$script:SpawnerCache = @{}
$script:SidecarCache = @{}   # sessionId -> @{ At; Dirs }
function Get-Spawner([System.IO.FileInfo]$sf, $meta, [object[]]$siblings) {
  $k = $sf.FullName
  if ($script:SpawnerCache.ContainsKey($k)) { return $script:SpawnerCache[$k] }
  $result = $null
  # Claude Code stamps parentAgentId on nested agents (verified 2026-09-18): use it directly
  if ($meta -and $meta.parentAgentId) {
    $hit = $siblings | Where-Object { $_.BaseName -eq ('agent-' + $meta.parentAgentId) } | Select-Object -First 1
    if ($hit) { $script:SpawnerCache[$k] = 'sub:' + $hit.FullName; return $script:SpawnerCache[$k] }
  }
  if ($meta -and $meta.toolUseId -and [int]$meta.spawnDepth -ge 2) {   # fallback: find the Agent call by id
    foreach ($o in $siblings) {
      if ($o.FullName -eq $k) { continue }
      if (Select-String -LiteralPath $o.FullName -Pattern ([regex]::Escape('"id":"' + $meta.toolUseId + '"')) -Quiet) { $result = 'sub:' + $o.FullName; break }
    }
  }
  if ($meta) { $script:SpawnerCache[$k] = $result }   # no meta yet = undecided, ask again next time
  return $result
}

# Subagent transcripts live in a sidecar dir beside the parent transcript:
#   <project>/<sessionId>/subagents/agent-<hex>.jsonl
# (third-party parser consensus, not official docs). Returns files active within $SubagentWindow.
$script:AllAgents = @{}   # sessionId -> every agent-*.jsonl of that session (Find-Subagents)
function Find-Subagents([System.IO.FileInfo]$parent, [string]$sessionId) {
  if (-not $sessionId -and $parent) { $sessionId = $parent.BaseName }
  if (-not $sessionId) { return @() }
  $cutoff = (Get-Date).AddSeconds(-$SubagentWindow)
  $found = @()
  # The sidecar can sit under a different project dir than the main transcript when the session
  # changed working directory (Claude Code files by cwd): search every project dir.
  # Which project dirs hold a sidecar for this session is rediscovered only on roster polls
  # (every -RosterInterval s), not every tick: probing 100+ dirs per session per tick is slow.
  $cache = $script:SidecarCache[$sessionId]
  if (-not $cache -or $cache.At -lt $script:RosterAt) {
    $dirs = @()
    if ($parent) { $dirs += Join-Path $parent.DirectoryName (Join-Path $sessionId 'subagents') }
    $dirs += @(Get-ChildItem -Path $ProjectsDir -Directory -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName (Join-Path $sessionId 'subagents') })
    $cache = @{ At = Get-Date; Dirs = @($dirs | Select-Object -Unique | Where-Object { Test-Path -LiteralPath $_ }) }
    $script:SidecarCache[$sessionId] = $cache
  }
  foreach ($dir in $cache.Dirs) {
    $found += @(Get-ChildItem -Path $dir -Filter 'agent-*.jsonl' -File -Recurse -ErrorAction SilentlyContinue)
  }
  $script:AllAgents[$sessionId] = $found   # every agent file, listed or not: for the tree's Σ cost
  # An agent with a tool call in flight (working) is always shown, however long the call takes.
  # Everything else ages out after -SubagentWindow (0 = never, i.e. until the parent goes away):
  # stopped agents, and 'thinking' ones too, since a real generation doesn't go the whole window
  # without writing anything; an old 'thinking' row means a transcript ending ctop misreads.
  if ($SubagentWindow -gt 0) {
    $found = @($found | Where-Object {
      if ($_.LastWriteTime -gt $cutoff) { return $true }
      $st = (Get-LastAction $_ ('sub:' + $_.FullName)).State
      $st -eq 'working' -and -not (Test-Finished $_ (Get-SubagentMeta $_))
    })
  }
  return ,$found
}

# ---- pricing (USD per million tokens) --------------------------------------------
# Source: platform.claude.com/docs/en/about-claude/pricing, read 2026-10-20. List price —
# the same basis Claude Code's own /usage figures use; does not reflect subscription plans
# or contracted rates. For a session billed to an API key, list price is roughly the real charge.
# Order matters: first regex match wins. MaxPrompt: the row applies only to requests whose prompt
# (input + cache reads + cache writes) is at most that many tokens (Haiku 5.5 is tiered at 100k).
# Bump PriceVer whenever this table changes: cached cost totals from an older table are recomputed.
$script:PriceVer = 2
$script:Pricing = @(
  @{ Match = 'fable-5-1|mythos-5-1'; In = 10;  W5 = 12.5;  W1h = 20;  Read = 0.25; Out = 50 }
  @{ Match = 'fable-5|mythos-5';     In = 10;  W5 = 12.5;  W1h = 20;  Read = 1;    Out = 50 }
  @{ Match = 'opus-5-5';             In = 4;   W5 = 5;     W1h = 8;   Read = 0.2;  Out = 20 }
  @{ Match = 'opus-4-1|opus-4-2025|opus-4$'; In = 15; W5 = 18.75; W1h = 30; Read = 1.5; Out = 75 }
  @{ Match = 'opus-';                In = 5;   W5 = 6.25;  W1h = 10;  Read = 0.5;  Out = 25 }   # Opus 5, 4.5-4.8
  @{ Match = 'sonnet-5-5';           In = 2;   W5 = 2.5;   W1h = 4;   Read = 0.1;  Out = 10 }
  @{ Match = 'sonnet-5';             In = 2;   W5 = 2.5;   W1h = 4;   Read = 0.2;  Out = 10 }
  @{ Match = 'sonnet-';              In = 3;   W5 = 3.75;  W1h = 6;   Read = 0.3;  Out = 15 }
  @{ Match = 'haiku-5-5'; MaxPrompt = 100000; In = 0.1; W5 = 0.125; W1h = 0.2; Read = 0.01; Out = 0.5 }
  @{ Match = 'haiku-5-5';            In = 0.5; W5 = 0.625; W1h = 1;   Read = 0.05; Out = 2.5 }
  @{ Match = 'haiku-3-5';            In = 0.8; W5 = 1;     W1h = 1.6; Read = 0.08; Out = 4 }
  @{ Match = 'haiku-';               In = 1;   W5 = 1.25;  W1h = 2;   Read = 0.1;  Out = 5 }
)
function Get-Price([string]$model, [long]$prompt = 0) {
  foreach ($p in $script:Pricing) { if ($model -match $p.Match -and (-not $p.MaxPrompt -or $prompt -le $p.MaxPrompt)) { return $p } }
  return $null
}

# ---- incremental transcript scanner ------------------------------------------------
# Reads only bytes appended since the last scan, so a large busy transcript costs one
# small read per tick, never a full-file grep. Per line, regex extraction (no JSON parse):
#   user line without tool_result  -> a prompt (TURNS, TurnStart)
#   "type":"tool_use" occurrences  -> TOOLS
#   assistant line with usage      -> tokens + cost, deduped on message id (Claude Code writes
#                                     one line per content block, each repeating the usage)
# Decode a JSON string body captured by regex. Never throws: a malformed escape returns the raw text.
function Unescape-Json([string]$t) {
  if (-not $t -or $t.IndexOf('\\') -lt 0) { return $t }
  try { return (ConvertFrom-Json ('"' + $t + '"')) } catch { return $t }
}

$script:ScanCache = @{}
# Scan state is saved between runs, so a relaunch resumes each transcript where it left off
# instead of re-reading it from byte 0 (seconds, for a long session).
# Loading touches NO transcript: opening every cached file to check it cost ~26 ms each on Windows
# (27 s for 1,049 entries, measured 2026-10-18). Instead an entry is checked the first time it is
# used in this run (Update-Scan: shrank or first 256 bytes changed -> rescan), and entries not used
# for $script:CacheDays (2) days are forgotten. Used = UTC ticks (a number: JSON round-trips it unchanged).
$script:ScanCachePath = Join-Path $ConfigDir 'ctop-scancache.json'
$script:ScanVerified = @{}   # keys whose file was checked this run (never saved)
$script:CacheDays = 2
function Load-ScanCache {
  try {
    if (-not (Test-Path -LiteralPath $script:ScanCachePath)) { return }
    $h = Get-Content -LiteralPath $script:ScanCachePath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
    $cut = (Get-Date).ToUniversalTime().AddDays(-$script:CacheDays).Ticks
    foreach ($k in @($h.Keys)) {
      $e = $h[$k]
      # no Used stamp = written by a build before 2026.10.18.2: drop it (its sessions rescan once)
      if (-not $e.Path -or -not $e.Head -or -not $e.Used -or [long]$e.Used -lt $cut) { continue }
      if ([int]$e.PriceVer -ne $script:PriceVer) { continue }   # costs from an older price table: rescan
      if (-not $e.ToolCounts) { $e.ToolCounts = @{} }
      $script:ScanCache[$k] = $e
    }
  } catch {}   # unreadable cache (or Windows PowerShell 5.1, no -AsHashtable): just scan from scratch
}
function Save-ScanCache {
  try {
    $cut = (Get-Date).ToUniversalTime().AddDays(-$script:CacheDays).Ticks
    $keep = @{}
    foreach ($k in @($script:ScanCache.Keys)) { $e = $script:ScanCache[$k]; if ($e.Path -and $e.Used -and [long]$e.Used -ge $cut) { $keep[$k] = $e } }
    $keep | ConvertTo-Json -Depth 5 -Compress | Set-Content -LiteralPath $script:ScanCachePath -Encoding UTF8
  } catch {}
}
# Identity of a transcript: its first 256 bytes (the opening entry never changes as the file grows,
# and a replaced file starts differently). Creation time is not portable: on Linux .NET reports the
# inode change time, which moves on every append.
function Get-HeadPrint([string]$path) {
  $fs = $null
  try {
    $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
    $b = New-Object byte[] ([math]::Min(256, $fs.Length)); $n = $fs.Read($b, 0, $b.Length)
    return [Convert]::ToBase64String($b, 0, $n)
  } catch { return '' } finally { if ($fs) { $fs.Dispose() } }
}
function New-ScanState([System.IO.FileInfo]$file) {
  @{ Path = $file.FullName; Head = (Get-HeadPrint $file.FullName)
     PriceVer = $script:PriceVer; Offset = 0; Turns = 0; Tools = 0; TurnStart = $null; Cost = 0.0; InTok = 0; OutTok = 0; CacheR = 0; CacheW = 0;
     LastId = ''; LastCost = 0.0; LastOut = 0; Model = '-'; AiTitle = ''; Summary = ''; Title = ''; First = ''; MsgSummary = ''; Cwd = ''; GitBranch = ''; ToolCounts = @{}
     Compacts = 0; LastCompactAt = $null; LastCompactTrigger = ''; LastCompactPreTokens = 0; ToolLog = @() }
}
function Update-Scan([System.IO.FileInfo]$file, [string]$key) {
  $st = $script:ScanCache[$key]
  # first use this run of state restored from disk: is it still the same file? (one 256-byte read)
  if ($st -and -not $script:ScanVerified.ContainsKey($key)) {
    if ($st.Path -ne $file.FullName -or $st.Head -ne (Get-HeadPrint $file.FullName)) { $st = $null }
  }
  # no state yet, or the file shrank / was replaced: start over from byte 0 with fresh totals
  if (-not $st -or $file.Length -lt $st.Offset) {
    $st = New-ScanState $file
    $script:ScanCache[$key] = $st
  }
  $script:ScanVerified[$key] = $true
  $st.Used = (Get-Date).ToUniversalTime().Ticks
  if ($file.Length -eq $st.Offset) { return $st }
  $fs = $null
  try {
    $fs = [IO.File]::Open($file.FullName, 'Open', 'Read', 'ReadWrite')
    $null = $fs.Seek($st.Offset, 'Begin')
    $buf = New-Object byte[] ($file.Length - $st.Offset)
    $n = $fs.Read($buf, 0, $buf.Length)
    if ($n -le 0) { return $st }
    $lastNl = [Array]::LastIndexOf($buf, [byte]10, $n - 1)
    if ($lastNl -lt 0) { return $st }                                 # no complete line yet
    $st.Offset += $lastNl + 1
    $text = [Text.Encoding]::UTF8.GetString($buf, 0, $lastNl)
    foreach ($line in $text.Split("`n")) {
      if ($line.Length -lt 20) { continue }
      # entry-level fields are in the last few hundred chars of a line: search only there
      $tailPart = if ($line.Length -gt 2000) { $line.Substring($line.Length - 2000) } else { $line }
      # Entry-level fields sit AFTER the message body (verified 2026-09-14: ... entrypoint, cwd,
      # sessionId, version, gitBranch). Anchor on the key adjacency so a "cwd" printed inside tool
      # output can't be mistaken for the session's location. Newest entry wins, so a session that
      # moved into a worktree (/cd, EnterWorktree) reports its new location.
      if ($tailPart -match '"cwd"\s*:\s*"((?:[^"\\]|\\.)*)"\s*,\s*"sessionId"\s*:') { $st.Cwd = Unescape-Json($Matches[1]) }
      if ($tailPart -match '"version"\s*:\s*"[^"]*"\s*,\s*"gitBranch"\s*:\s*"((?:[^"\\]|\\.)*)"') { $st.GitBranch = Unescape-Json($Matches[1]) }
      # Compaction: {"type":"system","subtype":"compact_boundary","compactMetadata":{trigger,preTokens}}
      # followed by a user entry with isCompactSummary:true (the summary that replaces the history)
      if ($line.Contains('"subtype":"compact_boundary"')) {
        $st.Compacts++
        if ($line -match '"timestamp":"([^"]+)"') { try { $st.LastCompactAt = [datetime]$Matches[1] } catch {} }
        if ($line -match '"trigger":"([^"]+)"') { $st.LastCompactTrigger = $Matches[1] }
        if ($line -match '"preTokens":(\d+)') { $st.LastCompactPreTokens = [long]$Matches[1] }
        continue
      }
      if ($line.Contains('"type":"ai-title"')) {
        # the VS Code picker's name: {"type":"ai-title","sessionId":"...","aiTitle":"..."}  (verified 2026-09-09)
        if ($line -match '"aiTitle":"((?:[^"\\]|\\.)*)"') { $st.AiTitle = Unescape-Json($Matches[1]) }
        continue
      }
      if ($line.Contains('"type":"summary"')) {
        if ($line -match '"summary":"((?:[^"\\]|\\.)*)"') { $st.Summary = Unescape-Json($Matches[1]) }
        continue
      }
      if ($line.Contains('"type":"custom-title"')) {
        if ($line -match '"customTitle":"((?:[^"\\]|\\.)*)"') { $st.Title = Unescape-Json($Matches[1]) }
        continue
      }
      if ($line.Contains('"type":"user"')) {
        if ($line.Contains('"isCompactSummary":true')) { continue }   # machine-written summary, not a human turn
        if (-not $line.Contains('tool_result')) {
          $st.Turns++
          if (-not $st.First -and $line -match '"content":"((?:[^"\\]|\\.)*)"') {
            $f = ((Unescape-Json($Matches[1]) -replace '<[^>]+>', '') -replace '\s+', ' ').Trim()
            # only accept something that reads like a human prompt
            if ($f.Length -ge 4 -and $f -notmatch '^[\[<{]' -and $f -notmatch 'toolu_|hook feedback|^Caveat:|^This session is being continued|^Another Claude session|^\[Request interrupted' -and $f -match '[a-zA-Z]{3}') { $st.First = $f }
          }
          if ($line -match '"timestamp":"([^"]+)"') { try { $st.TurnStart = [datetime]$Matches[1] } catch {} }
        }
      } elseif ($line.Contains('"type":"assistant"')) {
        $st.Tools += ([regex]::Matches($line, '"type":"tool_use"')).Count
        # tool_use blocks are {"type":"tool_use","id":..,"name":"Bash","input":{..}} — name precedes input
        foreach ($m in [regex]::Matches($line, '"name":"([^"]+)","input":\{')) { $n = $m.Groups[1].Value; $st.ToolCounts[$n] = 1 + [int]$st.ToolCounts[$n] }
        # when this agent made each Bash / PowerShell call: used to tell which agent a running job belongs to
        if ($line.Contains('"name":"Bash"') -or $line.Contains('"name":"PowerShell"')) {
          $ts = if ($tailPart -match '"timestamp":"([^"]+)"') { $Matches[1] } elseif ($line -match '"timestamp":"([^"]+)"') { $Matches[1] } else { $null }
          if ($ts) {
            foreach ($m in [regex]::Matches($line, '"name":"(Bash|PowerShell)","input":\{')) {
              $st.ToolLog = @(@($st.ToolLog) + @(@{ Tool = $m.Groups[1].Value; At = $ts }) | Select-Object -Last 40)
            }
          }
        }
        # The VS Code picker titles an otherwise-untitled session by the "summary" of its FIRST
        # outbound SendMessage, and keeps it when later messages are sent (verified 2026-09-14 against
        # sessions that sent a re-verdict: the picker kept the original). First wins.
        if (-not $st.MsgSummary -and $line -match '"name":"SendMessage","input":\{[^}]*?"summary":"((?:[^"\\]|\\.)*)"') { $st.MsgSummary = Unescape-Json($Matches[1]) }
        if ($line -match '"model":"([^"]+)"') { $m = $Matches[1]; if ($m -ne '<synthetic>') { $st.Model = $m } }
        if ($line -match '"usage":\{') {
          $id = if ($line -match '"id":"(msg_[^"]+)"') { $Matches[1] } else { '' }
          $in  = if ($line -match '"input_tokens":(\d+)') { [long]$Matches[1] } else { 0 }
          $out = if ($line -match '"output_tokens":(\d+)') { [long]$Matches[1] } else { 0 }
          $cr  = if ($line -match '"cache_read_input_tokens":(\d+)') { [long]$Matches[1] } else { 0 }
          $cw  = if ($line -match '"cache_creation_input_tokens":(\d+)') { [long]$Matches[1] } else { 0 }
          $cw1h = if ($line -match '"ephemeral_1h_input_tokens":(\d+)') { [long]$Matches[1] } else { 0 }
          $cw5 = [math]::Max(0, $cw - $cw1h)
          $price = Get-Price $st.Model ($in + $cr + $cw)
          $c = if ($price) { ($in * $price.In + $out * $price.Out + $cr * $price.Read + $cw5 * $price.W5 + $cw1h * $price.W1h) / 1e6 } else { 0.0 }
          if ($id -and $id -eq $st.LastId) {
            # same message: replace, don't add (later lines carry the final output_tokens)
            $st.Cost -= $st.LastCost; $st.OutTok -= $st.LastOut
          } else {
            $st.InTok += $in; $st.CacheR += $cr; $st.CacheW += $cw
          }
          $st.Cost += $c; $st.OutTok += $out; $st.LastId = $id; $st.LastCost = $c; $st.LastOut = $out
        }
      }
    }
  } catch {} finally { if ($fs) { $fs.Dispose() } }
  return $st
}

# Read the tail of the transcript and summarize the last assistant action.
# Last complete lines from the end of a file, reading at most $bytes. The first (partial) line of
# the window is dropped unless the window started at byte 0.
function Read-TailLines([string]$path, [int]$bytes) {
  $fs = $null
  try {
    $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
    $len = $fs.Length
    if ($len -eq 0) { return @() }
    $start = [math]::Max(0, $len - $bytes)
    $null = $fs.Seek($start, 'Begin')
    $buf = New-Object byte[] ($len - $start)
    $n = $fs.Read($buf, 0, $buf.Length)
    $text = [Text.Encoding]::UTF8.GetString($buf, 0, $n)
    $parts = $text.Split("`n")
    if ($start -gt 0 -and $parts.Count -gt 1) { $parts = $parts[1..($parts.Count - 1)] }   # drop the cut line
    return @($parts | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_.Length -gt 0 })
  } catch { return @() } finally { if ($fs) { $fs.Dispose() } }
}

function Get-LastAction([System.IO.FileInfo]$file, [string]$sessionId) {
  $out = [ordered]@{ State = '-'; Last = '-'; LastFull = ''; ToolLog = @(); Handback = $false; Synthetic = $null; SysError = $false; Cwd = ''; GitBranch = ''; ToolMix = ''; Compacts = 0; LastCompactAt = $null; LastCompactTrigger = ''; LastCompactPreTokens = 0; Turns = '-'; Model = '-'; Ctx = '-'; Tools = '-'; TurnStart = $null; Cost = 0.0; InTok = 0; OutTok = 0; CacheR = 0; CacheW = 0 }
  if (-not $file) { return $out }
  $stamp = $script:TailCache[$sessionId]
  if ($stamp -and $stamp.Length -eq $file.Length -and $stamp.Write -eq $file.LastWriteTimeUtc) {
    return $stamp.Result
  }
  # Read the tail by BYTES, not lines: Get-Content -Tail on a large transcript whose single lines
  # can be hundreds of KB costs seconds. 256 KB covers the newest few entries; if no two complete
  # lines fit (one giant tool result), retry once with a bigger window.
  # STATE heuristic from the newest line (undocumented transcript shape):
  #   user line          -> Claude's turn, nothing emitted yet        = thinking
  #   assistant+tool_use -> tool running or awaiting permission       = working
  #   assistant text     -> turn finished, waiting on you             = idle
  # The newest prompt/reply can sit behind a wall of other entries: a new subagent's transcript is
  # its prompt followed by ~10 setup attachments (environment, skill_listing, prompt_snapshot, …;
  # seen 2026-10-27), which can fill a 256 KB tail. So widen until the window holds a user or
  # assistant line, or covers the whole file.
  $lastObj = $null; $lines = @()
  foreach ($win in 262144, 4194304, 16777216) {
    $lines = @(Read-TailLines $file.FullName $win)
    for ($j = $lines.Count - 1; $j -ge 0; $j--) {
      $ln = $lines[$j]
      if (-not ($ln.Contains('"type":"user"') -or $ln.Contains('"type":"assistant"'))) { continue }   # cheap: no JSON parse of big attachments
      try { $lastObj = $ln | ConvertFrom-Json } catch { continue }
      if ($lastObj -and ($lastObj.type -in 'user','assistant')) { break }
      $lastObj = $null
    }
    if ($lastObj -or $win -ge $file.Length) { break }
  }
  if (-not $lines) { return $out }
  $interrupted = $false
  if ($lastObj) {
    if ($lastObj.type -eq 'user') {
      # Claude Code records a stop (Esc, or TaskStop on a subagent) as a user line
      # "[Request interrupted by user]" (or "... for tool use"). Nothing answers it: the agent has
      # stopped, so it must not read as about-to-reply. Seen 2026-10-18 on a TaskStop-killed subagent.
      $uc = $lastObj.message.content
      $utext = if ($uc -is [string]) { $uc } else { (@($uc) | Where-Object { $_.type -eq 'text' } | Select-Object -Last 1).text }
      $interrupted = [string]$utext -match '^\s*\[Request interrupted by user'
      $out.State = if ($interrupted) { 'idle' } else { 'thinking' }
    }
    else {
      $c = $lastObj.message.content
      $hasTool = ($c -isnot [string]) -and ($c | Where-Object { $_.type -eq 'tool_use' })
      # Claude Code writes each block of a reply as its own line. A turn never ends on a thinking
      # block (a reply ends in text or a tool call), so a thinking-only newest line = mid-reply.
      $onlyThinking = ($c -isnot [string]) -and @($c).Count -gt 0 -and -not ($c | Where-Object { $_.type -notin 'thinking', 'redacted_thinking' })
      $out.State = if ($hasTool) { 'working' } elseif ($onlyThinking) { 'thinking' } else { 'idle' }
    }
  }

  # Walk backwards to the newest assistant entry with content.
  for ($i = $lines.Count - 1; $i -ge 0; $i--) {
    $obj = $null
    if (-not $lines[$i].Contains('"type":"assistant"')) { continue }   # skip parsing attachments and results
    try { $obj = $lines[$i] | ConvertFrom-Json } catch { continue }
    if (-not $obj) { continue }
    if ($obj.type -ne 'assistant') { continue }
    $msg = $obj.message
    # Claude Code writes some assistant messages itself (usage-limit notices, API errors) with
    # model "<synthetic>" and no API call behind them. Never show that as the model.
    if ($null -eq $out.Synthetic) { $out.Synthetic = ($msg.model -eq '<synthetic>') }
    if ($msg.model -and $msg.model -ne '<synthetic>' -and $out.Model -eq '-') { $out.Model = ($msg.model -replace '^claude-', '') }
    if ($msg.usage -and $out.Ctx -eq '-') {
      $u = $msg.usage
      $ctx = [long]0
      foreach ($k in 'input_tokens','cache_read_input_tokens','cache_creation_input_tokens') { if ($u.$k) { $ctx += [long]$u.$k } }
      if ($ctx -gt 0) { $out.Ctx = [math]::Round($ctx / 1000) }
    }
    $content = $msg.content
    if (-not $content) { continue }
    # content may be a string or an array of blocks
    if ($content -is [string]) { $t = ($content -replace '\s+', ' ').Trim(); $out.LastFull = 'text: ' + $t; $out.Last = 'text: ' + $t.Substring(0, [math]::Min(120, $t.Length)); break }
    $tool = $content | Where-Object { $_.type -eq 'tool_use' } | Select-Object -Last 1
    if ($tool -and $tool.name -eq 'SubagentHandback') {
      # Claude Code >= 2.1.271: a subagent delivers its report through SubagentHandback, then stops.
      # The report is in input.message. It can hand back again later (e.g. when background work it
      # started finishes), so this means stopped-for-now, exactly like a text ending.
      $out.Handback = $true; $hbAt = $i
      $t = (([string]$tool.input.message) -replace '[\x00-\x1F\x7F]+', ' ') -replace '\s{2,}', ' '
      $out.LastFull = ('handback: ' + $t).Trim()
      $out.Last = if ($out.LastFull.Length -gt 130) { $out.LastFull.Substring(0, 129) + '…' } else { $out.LastFull }
      break
    }
    if ($tool) {
      $arg = ''; $keepTail = $false
      foreach ($k in 'file_path','path','command','pattern','query','description','prompt') {
        if ($tool.input.$k) { $arg = [string]$tool.input.$k; $keepTail = ($k -in 'file_path','path'); break }
      }
      $arg = ($arg -replace '[\x00-\x1F\x7F]+', ' ') -replace '\s{2,}', ' '
      $out.LastFull = "$($tool.name) $arg".Trim()
      if ($arg.Length -gt 120) { $arg = if ($keepTail) { '…' + $arg.Substring($arg.Length - 119) } else { $arg.Substring(0, 119) + '…' } }
      $out.Last = "$($tool.name) $arg".Trim()
      break
    }
    $text = ($content | Where-Object { $_.type -eq 'text' } | Select-Object -Last 1).text
    if ($text) { $t = ($text -replace '\s+', ' ').Trim(); $out.LastFull = 'text: ' + $t; $out.Last = 'text: ' + $t.Substring(0, [math]::Min(120, $t.Length)); break }
  }
  # the newest model entry handed back its report: the agent has stopped, whatever was logged after it
  # ...unless its spawner has since sent it a new message (SendMessage to a stopped agent resumes
  # it; seen 2026-10-19). What follows a handback on its own is only the handback's tool_result,
  # so: a later user line with real content (text, not a tool_result) = resumed, keep the live state.
  $resumed = $false
  if ($out.Handback) {
    for ($j = $hbAt + 1; $j -lt $lines.Count; $j++) {
      $o3 = $null; try { $o3 = $lines[$j] | ConvertFrom-Json } catch { continue }
      if (-not $o3 -or $o3.type -ne 'user' -or $o3.isMeta) { continue }
      $c3 = $o3.message.content
      $hasText = if ($c3 -is [string]) { [bool]$c3.Trim() } else { [bool](@($c3) | Where-Object { $_.type -ne 'tool_result' }) }
      if ($hasText) { $resumed = $true; break }
    }
    if (-not $resumed) { $out.State = 'idle' }
    else { $out.Last = 'resumed · after ' + $out.Last; $out.LastFull = 'resumed · after ' + $out.LastFull }
  }
  if ($interrupted) { $out.Last = 'interrupted · was ' + $out.Last; $out.LastFull = 'interrupted · was ' + $out.LastFull }
  $sc = Update-Scan $file $sessionId
  $out.Turns = $sc.Turns; $out.Tools = $sc.Tools; $out.TurnStart = $sc.TurnStart
  $out.Cost = $sc.Cost; $out.InTok = $sc.InTok; $out.OutTok = $sc.OutTok; $out.CacheR = $sc.CacheR; $out.CacheW = $sc.CacheW
  $out.Cwd = $sc.Cwd
  $out.ToolLog = @($sc.ToolLog)
  $out.GitBranch = $sc.GitBranch
  $out.Compacts = $sc.Compacts; $out.LastCompactAt = $sc.LastCompactAt; $out.LastCompactTrigger = $sc.LastCompactTrigger; $out.LastCompactPreTokens = $sc.LastCompactPreTokens
  $out.ToolMix = ($sc.ToolCounts.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "$($_.Key) $($_.Value)" }) -join ' · '
  # newest message was synthetic: its zero usage must not mask the context size; take CTX from
  # the newest real assistant entry in the tail
  if ($out.Synthetic -and $out.Ctx -eq '-') {
    for ($j = $lines.Count - 1; $j -ge 0; $j--) {
      $o2 = $null; try { $o2 = $lines[$j] | ConvertFrom-Json } catch { continue }
      if (-not $o2 -or $o2.type -ne 'assistant' -or $o2.message.model -eq '<synthetic>' -or -not $o2.message.usage) { continue }
      $u2 = $o2.message.usage; $c2 = [long]0
      foreach ($k in 'input_tokens','cache_read_input_tokens','cache_creation_input_tokens') { if ($u2.$k) { $c2 += [long]$u2.$k } }
      if ($c2 -gt 0) { $out.Ctx = [math]::Round($c2 / 1000); break }
    }
  }
  # newest message was synthetic: fall back to the last REAL model the scanner saw
  if ($out.Model -eq '-' -and $sc.Model -and $sc.Model -ne '-') { $out.Model = ($sc.Model -replace '^claude-', '') }
  $out.Synthetic = [bool]$out.Synthetic
  # a Claude-Code-written notice that the turn could not run: usage limit or API error
  $out.SysError = $out.Synthetic -and ($out.LastFull -match '(?i)limit|error|overloaded|unavailable|too long|credit')
  $script:TailCache[$sessionId] = @{ Length = $file.Length; Write = $file.LastWriteTimeUtc; Result = $out }
  return $out
}

# Resolve the claude executable once. On Windows an npm install may give a .cmd shim,
# which has to go through cmd.exe; the native installer gives claude.exe.
$script:ClaudeCmd = (Get-Command claude -ErrorAction Stop).Source

# Git branch of a directory, read from .git/HEAD without spawning git. Follows the
# "gitdir: <path>" pointer file that worktrees use. Cached per cwd per roster poll.
$script:BranchCache = @{}
function Get-Branch([string]$dir) { (Get-GitInfo $dir).Branch }
function Get-GitInfo([string]$dir) {
  $none = @{ Branch = '-'; Worktree = $false; Main = '' }
  if (-not $dir) { return $none }
  if ($script:BranchCache.ContainsKey($dir)) { return $script:BranchCache[$dir] }
  $result = $none
  try {
    $d = $dir
    while ($d -and -not (Test-Path -LiteralPath (Join-Path $d '.git'))) { $d = Split-Path -Parent $d }
    if ($d) {
      $g = Join-Path $d '.git'
      $wt = $false; $main = ''
      $headFile = if (Test-Path -LiteralPath $g -PathType Leaf) {
        # linked worktree: .git is a pointer file "gitdir: <main>/.git/worktrees/<name>"
        $ptr = (Get-Content -LiteralPath $g -First 1) -replace '^gitdir:\s*', ''
        if (-not [IO.Path]::IsPathRooted($ptr)) { $ptr = Join-Path $d $ptr }
        $wt = $true
        if ($ptr -match '^(.*)[\\/]\.git[\\/]worktrees[\\/]') { $main = $Matches[1] }
        Join-Path $ptr 'HEAD'
      } else { Join-Path $g 'HEAD' }
      $branch = '-'
      if (Test-Path -LiteralPath $headFile) {
        $h = Get-Content -LiteralPath $headFile -First 1
        $branch = if ($h -match '^ref: refs/heads/(.+)$') { $Matches[1] } else { $h.Substring(0, 7) }   # detached
      }
      $result = @{ Branch = $branch; Worktree = $wt; Main = $main }
    }
  } catch {}
  $script:BranchCache[$dir] = $result
  return $result
}

# ---- activity history (sparkline) -------------------------------------------------
# One sample every 2 s per row: █ working  ▒ thinking  · idle  (space) unknown. 20 samples = 40 s.
$script:History = @{}
$script:HistoryAt = [datetime]::MinValue
$script:SparkLen = 20
$script:CompactSeen = @{}
function Add-Sample([string]$key, [string]$state, [int]$compacts = 0) {
  $ch = switch -Wildcard ($state) { 'working' {'█'} 'thinking' {'▒'} 'idle' {'·'} 'waiting*' {'▁'} 'awaiting*' {'░'} 'polling' {'░'} default {' '} }
  # a compaction since the last sample is drawn as ▼ in that slot
  $prev = $script:CompactSeen[$key]
  if ($null -ne $prev -and $compacts -gt $prev) { $ch = '▼' }
  $script:CompactSeen[$key] = $compacts
  $h = $script:History[$key]; if (-not $h) { $h = '' }
  $h += $ch
  if ($h.Length -gt $script:SparkLen) { $h = $h.Substring($h.Length - $script:SparkLen) }
  $script:History[$key] = $h
}

# Subagent sidecar metadata: <agent>.meta.json next to the transcript
# (observed: agentType, description, toolUseId, spawnDepth). Cached per path — but only once it
# has been read: the sidecar can appear after the transcript, or be mid-write (unreadable / partial
# JSON) on first sight. A miss is retried at most every 2 s instead of being remembered forever.
# Claude Code rewrites the sidecar when the agent ends, adding "finished": true (seen 2026-10-21:
# true on every stopped agent of a 35-agent run, absent on the one still running), so a cached copy
# is re-read whenever the file's write time changes (one stat per agent per tick).
$script:MetaCache = @{}; $script:MetaMiss = @{}; $script:MetaWrite = @{}
function Get-SubagentMeta([System.IO.FileInfo]$sf) {
  $mp = [IO.Path]::ChangeExtension($sf.FullName, '.meta.json')
  $w = [IO.File]::GetLastWriteTimeUtc($mp)   # 1601-01-01 when the file doesn't exist
  if ($script:MetaCache.ContainsKey($mp) -and $script:MetaWrite[$mp] -eq $w) { return $script:MetaCache[$mp] }
  if (-not $script:MetaCache.ContainsKey($mp) -and $script:MetaMiss.ContainsKey($mp) -and ((Get-Date) - $script:MetaMiss[$mp]).TotalSeconds -lt 2) { return $null }
  $m = $null
  try { if ($w.Year -gt 1601) { $m = Get-Content -LiteralPath $mp -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } } catch { $m = $null }
  if ($m) { $script:MetaCache[$mp] = $m; $script:MetaWrite[$mp] = $w; $script:MetaMiss.Remove($mp) }
  elseif ($script:MetaCache.ContainsKey($mp)) { return $script:MetaCache[$mp] }   # mid-rewrite: keep the last good copy
  else { $script:MetaMiss[$mp] = Get-Date }
  return $m
}
# Stopped by Claude Code's own record: finished:true, and nothing written to the transcript since
# the sidecar was (a stopped agent that is sent a new message resumes: its transcript then grows
# past the sidecar's time, and the transcript decides again).
function Test-Finished([System.IO.FileInfo]$sf, $meta) {
  if (-not $meta -or $meta.finished -ne $true) { return $false }
  $mw = $script:MetaWrite[[IO.Path]::ChangeExtension($sf.FullName, '.meta.json')]
  return ($mw -and $sf.LastWriteTimeUtc -le $mw.AddSeconds(2))
}

# ---- clipboard ------------------------------------------------------------------
$script:Flash = ''; $script:FlashUntil = [datetime]::MinValue
function Copy-Text([string]$text, [string]$what) {
  try { Set-Clipboard -Value $text; $script:Flash = "copied $what to clipboard"; }
  catch { $script:Flash = "clipboard unavailable: $($_.Exception.Message)" }
  $script:FlashUntil = (Get-Date).AddSeconds(3)
}

# ---- closed-sessions log ----------------------------------------------------------
# Appended whenever a session leaves the roster; survives ctop restarts. Shown with 'x'.
function Write-ClosedLog($sess, [datetime]$when, [string]$why = 'closed') {
  try {
    $file  = Find-Transcript $sess.sessionId
    $title = Get-SessionTitle $sess.sessionId $file
    $rec = [ordered]@{ closedAt = $when.ToString('o'); why = $why; name = $sess.name; title = $title; sessionId = $sess.sessionId
                       cwd = $sess.cwd; pid = $sess.pid; startedAt = $sess.startedAt }
    Add-Content -LiteralPath $script:ClosedLogPath -Value ($rec | ConvertTo-Json -Compress) -Encoding UTF8
  } catch {}
}
function Read-ClosedLog([int]$max = 200) {
  if (-not (Test-Path -LiteralPath $script:ClosedLogPath)) { return @() }
  $recs = @()
  foreach ($l in (Get-Content -LiteralPath $script:ClosedLogPath -Tail $max -Encoding UTF8)) { try { $recs += ($l | ConvertFrom-Json) } catch {} }
  # newest first; one entry per session id
  $seen = @{}; $out = @()
  foreach ($r in ($recs | Sort-Object { [datetime]$_.closedAt } -Descending)) { if (-not $seen[[string]$r.sessionId]) { $seen[[string]$r.sessionId] = $true; $out += $r } }
  return $out
}
function Show-Closed {
  $recs = @(Read-ClosedLog)
  $lines = @(@{ Text = "  ctop — closed sessions   ($($recs.Count), newest first; clr = replaced by /clear, still resumable)   log: $($script:ClosedLogPath)"; Inverse = $true }, '')
  if ($recs.Count -eq 0) { $lines += '  (none recorded yet — sessions are logged here when they leave the roster)' }
  foreach ($r in $recs) {
    $t = ([datetime]$r.closedAt).ToString('MM-dd HH:mm')
    $lines += "  $t  $(if ($r.why -eq 'cleared') { 'clr' } else { '   ' })  $(([string]$r.name).PadRight(14))  $($r.title)"
    $lines += "                              claude --resume $($r.sessionId)     $($r.cwd)"
  }
  $per = [math]::Max(4, [Console]::WindowHeight - 3)
  $pages = [math]::Max(1, [math]::Ceiling($lines.Count / $per))
  for ($pg = 0; $pg -lt $pages; $pg++) {
    $chunk = @($lines[($pg * $per)..([math]::Min($lines.Count, ($pg + 1) * $per) - 1)])
    $foot = if ($pg -lt $pages - 1) { "  page $($pg + 1)/$pages   any key: next   q: close" } else { "  page $($pg + 1)/$pages   any key to close" }
    Write-Frame $chunk $foot
    while ([Console]::KeyAvailable) { $null = [Console]::ReadKey($true) }
    $k = [Console]::ReadKey($true)
    if ($k.KeyChar -eq 'q' -or $k.Key -eq 'Escape') { break }
  }
}

# ---- roster feed (asynchronous) ---------------------------------------------
# Starts `claude agents --json` as a windowless child (no console => can't retitle this
# tab or write escapes into it) and returns immediately. Read-Roster polls for completion.
function Start-RosterPoll {
  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  if ($script:ClaudeCmd -match '\.(cmd|bat)$') {
    $psi.FileName  = 'cmd.exe'
    $psi.Arguments = "/d /c `"`"$script:ClaudeCmd`" agents --json`""
  } else {
    $psi.FileName  = $script:ClaudeCmd
    $psi.Arguments = 'agents --json'
  }
  $psi.UseShellExecute        = $false
  $psi.CreateNoWindow         = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  $proc = [System.Diagnostics.Process]::Start($psi)
  # Async readers so a full pipe buffer can never deadlock the child.
  $script:Poll = @{
    Proc    = $proc
    Out     = $proc.StandardOutput.ReadToEndAsync()
    Err     = $proc.StandardError.ReadToEndAsync()
    Started = [System.Diagnostics.Stopwatch]::StartNew()
  }
}

# Returns $true if a fresh roster landed this call.
# ---- background jobs (process tree) ------------------------------------------------
# A session that launched shell work in the background and went idle still has that work running
# as OS processes under its claude process. The process table is read on a background thread at
# the roster cadence (Windows: CIM; elsewhere: ps), so the display never waits on it.
$script:ProcJob = $null; $script:ProcTable = @(); $script:JobMap = @{}
# pid -> @{ SessPid; JobPid; Label } for every process inside some session's job: a roster session
# whose own process is in there was launched by that session (e.g. a script that runs claude -p)
$script:LaunchedBy = @{}
$script:ProcAt = Get-Date; $script:JobCpuPrev = @{}   # job key -> @{ At } (when the job was last sampled)
$script:ProcCpuPrev = @{}   # "pid@start" -> CPU seconds at the previous poll, per process
$script:ProcScript = {
  if ($IsWindows -or $env:OS -eq 'Windows_NT') {
    Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CommandLine, CreationDate, KernelModeTime, UserModeTime -ErrorAction SilentlyContinue |
      ForEach-Object { [pscustomobject]@{ Pid = [int]$_.ProcessId; Ppid = [int]$_.ParentProcessId; Name = [string]$_.Name; Cmd = [string]$_.CommandLine; Start = $_.CreationDate
                                          Cpu = ([double]$_.KernelModeTime + [double]$_.UserModeTime) / 1e7 } }   # 100 ns units -> seconds
  } else {
    $now = Get-Date
    # -ww: never cut args to the terminal width (ps honors COLUMNS; a cut line loses the tool-wrapper marker)
    & ps -ww -eo 'pid=,ppid=,etimes=,stat=,times=,comm=,args=' 2>$null | ForEach-Object {
      # stat Z = zombie: exited, just not reaped yet. Finished work is not a running job.
      if ($_ -match '^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(\d+)\s+(\S+)\s+(.*)$' -and $Matches[4] -notlike 'Z*') {
        $o = [pscustomobject]@{ Pid = [int]$Matches[1]; Ppid = [int]$Matches[2]; Name = $Matches[6]; Cmd = $Matches[7]; Start = $now.AddSeconds(-[int]$Matches[3]); Cpu = [double]$Matches[5] }
        # ps reports CPU in whole seconds: too coarse for a 2 s rate. Linux keeps clock ticks
        # (1/100 s) in /proc/<pid>/stat: utime and stime are fields 14-15, i.e. 12th-13th after ')'
        try {
          $st = [IO.File]::ReadAllText("/proc/$($o.Pid)/stat")
          $f = $st.Substring($st.LastIndexOf(')') + 2).Split(' ')
          $o.Cpu = ([double]$f[11] + [double]$f[12]) / 100
        } catch {}
        $o
      }
    }
  }
}
function Start-ProcPoll {
  if ($script:ProcJob) { return }
  if (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue) { $script:ProcJob = Start-ThreadJob -ScriptBlock $script:ProcScript }
  else { $script:ProcTable = @(& $script:ProcScript); $script:ProcAt = Get-Date; Update-JobMap }   # no ThreadJob module: run inline
}
function Read-ProcPoll {
  $j = $script:ProcJob
  if (-not $j -or $j.State -notin 'Completed', 'Failed', 'Stopped') { return }
  $script:ProcTable = @(Receive-Job $j -ErrorAction SilentlyContinue)
  $script:ProcAt = Get-Date
  Remove-Job $j -Force -ErrorAction SilentlyContinue
  $script:ProcJob = $null
  Update-JobMap
}
# Long-lived helpers a session hosts that are not "work it is waiting on": MCP servers, language
# servers, console hosts. Also anything started within 15 s of the session process itself.
$script:HelperRx = '(?i)(^|[\\/\s"])(conhost|openconsole)(\.exe)?("|\s|$)|mcp|language-?server|--stdio|tsserver|pyright|gopls|rust-analyzer|eslint_d'
$script:ShellRx  = '(?i)^(bash|sh|zsh|dash|cmd|pwsh|powershell)(\.exe)?$'
# Wait loops: a command that does nothing but wait for something external (a file to appear, a
# marker like rc= in a log, another process to finish). until/while + sleep, a bare sleep, tail -f,
# PowerShell Start-Sleep loops and Wait-Process / Wait-Job.
$script:PollRx = '(?is)\b(until|while)\b.*\b(sleep|Start-Sleep)\b|^\s*(Bash|PowerShell)?\s*(sleep|Start-Sleep)(\s+-\w+)?\s+[\d.]+\s*$|\btail\s+-[fF]\b|\bWait-(Process|Job)\b'
# A row is polling if it has running work and every command behind it is a wait loop:
# its own pending tool call (when working) or its jobs' commands (when awaiting).
function Test-Polling([string]$state, $act, [object[]]$jobs) {
  $js = @($jobs | Where-Object { $_ })
  if (-not $js.Count) { return $false }   # no process yet: a poll still waiting for approval stays 'working'
  if ($state -eq 'working') { return [string]$act.LastFull -match $script:PollRx }
  if ($state -like 'awaiting*') { return -not ($js | Where-Object { [string]$_.Label -notmatch $script:PollRx }) }
  return $false
}
# The open tool call started an agent and is waiting for it: a foreground Agent / Task call, or a
# Skill that runs as a forked subagent (/code-review, seen 2026-10-21). While an agent it spawned
# is still live, the row is waiting on that agent, not stuck or waiting on you. $spawnerId: '' for
# the session (its direct agents have no spawner), else the subagent row's _SessionId.
# thinking counts too when the newest action started agents: parallel Agent calls hand their results
# back one by one, so a result line lands (reads "thinking") while sibling agents are still running
# and the model can't reply until they finish (seen 2026-10-21, a /code-review fan-out of 24 checks).
# Only foreground agents block that way: a parent can really be thinking while background ones run.
function Test-AwaitingAgent([string]$state, $act, [object[]]$kids, [string]$spawnerId) {
  if ($state -notin 'working', 'thinking' -or [string]$act.LastFull -notmatch '^(Agent|Task|Skill)\b') { return $false }
  return [bool](@($kids | Where-Object { $_ -and ([string]$_._Spawner) -eq $spawnerId -and -not $_._Done -and
                                          ($state -eq 'working' -or $_._Shape -ne 'background') }).Count)
}
# A readable label for a job: the command line without the executable's directory. If the deepest
# process is still the shell, pull the user command out of Claude Code's wrapper (eval '...').
function Get-JobLabel([string]$cmd, [string]$name) {
  if (-not $cmd) { return $name }
  if ($name -match $script:ShellRx -and $cmd -match "eval '((?:[^']|'\\'')*)'") {
    $cmd = ($Matches[1] -replace "'\\''", "'") -replace '\\"', '"'
    $cmd = $cmd -replace '^\s*cd\s+("[^"]*"|\S+)\s*&&\s*', ''                    # leading cd <dir> &&
    $cmd = $cmd -replace ';\s*echo\s+rc=\$\?\s*$', ''                             # trailing ; echo rc=$?
    $cmd = $cmd -replace '\s+\d?>>?&?\d?\s*("[^"]*"|[^\s&|;]+)?', ''            # redirections: > f, 2>&1, >> f
  }
  $cmd = ($cmd -replace '\s+', ' ').Trim()
  if ($cmd -match '^"([^"]*[\\/])?([^\\/"]+)"(.*)$') { return $Matches[2] + $Matches[3] }
  # drop a leading program's directory (C:\Py\python.exe x -> python.exe x), but only if the first word
  # looks like a program: an assignment (F="C:/a/b.out"; ...) or a quoted string must stay intact
  if ($cmd -match '^([^\s="]*[\\/])?([^\\/\s="]+)(\s.*)?$') { return $Matches[2] + $Matches[3] }
  return $cmd
}
function Update-JobMap {
  $script:ProcSeen = @{}   # this poll's per-process CPU, becomes ProcCpuPrev at the end
  $byPid = @{}; $kids = @{}
  foreach ($p in $script:ProcTable) {
    $byPid[$p.Pid] = $p
    if (-not $kids.ContainsKey($p.Ppid)) { $kids[$p.Ppid] = [System.Collections.Generic.List[object]]::new() }
    $kids[$p.Ppid].Add($p)
  }
  $map = @{}; $launched = @{}
  foreach ($s in $script:Roster) {
    if (-not $s.pid) { continue }
    $sp = [int]$s.pid; $root = $byPid[$sp]
    if (-not $root -or -not $kids.ContainsKey($sp)) { continue }
    $jobs = @(); $helpers = 0; $hooks = @()
    foreach ($c in $kids[$sp]) {
      # Claude Code's Bash tool runs every command through a wrapper that sources a snapshot from
      # ~/.claude/shell-snapshots (verified on Windows, 2026-10-01): that is always a job, even if
      # the command mentions "mcp" or started early. Everything else is checked against helpers.
      $isBashTool = [string]$c.Cmd -match 'shell-snapshots[\\/]snapshot-'
      # The PowerShell tool (verified on Windows, 2026-10-01): cmd.exe /c "chcp 65001 & pwsh.exe
      # -Command "$_claudeCodeScript = $env:CLAUDE_CODE_SHELL_LAUNCH..."". Its script travels in an
      # environment variable, which can't be read from outside, so it is labeled by what it runs.
      $psTool = $false
      foreach ($x in @($c) + @($kids[$c.Pid])) { if ($x -and [string]$x.Cmd -match '_claudeCodeScript|CLAUDE_CODE_SHELL') { $psTool = $true } }
      if ($psTool) { $isBashTool = $false }
      # Claude Code's tools run commands through a shell; what it starts directly (git for branch
      # info, ripgrep, MCP servers, console hosts) is its own plumbing. So a job must be rooted in a
      # shell: any other direct child is a helper, whatever its name.
      $isShell = [string]$c.Name -match $script:ShellRx
      $early = $root.Start -and $c.Start -and (([datetime]$c.Start) - ([datetime]$root.Start)).TotalSeconds -lt 15
      if (-not $isBashTool -and -not $psTool) {
        # Not one of the two verified tool wrappers. A shell started by Claude Code that isn't a tool
        # call is a hook run (e.g. bash -c "gk.exe ai hook run --host claude-code", seen 2026-10-01):
        # shown in peek, never treated as work the session is waiting on. Anything else is plumbing.
        if ($isShell -and -not ((("$($c.Name) $($c.Cmd)") -match $script:HelperRx) -or $early)) {
          $hooks += @{ Label = (Get-JobLabel ([string]$c.Cmd -replace '^.*?\s-c\s+', '' -replace '\\"', '"' -replace '^"(.*)"$', '$1') ''); Since = $c.Start; Pid = $c.Pid }
        } else { $helpers++ }
        continue
      }
      # label from the deepest descendant that isn't a console host
      $leaf = $c; $best = 0; $cpuGrow = 0.0; $deep = @{}   # depth -> processes at that depth (not console hosts)
      $byProg = @{}; $busyN = @{}   # program name -> CPU growth this window / processes of it that used CPU
      $key = "$($c.Pid)@$($c.Start)"; $prev = $script:JobCpuPrev[$key]
      $q = [System.Collections.Generic.Queue[object]]::new(); $q.Enqueue(@($c, 0))
      $treePids = [System.Collections.Generic.List[int]]::new()
      while ($q.Count) {
        $it = $q.Dequeue(); $p = $it[0]; $d = $it[1]
        $treePids.Add([int]$p.Pid)
        # CPU growth per process since the previous poll. Summing totals instead would let a process
        # that exits between polls take its whole history with it and drag the job's rate below zero;
        # a job of many short-lived processes would read 0% exactly when it is busiest.
        $pk = "$($p.Pid)@$($p.Start)"; $g = 0.0
        if ($script:ProcCpuPrev.ContainsKey($pk)) { $g = [math]::Max(0.0, [double]$p.Cpu - $script:ProcCpuPrev[$pk]) }   # 0.0, not 0: Max(0, x) picks the integer overload and rounds x away
        elseif ($prev) { $g = [double]$p.Cpu }   # new since the last poll: all of its CPU was spent in this window
        $cpuGrow += $g
        # which program is doing the work: CPU growth per program name (shells and console hosts aside)
        if ($g -gt 0 -and $p.Name -notmatch $script:ShellRx -and -not ("$($p.Name)" -match '(?i)conhost|openconsole')) {
          $byProg[$p.Name] = [double]$byProg[$p.Name] + $g; $busyN[$p.Name] = [int]$busyN[$p.Name] + 1
        }
        $script:ProcSeen[$pk] = [double]$p.Cpu
        if (-not ("$($p.Name) $($p.Cmd)" -match '(?i)conhost|openconsole')) {
          if (-not $deep.ContainsKey($d)) { $deep[$d] = @() }; $deep[$d] += $p
          if ($d -gt $best) { $leaf = $p; $best = $d }
        }
        if ($kids.ContainsKey($p.Pid) -and $d -lt 10) { foreach ($k in $kids[$p.Pid]) { $q.Enqueue(@($k, ($d + 1))) } }
      }
      # CPU rate across the job's whole process tree since the previous poll (needs two polls)
      $rate = $null
      if ($prev) { $dt = ($script:ProcAt - $prev.At).TotalSeconds; if ($dt -gt 0.5) { $rate = $cpuGrow / $dt * 100 } }
      $script:JobCpuPrev[$key] = @{ At = $script:ProcAt }
      # Name the job by what the session asked for: a Bash-tool job by the command in its wrapper,
      # which stays put while the work runs. The deepest process changes as it goes (a test script
      # shelling out to git, say), so it is shown separately as a sign of progress, not as the name.
      if ($isBashTool) { $label = Get-JobLabel $c.Cmd $c.Name }
      else {
        $label = Get-JobLabel $leaf.Cmd $leaf.Name
        $bare = -not ([string]$leaf.Cmd -match '\S\s+\S')   # no arguments visible
        if ($leaf -ne $c -and ($leaf.Name -match $script:ShellRx -or $bare)) { $label = Get-JobLabel $c.Cmd $c.Name }
      }
      if ($byProg.Count) {
        # where the CPU went this window, and how many of that program's processes were busy
        $top = $byProg.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1
        $now = [string]$top.Key; $workers = [int]$busyN[$top.Key]
      } else {
        # first poll (no CPU history yet) or nothing used CPU: the deepest process, and its siblings
        $now = if ($leaf -ne $c -and $leaf.Name -notmatch $script:ShellRx) { [string]$leaf.Name } else { '' }
        $workers = if ($best -gt 0) { @($deep[$best] | Where-Object { $_.Name -eq $leaf.Name }).Count } else { 0 }
      }
      if ($now -and $workers -gt 1) { $now = "$now ×$workers" }
      foreach ($tp in $treePids) { $launched[$tp] = @{ SessPid = $sp; JobPid = [int]$c.Pid; Label = $label } }
      $jobs += @{ Label = $label; Since = $c.Start; Pid = $c.Pid; Now = $now; Cpu = $rate; Via = $(if ($psTool) { 'PowerShell tool' } else { '' }); Kind = $(if ($psTool) { 'ps' } elseif ($isBashTool) { 'bash' } else { '' }) }
    }
    $map[$sp] = @{ Jobs = $jobs; Helpers = $helpers; Hooks = $hooks }
  }
  $script:JobMap = $map
  $script:LaunchedBy = $launched
  $script:ProcCpuPrev = $script:ProcSeen   # processes that exited simply drop out
  $live = @{}; foreach ($m in $map.Values) { foreach ($jb in $m.Jobs) { $live["$($jb.Pid)"] = $true } }
  foreach ($k in @($script:JobCpuPrev.Keys)) { if (-not $live[$k.Split('@')[0]]) { $script:JobCpuPrev.Remove($k) } }
}

function Read-Roster {
  $p = $script:Poll
  if (-not $p) { return $false }
  if (-not ($p.Proc.HasExited -and $p.Out.IsCompleted)) { return $false }
  $script:PollMs   = [int]$p.Started.ElapsedMilliseconds
  $script:RosterAt = Get-Date
  $script:Poll     = $null
  $raw = $p.Out.Result
  $p.Proc.Dispose()
  $sessions = @()
  if ($raw) { try { $sessions = @($raw | ConvertFrom-Json) } catch { $sessions = @() } }
  if (-not $All) { $sessions = @($sessions | Where-Object { $_.kind -eq 'interactive' }) }
  $script:BranchCache = @{}
  Update-TranscriptIndex
  Start-ProcPoll
  # One process, one row. After /clear (or a compaction that rolls to a new session id) the
  # supervisor can still list the old session id under the same pid; keep the live one —
  # the entry whose transcript was written most recently, then the newest startedAt.
  $byPid = [ordered]@{}
  foreach ($x in $sessions) {
    $k = if ($x.pid) { [string]$x.pid } else { [string]$x.sessionId }
    $cur = $byPid[$k]
    if (-not $cur) { $byPid[$k] = $x; continue }
    $tNew = $script:TranscriptIndex[[string]$x.sessionId];   $tCur = $script:TranscriptIndex[[string]$cur.sessionId]
    $wNew = if ($tNew) { $tNew.LastWriteTimeUtc } else { [datetime]::MinValue }
    $wCur = if ($tCur) { $tCur.LastWriteTimeUtc } else { [datetime]::MinValue }
    if ($wNew -gt $wCur -or ($wNew -eq $wCur -and [long]$x.startedAt -gt [long]$cur.startedAt)) { $byPid[$k] = $x }
  }
  $live = @($byPid.Values)
  $i = 0; foreach ($x in $live) { $x | Add-Member -NotePropertyName _order -NotePropertyValue $i -Force; $i++ }
  # departed: anything we knew last poll that isn't in this one lingers for $Linger minutes
  $now = Get-Date
  $liveIds = @($live | ForEach-Object { [string]$_.sessionId })
  foreach ($old in $script:Roster) {
    $id = [string]$old.sessionId
    if ($id -notin $liveIds -and -not $script:Departed.ContainsKey($id)) {
      $successor = $live | Where-Object { $_.pid -and $_.pid -eq $old.pid -and [string]$_.sessionId -ne $id } | Select-Object -First 1
      $script:Departed[$id] = @{ Session = $old; GoneAt = $now; Cleared = [bool]$successor; Successor = $(if ($successor) { [string]$successor.sessionId } else { '' }) }
      Write-ClosedLog $old $now $(if ($successor) { 'cleared' } else { 'closed' })
    }
  }
  foreach ($id in @($script:Departed.Keys)) {
    if ($id -in $liveIds -or ($now - $script:Departed[$id].GoneAt).TotalMinutes -gt $Linger) { $script:Departed.Remove($id) }
  }
  $script:Roster = $live
  return $true
}

# ---- display rows (cheap; runs every tick against the cached roster) --------
# Supervisor status (claude agents --json: status / state / waitingFor) is authoritative when it
# says something the transcript can't know (waiting on input). Where it only says "busy", the
# transcript heuristic supplies the working / thinking split. Unknown values pass through.
function Resolve-State($s, $act, $gone, $cleared = $false) {
  if ($gone) { return $(if ($cleared) { 'cleared ' } else { 'gone ' }) + (Get-Since $gone) }
  if ($s.waitingFor) { return "waiting: $($s.waitingFor)" }
  $sup = ([string]$s.status + [string]$s.state).ToLowerInvariant()
  switch -Regex ($sup) {
    '^$'                       { return $act.State }
    # busy + transcript ends in a tool call -> working (tool in flight); busy + anything else ->
    # thinking (the model is still generating; nothing new on disk yet)
    '^(busy|running|working|active)$' { if ($act.State -eq 'working') { return 'working' } else { return 'thinking' } }
    '^(idle|ready|done|completed|finished)$' { return 'idle' }
    '^(waiting|blocked|paused|permission)'   { return 'waiting' }
    default                    { return $sup }
  }
}

function Build-Rows {
  $sample = ((Get-Date) - $script:HistoryAt).TotalSeconds -ge 2
  if ($sample) { $script:HistoryAt = Get-Date }
  $all = @($script:Roster | ForEach-Object { @{ S = $_; Gone = $null; Cleared = $false; Successor = '' } })
  if ($script:ShowGone) { $all += @($script:Departed.Values | ForEach-Object { @{ S = $_.Session; Gone = $_.GoneAt; Cleared = $_.Cleared; Successor = $_.Successor } }) }
  foreach ($e in $all) {
    $s = $e.S; $gone = $e.Gone; $cleared = $e.Cleared
    $proc = if ($s.pid -and -not $gone) { Get-Process -Id $s.pid } else { $null }
    $file = Find-Transcript $s.sessionId
    $act  = Get-LastAction $file $s.sessionId
    $cwd  = Normalize-Path $(if ($act.Cwd) { $act.Cwd } else { [string]$s.cwd })   # transcript knows where the session is now
    $git  = Get-GitInfo $cwd
    $state = Resolve-State $s $act $gone $cleared
    if ($state -eq 'idle' -and $act.SysError) { $state = 'error' }   # stopped on a limit / API-error notice
    $jm = if ($s.pid -and -not $gone) { $script:JobMap[[int]$s.pid] } else { $null }
    $jobs = @(if ($jm) { $jm.Jobs })   # @(if ...) — a bare 'if' would unroll a one-job array into the hashtable
    # idle on the transcript, but shell work it launched is still running: it will wake when that ends
    # children are computed even when subagent rows are hidden, so the parent can show how many
    # are live (the rollup badge); they are only emitted when s is on
    $kids = @()
    if (-not $gone) {
      $agentFiles = @(Find-Subagents $file $s.sessionId | ForEach-Object { $_ } | Where-Object { $_ -is [System.IO.FileInfo] })
      foreach ($sf in $agentFiles) {
        $sid  = 'sub:' + $sf.FullName
        $sact = Get-LastAction $sf $sid
        $meta = Get-SubagentMeta $sf
        # the transcript's verdict, overruled to stopped when Claude Code has marked the agent finished
        # (a kill, or an ending ctop can't read, would otherwise leave it "working"/"thinking")
        $sst0 = if (Test-Finished $sf $meta) { 'idle' } else { $sact.State }
        $spawner = Get-Spawner $sf $meta $agentFiles
        # orphaned: this agent stopped AFTER its spawner had already stopped, so its result had no
        # reader (typical of a background child whose parent didn't wait). Only meaningful for
        # nested agents; a depth-1 agent's spawner is the session, which never "stops" this way.
        $orphaned = $false
        if ($spawner -and $sst0 -eq 'idle') {
          $spFile = Get-Item -LiteralPath $spawner.Substring(4) -ErrorAction SilentlyContinue
          if ($spFile) {
            $spAct = Get-LastAction $spFile $spawner
            $orphaned = ($spAct.State -eq 'idle' -and $spFile.LastWriteTimeUtc -lt $sf.LastWriteTimeUtc)
          }
        }
        $shortId = ($sf.BaseName -replace '^agent-', ''); $shortId = $shortId.Substring(0, [math]::Min(8, $shortId.Length))
        $depth = if ($meta.spawnDepth) { [int]$meta.spawnDepth } else { 1 }
        $kids += [pscustomobject]@{
          NAME     = ('  ' * $depth) + '└ ' + $(if ($meta.agentType) { "$($meta.agentType) ($shortId)" } else { $shortId })
          TITLE    = if ($meta.description) { [string]$meta.description } else { '' }
          KIND     = $(if ($meta.requestShape -eq 'background') { 'subagent·bg' } else { 'subagent' })
          STATE    = $(if ($orphaned) { 'orphaned' } elseif ($sst0 -eq 'idle' -and $sact.SysError) { 'error' } elseif ($sst0 -eq 'idle') { 'stopped' } else { $sst0 })   # idle = stopped (resumable); orphaned = finished after its spawner had
          PID      = '-'
          'CPU(s)' = '-'
          'MEM(MB)'= '-'
          AGE      = Get-Since $sf.CreationTime
          IDLE     = Get-Since $sf.LastWriteTime
          TURN     = if ($sact.TurnStart -and $sst0 -in 'working','thinking') { Get-Since $sact.TurnStart } else { '' }
          TURNS    = '-'
          TOOLS    = $sact.Tools
          CTX      = if ($sact.Ctx -ne '-') { "$($sact.Ctx)K" } else { '-' }
          CMP      = if ($sact.Compacts) { [string]$sact.Compacts } else { '' }
          MODEL    = $(if ($sact.Model -and $sact.Model -ne '-') { $sact.Model } elseif ($meta.model) { [string]$meta.model } else { '-' })   # meta holds the requested model when no reply ever came
          BRANCH   = ''
          COST     = if ($sact.Cost -gt 0) { '${0:N2}' -f $sact.Cost } else { '-' }
          RATE     = ''
          ACTIVITY = ''   # sampled after jobs are attributed, so the bar matches the final STATE
          _Done    = ($sst0 -eq 'idle')
          _Jobs    = @()
          _SessPid = $s.pid
          'LAST ACTION' = $sact.Last
          CWD      = '-'
          _SessionId  = $sid
          _Parent     = $s.sessionId
          _Spawner    = $spawner          # 'sub:<file>' of the agent that launched it, or $null = the session did
          _Shape      = [string]$meta.requestShape
          _Orphaned   = $orphaned
          _Depth      = $depth
          _Order      = 0
          _Gone       = $null
          _Act        = $sact
          _Desc       = if ($meta.description) { [string]$meta.description } else { '' }
          _Transcript = $sf.FullName
          _StartedAt  = $sf.CreationTime
        }
      }
    }
    # Give each job to the agent that launched it: the Bash / PowerShell call (in the session's own
    # transcript or a subagent's) closest in time to the job's start, within 15 s. Subagents run inside
    # the session's process, so the process tree alone can't say whose job it is.
    $mine = @()
    foreach ($jb in $jobs) {
      $tool = switch ($jb.Kind) { 'bash' { 'Bash' } 'ps' { 'PowerShell' } default { $null } }
      $owner = $null; $bestGap = 15.0
      if ($tool -and $jb.Since) {
        $cands = @(@{ Row = $null; Log = $act.ToolLog }) + @($kids | ForEach-Object { @{ Row = $_; Log = $_._Act.ToolLog } })
        foreach ($cd in $cands) {
          foreach ($t in @($cd.Log)) {
            if (-not $t -or $t.Tool -ne $tool) { continue }
            # compare in UTC: a call time read live is a "…Z" string ([datetime] makes it Local), but one
            # restored from the scan cache comes back as a Utc DateTime (ConvertFrom-Json parses ISO
            # dates), and .NET subtracts DateTimes without looking at Kind — a 7 h "gap" in UTC-7
            try { $gap = [math]::Abs((([datetime]$t.At).ToUniversalTime() - ([datetime]$jb.Since).ToUniversalTime()).TotalSeconds) } catch { continue }
            if ($gap -lt $bestGap) { $bestGap = $gap; $owner = $cd.Row }
          }
        }
      }
      if ($owner) { $owner._Jobs = @(@($owner._Jobs) + @($jb)) } else { $mine += $jb }
    }
    $kidJobs = $jobs.Count - $mine.Count
    $jobs = $mine
    foreach ($k in $kids) {
      # a stopped agent that still owns running work isn't done: like a session, it reads awaiting
      $kj = @($k._Jobs | Where-Object { $_ }).Count
      if ($kj -and $k.STATE -in 'stopped', 'error') { $k.STATE = if ($kj -eq 1) { 'awaiting job' } else { "awaiting $kj jobs" }; $k._Done = $false }
      if (Test-Polling $k.STATE $k._Act @($k._Jobs)) { $k.STATE = 'polling' }
      if (Test-AwaitingAgent $k.STATE $k._Act $kids $k._SessionId) { $k.STATE = 'awaiting agent' }
      $sst = if ($k.STATE -like 'awaiting*' -or $k.STATE -eq 'polling') { 'awaiting' } elseif ($k._Done) { 'idle' } else { $k._Act.State }
      if ($sample) { Add-Sample $k._SessionId $sst $k._Act.Compacts }
      $k.ACTIVITY = $script:History[$k._SessionId]
    }
    if ($state -eq 'idle' -and $jobs.Count) { $state = if ($jobs.Count -eq 1) { 'awaiting job' } else { "awaiting $($jobs.Count) jobs" } }
    # a foreground poll is still the model's current turn (TURN keeps counting); a background poll left
    # running after the turn ended is not, so TURN stays blank for it, as for awaiting job
    $pollInTurn = $false
    if (Test-Polling $state $act $jobs) { $pollInTurn = ($state -eq 'working'); $state = 'polling' }
    if (Test-AwaitingAgent $state $act $kids '') { $state = 'awaiting agent' }
    $active = $state -in 'working','thinking','awaiting agent' -or $pollInTurn -or $state -like 'waiting*'   # awaiting agent: still its turn
    $prow = [pscustomobject]@{
      NAME     = if ($s.name) { $s.name } elseif ($s.id) { $s.id } else { '-' }
      TITLE    = $($t = Get-SessionTitle $s.sessionId $file; if ($t) { $t } elseif ($file) { '(untitled)' } else { '' })
      KIND     = $s.kind
      STATE    = $state
      PID      = if ($s.pid) { $s.pid } else { '-' }
      'CPU(s)' = if ($proc) { [math]::Round($proc.CPU, 1) } else { '-' }
      'MEM(MB)'= if ($proc) { [math]::Round($proc.WorkingSet64 / 1MB) } else { '-' }
      AGE      = if ($s.startedAt) { Get-Age $s.startedAt } else { '-' }
      IDLE     = if ($file) { Get-Since $file.LastWriteTime } else { '-' }
      TURN     = if ($act.TurnStart -and $active) { Get-Since $act.TurnStart } else { '' }
      TURNS    = $act.Turns
      TOOLS    = $act.Tools
      CTX      = if ($act.Ctx -ne '-') { "$($act.Ctx)K" } else { '-' }
      CMP      = if ($act.Compacts) { [string]$act.Compacts } else { '' }
      MODEL    = $act.Model
      BRANCH   = $($b = if ($act.GitBranch) { $act.GitBranch } else { $git.Branch }; if ($git.Worktree) { 'wt:' + $b } else { $b })
      COST     = if ($act.Cost -gt 0) { '${0:N2}' -f $act.Cost } else { '-' }
      RATE     = if ($act.Cost -gt 0 -and $s.startedAt) { $h = ((Get-Date) - [DateTimeOffset]::FromUnixTimeMilliseconds($s.startedAt).LocalDateTime).TotalHours; if ($h -gt 0.05) { '${0:N2}' -f ($act.Cost / $h) } else { '-' } } else { '-' }
      ACTIVITY = $(if ($sample) { Add-Sample $s.sessionId $state $act.Compacts }; $script:History[$s.sessionId])
      'LAST ACTION' = $act.Last
      CWD      = $cwd
      # hidden (not in $script:Columns), used by sorting and the peek view
      _SessionId  = $s.sessionId
      _Parent     = $null
      _Git        = $git
      _Jobs       = $jobs
      _KidJobs    = $kidJobs
      _Helpers    = $(if ($jm) { $jm.Helpers } else { 0 })
      _Hooks      = @(if ($jm) { $jm.Hooks })
      _LaunchCwd  = Normalize-Path ([string]$s.cwd)
      _Order      = $s._order
      _Gone       = $gone
      _Cleared    = $cleared
      _Successor  = $e.Successor
      _LaunchedBy = $(if ($s.pid -and -not $gone) { $script:LaunchedBy[[int]$s.pid] } else { $null })   # @{ SessPid; JobPid; Label } or $null
      # the session's own cost plus every agent it ever ran, listed or aged out (each file's scan is
      # cached and incremental, so an unchanged agent costs one length check)
      _AgentCost  = $(if ($gone) { 0.0 } else { $sum = 0.0; foreach ($af in @($script:AllAgents[$s.sessionId])) { if ($af) { $sum += [double](Update-Scan $af ('sub:' + $af.FullName)).Cost } }; $sum })
      _AgentN     = $(if ($gone) { 0 } else { @($script:AllAgents[$s.sessionId] | Where-Object { $_ }).Count })
      _Act        = $act
      _Transcript = if ($file) { $file.FullName } else { '-' }
      _StartedAt  = if ($s.startedAt) { [DateTimeOffset]::FromUnixTimeMilliseconds($s.startedAt).LocalDateTime } else { $null }
    }
    $live = @($kids | Where-Object { $_.STATE -in 'working','thinking' -or $_.STATE -like 'awaiting*' }).Count
    # the +N badge stands in for hidden subagent rows; when the rows are shown they speak for themselves
    $prow | Add-Member -NotePropertyName _LiveKids -NotePropertyValue $(if ($script:ShowSubagents) { 0 } else { $live }) -Force
    $prow
    if ($script:ShowSubagents) { $kids }
  }
}

# Sort parents, keep each parent's subagent rows directly beneath it.
# Deterministic: every mode ends with startedAt (numeric) then sessionId as tiebreaks, so a
# row never moves without a real change. 'activity' ranks working and thinking together, so
# a session cycling through tool calls doesn't hop; only active<->idle transitions move it.
$script:SortModes = @('activity', 'roster', 'start', 'cost', 'ctx')
$script:SortMode  = [array]::IndexOf($script:SortModes, $Sort)
function Sort-Rows([object[]]$rows) {
  $mode = $script:SortModes[$script:SortMode]
  $key = switch ($mode) {
    'activity' { { param($r) if ($r._Gone) { 3 } elseif ($r.STATE -like 'waiting*') { 0 } elseif ($r.STATE -in 'working','thinking' -or $r.STATE -like 'awaiting*' -or $r.STATE -eq 'polling') { 1 } elseif ($r.STATE -eq 'idle') { 2 } else { 2 } } }
    'roster'   { { param($r) [int]$r._Order } }   # exactly as claude agents --json lists them
    'start'    { { param($r) 0 } }
    'cost'     { { param($r) -[double]$r._Act.Cost } }
    'ctx'      { { param($r) if ($r._Act.Ctx -ne '-') { -[double]$r._Act.Ctx } else { 0 } } }
  }
  # Sessions launched by another listed session's job (a script running claude -p, say) are drawn
  # under that session, after its own subagents. They stay sessions: own row, own subagents.
  $sessByPid = @{}
  foreach ($r in $rows) { if (-not $r._Parent -and -not $r._Gone -and "$($r.PID)" -match '^\d+$') { $sessByPid[[int]$r.PID] = $r } }
  $launchKids = @{}; $isLaunched = @{}
  foreach ($r in $rows) {
    if ($r._Parent -or -not $r._LaunchedBy) { continue }
    $l = $sessByPid[[int]$r._LaunchedBy.SessPid]
    if (-not $l -or $l._SessionId -eq $r._SessionId) { continue }
    if (-not $launchKids.ContainsKey($l._SessionId)) { $launchKids[$l._SessionId] = @() }
    $launchKids[$l._SessionId] += $r; $isLaunched[$r._SessionId] = $true
    $r | Add-Member -NotePropertyName _Launcher -NotePropertyValue ([string]$l.NAME).Trim() -Force
  }
  foreach ($id in @($launchKids.Keys)) {
    $lr = $rows | Where-Object { $_._SessionId -eq $id -and -not $_._Parent } | Select-Object -First 1
    if ($lr) { $lr | Add-Member -NotePropertyName _LaunchedNames -NotePropertyValue (@($launchKids[$id] | ForEach-Object { ([string]$_.NAME).Trim() }) -join ', ') -Force }
  }
  $parents = @($rows | Where-Object { -not $_._Parent -and -not $isLaunched.ContainsKey($_._SessionId) } |
    Sort-Object @{ e = { if ($mode -ne 'activity' -and $_._Gone) { 1 } else { 0 } } },
                @{ e = { & $key $_ } },
                @{ e = { if ($_._StartedAt) { $_._StartedAt.Ticks } else { [long]::MaxValue } } },
                @{ e = { $_._SessionId } })
  # Σ: own + agents + (recursively) sessions it launched
  $sumSeen = @{}
  function Sum-Tree($p) {
    if ($sumSeen.ContainsKey($p._SessionId)) { return 0.0 }; $sumSeen[$p._SessionId] = $true
    $own = [double]$p._Act.Cost + [double]$p._AgentCost; $l = 0.0; $ln = 0
    foreach ($lk in @($launchKids[$p._SessionId])) { if ($lk) { $l += Sum-Tree $lk; $ln++ } }
    $p | Add-Member -NotePropertyName _TreeCost -NotePropertyValue ($own + $l) -Force
    $p | Add-Member -NotePropertyName _LaunchCost -NotePropertyValue $l -Force
    $p | Add-Member -NotePropertyName _LaunchN -NotePropertyValue $ln -Force
    return $own + $l
  }
  foreach ($p in $parents) { [void](Sum-Tree $p) }
  $out = [System.Collections.Generic.List[object]]::new(); $done = @{}
  # one session, its subagent tree, then the sessions it launched; $base = how deep the session sits
  function Emit-Group($p, [int]$base, [string]$rootId) {
    if ($done.ContainsKey($p._SessionId)) { return }; $done[$p._SessionId] = $true
    $p | Add-Member -NotePropertyName _Group -NotePropertyValue $rootId -Force
    if ($base -gt 0) {
      $p.NAME = ('  ' * $base) + '└ ' + ([string]$p.NAME).Trim()
      $p | Add-Member -NotePropertyName _Depth -NotePropertyValue $base -Force
    }
    $out.Add($p)
    $kids = @($rows | Where-Object { $_._Parent -eq $p._SessionId })
    $place = {   # a subagent row, shifted under a launched session
      param($k)
      $k | Add-Member -NotePropertyName _Group -NotePropertyValue $rootId -Force
      if ($base -gt 0) { $k.NAME = ('  ' * $base) + [string]$k.NAME; $k._Depth = [int]$k._Depth + $base }
      $out.Add($k)
    }
    # depth-first: agents spawned by the session, each followed by the agents it spawned, and so on
    $bySpawner = @{}
    foreach ($k in $kids) { $sk = [string]$k._Spawner; if (-not $bySpawner.ContainsKey($sk)) { $bySpawner[$sk] = @() }; $bySpawner[$sk] += $k }
    $stack = New-Object System.Collections.Generic.Stack[object]
    $roots = @($bySpawner[''] | Sort-Object @{ e = { $_._StartedAt.Ticks } }, @{ e = { $_._SessionId } })
    for ($i = $roots.Count - 1; $i -ge 0; $i--) { $stack.Push($roots[$i]) }
    $seen = @{}
    while ($stack.Count -gt 0) {
      $k = $stack.Pop()
      & $place $k; $seen[$k._SessionId] = $true
      $children = @($bySpawner[[string]$k._SessionId] | Sort-Object @{ e = { $_._StartedAt.Ticks } }, @{ e = { $_._SessionId } })
      for ($i = $children.Count - 1; $i -ge 0; $i--) { $stack.Push($children[$i]) }
    }
    # anything whose spawner couldn't be resolved still gets listed
    foreach ($k in @($kids | Where-Object { -not $seen.ContainsKey($_._SessionId) } | Sort-Object @{ e = { $_._StartedAt.Ticks } })) { & $place $k }
    foreach ($lk in @($launchKids[$p._SessionId] | Sort-Object @{ e = { if ($_._StartedAt) { $_._StartedAt.Ticks } else { [long]::MaxValue } } }, @{ e = { $_._SessionId } })) {
      Emit-Group $lk ($base + 1) $rootId
    }
  }
  foreach ($p in $parents) { Emit-Group $p 0 $p._SessionId }
  return $out.ToArray()   # unrolled: the caller wraps it in @()
}

# ---- color -----------------------------------------------------------------------
# ANSI SGR, honored by Windows Terminal / VS Code terminal / PowerShell 7. -NoColor disables.
$script:Color = -not $NoColor
$script:Palette = @{ green = "$([char]27)[32m"; yellow = "$([char]27)[33m"; red = "$([char]27)[31m"
               magenta = "$([char]27)[35m"; cyan = "$([char]27)[36m"; dim = "$([char]27)[90m"; off = "$([char]27)[0m" }
function Paint([string]$text, [string]$color) {
  if (-not $script:Color -or -not $color -or -not $text.Trim()) { return $text }
  $script:Palette[$color] + $text + $script:Palette.off
}
# Decide a cell's color from the row. Returns '' for default.
function Cell-Color([string]$col, $r) {
  switch ($col) {
    'STATE'    { if ($r._Gone) { 'dim' }
                 elseif ($r.STATE -eq 'working') {
                   # nothing written for 2 min: if a job process is running, the command is executing (a long
                   # foreground run writes nothing until it ends); if not, the call is likely waiting on you
                   if ((Minutes $r.IDLE) -ge 2 -and -not @($r._Jobs | Where-Object { $_ }).Count) { 'red' } else { 'green' } }
                 elseif ($r.STATE -eq 'thinking') { 'yellow' } elseif ($r.STATE -in 'idle','stopped') { 'dim' }
                 elseif ($r.STATE -eq 'orphaned') { 'yellow' }
                 elseif ($r.STATE -like 'awaiting*' -or $r.STATE -eq 'polling') { 'cyan' }
                 elseif ($r.STATE -like 'waiting*' -or $r.STATE -eq 'error') { 'red' } else { '' } }
    'TURN'     { $m = Minutes $r.TURN; if ($m -ge 30) { 'red' } elseif ($m -ge 10) { 'yellow' } else { '' } }
    'IDLE'     { if ($r.STATE -eq 'idle' -and (Minutes $r.IDLE) -ge 30) { 'dim' } else { '' } }
    'MODEL'    { if ($r.MODEL -match $HighlightModel) { 'magenta' } else { '' } }
    'ACTIVITY' { 'spark' }
    'CMP'      { if (-not $r.CMP) { '' } elseif ($r._Act.LastCompactAt -and ((Get-Date) - $r._Act.LastCompactAt).TotalMinutes -lt 10) { 'magenta' } else { 'yellow' } }
    'TITLE'    { if ($r.TITLE -eq '(untitled)') { 'dim' } else { '' } }
    'BRANCH'   { if ($r.BRANCH -like 'wt:*') { 'cyan' } else { '' } }
    'KIND'     { if ($r.KIND -like 'subagent*') { 'cyan' } else { '' } }
    'CWD'      { if ($r._LaunchCwd -and -not [string]::Equals($r._LaunchCwd, $r.CWD, [StringComparison]::OrdinalIgnoreCase)) { 'cyan' } else { '' } }
    'COST'     { if ([double]($r._Act.Cost) -ge 100) { 'yellow' } else { '' } }
    default    { '' }
  }
}
# "45s" / "12m" / "6h38m" -> minutes
function Minutes([string]$t) {
  if (-not $t) { return 0 }
  $m = 0.0
  if ($t -match '(\d+)h') { $m += 60 * [int]$Matches[1] }
  if ($t -match '(\d+)m') { $m += [int]$Matches[1] }
  if ($t -match '^(\d+)s$') { $m += [int]$Matches[1] / 60 }
  return $m
}
function Paint-Spark([string]$sp) {
  if (-not $script:Color) { return $sp }
  (($sp -replace '(█+)', ($script:Palette.green + '$1' + $script:Palette.off)) -replace '(▒+)', ($script:Palette.yellow + '$1' + $script:Palette.off) -replace '(·+)', ($script:Palette.dim + '$1' + $script:Palette.off)) -replace '(▼)', ($script:Palette.magenta + '$1' + $script:Palette.off) -replace '(▁+)', ($script:Palette.red + '$1' + $script:Palette.off) -replace '(░+)', ($script:Palette.cyan + '$1' + $script:Palette.off)
}

# ---- table renderer with sticky widths -----------------------------------------
# Format-Table -AutoSize re-measures every frame, so columns jitter as values change.
# Instead: bounded columns get a fixed width sized to their longest possible value;
# unbounded ones (NAME, LAST ACTION, CWD) use a high-water mark that only ever grows.
# Priority: lower numbers are hidden first when the window is too narrow. Flex columns
# share the leftover width in proportion to Flex, never below Min.
$script:Columns = @(
  @{ Name = 'NAME';        Fixed = 0;  Min = 12; Flex = 2; Align = 'L'; Priority = 100 }
  @{ Name = 'TITLE';       Fixed = 0;  Min = 12; Flex = 3; Align = 'L'; Priority = 95 }   # picker's friendly name
  @{ Name = 'STATE';       Fixed = 8;  Auto = $true; Align = 'L'; Priority = 100 }
  @{ Name = 'TURN';        Fixed = 5;  Align = 'R'; Priority = 90 }   # time on current turn
  @{ Name = 'IDLE';        Fixed = 5;  Align = 'R'; Priority = 85 }
  @{ Name = 'CTX';         Fixed = 5;  Align = 'R'; Priority = 80 }   # "123K"
  @{ Name = 'CMP';         Fixed = 3;  Align = 'R'; Priority = 79 }   # compactions so far
  @{ Name = 'LAST ACTION'; Fixed = 0;  Min = 16; Flex = 4; Align = 'L'; Priority = 75 }
  @{ Name = 'ACTIVITY';    Fixed = 20; Align = 'L'; Priority = 70 }   # sparkline, 1 col = 2 s
  @{ Name = 'BRANCH';      Fixed = 6;  Auto = $true; Align = 'L'; Priority = 60 }
  @{ Name = 'AGE';         Fixed = 7;  Align = 'R'; Priority = 55 }
  @{ Name = 'CWD';         Fixed = 0;  Min = 14; Flex = 3; Align = 'L'; Priority = 50 }
  @{ Name = 'PID';         Fixed = 6;  Align = 'R'; Priority = 38 }
  @{ Name = 'TURNS';       Fixed = 5;  Align = 'R'; Priority = 35 }
  @{ Name = 'TOOLS';       Fixed = 5;  Align = 'R'; Priority = 30 }
  @{ Name = 'MODEL';       Fixed = 5;  Auto = $true; Align = 'L'; Priority = 78 }   # visible by default: catches an unintended model
  @{ Name = 'KIND';        Fixed = 4;  Auto = $true; Align = 'L'; Priority = 20 }
  @{ Name = 'CPU(s)';      Fixed = 7;  Align = 'R'; Priority = 15 }
  @{ Name = 'MEM(MB)';     Fixed = 7;  Align = 'R'; Priority = 10 }
  @{ Name = 'COST';        Fixed = 7;  Align = 'R'; Priority = 65 }   # "$12.34"
  @{ Name = 'RATE';        Fixed = 7;  Align = 'R'; Priority = 45 }   # "$/h"
)
foreach ($c in $script:Columns) { if ($c.Auto) { $c.Floor = $c.Fixed } }
if ($All) { ($script:Columns | Where-Object Name -eq 'STATE').Floor = 12 }   # "waiting: permission prompt"
$script:HighWater = @{}
$script:HiddenCols = @()

# Collapse newlines, tabs and other control characters: a cell must never break the grid.
function Clean([string]$text) {
  if ($null -eq $text) { return '' }
  # collapse runs of whitespace inside the text, but keep leading indentation (subagent depth)
  ($text -replace '[\x00-\x1F\x7F]+', ' ') -replace '(?<=\S)\s{2,}', ' '
}

function Fit([string]$text, [int]$width, [string]$align) {
  $text = Clean $text
  if ($text.Length -gt $width) { $text = $text.Substring(0, [math]::Max(0, $width - 1)) + '…' }
  if ($align -eq 'R') { $text.PadLeft($width) } else { $text.PadRight($width) }
}

# Shorten a path to fit: ~ for home, then keep the tail (the part that identifies a worktree).
function Fit-Path([string]$path, [int]$width) {
  if (-not $path) { return ''.PadRight($width) }
  $p = Clean $path
  if ($HOME -and $p.StartsWith($HOME, [StringComparison]::OrdinalIgnoreCase)) { $p = '~' + $p.Substring($HOME.Length) }
  if ($p.Length -gt $width) { $p = '…' + $p.Substring($p.Length - ($width - 1)) }
  $p.PadRight($width)
}

# Allocate widths for a set of columns inside $avail. Returns the visible columns (declared
# order) with .Width set, and records anything it had to hide.
# Auto columns (MODEL, BRANCH, KIND, STATE) size to their content: grow at once, shrink only
# after the content has been narrower for $ShrinkAfter consecutive frames (~5 s at 250 ms).
$script:AutoWidth = @{}
$script:ShrinkAfter = 20
function Auto-Width([string]$name, [int]$floor, [object[]]$rows) {
  $need = $floor
  foreach ($r in $rows) {
    $l = ([string]$r.$name).Length
    if ($name -eq 'STATE' -and $r._LiveKids -gt 0) { $l += (" +$($r._LiveKids)").Length }   # rollup badge
    if ($l -gt $need) { $need = $l }
  }
  $need = [math]::Max($need, $name.Length)
  $st = $script:AutoWidth[$name]
  if (-not $st) { $st = @{ Width = $need; Below = 0 }; $script:AutoWidth[$name] = $st }
  if ($need -ge $st.Width) { $st.Width = $need; $st.Below = 0 }
  else { $st.Below++; if ($st.Below -ge $script:ShrinkAfter) { $st.Width = $need; $st.Below = 0 } }
  return $st.Width
}

function Layout-Columns([object[]]$candidates, [object[]]$rows, [int]$avail, [string]$sep) {
  foreach ($c in $candidates) {
    if ($c.Auto) { $c.Fixed = Auto-Width $c.Name $c.Floor $rows; $c.Natural = $c.Fixed; continue }
    if ($c.Fixed -gt 0) { $c.Natural = $c.Fixed; continue }
    $seen = $c.Min
    foreach ($r in $rows) { $l = ([string]$r.($c.Name)).Length; if ($l -gt $seen) { $seen = $l } }
    $hw = $script:HighWater[$c.Name]
    if (-not $hw -or $seen -gt $hw) { $script:HighWater[$c.Name] = $seen; $hw = $seen }
    $wrap = $script:Layouts[$script:LayoutMode] -eq 'wrap'
    # caps are generous: the allocator only reaches them when the window has room
    $cap = switch ($c.Name) {
      'NAME'  { 24 }
      'TITLE' { 80 }
      'CWD'   { 60 }
      default { if ($script:Compact) { 40 } else { 120 } }
    }
    $c.Natural = [math]::Min($hw, $cap)
  }
  $cols = @($candidates | Sort-Object { -$_.Priority })
  $needNat = { param($cs) ($cs | ForEach-Object Natural | Measure-Object -Sum).Sum + $sep.Length * ($cs.Count - 1) }
  $needMin = { param($cs) ($cs | ForEach-Object { if ($_.Fixed -gt 0) { $_.Fixed } else { $_.Min } } | Measure-Object -Sum).Sum + $sep.Length * ($cs.Count - 1) }
  while ($cols.Count -gt 2 -and (& $needNat $cols) -gt $avail -and $cols[-1].Priority -lt 50) { $cols = @($cols[0..($cols.Count - 2)]) }
  while ($cols.Count -gt 2 -and (& $needMin $cols) -gt $avail) { $cols = @($cols[0..($cols.Count - 2)]) }
  $script:HiddenCols += @($candidates | Where-Object { $_.Name -notin $cols.Name } | ForEach-Object Name)
  $fixedSum = ($cols | Where-Object { $_.Fixed -gt 0 } | ForEach-Object Fixed | Measure-Object -Sum).Sum
  $left = $avail - $fixedSum - $sep.Length * ($cols.Count - 1)
  $flex = @($cols | Where-Object { $_.Fixed -eq 0 })
  $flexSum = ($flex | ForEach-Object Flex | Measure-Object -Sum).Sum
  foreach ($c in $flex) { $c.Width = [math]::Max($c.Min, [math]::Min($c.Natural, [math]::Floor($left * $c.Flex / [math]::Max(1, $flexSum)))) }
  # raising a column to its minimum can push the total past the budget: take the excess back from
  # whichever flex column has the most room above its minimum, one column-character at a time
  $over = ($flex | ForEach-Object Width | Measure-Object -Sum).Sum - $left
  while ($over -gt 0) {
    $c = $flex | Where-Object { $_.Width -gt $_.Min } | Sort-Object { $_.Width - $_.Min } -Descending | Select-Object -First 1
    if (-not $c) { break }
    $c.Width--; $over--
  }
  $used = ($flex | ForEach-Object Width | Measure-Object -Sum).Sum
  foreach ($n in 'NAME','TITLE','LAST ACTION','CWD') {
    $c = $flex | Where-Object Name -eq $n
    if ($c -and $left - $used -gt 0 -and $c.Width -lt $c.Natural) { $add = [math]::Min($left - $used, $c.Natural - $c.Width); $c.Width += $add; $used += $add }
  }
  # any remaining width: widen TITLE / LAST ACTION / CWD toward their full content, in proportion
  $growers = @($flex | Where-Object { $_.Name -in 'TITLE','LAST ACTION','CWD' -and $_.Width -lt $_.Natural })
  while ($growers.Count -gt 0 -and $left - $used -gt 0) {
    $share = [math]::Max(1, [math]::Floor(($left - $used) / $growers.Count))
    foreach ($c in $growers) { $add = [math]::Min($share, [math]::Min($left - $used, $c.Natural - $c.Width)); $c.Width += $add; $used += $add }
    $growers = @($growers | Where-Object { $_.Width -lt $_.Natural })
    if ($share -eq 1 -and $left - $used -lt $growers.Count) { break }
  }
  foreach ($c in $cols | Where-Object { $_.Fixed -gt 0 }) { $c.Width = $c.Fixed }
  return @($candidates | Where-Object { $_.Name -in $cols.Name })
}

# Split a cell into up to $maxLines pieces of $width. Word-wrap on spaces where possible;
# paths wrap from the tail (the identifying part) with the head cut. Last piece gets … if
# anything was left over.
function Wrap-Cell([string]$text, [int]$width, [int]$maxLines, [bool]$isPath) {
  $text = Clean $text
  if ($isPath -and $HOME -and $text.StartsWith($HOME, [StringComparison]::OrdinalIgnoreCase)) { $text = '~' + $text.Substring($HOME.Length) }
  if ($text.Length -le $width) { return ,@($text) }
  if ($maxLines -le 1) { return ,@($text.Substring(0, $width - 1) + '…') }
  if ($isPath) {
    $room = $width * $maxLines
    if ($text.Length -gt $room) { $text = '…' + $text.Substring($text.Length - ($room - 1)) }
    $parts = @(); for ($i = 0; $i -lt $text.Length; $i += $width) { $parts += $text.Substring($i, [math]::Min($width, $text.Length - $i)) }
    return ,$parts
  }
  $parts = @(); $rest = $text
  while ($rest.Length -gt $width -and $parts.Count -lt $maxLines - 1) {
    $cut = $rest.LastIndexOf(' ', $width)
    if ($cut -lt [math]::Floor($width * 0.5)) { $cut = $width }
    $parts += $rest.Substring(0, $cut).TrimEnd()
    $rest = $rest.Substring($cut).TrimStart()
  }
  if ($rest.Length -gt $width) { $rest = $rest.Substring(0, $width - 1) + '…' }
  $parts += $rest
  return ,$parts
}

function Format-Row([object[]]$cols, $r, [string]$sep, [int]$maxLines) {
  $cells = @{}; $height = 1
  foreach ($c in $cols) {
    $v = [string]$r.($c.Name)
    if ($c.Name -eq 'NAME' -and $v -match '^(\s*)[└├] (.*)$') {
      # a child: wrap the name inside its indent, and carry the tree rail down continuation lines
      $lead = $Matches[1]; $rest = $Matches[2]
      $glyph = if ($r._TreeLast) { '└ ' } else { '├ ' }
      $cont  = if ($r._TreeLast) { '  ' } else { '│ ' }
      $inner = [math]::Max(4, $c.Width - $lead.Length - 2)
      $wrapped = Wrap-Cell $rest $inner $maxLines $false   # already an array (Wrap-Cell returns ,$parts)
      $pieces = @(for ($k = 0; $k -lt $wrapped.Count; $k++) { $lead + $(if ($k -eq 0) { $glyph } else { $cont }) + $wrapped[$k] })
    }
    elseif ($c.Name -eq 'COST' -and $maxLines -gt 1 -and -not $r._Parent -and [double]$r._TreeCost -ge [double]$r._Act.Cost + 0.005) {
      $t = [double]$r._TreeCost
      $sig = if ($t -ge 1000) { 'Σ${0:N0}k' -f ($t / 1000) } elseif ($t -ge 100) { 'Σ${0:N0}' -f $t } else { 'Σ${0:N2}' -f $t }
      $pieces = @(((Fit $v $c.Width $c.Align)).TrimEnd(), ((Fit $sig $c.Width $c.Align)).TrimEnd())
    }
    elseif ($c.Name -eq 'STATE' -and $r._LiveKids -gt 0) {
      $pieces = ,@(((Fit "$v +$($r._LiveKids)" $c.Width $c.Align)).TrimEnd())
    }
    else {
      $pieces = if ($c.Fixed -eq 0) { Wrap-Cell $v $c.Width $maxLines ($c.Name -eq 'CWD') } else { ,@((Fit $v $c.Width $c.Align).TrimEnd()) }
    }
    $cells[$c.Name] = $pieces
    if ($pieces.Count -gt $height) { $height = $pieces.Count }
  }
  $lines = @()
  for ($i = 0; $i -lt $height; $i++) {
    $lines += ($cols | ForEach-Object {
      $piece = if ($i -lt $cells[$_.Name].Count) { $cells[$_.Name][$i] } else { '' }
      $padded = if ($_.Align -eq 'R') { $piece.PadLeft($_.Width) } else { $piece.PadRight($_.Width) }
      $color = Cell-Color $_.Name $r
      if ($_.Name -eq 'STATE' -and $r._LiveKids -gt 0 -and $i -eq 0) {
        # rollup badge: the session's own state in its usual color, then +N live subagents in green
        $own = [string]$r.STATE; $badge = " +$($r._LiveKids)"
        if ($own.Length + $badge.Length -le $_.Width) {
          (Paint $own $color) + (Paint $badge 'green') + (' ' * ($_.Width - $own.Length - $badge.Length))
        } else { Paint $padded $color }
      }
      elseif ($color -eq 'spark') { Paint-Spark $padded } else { Paint $padded $color }
    }) -join $sep
  }
  return ,$lines
}

# Formatting a row (wrap, pad, color every cell) is the costliest part of a frame, and most rows
# don't change between ticks (a stopped subagent's cells, even its all-dots sparkline, stay put).
# So each row's formatted lines are reused while everything they depend on is unchanged: the
# visible values, the column layout, and the hidden facts that steer colors.
$script:RowCache = @{}
function Row-Key([object[]]$cols, $r, [string]$sig) {
  $sb = [Text.StringBuilder]::new($sig)
  foreach ($c in $cols) { [void]$sb.Append([char]31).Append([string]$r.($c.Name)) }
  $jc = 0; foreach ($x in @($r._Jobs)) { if ($x) { $jc++ } }
  $cmpRecent = $false
  if ($r._Act -and $r._Act.LastCompactAt) { try { $cmpRecent = ((Get-Date) - [datetime]$r._Act.LastCompactAt).TotalMinutes -lt 10 } catch {} }
  [void]$sb.Append([char]30).Append("$([bool]$r._Gone)|$($r._LaunchCwd)|$cmpRecent|$jc|$($r._LiveKids)|$($r._TreeLast)|$($r._Depth)|$($r._Done)|$($r._Orphaned)|$($r._Parent -ne $null)|$([math]::Round([double]$r._TreeCost, 2))")
  return $sb.ToString()
}
function Get-RowLines([object[]]$cols, $r, [string]$sep, [int]$maxLines, [string]$sig) {
  $k = Row-Key $cols $r $sig
  $hit = $script:RowCache[$k]
  if ($hit) { return ,$hit }
  if ($script:RowCache.Count -gt 4000) { $script:RowCache.Clear() }   # bound memory over long runs
  $lines = Format-Row $cols $r $sep $maxLines
  $script:RowCache[$k] = $lines
  return ,$lines
}

function Style-Line([string]$text, $r, [string]$selectedId, [bool]$dim) {
  if ($selectedId -and $r._SessionId -eq $selectedId) { return @{ Text = $text; Select = $true } }
  if ($dim -or $r._Gone -or ($r._Done -and -not $r._Orphaned -and $r.STATE -ne 'error')) { return @{ Text = $text; Fg = 'DarkGray' } }
  return $text
}

$script:Layouts = @('wrap', 'truncate')
$script:LayoutMode = [array]::IndexOf($script:Layouts, $Layout)

function Render-Table([object[]]$rows, [string]$selectedId) {
  $sep = '  '
  $avail = [Console]::WindowWidth - 2
  if ($MaxWidth -gt 0) { $avail = [math]::Min($avail, $MaxWidth) }
  $script:HiddenCols = @()
  $cands = @($script:Columns)
  if ($script:Compact) { $cands = @($cands | Where-Object { $_.Priority -ge 60 }) }
  $maxLines = if ($script:Layouts[$script:LayoutMode] -eq 'wrap') { [math]::Max(1, $WrapLines) } else { 1 }
  $cols = Layout-Columns $cands $rows $avail $sep
  $out = @()
  $out += ($cols | ForEach-Object { Fit $_.Name $_.Width $_.Align }) -join $sep
  $out += ($cols | ForEach-Object { '-' * $_.Width }) -join $sep
  # tree shape: a child is the last at its level if no later sibling (same session, same depth)
  # appears before the group ends or climbs back above its depth
  for ($i = 0; $i -lt $rows.Count; $i++) {
    $r = $rows[$i]
    if (-not $r._Parent -and -not $r._Depth) { continue }   # top-level session
    $last = $true
    for ($j = $i + 1; $j -lt $rows.Count; $j++) {
      $n = $rows[$j]
      if ($n._Group -ne $r._Group) { break }
      if ([int]$n._Depth -lt [int]$r._Depth) { break }
      if ([int]$n._Depth -eq [int]$r._Depth) { $last = $false; break }
    }
    $r | Add-Member -NotePropertyName _TreeLast -NotePropertyValue $last -Force
  }
  # a faint rule between session groups, only while child rows are on screen
  $grouped = @($rows | Where-Object { $_._Parent -or $_._Depth }).Count -gt 0
  $ruleW = ($cols | ForEach-Object Width | Measure-Object -Sum).Sum + $sep.Length * ($cols.Count - 1)
  $first = $true
  $sig = ((@(foreach ($c in $cols) { "$($c.Name)=$($c.Width)" })) -join ',') + "|$maxLines|$($script:Color)"
  # for scrolling: which body lines belong to the selected row, and which row each line belongs to
  $script:SelSpan = $null; $script:LineRow = [System.Collections.Generic.List[int]]::new(); $ord = 0
  foreach ($r in $rows) {
    if ($grouped -and -not $r._Parent -and -not $r._Depth -and -not $first) { $out += @{ Text = ('╌' * $ruleW); Fg = 'DarkGray' }; $script:LineRow.Add(-1) }
    $first = $false
    $start = $out.Count
    foreach ($line in (Get-RowLines $cols $r $sep $maxLines $sig)) { $out += Style-Line $line $r $selectedId $false; $script:LineRow.Add($ord) }
    if ($selectedId -and $r._SessionId -eq $selectedId) { $script:SelSpan = @(($start - 2), ($out.Count - 3)) }   # body-relative
    $ord++
  }
  return $out
}

# ---- peek view ------------------------------------------------------------------
# Full, untruncated values for one session. Modal; any key closes.
function Peek-Block([string]$label, [string]$text, [int]$width) {
  $out = @(); $first = $true
  foreach ($piece in (Wrap-Cell $text ($width - 15) 12 $false)) {
    $out += ('  ' + $(if ($first) { $label.PadRight(13) } else { ''.PadRight(13) }) + $piece); $first = $false
  }
  return ,$out
}
function Build-Peek([object]$r) {
  $pw = [Console]::WindowWidth - 2
  $lines = @(
    @{ Text = "  ctop — $($r.NAME.Trim())   (live)"; Inverse = $true },   # keeps the └: says "subagent" at a glance
    '',
    "  NAME         $($r.NAME.Trim())",
    $(if ($r.TITLE) { Peek-Block 'TITLE' $r.TITLE $pw } else { $null }),
    $(if ($r._Gone -and $r._Cleared) { "  CLEARED      /clear $(Get-Since $r._Gone) ago — the process continues as session $($r._Successor.Substring(0,8))…; this pre-clear conversation is still resumable (below)" }
      elseif ($r._Gone) { "  GONE         left the roster $(Get-Since $r._Gone) ago (was still on disk; resume below)" } else { $null }),
    "  KIND         $($r.KIND)",
    "  STATE        $(Paint $r.STATE (Cell-Color 'STATE' $r))$(if ($r._SupStatus) { "      supervisor says: $($r._SupStatus)" })",
    $(if ($r.STATE -eq 'polling') { "  POLLING      a wait loop: idle until something external changes (a file, a log marker, another process)" } else { $null }),
    $(if (@($r._Jobs | Where-Object { $_ }).Count) { @(@($r._Jobs | Where-Object { $_ }) | ForEach-Object {   # @($null).Count is 1: filter first (subagent rows have no job list)
        $bits = @(); if ($_.Via) { $bits += "via $($_.Via)" }; if ($_.Now) { $bits += "now in $($_.Now)" }
        if ($null -ne $_.Cpu) { $bits += "cpu $([math]::Round($_.Cpu))%" }
        $bits += "pid $($_.Pid)"
        # status first, so it is never the part cut off; the command wraps below it
        Peek-Block 'JOB' "running $(Get-Since $_.Since)   ($($bits -join ', '))   $($_.Label)" $pw }) } else { $null }),
    $(if (@($r._Hooks | Where-Object { $_ }).Count) { @(@($r._Hooks | Where-Object { $_ }) | ForEach-Object { Peek-Block 'HOOK' "running $(Get-Since $_.Since)   (pid $($_.Pid); a hook, not work the session is waiting on)   $($_.Label)" $pw }) } else { $null }),
    $(if ($r._KidJobs) { "  SUBAGENT JOBS $($r._KidJobs) more running under its subagents (peek them to see)" } else { $null }),
    $(if ($r._Helpers) { "  HELPERS      $($r._Helpers) long-lived child process(es) not counted as jobs (MCP / language servers / console hosts)" } else { $null }),
    $(if ($r._Act.Synthetic) { "  SYSTEM MSG   the newest message was written by Claude Code itself (model <synthetic>, no API call," } else { $null }),
    $(if ($r._Act.Synthetic) { "               no tokens): typically a usage limit or an API error. Its text is under LAST ACTION." } else { $null }),
    $(if ($r._Parent) { "  PID          runs inside its session's claude process (pid $($r._SessPid))" } else { "  PID          $($r.PID)      CPU $($r.'CPU(s)')s      MEM $($r.'MEM(MB)') MB" }),
    "  STARTED      $(if ($r._StartedAt) { $r._StartedAt.ToString('yyyy-MM-dd HH:mm:ss') } else { '-' })   (age $($r.AGE))",
    "  IDLE         $($r.IDLE)      TURN $(Paint $(if ($r.TURN) { $r.TURN } else { '-' }) (Cell-Color 'TURN' $r))      TURNS $($r.TURNS)",
    $(Peek-Block 'TOOLS' "$($r.TOOLS) calls$(if ($r._Act.ToolMix) { ':  ' + $r._Act.ToolMix })" $pw),
    "  CTX          $($r.CTX) tokens in context      MODEL $(Paint $r.MODEL (Cell-Color 'MODEL' $r))      BRANCH $($r.BRANCH)",
    "  COMPACTIONS  $(if ($r._Act.Compacts) { "$($r._Act.Compacts)   last $(Get-Since $r._Act.LastCompactAt) ago ($($r._Act.LastCompactTrigger), $([math]::Round($r._Act.LastCompactPreTokens / 1000))K tokens before it) — context now holds a summary, not the full history" } else { 'none' })",
    "  COST         $($r.COST) at list price$(if ($r.RATE -and $r.RATE -ne '-') { "   ($($r.RATE)/h)" })     tokens: in $($r._Act.InTok)  out $($r._Act.OutTok)  cache read $($r._Act.CacheR)  cache write $($r._Act.CacheW)",
    "  ACTIVITY     $(Paint-Spark $r.ACTIVITY)   ($(Paint-Spark '█') working  $(Paint-Spark '▒') thinking  $(Paint-Spark '·') idle  $(Paint-Spark '▁') waiting on you  $(Paint-Spark '▼') compaction, 1 char = 2 s, newest right)",
    $(if ($r._Desc) { "  TASK         $($r._Desc)" } else { $null }),
    $(if ($r._Orphaned) { "  ORPHANED     it finished after its spawner had already stopped: its result reached no reader." } else { $null }),
    $(if ($r._Orphaned -and $r._Spawner) { "               to have it read, resume the spawner (peek it for the command) or the session" } else { $null }),
    $(if ($r._Shape) { "  SHAPE        $($r._Shape)" + $(if ($r._Shape -eq 'background') { '   (its spawner keeps working while this runs)' } else { '   (its spawner is blocked until this returns)' }) } else { $null }),
    $(Peek-Block 'LAST ACTION' $(if ($r._Act.LastFull) { $r._Act.LastFull } else { $r.'LAST ACTION' }) $pw),
    "  CWD          $($r.CWD)",
    $(if ($r._Git.Worktree) { "  WORKTREE     yes — branch $($r._Git.Branch); main repo $($r._Git.Main)" } else { $null }),
    $(if ($r._LaunchCwd -and -not [string]::Equals($r._LaunchCwd, $r.CWD, [StringComparison]::OrdinalIgnoreCase)) { "  LAUNCHED IN  $($r._LaunchCwd)   (session has since moved)" } else { $null }),
    $(if ($r._Parent) { "  PARENT       session $($r._Parent)" + $(if ($r._Depth) { "   depth $($r._Depth)" }) + $(if ($r._Spawner) { "   spawned by agent " + ((Split-Path $r._Spawner -Leaf) -replace '^agent-|\.jsonl$', '').Substring(0, 8) } else { '   spawned by the session' }) } else { "  SESSION ID   $($r._SessionId)" }),
    $(if (-not $r._Parent -and [double]$r._TreeCost -ge [double]$r._Act.Cost + 0.005) {
        "  TREE COST    " + ('${0:N2}' -f [double]$r._TreeCost) + " at list price:  this session " + ('${0:N2}' -f [double]$r._Act.Cost) +
        " · $($r._AgentN) subagent$(if ($r._AgentN -ne 1) { 's' }) " + ('${0:N2}' -f [double]$r._AgentCost) +
        $(if ($r._LaunchN) { " · $($r._LaunchN) launched session$(if ($r._LaunchN -ne 1) { 's' }) " + ('${0:N2}' -f [double]$r._LaunchCost) + ' (with their agents)' } else { '' }) } else { $null }),
    $(if ($r._Launcher) { Peek-Block 'LAUNCHED BY' "$($r._Launcher), from its job (pid $($r._LaunchedBy.JobPid)): $($r._LaunchedBy.Label)" $pw } else { $null }),
    $(if ($r._LaunchedNames) { Peek-Block 'LAUNCHED' $r._LaunchedNames $pw } else { $null }),
    "  TRANSCRIPT   $($r._Transcript)",
    '',
    $(if ($r._Parent) { "  (subagents run inside the parent session; resume the parent:  claude --resume $($r._Parent))" }
      else { "  resume in a terminal:   claude --resume $($r._SessionId)" })
  )
  $flat = @(); foreach ($l in $lines) { if ($null -eq $l) { continue }; if ($l -is [array]) { $flat += $l } else { $flat += $l } }
  return ,$flat
}

# ---- footer -----------------------------------------------------------------------
# Toggle keys light up (inverse) when their feature is on; mode keys show their value bright.
function Lamp([string]$key, [string]$label, [bool]$on) {
  $E = [char]27
  if ($on) { "$E[0;7m $key $label $E[0;90m" } else { " $key $label " }
}
function Mode([string]$key, [string]$value) {
  $E = [char]27
  " $key $E[0m$value$E[90m "
}
function Build-Footer {
  # [text, drop-order]: 0 = never dropped; higher numbers go first when the window is narrow
  $items = @(
    @(' ↑↓ select ', 5), @(' enter peek ', 4), @(' PgUp/PgDn ', 11),
    @((Mode 'o' "sort:$($script:SortModes[$script:SortMode])"), 3),
    @((Mode 'v' $script:Layouts[$script:LayoutMode]), 6),
    @((Lamp 'c' 'compact'   $script:Compact), 0),
    @((Lamp 's' 'subagents' $script:ShowSubagents), 0),
    @((Lamp 'g' 'gone'      $script:ShowGone), 0),
    @(' x closed ', 7), @(' t/y copy ', 8), @(' r poll ', 9), @(' +/- tick ', 10), @(' h help ', 0), @(' q quit ', 0)
  )
  $limit = [Console]::WindowWidth - 1
  $keep = @($items)
  while ($true) {
    $line = ' ' + (($keep | ForEach-Object { $_[0] }) -join ' ')
    if ((Strip-Ansi $line).Length -le $limit) { return $line }
    $drop = $keep | Where-Object { $_[1] -gt 0 } | Sort-Object { $_[1] } -Descending | Select-Object -First 1
    if (-not $drop) { return $line }
    $keep = @($keep | Where-Object { -not [object]::ReferenceEquals($_, $drop) })
  }
}

# ---- help overlay -------------------------------------------------------------
function Show-Help {
  $help = @(
    @{ Text = "  ctop $script:CtopVersion — help"; Inverse = $true },
    '',
    'HEADER',
    '  title bar   clock; live sessions / working / idle; live subagents (stopped, orphaned); gone sessions',
    '  tick        display refresh period (ms). +/- adjust by 50ms; floor 50',
    '  frame       measured ms to build + draw the last frame — the real floor for tick',
    '  roster age  time since the last `claude agents --json` result; * = poll in flight',
    '  last poll   measured ms that call took (runs async; display never waits on it)',
    '  hidden N cols  columns the window is too narrow for (low priority first). Peek shows everything.',
    '',
    'ROWS',
    '  A bright top-level row is a live session (one per claude process). Indented rows beginning with',
    '  ├ / └ are its subagents (└ marks the last); a deeper one is an agent spawned by the agent above it.',
    '  A whole session drawn under another was launched by it: its process runs inside one of that',
    '  session''s jobs (a script running claude -p, say). Peek shows LAUNCHED BY / LAUNCHED.',
    '  A faint ╌╌╌ rule separates session groups while subagent rows are shown. Dimmed rows are history',
    '  (gone / cleared sessions, stopped subagents). The tinted row is the cursor (↑/↓, Enter to peek).',
    '',
    'STATE — session rows',
    '  +N  (as in thinking +1, working +3, idle +2)  shown only while s hides the subagent rows: the',
    '             green +N counts the session''s subagents that are live right now (working or thinking);',
    '             stopped ones are not counted. "idle +2" means the session itself is waiting on you while',
    '             two of its agents are still busy. With the rows shown, each agent''s own STATE says it',
    '  working    last transcript entry is a tool call with no result yet: a command running, a file being',
    '             written, or a call waiting for your approval. Green. Turns RED after 2 min with nothing',
    '             written only if no process is running behind the call: a long command keeps green and',
    '             shows its JOB in peek; a call with no process is the one likely waiting on a prompt',
    '  thinking   the model is generating: your prompt or a tool result landed and nothing has come back,',
    '             or the supervisor says busy while the transcript ends in text (mid-answer). Yellow',
    '  idle       the turn ended in text and the supervisor agrees: waiting on you. Dim',
    '  awaiting agent  its open tool call (Agent, Task, or a Skill that runs as a subagent) is waiting',
    '             for an agent it started, and that agent is still live. Cyan; counted as awaiting',
    '  polling    the running command is a wait loop (until/while … sleep, sleep N, tail -f, Start-Sleep,',
    '             Wait-Process / Wait-Job): the session is waiting for something external to happen (a',
    '             file, a marker like rc= in a log, another process). Cyan, not done; counted as awaiting.',
    '             A poll still waiting for your approval has no process yet and stays working',
    '  awaiting job / awaiting N jobs  idle on the transcript, but shell work the session launched is',
    '             still running as child processes of its claude process (a background command, a test',
    '             run, a script). It is not done: it wakes when that work ends. Cyan, sorted with the',
    '             active sessions; peek lists each job''s command, how long it has run, and which program',
    '             is using the CPU right now (python.exe ×8 = eight of its processes busy), and its CPU summed over',
    '             its whole process tree (100% = one core; near 0% for minutes means it is blocked on',
    '             something external, or hung). Only work run',
    '             through the Bash or PowerShell tool counts. Hook runs (a shell Claude Code starts for a',
    '             hook, e.g. gk.exe ai hook run) show as HOOK lines in peek and never change STATE. What',
    '             Claude Code starts itself (git, ripgrep, MCP / language servers, console hosts) is plumbing',
    '  error      the turn ended on a notice Claude Code wrote itself (model <synthetic>): a usage limit',
    '             or an API error, not a model reply. Red; LAST ACTION has the text',
    '  waiting: <reason>  the supervisor''s own word for blocked on your input (newer Claude Code).',
    '             Red, sorted to the top',
    '  gone <t>   the session left the roster <t> ago (you closed it, or it ended). Kept -Linger min,',
    '             dimmed; peek gives the resume command; x lists it permanently',
    '  cleared <t>  a /clear: the same process carries on as a NEW session id (the bright row with the',
    '             same NAME). The pre-clear conversation is still resumable; peek shows how',
    '  anything else  a supervisor status ctop does not recognise, shown verbatim — tell the author',
    '',
    'STATE — subagent rows',
    '  working / thinking  as above. A subagent on a long tool call (working) is always listed, however',
    '             old; a thinking one that writes nothing for -SubagentWindow drops off like a stopped one',
    '  stopped    it returned its result: its transcript ends in text, or (Claude Code 2.1.271+) in a',
    '             SubagentHandback call, whose report LAST ACTION shows as handback: <report>. A subagent',
    '             never waits on you, so',
    '             this is "finished" — but the parent can resume it with SendMessage and it picks up',
    '             its full history; ctop shows it working again if so. Dimmed; drops off after',
    '             -SubagentWindow s (15 min; 0 = keep until the parent goes)',
    '  error      as for sessions: it stopped on a limit / API-error notice, not a result. Red, not dimmed',
    '  awaiting job  a stopped subagent whose background job is still running: not done. A job is',
    '             credited to the agent (session or subagent) whose Bash / PowerShell call is closest in',
    '             time to the job''s start',
    '  orphaned   a NESTED agent that finished AFTER its spawner had already stopped, so its result',
    '             reached no reader (typical of a background child whose parent did not wait). Yellow,',
    '             not dimmed: tokens spent for nothing unless you resume the spawner',
    '',
    'SUBAGENT NAMES   "└ <type> (<id>)"',
    '  <type>     the agent type Claude Code launched, from the sidecar .meta.json:',
    '               general-purpose  full tool set; the only built-in that can spawn agents of its own',
    '               Explore          read-only research agent (cannot spawn)',
    '               Plan             read-only planning agent (cannot spawn)',
    '               fork             a copy of the parent''s context',
    '               <other>          a custom agent from .claude/agents/ (its file name), or a newer built-in',
    '  <id>       the first 8 chars of the agent id; its transcript is <session>/subagents/agent-<id>.jsonl',
    '  TITLE      the task description the spawner gave it. KIND reads subagent, or subagent·bg for one',
    '             spawned in the background (the spawner kept working instead of waiting for it)',
    '',
    'COLUMNS   (source: J = claude agents --json, O = OS, T = transcript file — heuristic)',
    'MOUSE   (Windows; -NoMouse turns it off)  click a row to select it, click it again or double-click',
    '  to peek, wheel to move, click a footer item for its key, click in peek to close it. To select',
    '  text in the terminal while ctop runs, hold Shift while dragging.',
    '',
    '  NAME        J  session name (/rename or --name); for subagents see SUBAGENT NAMES above',
    '  COST Σ      T  second line of a session''s COST: the whole tree — the session, every subagent it',
    '                 ran (also those no longer listed), and sessions it launched. Breakdown in peek',
    '  TITLE       T  the VS Code picker''s name: custom-title (rename) > ai-title (generated) > summary',
    '                 record > summary of its FIRST SendMessage (peer sessions) > first human prompt.',
    '                 (untitled) = the picker shows Untitled too. Subagents: their task description',
    '  KIND        J  interactive (terminal / VS Code), background (agent view), subagent, subagent·bg',
    '  TURN        T  time since your last prompt — how long Claude has been on this turn (blank when idle).',
    '                 Yellow >= 10 min, red >= 30 min',
    '  IDLE        T  time since the transcript was last written to',
    '  CTX         T  context size in K tokens (input + cache tokens on the newest assistant entry)',
    '  CMP         T  compactions so far. Magenta = one in the last 10 min, yellow = older. Each replaces',
    '                 the history with a summary; peek shows when / why / how big',
    '  LAST ACTION T  newest tool call (name + main argument), the start of Claude''s last text (text:),',
    '                 or a subagent''s report (handback:)',
    '  ACTIVITY    T  sparkline of STATE, one sample every 2 s (40 s window), newest on the right:',
    '                 █ working   ▒ thinking   · idle   ░ (cyan) awaiting a background job   ▼ compaction',
    '                 ▁ (red) waiting on you: a permission',
    '                 prompt or a question. No tokens are consumed while waiting',
    '  BRANCH      T  the gitBranch Claude Code stamps on entries (falls back to .git/HEAD).',
    '                 wt: prefix = CWD is a linked git worktree',
    '  AGE         J  time since the session (or agent) started',
    '  CWD         T  where the session is NOW (newest cwd in its transcript). Cyan = it moved since launch',
    '  PID, CPU(s), MEM(MB)   O  the claude process; subagents run inside the parent (no PID)',
    '  TURNS       T  your prompts so far (compaction summaries excluded)',
    '  TOOLS       T  tool calls so far; peek lists them by tool',
    '  MODEL       T  model on the newest assistant entry that came from the API (a <synthetic> entry, which',
    '                 Claude Code writes itself for limits / errors, is skipped). Magenta when it matches -HighlightModel',
    '                 (default fable|mythos): catches a session on a model you did not intend',
    '  COST        T  session spend at API LIST price from per-turn usage (same basis as /usage; not',
    '                 your plan''s billing). Yellow >= $100',
    '  RATE        T  COST / session age, $ per hour',
    '',
    'READING IT',
    '  working + IDLE climbing (STATE turns red)   a permission prompt, or a very long command',
    '  thinking + TURN climbing + solid yellow bar  one long generation; minutes are normal, tens are not',
    '  █▒█▒▒█ alternating                          a healthy loop: tool, think, tool, think',
    '  CTX drops sharply and CMP ticks up          a compaction just happened',
    '  many └ rows under one session               fan-out; the title bar count is your gauge',
    '',
    'KEYS   ↑/↓ select row (the list scrolls to keep it in view; the strip shows "rows 12–30 of 45" when it',
    '         does not all fit)   PgUp/PgDn a screenful   Home/End first / last row',
    '       Enter or Space toggle peek (a live detail screen; ↑/↓ inside it switch',
    '         session; Esc/Enter/q close)   t copy the row''s transcript path   y copy its resume command',
    '       o sort: activity (active above idle, oldest first) | roster (as claude agents lists them) |',
    '         start (never moves) | cost | ctx.   v layout: wrap (long cells continue on the next line',
    '         of their column) | truncate.   c compact (essential columns only)',
    '       s subagent rows   g gone/cleared rows   (a toggle that is ON is lit in the footer)',
    '       x closed-sessions log: everything that left the roster, newest first, with title and resume',
    '         command; persists across runs (<config>/ctop-closed.jsonl). clr = replaced by /clear',
    '       r poll the roster now   +/- tick   h this help   q quit',
    '',
    'LAYOUT   the table fills the window (cap with -MaxWidth). Extra width widens TITLE / LAST ACTION / CWD',
    '  toward their full text; MODEL / BRANCH / KIND / STATE size to content (shrink is delayed ~5 s).',
    '  Column widths are sticky within a run so nothing jitters. Rows: one process = one row; after',
    '  /clear the old id may linger in the roster, ctop keeps the entry with the freshest transcript.',
    '',
    'COLORS   green working · yellow thinking / stopped-with-issue / TURN>=10m / COST>=$100 · red waiting,',
    '  stalled working, TURN>=30m · dim idle, stopped, gone · cyan worktree branch, moved CWD, subagent',
    '  kind · magenta highlighted MODEL, recent CMP, ▼ in the sparkline · yellow STATE orphaned',
    '',
    'All data is local (supervisor socket, OS, files under ~/.claude). No model calls, no tokens.',
    'T-columns depend on the undocumented transcript JSONL shape and may break on updates.'
  )
  # paginate to the window height; any key pages forward, q/Esc closes
  $per = [math]::Max(5, [Console]::WindowHeight - 3)
  $pages = [math]::Ceiling($help.Count / $per)
  for ($pg = 0; $pg -lt $pages; $pg++) {
    $chunk = @($help[($pg * $per)..([math]::Min($help.Count, ($pg + 1) * $per) - 1)])
    $foot = if ($pg -lt $pages - 1) { "  page $($pg + 1)/$pages   any key: next page   q: close" } else { "  page $($pg + 1)/$pages   any key to close" }
    Write-Frame $chunk $foot
    while ([Console]::KeyAvailable) { $null = [Console]::ReadKey($true) }   # drain
    $k = [Console]::ReadKey($true)
    if ($k.KeyChar -eq 'q' -or $k.Key -eq 'Escape') { break }
  }
}

# ---- main loop ----------------------------------------------------------------
# Two loops, decoupled:
#   feed    : roster poll, async, every $RosterInterval s (or on 'r'), never blocks
#   display : every $Tick ms, re-derives STATE/LAST/IDLE/CPU from local files + OS,
#             and repaints immediately whenever a roster poll lands.
# The header shows real numbers: measured poll latency, roster age, and how long the
# last frame took to build+draw, so you can see where the time actually goes.
$script:Roster   = @()
$script:Departed = @{}     # sessionId -> @{ Session; GoneAt }
$script:ClosedLogPath = if ($ClosedLog) { $ClosedLog } else { Join-Path $ConfigDir 'ctop-closed.jsonl' }
$script:ShowGone = $true
$script:Poll     = $null
$script:PollMs   = 0
$script:RosterAt = $null
$selectedId = $null       # session id of the highlighted row
$script:ScrollTop = 0     # first visible body line when the list is taller than the window
$script:PageRows = 10     # rows per screenful, for PgUp / PgDn
$script:PeekId = $null    # when set, the peek screen for this session is drawn live instead of the table
$script:ShowSubagents = -not $NoSubagents
$script:Compact = [bool]$Compact
$sorted     = @()
$origTitle = $Host.UI.RawUI.WindowTitle
$tick = [math]::Max(50, $Tick)

# ---- mouse (Windows console) ------------------------------------------------------
# .NET's Console.ReadKey / KeyAvailable discard every input record that isn't a key, so with the
# mouse on, ctop reads the console input queue itself (ReadConsoleInputW): key records become
# ConsoleKeyInfo for the usual key handling, mouse records become actions. Modes per
# learn.microsoft.com/windows/console/setconsolemode (read 2026-10-21): ENABLE_MOUSE_INPUT 0x10;
# QuickEdit 0x40 must be off for clicks to reach the program; changing it needs ENABLE_EXTENDED_FLAGS 0x80.
$script:Mouse = $false; $script:ConModeOld = $null
$script:ConSrc = @'
using System; using System.Runtime.InteropServices; using System.Collections.Generic;
namespace CtopCon {
  [StructLayout(LayoutKind.Sequential)] public struct KEY_EVENT_RECORD { public int bKeyDown; public ushort wRepeatCount; public ushort wVirtualKeyCode; public ushort wVirtualScanCode; public ushort UnicodeChar; public uint dwControlKeyState; }
  [StructLayout(LayoutKind.Sequential)] public struct MOUSE_EVENT_RECORD { public short X; public short Y; public uint dwButtonState; public uint dwControlKeyState; public uint dwEventFlags; }
  [StructLayout(LayoutKind.Explicit)] public struct INPUT_RECORD { [FieldOffset(0)] public ushort EventType; [FieldOffset(4)] public KEY_EVENT_RECORD Key; [FieldOffset(4)] public MOUSE_EVENT_RECORD Mouse; }
  public class Ev { public int Kind; public ushort Vk; public char Ch; public uint Ctrl; public int Repeat; public int X; public int Y; public uint Buttons; public uint Flags; }
  public static class Con {
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr GetStdHandle(int n);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetConsoleMode(IntPtr h, out uint m);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetConsoleMode(IntPtr h, uint m);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetNumberOfConsoleInputEvents(IntPtr h, out uint n);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "ReadConsoleInputW")] static extern bool ReadConsoleInput(IntPtr h, [Out] INPUT_RECORD[] b, uint len, out uint read);
    static IntPtr In { get { return GetStdHandle(-10); } }
    public static long Enable() {   // returns the old mode, or -1
      uint m; if (!GetConsoleMode(In, out m)) return -1;
      uint n = (m | 0x10u | 0x80u) & ~0x40u;
      return SetConsoleMode(In, n) ? (long)m : -1;
    }
    public static void Restore(long m) { if (m >= 0) SetConsoleMode(In, (uint)m | 0x80u); }
    public static Ev[] Read() {
      var list = new List<Ev>(); uint n;
      if (!GetNumberOfConsoleInputEvents(In, out n) || n == 0) return list.ToArray();
      var buf = new INPUT_RECORD[Math.Min(n, 64u)]; uint got;
      if (!ReadConsoleInput(In, buf, (uint)buf.Length, out got)) return list.ToArray();
      for (int i = 0; i < got; i++) {
        var r = buf[i];
        if (r.EventType == 1 && r.Key.bKeyDown != 0)
          list.Add(new Ev { Kind = 1, Vk = r.Key.wVirtualKeyCode, Ch = (char)r.Key.UnicodeChar, Ctrl = r.Key.dwControlKeyState, Repeat = Math.Max(1, (int)r.Key.wRepeatCount) });
        else if (r.EventType == 2)
          list.Add(new Ev { Kind = 2, X = r.Mouse.X, Y = r.Mouse.Y, Buttons = r.Mouse.dwButtonState, Flags = r.Mouse.dwEventFlags });
      }
      return list.ToArray();
    }
  }
}
'@
function Enable-Mouse {
  if ($NoMouse -or -not ($IsWindows -or $env:OS -eq 'Windows_NT')) { return }
  try {
    if (-not ('CtopCon.Con' -as [type])) {
      # compiled once to a DLL beside the caches: compiling on every start would cost ~1 s
      # named by a hash of the source (String.GetHashCode is randomized per process in .NET Core)
      $h = [BitConverter]::ToString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($script:ConSrc)), 0, 4) -replace '-'
      $dll = Join-Path $ConfigDir "ctop-con-$h.dll"
      if (-not (Test-Path -LiteralPath $dll)) { Add-Type -TypeDefinition $script:ConSrc -OutputAssembly $dll -OutputType Library -ErrorAction Stop }
      Add-Type -Path $dll -ErrorAction Stop
    }
    $old = [CtopCon.Con]::Enable()
    if ($old -ge 0) { $script:ConModeOld = $old; $script:Mouse = $true }
  } catch { $script:Mouse = $false }
}
function Disable-Mouse { if ($null -ne $script:ConModeOld) { try { [CtopCon.Con]::Restore($script:ConModeOld) } catch {} } }
# One queue for keys and mouse: Next-Input returns a ConsoleKeyInfo, a CtopCon.Ev (mouse), or $null.
$script:InQ = [System.Collections.Generic.Queue[object]]::new()
function Next-Input {
  if ($script:InQ.Count -eq 0) {
    if ($script:Mouse) {
      foreach ($e in [CtopCon.Con]::Read()) {
        if ($e.Kind -eq 1) {
          $sh = ($e.Ctrl -band 0x10) -ne 0; $alt = ($e.Ctrl -band 0x3) -ne 0; $ctl = ($e.Ctrl -band 0xC) -ne 0
          $ki = [ConsoleKeyInfo]::new($e.Ch, [ConsoleKey][int]$e.Vk, $sh, $alt, $ctl)
          for ($r = 0; $r -lt [math]::Min($e.Repeat, 10); $r++) { $script:InQ.Enqueue($ki) }
        } else { $script:InQ.Enqueue($e) }
      }
    } elseif ([Console]::KeyAvailable) { $script:InQ.Enqueue([Console]::ReadKey($true)) }
  }
  if ($script:InQ.Count) { return $script:InQ.Dequeue() }
  return $null
}
function Key-Of([string]$what) {
  switch ($what) {
    'Up'     { [ConsoleKeyInfo]::new([char]0,  [ConsoleKey]::UpArrow,   $false, $false, $false) }
    'Down'   { [ConsoleKeyInfo]::new([char]0,  [ConsoleKey]::DownArrow, $false, $false, $false) }
    'Enter'  { [ConsoleKeyInfo]::new([char]13, [ConsoleKey]::Enter,     $false, $false, $false) }
    'Escape' { [ConsoleKeyInfo]::new([char]27, [ConsoleKey]::Escape,    $false, $false, $false) }
    default  { [ConsoleKeyInfo]::new([char]$what, [ConsoleKey]([int][char]$what.ToUpper()), $false, $false, $false) }
  }
}
# A mouse event, as what it means here: @{ Select = <row ordinal> } or @{ Key = ConsoleKeyInfo } or $null.
#   left click on a row: select it (on the already selected row: open its peek); double-click: peek
#   wheel: one row per notch; click a footer item: that item's key; in peek, a click closes it
function Resolve-Mouse($e, [string]$footer, [bool]$inPeek, [int]$selOrd) {
  $y = $e.Y - $(try { [Console]::WindowTop } catch { 0 })
  if ($e.Flags -band 4) {   # MOUSE_WHEELED: the high word of the button state is the signed delta
    $hw = [int](($e.Buttons -shr 16) -band 0xFFFF); $delta = if ($hw -ge 0x8000) { $hw - 0x10000 } else { $hw }   # [int16]65416 throws in PowerShell
    return @{ Key = (Key-Of $(if ($delta -gt 0) { 'Up' } else { 'Down' })) }
  }
  $left = ($e.Buttons -band 1) -ne 0
  $dbl  = ($e.Flags -band 2) -ne 0
  if (-not $left -or ($e.Flags -band 1)) { return $null }   # release, other buttons, plain moves
  if ($inPeek) { if ($dbl) { return $null }; return @{ Key = (Key-Of 'Escape') } }
  $h = try { [Console]::WindowHeight } catch { 0 }
  if ($y -eq $h - 1) {   # footer: "<key> <label>" items
    $plain = Strip-Ansi $footer
    foreach ($m in [regex]::Matches($plain, '(?<![\w/])([a-z])\s+(sort:\w+|sort|wrap|compact|subagents|gone|closed|poll|help|quit)\b')) {
      if ($e.X -ge $m.Index -and $e.X -lt $m.Index + $m.Length) { return @{ Key = (Key-Of $m.Groups[1].Value) } }
    }
    if ($plain -match 'enter peek' -and $e.X -ge $plain.IndexOf('enter peek') -and $e.X -lt $plain.IndexOf('enter peek') + 10) { return @{ Key = (Key-Of 'Enter') } }
    return $null
  }
  if (-not $script:BodyMap -or $y -lt $script:BodyY0) { return $null }
  $i = $y - $script:BodyY0
  if ($i -ge $script:BodyMap.Count) { return $null }
  $ord = $script:BodyMap[$i]
  if ($ord -lt 0) { return $null }
  if ($dbl) { return @{ Select = $ord; Key = (Key-Of 'Enter') } }
  if ($ord -eq $selOrd) { return @{ Key = (Key-Of 'Enter') } }
  return @{ Select = $ord }
}

# Windows consoles default to the OEM code page (437), which lacks ▁ ▼ ↑ ↓ … — they print as ? or .
# Switch to UTF-8 for ctop's lifetime; the original is restored on exit.
$origOutEnc = [Console]::OutputEncoding
try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch {}
try {
  [Console]::CursorVisible = $false
  Clear-Host
  $Host.UI.RawUI.WindowTitle = 'ctop'
  Enable-Mouse
  Update-TranscriptIndex
  Start-RosterPoll
  $frameSw = [System.Diagnostics.Stopwatch]::new()
  $lastFrameMs = 0
  Load-ScanCache
  $lastSave = Get-Date
  $winW = [Console]::WindowWidth; $winH = [Console]::WindowHeight
  while ($true) {
    if (((Get-Date) - $lastSave).TotalSeconds -ge 60) { Save-ScanCache; $lastSave = Get-Date }
    $loopStart = [System.Diagnostics.Stopwatch]::StartNew()
    if ([Console]::WindowWidth -ne $winW -or [Console]::WindowHeight -ne $winH) {
      $winW = [Console]::WindowWidth; $winH = [Console]::WindowHeight
      Clear-Host   # the terminal reflows old lines on resize; wipe them, including the last column
    }

    # feed: harvest a finished poll, and (re)start one if it's time
    $fresh = Read-Roster
    Read-ProcPoll
    if (-not $script:Poll -and $script:RosterAt -and
        ((Get-Date) - $script:RosterAt).TotalSeconds -ge $RosterInterval) { Start-RosterPoll }

    # display
    $frameSw.Restart()
    $rows = @(Build-Rows)
    $top     = @($rows | Where-Object { -not $_._Parent -and -not $_._Gone })
    $goneN   = @($rows | Where-Object { $_._Gone }).Count
    $subs    = @($rows | Where-Object { $_._Parent -and -not $_._Done }).Count
    $subsDone = @($rows | Where-Object { $_._Parent -and $_._Done }).Count
    $subsOrph = @($rows | Where-Object { $_._Parent -and $_._Orphaned }).Count
    $working = @($top | Where-Object { $_.STATE -in 'working','thinking' -or $_.STATE -like 'waiting*' }).Count
    $idle    = @($top | Where-Object { $_.STATE -eq 'idle' }).Count
    $await   = @($top | Where-Object { $_.STATE -like 'awaiting*' -or $_.STATE -eq 'polling' }).Count
    $rosterAge = if ($script:RosterAt) { Get-Since $script:RosterAt } else { '…' }
    $pollFlag  = if ($script:Poll) { '*' } else { ' ' }
    $w = if ($MaxWidth -gt 0) { [math]::Min([Console]::WindowWidth, $MaxWidth + 1) } else { [Console]::WindowWidth }
    # title bar: name + clock on the left, counts right-aligned (within MaxWidth)
    $left  = "  ctop  $(Get-Date -Format 'HH:mm:ss')"
    $parts = @("$($top.Count) sessions", "$working working", "$idle idle")
    if ($await) { $parts += "$await awaiting" }
    if ($subs -or $subsDone) { $parts += "$subs subagents" + $(if ($subsDone) { " ($subsDone stopped" + $(if ($subsOrph) { ", $subsOrph orphaned" }) + ")" }) }
    if ($goneN) { $parts += "$goneN gone" }
    # narrow window: tighten the separators, then drop trailing counts, rather than cut mid-word
    $right = ($parts -join '  ·  ') + '  '
    if ($left.Length + 1 + $right.Length -gt $w - 1) { $right = ($parts -join ' · ') + ' ' }
    while ($left.Length + 1 + $right.Length -gt $w - 1 -and $parts.Count -gt 3) { $parts = $parts[0..($parts.Count - 2)]; $right = ($parts -join ' · ') + ' ' }
    $title = $left + (' ' * [math]::Max(1, ($w - 1) - $left.Length - $right.Length)) + $right
    # instrument strip: fixed-width cells with explicit dividers
    $strip = '  ' + (Cell 'tick'   "${tick}ms"        14) + '│ ' +
                    (Cell 'frame'  "${lastFrameMs}ms" 14) + '│ ' +
                    (Cell 'roster' "$rosterAge$pollFlag" 12) + '│ ' +
                    (Cell 'poll'   "$($script:PollMs)ms" 12) +
             $(if ($script:Compact) { '│ compact ' }) +
             $(if ($script:HiddenCols.Count) { '│ ' + (Cell 'hidden' "$($script:HiddenCols.Count) cols" 14) }) +
             $(if ($script:Departed.Count) { '│ ' + (Cell 'gone' "$($script:Departed.Count)$(if (-not $script:ShowGone) { ' hidden' })" 14) }) +
             '│ ' + (Cell 'build' $script:CtopVersion 20)   # labeled and away from the clock: a bare date beside it reads as "now"
    $frame = @()
    $frame += @{ Text = $title; Inverse = $true }
    $frame += @{ Text = $strip; Fg = 'DarkCyan' }
    $frame += ''
    if ($top.Count -eq 0) {
      $script:BodyMap = $null
      $frame += if ($script:RosterAt) { "(no interactive sessions reported by 'claude agents --json')" } else { '(polling…)' }
    } else {
      $sorted = @(Sort-Rows $rows)
      if (-not $selectedId -or -not ($sorted._SessionId -contains $selectedId)) { $selectedId = $sorted[0]._SessionId }
      $tbl  = @(Render-Table $sorted $selectedId)
      $head = @($tbl[0..1]); $body = if ($tbl.Count -gt 2) { @($tbl[2..($tbl.Count - 1)]) } else { @() }
      # rows left for the body: the footer takes the last line, the title/strip/blank and the column
      # header take the rest
      $room = [math]::Max(3, [Console]::WindowHeight - 1 - $frame.Count - $head.Count)
      $script:BodyY0 = $frame.Count + $head.Count   # screen line of the first body line (for mouse clicks)
      if ($body.Count -le $room) { $script:ScrollTop = 0; $script:PageRows = [math]::Max(1, $sorted.Count); $script:BodyMap = $script:LineRow }
      else {
        # scroll just enough to keep every line of the selected row visible
        if ($script:SelSpan) {
          if ($script:SelSpan[0] -lt $script:ScrollTop) { $script:ScrollTop = $script:SelSpan[0] }
          if ($script:SelSpan[1] -ge $script:ScrollTop + $room) { $script:ScrollTop = $script:SelSpan[1] - $room + 1 }
        }
        $script:ScrollTop = [math]::Max(0, [math]::Min($script:ScrollTop, $body.Count - $room))
        $vTop = $script:ScrollTop; $end = $vTop + $room - 1
        # a wrapped row cut by the window edge would read as a shorter row: leave it out entirely
        $cutTop = if ($vTop -gt 0 -and $script:LineRow[$vTop] -ge 0 -and $script:LineRow[$vTop - 1] -eq $script:LineRow[$vTop]) { $script:LineRow[$vTop] } else { -2 }
        $cutEnd = if ($end + 1 -lt $script:LineRow.Count -and $script:LineRow[$end] -ge 0 -and $script:LineRow[$end + 1] -eq $script:LineRow[$end]) { $script:LineRow[$end] } else { -2 }
        $slice = @(); $visRows = @()
        $script:BodyMap = [System.Collections.Generic.List[int]]::new()
        for ($li = $vTop; $li -le $end -and $li -lt $body.Count; $li++) {
          $rowOf = $script:LineRow[$li]
          if ($rowOf -ge 0 -and ($rowOf -eq $cutTop -or $rowOf -eq $cutEnd)) { $slice += ''; $script:BodyMap.Add(-1); continue }
          $slice += $body[$li]; $script:BodyMap.Add($rowOf); if ($rowOf -ge 0) { $visRows += $rowOf }
        }
        $vis = @($visRows | Select-Object -Unique)
        $script:PageRows = [math]::Max(1, ($vis | Measure-Object -Maximum).Maximum - ($vis | Measure-Object -Minimum).Minimum)
        $body = $slice
        # where we are, in the instrument strip
        $frame[1].Text = $frame[1].Text.TrimEnd() + "   │ rows $(($vis | Measure-Object -Minimum).Minimum + 1)–$(($vis | Measure-Object -Maximum).Maximum + 1) of $($sorted.Count)"
      }
      $frame += $head + $body
    }
    $foot = Build-Footer
    if ((Get-Date) -lt $script:FlashUntil) { $foot = "  ► $($script:Flash)" }
    if ($script:PeekId) {
      $pr = $sorted | Where-Object _SessionId -eq $script:PeekId | Select-Object -First 1
      if ($pr) {
        $pf = "  live peek   ↑↓ other session   esc/enter close   t copy transcript path   y copy resume   h help"
        if ((Get-Date) -lt $script:FlashUntil) { $pf = "  ► $($script:Flash)" }
        Write-Frame (Build-Peek $pr) $pf
      } else { $script:PeekId = $null; Write-Frame $frame $foot }
    } else {
      Write-Frame $frame $foot
    }
    $lastFrameMs = [int]$frameSw.ElapsedMilliseconds

    # sleep the *remainder* of the tick (actual-time based), servicing keys meanwhile
    while ($loopStart.ElapsedMilliseconds -lt $tick) {
      $inp = Next-Input
      if ($null -ne $inp) {
        $idx = [array]::IndexOf(@($sorted._SessionId), $selectedId)
        $repaint = $false
        $k = $inp
        if ($inp -isnot [ConsoleKeyInfo]) {   # a mouse event
          $act = Resolve-Mouse $inp $(if ($script:PeekId) { $pf } else { $foot }) ([bool]$script:PeekId) $idx
          if (-not $act) { continue }
          if ($null -ne $act.Select -and $act.Select -lt $sorted.Count) { $selectedId = $sorted[$act.Select]._SessionId; $idx = $act.Select; $repaint = $true }
          if (-not $act.Key) { break }
          $k = $act.Key
        }
        # NOTE: in PowerShell, break/continue inside `switch` only leave the switch, not the
        # enclosing while — so we set a flag and break the sleep loop explicitly below.
        switch ($k.Key) {
          'UpArrow'   { if ($idx -gt 0) { $selectedId = $sorted[$idx - 1]._SessionId }; if ($script:PeekId) { $script:PeekId = $selectedId }; $repaint = $true }
          'DownArrow' { if ($idx -ge 0 -and $idx -lt $sorted.Count - 1) { $selectedId = $sorted[$idx + 1]._SessionId }; if ($script:PeekId) { $script:PeekId = $selectedId }; $repaint = $true }
          'PageUp'    { if ($sorted.Count) { $selectedId = $sorted[[math]::Max(0, $idx - $script:PageRows)]._SessionId; if ($script:PeekId) { $script:PeekId = $selectedId } }; $repaint = $true }
          'PageDown'  { if ($sorted.Count) { $selectedId = $sorted[[math]::Min($sorted.Count - 1, [math]::Max(0, $idx) + $script:PageRows)]._SessionId; if ($script:PeekId) { $script:PeekId = $selectedId } }; $repaint = $true }
          'Home'      { if ($sorted.Count) { $selectedId = $sorted[0]._SessionId; if ($script:PeekId) { $script:PeekId = $selectedId } }; $repaint = $true }
          'End'       { if ($sorted.Count) { $selectedId = $sorted[-1]._SessionId; if ($script:PeekId) { $script:PeekId = $selectedId } }; $repaint = $true }
          'Enter'     { $script:PeekId = if ($script:PeekId) { $null } else { $selectedId }; $repaint = $true }
          'Spacebar'  { $script:PeekId = if ($script:PeekId) { $null } else { $selectedId }; $repaint = $true }
          'Escape'    { if ($script:PeekId) { $script:PeekId = $null; $repaint = $true } }
        }
        switch ($k.KeyChar) {
          'q' { if ($script:PeekId) { $script:PeekId = $null; $repaint = $true } else { return } }
          'r' { if (-not $script:Poll) { Start-RosterPoll } }
          '+' { $tick = [math]::Max(50,   $tick - 50); $repaint = $true }
          '-' { $tick = [math]::Min(5000, $tick + 50); $repaint = $true }
          'h' { Show-Help; $repaint = $true }
          's' { $script:ShowSubagents = -not $script:ShowSubagents; $repaint = $true }
          'c' { $script:Compact = -not $script:Compact; $repaint = $true }
          'o' { $script:SortMode = ($script:SortMode + 1) % $script:SortModes.Count; $repaint = $true }
          'v' { $script:LayoutMode = ($script:LayoutMode + 1) % $script:Layouts.Count; $repaint = $true }
          'g' { $script:ShowGone = -not $script:ShowGone; $repaint = $true }
          'x' { Show-Closed; $repaint = $true }
          't' { $sel = $sorted | Where-Object _SessionId -eq $selectedId | Select-Object -First 1; if ($sel -and $sel._Transcript -ne '-') { Copy-Text $sel._Transcript 'transcript path' } }
          'y' { $sel = $sorted | Where-Object _SessionId -eq $selectedId | Select-Object -First 1; if ($sel) { $id = if ($sel._Parent) { $sel._Parent } else { $sel._SessionId }; Copy-Text "claude --resume $id" 'resume command' } }
        }
        if ($repaint) { break }
      }
      # if a poll just finished mid-sleep, repaint now rather than waiting out the tick
      if ($script:Poll -and $script:Poll.Proc.HasExited -and $script:Poll.Out.IsCompleted) { break }
      Start-Sleep -Milliseconds ([math]::Min(20, [math]::Max(1, $tick - $loopStart.ElapsedMilliseconds)))
    }
  }
}
catch {
  $script:Fatal = $_
}
finally {
  if ($script:Poll) { try { $script:Poll.Proc.Kill(); $script:Poll.Proc.Dispose() } catch {} }
  Disable-Mouse   # give the console its QuickEdit / mouse mode back, crash or not
  [Console]::CursorVisible = $true
  if ($script:ProcJob) { Remove-Job $script:ProcJob -Force -ErrorAction SilentlyContinue }
  Save-ScanCache
  try { [Console]::OutputEncoding = $origOutEnc } catch {}
  $Host.UI.RawUI.WindowTitle = $origTitle
  [Console]::SetCursorPosition(0, [Console]::WindowHeight - 1)
  Write-Host ''
  if ($script:Fatal) {
    Write-Host "ctop $script:CtopVersion stopped: $($script:Fatal.Exception.GetType().Name): $($script:Fatal.Exception.Message)" -ForegroundColor Red
    Write-Host $script:Fatal.ScriptStackTrace -ForegroundColor DarkGray
  }
}
