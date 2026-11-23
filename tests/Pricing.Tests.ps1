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
    # (Windows PowerShell 5.1's JSON reader refuses 1e400 itself: the file is refused all the same)
    @{ Name = 'an infinite rate';      Json = '[{"Match":"x","In":1e400,"W5":1,"W1h":1,"Read":1,"Out":1}]';      Msg = $(if ($PSVersionTable.PSVersion.Major -lt 6) { '*not JSON*' } else { '*entry 1*In*' }) }
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

Describe 'where prices come from, in peek' {
  BeforeAll {
    Mock Get-WindowWidth { 160 }
    $script:ctopText = [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $PSScriptRoot) 'ctop.ps1'))
    $row = [pscustomobject]@{ NAME = 'p-one'; TITLE = ''; KIND = 'interactive'; VIA = 'cli'; STATE = 'idle'; PID = 1; 'CPU(s)' = 0; 'MEM(MB)' = 0
      AGE = '1m'; IDLE = '1m'; TURN = ''; TURNS = 1; TOOLS = 0; CTX = '-'; MODEL = 'opus-5-5'; BRANCH = '-'; COST = '$1.00'; RATE = '-'; ACTIVITY = ''
      'LAST ACTION' = '-'; CWD = '/w'; _SessionId = 's'; _Act = [pscustomobject]@{ Cost = 1.0; InTok = 0; OutTok = 0; CacheR = 0; CacheW = 0; Compacts = 0 }
      _Transcript = '/w/s.jsonl'; _StartedAt = (Get-Date) }
  }
  It 'says which price table a session''s COST comes from' {
    $script:PriceFrom = '-PricingFile /etc/prices.json'
    $text = (@(Build-Peek $row) | ForEach-Object { if ($_ -is [hashtable]) { $_.Text } else { $_ } }) -join "`n"
    $text | Should -Match '(?m)^  PRICES       -PricingFile /etc/prices\.json$'
  }
  It 'dates the built-in table as its source line does, so the two cannot drift apart' {
    $source = [regex]::Match($script:ctopText, '# Source: platform\.claude\.com\S* read (\d{4}-\d{2}-\d{2})').Groups[1].Value
    $shown  = [regex]::Match($script:ctopText, "PriceFrom = 'the built-in table, read (\d{4}-\d{2}-\d{2})").Groups[1].Value
    $source | Should -Match '^\d{4}-\d{2}-\d{2}$'
    $shown | Should -Be $source
  }
}

Describe 'the built-in price table' {
  BeforeAll {
    # the table as ctop.ps1 assigns it (Import-Ctop.ps1 loads only functions)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path -Parent $PSScriptRoot) 'ctop.ps1'), [ref]$null, [ref]$null)
    foreach ($a in $ast.EndBlock.Statements) { if ($a -is [System.Management.Automation.Language.AssignmentStatementAst] -and $a.Left.Extent.Text -eq '$script:Pricing') { . ([scriptblock]::Create($a.Extent.Text)) } }
  }
  It 'prices <Model> at its own rates, not a fallback row''s' -ForEach @(
    @{ Model = 'fable-5-2';  In = 8;  W5 = 10;   W1h = 16; Read = 0.2;  Out = 40 }   # claude-api skill, cached 2026-11-03
    @{ Model = 'mythos-5-2'; In = 8;  W5 = 10;   W1h = 16; Read = 0.2;  Out = 40 }
    @{ Model = 'fable-5-1';  In = 10; W5 = 12.5; W1h = 20; Read = 0.25; Out = 50 }
    @{ Model = 'fable-5';    In = 10; W5 = 12.5; W1h = 20; Read = 1;    Out = 50 }
    # fast mode's Foundry ids: the Fast Mode page's $16/$80 and $8/$40, with the
    # pricing page's cache multipliers on top (writes 1.25x and 2x; reads 0.025x on 5.2, 0.05x on Opus 5.5)
    @{ Model = 'claude-fable-5-2-fast';  In = 16; W5 = 20; W1h = 32; Read = 0.4; Out = 80 }
    @{ Model = 'claude-mythos-5-2-fast'; In = 16; W5 = 20; W1h = 32; Read = 0.4; Out = 80 }
    @{ Model = 'claude-opus-5-5-fast';   In = 8;  W5 = 10; W1h = 16; Read = 0.4; Out = 40 }
    @{ Model = 'claude-opus-5-5';        In = 4;  W5 = 5;  W1h = 8;  Read = 0.2; Out = 20 }
  ) {
    $p = Get-Price $Model
    @($p.In, $p.W5, $p.W1h, $p.Read, $p.Out) | Should -Be @($In, $W5, $W1h, $Read, $Out)
  }
}

