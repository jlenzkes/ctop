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
  # a main-thread user entry: a prompt or a tool result, which the extension takes as the request time
  function User([string]$ts, [bool]$side = $false) {
    '{"parentUuid":"p","isSidechain":' + $(if ($side) { 'true' } else { 'false' }) + ',"type":"user","message":{"role":"user","content":[{"tool_use_id":"t","type":"tool_result","content":"x"}]},"uuid":"u","timestamp":"' + $ts + '"}'
  }
  function Synthetic([string]$ts) {
    '{"type":"assistant","timestamp":"' + $ts + '","message":{"id":"msg_syn","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}'
  }
  function Scan([string[]]$lines, [switch]$Subagent) {
    $dir = if ($Subagent) { Join-Path $TestDrive "s-$([guid]::NewGuid().ToString('N'))/subagents" } else { $TestDrive }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $f = Join-Path $dir "t-$([guid]::NewGuid().ToString('N')).jsonl"
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
    $st = Scan @((Usage '2026-11-13T12:00:00.000Z' 'msg_1'), (Usage '2026-11-13T12:01:00.000Z' 'msg_2' -cr 0 -cw 0 -w1h 0))
    $st.CacheTtl | Should -Be ''
    (Get-CacheState $st (At '2026-11-13T12:02:00Z')).Kind | Should -Be 'unknown'
  }
  It 'ignores a <Name> after a 1-hour call (the extension records no frame for it)' -ForEach @(
    @{ Name = 'synthetic entry (an API error, a session limit)'; Line = 'syn' }
    @{ Name = 'call with no tokens at all'; Line = 'zero' }
  ) {
    $second = if ($Line -eq 'syn') { Synthetic '2026-11-13T12:02:00.000Z' } else { Usage '2026-11-13T12:02:00.000Z' 'msg_2' -in 0 -cr 0 -cw 0 -w1h 0 }
    $st = Scan @((Usage '2026-11-13T12:00:00.000Z' 'msg_1'), $second)
    $s = Get-CacheState $st (At '2026-11-13T12:03:00Z')
    $s.Kind | Should -Be 'warm'
    $s.MinutesLeft | Should -Be 57
  }
  It 'stays cold after a compaction followed by a synthetic entry' {
    $boundary = '{"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"auto","preTokens":150000},"timestamp":"2026-11-13T12:05:00.000Z"}'
    $st = Scan @((Usage '2026-11-13T12:00:00.000Z' 'msg_1'), $boundary, (Synthetic '2026-11-13T12:06:00.000Z'))
    (Get-CacheState $st (At '2026-11-13T12:07:00Z')).Kind | Should -Be 'cold'
  }
  It 'anchors on the request (the latest user entry before the reply), not the reply' {
    $st = Scan @((User '2026-11-13T12:00:00.000Z'), (Usage '2026-11-13T12:03:00.000Z' 'msg_1'))
    (Get-CacheState $st (At '2026-11-13T12:30:30Z')).MinutesLeft | Should -Be 30
    $st = Scan @((User '2026-11-13T12:00:00.000Z'), (Usage '2026-11-13T12:00:50.000Z' 'msg_1' -w1h 0 -w5 200))
    (Get-CacheState $st (At '2026-11-13T12:04:30Z')).MinutesLeft | Should -Be 1
  }
  It 'finds a tool result''s timestamp when a large toolUseResult follows it' {
    $big = '{"parentUuid":"p","isSidechain":false,"type":"user","message":{"role":"user","content":[{"tool_use_id":"t","type":"tool_result","content":"x"}]},"uuid":"9b3b2be4-638a-44f9-a48b-55941fedac45","timestamp":"2026-11-13T12:00:00.000Z","toolUseResult":{"stdout":"' + ('y' * 5000) + '"},"cwd":"c:\\x"}'
    $st = Scan @($big, (Usage '2026-11-13T12:03:00.000Z' 'msg_1'))
    (At $st.CacheAnchor) | Should -Be (At '2026-11-13T12:00:00.000Z')
  }
  It 'takes the latest of several user entries, and forgets them once a reply is recorded' {
    $st = Scan @((User '2026-11-13T12:00:00.000Z'), (User '2026-11-13T12:02:00.000Z'), (Usage '2026-11-13T12:03:00.000Z' 'msg_1'))
    (At $st.CacheAnchor) | Should -Be (At '2026-11-13T12:02:00.000Z')
    $st = Scan @((User '2026-11-13T12:00:00.000Z'), (Usage '2026-11-13T12:01:00.000Z' 'msg_1'), (Usage '2026-11-13T12:10:00.000Z' 'msg_2'))
    (At $st.CacheAnchor) | Should -Be (At '2026-11-13T12:10:00.000Z')
  }
  It 'ignores sidechain entries in a main transcript, and counts them in a subagent''s own' {
    $side = (Usage '2026-11-13T12:10:00.000Z' 'msg_s' -w1h 0 -w5 200) -replace '^\{', '{"isSidechain":true,'
    $st = Scan @((Usage '2026-11-13T12:00:00.000Z' 'msg_1'), (User '2026-11-13T12:09:00.000Z' $true), $side)
    $st.CacheTtl | Should -Be '1h'
    (At $st.CacheAnchor) | Should -Be (At '2026-11-13T12:00:00.000Z')
    $st = Scan -Subagent @((User '2026-11-13T12:09:00.000Z' $true), $side)
    $st.CacheTtl | Should -Be '5m'
    (At $st.CacheAnchor) | Should -Be (At '2026-11-13T12:09:00.000Z')
  }
  It 'takes a reply''s own timestamp, not a uuid/timestamp pair inside a tool_use input' {
    $line = '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"t","name":"X","input":{"uuid":"9b3b2be4-638a-44f9-a48b-55941fedac45","timestamp":"2025-01-01T00:00:00.000Z"}}],"usage":{"input_tokens":3,"cache_creation_input_tokens":200,"cache_read_input_tokens":1000,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z","cwd":"c:\\x"}'
    $st = Scan @($line)
    (At $st.CacheAnchor) | Should -Be (At '2026-11-13T12:00:00.000Z')
  }
  It 'keeps the milliseconds of the cache times through a save and a load' {
    $script:CacheDays = 2; $script:PriceVer = 2; $script:ScanVer = 6
    $script:ScanCachePath = Join-Path $TestDrive "sc-$([guid]::NewGuid().ToString('N')).json"
    $now = (Get-Date).ToUniversalTime()
    $t = $now.AddMinutes(-1).ToString('yyyy-MM-ddTHH:mm:ss') + '.250Z'
    $script:ScanCache = @{ k = @{ Path = '/a.jsonl'; Head = 'h'; Used = $now.Ticks; PriceVer = 2; ScanVer = 6; ToolCounts = @{}
                                  CacheAnchor = $t; CacheReqAt = $t; CacheCompactAt = $t; CacheTtl = '1h' } }
    Mock Move-Over { [IO.File]::Copy($src, $dst, $true); [IO.File]::Delete($src) }
    Save-ScanCache
    $script:ScanCache = @{}
    Load-ScanCache
    foreach ($f in 'CacheAnchor', 'CacheReqAt', 'CacheCompactAt') { (At ([string]$script:ScanCache.k[$f])) | Should -Be (At $t) -Because $f }
  }
  # Windows PowerShell 5.1 saves a DateTime as "\/Date(<ms since 1970, UTC>)\/", and both runtimes read that back
  # as a UTC DateTime; TURN and CMP subtract it from local time, so it must come back as local time.
  It 'gives back a turn start and a compaction time saved by Windows PowerShell 5.1 as local times' {
    $script:CacheDays = 2; $script:PriceVer = 2; $script:ScanVer = 6
    $script:ScanCachePath = Join-Path $TestDrive "sc-$([guid]::NewGuid().ToString('N')).json"
    $now = (Get-Date).ToUniversalTime()
    $ms = [DateTimeOffset]::UtcNow.AddMinutes(-30).ToUnixTimeMilliseconds()
    [IO.File]::WriteAllText($script:ScanCachePath, '{"k":{"Path":"/a.jsonl","Head":"h","Used":' + $now.Ticks + ',"PriceVer":2,"ScanVer":6,"ToolCounts":{},' +
      '"TurnStart":"\/Date(' + $ms + ')\/","LastCompactAt":"\/Date(' + $ms + ')\/"}}')
    $script:ScanCache = @{}
    Load-ScanCache
    Get-Since $script:ScanCache.k.TurnStart | Should -Be '30m'
    Get-Since $script:ScanCache.k.LastCompactAt | Should -Be '30m'
  }
  It 'reads the entry''s own fields, not look-alikes inside a tool input: <Name>' -ForEach @(
    @{ Name = 'a usage object';        Nested = '{"usage":{"input_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}' }
    @{ Name = 'isSidechain true';      Nested = '{"isSidechain":true}' }
    @{ Name = 'a synthetic model';     Nested = '{"message":{"model":"<synthetic>"},"model":"<synthetic>"}' }
    @{ Name = 'a user type';           Nested = '{"type":"user","role":"user"}' }
  ) {
    $line = '{"parentUuid":"p","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"tool_use","id":"t","name":"X","input":' + $Nested + '}],"usage":{"input_tokens":3,"cache_creation_input_tokens":200,"cache_read_input_tokens":1000,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}'
    $st = Scan @($line)
    $st.CacheTtl | Should -Be '1h'
    $st.RecacheTok | Should -Be 1203
    $st.Turns | Should -Be 0
    $st.InTok | Should -Be 3
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
  It 'keeps the size of the compacted conversation (postTokens) and the TTL before it, for RECACHE' {
    # a real boundary, as Claude Code writes it (seen in ~/.claude/projects on 2026-11-13)
    $boundary = '{"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"auto","preTokens":280717,"postTokens":51232,"cumulativeDroppedTokens":229485,"durationMs":1060},"timestamp":"2026-11-13T12:05:00.000Z"}'
    $st = Scan @((Usage '2026-11-13T12:00:00.000Z' 'msg_1'), $boundary)
    $st.LastCompactPreTokens | Should -Be 280717
    $st.LastCompactPostTokens | Should -Be 51232
    $s = Get-CacheState $st (At '2026-11-13T12:06:00Z')
    $s.Reason | Should -Be 'compacted'
    $s.RecacheTokens | Should -Be 51232
    $s.Ttl | Should -Be '1h'
  }
  It 'carries postTokens from the scan to the session''s action (Get-LastAction)' {
    $script:TailCache = @{}
    $boundary = '{"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"auto","preTokens":280717,"postTokens":51232},"timestamp":"2026-11-13T12:05:00.000Z"}'
    $f = Join-Path $TestDrive "la-$([guid]::NewGuid().ToString('N')).jsonl"
    [IO.File]::WriteAllText($f, (((Usage '2026-11-13T12:00:00.000Z' 'msg_1'), $boundary) -join "`n") + "`n")
    $a = Get-LastAction (Get-Item -LiteralPath $f) ([guid]::NewGuid().ToString())
    $a.LastCompactPostTokens | Should -Be 51232
    (Get-CacheState $a (At '2026-11-13T12:06:00Z')).RecacheTokens | Should -Be 51232
  }
  # the extension takes the main thread's events only, and a time it can't read as none
  It 'ignores a sidechain''s compaction in a main transcript, and counts it in a subagent''s own' {
    $boundary = '{"isSidechain":true,"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"auto","preTokens":150000},"timestamp":"2026-11-13T12:05:00.000Z"}'
    $st = Scan @((Usage '2026-11-13T12:00:00.000Z' 'msg_1'), $boundary)
    (Get-CacheState $st (At '2026-11-13T12:06:00Z')).Kind | Should -Be 'warm'
    $side = (Usage '2026-11-13T12:00:00.000Z' 'msg_1') -replace '^\{', '{"isSidechain":true,'
    $s = Get-CacheState (Scan -Subagent @($side, $boundary)) (At '2026-11-13T12:06:00Z')
    $s.Kind, $s.Reason | Should -Be @('cold', 'compacted')
  }
  It 'keeps a compaction when a later one''s time can''t be read' {
    $boundary = '{"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"auto","preTokens":150000},"timestamp":"2026-11-13T12:05:00.000Z"}'
    $bad = '{"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"auto","preTokens":150000},"timestamp":"not a time"}'
    $s = Get-CacheState (Scan @((Usage '2026-11-13T12:00:00.000Z' 'msg_1'), $boundary, $bad)) (At '2026-11-13T12:06:00Z')
    $s.Kind, $s.Reason | Should -Be @('cold', 'compacted')
  }
  # an ignored boundary keeps the mark where it is and must not replace its size, or RECACHE would price the
  # valid compaction at the ignored one's size ($0.72, $0.99, or none, for $0.41)
  It 'keeps the compaction''s size when a later boundary is ignored (<Case>, <Reader> reader)' -ForEach @(
    foreach ($reader in 'rx', 'cs') {
      @{ Reader = $reader; Case = 'sidechain'; Want = 51232; Line = '{"type":"system","subtype":"compact_boundary","timestamp":"2026-11-13T12:05:01Z","compactMetadata":{"trigger":"auto","postTokens":90000},"isSidechain":true}' }
      @{ Reader = $reader; Case = 'time that does not read'; Want = 51232; Line = '{"type":"system","subtype":"compact_boundary","timestamp":"invalid","compactMetadata":{"trigger":"auto","postTokens":123456}}' }
      @{ Reader = $reader; Case = 'time that does not read, no postTokens'; Want = 51232; Line = '{"type":"system","subtype":"compact_boundary","timestamp":"invalid","compactMetadata":{"trigger":"auto"}}' }
      @{ Reader = $reader; Case = 'a later main compaction (counts)'; Want = 80000; Line = '{"type":"system","subtype":"compact_boundary","timestamp":"2026-11-13T12:05:02Z","compactMetadata":{"trigger":"auto","postTokens":80000}}' }
    }
  ) {
    $keep = Get-EntryReader
    try {
      $script:EntryReader = $Reader
      if ($Reader -eq 'cs' -and $keep -ne 'cs') { Set-ItResult -Skipped -Because 'CtopJson does not compile here'; return }
      $main = '{"type":"system","subtype":"compact_boundary","timestamp":"2026-11-13T12:05:00Z","compactMetadata":{"trigger":"auto","preTokens":280717,"postTokens":51232}}'
      $st = Scan @((Usage '2026-11-13T12:00:00.000Z' 'msg_1'), $main, $Line)
      $st.LastCompactPostTokens | Should -Be $Want
      $s = Get-CacheState $st (At '2026-11-13T12:06:00Z')
      $s.Reason, $s.RecacheTokens, $s.Ttl | Should -Be @('compacted', $Want, '1h')
      # the same, read in two goes (the boundary appended after a first scan)
      $f = Join-Path $TestDrive "inc-$([guid]::NewGuid().ToString('N')).jsonl"
      [IO.File]::WriteAllText($f, (((Usage '2026-11-13T12:00:00.000Z' 'msg_1'), $main) -join "`n") + "`n")
      $k = [IO.Path]::GetFileNameWithoutExtension($f)
      (Update-Scan (Get-Item -LiteralPath $f) $k).LastCompactPostTokens | Should -Be 51232
      [IO.File]::AppendAllText($f, $Line + "`n")
      $script:ScanVerified = @{}
      (Update-Scan (Get-Item -LiteralPath $f) $k).LastCompactPostTokens | Should -Be $Want
    } finally { $script:EntryReader = $keep }
  }
  It 'prices RECACHE at the compaction''s own size after an ignored boundary, in the row and its hover' {
    $keepPricing = $script:Pricing
    $script:Pricing = @(@{ Match = '^claude-opus-5-5$'; In = 4; W5 = 5; W1h = 8; Read = 0.2; Out = 20 })
    try {
      $script:TailCache = @{}
      $main = '{"type":"system","subtype":"compact_boundary","timestamp":"2026-11-13T12:05:00Z","compactMetadata":{"trigger":"auto","postTokens":51232}}'
      $side = '{"type":"system","subtype":"compact_boundary","timestamp":"2026-11-13T12:05:01Z","compactMetadata":{"trigger":"auto","postTokens":90000},"isSidechain":true}'
      $f = Join-Path $TestDrive "la-$([guid]::NewGuid().ToString('N')).jsonl"
      [IO.File]::WriteAllText($f, (((Usage '2026-11-13T12:00:00.000Z' 'msg_1'), $main, $side) -join "`n") + "`n")
      $a = Get-LastAction (Get-Item -LiteralPath $f) ([guid]::NewGuid().ToString())
      $c = Get-CacheState $a (At '2026-11-13T12:06:00Z')
      Format-CacheCost $c (Get-PriceModel $a) | Should -Be '$0.41'
      $r = [pscustomobject]@{ NAME = 'n'; _Act = $a; _Cache = $c; RECACHE = '' }
      (Get-HoverParts $r 'RECACHE').Value | Should -Be '$0.41 to write 51K tokens back into the cache (1h)'
    } finally { $script:Pricing = $keepPricing }
  }
  It 'does not reuse a scan saved at ScanVer 9, where an ignored boundary could set the compaction''s size' {
    $now = [int]($ctopAst.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:ScanVer' }, $false).Right.Extent.Text)
    $now | Should -BeGreaterThan 9
    $script:CacheDays = 2; $script:PriceVer = 2; $script:ScanVer = $now
    $script:ScanCachePath = Join-Path $TestDrive "sc-$([guid]::NewGuid().ToString('N')).json"
    $e = @{ Path = '/a.jsonl'; Head = 'h'; Used = (Get-Date).ToUniversalTime().Ticks; PriceVer = 2; ScanVer = 9; ToolCounts = @{}; LastCompactPostTokens = 90000 }
    [IO.File]::WriteAllText($script:ScanCachePath, (@{ k = $e } | ConvertTo-Json -Depth 5))
    $script:ScanCache = @{}
    Load-ScanCache
    $script:ScanCache.ContainsKey('k') | Should -BeFalse
  }
  It 'has no anchor for a new call with no time and no request before it, as the extension' {
    $noTime = (Usage '' 'msg_2' -w1h 0 -w5 200).Replace('"timestamp":"",', '')
    $st = Scan @((Usage '2026-11-13T12:00:00.000Z' 'msg_1'), $noTime)
    $st.CacheAnchorId, $st.CacheTtl, $st.CacheAnchor | Should -Be @('msg_2', '5m', '')
    (Get-CacheState $st (At '2026-11-13T12:01:00Z')).Kind | Should -Be 'unknown' -Because 'the 12:00 anchor was msg_1''s'
  }
  It 'reads on past a call whose prompt adds up past the largest long' {
    $big = Usage '2026-11-13T12:00:00.000Z' 'msg_1' -in 5000000000000000000 -cr 5000000000000000000
    $prompt = '{"type":"user","timestamp":"2026-11-13T12:01:00.000Z","message":{"role":"user","content":"a prompt after it"}}'
    $st = Scan @($big, $prompt)
    $st.Turns | Should -Be 1 -Because 'the line after it is read'
    $st.RecacheTok | Should -Be ([long]::MaxValue)
    (Get-CacheState $st (At '2026-11-13T12:02:00Z')).Kind | Should -Be 'warm'
  }
  # a call's 5-minute writes (its cache writes less its 1-hour ones) through [math]::Max as an Int32 would throw
  # past 2^31-1 once the offset had moved on, and the lines after it would be lost
  It 'reads on past, and prices, a call whose <Name>' -ForEach @(
    @{ Name = '5-minute writes pass the largest Int32'; In = 0; Cr = 0; Cw = 2147683648; Want = 10739.01834 }
    @{ Name = 'reads and writes each pass the largest Int32 many times'; In = 0; Cr = 5000000000000000000; Cw = 5000000000000000000; Want = 26000000000000.6 }
    @{ Name = 'counts cancel to a prompt in range'; In = 5000000000000000000; Cr = 5000000000000000000; Cw = -9000000000000000000; Want = 21000000000001.6 }
  ) {
    $script:Pricing = @(@{ Match = 'opus-5-5'; In = 4; W5 = 5; W1h = 8; Read = 0.2; Out = 20 })
    try {
      $call = Usage '2026-11-13T12:00:00.000Z' 'msg_1' -in $In -cr $Cr -cw $Cw -w1h 200000
      $prompt = '{"type":"user","timestamp":"2026-11-13T12:01:00.000Z","message":{"role":"user","content":"a prompt after it"}}'
      $st = Scan @($call, $prompt)
      $st.Turns | Should -Be 1 -Because 'the line after it is read'
      $st.Cost | Should -BeGreaterThan ($Want * 0.999999) -Because 'the call is priced'
      $st.Cost | Should -BeLessThan ($Want * 1.000001)
    } finally { $script:Pricing = $null }
  }
  # the 5-minute writes as cache writes less 1-hour writes, taken as two doubles, round apart past 2^53: a
  # one-token remainder would be priced as 0 or 2 tokens. $1 a 5-minute token, nothing else.
  It 'prices a one-token 5-minute remainder as one token when <Name>, on both readers' -ForEach @(
    @{ Name = 'the writes are one past 2^53'; Cw = 9007199254740993; H = 9007199254740992 }
    @{ Name = 'the doubles round the writes up'; Cw = 9007199254740995; H = 9007199254740994 }
    @{ Name = 'the writes are the largest long'; Cw = [long]::MaxValue; H = [long]::MaxValue - 1 }
  ) {
    $script:Pricing = @(@{ Match = 'opus-5-5'; In = 0; W5 = 1000000; W1h = 0; Read = 0; Out = 0 })
    $keep = $script:EntryReader
    try {
      foreach ($reader in 'cs', 'rx') {
        $script:EntryReader = $reader
        if ($reader -eq 'cs' -and -not (Import-JsonType)) { continue }
        $prompt = '{"type":"user","timestamp":"2026-11-13T12:01:00.000Z","message":{"role":"user","content":"a prompt after it"}}'
        $st = Scan @((Usage '2026-11-13T12:00:00.000Z' 'msg_1' -cw $Cw -w1h $H), $prompt)
        $st.Cost | Should -Be 1.0 -Because "$reader reader: $Cw - $H is one 5-minute token"
        $st.Turns | Should -Be 1
      }
    } finally { $script:Pricing = $null; $script:EntryReader = $keep }
  }
  # CTX's tail read too: casting a count no long holds would throw under -ErrorAction Stop
  It 'shows CTX without the count no long holds, under -ErrorAction Stop, <Name>' -ForEach @(
    @{ Name = 'on the newest call'; Synthetic = $false }
    @{ Name = 'behind a synthetic entry'; Synthetic = $true }
  ) {
    $script:ScanCache = @{}; $script:ScanVerified = @{}; $script:TailCache = @{}
    $f = Join-Path $TestDrive "ctx-$([guid]::NewGuid().ToString('N')).jsonl"
    $lines = @('{"type":"assistant","timestamp":"2026-11-13T12:00:00.000Z","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":12000,"cache_read_input_tokens":0,"cache_creation_input_tokens":9223372036854775808},"content":[{"type":"text","text":"reply"}]}}')
    if ($Synthetic) { $lines += '{"type":"assistant","timestamp":"2026-11-13T12:00:30.000Z","message":{"model":"<synthetic>","usage":{"input_tokens":0},"content":[{"type":"text","text":"notice"}]}}' }
    [IO.File]::WriteAllText($f, ($lines -join "`n") + "`n")
    $keep = $ErrorActionPreference
    $ErrorActionPreference = 'Stop'
    try { $act = Get-LastAction (Get-Item -LiteralPath $f) 'ctx' } finally { $ErrorActionPreference = $keep }
    $act.Ctx | Should -Be 12
  }
  # the extension reads a time with Date.parse, to the millisecond
  It 'reads <Name> as the extension does' -ForEach @(
    @{ Name = 'a compaction and a reply in the same millisecond: compacted'; Second = 'boundary'; At = '2026-11-13T12:02:00.0000001Z'; Third = '2026-11-13T12:02:00.0000002Z'; Want = 'cold' }
    @{ Name = 'a compaction at a time of day alone: no mark'; Second = 'boundary'; At = '12:05'; Third = ''; Want = 'warm' }
    @{ Name = 'a new call at a time of day alone: no anchor'; Second = 'call'; At = '12:05'; Third = ''; Want = 'unknown' }
  ) {
    $lines = @(Usage '2026-11-13T12:00:00.000Z' 'msg_1')
    $lines += if ($Second -eq 'boundary') { '{"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"auto","preTokens":70},"timestamp":"' + $At + '"}' } else { Usage $At 'msg_2' -w1h 0 -w5 200 }
    if ($Third) { $lines += Usage $Third 'msg_2' }
    (Get-CacheState (Scan $lines) (At '2026-11-13T12:04:00Z')).Kind | Should -Be $Want
  }
}

# The extension parses a time with JavaScript's Date.parse (kE in webview/index.js, 2.1.330). ctop reads only the
# shape Claude Code writes (2026-11-13T12:00:00.000Z): a whole date and time with seconds, an optional fraction, and
# Z or +hh:mm. Each value read here is what Date.parse gave in Node 24 (V8 13.6), 2026-11-23. Everything else is no
# time, including forms V8 reads (D22): a wider grammar reads some of them differently from V8.
Describe 'ConvertFrom-CacheTime: the one shape Claude Code writes, to the millisecond' {
  It 'reads <Ts> as <Want>' -ForEach @(
    @{ Ts = '2026-11-13T12:00:00.000Z';         Want = '2026-11-13T12:00:00.000Z' }
    @{ Ts = '2026-11-13T12:02:00.0000001Z';     Want = '2026-11-13T12:02:00.000Z' }
    @{ Ts = '2026-11-13T12:02:00.9999999Z';     Want = '2026-11-13T12:02:00.999Z' }
    @{ Ts = '2026-11-13T12:00:00.12345678901234567890Z'; Want = '2026-11-13T12:00:00.123Z' }
    @{ Ts = '2026-11-13T12:00:00.5Z';           Want = '2026-11-13T12:00:00.500Z' }
    @{ Ts = '2026-11-13T12:00:00Z';             Want = '2026-11-13T12:00:00.000Z' }
    @{ Ts = '2026-11-13T12:00:00.000+05:30';    Want = '2026-11-13T06:30:00.000Z' }
    @{ Ts = '2026-11-13T12:00:00+23:59';        Want = '2026-11-12T12:01:00.000Z' }
    @{ Ts = '2026-11-13T12:00:00-00:00';        Want = '2026-11-13T12:00:00.000Z' }
    # the hour a DST change folds, written with its offset: one instant each
    @{ Ts = '2026-11-01T01:30:00-07:00';        Want = '2026-11-01T08:30:00.000Z' }
    @{ Ts = '2026-11-01T01:30:00-08:00';        Want = '2026-11-01T09:30:00.000Z' }
    @{ Ts = '2024-02-29T12:00:00Z';             Want = '2024-02-29T12:00:00.000Z' }
    @{ Ts = '0001-01-01T00:00:00Z';             Want = '0001-01-01T00:00:00.000Z' }
    @{ Ts = '9999-12-31T23:59:59.999Z';         Want = '9999-12-31T23:59:59.999Z' }
  ) {
    (ConvertFrom-CacheTime $Ts).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture) | Should -Be $Want
  }
  It 'reads no time from <_>' -ForEach @('12:05', 'not a time', ' 2026-11-13T12:00:00Z', '2026-11-13T12:00:00Z ', '2026-11-13T24:00:01Z',
      '2026-11-13T24:00:00.001Z', '2026-11-13T12:00:00.Z', '2026-13-01T00:00:00Z', '2026-11-32T00:00:00Z', '2026-11-00', '2026-00-10',
      '2026-11-13T12:60:00Z', '2026-11-13T12:00:60Z', '2026-11-13T12Z', '2026-11-13T1:00:00Z', '2026-11-13+01:00', '2026-11-13T12:00:00+01',
      '2026-11-13T12:00:00+24:00', '2026-11-13T12:00:00,5Z', '2026-11-13T12:00:00 Z', '2026-11-13T12:00:00.000ZZ', '-000000-01-01T00:00:00Z',
      # forms V8 reads and ctop does not (D22): no seconds, a date alone, other separators, a zone in lowercase or
      # without its colon, 24:00, a day past the month's end, a six-digit year, and no zone at all
      '2026-11-13T12:00Z', '2026-11-13', '2026-11', '2026', '2026-11-13Z', '2026-11-13t12:00:00Z', '2026-11-13 12:00:00Z', '2026-11-13T12:00:00z',
      '2026-11-13T12:00:00+0100', '2026-11-13T24:00:00Z', '2026-11-31T00:00:00Z', '2026-02-29T12:00:00Z', '+002026-11-13T12:00:00Z',
      '0000-01-01T12:00:00Z', '2026-11-13T12:00:00', '2026-11-13T12:00:00.9999999', '2026-11-01T01:30:00',
      # a final newline (a $ anchor would match before it), a fraction past 24:00, UTC outside .NET's range
      "2026-11-01T09:30:00Z`n", "2026-11-01T09:30:00Z`r`n", '2026-11-13T24:00:00.0001Z', '0001-01-01T00:00:00+00:01',
      '9999-12-31T23:59:59.999-00:01', ([string][char]0xFF12 + '026-11-13T12:00:00Z')) {
    ConvertFrom-CacheTime $_ | Should -BeNullOrEmpty
  }
  It 'gives no anchor for a call at a local time the DST change folds, where V8 and .NET pick different hours' {
    $st = Scan @(Usage '2026-11-01T01:30:00.000' 'msg_1' -w1h 0 -w5 200)
    $st.CacheAnchor | Should -Be ''
    (Get-CacheState $st (At '2026-11-01T09:33:00Z')).Kind | Should -Be 'unknown'
  }
}

