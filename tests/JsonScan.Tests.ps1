# Update-Scan reads each transcript line as JSON.parse reads it: exactly one JSON
# object per line, its fields at their own places, escapes decoded, numbers by value, a key written twice
# taken from its last occurrence (a container written twice: the last one, whole). A line JSON.parse would
# reject changes nothing. And in time linear in the line.
BeforeAll {
  . (Join-Path $PSScriptRoot 'Import-Ctop.ps1')
  # scans a file holding exactly $raw (UTF-8, no byte-order mark of its own)
  function ScanRaw([string]$raw) {
    $f = Join-Path $TestDrive "t-$([guid]::NewGuid().ToString('N')).jsonl"
    [IO.File]::WriteAllText($f, $raw)
    $script:ScanCache = @{}; $script:ScanVerified = @{}
    Update-Scan (Get-Item -LiteralPath $f) ([IO.Path]::GetFileNameWithoutExtension($f))
  }
  function Scan([string[]]$lines) { ScanRaw (($lines -join "`n") + "`n") }
  # what a scan found, everything but where the file is and how far it was read
  function Fields($st) {
    $names = 'Turns', 'Tools', 'TurnStart', 'Cost', 'InTok', 'OutTok', 'CacheR', 'CacheW', 'LastId', 'LastCost', 'LastOut', 'Model', 'AiTitle', 'Summary',
             'Title', 'First', 'MsgSummary', 'Cwd', 'GitBranch', 'Compacts', 'LastCompactAt', 'LastCompactTrigger', 'LastCompactPreTokens', 'LastCompactPostTokens',
             'CacheAnchor', 'CacheAnchorId', 'CacheTtl', 'RecacheTok', 'CacheCompactAt', 'CacheReqAt'
    $o = foreach ($n in $names) { '{0}={1}' -f $n, $st[$n] }
    $o += 'ToolCounts=' + (($st.ToolCounts.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name):$($_.Value)" }) -join ',')
    $o += 'ToolLog=' + @($st.ToolLog).Count
    $o -join "`n"
  }
  function At([string]$ts) { [DateTimeOffset]::Parse($ts, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime }
  # a whole valid line before the one tested: a line read when it should not be would change what it left
  $script:Prior = '{"type":"assistant","timestamp":"2026-11-13T11:00:00.000Z","message":{"id":"msg_0","model":"claude-sonnet-5-5","content":[{"type":"tool_use","id":"t0","name":"Read","input":{}}],"usage":{"input_tokens":7,"cache_read_input_tokens":50,"cache_creation_input_tokens":20,"cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":20},"output_tokens":9}},"cwd":"C:\\prior","gitBranch":"prior"}'
  # the baseline: a 1-hour call at 12:00, 1,203 tokens, one tool call X
  $script:B = '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"ok":1}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}'
  function Should-Reject([string]$raw) {
    $before = Fields (ScanRaw ($script:Prior + "`n"))
    $before | Should -Match '(?m)^Tools=1$' -Because 'the line before is read (it has to be valid JSON for that)'
    $after = Fields (ScanRaw ($script:Prior + "`n" + $raw))
    $after | Should -BeExactly $before
  }
}

# Fixture lines, byte for byte (each as a file's whole text). Want: the cache frame, the tokens (input, cache
# read, cache write, output) and the tool calls JSON.parse gives; 'reject': JSON.parse rejects the line, so it
# changes nothing.
Describe 'Update-Scan reads a line as JSON.parse does, fixture by fixture' {
  It '<Name>' -ForEach @(
    @{ Name = 'arrays_escaped_quotes_nested_metadata'; Want = @{ Ttl = '1h'; Tok = 1203; Tok4 = @(3, 1000, 200, 5); Tools = 1 }; Raw = '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"a":[null,true,false,1,-2,3.5,"x\\\"{}[]",[],{},[{"type":"system","subtype":"compact_boundary","usage":{"input_tokens":0}}]],"message":{"usage":{"input_tokens":0}}}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' + [char]0x000A }
    @{ Name = 'baseline'; Want = @{ Ttl = '1h'; Tok = 1203; Tok4 = @(3, 1000, 200, 5); Tools = 1 }; Raw = '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"ok":1}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' + [char]0x000A }
    @{ Name = 'bom_crlf'; Want = @{ Ttl = '1h'; Tok = 1203; Tok4 = @(3, 1000, 200, 5); Tools = 1 }; Raw = '' + [char]0xFEFF + '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"ok":1}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' + [char]0x000D + [char]0x000A }
    @{ Name = 'duplicate_cache_creation_partial_last_wins'; Want = @{ Ttl = '5m'; Tok = 1203; Tok4 = @(3, 1000, 200, 5); Tools = 1 }; Raw = '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"ok":1}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200},"cache_creation":{"ephemeral_5m_input_tokens":200},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' + [char]0x000A }
    @{ Name = 'duplicate_content_last_wins'; Want = @{ Ttl = '1h'; Tok = 1203; Tok4 = @(3, 1000, 200, 5); Tools = 1 }; Raw = '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","name":"BAD","input":{}}],"content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"ok":1}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' + [char]0x000A }
    @{ Name = 'duplicate_scalar_token_last_wins'; Want = @{ Ttl = '1h'; Tok = 1203; Tok4 = @(3, 1000, 200, 5); Tools = 1 }; Raw = '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"ok":1}}],"usage":{"input_tokens":0,"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' + [char]0x000A }
    @{ Name = 'duplicate_type_last_wins'; Want = @{ Ttl = '1h'; Tok = 1203; Tok4 = @(3, 1000, 200, 5); Tools = 1 }; Raw = '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"ok":1}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"user","type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' + [char]0x000A }
    @{ Name = 'duplicate_usage_null_last_wins'; Want = @{ Ttl = ''; Tok = 0; Tok4 = @(0, 0, 0, 0); Tools = 1 }; Raw = '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"ok":1}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5},"usage":null},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' + [char]0x000A }
    @{ Name = 'duplicate_usage_partial_last_wins'; Want = @{ Ttl = '1h'; Tok = 1200; Tok4 = @(0, 1000, 200, 5); Tools = 1 }; Raw = '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"ok":1}}],"usage":{"input_tokens":999999,"cache_read_input_tokens":999999,"cache_creation_input_tokens":999999,"cache_creation":{"ephemeral_1h_input_tokens":999999}},"usage":{"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' + [char]0x000A }
    @{ Name = 'escaped_model_value'; Want = @{ Ttl = '1h'; Tok = 1203; Tok4 = @(3, 1000, 200, 5); Tools = 1 }; Raw = '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"cl\u0061ude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"ok":1}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' + [char]0x000A }
    @{ Name = 'exponent_token_integer'; Want = @{ Ttl = '1h'; Tok = 1203; Tok4 = @(3, 1000, 200, 5); Tools = 1 }; Raw = '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"ok":1}}],"usage":{"input_tokens":3e0,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' + [char]0x000A }
    @{ Name = 'invalid_mismatched_nested_closer'; Want = 'reject'; Raw = '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"ok":[}}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' + [char]0x000A }
    @{ Name = 'invalid_nested_missing_value'; Want = 'reject'; Raw = '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"ok":}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' + [char]0x000A }
    @{ Name = 'invalid_number_leadingzero'; Want = 'reject'; Raw = '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"ok":1}}],"usage":{"input_tokens":03,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' + [char]0x000A }
    @{ Name = 'invalid_number_plus'; Want = 'reject'; Raw = '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"ok":1}}],"usage":{"input_tokens":+3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' + [char]0x000A }
    @{ Name = 'invalid_number_word'; Want = 'reject'; Raw = '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"ok":banana}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' + [char]0x000A }
    @{ Name = 'invalid_prefix'; Want = 'reject'; Raw = 'garbage{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"ok":1}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' + [char]0x000A }
    @{ Name = 'invalid_string_control'; Want = 'reject'; Raw = '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"ok":"' + [char]0x0001 + '"}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' + [char]0x000A }
    @{ Name = 'invalid_string_escape'; Want = 'reject'; Raw = '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"ok":"\q"}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' + [char]0x000A }
    @{ Name = 'invalid_trailing_comma'; Want = 'reject'; Raw = '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"ok":1}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z",}' + [char]0x000A }
    @{ Name = 'invalid_trailing_junk'; Want = 'reject'; Raw = '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"ok":1}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}garbage' + [char]0x000A }
    @{ Name = 'invalid_truncated'; Want = 'reject'; Raw = '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"ok":1}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"' + [char]0x000A }
    @{ Name = 'invalid_two_objects'; Want = 'reject'; Raw = '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"ok":1}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}{}' + [char]0x000A }
    @{ Name = 'knownlimit_duplicate_block_type'; Want = @{ Ttl = '1h'; Tok = 1203; Tok4 = @(3, 1000, 200, 5); Tools = 1 }; Raw = '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"text","type":"tool_use","id":"tool_1","name":"X","input":{"ok":1}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' + [char]0x000A }
    @{ Name = 'knownlimit_duplicate_message'; Want = @{ Ttl = '1h'; Tok = 1200; Tok4 = @(0, 1000, 200, 5); Tools = 1 }; Raw = '{"parentUuid":"p","isSidechain":false,"message":{"model":"bad","id":"msg_bad","usage":{"input_tokens":999999}},"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"ok":1}}],"usage":{"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' + [char]0x000A }
    @{ Name = 'leading_trailing_whitespace'; Want = @{ Ttl = '1h'; Tok = 1203; Tok4 = @(3, 1000, 200, 5); Tools = 1 }; Raw = ' ' + [char]0x0009 + '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"ok":1}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"} ' + [char]0x000D + [char]0x000A }
    @{ Name = 'reordered_fields'; Want = @{ Ttl = '1h'; Tok = 1203; Tok4 = @(3, 1000, 200, 5); Tools = 1 }; Raw = '{"timestamp":"2026-11-13T12:00:00.000Z","type":"assistant","message":{"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5},"content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"ok":1}}],"id":"msg_1","model":"claude-opus-5-5"},"isSidechain":false}' + [char]0x000A }
    @{ Name = 'unicode_message_key'; Want = @{ Ttl = '1h'; Tok = 1203; Tok4 = @(3, 1000, 200, 5); Tools = 1 }; Raw = '{"parentUuid":"p","isSidechain":false,"mess\u0061ge":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"ok":1}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' + [char]0x000A }
    @{ Name = 'unicode_token_digits'; Want = @{ Ttl = '1h'; Tok = 1203; Tok4 = @(3, 1000, 200, 5); Tools = 1 }; Raw = '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"ok":1}}],"usage":{"input_tokens":3.0,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' + [char]0x000A }
    @{ Name = 'unicode_token_key'; Want = @{ Ttl = '1h'; Tok = 1203; Tok4 = @(3, 1000, 200, 5); Tools = 1 }; Raw = '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"ok":1}}],"usage":{"input_\u0074okens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' + [char]0x000A }
    @{ Name = 'unicode_type_key'; Want = @{ Ttl = '1h'; Tok = 1203; Tok4 = @(3, 1000, 200, 5); Tools = 1 }; Raw = '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"ok":1}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"\u0074ype":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' + [char]0x000A }
    @{ Name = 'unicode_type_value'; Want = @{ Ttl = '1h'; Tok = 1203; Tok4 = @(3, 1000, 200, 5); Tools = 1 }; Raw = '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"ok":1}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"\u0061ssistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' + [char]0x000A }
    @{ Name = 'unicode_usage_key'; Want = @{ Ttl = '1h'; Tok = 1203; Tok4 = @(3, 1000, 200, 5); Tools = 1 }; Raw = '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"ok":1}}],"us\u0061ge":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' + [char]0x000A }
    @{ Name = 'valid_depth100'; Want = @{ Ttl = '1h'; Tok = 1203; Tok4 = @(3, 1000, 200, 5); Tools = 1 }; Raw = '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"wrap":{"value":0}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' + [char]0x000A }
    @{ Name = 'valid_long_150k'; Want = @{ Ttl = '1h'; Tok = 1203; Tok4 = @(3, 1000, 200, 5); Tools = 1 }; Raw = '{"parentUuid":"p","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tool_1","name":"X","input":{"str":"' + ('text \\\" {} [] ' * 10000) + '","arr":[{"type":"user","isSidechain":true,"usage":{"input_tokens":0}}]}}],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"type":"assistant","uuid":"60e1b897-551b-4656-862d-7a087d547208","timestamp":"2026-11-13T12:00:00.000Z"}' + [char]0x000A }
    @{ Name = 'stress_bareword'; Want = 'reject'; Raw = '{"type":"assistant","message":{"model":"claude-opus-5-5","id":"msg_one","usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0}}},"data":undefined,"timestamp":"2026-11-13T12:00:00Z"}' + [char]0x000A }
    @{ Name = 'stress_concatenated'; Want = 'reject'; Raw = '{"type":"assistant","message":{"model":"claude-opus-5-5","id":"msg_one","usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0}}},"timestamp":"2026-11-13T12:00:00Z"}{"type":"assistant","message":{"model":"claude-opus-5-5","id":"msg_one","usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0}}},"timestamp":"2026-11-13T12:00:00Z"}' + [char]0x000A }
    @{ Name = 'stress_invalid_escape'; Want = 'reject'; Raw = '{"type":"assistant","message":{"model":"claude-opus-5-5","id":"msg_one","usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0}}},"data":"\q","timestamp":"2026-11-13T12:00:00Z"}' + [char]0x000A }
    @{ Name = 'stress_invalid_number_plus'; Want = 'reject'; Raw = '{"type":"assistant","message":{"model":"claude-opus-5-5","id":"msg_one","usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0}}},"data":+1,"timestamp":"2026-11-13T12:00:00Z"}' + [char]0x000A }
    @{ Name = 'stress_invalid_number_trailingdot'; Want = 'reject'; Raw = '{"type":"assistant","message":{"model":"claude-opus-5-5","id":"msg_one","usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0}}},"data":1.,"timestamp":"2026-11-13T12:00:00Z"}' + [char]0x000A }
    @{ Name = 'stress_invalid_number_zero'; Want = 'reject'; Raw = '{"type":"assistant","message":{"model":"claude-opus-5-5","id":"msg_one","usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0}}},"data":01,"timestamp":"2026-11-13T12:00:00Z"}' + [char]0x000A }
    @{ Name = 'stress_leading_garbage'; Want = 'reject'; Raw = 'INVALID{"type":"assistant","message":{"model":"claude-opus-5-5","id":"msg_one","usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0}}},"timestamp":"2026-11-13T12:00:00Z"}' + [char]0x000A }
    @{ Name = 'stress_nested_mismatched'; Want = 'reject'; Raw = '{"type":"assistant","message":{"model":"claude-opus-5-5","id":"msg_one","usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0}}},"data":[1,2},"timestamp":"2026-11-13T12:00:00Z"}' + [char]0x000A }
    @{ Name = 'stress_raw_tab_string'; Want = 'reject'; Raw = '{"type":"assistant","message":{"model":"claude-opus-5-5","id":"msg_one","usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0}}},"data":"a' + [char]0x0009 + 'b","timestamp":"2026-11-13T12:00:00Z"}' + [char]0x000A }
    @{ Name = 'stress_top_trailing_comma'; Want = 'reject'; Raw = '{"type":"assistant","message":{"model":"claude-opus-5-5","id":"msg_one","usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0}}},"timestamp":"2026-11-13T12:00:00Z",}' + [char]0x000A }
    @{ Name = 'stress_trailing_garbage'; Want = 'reject'; Raw = '{"type":"assistant","message":{"model":"claude-opus-5-5","id":"msg_one","usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0}}},"timestamp":"2026-11-13T12:00:00Z"}INVALID' + [char]0x000A }
    @{ Name = 'stress_unclosed'; Want = 'reject'; Raw = '{"type":"assistant","message":{"model":"claude-opus-5-5","id":"msg_one","usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0}}},"timestamp":"2026-11-13T12:00:00Z"' + [char]0x000A }
    @{ Name = 'stress_unknown_invalid_object'; Want = 'reject'; Raw = '{"type":"assistant","message":{"model":"claude-opus-5-5","id":"msg_one","usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0}}},"data":{"x"::0},"timestamp":"2026-11-13T12:00:00Z"}' + [char]0x000A }
    @{ Name = 'stress_valid'; Want = @{ Ttl = '1h'; Tok = 1203; Tok4 = @(3, 1000, 200, 0); Tools = 0 }; Raw = '{"type":"assistant","message":{"model":"claude-opus-5-5","id":"msg_one","usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0}}},"timestamp":"2026-11-13T12:00:00Z"}' + [char]0x000A }
    @{ Name = 'stress_valid_BOM'; Want = @{ Ttl = '1h'; Tok = 1203; Tok4 = @(3, 1000, 200, 0); Tools = 0 }; Raw = '' + [char]0xFEFF + '{"type":"assistant","message":{"model":"claude-opus-5-5","id":"msg_one","usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0}}},"timestamp":"2026-11-13T12:00:00Z"}' + [char]0x000A }
    @{ Name = 'stress_valid_CRLF'; Want = @{ Ttl = '1h'; Tok = 1203; Tok4 = @(3, 1000, 200, 0); Tools = 0 }; Raw = '{"type":"assistant","message":{"model":"claude-opus-5-5","id":"msg_one","usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0}}},"timestamp":"2026-11-13T12:00:00Z"}' + [char]0x000D + [char]0x000A + [char]0x000A }
    @{ Name = 'stress_valid_escaped_quote'; Want = @{ Ttl = '1h'; Tok = 1203; Tok4 = @(3, 1000, 200, 0); Tools = 0 }; Raw = '{"type":"assistant","message":{"model":"claude-opus-5-5","id":"msg_one","usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0}}},"data":"a\"b\\c","timestamp":"2026-11-13T12:00:00Z"}' + [char]0x000A }
  ) {
    if ($Want -eq 'reject') { Should-Reject $Raw; return }
    $st = ScanRaw $Raw
    $st.CacheTtl | Should -Be $Want.Ttl
    $st.RecacheTok | Should -Be $Want.Tok
    if ($Want.Ttl) { (At $st.CacheAnchor) | Should -Be (At '2026-11-13T12:00:00.000Z') }
    $st.InTok, $st.CacheR, $st.CacheW, $st.OutTok | Should -Be $Want.Tok4
    $st.Tools | Should -Be $Want.Tools
    if ($Want.Tools) { @($st.ToolCounts.Keys) | Should -Be @('X') }
    $st.Model | Should -Be 'claude-opus-5-5'
    $st.Turns | Should -Be 0
  }
}

Describe 'Update-Scan reads what JSON.parse reads' {
  It 'a content block''s keys and values written with escapes' {
    $st = Scan @($B.Replace('"type":"tool_use","id":"tool_1","name":"X"', '"\u0074ype":"tool_\u0075se","id":"tool_1","n\u0061me":"\u0042ash"'))
    $st.Tools | Should -Be 1
    @($st.ToolCounts.Keys) | Should -Be @('Bash')
    @($st.ToolLog).Count | Should -Be 1
  }
  It 'a count <N> is <Want>, as JSON.parse rounds it' -ForEach @(
    @{ N = '99999999999999994449e-20'; Want = 1 }, @{ N = '29999999999999997780e-19'; Want = 3 },
    @{ N = '4.9999999999999999999e0'; Want = 5 }, @{ N = '0.5e1'; Want = 5 }, @{ N = '1e0'; Want = 1 },
    @{ N = '9007199254740993e0'; Want = 9007199254740992 }, @{ N = '2.5'; Want = 0 }, @{ N = '-0.0'; Want = 0 },
    @{ N = '1e19'; Want = 0 }, @{ N = '0.000000000000000000000000000000001e33'; Want = 1 }, @{ N = '1e-400'; Want = 0 }
  ) {
    $st = Scan @($B.Replace('"input_tokens":3,', '"input_tokens":' + $N + ','))
    $st.InTok | Should -Be $Want
  }
  It 'a count whose long mantissa and large exponent cancel is <Want>' -ForEach @(
    @{ N = '1' + ('0' * 100000) + 'e-1000000'; Want = 0 }, @{ N = '1' + ('0' * 1000000) + 'e-1000000'; Want = 1 },
    @{ N = '3' + ('0' * 200000) + 'e-200000'; Want = 3 }, @{ N = '0.' + ('0' * 99999) + '7e100000'; Want = 7 }
  ) {
    $st = Scan @($B.Replace('"input_tokens":3,', '"input_tokens":' + $N + ','))
    $st.InTok | Should -Be $Want
  }
  It 'a compaction whose keys are escaped and whose token count has an exponent' {
    $st = Scan @('{"type":"system","subtype":"compact_bound\u0061ry","compact\u004detadata":{"trig\u0067er":"\u0061uto","preTokens":2.80717e5,"postTokens":5.1232e4},"timestamp":"2026-11-14T02:15:54.010Z"}')
    $st.Compacts | Should -Be 1
    $st.LastCompactTrigger | Should -BeExactly 'auto'
    $st.LastCompactPreTokens | Should -Be 280717
    $st.LastCompactPostTokens | Should -Be 51232
  }
  It 'a title with a surrogate pair and every short escape' {
    $st = Scan @('{"type":"ai-title","aiTitle":"a \ud83d\ude00 \"b\" \\ \/ \b\f\n\r\t end"}')
    $st.AiTitle | Should -BeExactly ('a ' + [char]0xD83D + [char]0xDE00 + ' "b" \ / ' + [char]8 + [char]12 + "`n`r`t end")
  }
  It 'a title holding a lone surrogate (JSON.parse keeps it)' {
    (Scan @('{"type":"custom-title","customTitle":"x\udc00y"}')).Title | Should -BeExactly ('x' + [char]0xDC00 + 'y')
  }
  It 'a token count of 3 written <Text>' -ForEach @(
    @{ Text = '3' }, @{ Text = '3.0' }, @{ Text = '3e0' }, @{ Text = '3E+0' }, @{ Text = '0.3e1' }, @{ Text = '30e-1' }, @{ Text = '300E-2' },
    @{ Text = '3.000e0' }, @{ Text = '0.03e2' }, @{ Text = '0.0000000000000000000000000003e28' }
  ) {
    $st = Scan @($B.Replace('"input_tokens":3', '"input_tokens":' + $Text))
    $st.InTok | Should -Be 3
    $st.RecacheTok | Should -Be 1203
  }
  # A count is a whole number of tokens. A plain integer: its exact value (Get-JsonLong). Any other
  # number: its value as JSON.parse reads it, a double (1.00000000000000000001 is 1; 9.223372036854775807e18 is
  # 2^63, past a long). 0 when that is not whole or not within a long: JSON.parse keeps 3.5 as 3.5, which no
  # transcript holds, and Get-JsonLong reads it as 0.
  It 'a token count of <Text> as <Want>' -ForEach @(
    @{ Text = '3.5'; Want = 0 }, @{ Text = '1e400'; Want = 0 }, @{ Text = '1e-400'; Want = 0 }, @{ Text = '-0'; Want = 0 }, @{ Text = '0.0e5'; Want = 0 },
    @{ Text = '12345678901234567890'; Want = 0 }, @{ Text = '9223372036854775808'; Want = 0 }, @{ Text = '"3"'; Want = 0 }, @{ Text = 'true'; Want = 0 },
    @{ Text = 'null'; Want = 0 }, @{ Text = '[3]'; Want = 0 }, @{ Text = '{"n":3}'; Want = 0 }, @{ Text = '-5'; Want = -5 },
    @{ Text = '9223372036854775807'; Want = 9223372036854775807 }, @{ Text = '9.223372036854775807e18'; Want = 0 }, @{ Text = '1.00000000000000000001'; Want = 1 },
    @{ Text = '2.5e1'; Want = 25 }, @{ Text = '-3.0'; Want = -3 }
  ) {
    $st = Scan @($B.Replace('"output_tokens":5', '"output_tokens":' + $Text))
    $st.OutTok | Should -Be $Want
    $st.LastOut | Should -Be $Want
  }
  It 'the last compactMetadata, whole: a count only the first one had is not read' {
    $st = Scan @('{"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"auto","preTokens":280717,"postTokens":51232},"compactMetadata":{"trigger":"manual"},"timestamp":"2026-11-14T02:15:54.010Z"}')
    $st.LastCompactTrigger | Should -BeExactly 'manual'
    $st.LastCompactPreTokens | Should -Be 0
    $st.LastCompactPostTokens | Should -Be 0
  }
  It 'the last input of a SendMessage call, whole' {
    $two = '{"type":"tool_use","id":"t1","name":"SendMessage","input":{"summary":"first"},"input":{"to":"a"}}'
    (Scan @($B.Replace('{"type":"tool_use","id":"tool_1","name":"X","input":{"ok":1}}', $two))).MsgSummary | Should -BeExactly ''
    $two = '{"type":"tool_use","id":"t1","name":"SendMessage","input":{"to":"a"},"input":{"summary":"second"}}'
    (Scan @($B.Replace('{"type":"tool_use","id":"tool_1","name":"X","input":{"ok":1}}', $two))).MsgSummary | Should -BeExactly 'second'
  }
  It 'the last name and type of a block' {
    $st = Scan @($B.Replace('"name":"X"', '"name":"Bad","name":"Bash"'))
    @($st.ToolCounts.Keys) | Should -Be @('Bash')
    (Scan @($B.Replace('"type":"tool_use"', '"type":"tool_use","type":"text"'))).Tools | Should -Be 0
  }
  It 'the last content of a prompt: <Name>' -ForEach @(
    @{ Name = 'a tool result after text'; Content = '"content":"a real prompt","content":[{"type":"tool_result","tool_use_id":"t","content":"x"}]'; Turns = 0; First = '' }
    @{ Name = 'text after a tool result'; Content = '"content":[{"type":"tool_result","tool_use_id":"t","content":"x"}],"content":"a real prompt"'; Turns = 1; First = 'a real prompt' }
  ) {
    $st = Scan @('{"type":"user","timestamp":"2026-11-13T12:00:00.000Z","message":{"role":"user",' + $Content + '}}')
    $st.Turns | Should -Be $Turns
    $st.First | Should -BeExactly $First
  }
  It 'the last message, even when it is not an object' {
    $st = Scan @($B.Replace(',"type":"assistant"', ',"message":null,"type":"assistant"'))
    $st.CacheTtl, $st.RecacheTok, $st.InTok, $st.Tools, $st.Model | Should -Be @('', 0, 0, 0, '-')
  }
  It 'whitespace between any two tokens (space, tab, carriage return)' {
    $st = Scan @(' ' + $B.Replace('":', "`" :`t ").Replace(',"', " ,`r `"").Replace('{', "{ `t").Replace('}', "`r }").Replace('[', '[ ').Replace(']', ' ]') + "`t")
    $st.CacheTtl, $st.RecacheTok, $st.Tools | Should -Be @('1h', 1203, 1)
    (At $st.CacheAnchor) | Should -Be (At '2026-11-13T12:00:00.000Z')
  }
  It 'a tool input nested <Depth> levels deep' -ForEach @(@{ Depth = 100000; Open = '['; Close = ']' }, @{ Depth = 50000; Open = '{"a":'; Close = '}' }) {
    $st = Scan @($B.Replace('"input":{"ok":1}', '"input":{"ok":' + ($Open * $Depth) + '0' + ($Close * $Depth) + '}'))
    $st.CacheTtl, $st.RecacheTok, $st.Tools | Should -Be @('1h', 1203, 1)
  }
  It 'a line too short for the regex reader to look at' {
    (Scan @('{"cwd":"C:\\a"}')).Cwd | Should -BeExactly 'C:\a'
  }
}

Describe 'Update-Scan reads nothing from a line JSON.parse rejects' {
  It 'a tool input holding <Frag>' -ForEach @(
    @{ Frag = '{"ok":1,}' }, @{ Frag = '{"ok":[1,]}' }, @{ Frag = '{"ok":[,1]}' }, @{ Frag = '{"ok":1,,"b":2}' }, @{ Frag = '{,}' }, @{ Frag = '{"ok" 1}' },
    @{ Frag = '{"ok":1 "b":2}' }, @{ Frag = '{:1}' }, @{ Frag = '{ok:1}' }, @{ Frag = '{''ok'':1}' }, @{ Frag = '{"ok":''a''}' }, @{ Frag = '{"ok":[}' },
    @{ Frag = '{"ok":{]}' }, @{ Frag = '{"ok":[1}}' }, @{ Frag = '{"ok":[[1]}' }, @{ Frag = '{"ok":-01}' }, @{ Frag = '{"ok":1e}' }, @{ Frag = '{"ok":1e+}' },
    @{ Frag = '{"ok":.5}' }, @{ Frag = '{"ok":-}' }, @{ Frag = '{"ok":0x1}' }, @{ Frag = '{"ok":1.e5}' }, @{ Frag = '{"ok":+1}' }, @{ Frag = '{"ok":01}' },
    @{ Frag = '{"ok":1.}' }, @{ Frag = '{"ok":--1}' }, @{ Frag = '{"ok":tru}' }, @{ Frag = '{"ok":nul}' }, @{ Frag = '{"ok":NaN}' }, @{ Frag = '{"ok":Infinity}' },
    @{ Frag = '{"ok":True}' }, @{ Frag = '{"ok":undefined}' }, @{ Frag = '{"ok":truex}' }, @{ Frag = '{"ok":"\u12G4"}' }, @{ Frag = '{"ok":"\U0041"}' },
    @{ Frag = '{"ok":"\x41"}' }, @{ Frag = '{"ok":"\''"}' }, @{ Frag = '{"ok":"\u004"}' }, @{ Frag = '{"ok":"abc}' }, @{ Frag = '{"ok":"a\"}' },
    @{ Frag = '{"o\k":1}' }, @{ Frag = '{"ok":"a' + [char]0x1F + 'b"}' }, @{ Frag = '{"ok":"a' + [char]0 + 'b"}' }, @{ Frag = '{"ok":"a' + [char]9 + 'b"}' },
    @{ Frag = '{"ok":' + [char]0xA0 + '1}' }, @{ Frag = '{"ok":' + [char]12 + '1}' }, @{ Frag = '{"ok":' + [char]11 + '1}' }, @{ Frag = '{"ok":' + [char]0x2028 + '1}' },
    @{ Frag = '{"ok":' + [char]0xFEFF + '1}' }, @{ Frag = '{"ok":1}}' }, @{ Frag = '[' }
  ) {
    Should-Reject ($B.Replace('"input":{"ok":1}', '"input":' + $Frag) + "`n")
  }
  It 'a field it reads, written wrong: <Name>' -ForEach @(
    @{ Name = 'a bad escape in the model'; From = '"model":"claude-opus-5-5"'; To = '"model":"claude\q"' }
    @{ Name = 'a control character in the type'; From = '"type":"assistant"'; To = '"type":"assist' + [char]1 + 'ant"' }
    @{ Name = 'a bad escape in a key'; From = '"usage":'; To = '"us\age":' }
    @{ Name = 'a short \u in a tool name'; From = '"name":"X"'; To = '"name":"X\u00"' }
    @{ Name = 'a count ending in a dot'; From = '"input_tokens":3'; To = '"input_tokens":3.' }
    @{ Name = 'a count with a plus'; From = '"input_tokens":3'; To = '"input_tokens":+3' }
    @{ Name = 'a count with a leading zero'; From = '"cache_read_input_tokens":1000'; To = '"cache_read_input_tokens":01000' }
    @{ Name = 'a cut-off literal'; From = '"isSidechain":false'; To = '"isSidechain":fals' }
    @{ Name = 'a literal run on'; From = '"isSidechain":false'; To = '"isSidechain":falsey' }
    @{ Name = 'a usage closed as an array'; From = '"output_tokens":5}}'; To = '"output_tokens":5]}' }
    @{ Name = 'content closed as an object'; From = '{"ok":1}}]'; To = '{"ok":1}}}' }
    @{ Name = 'a trailing comma in content'; From = '{"ok":1}}]'; To = '{"ok":1}},]' }
    @{ Name = 'a trailing comma in the message'; From = '"output_tokens":5}}'; To = '"output_tokens":5},}' }
  ) {
    $B.Contains($From) | Should -BeTrue
    Should-Reject ($B.Replace($From, $To) + "`n")
  }
  It 'a line that is not one object: <Name>' -ForEach @(
    @{ Name = 'two objects, a space between'; Line = $B + ' {}' }
    @{ Name = 'the same object twice'; Line = $B + $B }
    @{ Name = 'an array holding it'; Line = '[' + $B + ']' }
    @{ Name = 'a string'; Line = '"x"' }
    @{ Name = 'a number'; Line = '1' }
    @{ Name = 'nothing'; Line = '' }
    @{ Name = 'only spaces'; Line = '   ' }
    @{ Name = 'two byte-order marks'; Line = [string][char]0xFEFF + [char]0xFEFF + $B }
    @{ Name = 'a byte-order mark after a space'; Line = ' ' + [char]0xFEFF + $B }
    @{ Name = 'a non-breaking space before it'; Line = [string][char]0xA0 + $B }
    @{ Name = 'a form feed after it'; Line = $B + [char]12 }
  ) {
    Should-Reject ($Line + "`n")
  }
  It 'a tool input of 500,000 unclosed arrays, quickly' {
    $line = $B.Replace('"input":{"ok":1}', '"input":{"ok":' + ('[' * 500000) + '}')
    $t = [Diagnostics.Stopwatch]::StartNew()
    Should-Reject ($line + "`n")
    $t.ElapsedMilliseconds | Should -BeLessThan 5000
  }
}

# Looking for each block's fields from the start of the line makes 10,000 tool calls in one line (510 KB, valid)
# take 17.9 s on PowerShell 7; blocks are read in the one pass.
Describe 'Update-Scan reads a line with many content blocks in linear time' {
  It 'reads 10,000 tool calls in one line in well under a second' {
    $line = '{"type":"assistant","message":{"model":"claude-opus-5-5","id":"msg_many","content":[' + ((@('{"type":"tool_use","id":"t","name":"X","input":{}}') * 10000) -join ',') +
            '],"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":200,"ephemeral_5m_input_tokens":0},"output_tokens":5}},"timestamp":"2026-11-13T12:00:00Z"}'
    $null = Scan @($B)   # the reader loaded (compiled, the first time on this machine) before the clock starts
    $ms = foreach ($i in 1..3) {
      $t = [Diagnostics.Stopwatch]::StartNew(); $st = Scan @($line); $t.Stop()
      $st.Tools | Should -Be 10000
      $st.ToolCounts.X | Should -Be 10000
      $st.RecacheTok | Should -Be 1203
      $t.ElapsedMilliseconds
    }
    $median = @($ms | Sort-Object)[1]
    $median | Should -BeLessThan 1000 -Because "a median of 3 scans; took $($ms -join ', ') ms"
  }
}

# Where the scanner can't be compiled (no C# compiler, a locked-down machine), the regex reader
# reads the lines instead: it reads every real transcript the same, but not escaped keys, a
# container written twice, nor some invalid lines. Forced here.
Describe 'Update-Scan without the compiled reader' {
  BeforeAll { $script:KeepReader = $script:EntryReader; $script:EntryReader = 'rx' }
  AfterAll { $script:EntryReader = $script:KeepReader }
  It 'falls back to the regex reader when the scanner does not compile' {
    $script:EntryReader = $null
    Mock Import-JsonType { $false }
    Get-EntryReader | Should -Be 'rx'
    $script:EntryReader | Should -Be 'rx'
  }
  It 'reads a call, its tool calls and its cache frame' {
    $st = Scan @($Prior, $B)
    $st.CacheTtl, $st.RecacheTok, $st.Tools, $st.Model, $st.Cwd, $st.GitBranch | Should -Be @('1h', 1203, 2, 'claude-opus-5-5', 'C:\prior', 'prior')
    (At $st.CacheAnchor) | Should -Be (At '2026-11-13T12:00:00.000Z')
    $st.InTok, $st.CacheR, $st.CacheW, $st.OutTok | Should -Be @(10, 1050, 220, 14)
  }
  It 'takes cwd and branch from a newer entry of a kind it does not read' {
    $st = Scan @($Prior, '{"type":"progress","cwd":"C:\\other","gitBranch":"other","timestamp":"2026-11-13T12:00:00.000Z"}')
    $st.Cwd, $st.GitBranch, $st.Tools | Should -Be @('C:\other', 'other', 1)
    $st = Scan @('{"type":"progress","cwd":"C:\\other","gitBranch":"other","timestamp":"2026-11-13T12:00:00.000Z"}', $Prior)
    $st.Cwd, $st.GitBranch | Should -Be @('C:\prior', 'prior') -Because 'the newest entry with a cwd wins'
  }
  It 'decodes each escaped string as written, whatever case another had (C:\project, not C:\Project)' {
    $st = Scan @($Prior.Replace('C:\\prior', 'C:\\Project'), $Prior.Replace('C:\\prior', 'C:\\project').Replace('msg_0', 'msg_9'))
    $st.Cwd | Should -BeExactly 'C:\project'
  }
  It 'does not resume a scan the other reader made' {
    $f = Join-Path $TestDrive "switch-$([guid]::NewGuid().ToString('N')).jsonl"
    $esc = '{"\u0074ype":"user","timestamp":"2026-11-13T12:00:00.000Z","message":{"role":"user","content":"an escaped prompt"}}'
    [IO.File]::WriteAllText($f, $esc + "`n")
    $script:ScanCache = @{}; $script:ScanVerified = @{}
    $script:EntryReader = 'rx'
    # the reader is put back whatever fails, or the tests after this one would run on CtopJson
    try {
      (Update-Scan (Get-Item -LiteralPath $f) 'sw').Turns | Should -Be 0 -Because 'the regex reader does not know an escaped key (D15)'
      [IO.File]::AppendAllText($f, '{"type":"user","timestamp":"2026-11-13T12:01:00.000Z","message":{"role":"user","content":"a second prompt"}}' + "`n")
      $script:EntryReader = $script:KeepReader
      if ((Get-EntryReader) -ne 'cs') { Set-ItResult -Skipped -Because 'CtopJson does not compile here'; return }
      (Update-Scan (Get-Item -LiteralPath $f) 'sw').Turns | Should -Be 2 -Because 'a fresh CtopJson scan reads both prompts'
    } finally { $script:EntryReader = 'rx' }
  }
  It 'reads a prompt, a compaction and titles' {
    $st = Scan @(
      '{"type":"user","timestamp":"2026-11-13T12:00:00.000Z","message":{"role":"user","content":"the \"first\" prompt"},"cwd":"C:\\a"}'
      '{"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"auto","preTokens":280717,"postTokens":51232},"timestamp":"2026-11-14T02:15:54.010Z"}'
      '{"type":"ai-title","aiTitle":"An \"AI\" title"}'
      '{"type":"assistant","timestamp":"2026-11-13T12:00:00.000Z","message":{"model":"m","id":"msg_1","content":[{"type":"tool_use","id":"t2","name":"SendMessage","input":{"to":"a","summary":"the plan"}}],"usage":{"input_tokens":3,"output_tokens":5}}}'
    )
    $st.Turns, $st.First, $st.Compacts, $st.LastCompactTrigger, $st.LastCompactPreTokens, $st.LastCompactPostTokens, $st.AiTitle, $st.MsgSummary, $st.Cwd |
      Should -Be @(1, 'the "first" prompt', 1, 'auto', 280717, 51232, 'An "AI" title', 'the plan', 'C:\a')
  }
  It 'does not read look-alikes inside a tool input' {
    $st = Scan @($B.Replace('"input":{"ok":1}', '"input":{"type":"user","isSidechain":true,"usage":{"input_tokens":0},"model":"<synthetic>"}'))
    $st.CacheTtl, $st.RecacheTok, $st.Turns, $st.Model | Should -Be @('1h', 1203, 0, 'claude-opus-5-5')
  }
  It 'reads nothing from a line cut short or with more after the object' {
    Should-Reject ($B.Substring(0, $B.Length - 1) + "`n")
    Should-Reject ($B + "garbage`n")
  }
  It 'reads 10,000 tool calls in one line in linear time' {
    $line = '{"type":"assistant","message":{"model":"claude-opus-5-5","id":"msg_many","content":[' + ((@('{"type":"tool_use","id":"t","name":"X","input":{}}') * 10000) -join ',') + '],"usage":{"input_tokens":3,"output_tokens":5}},"timestamp":"2026-11-13T12:00:00Z"}'
    $t = [Diagnostics.Stopwatch]::StartNew(); $st = Scan @($line); $t.Stop()
    $st.Tools | Should -Be 10000
    $t.ElapsedMilliseconds | Should -BeLessThan 5000
  }
}

# CtopJson is compiled once per source and runtime into a DLL beside the caches, on every platform. Each test
# runs in a PowerShell of its own: a type once loaded stays loaded. Whether it came from the DLL: its assembly's name,
# which each compile makes anew, is the one the DLL on disk carries ($from).
Describe 'compiling the transcript reader' {
  BeforeAll {
    # runs $code in a new PowerShell (this one's kind) with ctop's functions and $ConfigDir = $cfg; its output lines
    function InChild([string]$cfg, [string]$code) {
      $code = "`$ErrorActionPreference = 'Stop'; . '$(Join-Path $PSScriptRoot 'Import-Ctop.ps1')'; `$ConfigDir = '$cfg'; $code"
      $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
      $args = @('-NoProfile', '-NonInteractive') + $(if ($IsWindows -or $env:OS -eq 'Windows_NT') { @('-ExecutionPolicy', 'Bypass') }) + @('-EncodedCommand', $enc)
      @(& (Get-Process -Id $PID).Path @args 2>&1 | ForEach-Object { "$_" })
    }
    function New-Cfg { $d = Join-Path $TestDrive "cfg-$([guid]::NewGuid().ToString('N'))"; New-Item -ItemType Directory -Path $d | Out-Null; $d }
    $from = '[CtopJson.Reader].Assembly.FullName -ceq [Reflection.AssemblyName]::GetAssemblyName((Get-JsonDllPath)).FullName'
  }
  It 'compiles to a DLL named by its source and runtime, through a name of its own, and loads it from there' {
    $cfg = New-Cfg
    # Add-Type, through: where it compiled to
    $spy = 'function Add-Type { param($TypeDefinition, $OutputAssembly, $OutputType, $Path, $ReferencedAssemblies, $ErrorAction) $script:To += @($OutputAssembly | Where-Object { $_ }); Microsoft.PowerShell.Utility\Add-Type @PSBoundParameters }; $script:To = @(); '
    $out = InChild $cfg ($spy + "Import-JsonType; $from; Get-JsonDllPath; `$script:To")
    $out[0] | Should -Be 'True' -Because ($out -join "`n")
    $ed = if ($PSVersionTable.PSEdition -eq 'Core') { "core$([Environment]::Version.Major)" } else { 'desktop' }
    Split-Path -Leaf $out[2] | Should -Match "^ctop-json-[0-9A-F]{8}-$ed\.dll$"
    $out[1] | Should -Be 'True' -Because 'loaded from its DLL'
    $out.Count | Should -Be 4 -Because 'one compile'
    Split-Path -Leaf $out[3] | Should -BeLike 'ctop-json-tmp-*.dll' -Because 'compiled under a name of its own, then renamed into place'
    @(Get-ChildItem -LiteralPath $cfg -Name) | Should -Be @(Split-Path -Leaf $out[2])   # no ctop-json-tmp-* left
    $written = (Get-Item -LiteralPath $out[2]).LastWriteTimeUtc
    $again = InChild $cfg "Import-JsonType; $from"
    $again | Should -Be @('True', 'True')
    (Get-Item -LiteralPath $out[2]).LastWriteTimeUtc | Should -Be $written -Because 'the second start loads the DLL, it does not compile again'
  }
  It 'deletes its own old DLLs of this runtime, and nothing of the console helper''s' {
    $d = New-Cfg
    foreach ($n in 'ctop-json-AAAAAAAA-core.dll', 'ctop-json-BBBBBBBB-core.dll', 'ctop-json-CCCCCCCC-desktop.dll', 'ctop-con-DDDDDDDD-core.dll',
                   'ctop-json-tmp-1-old.dll', 'ctop-json-tmp-2-new.dll', 'ctop-con-tmp-3-old.dll') {
      [IO.File]::WriteAllText((Join-Path $d $n), 'x')
    }
    foreach ($n in 'ctop-json-tmp-1-old.dll', 'ctop-con-tmp-3-old.dll') { (Get-Item -LiteralPath (Join-Path $d $n)).LastWriteTimeUtc = [datetime]::UtcNow.AddHours(-1) }
    Remove-OldConDlls (Join-Path $d 'ctop-json-AAAAAAAA-core.dll') 'ctop-json'
    @(Get-ChildItem -LiteralPath $d -Name | Sort-Object) | Should -Be @('ctop-con-DDDDDDDD-core.dll', 'ctop-con-tmp-3-old.dll', 'ctop-json-AAAAAAAA-core.dll',
                                                                      'ctop-json-CCCCCCCC-desktop.dll', 'ctop-json-tmp-2-new.dll')
  }
  It 'keeps and reuses its DLL in a folder whose name has [ and ] (Add-Type reads wildcards there)' {
    $cfg = Join-Path $TestDrive "cfg [x]-$([guid]::NewGuid().ToString('N').Substring(0, 6))"; $null = [IO.Directory]::CreateDirectory($cfg)
    $out = InChild $cfg "Import-JsonType; $from; Get-JsonDllPath"
    $out[0] | Should -Be 'True' -Because ($out -join "`n")
    $out[1] | Should -Be 'True' -Because 'loaded from its DLL'
    [IO.Directory]::GetFiles($cfg) | Should -Be @($out[2])   # no ctop-json-tmp-* left
    $written = [IO.File]::GetLastWriteTimeUtc($out[2])
    InChild $cfg "Import-JsonType; $from" | Should -Be @('True', 'True')
    [IO.File]::GetLastWriteTimeUtc($out[2]) | Should -Be $written -Because 'the second start loads the DLL, it does not compile again'
  }
  It 'keeps its DLL when the temp folder has [ and ] too' {
    $cfg = Join-Path $TestDrive "cfg [y]-$([guid]::NewGuid().ToString('N').Substring(0, 6))"; $null = [IO.Directory]::CreateDirectory($cfg)
    $tmp = Join-Path $TestDrive "tmp [z]-$([guid]::NewGuid().ToString('N').Substring(0, 6))"; $null = [IO.Directory]::CreateDirectory($tmp)
    # TMPDIR: .NET's temp folder on Linux and macOS, which read neither TMP nor TEMP
    $out = InChild $cfg "`$env:TMP = '$tmp'; `$env:TEMP = '$tmp'; `$env:TMPDIR = '$tmp'; Import-JsonType; $from; Get-JsonDllPath; [IO.Path]::GetTempPath()"
    $out[0] | Should -Be 'True' -Because ($out -join "`n")
    $out[1] | Should -Be 'True' -Because 'loaded from its DLL'
    [IO.Directory]::GetFiles($cfg) | Should -Be @($out[2])
    $out[3].TrimEnd('\', '/') | Should -Be $tmp -Because 'the child''s temp folder is the one with [ and ]'
  }
  It 'keeps a whole DLL it can''t open for the moment, and compiles in memory instead' -Skip:(-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
    $cfg = New-Cfg
    $dll = @(InChild $cfg 'Import-JsonType | Out-Null; Get-JsonDllPath')[0]
    $written = [IO.File]::GetLastWriteTimeUtc($dll).Ticks
    # held by another program sharing only delete (as a scanner might): it can't be read, and can be deleted
    $out = InChild $cfg "`$fs = [IO.File]::Open('$dll', 'Open', 'Read', 'Delete'); try { Import-JsonType } finally { `$fs.Dispose() }; [IO.File]::Exists('$dll'); [IO.File]::GetLastWriteTimeUtc('$dll').Ticks"
    $out | Should -Be @('True', 'True', "$written") -Because 'the DLL is whole: it is left in place, not deleted and compiled again'
  }
  # Checking the DLL (GetAssemblyName) and then loading it from its path (LoadFrom) would take a lock taken between
  # the two for damage, and delete the whole DLL. And an assembly without the reader, once loaded from its path,
  # would hold its own file, which could then never be replaced.
  It 'replaces a DLL that is an assembly without the reader, and loads the new one' {
    $cfg = New-Cfg
    $dll = @(InChild $cfg 'Get-JsonDllPath')[0]
    InChild $cfg "Push-Location -LiteralPath '$cfg'; Add-Type -TypeDefinition 'namespace Wrong { public class T { } }' -OutputAssembly '$(Split-Path -Leaf $dll)' -OutputType Library; Pop-Location" | Should -BeNullOrEmpty
    { [Reflection.AssemblyName]::GetAssemblyName($dll) } | Should -Not -Throw -Because 'it is an assembly, just not the reader'
    InChild $cfg "Import-JsonType; $from; [CtopJson.Reader]::Read('{`"type`":`"user`"}').Type" | Should -Be @('True', 'True', 'user')
  }
  It 'reads its DLL once and holds nothing open after loading it' -Skip:(-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
    $cfg = New-Cfg
    $null = InChild $cfg 'Import-JsonType'
    InChild $cfg 'Import-JsonType | Out-Null; [IO.File]::Delete((Get-JsonDllPath)); [IO.File]::Exists((Get-JsonDllPath)); [bool](''CtopJson.Reader'' -as [type])' | Should -Be @('False', 'True')
  }
  It 'names its DLLs where SHA256.Create() is refused, as under a FIPS policy on Windows PowerShell 5.1' {
    if ($PSVersionTable.PSEdition -eq 'Core') { Set-ItResult -Skipped -Because '.NET 5+ makes SHA256.Create() without CryptoConfig, so the refusal can''t be put in its way here (nor does .NET 5+ apply the FIPS policy)'; return }
    $cfg = New-Cfg
    $prices = Join-Path $cfg 'prices.json'
    [IO.File]::WriteAllText($prices, '[{"Match":"x","In":1,"W5":1,"W1h":1,"Read":1,"Out":1}]')
    $names = "`$script:ConSrc = 'public class X { }'; Get-JsonDllPath; Get-ConDllPath; (Import-PricingFile '$prices').Ver"
    $want = InChild $cfg $names
    $want.Count | Should -Be 3 -Because ($want -join "`n")
    # SHA256.Create() goes through CryptoConfig on .NET Framework: a class whose constructor throws, as SHA256Managed's does under FIPS
    $refuse = 'Add-Type -TypeDefinition ''public class FipsRefused : System.Security.Cryptography.SHA256 { public FipsRefused() { throw new System.InvalidOperationException("not FIPS-validated"); } protected override void HashCore(byte[] a, int b, int c) { } protected override byte[] HashFinal() { return null; } public override void Initialize() { } }''; ' +
              '[Security.Cryptography.CryptoConfig]::AddAlgorithm([FipsRefused], ''System.Security.Cryptography.SHA256''); ' +
              'try { $null = [Security.Cryptography.SHA256]::Create(); ''created'' } catch { ''refused'' }; '
    InChild $cfg ($refuse + $names) | Should -Be (@('refused') + $want)
  }
  It 'compiles again over a damaged DLL, and a snapshot leaves it alone' {
    $cfg = New-Cfg
    $dll = @(InChild $cfg 'Get-JsonDllPath')[0]
    [IO.File]::WriteAllText($dll, 'not a DLL')
    InChild $cfg '$script:ReadOnly = $true; Import-JsonType; [CtopJson.Reader]::Read(''{"type":"user"}'').Type' | Should -Be @('True', 'user')
    [IO.File]::ReadAllText($dll) | Should -BeExactly 'not a DLL' -Because 'a snapshot writes nothing'
    InChild $cfg "Import-JsonType; $from" | Should -Be @('True', 'True')
    (Get-Item -LiteralPath $dll).Length | Should -BeGreaterThan 1000
  }
  It 'names .NET''s major version in a PowerShell 7 DLL, and deletes only names of this one and those from before' {
    $d = New-Cfg
    foreach ($n in 'ctop-json-AAAAAAAA-core10.dll', 'ctop-json-BBBBBBBB-core10.dll', 'ctop-json-CCCCCCCC-core8.dll', 'ctop-json-DDDDDDDD-core.dll',
                   'ctop-json-EEEEEEEE-desktop.dll') {
      [IO.File]::WriteAllText((Join-Path $d $n), 'x')
    }
    Remove-OldConDlls (Join-Path $d 'ctop-json-AAAAAAAA-core10.dll') 'ctop-json'
    @(Get-ChildItem -LiteralPath $d -Name | Sort-Object) | Should -Be @('ctop-json-AAAAAAAA-core10.dll', 'ctop-json-CCCCCCCC-core8.dll', 'ctop-json-EEEEEEEE-desktop.dll')
    Get-DllRuntime | Should -Be $(if ($PSVersionTable.PSEdition -eq 'Core') { "core$([Environment]::Version.Major)" } else { 'desktop' })
  }
  It 'compiles in memory, writing nothing, in a snapshot that finds no DLL' {
    $cfg = New-Cfg
    $out = InChild $cfg '$script:ReadOnly = $true; Import-JsonType; [CtopJson.Reader]::Read(''{"type":"user"}'').Type'
    $out | Should -Be @('True', 'user')
    @(Get-ChildItem -LiteralPath $cfg -Force) | Should -BeNullOrEmpty
  }
  It 'falls back to the regex reader, and still scans, where nothing compiles' {
    $cfg = New-Cfg
    $f = Join-Path $cfg 't.jsonl'
    [IO.File]::WriteAllText($f, '{"type":"user","timestamp":"2026-11-13T12:00:00.000Z","message":{"role":"user","content":"a prompt here"}}' + "`n")
    $out = InChild $cfg "function Add-Type { throw 'no compiler here' }; `$script:ScanCache = @{}; `$script:ScanVerified = @{}; `$st = Update-Scan (Get-Item -LiteralPath '$f') 'k'; `$script:EntryReader; `$st.Turns; `$st.First; [bool]('CtopJson.Reader' -as [type])"
    $out | Should -Be @('rx', '1', 'a prompt here', 'False')
    @(Get-ChildItem -LiteralPath $cfg -Name) | Should -Be @('t.jsonl')
  }
}
