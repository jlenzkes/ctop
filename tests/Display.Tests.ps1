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
    @{ Mode = 'activity' }, @{ Mode = 'start' }, @{ Mode = 'roster' }
  ) {
    $script:SortMode = [array]::IndexOf($script:SortModes, $Mode)
    @(Sort-Rows $rows | ForEach-Object { $_._SessionId }) | Should -Be @('live', 'g-new', 'g-mid', 'g-old')
  }
  It 'sorts gone rows by cost, after the live ones, in cost mode' {
    $script:SortMode = [array]::IndexOf($script:SortModes, 'cost')
    $byCost = @(
      (Row 'live'  $null              $t0.AddHours(-1))
      (Row 'cheap' $t0.AddMinutes(-5) $t0.AddDays(-2))
      (Row 'dear'  $t0.AddDays(-3)    $t0.AddDays(-4))
    )
    $byCost[1]._Act = @{ Cost = 1.0; Ctx = '-' }; $byCost[2]._Act = @{ Cost = 50.0; Ctx = '-' }
    @(Sort-Rows $byCost | ForEach-Object { $_._SessionId }) | Should -Be @('live', 'dear', 'cheap')
  }
  It 'orders gone rows that left in the same poll (same time) by session id, so they never swap' {
    $script:SortMode = 0
    $same = $t0.AddMinutes(-3)
    $tied = @((Row 'g-b' $same $t0.AddDays(-1)), (Row 'g-c' $same $t0.AddDays(-3)), (Row 'g-a' $same $t0.AddDays(-2)))
    @(Sort-Rows $tied | ForEach-Object { $_._SessionId }) | Should -Be @('g-a', 'g-b', 'g-c')
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

Describe 'Update-GoneRow (refresh the clock-dependent cells of a gone row)' {
  BeforeAll {
    $script:TranscriptIndex = @{}; $script:History = @{ g1 = '▒█·   ' }
    function GoneRow([bool]$cleared) {
      $started = [DateTimeOffset]::UtcNow.AddHours(-3)
      [pscustomobject]@{ _SessionId = 'g1'; _Gone = (Get-Date).AddMinutes(-7); _Cleared = $cleared; _Act = @{ Cost = 6.0 }
                         _StartedAt = $started.LocalDateTime; _Src = [pscustomobject]@{ sessionId = 'g1'; startedAt = $started.ToUnixTimeMilliseconds() }
                         STATE = 'stale'; AGE = 'stale'; IDLE = 'stale'; RATE = 'stale'; ACTIVITY = 'stale'; _Dirty = $false }
    }
  }
  It 'sets STATE, AGE, IDLE, RATE and ACTIVITY from the clock and marks the row changed' {
    $r = GoneRow $false
    Update-GoneRow $r
    $r.STATE | Should -Be 'gone 7m'
    $r.AGE | Should -Match '^(2h59m|3h00m)$'
    $r.IDLE | Should -Be '-'          # no transcript on disk
    $r.RATE | Should -Be '$2.00'      # $6 over 3 h
    $r.ACTIVITY | Should -Be '▒█·   '
    $r._Dirty | Should -BeTrue
  }
  It 'reads cleared for a /clear' {
    $r = GoneRow $true
    Update-GoneRow $r
    $r.STATE | Should -Be 'cleared 7m'
  }
}

Describe 'Cell-Color on ages from Format-Since (the color must survive the day formats)' {
  BeforeAll {
    $script:HighlightModel = 'fable|mythos'
    function Working([timespan]$span) {
      $t = Format-Since $span
      [pscustomobject]@{ STATE = 'working'; IDLE = $t; TURN = $t; _Jobs = @(); _Gone = $null }
    }
    function IdleRow([timespan]$span) { [pscustomobject]@{ STATE = 'idle'; IDLE = (Format-Since $span); TURN = ''; _Jobs = @(); _Gone = $null } }
  }
  It 'turns TURN and a stalled working STATE red at <Span> (shown as <Text>)' -ForEach @(
    @{ Span = [timespan]::FromMinutes(30) },
    @{ Span = [timespan]::FromMinutes(23 * 60 + 59) },
    @{ Span = [timespan]::FromHours(24) },
    @{ Span = [timespan]::FromHours(24.5) },
    @{ Span = [timespan]::FromHours(25) },
    @{ Span = [timespan]::FromDays(10) },
    @{ Span = [timespan]::FromDays(400) }
  ) {
    $r = Working $Span
    Cell-Color 'TURN' $r | Should -Be 'red'
    Cell-Color 'STATE' $r | Should -Be 'red'
    Cell-Color 'IDLE' (IdleRow $Span) | Should -Be 'dim'
  }
  It 'keeps the thresholds below an hour: <Span> -> TURN <Turn>, working STATE <State>' -ForEach @(
    @{ Span = [timespan]::FromSeconds(50); Turn = '';       State = 'green' }
    @{ Span = [timespan]::FromMinutes(2);  Turn = '';       State = 'red' }
    @{ Span = [timespan]::FromMinutes(10); Turn = 'yellow'; State = 'red' }
    @{ Span = [timespan]::FromMinutes(29); Turn = 'yellow'; State = 'red' }
  ) {
    $r = Working $Span
    Cell-Color 'TURN' $r | Should -Be $Turn
    Cell-Color 'STATE' $r | Should -Be $State
  }
}

Describe 'ConvertFrom-UnixMs (roster startedAt, which ctop does not control)' {
  It 'converts milliseconds since 1970 to local time' {
    ConvertFrom-UnixMs 1793400000000 | Should -Be ([DateTimeOffset]::FromUnixTimeMilliseconds(1793400000000).LocalDateTime)
  }
  It 'gives $null for <Name> instead of failing' -ForEach @(
    @{ Name = 'nothing';      Ms = $null }
    @{ Name = 'zero';         Ms = 0 }
    @{ Name = 'out of range'; Ms = 99999999999999999 }
    @{ Name = 'negative';     Ms = -5 }
    @{ Name = 'text';         Ms = 'soon' }
  ) {
    ConvertFrom-UnixMs $Ms | Should -BeNullOrEmpty
  }
}

Describe 'Protect-TerminalText (everything drawn goes through it)' {
  BeforeAll { $E = [char]27; $BEL = [char]7 }
  It 'keeps the color codes ctop paints with' {
    Protect-TerminalText "$E[31mred$E[0m plain" | Should -BeExactly "$E[31mred$E[0m plain"
  }
  It 'neutralizes <Name>' -ForEach @(
    @{ Name = 'OSC 52 (set the clipboard)'; Text = "a$([char]27)]52;c;QUJD$([char]7)b" }
    @{ Name = 'OSC 0 (set the title)';     Text = "a$([char]27)]0;owned$([char]27)\b" }
    @{ Name = 'a cursor move';             Text = "a$([char]27)[2;5Hb" }
    @{ Name = 'clear screen';              Text = "a$([char]27)[2Jb" }
    @{ Name = 'an 8-bit CSI (C1)';         Text = "a$([char]0x9B)2Jb" }
    @{ Name = 'BEL';                       Text = "a$([char]7)b" }
  ) {
    $out = Protect-TerminalText $Text
    $out | Should -Not -Match "[\x00-\x1A\x1C-\x1F\x7F-\x9F]"
    # any ESC left must start a color code
    ([regex]::Matches($out, "\x1b(?!\[[0-9;]*m)")).Count | Should -Be 0
  }
  It 'turns line breaks and tabs into spaces (a break would split the row)' {
    Protect-TerminalText "one`ntwo`r`nthree`tfour" | Should -BeExactly 'one two  three four'
  }
}

Describe 'terminal cell widths' {
  BeforeAll {
    $cjk = [string]::new([char[]]@([char]0x754C, [char]0x754C))                 # 界界
    $acute = "e$([char]0x0301)"                                                   # e + combining acute
    $grin = [char]::ConvertFromUtf32(0x1F600)                                     # 😀 (a surrogate pair)
    function NoLoneSurrogate([string]$s) {
      for ($i = 0; $i -lt $s.Length; $i++) {
        if ([char]::IsHighSurrogate($s[$i])) { if ($i + 1 -ge $s.Length -or -not [char]::IsLowSurrogate($s[$i + 1])) { return $false }; $i++ }
        elseif ([char]::IsLowSurrogate($s[$i])) { return $false }
      }
      $true
    }
  }
  It 'measures <Name> as <Cells> cells' -ForEach @(
    @{ Name = 'ASCII';                       Text = 'abc';                                   Cells = 3 }
    @{ Name = 'nothing';                     Text = '';                                      Cells = 0 }
    @{ Name = 'two CJK characters';          Text = [string]::new([char[]]@([char]0x754C, [char]0x754C)); Cells = 4 }
    @{ Name = 'a combining accent';          Text = "e$([char]0x0301)";                      Cells = 1 }
    @{ Name = 'an emoji (surrogate pair)';   Text = [char]::ConvertFromUtf32(0x1F600);        Cells = 2 }
    @{ Name = 'a zero-width joiner';         Text = "a$([char]0x200D)b";                     Cells = 2 }
    @{ Name = 'ctop''s own symbols';         Text = '█▒·▁░▼∞→│…Σ';                           Cells = 11 }
    @{ Name = 'Hangul';                      Text = [string]::new([char[]]@([char]0xD55C, [char]0xAE00)); Cells = 4 }
    @{ Name = 'fullwidth letters';           Text = [string]::new([char[]]@([char]0xFF21, [char]0xFF22)); Cells = 4 }
  ) {
    Get-CellWidth $Text | Should -Be $Cells
  }
  It 'Fit makes exactly <Width> cells of <Name>, without splitting a character' -ForEach @(
    @{ Name = 'two CJK in 4';  Text = [string]::new([char[]]@([char]0x754C, [char]0x754C)); Width = 4 }
    @{ Name = 'three CJK in 4'; Text = [string]::new([char[]]@([char]0x754C, [char]0x754C, [char]0x754C)); Width = 4 }
    @{ Name = 'three CJK in 5'; Text = [string]::new([char[]]@([char]0x754C, [char]0x754C, [char]0x754C)); Width = 5 }
    @{ Name = 'emoji in 2';    Text = ([char]::ConvertFromUtf32(0x1F600) * 3); Width = 2 }
    @{ Name = 'emoji in 3';    Text = ([char]::ConvertFromUtf32(0x1F600) * 3); Width = 3 }
    @{ Name = 'accents in 3';  Text = ("e$([char]0x0301)" * 5); Width = 3 }
    @{ Name = 'ASCII in 4';    Text = 'abcdefgh'; Width = 4 }
  ) {
    foreach ($align in 'L', 'R') {
      $out = Fit $Text $Width $align
      Get-CellWidth $out | Should -Be $Width
      NoLoneSurrogate $out | Should -BeTrue
    }
  }
  It 'Fit keeps short text as is, padded: <Name>' -ForEach @(
    @{ Name = 'CJK'; Text = [string]::new([char[]]@([char]0x754C, [char]0x754C)); Width = 6; Want = ([string]::new([char[]]@([char]0x754C, [char]0x754C)) + '  ') }
  ) {
    Fit $Text $Width 'L' | Should -BeExactly $Want
  }
  It 'Limit-Cells cuts on whole characters: <Name>' -ForEach @(
    @{ Name = 'CJK in 3';       Text = [string]::new([char[]]@([char]0x754C, [char]0x754C)); Cells = 3; Want = [string][char]0x754C }
    @{ Name = 'accent kept';    Text = "e$([char]0x0301)x"; Cells = 1; Want = "e$([char]0x0301)" }
    @{ Name = 'emoji not half'; Text = ([char]::ConvertFromUtf32(0x1F600) + 'x'); Cells = 1; Want = '' }
    @{ Name = 'ASCII';          Text = 'abcdef'; Cells = 2; Want = 'ab' }
  ) {
    Limit-Cells $Text $Cells | Should -BeExactly $Want
  }
  It 'Wrap-Cell keeps every piece within the width: <Name>' -ForEach @(
    @{ Name = 'a CJK title'; Text = ([string]::new([char[]]@([char]0x6F22, [char]0x5B57, [char]0x306E, [char]0x30BF, [char]0x30A4, [char]0x30C8, [char]0x30EB)) * 4); Width = 9; Lines = 3; Path = $false }
    @{ Name = 'a CJK path';  Text = ('/home/u/' + ([string]::new([char[]]@([char]0x6F22, [char]0x5B57)) * 10)); Width = 9; Lines = 2; Path = $true }
    @{ Name = 'emoji words'; Text = (([char]::ConvertFromUtf32(0x1F600) * 3 + ' ') * 6); Width = 7; Lines = 3; Path = $false }
  ) {
    foreach ($piece in (Wrap-Cell $Text $Width $Lines $Path)) {
      Get-CellWidth $piece | Should -BeLessOrEqual $Width
      NoLoneSurrogate $piece | Should -BeTrue
    }
  }
  It 'Format-Row pads every cell to its column in cells, so the next column lines up (<Align>)' -ForEach @(@{ Align = 'L' }, @{ Align = 'R' }) {
    $cols = @([pscustomobject]@{ Name = 'NAME'; Width = 12; Align = $Align; Fixed = 0 },
              [pscustomobject]@{ Name = 'KIND'; Width = 5; Align = 'L'; Fixed = 5 })
    $wide = [pscustomobject]@{ NAME = ([string]::new([char[]]@([char]0x65E5, [char]0x672C, [char]0x8A9E)) + '-x'); KIND = 'k' }
    $plain = [pscustomobject]@{ NAME = 'plain-x'; KIND = 'k' }
    foreach ($r in $wide, $plain) {
      $line = @(Format-Row $cols $r '  ' 1)[0]
      Get-CellWidth (Strip-Ansi $line) | Should -Be (12 + 2 + 5) -Because "[$line]"
    }
  }
  It 'Truncate-Ansi stops at <N> cells, with color codes around' {
    $E = [char]27; $t = "$E[31m" + ([string][char]0x754C * 5) + "$E[0m"
    $out = Truncate-Ansi $t 5
    Get-CellWidth (Strip-Ansi $out) | Should -BeLessOrEqual 5
  }
}
