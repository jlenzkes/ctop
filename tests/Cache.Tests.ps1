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
