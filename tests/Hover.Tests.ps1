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
  It 'ends COST''s words with where prices come from' {
    $script:PriceFrom = 'the built-in table, read today'; $script:ColumnMeaning = $null
    Get-ColumnMeaning 'COST' | Should -Match 'Yellow >= \$100 Prices: the built-in table, read today$'
  }
  It 'is empty for a name that is no column' {
    Get-ColumnMeaning 'NOPE' | Should -BeNullOrEmpty
  }
  It 'has words for every column of the table' {
    # the real column table, from ctop.ps1 itself (Import-Ctop defines only the functions)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path -Parent $PSScriptRoot) 'ctop.ps1'), [ref]$null, [ref]$null)
    $text = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:Columns' }, $true).Right.Extent.Text
    $names = @((& ([scriptblock]::Create($text))) | ForEach-Object { $_.Name })
    $names.Count | Should -BeGreaterThan 20
    $script:ColumnMeaning = $null
    @($names | Where-Object { -not (Get-ColumnMeaning $_) }) | Should -BeNullOrEmpty
    Get-ColumnMeaning 'MEM(MB)' | Should -Match 'memory'
    Get-ColumnMeaning 'CPU(s)' | Should -Match 'CPU'
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
  It 'drops control characters from the value and the title, as the table''s cells do' {
    $r = [pscustomobject]@{ NAME = "n$([char]27)[31mred"; 'LAST ACTION' = 'x'; _Act = @{ LastFull = "a$([char]27)[31mred$([char]27)[0m b" } }
    $p = Get-HoverParts $r 'LAST ACTION'
    $p.Value | Should -Not -Match '[\x00-\x1F\x7F]'
    $p.Title | Should -Not -Match '[\x00-\x1F\x7F]'
  }
  # U+009B (CSI) and U+009D (OSC) too, which the table's cells still let through (D21)
  It 'drops C1 control characters (U+0080 to U+009F) from the value and the title' {
    $c1 = "$([char]0x80)$([char]0x9B)31m$([char]0x9D)0;t$([char]0x9C)$([char]0x9F)"
    $r = [pscustomobject]@{ NAME = "n${c1}x"; 'LAST ACTION' = 'x'; _Act = @{ LastFull = "a$([char]27)b$([char]0x7F)c${c1}d" } }
    $p = Get-HoverParts $r 'LAST ACTION'
    $p.Value | Should -Not -Match '[\x00-\x1F\x7F-\x9F]'
    $p.Title | Should -Not -Match '[\x00-\x1F\x7F-\x9F]'
    $p.Value | Should -Be 'a b c 31m 0;t d'
    $p.Title | Should -Be 'LAST ACTION · n 31m 0;t x'
  }
  It 'says what RECACHE prices' {
    (Get-HoverParts (Row 'a') 'RECACHE').Value | Should -Match '^\$2\.20 to write 220K tokens back into the cache \(1h\)'
  }
  # COST's meaning ends with the pricing file's name: a U+009B in it must be gone before the word wrap (it
  # changes the line breaks at width 19), not only at output, where Write-Frame removes it
  Context 'with a control character in the pricing file''s name' {
    BeforeAll { $script:SavedPriceFrom = $script:PriceFrom }
    AfterAll { $script:PriceFrom = $script:SavedPriceFrom; $script:ColumnMeaning = $null }
    It 'drops it from COST''s meaning, as from the value and the title, before the box wraps it' {
      $c = "$([char]0x9B)$([char]0x85)$([char]27)"
      $script:PriceFrom = "-PricingFile C:\p\audit${c}-pricing.json"; $script:ColumnMeaning = $null
      $p = Get-HoverParts (Row 'a') 'COST'
      $p.Meaning | Should -Not -Match '[\x00-\x1F\x7F-\x9F]'
      $p.Meaning | Should -Match 'audit -pricing\.json$'
    }
    It 'wraps COST''s meaning as it would with a space in the character''s place (width <Width>)' -ForEach @(@{ Width = 19 }, @{ Width = 24 }, @{ Width = 40 }, @{ Width = 61 }) {
      $script:ShownCols = @(@{ Name = 'COST'; Width = 10 }); $script:ShownSep = 2
      $script:BodyY0 = 4; $script:BodyMap = @(0, 0)
      $view = [pscustomobject]@{ Hover = [pscustomobject]@{ X = 3; Y = 4 }; PeekId = $null }
      $script:PriceFrom = "-PricingFile C:\p\audit$([char]0x9B)-pricing.json"; $script:ColumnMeaning = $null
      $late = @((Get-HoverBox $view @(Row 'a') $Width 30).Lines)
      $script:PriceFrom = '-PricingFile C:\p\audit -pricing.json'; $script:ColumnMeaning = $null
      $early = @((Get-HoverBox $view @(Row 'a') $Width 30).Lines)
      ($late -join "`n") | Should -Not -Match '[\x80-\x9F]'
      ($late -join "`n") | Should -BeExactly ($early -join "`n")
    }
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
    $rows = @((Row 'first'), (Row 'second'))
  }
  BeforeEach {
    $script:ShownCols = @(@{ Name = 'NAME'; Width = 10 }, @{ Name = 'CACHE'; Width = 5 }); $script:ShownSep = 2
    $script:BodyY0 = 5; $script:BodyMap = @(0, 0, -1, 1, 1)   # two rows of two lines, a gap line between
  }   # two rows of two lines, a gap line between
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
  # Write-Frame draws a line's first width - 1 cells, so a box reaching the last column would lose its right edge
  It 'keeps its right edge on screen, in the first width - 1 cells Write-Frame draws (width <Width>, column at <X>)' -ForEach @(
    @{ Width = 30; X = 13 }, @{ Width = 60; X = 13 }, @{ Width = 70; X = 13 }, @{ Width = 120; X = 13 }
  ) {
    $script:ShownCols = @(@{ Name = 'NAME'; Width = 10 }, @{ Name = 'CACHE'; Width = 5 }, @{ Name = 'BRANCH'; Width = 100 })
    $b = Get-HoverBox ([pscustomobject]@{ Hover = [pscustomobject]@{ X = $X; Y = 6 }; PeekId = $null }) $rows $Width 40
    ($b.X + (Get-CellWidth (Strip-Ansi $b.Lines[0]))) | Should -BeLessOrEqual ($Width - 1)
  }
  It 'keeps its right edge on screen when pushed left from a column near the right' {
    $script:ShownCols = @(@{ Name = 'NAME'; Width = 10 }, @{ Name = 'CACHE'; Width = 5 }, @{ Name = 'BRANCH'; Width = 100 })
    $b = Get-HoverBox ([pscustomobject]@{ Hover = [pscustomobject]@{ X = 20; Y = 6 }; PeekId = $null }) $rows 70 40
    ($b.X + (Get-CellWidth (Strip-Ansi $b.Lines[0]))) | Should -Be 69
  }
  It 'lines up its right edge with control characters in the value' {
    $r = [pscustomobject]@{ NAME = 'n'; 'LAST ACTION' = 'x'; _Act = @{ LastFull = "a$([char]27)[31mred$([char]27)[0m b" } }
    $script:ShownCols = @(@{ Name = 'NAME'; Width = 10 }, @{ Name = 'LAST ACTION'; Width = 20 })
    $script:BodyMap = @(0, 0)
    $b = Get-HoverBox ([pscustomobject]@{ Hover = [pscustomobject]@{ X = 13; Y = 5 }; PeekId = $null }) @($r) 120 40
    $w = @($b.Lines | ForEach-Object { Get-CellWidth (Strip-Ansi (Protect-TerminalText $_)) } | Select-Object -Unique)
    $w.Count | Should -Be 1
  }
  It 'shows a long value whole, and the column''s meaning whole, when the window holds them' {
    $long = [pscustomobject]@{ NAME = 'long'; 'LAST ACTION' = 'Bash x…'; _Act = @{ LastFull = ('x' * 350) + 'ENDMARK' } }
    $script:ShownCols = @(@{ Name = 'NAME'; Width = 12 }, @{ Name = 'LAST ACTION'; Width = 50 })
    $b = Get-HoverBox ([pscustomobject]@{ Hover = [pscustomobject]@{ X = 15; Y = 5 }; PeekId = $null }) @($long) 120 40
    $text = (($b.Lines | ForEach-Object { Strip-Ansi $_ }) -join '') -replace '[│ ]', ''
    $text | Should -Match ('x{350}ENDMARK')   # the value, across its lines
    $text | Should -Not -Match '…'
    $text | Should -Match 'answerinthatsession'   # the meaning's last words (spaces and frame removed)
  }
  It 'in a short window, never covers the hovered row nor leaves the window, and is cut with … to fit (height 8, row at 4)' {
    $long = [pscustomobject]@{ NAME = 'long'; 'LAST ACTION' = 'Bash x…'; _Act = @{ LastFull = ('x' * 350) + 'ENDMARK' } }
    $script:ShownCols = @(@{ Name = 'NAME'; Width = 12 }, @{ Name = 'LAST ACTION'; Width = 50 })
    $script:BodyY0 = 4; $script:BodyMap = @(0, 0)   # the row's lines are 4 and 5; 6 is free, 7 is the footer
    $b = Get-HoverBox ([pscustomobject]@{ Hover = [pscustomobject]@{ X = 15; Y = 4 }; PeekId = $null }) @($long) 120 8
    $b.Y | Should -BeGreaterOrEqual 0
    ($b.Y + $b.Lines.Count - 1) | Should -BeLessOrEqual 3   # above the row: more room there (4 lines) than below (1)
    $b.Lines[0] | Should -Match '^┌'
    $b.Lines[-1] | Should -Match '^└─+┘$'
    (Strip-Ansi $b.Lines[-2]) | Should -Match '… │$'
  }
  It 'opens above, whole, when only above has room for it' {
    $script:BodyY0 = 14; $script:BodyMap = @(0, 0)
    $b = Get-HoverBox ([pscustomobject]@{ Hover = [pscustomobject]@{ X = 2; Y = 14 }; PeekId = $null }) $rows 120 18
    ($b.Y + $b.Lines.Count) | Should -Be 14
    (($b.Lines | ForEach-Object { Strip-Ansi $_ }) -join '') | Should -Not -Match '…'
  }
  # with one row of one line the body map is [0], which PowerShell reads as false
  It 'shows the box for the only row, one line high (body map of a single 0, as <Kind>)' -ForEach @(
    @{ Kind = 'an array' }, @{ Kind = 'a List[int]' }
  ) {
    $script:BodyY0 = 5
    $script:BodyMap = if ($Kind -eq 'an array') { @(0) } else { $l = [System.Collections.Generic.List[int]]::new(); $l.Add(0); , $l }
    $b = Get-HoverBox ([pscustomobject]@{ Hover = [pscustomobject]@{ X = 13; Y = 5 }; PeekId = $null }) @(Row 'only') 120 40
    $b | Should -Not -BeNullOrEmpty
    $b.Y | Should -Be 6
    $b.Lines[0] | Should -Match '^┌ CACHE · only ─+┐$'
  }
  It 'is none when neither side has room for one line of it' {
    $script:BodyY0 = 1; $script:BodyMap = @(0, 0)
    Get-HoverBox ([pscustomobject]@{ Hover = [pscustomobject]@{ X = 2; Y = 1 }; PeekId = $null }) $rows 120 5 | Should -BeNullOrEmpty
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
  It 'keeps the text right of the box in its cells when a wide character straddles the box''s right edge' {
    $base = 'abcd' + [string][char]0x4E2D + 'XYZ'   # 中 in cells 4 and 5; the box covers 2 to 4
    $out = Add-HoverBox @($base) @{ X = 2; Y = 0; Lines = @('┌─┐') }
    Strip-Ansi $out[0] | Should -Be 'ab┌─┐ XYZ'
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

# A table of one row, one line high, has the body map [0], which PowerShell reads as false: the frame must
# still draw a hover box over it, and a click on it must still select it
Describe 'a lone row of one line' {
  It 'is selected by a click on it' {
    $script:BodyY0 = 5; $script:BodyMap = @(0)
    Mock Get-WindowHeight { 40 }
    $top = try { [Console]::WindowTop } catch { 0 }
    $act = Resolve-Mouse ([pscustomobject]@{ X = 3; Y = 5 + $top; Buttons = [uint32]1; Flags = [uint32]0 }) '  q quit' $false -1
    $act | Should -Not -BeNullOrEmpty
    $act.Select | Should -Be 0
  }
  It 'gets the hover box in the frame drawn for it' {
    Mock Read-Roster { }; Mock Read-ProcPoll { }; Mock Update-ClineRoster { }; Mock Update-CopilotRoster { }; Mock Update-CopilotCliRoster { }; Mock Write-SwallowedErrors { }
    Mock Build-Rows { $script:FixtureRows }
    $script:FixedSize = @{ W = 100; H = 30 }; $script:ReadOnly = $true
    $script:ClineAt = Get-Date; $script:CopilotAt = Get-Date; $script:CopilotCliAt = Get-Date
    $script:Departed = @{}; $script:RefreshIds = [Collections.Generic.HashSet[string]]::new(); $script:RowCache = @{}; $script:AutoWidth = @{}
    $script:Columns = @(@{ Name = 'COST'; Fixed = 10; Align = 'R'; Priority = 100 })
    $script:SortModes = @('activity', 'roster', 'start', 'cost', 'ctx', 'cache'); $script:Layouts = @('wrap', 'truncate')
    $script:FixtureRows = @([pscustomobject]@{ NAME = 'demo'; COST = '$0.42'; _SessionId = 'demo'; _Dirty = $true; _LinesSig = ''; _Lines = $null })
    try {
      $frame = Invoke-Frame @{ Hover = @{ X = 3; Y = 5 }; LayoutMode = 1; SortMode = 0; KeepMin = 0; Actions = @() }
    } finally { $script:FixedSize = $null }
    @($frame.BodyMap) | Should -Be @(0)
    $frame.BodyY0 | Should -Be 5
    ($frame.Lines | ForEach-Object { if ($_ -is [string]) { $_ } else { [string]$_.Text } }) -join "`n" | Should -Match '┌ COST · demo'
  }
}
