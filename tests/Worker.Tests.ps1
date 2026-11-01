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

Describe 'Invoke-CopyKey' {
  It 'copies from the frame drawn for the current selection, and waits when that frame is not in yet' {
    $script:copied = @()
    Mock Copy-Text { $script:copied += "$what=$text" }
    $v = [pscustomobject]@{ SelectedId = 'b'; PendingCopy = $null }
    $stale = @{ Copy = @{ Id = 'a'; Transcript = '/a.jsonl'; Resume = 'claude --resume a'; Contact = 'A'; IdText = 'a'; IdWhat = 'session ID' } }
    Invoke-CopyKey 'y' $stale $v
    $script:copied.Count | Should -Be 0 -Because 'the frame still shows the old selection'
    $v.PendingCopy | Should -Be 'y'
    $fresh = @{ Copy = @{ Id = 'b'; Transcript = '/b.jsonl'; Resume = 'claude --resume b'; Contact = 'B'; IdText = 'b'; IdWhat = 'session ID' } }
    Invoke-CopyKey $v.PendingCopy $fresh $v
    $script:copied | Should -Be @('resume command=claude --resume b')
    $v.PendingCopy | Should -BeNullOrEmpty
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
    $roster = '[{"sessionId":"' + $sid + '","name":"live-one","kind":"interactive","cwd":"/w","pid":' + $PID + ',"startedAt":' + $start + ',"status":"idle"}]'
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
      $psi.EnvironmentVariables['PATH'] = $bin + [IO.Path]::PathSeparator + $env:PATH
      [Diagnostics.Process]::Start($psi)
    }
    function Read-Reply($p, [int]$seconds) {
      $t = $p.StandardOutput.ReadLineAsync()
      if (-not $t.Wait($seconds * 1000)) { throw "no reply within $seconds s; stderr: $($p.StandardError.ReadToEnd())" }
      return $t.Result
    }
  }
  AfterAll { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }

  It 'draws a frame for a view it is sent, as one line of ASCII JSON, then saves its cache and exits when its input closes' {
    $p = Start-TestWorker
    try {
      $p.StandardInput.WriteLine('{"Keep":"inf","ClosedLog":' + (ConvertTo-Json $closed) + '}')
      $view = @{ Rev = 7; SelectedId = $null; PeekId = $null; Tick = 250; KeepMin = -1; ShowSubagents = $true; Compact = $false
                 SortMode = 0; LayoutMode = 0; ShowGone = $true; Actions = @('poll'); PendingCopy = $null }
      # the first frames can come before the roster: ask until the session is in one
      $packet = $null
      for ($i = 0; $i -lt 40 -and -not ($packet -and @($packet.Ids) -contains $sid); $i++) {
        $p.StandardInput.WriteLine((ConvertTo-Json -Compress -Depth 5 @{ W = 160; H = 40; View = $view }))
        $line = Read-Reply $p 60
        $line | Should -Match '^[\x20-\x7E]*$' -Because 'the reply is escaped to ASCII, whatever the console encodings'
        $packet = ConvertFrom-Json -InputObject $line
        if (-not (@($packet.Ids) -contains $sid)) { Start-Sleep -Milliseconds 250 }
      }
      @($packet.Ids) | Should -Contain $sid
      [int]$packet.Rev | Should -Be 7 -Because 'the frame says which view it drew'
      $packet.SelectedId | Should -Be $sid
      (@($packet.Lines) | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.Text } }) -join "`n" | Should -Match 'live-one'
      $packet.Copy.Contact | Should -Match '@live-one'
      $p.StandardInput.Close()
      $p.WaitForExit(30000) | Should -BeTrue
      $p.ExitCode | Should -Be 0 -Because $p.StandardError.ReadToEnd()
      Test-Path -LiteralPath (Join-Path $cfg 'ctop-scancache.json') | Should -BeTrue -Because 'the worker owns the scan cache and saves it on the way out'
    } finally { if (-not $p.HasExited) { $p.Kill() } }
  }
}
