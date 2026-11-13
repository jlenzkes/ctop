# The display process and its worker: keys against a view (Apply-Key), and the worker's protocol, run as
# a real process with a fake claude. No terminal needed, so it runs on every CI job, Windows included.
BeforeAll { . (Join-Path $PSScriptRoot 'Import-Ctop.ps1') }

Describe 'Apply-Key' {
  BeforeAll {
    $script:SortModes = @('activity', 'roster', 'start', 'cost', 'ctx'); $script:Layouts = @('wrap', 'truncate')
    function Key([string]$name, [char]$ch = [char]0) { [ConsoleKeyInfo]::new($ch, [ConsoleKey]$name, $false, $false, $false) }
    function Char([char]$ch) { [ConsoleKeyInfo]::new($ch, [ConsoleKey]::A, $false, $false, $false) }
    function View { [pscustomobject]@{ Rev = 0; SelectedId = 'b'; PeekId = $null; Tick = 250; KeepMin = 15; ShowSubagents = $true; Compact = $false
                                        SortMode = 0; LayoutMode = 0; ShowGone = $true; Actions = @(); PendingCopy = $null } }
    $packet = @{ Ids = @('a', 'b', 'c', 'd', 'e'); PageRows = 2 }
  }
  It 'moves the selection with <Key> to <Want>' -ForEach @(
    @{ Key = 'UpArrow'; Want = 'a' }, @{ Key = 'DownArrow'; Want = 'c' }, @{ Key = 'Home'; Want = 'a' }
    @{ Key = 'End'; Want = 'e' }, @{ Key = 'PageDown'; Want = 'd' }, @{ Key = 'PageUp'; Want = 'a' }
  ) {
    $v = View
    Apply-Key $v (Key $Key) $packet | Should -BeNullOrEmpty
    $v.SelectedId | Should -Be $Want
    $v.Rev | Should -Be 1 -Because 'a change the worker has to draw'
  }
  It 'opens peek on Enter, follows the selection in it, and closes it on q without quitting' {
    $v = View
    Apply-Key $v (Key 'Enter' "`r") $packet | Should -BeNullOrEmpty
    $v.PeekId | Should -Be 'b'
    Apply-Key $v (Key 'DownArrow') $packet | Out-Null
    $v.PeekId | Should -Be 'c'
    Apply-Key $v (Char 'q') $packet | Should -BeNullOrEmpty
    $v.PeekId | Should -BeNullOrEmpty
    Apply-Key $v (Char 'q') $packet | Should -Be 'quit'
  }
  It 'changes the view for <Ch>' -ForEach @(
    @{ Ch = '+'; Prop = 'KeepMin'; Want = 30 }, @{ Ch = '-'; Prop = 'KeepMin'; Want = 0 }, @{ Ch = 's'; Prop = 'ShowSubagents'; Want = $false }
    @{ Ch = 'c'; Prop = 'Compact'; Want = $true }, @{ Ch = 'g'; Prop = 'ShowGone'; Want = $false }, @{ Ch = 'o'; Prop = 'SortMode'; Want = 1 }
    @{ Ch = 'v'; Prop = 'LayoutMode'; Want = 1 }, @{ Ch = ']'; Prop = 'Tick'; Want = 200 }, @{ Ch = '['; Prop = 'Tick'; Want = 300 }
  ) {
    $v = View
    Apply-Key $v (Char $Ch) $packet | Should -BeNullOrEmpty
    $v.$Prop | Should -Be $Want
    $v.Rev | Should -Be 1
  }
  It 'hands <Ch> to the loop as <Want>' -ForEach @(
    @{ Ch = 'h'; Want = 'help' }, @{ Ch = 'x'; Want = 'closed' }, @{ Ch = 'r'; Want = 'poll' }
    @{ Ch = 't'; Want = 'copy-t' }, @{ Ch = 'y'; Want = 'copy-y' }, @{ Ch = 'n'; Want = 'copy-n' }, @{ Ch = 'd'; Want = 'copy-d' }
  ) {
    Apply-Key (View) (Char $Ch) $packet | Should -Be $Want
  }
  It 'asks the worker for a roster poll on r' {
    $v = View
    Apply-Key $v (Char 'r') $packet | Out-Null
    @($v.Actions) | Should -Contain 'poll'
  }
  It 'leaves the view alone for a key it does not know' {
    $v = View
    Apply-Key $v (Char 'z') $packet | Should -BeNullOrEmpty
    $v.Rev | Should -Be 0
  }
}

