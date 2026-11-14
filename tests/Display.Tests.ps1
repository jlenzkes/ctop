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
                         STATE = 'stale'; AGE = 'stale'; IDLE = 'stale'; RATE = 'stale'; ACTIVITY = 'stale'; CACHE = 'stale'; _Cache = $null; _Dirty = $false }
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
  It 'Format-Row keeps a STATE with a +N subagent badge to its column in cells (width <Width>)' -ForEach @(
    @{ Width = 13 }   # the badge fits: own text, badge, padding
    @{ Width = 9 }    # it does not: the cell is cut to the column
  ) {
    $cols = @([pscustomobject]@{ Name = 'STATE'; Width = $Width; Align = 'L'; Fixed = $Width },
              [pscustomobject]@{ Name = 'KIND'; Width = 4; Align = 'L'; Fixed = 4 })
    $r = [pscustomobject]@{ STATE = "waiting: $([char]0x754C)"; KIND = 'test'; _LiveKids = 1 }
    $line = @(Format-Row $cols $r '  ' 1)[0]
    Get-CellWidth (Strip-Ansi $line) | Should -Be ($Width + 2 + 4) -Because "[$line]"
  }
  It 'Wrap-Cell keeps a path to <Lines> lines of <Width> cells and keeps its tail: <Name>' -ForEach @(
    @{ Name = 'wide tail, odd width';   Text = ('/x/ab/' + ([string][char]0x754C * 6));  Width = 9;  Lines = 2 }
    @{ Name = 'all wide, odd width';    Text = ([string][char]0x754C * 20);              Width = 7;  Lines = 3 }
    @{ Name = 'mixed, odd width';       Text = ('/a' + ([string][char]0x754C) + 'b') * 9; Width = 5;  Lines = 2 }
    @{ Name = 'mixed, even width';      Text = ('/a' + ([string][char]0x754C) + 'b') * 9; Width = 6;  Lines = 3 }
    @{ Name = 'emoji';                  Text = ('/p/' + ([char]::ConvertFromUtf32(0x1F600) * 8)); Width = 5; Lines = 2 }
    @{ Name = 'narrow only';            Text = '/home/u/' + ('abcdefgh' * 4);            Width = 9;  Lines = 2 }
  ) {
    $pieces = Wrap-Cell $Text $Width $Lines $true   # already an array (,$parts); @() would nest it
    $pieces.Count | Should -BeLessOrEqual $Lines -Because ($pieces -join ' | ')
    foreach ($p in $pieces) { Get-CellWidth $p | Should -BeLessOrEqual $Width }
    $joined = (-join $pieces).TrimStart([char]0x2026)
    $Text.EndsWith($joined) | Should -BeTrue -Because "the tail identifies the path: [$(-join $pieces)]"
  }
  It 'measures every BMP character, alone and after a letter, as its text elements do (the fast path agrees)' {
    # the oracle: text elements one by one, never the fast path
    function Slow([string]$t) { $w = 0; $en = [Globalization.StringInfo]::GetTextElementEnumerator($t); while ($en.MoveNext()) { $w += Get-ElementCells ([string]$en.Current) }; $w }
    $bad = [Collections.Generic.List[string]]::new()
    for ($cp = 0x20; $cp -le 0xFFFF; $cp++) {
      if ($cp -ge 0xD800 -and $cp -le 0xDFFF) { continue }
      if ($cp -ge 0x7F -and $cp -le 0x9F) { continue }   # controls: Clean / Protect-TerminalText replace them first
      $ch = [string][char]$cp
      foreach ($t in $ch, "a$ch") { if ((Get-CellWidth $t) -ne (Slow $t)) { $bad.Add(('U+{0:X4} in "{1}"' -f $cp, $(if ($t.Length -gt 1) { 'a+' } else { '' }))) } }
      if ($bad.Count -ge 10) { break }
    }
    $bad | Should -BeNullOrEmpty
  }
  It 'measures a flag (two regional indicators) as two cells' -Skip:($PSVersionTable.PSEdition -eq 'Desktop') {
    # .NET Framework (Windows PowerShell 5.1) splits the pair into two text elements: there it measures 4
    Get-CellWidth ([char]::ConvertFromUtf32(0x1F1FA) + [char]::ConvertFromUtf32(0x1F1F8)) | Should -Be 2
  }
  It 'Limit-Chars / Last-Chars keep a supplementary combining mark with its letter' {
    $mark = [char]::ConvertFromUtf32(0x1D167)          # MUSICAL SYMBOL COMBINING TREMOLO-1: a surrogate pair, category Mn
    $s = "a$($mark)x"                                   # 'a' and its mark are one text element
    Limit-Chars $s 1 | Should -BeExactly ''             # the letter cannot leave without its mark
    Limit-Chars $s 3 | Should -BeExactly "a$mark"
    Last-Chars $s 3 | Should -BeExactly 'x'             # nor the mark start a tail on its own
    Last-Chars $s 4 | Should -BeExactly $s
  }
  It 'Truncate-Ansi stops at <N> cells, with color codes around' {
    $E = [char]27; $t = "$E[31m" + ([string][char]0x754C * 5) + "$E[0m"
    $out = Truncate-Ansi $t 5
    Get-CellWidth (Strip-Ansi $out) | Should -BeLessOrEqual 5
  }
}

