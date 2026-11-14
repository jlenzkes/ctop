# The hover box: with the mouse on (Windows), the console reports pointer moves; a framed box under the cell
# the pointer rests on shows the cell in full and what its column means (the help screen's own words).
BeforeAll {
  . (Join-Path $PSScriptRoot 'Import-Ctop.ps1')
  $script:Pricing = @(@{ Match = '^priced$'; In = 5; Out = 25; Read = 0.5; W5 = 6.25; W1h = 10 })
  $script:Color = $false
  function Row([string]$name) {
    [pscustomobject]@{ NAME = $name; STATE = 'working'; CACHE = '43m'; BRANCH = 'claude/a-rather-long-branch-name'; 'LAST ACTION' = 'Bash git log --oneli…'
                       _Act = @{ Model = 'priced'; LastFull = 'Bash git log --oneline -5 --graph'; Cost = 1.0 }; _Cache = @{ Kind = 'warm'; Ttl = '1h'; MinutesLeft = 43; RecacheTokens = 220000; Anchor = [datetime]::UtcNow.AddMinutes(-17) }
                       _Parent = $null; _TreeCost = $null; COST = '$1.00' }
  }
}

Describe 'Get-ColumnAt' {
  BeforeAll { $script:ShownCols = @(@{ Name = 'NAME'; Width = 10 }, @{ Name = 'STATE'; Width = 8 }); $script:ShownSep = 2 }
  It 'is <Want> at x = <X>' -ForEach @(
    @{ X = 0; Want = 'NAME' }, @{ X = 9; Want = 'NAME' }, @{ X = 10; Want = $null }, @{ X = 12; Want = 'STATE' }
    @{ X = 19; Want = 'STATE' }, @{ X = 20; Want = $null }, @{ X = -1; Want = $null }
  ) {
    Get-ColumnAt $X | Should -Be $Want
  }
}

Describe 'Get-ColumnMeaning' {
  It 'takes a column''s words from the help screen, continuation lines joined' {
    Get-ColumnMeaning 'CACHE' | Should -Match '^prompt cache: minutes left while warm'
    Get-ColumnMeaning 'TURN' | Should -Match 'Yellow >= 10 min, red >= 30 min$'
    Get-ColumnMeaning 'LAST ACTION' | Should -Match '^newest tool call'
  }
  It 'is empty for a name that is no column' {
    Get-ColumnMeaning 'NOPE' | Should -BeNullOrEmpty
  }
}

Describe 'Get-HoverParts' {
  It 'shows a CACHE cell as peek does, and what the column means' {
    $p = Get-HoverParts (Row 'ctop-cc') 'CACHE'
    $p.Title | Should -Be 'CACHE · ctop-cc'
    $p.Value | Should -Match '^warm, 43 min left \(1h, last call [0-9:]{8}\) · next turn ≈ \$0\.11 warm, \$2\.20 cold \(220K tokens\)'
    $p.Meaning | Should -Match '^prompt cache: minutes left'
  }
  It 'shows LAST ACTION and BRANCH whole, where the cells are cut' {
    (Get-HoverParts (Row 'a') 'LAST ACTION').Value | Should -Be 'Bash git log --oneline -5 --graph'
    (Get-HoverParts (Row 'a') 'BRANCH').Value | Should -Be 'claude/a-rather-long-branch-name'
  }
  It 'names a subagent row without its tree rail' {
    (Get-HoverParts (Row '  ├ general-purpose') 'STATE').Title | Should -Be 'STATE · general-purpose'
  }
  It 'says what RECACHE prices' {
    (Get-HoverParts (Row 'a') 'RECACHE').Value | Should -Match '^\$2\.20 to write 220K tokens back into the cache \(1h\)'
  }
}

Describe 'Split-Words' {
  It 'keeps every line within <W> cells, breaking a word longer than a line' -ForEach @(@{ W = 10 }, @{ W = 16 }) {
    foreach ($l in (Split-Words 'warm, 43 min left (1h, last call 21:12:03) claude/a-rather-long-branch-name' $W 20)) {
      Get-CellWidth $l | Should -BeLessOrEqual $W
    }
  }
  It 'ends with … when there are more than <Max> lines of it' -ForEach @(@{ Max = 2 }) {
    $l = @(Split-Words ('word ' * 40) 12 $Max)
    $l.Count | Should -Be $Max
    $l[-1] | Should -Match '…$'
  }
}

