# End to end: the real ctop.ps1 in a terminal (tmux), against a fake `claude` that prints a fixed roster
# and a scratch config dir holding synthetic transcripts and a closed-sessions history.
# Needs tmux (Linux). Run alone with:  Invoke-Pester ./tests -TagFilter Integration
BeforeDiscovery { $script:noTmux = -not (Get-Command tmux -ErrorAction SilentlyContinue) -or $IsWindows }

BeforeAll {
  $script:ctop = Join-Path (Split-Path -Parent $PSScriptRoot) 'ctop.ps1'
  $script:pwsh = (Get-Process -Id $PID).Path
  $script:n = 0

  # a synthetic transcript: prompt, tool call + result, reply; repeated to ~60 KB
  function New-Transcript([string]$path, [string]$sid, [int]$turns = 25) {
    $ts = [DateTime]::UtcNow.AddDays(-3).ToString('o')
    $turn = @(
      @{ type = 'user'; sessionId = $sid; timestamp = $ts; cwd = '/w'; message = @{ role = 'user'; content = 'do the thing ' + ('x' * 400) } }
      @{ type = 'assistant'; sessionId = $sid; timestamp = $ts; cwd = '/w'; gitBranch = 'main'
         message = @{ role = 'assistant'; model = 'claude-sonnet-5-5'; usage = @{ input_tokens = 10; output_tokens = 200; cache_read_input_tokens = 30000; cache_creation_input_tokens = 500 }
                      content = @(@{ type = 'tool_use'; id = 'tu1'; name = 'Bash'; input = @{ command = 'ls -la' } }) } }
      @{ type = 'user'; sessionId = $sid; timestamp = $ts; cwd = '/w'; message = @{ role = 'user'; content = @(@{ type = 'tool_result'; tool_use_id = 'tu1'; content = ('line ' * 300) }) } }
      @{ type = 'assistant'; sessionId = $sid; timestamp = $ts; cwd = '/w'; gitBranch = 'main'
         message = @{ role = 'assistant'; model = 'claude-sonnet-5-5'; usage = @{ input_tokens = 10; output_tokens = 300; cache_read_input_tokens = 31000; cache_creation_input_tokens = 200 }
                      content = @(@{ type = 'text'; text = 'done' }) } }
    ) | ForEach-Object { $_ | ConvertTo-Json -Depth 10 -Compress }
    $lines = for ($i = 0; $i -lt $turns; $i++) { $turn }
    [IO.File]::WriteAllLines($path, [string[]]$lines)
  }

  # A config dir with one live session (pid: this test process, so the OS columns resolve) and one
  # closed session per entry of $closedAt, each with its transcript on disk. A transcript stops changing
  # when its session closes, so its write time is set to the close time (IDLE then reads like real
  # history). Returns what Start-Ctop needs, plus each history row's name -> close time.
  # -NoLive: the roster starts empty. -Kinds: each history entry's kind (default interactive). The fake
  # claude prints RosterFile on every poll, so a test can change the roster while ctop runs.
  function New-Fixture([string]$root, [DateTimeOffset[]]$closedAt, [string]$PathTail = $env:PATH, [int]$Turns = 25,
                       [switch]$NoLive, [string[]]$Kinds = @()) {
    $cfg = Join-Path $root 'cfg'; $bin = Join-Path $root 'bin'
    New-Item -ItemType Directory -Force -Path $bin, (Join-Path $cfg 'projects/-w') | Out-Null
    $live = @{ pid = $PID; cwd = $root; kind = 'interactive'; startedAt = [DateTimeOffset]::UtcNow.AddHours(-1).ToUnixTimeMilliseconds()
               sessionId = '11111111-1111-4111-8111-111111111111'; name = 'live-one'; status = 'idle' }
    $rosterFile = Join-Path $root 'roster.json'
    $liveJson = ConvertTo-Json -InputObject @($live) -Depth 5
    Set-Content -LiteralPath $rosterFile -Value $(if ($NoLive) { '[]' } else { $liveJson })
    $fake = Join-Path $bin 'claude'
    Set-Content -LiteralPath $fake -Value "#!/bin/sh`ncat '$rosterFile'"
    & chmod +x $fake
    New-Transcript (Join-Path $cfg "projects/-w/$($live.sessionId).jsonl") $live.sessionId
    $closed = @{}
    $log = for ($i = 0; $i -lt $closedAt.Count; $i++) {
      $sid = [guid]::new(('{0:x8}-0000-4000-8000-{1:x12}' -f $i, $i)).ToString()
      $dir = Join-Path $cfg "projects/-w-p$($i % 12)"
      New-Item -ItemType Directory -Force -Path $dir | Out-Null
      $tf = Join-Path $dir "$sid.jsonl"
      New-Transcript $tf $sid $Turns
      [IO.File]::SetLastWriteTimeUtc($tf, $closedAt[$i].UtcDateTime)
      $name = 'h{0:d3}' -f $i; $closed[$name] = $closedAt[$i]
      @{ closedAt = $closedAt[$i].ToString('o'); why = 'closed'; name = $name; title = "history $i"
         sessionId = $sid; cwd = "/w/p$($i % 12)"; pid = 50000 + $i; startedAt = 1793400000000
         kind = $(if ($i -lt $Kinds.Count) { $Kinds[$i] } else { 'interactive' }) } | ConvertTo-Json -Compress
    }
    $closedLog = Join-Path $root 'closed.jsonl'
    [IO.File]::WriteAllLines($closedLog, [string[]]@($log | Where-Object { $_ }))   # none: an empty log
    return @{ Cfg = $cfg; Log = $closedLog; Env = "CLAUDE_CONFIG_DIR='$cfg' PATH='${bin}:$PathTail'"; Closed = $closed
              RosterFile = $rosterFile; LiveJson = $liveJson }
  }

  $script:ErrFile = @{}   # tmux session -> the file holding ctop's stderr
  function Start-Ctop($fx, [string]$ctopArgs, [int]$height = 50) {
    $script:n++
    $s = "ctop-it-$PID-$($script:n)"
    $err = Join-Path ([IO.Path]::GetTempPath()) "$s.err"
    $script:ErrFile[$s] = $err
    $cmd = "$($fx.Env) '$($script:pwsh)' -NoProfile -File '$($script:ctop)' -ClosedLog '$($fx.Log)' -NoColor $ctopArgs 2>'$err'; echo CTOP-EXITED `$?; sleep 60"
    & tmux new-session -d -s $s -x 200 -y $height $cmd
    # some tmux builds keep a detached session at 80x24 whatever -x / -y say (AlmaLinux 9's 3.2a did),
    # which cut the strip the tests read
    & tmux resize-window -t $s -x 200 -y $height 2>$null
    return $s
  }
  function Get-Screen([string]$s) { (& tmux capture-pane -p -t $s) -join "`n" }
  function Wait-Screen([string]$s, [string]$pattern, [double]$seconds) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $seconds) {
      if ((Get-Screen $s) -match $pattern) { return $sw.Elapsed.TotalSeconds }
      Start-Sleep -Milliseconds 100
    }
    # timed out: show what was there instead, so a failure on another machine can be read from its log
    Write-Host "    waited $seconds s for /$pattern/ on $s; tmux $(& tmux -V), pane TERM $(& tmux display -p -t $s '#{client_termname}' 2>$null) / default-terminal $(& tmux show -gv default-terminal 2>$null)"
    Write-Host "    --- screen:"; (Get-Screen $s) -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 15 | ForEach-Object { Write-Host "    | $_" }
    $err = $script:ErrFile[$s]
    if ($err -and (Test-Path -LiteralPath $err)) { Write-Host "    --- ctop stderr:"; Get-Content -LiteralPath $err -TotalCount 20 | ForEach-Object { Write-Host "    ! $_" } }
    return $null
  }
  function Stop-Ctop([string]$s) { & tmux kill-session -t $s 2>$null }
  # Wait for the process in $s to end (the wrapper prints CTOP-EXITED <status>): its exit status, the
  # screen and its stderr. $null when it did not end in time.
  function Wait-Exit([string]$s, [double]$seconds) {
    if ($null -eq (Wait-Screen $s 'CTOP-EXITED \d+' $seconds)) { return $null }
    $screen = Get-Screen $s
    $err = $script:ErrFile[$s]
    @{ Code = [int]([regex]::Match($screen, 'CTOP-EXITED (\d+)').Groups[1].Value); Screen = $screen
       Stderr = $(if ($err -and (Test-Path -LiteralPath $err)) { (Get-Content -LiteralPath $err -Raw) } else { '' }) }
  }
  # A clean exit: status 0, no fatal "stopped:" report, nothing on stderr
  function Test-CleanExit($x) { $x -and $x.Code -eq 0 -and $x.Screen -notmatch 'stopped:' -and -not "$($x.Stderr)".Trim() }
  # Median of the pass times ctop reports on its strip, sampled over ~5 s. Only from a ctop that is
  # alive and drawing: it fails on an exit or crash report, on fewer than 10 readings, and unless the
  # title-bar clock moved through at least 3 seconds (a frozen screen keeps showing its last figure).
  function Get-MedianFrame([string]$s) {
    $ms = @(); $clocks = @{}
    for ($i = 0; $i -lt 12; $i++) {
      $screen = Get-Screen $s
      if ($screen -match 'CTOP-EXITED|stopped:') { throw "ctop is not running: $(($screen -split "`n" | Where-Object { $_ -match 'CTOP-EXITED|stopped:' }) -join ' / ')" }
      if ($screen -match 'frame +(\d+)ms') { $ms += [int]$Matches[1] }
      if ($screen -match 'ctop  (\d\d:\d\d:\d\d)') { $clocks[$Matches[1]] = $true }
      Start-Sleep -Milliseconds 400
    }
    if ($ms.Count -lt 10) { throw "only $($ms.Count) frame readings in 12 samples" }
    if ($clocks.Count -lt 3) { throw "the screen did not advance: $($clocks.Count) distinct clock readings in ~5 s" }
    $sorted = @($ms | Sort-Object)
    $median = $sorted[[math]::Floor($sorted.Count / 2)]
    Write-Host "    frame ms: $($ms -join ' ')  (median $median, max $($sorted[-1]))"
    return $median
  }
  # Time from a key to its visible effect, by watching the screen every 20 ms
  function Measure-KeyResponse([string]$s, [string]$key, [string]$expect, [double]$seconds = 5) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & tmux send-keys -t $s $key
    while ($sw.Elapsed.TotalSeconds -lt $seconds) {
      if ((Get-Screen $s) -match $expect) { return $sw.Elapsed.TotalMilliseconds }
      Start-Sleep -Milliseconds 20
    }
    return $null
  }
}

Describe 'ctop under a long history' -Tag Integration -Skip:$script:noTmux {
  BeforeAll {
    # 300 closed sessions over the last 30 days
    $rand = [Random]::new(7)
    $now = [DateTimeOffset]::UtcNow
    $script:fx = New-Fixture (Join-Path $TestDrive 'h') @(for ($i = 0; $i -lt 300; $i++) { $now.AddMinutes(-1 - $rand.NextDouble() * 30 * 1440) })
  }

  It 'shows the live session while the history is still loading (cold cache)' {
    # The property, independent of machine speed: the first screen with the live session on it still
    # reads "gone N/300", so live rows did not wait for the history. (Building all 300 history rows
    # before the first frame took ~8 s here.) A loose cap guards against startup getting slow overall.
    Remove-Item -LiteralPath (Join-Path $fx.Cfg 'ctop-scancache.json') -ErrorAction SilentlyContinue
    $sw = [Diagnostics.Stopwatch]::StartNew(); & $script:pwsh -NoProfile -File $script:ctop -Version | Out-Null; $base = $sw.Elapsed.TotalSeconds
    $sw.Restart()
    $s = Start-Ctop $fx '-Keep inf'
    try {
      Wait-Screen $s 'live-one' 60 | Should -Not -BeNullOrEmpty
      $took = $sw.Elapsed.TotalSeconds
      $screen = Get-Screen $s
      $loading = if ($screen -match 'gone (\d+)/300') { [int]$Matches[1] } else { $null }
      Write-Host ("    pwsh start {0:N1} s, live session shown after {1:N1} s, history then at {2}/300" -f $base, $took, $(if ($null -ne $loading) { $loading } else { 'done' }))
      $loading | Should -Not -BeNullOrEmpty -Because 'the live session must show before the history has loaded'
      $took | Should -BeLessThan ($base * 4 + 4)
    } finally { Stop-Ctop $s }
  }

  It 'lists the whole history at keep ∞' {
    $s = Start-Ctop $fx '-Keep inf'
    try {
      Wait-Screen $s 'live-one' 60 | Should -Not -BeNullOrEmpty
      Wait-Screen $s 'gone 300\b|300 gone' 30 | Should -Not -BeNullOrEmpty
    } finally { Stop-Ctop $s }
  }

  It 'quits on q within 2 s with 300 gone rows listed' {
    $s = Start-Ctop $fx '-Keep inf'
    try {
      Wait-Screen $s 'gone 300\b|300 gone' 60 | Should -Not -BeNullOrEmpty
      Start-Sleep -Seconds 3   # past the first scans: steady state
      & tmux send-keys -t $s q
      $x = Wait-Exit $s 2
      $x | Should -Not -BeNullOrEmpty -Because 'q must end ctop within 2 s'
      $x.Code | Should -Be 0
      $x.Screen | Should -Not -Match 'stopped:'
      "$($x.Stderr)".Trim() | Should -BeNullOrEmpty
    } finally { Stop-Ctop $s }
  }

  It 'applies every one of five quick + presses' {
    $s = Start-Ctop $fx '-Keep 0'
    try {
      Wait-Screen $s 'live-one' 60 | Should -Not -BeNullOrEmpty
      & tmux send-keys -t $s + + + + +   # 0 → 15m → 30m → 45m → 1h → 2h
      Wait-Screen $s 'keep 2h ' 5 | Should -Not -BeNullOrEmpty
      Start-Sleep -Milliseconds 800
      (Get-Screen $s) | Should -Match 'keep 2h '   # and not past it
    } finally { Stop-Ctop $s }
  }

  It 'applies every one of five quick - presses under full load (300 gone rows)' {
    $s = Start-Ctop $fx '-Keep inf'
    try {
      Wait-Screen $s 'gone 300\b|300 gone' 60 | Should -Not -BeNullOrEmpty
      Start-Sleep -Seconds 3
      & tmux send-keys -t $s - - - - -   # ∞ → 30d → 14d → 7d → 3d → 2d
      Wait-Screen $s 'keep 2d ' 5 | Should -Not -BeNullOrEmpty
      Start-Sleep -Milliseconds 800
      (Get-Screen $s) | Should -Match 'keep 2d '
    } finally { Stop-Ctop $s }
  }

  It 'draws a frame within the 250 ms tick with 300 gone rows listed (steady state, median)' {
    $s = Start-Ctop $fx '-Keep inf'
    try {
      Wait-Screen $s 'gone 300\b|300 gone' 60 | Should -Not -BeNullOrEmpty
      Start-Sleep -Seconds 10   # past warm-up (first scans, first full render)
      Get-MedianFrame $s | Should -BeLessThan 250
    } finally { Stop-Ctop $s }
  }

  It 'answers every key within 750 ms with 300 gone rows (worst of 8, measured from outside)' {
    $s = Start-Ctop $fx '-Keep 30d'
    try {
      Wait-Screen $s 'gone 300\b|300 gone' 60 | Should -Not -BeNullOrEmpty
      Start-Sleep -Seconds 5
      # 30d <-> 14d: each press changes how many history rows are listed, so the response is a real redraw
      $lat = for ($i = 0; $i -lt 8; $i++) {
        if ($i % 2 -eq 0) { Measure-KeyResponse $s '-' 'keep 14d ' } else { Measure-KeyResponse $s '+' 'keep 30d ' }
      }
      Write-Host ("    key -> visible ms: {0}" -f (($lat | ForEach-Object { if ($null -eq $_) { 'none' } else { [int]$_ } }) -join ' '))
      @($lat | Where-Object { $null -eq $_ }).Count | Should -Be 0
      ($lat | Measure-Object -Maximum).Maximum | Should -BeLessThan 750
    } finally { Stop-Ctop $s }
  }

  It 'costs about the same with 300 gone rows as with the screenful that is visible (off-screen rows are nearly free)' {
    # A screenful of history (-Keep 4d: about 40 rows here, all of them on screen) against all 300 with
    # the same screenful visible. Relative, so it holds on slower and faster machines alike.
    $s = Start-Ctop $fx '-Keep 4d'
    try {
      Wait-Screen $s 'live-one' 60 | Should -Not -BeNullOrEmpty
      Start-Sleep -Seconds 8
      if ((Get-Screen $s) -match 'gone (\d+) ') { Write-Host "    keep 4d lists $($Matches[1]) gone rows" }
      $base = Get-MedianFrame $s
    } finally { Stop-Ctop $s }
    $s = Start-Ctop $fx '-Keep inf'
    try {
      Wait-Screen $s 'gone 300\b|300 gone' 60 | Should -Not -BeNullOrEmpty
      Start-Sleep -Seconds 10
      $full = Get-MedianFrame $s
    } finally { Stop-Ctop $s }
    Write-Host "    a screenful: $base ms, 300 rows: $full ms"
    $full | Should -BeLessThan (1.5 * $base)
  }
}

Describe 'ages on rows that scroll into view' -Tag Integration -Skip:$script:noTmux {
  BeforeAll {
    # 40 sessions that closed 2–12 s ago: their ages tick every second, so a stale one shows. One-turn
    # transcripts so they load in a few frames even at a 3 s tick on a slow runner: the ages must still
    # read in seconds (under a minute) when the test looks, or a stale age could hide in "1m"
    $now = [DateTimeOffset]::UtcNow
    $script:fx2 = New-Fixture (Join-Path $TestDrive 'a') @(for ($i = 0; $i -lt 40; $i++) { $now.AddSeconds(-2 - $i / 4) }) -Turns 1
  }

  It 'shows the current age on a row the moment it scrolls into view, after time off screen' {
    # 20 lines: most of the 40 rows are off screen. A 3 s tick keeps the frame drawn right after the key
    # on screen while it is read, so a row refreshed only by the NEXT frame would show its stale age.
    $s = Start-Ctop $fx2 '-Keep inf -Tick 3000' 20
    try {
      Wait-Screen $s 'gone 40 |40 gone' 60 | Should -Not -BeNullOrEmpty
      Start-Sleep -Seconds 6               # the bottom rows' ages move on while they are off screen
      & tmux send-keys -t $s End           # oldest gone is listed last; the key repaints at once
      Start-Sleep -Milliseconds 700
      $screen = Get-Screen $s
      $at = [DateTimeOffset]::UtcNow
      $line = ($screen -split "`n") | Where-Object { $_ -match '^h039\b' } | Select-Object -First 1
      $line | Should -Not -BeNullOrEmpty
      $line -match 'gone (\d+)s' | Should -BeTrue
      $expected = [int][math]::Floor(($at - $fx2.Closed['h039']).TotalSeconds)
      Write-Host "    h039 shows gone $($Matches[1])s, expected ~$($expected)s"
      [math]::Abs([int]$Matches[1] - $expected) | Should -BeLessOrEqual 1
    } finally { Stop-Ctop $s }
  }
}

