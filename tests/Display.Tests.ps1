# Display helpers: how ages read, and where gone rows sort.
BeforeAll { . (Join-Path $PSScriptRoot 'Import-Ctop.ps1') }

Describe 'Format-Since' {
  It 'shows <Span> as <Text>' -ForEach @(
    @{ Span = [timespan]::FromSeconds(0);    Text = '0s' }
    @{ Span = [timespan]::FromSeconds(42);   Text = '42s' }
    @{ Span = [timespan]::FromMinutes(5.5);  Text = '5m' }
    @{ Span = [timespan]::FromMinutes(90);   Text = '1h' }
    @{ Span = [timespan]::FromHours(23.9);   Text = '23h' }
    @{ Span = [timespan]::FromHours(24);     Text = '1d' }
    @{ Span = [timespan]::FromHours(25);     Text = '1d1h' }
    @{ Span = [timespan]::FromHours(49);     Text = '2d1h' }
    @{ Span = [timespan]::FromDays(9.99);    Text = '9d23h' }
    @{ Span = [timespan]::FromDays(10.5);    Text = '10d' }
    @{ Span = [timespan]::FromDays(400);     Text = '400d' }
    @{ Span = [timespan]::FromMinutes(-3);   Text = '0s' }   # clock skew: never negative
  ) {
    Format-Since $Span | Should -Be $Text
  }
}

Describe 'Sort-Rows: gone rows' {
  BeforeAll {
    $script:SortModes = @('activity', 'roster', 'start', 'cost', 'ctx')
    $t0 = [datetime]'2026-10-31T12:00:00'
    function Row([string]$id, $gone, [datetime]$started, [string]$state = 'idle') {
      [pscustomobject]@{ _SessionId = $id; _Gone = $gone; _StartedAt = $started; STATE = $(if ($gone) { 'gone' } else { $state })
                         NAME = $id; PID = '-'; _Parent = $null; _LaunchedBy = $null; _Spawner = ''; _Order = 0; _Depth = 0
                         _Act = @{ Cost = 0.0; Ctx = '-' }; _AgentCost = 0.0 }
    }
    # started order (old → new) deliberately differs from gone order (newest gone = g-new)
    $rows = @(
      (Row 'g-old' $t0.AddDays(-3)     $t0.AddDays(-10))
      (Row 'live'  $null               $t0.AddHours(-1))
      (Row 'g-new' $t0.AddMinutes(-5)  $t0.AddDays(-20))
      (Row 'g-mid' $t0.AddHours(-2)    $t0.AddDays(-1))
    )
  }
  It 'puts live sessions first, then gone ones, most recently gone first (<Mode>)' -ForEach @(
    @{ Mode = 'activity' }, @{ Mode = 'start' }
  ) {
    $script:SortMode = [array]::IndexOf($script:SortModes, $Mode)
    @(Sort-Rows $rows | ForEach-Object { $_._SessionId }) | Should -Be @('live', 'g-new', 'g-mid', 'g-old')
  }
}

Describe 'Sort-Rows: subagent placement (characterization: must not change when sorting gets faster)' {
  BeforeAll {
    $script:SortModes = @('activity', 'roster', 'start', 'cost', 'ctx')
    $t0 = [datetime]'2026-10-31T12:00:00'
    function Sess([string]$id, [datetime]$started) {
      [pscustomobject]@{ _SessionId = $id; _Gone = $null; _StartedAt = $started; STATE = 'idle'; NAME = $id; PID = '-'
                         _Parent = $null; _LaunchedBy = $null; _Spawner = ''; _Order = 0; _Depth = 0; _Act = @{ Cost = 0.0; Ctx = '-' }; _AgentCost = 0.0 }
    }
    function Sub([string]$id, [string]$parent, [string]$spawner, [datetime]$started, [int]$depth = 1) {
      [pscustomobject]@{ _SessionId = $id; _Gone = $null; _StartedAt = $started; STATE = 'stopped'; NAME = "  └ $id"; PID = '-'
                         _Parent = $parent; _LaunchedBy = $null; _Spawner = $spawner; _Order = 0; _Depth = $depth; _Act = @{ Cost = 0.0; Ctx = '-' }; _AgentCost = 0.0 }
    }
    $rows = @(
      (Sub 'sub:a2'  'A' ''       $t0.AddMinutes(2))
      (Sess 'B' $t0.AddHours(-1))
      (Sub 'sub:a1x' 'A' 'sub:a1' $t0.AddMinutes(3) 2)
      (Sess 'A' $t0.AddHours(-2))
      (Sub 'sub:b1'  'B' ''       $t0.AddMinutes(1))
      (Sub 'sub:a1'  'A' ''       $t0.AddMinutes(1))
    )
  }
  It 'emits each session followed by its agents depth-first, sessions oldest first' {
    $script:SortMode = 0
    @(Sort-Rows $rows | ForEach-Object { $_._SessionId }) | Should -Be @('A', 'sub:a1', 'sub:a1x', 'sub:a2', 'B', 'sub:b1')
  }
}

Describe 'Test-SampleActivity (which rows get a sparkline sample)' {
  It 'samples a live row' { Test-SampleActivity -Gone $false -History '' | Should -BeTrue }
  It 'samples a gone row while its last activity is still scrolling off' { Test-SampleActivity -Gone $true -History '██·  ' | Should -BeTrue }
  It 'leaves a gone row with no activity alone (history rows: their sparkline must not change, or every row re-renders)' {
    Test-SampleActivity -Gone $true -History '' | Should -BeFalse
    Test-SampleActivity -Gone $true -History $null | Should -BeFalse
    Test-SampleActivity -Gone $true -History (' ' * 20) | Should -BeFalse
  }
}

Describe 'Format-Rate (COST per hour since start)' {
  BeforeAll { $now = [datetime]'2026-10-31T12:00:00' }
  It 'divides cost by hours since start' {
    Format-Rate -Cost 10 -Started $now.AddHours(-2) -Now $now | Should -Be '$5.00'
  }
  It 'shows - with no cost, no start, or under 3 minutes of age' {
    Format-Rate -Cost 0 -Started $now.AddHours(-2) -Now $now | Should -Be '-'
    Format-Rate -Cost 5 -Started $null -Now $now | Should -Be '-'
    Format-Rate -Cost 5 -Started $now.AddMinutes(-2) -Now $now | Should -Be '-'
  }
}