Describe 'Get-QuestionLines (peek: a question waiting on you)' {
  It 'gives one plain line per question, choice and note' {
    $qs = @(@{ Text = 'Which DB?'; Header = 'DB'; Multi = $false; Options = @('SQLite: fast', 'Postgres: real') },
            @{ Text = 'Which suites?'; Header = ''; Multi = $true; Options = @('unit') })
    $lines = Get-QuestionLines $qs 100
    foreach ($l in $lines) { $l | Should -BeOfType [string] }   # a nested array draws as a blank line
    ($lines -join "`n") | Should -Match 'QUESTION +\[DB\] Which DB\?'
    ($lines -join "`n") | Should -Match '1\. SQLite: fast'
    ($lines -join "`n") | Should -Match '2\. Postgres: real'
    ($lines -join "`n") | Should -Match 'Which suites\?'
    ($lines -join "`n") | Should -Match '\(choose any\)'
    $lines.Count | Should -Be 7
  }
  It 'gives nothing when no question is waiting' {
    @(Get-QuestionLines @() 100).Count | Should -Be 0
  }
}

Describe 'moving the cursor after the window shrank (a resize while a frame is drawn)' {
  It 'keeps the row inside the console buffer' {
    Mock Get-ConsoleBufferHeight { 40 }
    $t = Get-CursorTarget 0 50
    $t[1] | Should -Be 39
    (Get-CursorTarget 0 12)[1] | Should -Be 12
  }
  It 'does not stop ctop when the console refuses the move' {
    Mock Get-ConsoleBufferHeight { 0 }   # no console here (output redirected): the move itself throws
    { Set-ConsoleCursor 0 50 } | Should -Not -Throw
  }
}