Describe 'portability' -Tag Integration -Skip:$script:noTmux {
  It 'starts on a system without the clear command (minimal Fedora / RHEL images have none)' {
    # PATH: the fake claude, plus only cat (which it runs) and ps. PowerShell's Clear-Host on Linux runs
    # the external clear program and fails with "The expression after '&' ..." when there is none.
    $tools = Join-Path $TestDrive 'tools'
    New-Item -ItemType Directory -Force -Path $tools | Out-Null
    foreach ($t in 'cat', 'ps') {
      $src = (Get-Command $t -CommandType Application | Select-Object -First 1).Source
      New-Item -ItemType SymbolicLink -Path (Join-Path $tools $t) -Target $src | Out-Null
    }
    $fx3 = New-Fixture (Join-Path $TestDrive 'nc') @([DateTimeOffset]::UtcNow.AddMinutes(-5)) $tools
    $s = Start-Ctop $fx3 ''
    try {
      Wait-Screen $s 'live-one' 30 | Should -Not -BeNullOrEmpty
      (Get-Screen $s) | Should -Not -Match 'stopped:'
    } finally { Stop-Ctop $s }
  }
}

Describe 'session lifecycle' -Tag Integration -Skip:$script:noTmux {
  It 'shows the history when no session is live (history-only start)' {
    $fx = New-Fixture (Join-Path $TestDrive 'l1') @([DateTimeOffset]::UtcNow.AddMinutes(-5), [DateTimeOffset]::UtcNow.AddMinutes(-9)) -NoLive
    $s = Start-Ctop $fx '-Keep inf'
    try {
      Wait-Screen $s '(?m)^h000 ' 30 | Should -Not -BeNullOrEmpty
      Wait-Screen $s '(?m)^h001 ' 10 | Should -Not -BeNullOrEmpty   # history loads newest first, a slice per frame
      (Get-Screen $s) | Should -Not -Match 'no interactive sessions'
    } finally { Stop-Ctop $s }
  }

  It 'keeps the history on screen when the last live session leaves' {
    $fx = New-Fixture (Join-Path $TestDrive 'l2') @([DateTimeOffset]::UtcNow.AddMinutes(-5))
    $s = Start-Ctop $fx '-Keep inf -RosterInterval 0.5'
    try {
      Wait-Screen $s '(?m)^live-one ' 30 | Should -Not -BeNullOrEmpty
      Wait-Screen $s '(?m)^h000 ' 30 | Should -Not -BeNullOrEmpty
      Set-Content -LiteralPath $fx.RosterFile -Value '[]'
      Wait-Screen $s '(?m)^live-one +.*gone' 15 | Should -Not -BeNullOrEmpty   # it left, and stays listed as gone
      $screen = Get-Screen $s
      $screen | Should -Match '(?m)^h000 '
      $screen | Should -Not -Match 'no interactive sessions'
    } finally { Stop-Ctop $s }
  }

  It 'says there is nothing to show once the last row is hidden, and peek on nothing does not fail' {
    $fx = New-Fixture (Join-Path $TestDrive 'l3') @([DateTimeOffset]::UtcNow.AddMinutes(-5)) -NoLive
    $s = Start-Ctop $fx '-Keep inf'
    try {
      Wait-Screen $s '(?m)^h000 ' 30 | Should -Not -BeNullOrEmpty
      & tmux send-keys -t $s Enter            # peek the history row
      Wait-Screen $s 'ctop — h000' 5 | Should -Not -BeNullOrEmpty
      & tmux send-keys -t $s Escape
      Start-Sleep -Milliseconds 400
      & tmux send-keys -t $s g                # hide gone rows: nothing left
      Wait-Screen $s 'no interactive sessions' 5 | Should -Not -BeNullOrEmpty
      & tmux send-keys -t $s Enter            # peek with no rows: must not open a stale row or fail
      Start-Sleep -Milliseconds 600
      $screen = Get-Screen $s
      $screen | Should -Not -Match 'ctop — h000'
      $screen | Should -Not -Match 'stopped:|CTOP-EXITED'
      & tmux send-keys -t $s g                # and it comes back
      Wait-Screen $s '(?m)^h000 ' 5 | Should -Not -BeNullOrEmpty
    } finally { Stop-Ctop $s }
  }

  It 'lists a background session from history only with -All, as it does live ones' {
    $fx = New-Fixture (Join-Path $TestDrive 'l4') @([DateTimeOffset]::UtcNow.AddMinutes(-5), [DateTimeOffset]::UtcNow.AddMinutes(-6)) -Kinds @('background', 'interactive')
    $s = Start-Ctop $fx '-Keep inf'
    try {
      Wait-Screen $s '(?m)^h001 ' 30 | Should -Not -BeNullOrEmpty   # the interactive one
      (Get-Screen $s) | Should -Not -Match '(?m)^h000 '
    } finally { Stop-Ctop $s }
    $s = Start-Ctop $fx '-Keep inf -All'
    try {
      Wait-Screen $s '(?m)^h000 ' 30 | Should -Not -BeNullOrEmpty
      (Get-Screen $s) | Should -Match '(?m)^h001 '
    } finally { Stop-Ctop $s }
  }
}

