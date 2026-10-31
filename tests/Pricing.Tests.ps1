# -PricingFile: your own price table, in place of the built-in one.
BeforeAll { . (Join-Path $PSScriptRoot 'Import-Ctop.ps1') }

Describe 'Import-PricingFile' {
  BeforeAll {
    function Write-Prices([string]$name, [string]$json) { $f = Join-Path $TestDrive $name; [IO.File]::WriteAllText($f, $json); $f }
    $good = '[{"Match":"sonnet-","In":3,"W5":3.75,"W1h":6,"Read":0.3,"Out":15},{"Match":"haiku-","MaxPrompt":100000,"In":1,"W5":1.25,"W1h":2,"Read":0.1,"Out":5}]'
  }
  It 'reads a JSON array of rates per million tokens, in order' {
    $p = Import-PricingFile (Write-Prices 'good.json' $good)
    @($p.Table).Count | Should -Be 2
    $p.Table[0].Match | Should -Be 'sonnet-'
    [double]$p.Table[0].Out | Should -Be 15
    [int]$p.Table[1].MaxPrompt | Should -Be 100000
  }
  It 'versions the cached costs by the file''s content' {
    $a = Import-PricingFile (Write-Prices 'a.json' $good)
    $b = Import-PricingFile (Write-Prices 'b.json' $good)
    $c = Import-PricingFile (Write-Prices 'c.json' ($good -replace '"Out":15', '"Out":16'))
    $a.Ver | Should -Match '^file-[0-9a-f]{16}$'
    $b.Ver | Should -Be $a.Ver -Because 'the same table at another path prices the same'
    $c.Ver | Should -Not -Be $a.Ver -Because 'a changed rate must recompute cached costs'
  }
  It 'refuses <Name>, saying what is wrong' -ForEach @(
    @{ Name = 'a missing file';        Json = $null;                                                             Msg = '*not found*' }
    @{ Name = 'text that is not JSON'; Json = 'prices: cheap';                                                   Msg = '*not JSON*' }
    @{ Name = 'an object, not a list'; Json = '{"Match":"x","In":1,"W5":1,"W1h":1,"Read":1,"Out":1}';            Msg = '*array*' }
    @{ Name = 'an empty list';         Json = '[]';                                                              Msg = '*no rates*' }
    @{ Name = 'a missing rate';        Json = '[{"Match":"x","In":1,"W5":1,"W1h":1,"Out":1}]';                   Msg = '*entry 1*Read*' }
    @{ Name = 'a negative rate';       Json = '[{"Match":"x","In":-1,"W5":1,"W1h":1,"Read":1,"Out":1}]';         Msg = '*entry 1*In*' }
    @{ Name = 'a rate that is text';   Json = '[{"Match":"x","In":"cheap","W5":1,"W1h":1,"Read":1,"Out":1}]';    Msg = '*entry 1*In*' }
    @{ Name = 'a broken regex';        Json = '[{"Match":"son(net","In":1,"W5":1,"W1h":1,"Read":1,"Out":1}]';    Msg = '*entry 1*Match*' }
    @{ Name = 'a zero MaxPrompt';      Json = '[{"Match":"x","MaxPrompt":0,"In":1,"W5":1,"W1h":1,"Read":1,"Out":1}]'; Msg = '*entry 1*MaxPrompt*' }
  ) {
    $f = if ($null -eq $Json) { Join-Path $TestDrive 'nope.json' } else { Write-Prices "bad-$([guid]::NewGuid()).json" $Json }
    { Import-PricingFile $f } | Should -Throw -ExpectedMessage $Msg
  }
}

Describe 'Get-Price with a pricing file' {
  It 'prices from the file''s table, first match wins' {
    $script:Pricing = (Import-PricingFile (Join-Path $TestDrive 'p.json' | ForEach-Object { [IO.File]::WriteAllText($_, '[{"Match":"sonnet-5-5","In":7,"W5":1,"W1h":1,"Read":1,"Out":1},{"Match":"sonnet-","In":9,"W5":1,"W1h":1,"Read":1,"Out":1}]'); $_ })).Table
    [double](Get-Price 'claude-sonnet-5-5').In | Should -Be 7
    [double](Get-Price 'claude-sonnet-4-6').In | Should -Be 9
    Get-Price 'claude-opus-5-5' | Should -BeNullOrEmpty
  }
}

Describe 'Load-ScanCache and the price version' {
  BeforeAll {
    function Write-Cache([object]$priceVer) {
      $script:ScanCachePath = Join-Path $TestDrive "cache-$([guid]::NewGuid()).json"
      $e = @{ Path = '/x.jsonl'; Head = 'AAAA'; Used = (Get-Date).ToUniversalTime().Ticks; PriceVer = $priceVer; ScanVer = 4; ToolCounts = @{}; Cost = 1.5 }
      [IO.File]::WriteAllText($script:ScanCachePath, (@{ k1 = $e; k2 = ($e.Clone()) } | ConvertTo-Json -Depth 5))
    }
  }
  BeforeEach { $script:ScanCache = @{}; $script:ScanVer = 4; $script:CacheDays = 2 }
  It 'keeps entries priced by the same table (<Name>)' -ForEach @(
    @{ Name = 'built in'; Ver = 2 }
    @{ Name = 'a file';   Ver = 'file-0123456789abcdef' }
  ) {
    $script:PriceVer = $Ver; Write-Cache $Ver
    Load-ScanCache
    $script:ScanCache.Count | Should -Be 2
  }
  It 'drops entries priced by another table, and keeps loading (<Name>)' -ForEach @(
    @{ Name = 'file now, built-in cached'; Now = 'file-0123456789abcdef'; Cached = 2 }
    @{ Name = 'built-in now, file cached'; Now = 2; Cached = 'file-0123456789abcdef' }
  ) {
    $script:PriceVer = $Now; Write-Cache $Cached
    Load-ScanCache
    $script:ScanCache.Count | Should -Be 0
  }
}