Describe 'copy keys (t / y / n / d) keep the session selected when the key was pressed' {
  BeforeAll {
    function Copy-For([string]$id) { @{ Id = $id; Transcript = "/$id.jsonl"; Resume = "claude --resume $id"; Contact = "contact $id"; IdText = $id; IdWhat = 'session ID' } }
    function View([string]$sel) { [pscustomobject]@{ Rev = 0; SelectedId = $sel; PendingCopies = @(); CopyFor = $null } }
  }
  BeforeEach { $script:copied = @(); Mock Copy-Text { $script:copied += "$what=$text" } }
  It 'copies at once when the frame on screen is for the selected session' {
    $v = View 'a'
    Invoke-CopyKey 'y' @{ Ids = @('a', 'b'); Copy = (Copy-For 'a') } $v
    $script:copied | Should -Be @('resume command=claude --resume a')
  }
  It 'copies B when y was pressed on B, even after the selection moved on to C (the audit''s case)' {
    $v = View 'b'
    $shown = @{ Ids = @('a', 'b', 'c'); Copy = (Copy-For 'a') }       # still the frame drawn for A
    Invoke-CopyKey 'y' $shown $v
    $script:copied.Count | Should -Be 0
    $v.CopyFor | Should -Be 'b' -Because 'the next frame must carry what to copy for B'
    $v.SelectedId = 'c'                                                 # moves on before B's frame arrives
    Complete-PendingCopies @{ Ids = @('a', 'b', 'c'); Copy = (Copy-For 'c') } $v   # a frame made before it knew
    $script:copied.Count | Should -Be 0 -Because 'C''s data is not what was asked for'
    Complete-PendingCopies @{ Ids = @('a', 'b', 'c'); Copy = (Copy-For 'b') } $v
    $script:copied | Should -Be @('resume command=claude --resume b')
    @($v.PendingCopies).Count | Should -Be 0
    $v.CopyFor | Should -BeNullOrEmpty
  }
  It 'keeps the order of several copies, each with its own session' {
    $v = View 'b'
    $shown = @{ Ids = @('a', 'b', 'c'); Copy = (Copy-For 'a') }
    Invoke-CopyKey 'y' $shown $v
    $v.SelectedId = 'c'; Invoke-CopyKey 't' $shown $v
    Complete-PendingCopies @{ Ids = @('a', 'b', 'c'); Copy = (Copy-For 'b') } $v
    $v.CopyFor | Should -Be 'c'
    Complete-PendingCopies @{ Ids = @('a', 'b', 'c'); Copy = (Copy-For 'c') } $v
    $script:copied | Should -Be @('resume command=claude --resume b', 'transcript path=/c.jsonl')
  }
  It 'drops a copy whose session is no longer listed, and says so, rather than copy another' {
    $v = View 'b'
    Invoke-CopyKey 'n' @{ Ids = @('a', 'b'); Copy = (Copy-For 'a') } $v
    Complete-PendingCopies @{ Ids = @('a'); Copy = (Copy-For 'a') } $v
    $script:copied.Count | Should -Be 0
    @($v.PendingCopies).Count | Should -Be 0
    $script:Flash | Should -Match 'not copied'
  }
}

