# Build-Rows on gone sessions: the real row construction, scanner and caches, with a config dir in
# TestDrive. Only Get-GitInfo is replaced (no git here). Which transcript a session has comes from the
# transcript index, as it does in ctop (rebuilt on roster polls).
BeforeAll { . (Join-Path $PSScriptRoot 'Import-Ctop.ps1') }

Describe 'Build-Rows: a gone row''s cache' {
  BeforeAll {
    Mock Get-GitInfo { @{} }
    $sid = 'g1'
    function Reply([string]$text, [int]$inTok = 0) {
      $m = @{ role = 'assistant'; model = 'm'; content = @(@{ type = 'text'; text = $text }) }
      if ($inTok) { $m.usage = @{ input_tokens = $inTok; output_tokens = 0 } }
      @{ type = 'assistant'; sessionId = $sid; timestamp = '2026-10-31T05:19:00Z'; message = $m } | ConvertTo-Json -Compress -Depth 6
    }
    function Reset-State([string]$root) {
      $script:ProjectsDir = Join-Path $root 'projects'
      New-Item -ItemType Directory -Force -Path $script:ProjectsDir | Out-Null
      $rec = @{ Session = [pscustomobject]@{ sessionId = $sid; pid = 1; cwd = '/w'; kind = 'interactive'; name = 'g-one'; startedAt = 1793400000000 }
                GoneAt = (Get-Date).AddMinutes(-3); Cleared = $false; Successor = '' }
      $script:Departed = @{ $sid = $rec }; $script:KeptGone = @($rec); $script:Roster = @()
      $script:ShowGone = $true; $script:ShowSubagents = $false
      $script:GoneRows = @{}; $script:History = @{}; $script:HistoryAt = Get-Date
      $script:FreshIds = [Collections.Generic.HashSet[string]]::new(); $script:RefreshIds = [Collections.Generic.HashSet[string]]::new()
      [void]$script:RefreshIds.Add($sid)                  # on screen: checked every frame
      $script:GoneCheckedAt = Get-Date; $script:GoneBuildMs = 60000
      $script:AllAgents = @{}; $script:SidecarCache = @{}; $script:RosterAt = Get-Date
      $script:LaunchedBy = @{}; $script:JobMap = @{}; $script:SpawnerCache = @{}
      $script:ScanCache = @{}; $script:ScanVerified = @{}; $script:TailCache = @{}; $script:PriceVer = 2; $script:ScanVer = 2
      $script:Pricing = @(@{ Match = '^m$'; In = 1000000; W5 = 0; W1h = 0; Read = 0; Out = 0 })   # $1 an input token
    }
    function Row { @(Build-Rows) | Where-Object { $_._SessionId -eq $sid } | Select-Object -First 1 }
  }

  It 'reads the transcript the index now names, when it has the same size and time as the old one' {
    Reset-State (Join-Path $TestDrive 'switch')
    $when = [datetime]::UtcNow.AddMinutes(-5)
    $a = Join-Path $script:ProjectsDir "-a/$sid.jsonl"; $b = Join-Path $script:ProjectsDir "-b/$sid.jsonl"
    foreach ($p in $a, $b) { New-Item -ItemType Directory -Force -Path (Split-Path $p) | Out-Null }
    [IO.File]::WriteAllText($a, (Reply 'alpha final') + "`n"); [IO.File]::SetLastWriteTimeUtc($a, $when)
    [IO.File]::WriteAllText($b, (Reply 'bravo final') + "`n"); [IO.File]::SetLastWriteTimeUtc($b, $when)
    $script:TranscriptIndex = @{ $sid = Get-Item -LiteralPath $a }
    (Row).'LAST ACTION' | Should -Be 'text: alpha final'
    $script:TranscriptIndex = @{ $sid = Get-Item -LiteralPath $b }   # the session's newest transcript is now b
    $r = Row
    $r._Transcript | Should -Be $b
    $r.'LAST ACTION' | Should -Be 'text: bravo final'
  }

  It 'counts a subagent write that lands while the row is being built, once the row is checked again' {
    Reset-State (Join-Path $TestDrive 'race')
    $t = Join-Path $script:ProjectsDir "-w/$sid.jsonl"
    $agent = Join-Path $script:ProjectsDir "-w/$sid/subagents/agent-a1.jsonl"
    New-Item -ItemType Directory -Force -Path (Split-Path $agent) | Out-Null
    [IO.File]::WriteAllText($t, (Reply 'parent done') + "`n")
    [IO.File]::WriteAllText($agent, (Reply 'one' 1) + "`n")                                  # $1
    $script:TranscriptIndex = @{ $sid = Get-Item -LiteralPath $t }
    # the agent writes again after the build has scanned it, before the row is stored: the _LiveKids
    # Add-Member comes right after the row (and its _AgentCost) is built
    $script:appended = $false
    Mock Add-Member -ParameterFilter { $NotePropertyName -eq '_LiveKids' } {
      if (-not $script:appended) { $script:appended = $true; [IO.File]::AppendAllText($agent, (Reply 'two' 1) + "`n") }   # +$1
      $InputObject.PSObject.Properties.Add([psnoteproperty]::new('_LiveKids', $NotePropertyValue))
    }
    [double](Row)._AgentCost | Should -Be 1 -Because 'built from what was there when it was scanned'
    $script:appended | Should -BeTrue
    [double](Row)._AgentCost | Should -Be 2 -Because 'the next check must see the agent file changed since that scan'
  }
}
