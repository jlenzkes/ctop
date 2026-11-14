# The prompt-cache countdown: the same rule as the Claude Code extension for VS Code
# (anthropic.claude-code-2.1.323, webview/index.js): anchored on the last model call, 1h or 5m from that
# call's cache writes, minutes rounded up, cold once expired or compacted.
BeforeAll {
  . (Join-Path $PSScriptRoot 'Import-Ctop.ps1')
  function Usage([string]$ts, [string]$id, [long]$in = 3, [long]$cr = 1000, [long]$cw = 200, [long]$w1h = 200, [long]$w5 = 0) {
    '{"type":"assistant","timestamp":"' + $ts + '","message":{"id":"' + $id + '","model":"claude-opus-5-5","usage":{"input_tokens":' + $in +
      ',"cache_creation_input_tokens":' + $cw + ',"cache_read_input_tokens":' + $cr + ',"cache_creation":{"ephemeral_1h_input_tokens":' + $w1h +
      ',"ephemeral_5m_input_tokens":' + $w5 + '},"output_tokens":5}}}'
  }
  function Scan([string[]]$lines) {
    $f = Join-Path $TestDrive "t-$([guid]::NewGuid().ToString('N')).jsonl"
    [IO.File]::WriteAllText($f, (($lines -join "`n") + "`n"))
    Update-Scan (Get-Item -LiteralPath $f) ([IO.Path]::GetFileNameWithoutExtension($f))
  }
  function At([string]$ts) { [DateTimeOffset]::Parse($ts, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime }
  function Act([string]$ttl, [string]$anchor = '2026-11-13T12:00:00.000Z', [long]$tok = 220000, [string]$compact = '') {
    @{ CacheTtl = $ttl; CacheAnchor = $anchor; RecacheTok = $tok; CacheCompactAt = $compact }
  }
}

Describe 'Update-Scan: the cache anchor' {
  BeforeEach { $script:ScanCache = @{}; $script:ScanVerified = @{} }
  It 'takes 1h from a call that wrote a 1-hour cache' {
    $st = Scan @(Usage '2026-11-13T12:00:00.000Z' 'msg_1')
    $st.CacheTtl | Should -Be '1h'
    $st.RecacheTok | Should -Be 1203
    (At $st.CacheAnchor) | Should -Be (At '2026-11-13T12:00:00.000Z')
  }
  It 'takes 5m from a call that wrote a 5-minute cache' {
    (Scan @(Usage '2026-11-13T12:00:00.000Z' 'msg_1' -w1h 0 -w5 200)).CacheTtl | Should -Be '5m'
  }
  It 'carries the TTL over a call that only read the cache' {
    $st = Scan @((Usage '2026-11-13T12:00:00.000Z' 'msg_1'), (Usage '2026-11-13T12:01:00.000Z' 'msg_2' -cw 0 -w1h 0))
    $st.CacheTtl | Should -Be '1h'
    (At $st.CacheAnchor) | Should -Be (At '2026-11-13T12:01:00.000Z')
  }
  It 'forgets the TTL after a call with no cache use' {
    $st = Scan @((Usage '2026-11-13T12:00:00.000Z' 'msg_1'), (Usage '2026-11-13T12:01:00.000Z' 'msg_2' -in 0 -cr 0 -cw 0 -w1h 0))
    $st.CacheTtl | Should -Be ''
    (Get-CacheState $st (At '2026-11-13T12:02:00Z')).Kind | Should -Be 'unknown'
  }
  It 'keeps the first anchor across lines of one message' {
    $st = Scan @((Usage '2026-11-13T12:00:00.000Z' 'msg_1'), (Usage '2026-11-13T12:00:30.000Z' 'msg_1'))
    (At $st.CacheAnchor) | Should -Be (At '2026-11-13T12:00:00.000Z')
  }
  It 'is cold after a compaction until the next call' {
    $boundary = '{"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"auto","preTokens":150000},"timestamp":"2026-11-13T12:05:00.000Z"}'
    $st = Scan @((Usage '2026-11-13T12:00:00.000Z' 'msg_1'), $boundary)
    $s = Get-CacheState $st (At '2026-11-13T12:06:00Z')
    $s.Kind | Should -Be 'cold'
    $s.Reason | Should -Be 'compacted'
    $st = Scan @((Usage '2026-11-13T12:00:00.000Z' 'msg_1'), $boundary, (Usage '2026-11-13T12:06:00.000Z' 'msg_2'))
    (Get-CacheState $st (At '2026-11-13T12:07:00Z')).Kind | Should -Be 'warm'
  }
}

Describe 'Get-CacheState' {
  It 'is <Kind> <Want> with <Ttl> after <Offset>' -ForEach @(
    @{ Ttl = '1h'; Offset = '00:17:01';    Kind = 'warm'; Want = 43 }
    @{ Ttl = '1h'; Offset = '00:59:59.5';  Kind = 'warm'; Want = 1 }
    @{ Ttl = '5m'; Offset = '00:01:00';    Kind = 'warm'; Want = 4 }
    @{ Ttl = '1h'; Offset = '-00:05:00';   Kind = 'warm'; Want = 60 }   # clock skew: never above the TTL
    @{ Ttl = '1h'; Offset = '01:00:00';    Kind = 'cold'; Want = 'expired' }
  ) {
    $s = Get-CacheState (Act $Ttl) ((At '2026-11-13T12:00:00Z') + [timespan]::Parse($Offset))
    $s.Kind | Should -Be $Kind
    if ($Kind -eq 'warm') { $s.MinutesLeft | Should -Be $Want } else { $s.Reason | Should -Be $Want; $s.IdleMs | Should -Be 3600000 }
  }
  It 'is unknown with no anchor or no TTL' {
    (Get-CacheState (Act '') (At '2026-11-13T12:01:00Z')).Kind | Should -Be 'unknown'
    (Get-CacheState (Act '1h' '') (At '2026-11-13T12:01:00Z')).Kind | Should -Be 'unknown'
    (Get-CacheState $null (At '2026-11-13T12:01:00Z')).Kind | Should -Be 'unknown'
  }
  It 'parses the anchor under de-DE' {
    $old = [Threading.Thread]::CurrentThread.CurrentCulture
    try {
      [Threading.Thread]::CurrentThread.CurrentCulture = 'de-DE'
      (Get-CacheState (Act '1h') ((At '2026-11-13T12:00:00Z').AddSeconds(1021))).MinutesLeft | Should -Be 43
    } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $old }
  }
}

