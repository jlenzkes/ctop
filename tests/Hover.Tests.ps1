# The hover line: with the mouse on (Windows), the console reports pointer moves; the footer then shows the
# cell under the pointer in full, and what its column means (the help screen's own words).
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

Describe 'Format-Hover' {
  It 'shows a CACHE cell as peek does, then what the column means' {
    $t = Format-Hover (Row 'ctop-cc') 'CACHE' 400
    $t | Should -Match '^  CACHE · ctop-cc: warm, 43 min left \(1h, last call [0-9:]{8}\) · next turn ≈ \$0\.11 warm, \$2\.20 cold \(220K tokens\)'
    $t | Should -Match '— prompt cache: minutes left'
  }
  It 'shows LAST ACTION and BRANCH whole, where the cells are cut' {
    Format-Hover (Row 'a') 'LAST ACTION' 400 | Should -Match 'LAST ACTION · a: Bash git log --oneline -5 --graph'
    Format-Hover (Row 'a') 'BRANCH' 400 | Should -Match 'BRANCH · a: claude/a-rather-long-branch-name'
  }
  It 'names a subagent row without its tree rail' {
    Format-Hover (Row '  ├ general-purpose') 'STATE' 400 | Should -Match '^  STATE · general-purpose: working'
  }
  It 'fits the window width' {
    $t = Format-Hover (Row 'a') 'CACHE' 60
    Get-CellWidth $t | Should -BeLessOrEqual 60
  }
}

Describe 'Get-HoverText' {
  BeforeAll {
    $script:ShownCols = @(@{ Name = 'NAME'; Width = 10 }, @{ Name = 'CACHE'; Width = 5 }); $script:ShownSep = 2
    $script:BodyY0 = 5; $script:BodyMap = @(0, 0, -1, 1, 1)   # two rows of two lines, a gap line between
    $rows = @((Row 'first'), (Row 'second'))
  }
  It 'is the hovered cell''s line over a row' {
    Get-HoverText ([pscustomobject]@{ Hover = [pscustomobject]@{ X = 13; Y = 8 }; PeekId = $null }) $rows 200 | Should -Match '^  CACHE · second:'
    Get-HoverText ([pscustomobject]@{ Hover = [pscustomobject]@{ X = 2; Y = 6 }; PeekId = $null }) $rows 200 | Should -Match '^  NAME · first: first'
  }
  It 'is empty <Name>' -ForEach @(
    @{ Name = 'with no pointer seen';     Hover = $null;                                     Peek = $null }
    @{ Name = 'over the header';          Hover = [pscustomobject]@{ X = 2; Y = 3 };         Peek = $null }
    @{ Name = 'over a line between rows'; Hover = [pscustomobject]@{ X = 2; Y = 7 };         Peek = $null }
    @{ Name = 'over the gap between columns'; Hover = [pscustomobject]@{ X = 11; Y = 5 };    Peek = $null }
    @{ Name = 'below the table';          Hover = [pscustomobject]@{ X = 2; Y = 30 };        Peek = $null }
    @{ Name = 'in peek';                  Hover = [pscustomobject]@{ X = 2; Y = 5 };         Peek = 'x' }
  ) {
    Get-HoverText ([pscustomobject]@{ Hover = $Hover; PeekId = $Peek }) $rows 200 | Should -BeNullOrEmpty
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
  It 'clears the hover on a key press, so the footer''s key hints come back' {
    $view = New-View; $view.Hover = [pscustomobject]@{ X = 1; Y = 1 }
    $script:InQ.Enqueue([ConsoleKeyInfo]::new([char]']', [ConsoleKey]::Oem6, $false, $false, $false))
    Mock Next-Input { if ($script:InQ.Count) { $script:InQ.Dequeue() } else { $null } }
    Read-Keys $view @{ Ids = @('a'); PageRows = 1 } | Out-Null
    $view.Hover | Should -BeNullOrEmpty
  }
  It 'draws the hover line in the footer''s place, and keeps the footer for clicks' {
    Mock Write-Frame { $script:Drawn = $footer }
    Show-Packet ([pscustomobject]@{ Lines = @('x'); Footer = '  q quit'; Hover = '  CACHE · a: warm'; Ids = @(); BodyMap = @(); BodyY0 = 0 })
    $script:Drawn | Should -Be '  CACHE · a: warm'
    $script:ShownFooter | Should -Be '  q quit'
  }
}
