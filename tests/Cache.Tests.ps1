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
    $big = '{"parentUuid":"p","isSidechain":false,"type":"user","message":{"role":"user","content":[{"tool_use_id":"t","type":"tool_result","content":"x"}]},"uuid":"9b3b2be4-638a-44f9-a48b-55941fedac45","timestamp":"2026-11-13T12:00:00.000Z","toolUseResult":{"stdout":"' + ('y' * 5000) + '"},"cwd":"c:\x"}'
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
    $line = '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"t","name":"X","input":{"uuid":"9b3b2be4-638a-44f9-a48b-55941fedac45","timestamp":"2025-01-01T00:00:00.000Z"}}],"usage":{"input_tokens":3,"cache_creation_input_tokens":200,"cache_read_input_tokens":1000,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z","cwd":"c:\x"}'
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
}

# Sol's witnesses (rounds 1 and 2 of PR #8's audit, 2026-11-13), byte for byte: each is one assistant entry whose
# tool_use input holds look-alikes of entry fields, or whose own fields are in another order. Only the entry's
# own fields count: its type, isSidechain and timestamp, and its message's model, id and usage.
Describe 'Update-Scan: an entry is read from its own fields, never from a tool input' {
  BeforeEach { $script:ScanCache = @{}; $script:ScanVerified = @{} }
  It '<Name>' -ForEach @(
    # round 1 (sol-pr8-rule): message.id before model
    @{ Name = 'baseline'; Want = 'H'; Line = '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"ok":1}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' }
    @{ Name = 'nested_sidechain'; Want = 'H'; Line = '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"isSidechain":true}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' }
    @{ Name = 'nested_synthetic'; Want = 'H'; Line = '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"model":"<synthetic>"}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' }
    @{ Name = 'nested_usage'; Want = 'H'; Line = '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"usage":{"input_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0},"output_tokens":0}}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' }
    @{ Name = 'nested_user_type'; Want = 'H'; Line = '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"type":"user"}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' }
    # round 2 (sol-round2-rule): model-first messages
    @{ Name = 'canonical_baseline'; Want = 'H'; Line = '{"parentUuid":"p","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"ok":1}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' }
    @{ Name = 'canonical_nested_ai_title'; Want = 'H'; Line = '{"parentUuid":"p","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"type":"ai-title","aiTitle":"metadata"}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' }
    @{ Name = 'canonical_nested_compact'; Want = 'H'; Line = '{"parentUuid":"p","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"type":"system","subtype":"compact_boundary","timestamp":"2025-01-01T00:00:00Z"}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' }
    @{ Name = 'canonical_nested_custom_title'; Want = 'H'; Line = '{"parentUuid":"p","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"type":"custom-title","customTitle":"metadata"}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' }
    @{ Name = 'canonical_nested_sidechain'; Want = 'H'; Line = '{"parentUuid":"p","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"isSidechain":true}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' }
    @{ Name = 'canonical_nested_summary'; Want = 'H'; Line = '{"parentUuid":"p","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"type":"summary","summary":"metadata"}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' }
    @{ Name = 'canonical_nested_synthetic'; Want = 'H'; Line = '{"parentUuid":"p","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"message":{"model":"<synthetic>"},"model":"<synthetic>"}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' }
    @{ Name = 'canonical_nested_usage'; Want = 'H'; Line = '{"parentUuid":"p","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"usage":{"input_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0},"output_tokens":0}}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' }
    @{ Name = 'canonical_nested_user_type'; Want = 'H'; Line = '{"parentUuid":"p","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"type":"user","role":"user"}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' }
    # round 2: fields missing, after the message, or in another order
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
  It 'stands between STATE and TURN (user, 2026-11-13: "flip the turn and cache columns")' {
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
  # Sol's R2-F8c (ties.ps1): each row's key read its own clock, so two rows with one deadline got different keys
  # and swapped places from one frame to the next
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
  It 'is described in the help (the hover line reads it there), and CACHE no longer speaks of a second line' {
    $script:ColumnMeaning = $null
    Get-ColumnMeaning 'RECACHE' | Should -Match 'next turn'
    Get-ColumnMeaning 'CACHE' | Should -Not -Match 'Second line'
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