Describe 'Format-CacheCell' {
  It 'shows <Want>' -ForEach @(
    @{ State = @{ Kind = 'warm'; MinutesLeft = 43 }; Want = '43m' }
    @{ State = @{ Kind = 'cold'; Reason = 'expired' }; Want = 'cold' }
    @{ State = @{ Kind = 'unknown' }; Want = '-' }
    @{ State = $null; Want = '-' }
  ) {
    Format-CacheCell $State | Should -Be $Want
  }
}

Describe 'the CACHE column' {
  It 'shows CACHE, not IDLE, among the table''s columns (IDLE is in peek)' {
    $src = Get-Content -Raw (Join-Path (Split-Path -Parent $PSScriptRoot) 'ctop.ps1')
    $src | Should -Match "@\{ Name = 'CACHE';"
    $src | Should -Not -Match "@\{ Name = 'IDLE';"
  }
  It 'sorts warm rows soonest-first, then cold, then unknown' {
    $script:SortModes = @('activity', 'roster', 'start', 'cost', 'ctx', 'cache')
    $script:SortMode = 5
    function Row([string]$id, $cache) {
      [pscustomobject]@{ _SessionId = $id; _Gone = $null; _StartedAt = [datetime]'2026-11-13T10:00:00'; STATE = 'idle'
                         NAME = $id; PID = '-'; _Parent = $null; _LaunchedBy = $null; _Spawner = ''; _Order = 0; _Depth = 0
                         _Act = @{ Cost = 0.0; Ctx = '-' }; _AgentCost = 0.0; _Cache = $cache }
    }
    $rows = @(
      (Row 'unknown' @{ Kind = 'unknown' }), (Row 'w10' @{ Kind = 'warm'; MsLeft = 600000.0 })
      (Row 'cold' @{ Kind = 'cold'; Reason = 'expired' }), (Row 'w2' @{ Kind = 'warm'; MsLeft = 120000.0 })
    )
    @(Sort-Rows $rows | ForEach-Object { $_._SessionId }) | Should -Be @('w2', 'w10', 'cold', 'unknown')
  }
  It 'colours <Name>' -ForEach @(
    @{ Name = '4 min left of 1h yellow';  State = @{ Kind = 'warm'; Ttl = '1h'; MsLeft = 240000.0 }; Want = 'yellow' }
    @{ Name = '6 min left of 1h plain';   State = @{ Kind = 'warm'; Ttl = '1h'; MsLeft = 360000.0 }; Want = '' }
    @{ Name = '40 s left of 5m yellow';   State = @{ Kind = 'warm'; Ttl = '5m'; MsLeft = 40000.0 };  Want = 'yellow' }
    @{ Name = '2 min left of 5m plain';   State = @{ Kind = 'warm'; Ttl = '5m'; MsLeft = 120000.0 }; Want = '' }
    @{ Name = 'cold dim';                 State = @{ Kind = 'cold'; Reason = 'expired' };            Want = 'dim' }
    @{ Name = 'unknown plain';            State = @{ Kind = 'unknown' };                             Want = '' }
  ) {
    Cell-Color 'CACHE' ([pscustomobject]@{ _Cache = $State; _Gone = $null }) | Should -Be $Want
  }
  It 'counts down a gone session' {
    $script:TranscriptIndex = @{}; $script:History = @{}
    $started = [DateTimeOffset]::UtcNow.AddHours(-3)
    $anchor = [DateTimeOffset]::UtcNow.AddMinutes(-20).ToString('o')
    $r = [pscustomobject]@{ _SessionId = 'g1'; _Gone = (Get-Date).AddMinutes(-7); _Cleared = $false
                            _Act = @{ Cost = 6.0; CacheAnchor = $anchor; CacheTtl = '1h'; RecacheTok = 1000; CacheCompactAt = '' }
                            _StartedAt = $started.LocalDateTime; _Src = [pscustomobject]@{ sessionId = 'g1'; startedAt = $started.ToUnixTimeMilliseconds() }
                            STATE = 'stale'; AGE = 'stale'; IDLE = 'stale'; RATE = 'stale'; ACTIVITY = 'stale'; CACHE = 'stale'; _Cache = $null; _Dirty = $false }
    Update-GoneRow $r
    $r.CACHE | Should -Be '40m'
    $r._Cache.Kind | Should -Be 'warm'
    $r._Dirty | Should -BeTrue
  }
}