Describe 'Get-HoverBox' {
  BeforeAll {
    $script:ShownCols = @(@{ Name = 'NAME'; Width = 10 }, @{ Name = 'CACHE'; Width = 5 }); $script:ShownSep = 2
    $rows = @((Row 'first'), (Row 'second'))
  }
  BeforeEach { $script:BodyY0 = 5; $script:BodyMap = @(0, 0, -1, 1, 1) }   # two rows of two lines, a gap line between
  It 'is a framed box under the hovered row, at its column''s left edge' {
    $b = Get-HoverBox ([pscustomobject]@{ Hover = [pscustomobject]@{ X = 13; Y = 6 }; PeekId = $null }) $rows 120 40
    $b.Y | Should -Be 7          # under the first row's two lines (5, 6)
    $b.X | Should -Be 12         # CACHE starts after NAME (10) and the separator (2)
    $b.Lines[0] | Should -Match '^┌ CACHE · first ─+┐$'
    $b.Lines[-1] | Should -Match '^└─+┘$'
    $w = Get-CellWidth (Strip-Ansi $b.Lines[0])
    foreach ($l in $b.Lines) { Get-CellWidth (Strip-Ansi $l) | Should -Be $w }
  }
  It 'opens above the row when there is no room below' {
    $b = Get-HoverBox ([pscustomobject]@{ Hover = [pscustomobject]@{ X = 2; Y = 9 }; PeekId = $null }) $rows 120 12
    ($b.Y + $b.Lines.Count) | Should -BeLessOrEqual 8   # ends above the second row (lines 8, 9)
  }
  It 'stays inside a narrow window' {
    $b = Get-HoverBox ([pscustomobject]@{ Hover = [pscustomobject]@{ X = 13; Y = 6 }; PeekId = $null }) $rows 30 40
    ($b.X + (Get-CellWidth (Strip-Ansi $b.Lines[0]))) | Should -BeLessOrEqual 30
  }
  It 'is none <Name>' -ForEach @(
    @{ Name = 'with no pointer seen';     Hover = $null;                                     Peek = $null }
    @{ Name = 'over the header';          Hover = [pscustomobject]@{ X = 2; Y = 3 };         Peek = $null }
    @{ Name = 'over a line between rows'; Hover = [pscustomobject]@{ X = 2; Y = 7 };         Peek = $null }
    @{ Name = 'over the gap between columns'; Hover = [pscustomobject]@{ X = 11; Y = 5 };    Peek = $null }
    @{ Name = 'below the table';          Hover = [pscustomobject]@{ X = 2; Y = 30 };        Peek = $null }
    @{ Name = 'in peek';                  Hover = [pscustomobject]@{ X = 2; Y = 5 };         Peek = 'x' }
  ) {
    Get-HoverBox ([pscustomobject]@{ Hover = $Hover; PeekId = $Peek }) $rows 120 40 | Should -BeNullOrEmpty
  }
}

Describe 'Add-HoverBox' {
  It 'draws the box over the lines, keeping what is left and right of it' {
    $lines = @('0123456789abcdefghij', @{ Text = 'ABCDEFGHIJKLMNOPQRST'; Fg = 'DarkGray' }, 'short')
    $box = @{ X = 4; Y = 0; Lines = @('┌──┐', '│xy│', '└──┘') }
    $out = Add-HoverBox $lines $box
    Strip-Ansi $out[0] | Should -Be '0123┌──┐89abcdefghij'
    Strip-Ansi $out[1] | Should -Be 'ABCD│xy│IJKLMNOPQRST'
    Strip-Ansi $out[2] | Should -Be 'shor└──┘'
  }
  It 'pads a short line out to the box' {
    $out = Add-HoverBox @('ab') @{ X = 4; Y = 0; Lines = @('┌┐') }
    Strip-Ansi $out[0] | Should -Be 'ab  ┌┐'
  }
  It 'adds lines when the box runs past the frame' {
    $out = Add-HoverBox @('a') @{ X = 0; Y = 0; Lines = @('┌┐', '└┘') }
    $out.Count | Should -Be 2
  }
  It 'leaves the lines alone with no box' {
    (Add-HoverBox @('a', 'b') $null).Count | Should -Be 2
  }
}

Describe 'Read-Keys and Show-Packet with a hover' {
  BeforeEach {
    $script:InQ = [System.Collections.Generic.Queue[object]]::new()
    $script:FlashUntil = [datetime]::MinValue
  }
  It 'records a pointer move as the view''s hover, selecting nothing' {
    $view = New-View; $view.SelectedId = 'a'
    $script:InQ.Enqueue([pscustomobject]@{ Kind = 2; X = 14; Y = 9; Buttons = [uint32]0; Flags = [uint32]1 })
    Mock Next-Input { if ($script:InQ.Count) { $script:InQ.Dequeue() } else { $null } }
    Read-Keys $view @{ Ids = @('a', 'b'); PageRows = 2 } | Out-Null
    $view.Hover.X | Should -Be 14
    $view.SelectedId | Should -Be 'a'
  }
  It 'clears the hover on a key press, so the box goes away' {
    $view = New-View; $view.Hover = [pscustomobject]@{ X = 1; Y = 1 }
    $script:InQ.Enqueue([ConsoleKeyInfo]::new([char]']', [ConsoleKey]::Oem6, $false, $false, $false))
    Mock Next-Input { if ($script:InQ.Count) { $script:InQ.Dequeue() } else { $null } }
    Read-Keys $view @{ Ids = @('a'); PageRows = 1 } | Out-Null
    $view.Hover | Should -BeNullOrEmpty
  }
  It 'keeps the footer''s key hints on the bottom line' {
    Mock Write-Frame { $script:Drawn = $footer }
    Show-Packet ([pscustomobject]@{ Lines = @('x'); Footer = '  q quit'; Ids = @(); BodyMap = @(); BodyY0 = 0 })
    $script:Drawn | Should -Be '  q quit'
    $script:ShownFooter | Should -Be '  q quit'
  }
}