Describe 'BRANCH: at most 14 wide, a longer name on the row''s second line; LAST ACTION gets the room' {
  BeforeAll {
    # the real column table, from ctop.ps1 itself (Import-Ctop defines only the functions)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path -Parent $PSScriptRoot) 'ctop.ps1'), [ref]$null, [ref]$null)
    $script:ColumnsText = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:Columns' }, $true).Right.Extent.Text
    function Columns { $cs = & ([scriptblock]::Create($script:ColumnsText)); foreach ($c in $cs) { if ($c.Auto) { $c.Floor = $c.Fixed } }; $cs }
    function Lay([object[]]$rows, [int]$avail, [string[]]$only) {
      foreach ($r in $rows) { foreach ($f in '_Widths', '_Dirty') { if (-not $r.PSObject.Properties[$f]) { $r | Add-Member $f $null } } }   # ctop's rows carry these
      $cands = @(Columns); if ($only) { $cands = @($cands | Where-Object { $_.Name -in $only }) }
      $out = @{}; foreach ($c in (Layout-Columns $cands $rows $avail '  ')) { $out[$c.Name] = [int]$c.Width }; $out
    }
    $script:Color = $false
    $one = @([pscustomobject]@{ Name = 'BRANCH'; Width = 14; Align = 'L'; Fixed = 14 })
  }
  BeforeEach {
    $script:HighWater = @{}; $script:AutoWidth = @{}; $script:HiddenCols = @(); $script:ShrinkAfter = 20
    $script:Layouts = @('wrap', 'truncate'); $script:LayoutMode = 0; $script:Compact = $false
  }
  It 'is <Want> wide for <Names>' -ForEach @(
    @{ Names = @('claude/display-polish', 'main'); Want = 14 }
    @{ Names = @('feature/x1', 'main');            Want = 10 }
    @{ Names = @('main', 'master');                Want = 6 }    # the header's own width
  ) {
    $rows = @($Names | ForEach-Object { [pscustomobject]@{ NAME = 'n'; BRANCH = $_ } })
    (Lay $rows 400)['BRANCH'] | Should -Be $Want
  }
  It 'continues a longer name on the second line' {
    $lines = Format-Row $one ([pscustomobject]@{ BRANCH = 'claude/display-columns' }) '  ' 2
    @($lines | ForEach-Object { (Strip-Ansi $_).TrimEnd() }) | Should -Be @('claude/display', '-columns')
  }
  It 'keeps the end of a name over 28 characters, in two lines' {
    $v = 'wt:claude/a-really-long-branch-name-x'
    $lines = Format-Row $one ([pscustomobject]@{ BRANCH = $v }) '  ' 2
    $lines = @($lines | ForEach-Object { (Strip-Ansi $_).TrimEnd() })
    $lines.Count | Should -Be 2
    -join $lines | Should -BeExactly ([string][char]0x2026 + $v.Substring($v.Length - 27))
  }
  It 'keeps the end in one line (truncate layout)' {
    $v = 'claude/display-columns'
    $lines = @(Format-Row $one ([pscustomobject]@{ BRANCH = $v }) '  ' 1)
    $lines.Count | Should -Be 1
    (Strip-Ansi $lines[0]).TrimEnd() | Should -BeExactly ([string][char]0x2026 + $v.Substring($v.Length - 13))
  }
  It 'gives LAST ACTION the widest share in a 199-wide window (user, 2026-11-13: BRANCH 21 vs LAST ACTION 25)' {
    $long = 'Bash cd c:/dev/src/genai-mil-s7-repairs && python -m pytest tests/test_reader.py -k fallback -q 2>&1 | tail -20'
    $rows = @(
      [pscustomobject]@{ NAME = '  ├ general-purpose (a1b2c3d4)'; TITLE = 'Build step 7 row 3.6 repair the trusted text path'; STATE = 'awaiting 3 jobs'
                         CACHE = '60m'; RECACHE = '$3.37'; TURN = '40m'; CTX = '421K'; CMP = '3'; 'LAST ACTION' = $long; ACTIVITY = ('▒' * 20)
                         BRANCH = 'claude/display-polish'; AGE = '11h57m'; CWD = 'c:\dev\src\genai-mil'; MODEL = 'fable-5-2'; VIA = 'vscode'; COST = '$185.79'
                         PID = '12345'; TURNS = '12'; TOOLS = '345'; KIND = 'interactive'; 'CPU(s)' = '12.3'; 'MEM(MB)' = '512'; RATE = '$15.10' }
    )
    $w = Lay $rows 197
    $w['BRANCH'] | Should -Be 14
    $w['RECACHE'] | Should -Be 7
    $w['LAST ACTION'] | Should -BeGreaterOrEqual 25
    foreach ($n in 'NAME', 'TITLE', 'CWD') { $w['LAST ACTION'] | Should -BeGreaterThan $w[$n] -Because "$n is $($w[$n])" }
  }
  It 'gives width another flexible column can''t use to LAST ACTION before TITLE' {
    $rows = @([pscustomobject]@{ NAME = 'short-name12'; TITLE = ('T' * 80); 'LAST ACTION' = ('L' * 120); CWD = 'c:\x\abcdefghi' })
    $w = Lay $rows 106 @('NAME', 'TITLE', 'LAST ACTION', 'CWD')   # 100 cells for the four, after 3 gaps
    $w['NAME'] | Should -Be 12
    $w['CWD'] | Should -Be 14
    $w['TITLE'] | Should -Be 21          # its share: 100 x 3/14
    $w['LAST ACTION'] | Should -Be 53    # its share (42) and the 11 cells NAME and CWD left
  }
}
