# Keys read from the Windows console with the mouse on: the console reports records .NET's ConsoleKey has no
# name for (a lone Alt is key code 18), and ctop must neither crash on them nor let Alt/Ctrl chords act as
# commands. The C# reader is compiled here from ctop.ps1's own source, under another namespace.
BeforeAll {
  . (Join-Path $PSScriptRoot 'Import-Ctop.ps1')
  function Ev([int]$vk, [char]$ch = [char]0, [uint32]$ctrl = 0) { [pscustomobject]@{ Kind = 1; Vk = $vk; Ch = $ch; Ctrl = $ctrl; Repeat = 1 } }
  function Drain { $out = @(); while ($script:InQ.Count) { $out += $script:InQ.Dequeue() }; , $out }
}

Describe 'Add-ConsoleInputEvents' {
  BeforeEach { $script:InQ = [System.Collections.Generic.Queue[object]]::new() }
  It 'ignores a lone <Name> key (code <Vk>) instead of stopping ctop' -ForEach @(
    @{ Name = 'Shift'; Vk = 16 }, @{ Name = 'Ctrl'; Vk = 17 }, @{ Name = 'Alt'; Vk = 18 }, @{ Name = 'Caps Lock'; Vk = 20 }
    @{ Name = 'Num Lock'; Vk = 144 }, @{ Name = 'Scroll Lock'; Vk = 145 }, @{ Name = 'Left Shift'; Vk = 160 }, @{ Name = 'Right Alt'; Vk = 165 }
  ) {
    { Add-ConsoleInputEvents @(Ev $Vk) } | Should -Not -Throw
    (Drain).Count | Should -Be 0
  }
  It 'keeps the character of a key ConsoleKey has no name for, with no key identity' {
    Add-ConsoleInputEvents @(Ev 255 ([char]0x00E9))
    $k = (Drain)[0]
    $k.KeyChar | Should -Be ([char]0x00E9)
    [int]$k.Key | Should -Be 0
  }
  It 'drops a key with neither a name nor a character' {
    Add-ConsoleInputEvents @(Ev 255)
    (Drain).Count | Should -Be 0
  }
  It 'passes an ordinary key through, with its modifiers' {
    Add-ConsoleInputEvents @((Ev 0x51 'q'), (Ev 0x51 'q' 0x2))
    $keys = Drain
    $keys[0].Key | Should -Be ([ConsoleKey]::Q)
    $keys[0].Modifiers | Should -Be ([ConsoleModifiers]0)
    $keys[1].Modifiers | Should -Be ([ConsoleModifiers]::Alt)
  }
  It 'passes a mouse event through untouched' {
    $m = [pscustomobject]@{ Kind = 2; X = 3; Y = 4 }
    Add-ConsoleInputEvents @($m)
    (Drain)[0] | Should -Be $m
  }
}

Describe 'Apply-Key with Alt or Ctrl held' {
  BeforeAll {
    $script:SortModes = @('activity', 'roster', 'start', 'cost', 'ctx'); $script:Layouts = @('wrap', 'truncate')
    function View { [pscustomobject]@{ Rev = 0; SelectedId = 'b'; PeekId = $null; Tick = 250; KeepMin = 15; ShowSubagents = $true; Compact = $false
                                        SortMode = 0; LayoutMode = 0; ShowGone = $true; Actions = @(); PendingCopy = $null } }
    function Chord([char]$ch, [ConsoleKey]$key, [bool]$alt, [bool]$ctl) { [ConsoleKeyInfo]::new($ch, $key, $false, $alt, $ctl) }
    $packet = @{ Ids = @('a', 'b', 'c'); PageRows = 2 }
  }
  It 'does not quit on Alt+q' {
    $v = View
    Apply-Key $v (Chord 'q' Q $true $false) $packet | Should -BeNullOrEmpty
    $v.Rev | Should -Be 0
  }
  It 'does not act on Ctrl+<Ch>' -ForEach @(@{ Ch = 'r' }, @{ Ch = 's' }, @{ Ch = 'q' }) {
    $v = View
    Apply-Key $v (Chord $Ch ([ConsoleKey][int][char]$Ch.ToUpper()) $false $true) $packet | Should -BeNullOrEmpty
    $v.Rev | Should -Be 0
  }
  It 'does not move the selection on Alt+Down' {
    $v = View
    Apply-Key $v (Chord ([char]0) DownArrow $true $false) $packet | Out-Null
    $v.SelectedId | Should -Be 'b'
  }
  It 'does not quit on Ctrl+Alt+q reported with its letter (AltGr text is never a letter command)' {
    $v = View
    Apply-Key $v (Chord 'q' Q $true $true) $packet | Should -BeNullOrEmpty
    $v.Rev | Should -Be 0
  }
  It 'takes AltGr text as the character it types (AltGr+9 is ] on a German keyboard)' {
    $v = View
    Apply-Key $v (Chord ']' D9 $true $true) $packet | Should -BeNullOrEmpty
    $v.Tick | Should -Be 200
  }
}