# COST, CACHE's cold cost and peek all price the transcript's own id (claude-opus-5-5), not the model as MODEL
# shows it (opus-5-5), so a -PricingFile rule anchored on claude- prices all of them or none.
Describe 'a pricing file rule on the transcript''s model id' {
  BeforeAll { Mock Get-WindowWidth { 160 }; $script:Color = $false; $script:PriceVer = 2; $script:ScanVer = 2 }
  AfterAll { $script:Pricing = $null }
  It 'prices COST, RECACHE and peek''s next turn alike' {
    $script:Pricing = @(@{ Match = '^claude-opus-5-5$'; In = 4; W5 = 5; W1h = 8; Read = 0.2; Out = 20 })
    $script:ScanCache = @{}; $script:ScanVerified = @{}; $script:TailCache = @{}
    $f = Join-Path $TestDrive "f2-$([guid]::NewGuid().ToString('N')).jsonl"
    $ts = [datetime]::UtcNow.AddMinutes(-10).ToString('o')
    [IO.File]::WriteAllText($f, '{"type":"assistant","timestamp":"' + $ts + '","message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"text","text":"done"}],"usage":{"input_tokens":20000,"cache_creation_input_tokens":200000,"cache_read_input_tokens":0,"cache_creation":{"ephemeral_1h_input_tokens":200000,"ephemeral_5m_input_tokens":0},"output_tokens":5}}}' + "`n")
    $act = Get-LastAction (Get-Item -LiteralPath $f) 'f2'
    $act.Model | Should -Be 'opus-5-5'
    $act.Cost | Should -BeGreaterThan 0 -Because 'COST is priced by the rule'
    $cache = Get-CacheState $act (Get-Date)
    $cols = @([pscustomobject]@{ Name = 'CACHE'; Width = 5; Align = 'R'; Fixed = 5 })
    $r = [pscustomobject]@{ NAME = 'p-two'; TITLE = ''; KIND = 'interactive'; VIA = 'cli'; STATE = 'idle'; PID = 1; 'CPU(s)' = 0; 'MEM(MB)' = 0
      AGE = '1m'; IDLE = '1m'; TURN = ''; TURNS = 1; TOOLS = 0; CTX = '-'; MODEL = 'opus-5-5'; BRANCH = '-'; COST = '$1.00'; RATE = '-'; ACTIVITY = ''
      'LAST ACTION' = '-'; CWD = '/w'; _SessionId = 'f2'; _Act = $act; _Cache = $cache; CACHE = (Format-CacheCell $cache); _Gone = $null
      _Transcript = $f; _StartedAt = (Get-Date) }
    Format-CacheCost $cache (Get-PriceModel $act) | Should -Be '$1.76'   # 220K x $8/MTok: RECACHE
    (Get-HoverParts $r 'RECACHE').Value | Should -Match '1\.76'
    $text = (@(Build-Peek $r) | ForEach-Object { if ($_ -is [hashtable]) { $_.Text } else { $_ } }) -join "`n"
    $text | Should -Match ([regex]::Escape('next turn ≈ $0.04 warm, $1.76 cold (220K tokens)'))
  }
  # not by the newest entry's model, which can be a later entry's that set no frame: a sidechain call in the main
  # transcript, or an assistant entry with no usage
  It 'prices the cache by the call that set it, not a later <Name>' -ForEach @(
    @{ Name = 'sidechain call'; Later = '{"type":"assistant","isSidechain":true,"timestamp":"TS","message":{"id":"side","model":"opus-5-5","content":[{"type":"text","text":"reply"}],"usage":{"input_tokens":20000,"cache_creation_input_tokens":200000,"cache_read_input_tokens":0,"cache_creation":{"ephemeral_1h_input_tokens":200000,"ephemeral_5m_input_tokens":0},"output_tokens":5}}}' }
    @{ Name = 'entry with no usage'; Later = '{"type":"assistant","timestamp":"TS","message":{"model":"opus-5-5","content":"metadata only"}}' }
  ) {
    $script:Pricing = @(@{ Match = '^claude-opus-5-5$'; In = 4; W5 = 5; W1h = 8; Read = 0.2; Out = 20 }
                        @{ Match = '^opus-5-5$'; In = 20; W5 = 25; W1h = 40; Read = 0.2; Out = 20 })
    $script:ScanCache = @{}; $script:ScanVerified = @{}; $script:TailCache = @{}
    $f = Join-Path $TestDrive "r6d-$([guid]::NewGuid().ToString('N')).jsonl"
    $ts = [datetime]::UtcNow.AddMinutes(-10).ToString('o')
    $main = '{"type":"assistant","timestamp":"' + $ts + '","message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"text","text":"done"}],"usage":{"input_tokens":20000,"cache_creation_input_tokens":200000,"cache_read_input_tokens":0,"cache_creation":{"ephemeral_1h_input_tokens":200000,"ephemeral_5m_input_tokens":0},"output_tokens":5}}}'
    [IO.File]::WriteAllText($f, $main + "`n" + $Later.Replace('TS', [datetime]::UtcNow.AddMinutes(-9).ToString('o')) + "`n")
    $act = Get-LastAction (Get-Item -LiteralPath $f) 'r6d'
    $cache = Get-CacheState $act (Get-Date)
    $cols = @([pscustomobject]@{ Name = 'CACHE'; Width = 5; Align = 'R'; Fixed = 5 })
    $r = [pscustomobject]@{ NAME = 'p-two'; TITLE = ''; KIND = 'interactive'; VIA = 'cli'; STATE = 'idle'; PID = 1; 'CPU(s)' = 0; 'MEM(MB)' = 0
      AGE = '1m'; IDLE = '1m'; TURN = ''; TURNS = 1; TOOLS = 0; CTX = '-'; MODEL = 'opus-5-5'; BRANCH = '-'; COST = '$1.00'; RATE = '-'; ACTIVITY = ''
      'LAST ACTION' = '-'; CWD = '/w'; _SessionId = 'r6d'; _Act = $act; _Cache = $cache; CACHE = (Format-CacheCell $cache); _Gone = $null
      _Transcript = $f; _StartedAt = (Get-Date) }
    # the cold cost is in the RECACHE column and its hover
    Format-CacheCost $cache (Get-PriceModel $act) | Should -Be '$1.76' -Because 'msg_1 (claude-opus-5-5) set the frame: 220K x $8/MTok, not x $40'
    (Get-HoverParts $r 'RECACHE').Value | Should -Match '1\.76'
    $text = (@(Build-Peek $r) | ForEach-Object { if ($_ -is [hashtable]) { $_.Text } else { $_ } }) -join "`n"
    $text | Should -Match ([regex]::Escape('$1.76 cold (220K tokens)'))
  }
  # a later line of msg_1 with no model keeps the frame's model, rather than the sidechain's pricing the cache. A new
  # call with no model is priced as the last call that wrote the thread's cache (a policy: the transcript says
  # nothing of that call's model).
  It 'keeps the frame''s model when <Name> has none, past a sidechain call' -ForEach @(
    @{ Name = 'a later line of the same call'; Id = 'msg_1' }
    @{ Name = 'a new call'; Id = 'msg_2' }
  ) {
    $script:Pricing = @(@{ Match = '^claude-opus-5-5$'; In = 4; W5 = 5; W1h = 8; Read = 0.2; Out = 20 }
                        @{ Match = '^opus-5-5$'; In = 20; W5 = 25; W1h = 40; Read = 0.2; Out = 20 })
    $script:ScanCache = @{}; $script:ScanVerified = @{}; $script:TailCache = @{}
    $f = Join-Path $TestDrive "r7c-$([guid]::NewGuid().ToString('N')).jsonl"
    $usage = '"usage":{"input_tokens":20000,"cache_creation_input_tokens":200000,"cache_read_input_tokens":0,"cache_creation":{"ephemeral_1h_input_tokens":200000,"ephemeral_5m_input_tokens":0},"output_tokens":5}'
    $at = { param($m) [datetime]::UtcNow.AddMinutes(-$m).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture) }
    $lines = @('{"type":"assistant","timestamp":"' + (& $at 10) + '","message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"text","text":"done"}],' + $usage + '}}'
               '{"type":"assistant","isSidechain":true,"timestamp":"' + (& $at 9) + '","message":{"id":"side","model":"opus-5-5","content":[{"type":"text","text":"reply"}],' + $usage + '}}'
               '{"type":"assistant","timestamp":"' + (& $at 8) + '","message":{"id":"' + $Id + '","content":[{"type":"text","text":"more"}],' + $usage + '}}')
    [IO.File]::WriteAllText($f, ($lines -join "`n") + "`n")
    $act = Get-LastAction (Get-Item -LiteralPath $f) 'r7c'
    $act.CacheModel | Should -Be 'claude-opus-5-5'
    $cache = Get-CacheState $act (Get-Date)
    Format-CacheCost $cache (Get-PriceModel $act) | Should -Be '$1.76' -Because 'claude-opus-5-5 set the frame: 220K x $8/MTok, not the sidechain''s x $40'
  }
}