# On PowerShell 7 a cache time can change at a JSON boundary: ConvertFrom-Json makes a zone-less time a DateTime,
# which Load-ScanCache would take as UTC where the scan read local time (a warm cache cold after a restart, a
# compaction eight hours off), and the regex reader's unescaping would make an escaped timestamp a DateTime, then
# culture text: no anchor, request or compaction.
Describe 'cache times through a save, a load and an append' {
  BeforeAll {
    $script:Next = '{"type":"assistant","timestamp":"2026-11-13T20:01:00Z","message":{"id":"m2","model":"claude-opus-5-5","usage":{"input_tokens":2,"cache_creation_input_tokens":3,"cache_creation":{"ephemeral_5m_input_tokens":3}}}}'
    function Shape($st) {
      $c = Get-CacheState $st (At '2026-11-13T20:04:00Z')
      "$($c.Kind)|$($c.Reason)|$($c.MsLeft)|$($c.IdleMs)|$(if ($c.Anchor) { $c.Anchor.ToString('o') })"
    }
    function Readers { 'rx'; if (Import-JsonType) { 'cs' } }
  }
  BeforeEach { $script:CacheDays = 2; $script:PriceVer = 2; $script:ScanVer = 6; $script:KeepReader = $script:EntryReader }
  AfterEach { $script:EntryReader = $script:KeepReader }
  It 'resumes a <Role> written <Label> at the instant a fresh scan reads' -ForEach @(
    foreach ($s in @(@{ Label = 'in UTC to 7 digits'; Text = '2026-11-13T20:00:00.9999999Z' }, @{ Label = 'with an offset'; Text = '2026-11-13T12:00:00.9999999-08:00' },
                     @{ Label = 'with no zone'; Text = '2026-11-13T12:00:00.9999999' }, @{ Label = 'with an escaped Z'; Text = '2026-11-13T20:00:00.9999999\u005a' },
                     @{ Label = 'with an escaped digit'; Text = '2026-11-13T20:00:00.999999\u0039Z' })) {
      foreach ($role in 'anchor', 'compaction', 'compaction then a call', 'request then a call') { @{ Label = $s.Label; Text = $s.Text; Role = $role } }
    }
  ) {
    Mock Move-Over { [IO.File]::Copy($src, $dst, $true); [IO.File]::Delete($src) }
    foreach ($reader in Readers) {
      $script:EntryReader = $reader
      $script:ScanCachePath = Join-Path $TestDrive "sc-$([guid]::NewGuid().ToString('N')).json"
      $f = Join-Path $TestDrive "r7e-$([guid]::NewGuid().ToString('N')).jsonl"
      $line = switch -Wildcard ($Role) {
        'anchor'      { $script:Next.Replace('2026-11-13T20:01:00Z', $Text) }
        'compaction*' { '{"type":"system","subtype":"compact_boundary","timestamp":"' + $Text + '"}' }
        'request*'    { '{"type":"user","timestamp":"' + $Text + '","message":{"content":"new request"}}' }
      }
      [IO.File]::WriteAllText($f, $line + "`n")
      $script:ScanCache = @{}; $script:ScanVerified = @{}
      $null = Update-Scan (Get-Item -LiteralPath $f) 'date'
      Save-ScanCache
      $script:ScanCache = @{}; $script:ScanVerified = @{}
      Load-ScanCache
      $script:ScanCache.ContainsKey('date') | Should -BeTrue -Because 'the saved state is loaded, and resumed'
      if ($Role -eq 'request then a call') { [IO.File]::AppendAllText($f, $script:Next + "`n") }
      if ($Role -eq 'compaction then a call') { [IO.File]::AppendAllText($f, $script:Next.Replace('20:01:00Z', '19:59:30Z') + "`n") }
      $resumed = Shape (Update-Scan (Get-Item -LiteralPath $f) 'date')
      $script:ScanCache = @{}; $script:ScanVerified = @{}
      $fresh = Shape (Update-Scan (Get-Item -LiteralPath $f) 'date')
      $resumed | Should -Be $fresh -Because "$reader reader"
    }
  }
  It 'reads an escaped timestamp as the time it spells, on both readers' {
    foreach ($reader in Readers) {
      $script:EntryReader = $reader
      foreach ($ts in '2026-11-13T20:00:00.9999999\u005a', '2026-11-13T20:00:00.999999\u0039Z') {
        $st = Scan @($script:Next.Replace('2026-11-13T20:01:00Z', $ts))
        ConvertFrom-CacheTime $st.CacheAnchor | Should -Be (At '2026-11-13T20:00:00.999Z') -Because "$reader reader, $ts"
        $st = Scan @('{"type":"system","subtype":"compact_boundary","timestamp":"' + $ts + '"}')
        ConvertFrom-CacheTime $st.CacheCompactAt | Should -Be (At '2026-11-13T20:00:00.999Z') -Because "$reader reader, $ts"
      }
    }
  }
  It 'decodes a JSON string''s escapes and leaves a date as its text, for every caller' {
    Unescape-Json '2026-11-13T20:00:00\u005a' | Should -BeExactly '2026-11-13T20:00:00Z'
    Unescape-Json 'C:\\x\u00e9\"q\"\/\n' | Should -BeExactly "C:\xé`"q`"/`n"
    Unescape-Json 'no escapes' | Should -BeExactly 'no escapes'
    Unescape-Json 'bad \x escape' | Should -BeExactly 'bad \x escape'
    Unescape-Json '\ud83d\ude00' | Should -BeExactly ([char]::ConvertFromUtf32(0x1F600))
  }
}