Describe 'the console reader (C#, compiled from ctop.ps1)' -Skip:(-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
  BeforeAll {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path -Parent $PSScriptRoot) 'ctop.ps1'), [ref]$null, [ref]$null)
    $assign = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:ConSrc' }, $true)
    $src = $assign.Right.Extent.Text -replace "^@'\r?\n", '' -replace "\r?\n'@$", ''
    if (-not ('CtopConTest.Con' -as [type])) { Add-Type -TypeDefinition ($src -replace 'namespace CtopCon', 'namespace CtopConTest') }
    function Rec([int]$vk, [int]$ch = 0, [uint32]$ctrl = 0, [bool]$down = $true) {
      $k = [CtopConTest.KEY_EVENT_RECORD]::new(); $k.bKeyDown = [int]$down; $k.wRepeatCount = 1; $k.wVirtualKeyCode = $vk; $k.UnicodeChar = $ch; $k.dwControlKeyState = $ctrl
      $r = [CtopConTest.INPUT_RECORD]::new(); $r.EventType = 1; $r.Key = $k; $r
    }
  }
  It 'drops a lone modifier key-down' {
    [CtopConTest.Con]::ConvertRecord((Rec 18 0 0x2)) | Should -BeNullOrEmpty
  }
  It 'drops the digits typed with Alt held to compose a character on the number pad' {
    [CtopConTest.Con]::ConvertRecord((Rec 0x61 0 0x2)) | Should -BeNullOrEmpty
  }
  It 'keeps the composed character the console delivers when Alt is released' {
    $e = [CtopConTest.Con]::ConvertRecord((Rec 18 0x00E9 0 $false))
    $e.Ch | Should -Be ([char]0x00E9)
    $e.Vk | Should -Be 0
  }
  It 'drops other key-ups' {
    [CtopConTest.Con]::ConvertRecord((Rec 0x51 0x71 0 $false)) | Should -BeNullOrEmpty
  }
  It 'keeps an ordinary key-down' {
    $e = [CtopConTest.Con]::ConvertRecord((Rec 0x51 0x71))
    $e.Vk | Should -Be 0x51
    $e.Ch | Should -Be 'q'
  }
}

# A click on a footer item presses its key: every "<key> <label>" item, whatever its label, and each key of an
# item that names several ("t/y/n/d copy", "+/- keep").
Describe 'Resolve-Mouse on the footer' {
  BeforeAll {
    Mock Get-WindowHeight { 40 }
    $script:SortModes = @('activity', 'roster', 'start', 'cost', 'ctx', 'cache'); $script:Layouts = @('wrap', 'truncate')
    $script:SortMode = 0; $script:Compact = $false; $script:ShowSubagents = $false; $script:ShowGone = $true; $script:KeepMin = 60
    function Click([string]$footer, [int]$x) {
      $top = try { [Console]::WindowTop } catch { 0 }
      $a = Resolve-Mouse ([pscustomobject]@{ X = $x; Y = 39 + $top; Buttons = [uint32]1; Flags = [uint32]0 }) $footer $false -1
      if ($a -and $a.Key) { [string]$a.Key.KeyChar } else { '' }
    }
  }
  It 'presses <Key> for a click on "<Item>"' -ForEach @(
    @{ Layout = 0; Item = 'v wrap'; Key = 'v' }, @{ Layout = 1; Item = 'v truncate'; Key = 'v' },
    @{ Layout = 0; Item = 'o sort:activity'; Key = 'o' }, @{ Layout = 0; Item = 'x closed'; Key = 'x' }, @{ Layout = 0; Item = 'q quit'; Key = 'q' }
  ) {
    Mock Get-WindowWidth { 300 }
    $script:LayoutMode = $Layout
    $plain = Strip-Ansi (Build-Footer)
    $at = $plain.IndexOf($Item); $at | Should -BeGreaterOrEqual 0 -Because $plain
    for ($x = $at; $x -lt $at + $Item.Length; $x++) { Click (Build-Footer) $x | Should -Be $Key -Because "column $x of '$Item'" }
  }
  It 'presses the key clicked in "<Item>"' -ForEach @(@{ Item = 't/y/n/d copy'; Keys = 't', 'y', 'n', 'd' }, @{ Item = '+/- keep'; Keys = '+', '-' }) {
    Mock Get-WindowWidth { 300 }
    $script:LayoutMode = 0
    $plain = Strip-Ansi (Build-Footer)
    $at = $plain.IndexOf($Item); $at | Should -BeGreaterOrEqual 0 -Because $plain
    for ($i = 0; $i -lt $Keys.Count; $i++) { Click (Build-Footer) ($at + 2 * $i) | Should -Be $Keys[$i] }
  }
}

Describe 'Copy-From y' {
  It 'says so when the session has no resume command, instead of doing nothing' {
    $script:Flash = ''
    Copy-From 'y' @{ Resume = '' }
    $script:Flash | Should -Match 'no resume command'
  }
}