# Fast mode's own model ids (Microsoft Foundry's deployments of the fast mode model: claude-fable-5-2-fast,
# claude-mythos-5-2-fast, claude-opus-5-5-fast) have their own rows: matched by the standard rows, they would be
# priced at standard rates, half the published fast price, in both the transcript scan and the Copilot CLI reader.
Describe 'fast mode model ids, through both consumers' {
  BeforeAll {
    # the table, its version and the scan version as ctop.ps1 assigns them
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path -Parent $PSScriptRoot) 'ctop.ps1'), [ref]$null, [ref]$null)
    foreach ($a in $ast.EndBlock.Statements) {
      if ($a -is [System.Management.Automation.Language.AssignmentStatementAst] -and $a.Left.Extent.Text -in '$script:Pricing', '$script:PriceVer', '$script:ScanVer') {
        . ([scriptblock]::Create($a.Extent.Text))
      }
    }
    $script:CacheDays = 2
    # one call of each kind of token, 1M each: input, 5-minute write, 1-hour write, cache read, output
    function Write-Transcript([string]$model) {
      $at = [datetime]::UtcNow.AddMinutes(-10).ToString('o')
      $f = Join-Path $TestDrive "fast-$([guid]::NewGuid().ToString('N')).jsonl"
      [IO.File]::WriteAllText($f, '{"type":"assistant","timestamp":"' + $at + '","message":{"id":"msg_1","model":"' + $model + '","content":[{"type":"text","text":"done"}],"usage":{"input_tokens":1000000,"cache_creation_input_tokens":2000000,"cache_read_input_tokens":1000000,"cache_creation":{"ephemeral_1h_input_tokens":1000000,"ephemeral_5m_input_tokens":1000000},"output_tokens":1000000}}}' + "`n")
      Get-Item -LiteralPath $f
    }
    # the same tokens in Copilot CLI's records: inputTokens counts the cache's own, one TTL per record
    function Write-CliLog([string]$model) {
      $at = [datetime]::UtcNow.AddMinutes(-10).ToString('o')
      $d = Join-Path $TestDrive "cli-$([guid]::NewGuid().ToString('N'))"; $null = New-Item -ItemType Directory -Path $d
      $f = Join-Path $d 'events.jsonl'
      $a = '{"type":"session.usage_record","data":{"usage":{"model":"Anthropic/' + $model + '","inputTokens":3000000,"cacheReadTokens":1000000,"cacheWriteTokens":1000000,"cachePolicyTtlSeconds":300,"outputTokens":1000000,"isByok":true}},"timestamp":"' + $at + '"}'
      $b = '{"type":"session.usage_record","data":{"usage":{"model":"Anthropic/' + $model + '","inputTokens":1000000,"cacheReadTokens":0,"cacheWriteTokens":1000000,"cachePolicyTtlSeconds":3600,"outputTokens":0,"isByok":true}},"timestamp":"' + $at + '"}'
      [IO.File]::WriteAllText($f, $a + "`n" + $b + "`n")
      Get-Item -LiteralPath $f
    }
  }
  BeforeEach { $script:ScanCache = @{}; $script:ScanVerified = @{}; $script:CopilotCliScans = @{}; $script:CopilotCliActs = @{} }
  BeforeDiscovery {
    $script:fastCases = @(
      @{ Model = 'claude-fable-5-2-fast';  Total = 148.4 }   # 16 + 20 + 32 + 0.40 + 80
      @{ Model = 'claude-mythos-5-2-fast'; Total = 148.4 }
      @{ Model = 'claude-opus-5-5-fast';   Total = 74.4 }    # 8 + 10 + 16 + 0.40 + 40
      @{ Model = 'claude-fable-5-2';       Total = 74.2 }    # 8 + 10 + 16 + 0.20 + 40: the standard ids keep theirs
      @{ Model = 'claude-mythos-5-2';      Total = 74.2 }
      @{ Model = 'claude-opus-5-5';        Total = 37.2 }    # 4 + 5 + 8 + 0.20 + 20
    )
  }
  It 'prices <Model> at <Total> dollars for 1M tokens of each kind, in the transcript scan' -ForEach $script:fastCases {
    [math]::Round((Update-Scan (Write-Transcript $Model) "fast-$Model").Cost, 6) | Should -Be $Total
  }
  It 'prices <Model> at <Total> dollars for 1M tokens of each kind, in the Copilot CLI reader' -ForEach $script:fastCases {
    $cli = Update-CopilotCliScan (Write-CliLog $Model)
    $cli.Unpriced | Should -Be 0
    [math]::Round($cli.Cost, 6) | Should -Be $Total
  }
  It 'recomputes a fast id''s total saved by an older price table (version 3, standard rates), not reuse it' {
    $script:ScanCachePath = Join-Path $TestDrive "cache-$([guid]::NewGuid().ToString('N')).json"
    $f = Write-Transcript 'claude-fable-5-2-fast'
    $null = Update-Scan $f 'replay'
    Save-ScanCache
    $saved = [IO.File]::ReadAllText($script:ScanCachePath)
    $saved | Should -Match '"Cost":' -Because 'the scan was saved'
    # control: a total saved by this table is reused as it is (here a marker, $1.25), so the cache is in use
    [IO.File]::WriteAllText($script:ScanCachePath, ($saved -replace '"Cost":\s*[0-9.Ee+-]+', '"Cost":1.25'))
    $script:ScanCache = @{}; $script:ScanVerified = @{}
    Load-ScanCache
    [math]::Round((Update-Scan $f 'replay').Cost, 6) | Should -Be 1.25 -Because 'a total saved by the same table is reused'
    # what an older table saves for this file: price version 3, and the fable-5-2 row's $74.20
    [IO.File]::WriteAllText($script:ScanCachePath, ($saved -replace '"PriceVer":\s*\d+', '"PriceVer":3' -replace '"Cost":\s*[0-9.Ee+-]+', '"Cost":74.2'))
    $script:ScanCache = @{}; $script:ScanVerified = @{}
    Load-ScanCache
    [math]::Round((Update-Scan $f 'replay').Cost, 6) | Should -Be 148.4
  }
}