Describe 'Invoke-InProcessLoop (one process)' {
  It 'starts a frame every tick, counting the frame''s own time in it (tick 250 ms, frames of 150 ms)' {
    $script:starts = [Collections.Generic.List[double]]::new(); $script:clock = [Diagnostics.Stopwatch]::StartNew()
    Mock Invoke-Frame { $script:starts.Add($script:clock.Elapsed.TotalMilliseconds); Start-Sleep -Milliseconds 150; @{ Ids = @(); SelectedId = $null; PeekId = $null } }
    Mock Show-Packet { }
    Mock Complete-PendingCopies { }
    Mock Read-Keys { if ($script:starts.Count -ge 8) { 'quit' } else { $null } }
    Mock Get-WindowWidth { 120 }; Mock Get-WindowHeight { 40 }
    $script:Poll = $null
    Invoke-InProcessLoop ([pscustomobject]@{ Tick = 250; Actions = @(); SelectedId = $null; PeekId = $null; PendingCopies = @(); CopyFor = $null })
    $gaps = @(for ($i = 1; $i -lt $script:starts.Count; $i++) { $script:starts[$i] - $script:starts[$i - 1] })
    Write-Host ("    frame starts every: {0} ms" -f (($gaps | ForEach-Object { [int]$_ }) -join ' '))
    # The median of 7 gaps: one slow scheduling slot on a shared CI runner (354 ms once, Windows PowerShell
    # 5.1) is not the bug. The bug (a tick counted from frame end) makes every gap ~400 ms or more.
    $median = @($gaps | Sort-Object)[[math]::Floor($gaps.Count / 2)]
    $median | Should -BeLessThan 330 -Because 'a tick from frame start to frame start, not tick + frame'
  }
}

Describe 'Read-WorkerFrame: what the display accepts from the worker' {
  It 'takes a frame' {
    $p = Read-WorkerFrame '{"Lines":["a",{"Text":"b","Inverse":true}],"Footer":"f","Ids":["x"],"Rev":3,"BodyMap":[],"BodyY0":1}'
    $p | Should -Not -BeNullOrEmpty
    [int]$p.Rev | Should -Be 3
  }
  It 'refuses <Name>' -ForEach @(
    @{ Name = 'text that is not JSON';  Line = 'Exception: something broke' }
    @{ Name = 'a JSON number';          Line = '42' }
    @{ Name = 'a JSON list';            Line = '[1,2]' }
    @{ Name = 'a frame without Lines';  Line = '{"Rev":1}' }
    @{ Name = 'Lines that are text';    Line = '{"Lines":"a","Rev":1}' }
    @{ Name = 'a line that is a number'; Line = '{"Lines":[1],"Rev":1}' }
    @{ Name = 'no Rev';                 Line = '{"Lines":["a"]}' }
    @{ Name = 'a Rev that is text';     Line = '{"Lines":["a"],"Rev":"1"}' }
    @{ Name = 'a Footer that is a list'; Line = '{"Lines":["a"],"Rev":1,"Footer":[1]}' }
    @{ Name = 'Ids that are text';      Line = '{"Lines":["a"],"Rev":1,"Ids":"x"}' }
  ) {
    Read-WorkerFrame $Line | Should -BeNullOrEmpty
  }
}