Describe 'a table whose body is one line' -Tag Integration -Skip:$script:noTmux {
  It 'draws a lone session whose row fits on one line (a one-line body was drawn as nothing)' {
    $fx = New-Fixture (Join-Path $TestDrive 'one') @()
    $start = [DateTimeOffset]::UtcNow.AddMinutes(-30).ToUnixTimeMilliseconds()
    # no transcript: an empty title, so the row does not wrap
    Set-Content -LiteralPath $fx.RosterFile -Value ('[{"pid":' + $PID + ',"cwd":"/tmp","kind":"interactive","startedAt":' + $start + ',"sessionId":"solo-1","name":"solo-one","status":"idle"}]')
    $s = Start-Ctop $fx ''
    try { Wait-Screen $s '(?m)^solo-one ' 20 | Should -Not -BeNullOrEmpty } finally { Stop-Ctop $s }
  }
}

Describe 'bad roster data' -Tag Integration -Skip:$script:noTmux {
  It 'keeps running when a session has an impossible startedAt (it crashed ctop)' {
    $fx = New-Fixture (Join-Path $TestDrive 'bad') @()
    Set-Content -LiteralPath $fx.RosterFile -Value '[{"pid":1,"cwd":"/","kind":"interactive","startedAt":99999999999999999,"sessionId":"bad-1","name":"bad-one","status":"idle"}]'
    $s = Start-Ctop $fx ''
    try {
      Wait-Screen $s '(?m)^bad-one ' 30 | Should -Not -BeNullOrEmpty
      Start-Sleep -Seconds 2
      (Get-Screen $s) | Should -Not -Match 'stopped:|CTOP-EXITED'
      & tmux send-keys -t $s q
      Test-CleanExit (Wait-Exit $s 5) | Should -BeTrue
    } finally { Stop-Ctop $s }
  }
}