Describe 'Format-CachePeek' {
  BeforeAll {
    $script:Pricing = @(@{ Match = '^priced$'; In = 5; Out = 25; Read = 0.5; W5 = 6.25; W1h = 10 })
    $anchor = [datetime]::new(2026, 11, 13, 14, 2, 11, [DateTimeKind]::Local)
  }
  It 'gives the time left and the next turn warm and cold' {
    $s = @{ Kind = 'warm'; Ttl = '1h'; MinutesLeft = 43; RecacheTokens = 220000; Anchor = $anchor.ToUniversalTime() }
    Format-CachePeek $s 'priced' | Should -Be 'warm, 43 min left (1h, last call 14:02:11) · next turn ≈ $0.11 warm, $2.20 cold (220K tokens)'
  }
  It 'prices a cold 5-minute cache at the 5-minute write price' {
    $s = @{ Kind = 'warm'; Ttl = '5m'; MinutesLeft = 3; RecacheTokens = 220000; Anchor = $anchor.ToUniversalTime() }
    Format-CachePeek $s 'priced' | Should -Be 'warm, 3 min left (5m, last call 14:02:11) · next turn ≈ $0.11 warm, $1.38 cold (220K tokens)'
  }
  It 'leaves the dollars out for a model with no price' {
    $s = @{ Kind = 'warm'; Ttl = '1h'; MinutesLeft = 43; RecacheTokens = 220000; Anchor = $anchor.ToUniversalTime() }
    Format-CachePeek $s 'nobody' | Should -Be 'warm, 43 min left (1h, last call 14:02:11) · next turn (220K tokens)'
  }
  It 'says how long it has been idle once expired' {
    $s = @{ Kind = 'cold'; Reason = 'expired'; Ttl = '1h'; IdleMs = 72 * 60000.0; RecacheTokens = 220000 }
    Format-CachePeek $s 'priced' | Should -Be 'likely expired (idle 1h 12m) · next turn re-caches about 220K tokens ≈ $2.20'
  }
  It 'formats idle like the extension: <Want>' -ForEach @(
    @{ Ms = 59 * 60000.0; Want = 'idle 59m' }, @{ Ms = 25 * 3600000.0 + 60000; Want = 'idle 1d 1h' }
  ) {
    Format-CachePeek @{ Kind = 'cold'; Reason = 'expired'; Ttl = '5m'; IdleMs = $Ms; RecacheTokens = 0 } 'priced' | Should -Match ([regex]::Escape("($Want)"))
  }
  It 'explains a compaction' {
    Format-CachePeek @{ Kind = 'cold'; Reason = 'compacted' } 'priced' | Should -Be "doesn't cover the compacted conversation: the next turn re-caches it"
  }
  It 'says when nothing is known' {
    Format-CachePeek @{ Kind = 'unknown' } 'priced' | Should -Be 'unknown (no cache use recorded)'
    Format-CachePeek $null 'priced' | Should -Be 'unknown (no cache use recorded)'
  }
}