Describe 'Invoke-FrontendLoop against a worker that misbehaves' {
  BeforeAll {
    # a stand-in worker: answers the first request with the given line, then reads on and never answers again
    function Start-FakeWorker([string]$reply) {
      $f = Join-Path $TestDrive "fake-$([guid]::NewGuid()).ps1"; $r = Join-Path $TestDrive "reply-$([guid]::NewGuid()).txt"
      [IO.File]::WriteAllText($r, $reply)
      [IO.File]::WriteAllText($f, "`$null = [Console]::In.ReadLine(); [Console]::Out.WriteLine([IO.File]::ReadAllText('$r')); [Console]::Out.Flush(); while (`$null -ne [Console]::In.ReadLine()) { }")
      $psi = [Diagnostics.ProcessStartInfo]::new()
      $psi.FileName = (Get-Process -Id $PID).Path
      $psi.Arguments = '-NoProfile -NonInteractive ' + $(if ($IsWindows -or $env:OS -eq 'Windows_NT') { '-ExecutionPolicy Bypass ' }) + "-File `"$f`""
      $psi.UseShellExecute = $false; $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
      $p = [Diagnostics.Process]::Start($psi)
      @{ Proc = $p; Err = $p.StandardError.ReadToEndAsync(); Reply = $null }
    }
  }
  BeforeEach {
    $script:notes = [Collections.Generic.List[string]]::new(); $script:why = $null; $script:clock = [Diagnostics.Stopwatch]::StartNew()
    Mock Show-Packet { $script:notes.Add([string]$note) }
    Mock Get-WindowWidth { 120 }; Mock Get-WindowHeight { 40 }
    Mock Invoke-Fallback { $script:why = $why }
  }
  It 'gives up on the worker and runs in one process when it sends something that is not a frame' {
    $script:EarlyWorker = Start-FakeWorker 'Exception: something broke'
    Mock Read-Keys { if ($script:clock.Elapsed.TotalSeconds -gt 20) { 'quit' } }
    try { Invoke-FrontendLoop } finally { try { $script:EarlyWorker.Proc.Kill() } catch {} }
    $script:why | Should -Be 'worker sent an unreadable frame'
  }
  It 'says how old the screen is once a frame it asked for is 5 s late, and counts up' {
    $script:EarlyWorker = Start-FakeWorker '{"Lines":["frame one"],"Footer":"f","Ids":[],"Rev":0,"BodyMap":[],"BodyY0":1}'
    Mock Read-Keys { if (@($script:notes | Where-Object { $_ -match 'not updated for 6 s' }).Count -or $script:clock.Elapsed.TotalSeconds -gt 20) { 'quit' } }
    try { Invoke-FrontendLoop } finally { try { $script:EarlyWorker.Proc.Kill() } catch {} }
    $script:why | Should -BeNullOrEmpty
    $stale = @($script:notes | Where-Object { $_ -match 'not updated' })
    $stale[0] | Should -Match 'not updated for 5 s: the worker is busy'
    $stale | Should -Contain ($stale[0] -replace '5 s', '6 s')
    $script:clock.Elapsed.TotalSeconds | Should -BeLessThan 15
  }
}

Describe 'the worker process (ctop.ps1 -Worker)' {
  BeforeAll {
    $onWindows = $IsWindows -or $env:OS -eq 'Windows_NT'
    $root = Join-Path ([IO.Path]::GetTempPath()) "ctop-worker-$PID"
    $cfg = Join-Path $root 'cfg'; $bin = Join-Path $root 'bin'
    New-Item -ItemType Directory -Force -Path $bin, (Join-Path $cfg 'projects') | Out-Null
    $sid = '11111111-1111-4111-8111-111111111111'
    $start = [DateTimeOffset]::UtcNow.AddHours(-1).ToUnixTimeMilliseconds()
    # a name outside ASCII (é, 日), written as JSON escapes so even a .cmd file can echo it
    $name = "live-$([char]0xE9)$([char]0x65E5)"
    $roster = '[{"sessionId":"' + $sid + '","name":"live-\u00e9\u65e5","kind":"interactive","cwd":"/w","pid":' + $PID + ',"startedAt":' + $start + ',"status":"idle"}]'
    if ($onWindows) { [IO.File]::WriteAllText((Join-Path $bin 'claude.cmd'), "@echo off`r`necho $roster`r`n") }
    else { $f = Join-Path $bin 'claude'; [IO.File]::WriteAllText($f, "#!/bin/sh`necho '$roster'`n"); & chmod +x $f }
    $closed = Join-Path $root 'closed.jsonl'; [IO.File]::WriteAllText($closed, '')
    $ctop = Join-Path (Split-Path -Parent $PSScriptRoot) 'ctop.ps1'

    function Start-TestWorker {
      $psi = [Diagnostics.ProcessStartInfo]::new()
      $psi.FileName = (Get-Process -Id $PID).Path
      $psi.Arguments = '-NoProfile -NonInteractive ' + $(if ($onWindows) { '-ExecutionPolicy Bypass ' }) + "-File `"$ctop`" -Worker"
      $psi.UseShellExecute = $false; $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
      $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
      $psi.EnvironmentVariables['CLAUDE_CONFIG_DIR'] = $cfg
      $psi.EnvironmentVariables['CLINE_SESSION_DATA_DIR'] = Join-Path $cfg 'no-cline'   # not this machine's Cline
      $psi.EnvironmentVariables['VSCODE_APPDATA'] = Join-Path $cfg 'no-vscode'          # nor its VS Code chats
      $psi.EnvironmentVariables['VSCODE_PORTABLE'] = ''
      $psi.EnvironmentVariables['PATH'] = $bin + [IO.Path]::PathSeparator + $env:PATH
      $p = [Diagnostics.Process]::Start($psi)
      @{ P = $p; Err = $p.StandardError.ReadToEndAsync() }   # stderr drained from the start: reading it later can block
    }
    # One reply line, or a failure within the deadline: a worker that stops answering is killed (it keeps
    # stderr open while it lives) before what it wrote to stderr is reported.
    function Read-Reply($w, [int]$seconds) {
      $t = $w.P.StandardOutput.ReadLineAsync()
      if (-not $t.Wait($seconds * 1000)) {
        try { $w.P.Kill() } catch {}
        $null = $w.P.WaitForExit(5000)
        $err = if ($w.Err.Wait(2000)) { $w.Err.Result } else { '(stderr still open)' }
        throw "no reply within $seconds s; stderr: $err"
      }
      return $t.Result
    }
  }
  AfterAll { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }

  It 'gives up on a worker that never answers, within its deadline, and leaves no child running' {
    # the harness itself: a child that reads its input and then just sits there, stdout and stderr open
    $psi = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path, '-NoProfile -NonInteractive -Command "$null = [Console]::In.ReadLine(); Start-Sleep 300"')
    $psi.UseShellExecute = $false; $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = [Diagnostics.Process]::Start($psi)
    $w = @{ P = $p; Err = $p.StandardError.ReadToEndAsync() }
    try {
      $p.StandardInput.WriteLine('{}')
      $sw = [Diagnostics.Stopwatch]::StartNew()
      { Read-Reply $w 2 } | Should -Throw -ExpectedMessage '*no reply within 2 s*'
      $sw.Elapsed.TotalSeconds | Should -BeLessThan 12
      $p.HasExited | Should -BeTrue
    } finally { if (-not $p.HasExited) { $p.Kill() } }
  }
  It 'draws a frame for a view it is sent, as one line of ASCII JSON, then saves its cache and exits when its input closes' {
    $w = Start-TestWorker; $p = $w.P
    try {
      $p.StandardInput.WriteLine('{"Keep":"inf","ClosedLog":' + (ConvertTo-Json $closed) + '}')
      $view = @{ Rev = 7; SelectedId = $null; PeekId = $null; Tick = 250; KeepMin = -1; ShowSubagents = $true; Compact = $false
                 SortMode = 0; LayoutMode = 0; ShowGone = $true; Actions = @('poll'); PendingCopy = $null }
      # the first frames can come before the roster: ask until the session is in one
      $packet = $null
      for ($i = 0; $i -lt 40 -and -not ($packet -and @($packet.Ids) -contains $sid); $i++) {
        $p.StandardInput.WriteLine((ConvertTo-Json -Compress -Depth 5 @{ W = 160; H = 40; View = $view }))
        $line = Read-Reply $w 60
        $line | Should -Match '^[\x20-\x7E]*$' -Because 'the reply is escaped to ASCII, whatever the console encodings'
        $packet = ConvertFrom-Json -InputObject $line
        if (-not (@($packet.Ids) -contains $sid)) { Start-Sleep -Milliseconds 250 }
      }
      @($packet.Ids) | Should -Contain $sid
      [int]$packet.Rev | Should -Be 7 -Because 'the frame says which view it drew'
      $packet.SelectedId | Should -Be $sid
      (@($packet.Lines) | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.Text } }) -join "`n" | Should -Match ([regex]::Escape($name)) -Because 'the name crosses the pipe intact, as \u escapes'
      $packet.Copy.Contact | Should -Match ([regex]::Escape("@$name"))
      $p.StandardInput.Close()
      $p.WaitForExit(30000) | Should -BeTrue
      $p.ExitCode | Should -Be 0 -Because $(if ($w.Err.Wait(2000)) { $w.Err.Result })
      Test-Path -LiteralPath (Join-Path $cfg 'ctop-scancache.json') | Should -BeTrue -Because 'the worker owns the scan cache and saves it on the way out'
    } finally { if (-not $p.HasExited) { $p.Kill() } }
  }
}