Describe 'the test harness itself' -Tag Integration -Skip:$script:noTmux {
  It 'refuses a frame reading from a frozen screen' {
    $script:n++
    $s = "ctop-it-$PID-$($script:n)"
    & tmux new-session -d -s $s -x 200 -y 20 "echo '  ctop  12:00:00'; echo 'frame 1ms'; sleep 60"
    try { { Get-MedianFrame $s } | Should -Throw -ExpectedMessage '*did not advance*' } finally { Stop-Ctop $s }
  }
  It 'refuses a frame reading once ctop has exited' {
    $script:n++
    $s = "ctop-it-$PID-$($script:n)"
    & tmux new-session -d -s $s -x 200 -y 20 "echo '  ctop  12:00:00'; echo 'frame 1ms'; echo CTOP-EXITED 1; sleep 60"
    try { { Get-MedianFrame $s } | Should -Throw -ExpectedMessage '*not running*' } finally { Stop-Ctop $s }
  }
  It 'rejects a child that crashes after drawing a frame, which the quit check used to accept' {
    $script:n++
    $s = "ctop-it-$PID-$($script:n)"
    $err = Join-Path ([IO.Path]::GetTempPath()) "$s.err"; $script:ErrFile[$s] = $err
    & tmux new-session -d -s $s -x 200 -y 20 "echo 'frame 5ms'; echo 'ctop x stopped: boom' >&2; sh -c 'exit 1' 2>'$err'; echo CTOP-EXITED `$?; sleep 30"
    try {
      $x = Wait-Exit $s 10
      $x | Should -Not -BeNullOrEmpty
      $x.Code | Should -Be 1
      Test-CleanExit $x | Should -BeFalse
    } finally { Stop-Ctop $s }
  }
  It 'accepts a clean exit' {
    $script:n++
    $s = "ctop-it-$PID-$($script:n)"
    & tmux new-session -d -s $s -x 200 -y 20 "echo 'frame 5ms'; true; echo CTOP-EXITED `$?; sleep 30"
    try { Test-CleanExit (Wait-Exit $s 10) | Should -BeTrue } finally { Stop-Ctop $s }
  }
}