# Witness lines, byte for byte: each is one assistant entry whose
# tool_use input holds look-alikes of entry fields, or whose own fields are in another order. Only the entry's
# own fields count: its type, isSidechain and timestamp, and its message's model, id and usage.
Describe 'Update-Scan: an entry is read from its own fields, never from a tool input' {
  BeforeEach { $script:ScanCache = @{}; $script:ScanVerified = @{} }
  It '<Name>' -ForEach @(
    # message.id before model
    @{ Name = 'baseline'; Want = 'H'; Line = '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"ok":1}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' }
    @{ Name = 'nested_sidechain'; Want = 'H'; Line = '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"isSidechain":true}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' }
    @{ Name = 'nested_synthetic'; Want = 'H'; Line = '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"model":"<synthetic>"}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' }
    @{ Name = 'nested_usage'; Want = 'H'; Line = '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"usage":{"input_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0},"output_tokens":0}}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' }
    @{ Name = 'nested_user_type'; Want = 'H'; Line = '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"type":"user"}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' }
    # model-first messages
    @{ Name = 'canonical_baseline'; Want = 'H'; Line = '{"parentUuid":"p","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"ok":1}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' }
    @{ Name = 'canonical_nested_ai_title'; Want = 'H'; Line = '{"parentUuid":"p","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"type":"ai-title","aiTitle":"metadata"}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' }
    @{ Name = 'canonical_nested_compact'; Want = 'H'; Line = '{"parentUuid":"p","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"type":"system","subtype":"compact_boundary","timestamp":"2025-01-01T00:00:00Z"}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' }
    @{ Name = 'canonical_nested_custom_title'; Want = 'H'; Line = '{"parentUuid":"p","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"type":"custom-title","customTitle":"metadata"}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' }
    @{ Name = 'canonical_nested_sidechain'; Want = 'H'; Line = '{"parentUuid":"p","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"isSidechain":true}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' }
    @{ Name = 'canonical_nested_summary'; Want = 'H'; Line = '{"parentUuid":"p","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"type":"summary","summary":"metadata"}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' }
    @{ Name = 'canonical_nested_synthetic'; Want = 'H'; Line = '{"parentUuid":"p","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"message":{"model":"<synthetic>"},"model":"<synthetic>"}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' }
    @{ Name = 'canonical_nested_usage'; Want = 'H'; Line = '{"parentUuid":"p","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"usage":{"input_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0},"output_tokens":0}}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' }
    @{ Name = 'canonical_nested_user_type'; Want = 'H'; Line = '{"parentUuid":"p","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"type":"user","role":"user"}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' }
    # fields missing, after the message, or in another order
    @{ Name = 'id_first_user_type'; Want = 'H'; Line = '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"type":"user","role":"user"}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' }
    @{ Name = 'role_first_user_type'; Want = 'H'; Line = '{"parentUuid":"p","isSidechain":false,"message":{"role":"assistant","model":"claude-opus-5-5","id":"msg_1","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"type":"user","role":"user"}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' }
    @{ Name = 'missing_side_flag'; Want = 'H'; Line = '{"parentUuid":"p","message":{"model":"claude-opus-5-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"isSidechain":true}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' }
    @{ Name = 'side_flag_after_message'; Want = 'H'; Line = '{"parentUuid":"p","message":{"model":"claude-opus-5-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"isSidechain":true}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z","isSidechain":false}' }
    @{ Name = 'object_prefix_before_side_flag'; Want = 'H'; Line = '{"metadata":{"v":1},"parentUuid":"p","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"isSidechain":true}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' }
    @{ Name = 'usage_precedes_content'; Want = 'H'; Line = '{"parentUuid":"p","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_1","type":"message","role":"assistant","usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5},"content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"usage":{"input_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0},"output_tokens":0}}}]},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' }
    @{ Name = 'usage_only_inside_tool'; Want = 'U'; Line = '{"parentUuid":"p","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"usage":{"input_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0},"output_tokens":0}}}]},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' }
    @{ Name = 'positive_usage_only_inside_tool'; Want = 'U'; Line = '{"parentUuid":"p","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}}}]},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' }
  ) {
    $st = Scan @($Line)
    # H: the call's own cache frame (1h, 1203 tokens, at its timestamp); U: no frame (no usage of its own)
    if ($Want -eq 'H') {
      $st.CacheTtl | Should -Be '1h'
      $st.RecacheTok | Should -Be 1203
      (At $st.CacheAnchor) | Should -Be (At '2026-11-13T12:00:00.000Z')
      $st.InTok, $st.CacheR, $st.CacheW, $st.OutTok | Should -Be @(3, 1000, 200, 5)
    } else {
      $st.CacheTtl | Should -Be ''
      $st.RecacheTok | Should -Be 0
      $st.CacheAnchor | Should -Be ''
      $st.InTok, $st.CacheR, $st.CacheW, $st.OutTok | Should -Be @(0, 0, 0, 0)
    }
    $st.CacheCompactAt | Should -Be ''
    $st.Compacts | Should -Be 0
    $st.Turns | Should -Be 0
    $st.AiTitle, $st.Summary, $st.Title | Should -Be @('', '', '')
    $st.Model | Should -Be 'claude-opus-5-5'
    $st.Tools | Should -Be 1
    @($st.ToolCounts.Keys) | Should -Be @('X')
  }
  It 'counts the tool calls of the message, not look-alikes inside one''s input' {
    $line = '{"type":"assistant","timestamp":"2026-11-13T12:00:00.000Z","message":{"model":"claude-opus-5-5","id":"msg_1","content":[{"type":"tool_use","id":"t1","name":"Write","input":{"file_path":"a.jsonl","x":{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"ls"}},"y":{"name":"SendMessage","input":{"summary":"not mine"}}}}],"usage":{"input_tokens":3,"output_tokens":5}}}'
    $st = Scan @($line)
    $st.Tools | Should -Be 1
    @($st.ToolCounts.Keys) | Should -Be @('Write')
    @($st.ToolLog).Count | Should -Be 0
    $st.MsgSummary | Should -Be ''
  }
  It 'reads the tool calls of a message: names, Bash times, the first SendMessage summary' {
    $line = '{"type":"assistant","timestamp":"2026-11-13T12:00:00.000Z","message":{"model":"claude-opus-5-5","id":"msg_1","content":[{"type":"text","text":"ok"},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}},{"type":"tool_use","id":"t2","name":"SendMessage","input":{"to":"a","summary":"the \"plan\"","message":"m"}}],"usage":{"input_tokens":3,"output_tokens":5}}}'
    $st = Scan @($line)
    $st.Tools | Should -Be 2
    $st.ToolCounts.Bash | Should -Be 1
    $st.ToolCounts.SendMessage | Should -Be 1
    @($st.ToolLog).Count | Should -Be 1
    $st.ToolLog[0].At | Should -Be '2026-11-13T12:00:00.000Z'
    $st.MsgSummary | Should -BeExactly 'the "plan"'
  }
  It 'takes the cwd and branch of the entry, not of a tool input' {
    $line = '{"type":"assistant","message":{"model":"claude-opus-5-5","id":"msg_1","content":[{"type":"tool_use","id":"t1","name":"X","input":{"cwd":"C:\\evil","sessionId":"s","version":"1","gitBranch":"evil"}}],"usage":{"input_tokens":3,"output_tokens":5}},"uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z","cwd":"C:\\dev\\real","sessionId":"s","version":"2.1.323","gitBranch":"main"}'
    $st = Scan @($line)
    $st.Cwd | Should -BeExactly 'C:\dev\real'
    $st.GitBranch | Should -BeExactly 'main'
  }
  It 'takes the cwd and branch of the newest entry that has them, of any kind' {
    $user = '{"type":"user","timestamp":"2026-11-13T12:00:00.000Z","message":{"role":"user","content":"a prompt here"},"cwd":"C:\\a","sessionId":"s","version":"1","gitBranch":"main"}'
    $att = '{"type":"attachment","attachment":{"type":"x"},"timestamp":"2026-11-13T12:00:01.000Z","cwd":"C:\\b","sessionId":"s"}'
    $reply = '{"type":"assistant","timestamp":"2026-11-13T12:00:02.000Z","message":{"model":"m","id":"msg_1","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":1,"output_tokens":1}},"cwd":"C:\\c","sessionId":"s","gitBranch":"wt"}'
    $st = Scan @($user, $att)
    $st.Cwd, $st.GitBranch | Should -Be @('C:\b', 'main')
    $st = Scan @($user, $att, $reply)
    $st.Cwd, $st.GitBranch | Should -Be @('C:\c', 'wt')
    $st = Scan @($reply, $user, $att, '{"type":"queue-operation","operation":"x","timestamp":"2026-11-13T12:00:03.000Z"}')
    $st.Cwd, $st.GitBranch | Should -Be @('C:\b', 'main')
  }
  It 'counts no turn for a user message nested in another kind of entry' {
    $line = '{"type":"progress","data":{"message":{"type":"user","message":{"role":"user","content":"a nested prompt text"}}},"uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}'
    $st = Scan @($line)
    $st.Turns | Should -Be 0
    $st.First | Should -Be ''
  }
  It 'reads the first line of a file that starts with a byte-order mark (Windows PowerShell 5.1''s -Encoding utf8)' {
    $f = Join-Path $TestDrive "bom-$([guid]::NewGuid().ToString('N')).jsonl"
    [IO.File]::WriteAllText($f, '{"type":"user","timestamp":"2026-11-13T12:00:00.000Z","message":{"role":"user","content":"the first prompt"}}' + "`n", [Text.UTF8Encoding]::new($true))
    $st = Update-Scan (Get-Item -LiteralPath $f) ([IO.Path]::GetFileNameWithoutExtension($f))
    $st.Turns | Should -Be 1
    $st.First | Should -Be 'the first prompt'
  }
  It 'reads nothing from a line that is not one whole JSON object' {
    $cut = '{"type":"user","message":{"role":"user","content":"a prompt cut short in the middle'
    $st = Scan @($cut, '{"type":"user","timestamp":"2026-11-13T12:00:00.000Z","message":{"role":"user","content":"the whole prompt"}}')
    $st.Turns | Should -Be 1
    $st.First | Should -Be 'the whole prompt'
  }
  It 'reads a compaction, a title and a summary from their own entries' {
    $st = Scan @(
      '{"parentUuid":null,"isSidechain":false,"type":"system","subtype":"compact_boundary","content":"Conversation compacted","compactMetadata":{"trigger":"auto","preTokens":280717,"postTokens":51232},"uuid":"29639f6d-8c13-42d3-8002-5fef46a4d835","timestamp":"2026-11-14T02:15:54.010Z","cwd":"c:\\dev\\src\\ctop","sessionId":"s","version":"2.1.323","gitBranch":"b"}'
      '{"type":"ai-title","sessionId":"s","aiTitle":"An \"AI\" title"}'
      '{"type":"custom-title","customTitle":"Mine","sessionId":"s"}'
      '{"type":"summary","summary":"What happened","leafUuid":"u"}'
    )
    $st.Compacts | Should -Be 1
    $st.LastCompactTrigger | Should -Be 'auto'
    $st.LastCompactPreTokens | Should -Be 280717
    (At $st.CacheCompactAt) | Should -Be (At '2026-11-14T02:15:54.010Z')
    $st.LastCompactAt.ToUniversalTime() | Should -Be (At '2026-11-14T02:15:54.010Z')
    $st.AiTitle | Should -BeExactly 'An "AI" title'
    $st.Title | Should -BeExactly 'Mine'
    $st.Summary | Should -BeExactly 'What happened'
    $st.Cwd | Should -BeExactly 'c:\dev\src\ctop'
  }
  It 'reads a message that does not start with its model (Claude Code writes diagnostics first on some)' {
    $line = '{"parentUuid":"p","isSidechain":false,"type":"assistant","uuid":"b3e50dfa-7eef-40f6-a2e6-27256ef30667","timestamp":"2026-11-13T12:00:00.000Z","message":{"diagnostics":null,"id":"msg_1","container":null,"model":"claude-opus-5-5","role":"assistant","type":"message","usage":{"output_tokens_details":null,"input_tokens":3,"output_tokens":5,"cache_creation_input_tokens":200,"cache_read_input_tokens":1000,"server_tool_use":{"web_search_requests":0},"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0}},"content":[{"type":"text","text":"hi"}]},"cwd":"c:\\x","sessionId":"s"}'
    $st = Scan @($line)
    $st.Model | Should -Be 'claude-opus-5-5'
    $st.CacheTtl | Should -Be '1h'
    $st.RecacheTok | Should -Be 1203
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
  It 'stands between STATE and TURN' {
    $src = Get-Content -Raw (Join-Path (Split-Path -Parent $PSScriptRoot) 'ctop.ps1')
    $at = @('STATE', 'CACHE', 'TURN' | ForEach-Object { $src.IndexOf("@{ Name = '$_';") })
    $at[0] | Should -BeLessThan $at[1]
    $at[1] | Should -BeLessThan $at[2]
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
  It 'sorts gone sessions by the cache too, after the live ones' {
    $script:SortModes = @('activity', 'roster', 'start', 'cost', 'ctx', 'cache')
    $script:SortMode = 5
    function GoneRow([string]$id, $cache, [int]$goneMin) {
      [pscustomobject]@{ _SessionId = $id; _Gone = (Get-Date).AddMinutes(-$goneMin); _StartedAt = [datetime]'2026-11-13T10:00:00'; STATE = 'gone'
                         NAME = $id; PID = '-'; _Parent = $null; _LaunchedBy = $null; _Spawner = ''; _Order = 0; _Depth = 0
                         _Act = @{ Cost = 0.0; Ctx = '-' }; _AgentCost = 0.0; _Cache = $cache }
    }
    $now = [datetime]::UtcNow
    $rows = @(
      (GoneRow 'unknown' @{ Kind = 'unknown' } 1)
      (GoneRow 'cold' @{ Kind = 'cold'; Reason = 'expired' } 2)
      (GoneRow 'warm30' @{ Kind = 'warm'; Ttl = '1h'; MsLeft = 1800000.0; Anchor = $now.AddMinutes(-30) } 3)
      (GoneRow 'warm1' @{ Kind = 'warm'; Ttl = '1h'; MsLeft = 60000.0; Anchor = $now.AddMinutes(-59) } 4)
    )
    @(Sort-Rows $rows | ForEach-Object { $_._SessionId }) | Should -Be @('warm1', 'warm30', 'cold', 'unknown')
  }
  # the rows share one clock: if each row's key read its own, two rows with one deadline would get different keys
  # and swap places from one frame to the next
  It 'keeps <Cohort> rows with the same deadline in one order, sort after sort' -ForEach @(@{ Cohort = 'live' }, @{ Cohort = 'gone' }) {
    $script:SortModes = @('activity', 'roster', 'start', 'cost', 'ctx', 'cache')
    $script:SortMode = 5
    $now = [datetime]::UtcNow; $anchor = $now.AddMinutes(-30); $gone = $now.AddMinutes(-1)
    $rows = @(foreach ($id in 'a', 'b') {
      [pscustomobject]@{ _SessionId = $id; _Gone = $(if ($Cohort -eq 'gone') { $gone } else { $null }); _StartedAt = $now.AddHours(-4); STATE = 'idle'
                         NAME = $id; PID = '-'; _Parent = $null; _LaunchedBy = $null; _Spawner = ''; _Order = 0; _Depth = 0
                         _Act = @{ Cost = 0.0; Ctx = '-' }; _AgentCost = 0.0; _Cache = @{ Kind = 'warm'; Ttl = '1h'; Anchor = $anchor; MsLeft = 1800000 } }
    })
    $orders = @(for ($i = 0; $i -lt 64; $i++) { $rows = @(Sort-Rows $rows); @($rows | ForEach-Object { $_._SessionId }) -join ',' })
    @($orders | Select-Object -Unique) | Should -Be @('a,b')
  }
  It 'sorts gone sessions in <Mode> by the mode''s key, then most recently gone, then id' -ForEach @(
    @{ Mode = 'cost'; Want = @('big', 'mid-new', 'mid-old-a', 'mid-old-b', 'zero') }
    @{ Mode = 'ctx';  Want = @('big', 'mid-new', 'mid-old-a', 'mid-old-b', 'zero') }
  ) {
    $script:SortModes = @('activity', 'roster', 'start', 'cost', 'ctx', 'cache')
    $script:SortMode = [array]::IndexOf($script:SortModes, $Mode)
    $now = Get-Date
    function GoneRow([string]$id, [double]$v, [int]$goneMin) {
      [pscustomobject]@{ _SessionId = $id; _Gone = $now.AddMinutes(-$goneMin); _StartedAt = [datetime]'2026-11-13T10:00:00'; STATE = 'gone'
                         NAME = $id; PID = '-'; _Parent = $null; _LaunchedBy = $null; _Spawner = ''; _Order = 0; _Depth = 0
                         _Act = @{ Cost = $v; Ctx = $(if ($v) { $v } else { '-' }) }; _AgentCost = 0.0; _Cache = $null }
    }
    $rows = @((GoneRow 'zero' 0 1), (GoneRow 'mid-old-b' 2.5 9), (GoneRow 'big' 40 5), (GoneRow 'mid-old-a' 2.5 9), (GoneRow 'mid-new' 2.5 2))
    @(Sort-Rows $rows | ForEach-Object { $_._SessionId }) | Should -Be $Want
  }
  It 'sorts by the time left now, not when the row was built' {
    $script:SortModes = @('activity', 'roster', 'start', 'cost', 'ctx', 'cache')
    $script:SortMode = 5
    function Row([string]$id, $cache) {
      [pscustomobject]@{ _SessionId = $id; _Gone = $null; _StartedAt = [datetime]'2026-11-13T10:00:00'; STATE = 'idle'
                         NAME = $id; PID = '-'; _Parent = $null; _LaunchedBy = $null; _Spawner = ''; _Order = 0; _Depth = 0
                         _Act = @{ Cost = 0.0; Ctx = '-' }; _AgentCost = 0.0; _Cache = $cache }
    }
    $now = [datetime]::UtcNow
    $rows = @(
      (Row 'stale' @{ Kind = 'warm'; Ttl = '1h'; MsLeft = 60000.0; Anchor = $now.AddHours(-2) })   # built when 1 min was left
      (Row 'w30' @{ Kind = 'warm'; Ttl = '1h'; MsLeft = 1800000.0; Anchor = $now.AddMinutes(-30) })
      (Row 'unknown' @{ Kind = 'unknown' })
    )
    @(Sort-Rows $rows | ForEach-Object { $_._SessionId }) | Should -Be @('w30', 'stale', 'unknown')
  }
  It 'sorts an anchor ahead of the clock by the time CACHE shows, at most the TTL' {
    $script:SortModes = @('activity', 'roster', 'start', 'cost', 'ctx', 'cache')
    $script:SortMode = 5
    function Row([string]$id, $cache) {
      [pscustomobject]@{ _SessionId = $id; _Gone = $null; _StartedAt = [datetime]'2026-11-13T10:00:00'; STATE = 'idle'
                         NAME = $id; PID = '-'; _Parent = $null; _LaunchedBy = $null; _Spawner = ''; _Order = 0; _Depth = 0
                         _Act = @{ Cost = 0.0; Ctx = '-' }; _AgentCost = 0.0; _Cache = $cache }
    }
    $now = [datetime]::UtcNow
    $rows = @(
      (Row 'w7' @{ Kind = 'warm'; Ttl = '1h'; MsLeft = 420000.0; Anchor = $now.AddMinutes(-53) })   # shows 7m
      (Row 'skew' @{ Kind = 'warm'; Ttl = '5m'; MsLeft = 300000.0; Anchor = $now.AddMinutes(3) })   # 3 min ahead: shows 5m
    )
    @(Sort-Rows $rows | ForEach-Object { $_._SessionId }) | Should -Be @('skew', 'w7')
  }
  It 'sorts an anchor at the last time .NET has by the 5m CACHE shows' {
    $script:SortModes = @('activity', 'roster', 'start', 'cost', 'ctx', 'cache')
    $script:SortMode = 5
    function Row([string]$id, $cache) {
      [pscustomobject]@{ _SessionId = $id; _Gone = $null; _StartedAt = [datetime]'2026-11-13T10:00:00'; STATE = 'idle'
                         NAME = $id; PID = '-'; _Parent = $null; _LaunchedBy = $null; _Spawner = ''; _Order = 0; _Depth = 0
                         _Act = @{ Cost = 0.0; Ctx = '-' }; _AgentCost = 0.0; _Cache = $cache }
    }
    $now = [datetime]::UtcNow
    $edge = Get-CacheState @{ CacheAnchor = '9999-12-31T23:59:59Z'; CacheTtl = '5m'; RecacheTok = 3 } $now
    Format-CacheCell $edge | Should -Be '5m'
    $w2 = Get-CacheState @{ CacheAnchor = $now.AddMinutes(-3).ToString('o'); CacheTtl = '5m'; RecacheTok = 3 } $now
    $ErrorActionPreference = 'Stop'
    @(Sort-Rows @((Row 'edge' $edge), (Row 'w2' $w2)) | ForEach-Object { $_._SessionId }) | Should -Be @('w2', 'edge')
  }
  It 'redraws a working row once IDLE passes 2 minutes (STATE turns red), with no other cell changed' {
    $cols = @(@{ Name = 'NAME' }, @{ Name = 'STATE' }, @{ Name = 'CACHE' })
    $r = [pscustomobject]@{ NAME = 'a'; STATE = 'working'; CACHE = '40m'; IDLE = '1m'; _Jobs = @(); _Cache = @{ Ttl = '1h' }; _Gone = $null; _Act = @{} }
    $k1 = Row-Key $cols $r 'sig'
    $r.IDLE = '2m'
    Row-Key $cols $r 'sig' | Should -Not -Be $k1
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

Describe 'RECACHE: what the next turn costs once the cache is cold' {
  BeforeAll {
    $script:Pricing = @(@{ Match = '^priced$'; In = 5; Out = 25; Read = 0.5; W5 = 6.25; W1h = 10 })
    $script:Color = $false
    $cols = @([pscustomobject]@{ Name = 'CACHE'; Width = 5; Align = 'R'; Fixed = 5 }, [pscustomobject]@{ Name = 'RECACHE'; Width = 7; Align = 'R'; Fixed = 7 })
    $src = Get-Content -Raw (Join-Path (Split-Path -Parent $PSScriptRoot) 'ctop.ps1')
  }
  It 'is <Want> for <Tok> tokens of a <Ttl> cache' -ForEach @(
    @{ Tok = 220000;  Ttl = '1h'; Want = '$2.20' }    # 220K x $10/MTok
    @{ Tok = 220000;  Ttl = '5m'; Want = '$1.38' }    # 220K x $6.25/MTok
    @{ Tok = 1500000; Ttl = '1h'; Want = '$15' }      # no cents from $10
    @{ Tok = 12000000; Ttl = '1h'; Want = '$120' }
  ) {
    Format-CacheCost @{ Kind = 'warm'; Ttl = $Ttl; RecacheTokens = $Tok } 'priced' | Should -Be $Want
  }
  It 'is the next turn''s cost once expired too' {
    Format-CacheCost @{ Kind = 'cold'; Reason = 'expired'; Ttl = '1h'; RecacheTokens = 220000 } 'priced' | Should -Be '$2.20'
  }
  It 'prices the compacted conversation at the write price of the TTL before the compaction: <Ttl>' -ForEach @(
    @{ Ttl = '1h'; Want = '$0.51' }    # 51,232 x $10/MTok
    @{ Ttl = '5m'; Want = '$0.32' }    # 51,232 x $6.25/MTok
  ) {
    $act = @{ CacheTtl = $Ttl; CacheAnchor = '2026-11-13T12:00:00.000Z'; RecacheTok = 280000; CacheCompactAt = '2026-11-13T12:05:00.000Z'; LastCompactPostTokens = 51232 }
    Format-CacheCost (Get-CacheState $act (At '2026-11-13T12:06:00Z')) 'priced' | Should -Be $Want
  }
  It 'is empty when it can''t be priced or isn''t known: <Name>' -ForEach @(
    @{ Name = 'unpriced model'; State = @{ Kind = 'warm'; Ttl = '1h'; RecacheTokens = 220000 }; Model = 'nobody' }
    @{ Name = 'compacted, no size recorded'; State = @{ Kind = 'cold'; Reason = 'compacted'; Ttl = '1h' }; Model = 'priced' }
    @{ Name = 'compacted, no TTL before it'; State = @{ Kind = 'cold'; Reason = 'compacted'; RecacheTokens = 51232 }; Model = 'priced' }
    @{ Name = 'unknown';        State = @{ Kind = 'unknown' };                                  Model = 'priced' }
    @{ Name = 'no tokens';      State = @{ Kind = 'warm'; Ttl = '1h'; RecacheTokens = 0 };      Model = 'priced' }
  ) {
    Format-CacheCost $State $Model | Should -Be ''
  }
  It 'is a column of its own right after CACHE, 7 wide, right-aligned, hidden just before CACHE' {
    $at = @('CACHE', 'RECACHE', 'TURN' | ForEach-Object { $src.IndexOf("@{ Name = '$_';") })
    $at[1] | Should -BeGreaterThan $at[0]
    $at[1] | Should -BeLessThan $at[2]
    $src | Should -Match "@\{ Name = 'RECACHE';\s+Fixed = 7;\s+Align = 'R'; Priority = 84 \}"
  }
  It 'leaves CACHE one line: the figure is in RECACHE, not under the minutes' {
    $r = [pscustomobject]@{ CACHE = '43m'; RECACHE = '$2.20'; _Cache = @{ Kind = 'warm'; Ttl = '1h'; RecacheTokens = 220000; MsLeft = 2580000.0 }; _Act = @{ Model = 'priced' }; _Gone = $null }
    $lines = Format-Row $cols $r '  ' 2   # returns its lines as one array (return ,$lines)
    @($lines).Count | Should -Be 1
    (Strip-Ansi $lines[0]) | Should -Be '  43m    $2.20'
  }
  It 'redraws the row when RECACHE changes' {
    $r = [pscustomobject]@{ CACHE = '43m'; RECACHE = '$2.20'; _Cache = @{ Kind = 'warm'; Ttl = '1h'; RecacheTokens = 220000 }; _Act = @{ Model = 'priced' }; _Gone = $null; _Jobs = @(); IDLE = '1m' }
    $k1 = Row-Key $cols $r 'sig'
    $r.RECACHE = '$2.30'
    Row-Key $cols $r 'sig' | Should -Not -Be $k1
  }
  It 'is set on a gone row as its clock moves' {
    $script:TranscriptIndex = @{}; $script:History = @{}
    $started = [DateTimeOffset]::UtcNow.AddHours(-3)
    $anchor = [DateTimeOffset]::UtcNow.AddMinutes(-20).ToString('o')
    $r = [pscustomobject]@{ _SessionId = 'g1'; _Gone = (Get-Date).AddMinutes(-7); _Cleared = $false
                            _Act = @{ Cost = 6.0; Model = 'priced'; CacheAnchor = $anchor; CacheTtl = '1h'; RecacheTok = 220000; CacheCompactAt = '' }
                            _StartedAt = $started.LocalDateTime; _Src = [pscustomobject]@{ sessionId = 'g1'; startedAt = $started.ToUnixTimeMilliseconds() }
                            STATE = 'stale'; AGE = 'stale'; IDLE = 'stale'; RATE = 'stale'; ACTIVITY = 'stale'; CACHE = 'stale'; RECACHE = 'stale'; _Cache = $null; _Dirty = $false }
    Update-GoneRow $r
    $r.RECACHE | Should -Be '$2.20'
  }
  It 'is described in the help (the hover line reads it there), and CACHE does not speak of a second line' {
    $script:ColumnMeaning = $null
    Get-ColumnMeaning 'RECACHE' | Should -Match 'next turn'
    Get-ColumnMeaning 'CACHE' | Should -Not -Match 'Second line'
  }
  It 'redraws the row when only the model id it is priced by changes' {
    $r = [pscustomobject]@{ CACHE = '43m'; _Cache = @{ Kind = 'warm'; Ttl = '1h'; RecacheTokens = 220000 }; _Act = @{ Model = 'opus-5-5'; ModelId = 'claude-opus-5-5' }
                            _Gone = $null; _Jobs = @(); IDLE = '1m'; _TreeCost = 1.7242 }
    $k1 = Row-Key $cols $r 'sig'
    $r._Act.ModelId = 'opus-5-5'   # MODEL, COST and the cache the same: two rules of a pricing file can still price them apart
    Row-Key $cols $r 'sig' | Should -Not -Be $k1
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
