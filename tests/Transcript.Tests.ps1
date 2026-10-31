# Reading transcripts: JSON string values pulled out by regex must be unescaped, and cached scan state
# from an older scan format is redone.
BeforeAll { . (Join-Path $PSScriptRoot 'Import-Ctop.ps1') }

Describe 'Unescape-Json' {
  It 'turns <Raw> into <Text>' -ForEach @(
    @{ Raw = 'plain text';            Text = 'plain text' }
    @{ Raw = 'a full \"repo\" please'; Text = 'a full "repo" please' }
    @{ Raw = 'line one\nline two';    Text = "line one`nline two" }
    @{ Raw = 'C:\\dev\\src';          Text = 'C:\dev\src' }
    @{ Raw = 'caf\u00e9';             Text = 'café' }
    @{ Raw = 'tab\there';             Text = "tab`there" }
    @{ Raw = '';                      Text = '' }
  ) {
    Unescape-Json $Raw | Should -BeExactly $Text
  }
  It 'returns text that is not a valid JSON string body unchanged' {
    Unescape-Json 'bad \x escape' | Should -BeExactly 'bad \x escape'
  }
}

Describe 'Update-Scan: titles' {
  BeforeAll {
    $script:ScanCache = @{}; $script:ScanVerified = @{}; $script:PriceVer = 2; $script:ScanVer = 2
    $script:Prices = @{}
  }
  It 'reads a first prompt containing quotes as plain text' {
    $f = Join-Path $TestDrive 's1.jsonl'
    $line = @{ type = 'user'; sessionId = 's1'; timestamp = '2026-10-31T05:19:00Z'; message = @{ role = 'user'; content = 'Please turn this one file into a full "repo" by adding a README' } } | ConvertTo-Json -Compress -Depth 5
    Set-Content -LiteralPath $f -Value $line
    $st = Update-Scan (Get-Item -LiteralPath $f) 's1'
    $st.First | Should -BeExactly 'Please turn this one file into a full "repo" by adding a README'
  }
  It 'stamps new scan state with the current scan version' {
    $f = Join-Path $TestDrive 's2.jsonl'
    Set-Content -LiteralPath $f -Value (@{ type = 'user'; sessionId = 's2'; message = @{ role = 'user'; content = 'hello there' } } | ConvertTo-Json -Compress -Depth 5)
    (Update-Scan (Get-Item -LiteralPath $f) 's2').ScanVer | Should -Be $script:ScanVer
  }
}

Describe 'Load-ScanCache: scan format version' {
  BeforeEach {
    $script:ScanCache = @{}; $script:PriceVer = 2; $script:ScanVer = 2; $script:CacheDays = 2
    $script:ScanCachePath = Join-Path $TestDrive "cache-$([guid]::NewGuid()).json"
    $used = (Get-Date).ToUniversalTime().Ticks
    $entry = { param($ver) $e = @{ Path = '/x.jsonl'; Head = 'AAAA'; Used = $used; PriceVer = 2; ToolCounts = @{}; First = 'x' }; if ($null -ne $ver) { $e.ScanVer = $ver }; $e }
    @{ current = (& $entry 2); old = (& $entry 1); none = (& $entry $null) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:ScanCachePath
  }
  It 'keeps entries of the current scan version and drops older ones (they are rescanned once)' {
    Load-ScanCache
    @($script:ScanCache.Keys | Sort-Object) | Should -Be @('current')
  }
}
