# End to end: the real ctop.ps1 in a terminal (tmux), against a fake `claude` that prints a fixed roster
# and a scratch config dir holding synthetic transcripts and a closed-sessions history.
# Needs tmux (Linux). Run alone with:  Invoke-Pester ./tests -TagFilter Integration
BeforeDiscovery { $script:noTmux = -not (Get-Command tmux -ErrorAction SilentlyContinue) -or $IsWindows }
AfterAll { if ($script:tmuxExe) { & $script:tmuxExe -L $script:tmuxSock kill-server 2>$null } }

BeforeAll {
  $script:ctop = Join-Path (Split-Path -Parent $PSScriptRoot) 'ctop.ps1'
  $script:pwsh = (Get-Process -Id $PID).Path
  $script:n = 0

  # Every tmux call below goes to a private server for this run (tmux -L): the tests never touch your own
  # sessions or options. A function wins over the program of the same name, so `& tmux …` lands here.
  $script:tmuxExe = (Get-Command tmux -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
  $script:tmuxSock = "ctop-it-$PID"
  function tmux { & $script:tmuxExe -L $script:tmuxSock @args }

  # a synthetic transcript: prompt, tool call + result, reply; repeated to ~60 KB
  function New-Transcript([string]$path, [string]$sid, [int]$turns = 25, [string]$prompt = ('do the thing ' + ('x' * 400))) {
    $ts = [DateTime]::UtcNow.AddDays(-3).ToString('o')
    $turn = @(
      @{ type = 'user'; sessionId = $sid; timestamp = $ts; cwd = '/w'; message = @{ role = 'user'; content = $prompt } }
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
                       [switch]$NoLive, [string[]]$Kinds = @(), [string]$Prompt = ('do the thing ' + ('x' * 400))) {
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
      New-Transcript $tf $sid $Turns $Prompt
      [IO.File]::SetLastWriteTimeUtc($tf, $closedAt[$i].UtcDateTime)
      $name = 'h{0:d3}' -f $i; $closed[$name] = $closedAt[$i]
      @{ closedAt = $closedAt[$i].ToString('o'); why = 'closed'; name = $name; title = "history $i"
         sessionId = $sid; cwd = "/w/p$($i % 12)"; pid = 50000 + $i; startedAt = 1793400000000
         kind = $(if ($i -lt $Kinds.Count) { $Kinds[$i] } else { 'interactive' }) } | ConvertTo-Json -Compress
    }
    $closedLog = Join-Path $root 'closed.jsonl'
    [IO.File]::WriteAllLines($closedLog, [string[]]@($log | Where-Object { $_ }))   # none: an empty log
    return @{ Cfg = $cfg; Log = $closedLog; Env = "CLAUDE_CONFIG_DIR='$cfg' PATH='${bin}:$PathTail'"; Closed = $closed
              RosterFile = $rosterFile; LiveJson = $liveJson; Fake = $fake }
  }

  # cells on screen, for plain text (East Asian wide characters count two)
  function Get-CellWidthForTest([string]$t) { $t.Length + [regex]::Matches($t, '[\u1100-\u115F\u2E80-\uA4CF\uAC00-\uD7A3\uF900-\uFAFF\uFF00-\uFF60\uFFE0-\uFFE6]').Count }
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
  # ms from a key to the screen answering it: the keep window, shown on the strip and in the footer, goes
  # from $from to $to. Before the key both must read $from (else it throws: no clean starting state).
  # It counts as answered only once both read $to and the screen has changed, so a half-drawn frame
  # (strip new, footer old) or a frozen screen showing the new value somewhere is not taken for an answer.
  # $null when no answer came in $seconds.
  function Get-KeepShown([string]$screen) { @([regex]::Matches($screen, 'keep (\S+)') | ForEach-Object { $_.Groups[1].Value }) }
  function Measure-KeyResponse([string]$s, [string]$key, [string]$from, [string]$to, [double]$seconds = 5) {
    $before = Get-Screen $s
    $shown = Get-KeepShown $before
    if ($shown.Count -lt 2 -or @($shown | Where-Object { $_ -ne $from }).Count) { throw "before the key the screen must show keep $from on the strip and footer; it shows: $($shown -join ', ')" }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & tmux send-keys -t $s $key
    while ($sw.Elapsed.TotalSeconds -lt $seconds) {
      $screen = Get-Screen $s
      $shown = Get-KeepShown $screen
      if ($screen -ne $before -and $shown.Count -ge 2 -and -not @($shown | Where-Object { $_ -ne $to }).Count) { return $sw.Elapsed.TotalMilliseconds }
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
        if ($i % 2 -eq 0) { Measure-KeyResponse $s '-' '30d' '14d' } else { Measure-KeyResponse $s '+' '14d' '30d' }
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

Describe 'titles in a non-Latin script' -Tag Integration -Skip:$script:noTmux {
  It 'cost about what ASCII titles do (a screenful of Hebrew or Chinese titles, frame median)' {
    # The same history three times, with ASCII, Hebrew and Chinese titles. Text the width fast paths do not
    # cover is measured element by element, ~10 ms a line (Hebrew titles took a frame from ~55 to ~175 ms).
    # Relative, so it holds on slower and faster machines alike.
    $now = [DateTimeOffset]::UtcNow
    $at = @(for ($i = 0; $i -lt 60; $i++) { $now.AddMinutes(-2 - $i) })
    $hebrew = (-join @(0x05EA, 0x05E7, 0x05DF, 0x0020, 0x05D0, 0x05EA, 0x0020, 0x05D4, 0x05D1, 0x05D3, 0x05D9, 0x05E7, 0x05D5, 0x05EA, 0x0020 | ForEach-Object { [char]$_ })) * 12
    $chinese = (-join @(0x4FEE, 0x590D, 0x6D4B, 0x8BD5, 0x7528, 0x4F8B, 0x0020 | ForEach-Object { [char]$_ })) * 10
    $med = @{}
    foreach ($case in @(@{ Name = 'ascii'; Prompt = ('fix the tests ' * 12) }, @{ Name = 'hebrew'; Prompt = $hebrew }, @{ Name = 'chinese'; Prompt = $chinese })) {
      $fx = New-Fixture (Join-Path $TestDrive "script-$($case.Name)") $at -Turns 1 -Prompt $case.Prompt
      $s = Start-Ctop $fx '-Keep inf'
      try {
        Wait-Screen $s 'gone 60\b|60 gone' 60 | Should -Not -BeNullOrEmpty
        Wait-Screen $s ([regex]::Escape($case.Prompt.Substring(0, 8))) 10 | Should -Not -BeNullOrEmpty -Because 'the titles measured must be on screen'
        Start-Sleep -Seconds 6
        $med[$case.Name] = Get-MedianFrame $s
      } finally { Stop-Ctop $s }
    }
    Write-Host ("    frame median: ascii titles {0} ms, hebrew {1} ms, chinese {2} ms" -f $med.ascii, $med.hebrew, $med.chinese)
    $limit = [math]::Max(1.5 * $med.ascii, $med.ascii + 15)
    $med.hebrew | Should -BeLessThan $limit
    $med.chinese | Should -BeLessThan $limit
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

Describe 'a roster poll that hangs' -Tag Integration -Skip:$script:noTmux {
  It 'gives up on it, keeps the last roster, says so, and recovers when polls work again' {
    $fx = New-Fixture (Join-Path $TestDrive 'hang') @()
    $flag = Join-Path $TestDrive 'hang/hang-now'
    # hangs while the flag file exists (as a stuck claude agents --json would), answers otherwise
    Set-Content -LiteralPath $fx.Fake -Value "#!/bin/sh`nif [ -e '$flag' ]; then exec sleep 600; fi`ncat '$($fx.RosterFile)'"
    $s = Start-Ctop $fx '-RosterInterval 0.5'
    try {
      Wait-Screen $s '(?m)^live-one ' 30 | Should -Not -BeNullOrEmpty
      New-Item -ItemType File -Path $flag | Out-Null
      Wait-Screen $s 'poll FAILED' 20 | Should -Not -BeNullOrEmpty -Because 'a hung poll must time out (it blocked every later poll)'
      (Get-Screen $s) | Should -Match '(?m)^live-one '          # the last good roster stays
      Remove-Item -LiteralPath $flag
      Wait-Screen $s 'poll +\d+ms' 20 | Should -Not -BeNullOrEmpty -Because 'polls resume once claude answers again'
      (Get-Screen $s) | Should -Match '(?m)^live-one '
    } finally { Stop-Ctop $s; Remove-Item -LiteralPath $flag -ErrorAction SilentlyContinue }
  }
}

Describe 'hostile session text' -Tag Integration -Skip:$script:noTmux {
  BeforeAll {
    # Two sessions, one payload each, so each view is judged on its own: the cwd one is newer (listed
    # first, so peek opens on it; peek showed the cwd raw), the title one older (the closed log showed
    # titles raw). Nothing here clears the screen (the unit tests cover that), so no screen check can
    # fail before the clipboard is checked.
    function Start-Hostile([string]$dir) {
      $fx = New-Fixture (Join-Path $TestDrive $dir) @() -NoLive
      $osc = { param($text) "$([char]27)]52;c;$([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text)))$([char]7)" }
      $recs = @(
        @{ closedAt = [DateTimeOffset]::UtcNow.AddMinutes(-2).ToString('o'); why = 'closed'; name = 'evil-cwd'; title = 'plain title'
           sessionId = 'eeeeeeee-0000-4000-8000-000000000002'; cwd = "/tmp/a$(& $osc 'pwned-by-cwd')b"; pid = 1; startedAt = 1793400000000; kind = 'interactive' }
        @{ closedAt = [DateTimeOffset]::UtcNow.AddMinutes(-3).ToString('o'); why = 'closed'; name = 'evil-title'; title = "evil $(& $osc 'pwned-by-title') title"
           sessionId = 'eeeeeeee-0000-4000-8000-000000000001'; cwd = '/tmp/plain'; pid = 1; startedAt = 1793400000000; kind = 'interactive' }
      ) | ForEach-Object { $_ | ConvertTo-Json -Compress }
      [IO.File]::WriteAllLines($fx.Log, [string[]]$recs)
      # A server must exist before its options can be set (an empty one exits): a holder session first.
      $script:n++; $h = @{ Hold = "ctop-it-$PID-$($script:n)-hold"; S = $null }
      & tmux new-session -d -s $h.Hold -x 80 -y 10 'sleep 120'
      $h.Prev = & tmux show-options -gv set-clipboard
      & tmux set-option -g set-clipboard on
      $LASTEXITCODE | Should -Be 0
      & tmux show-options -gv set-clipboard | Should -Be 'on'
      # positive control: with this setting an application's OSC 52 does land in a tmux buffer
      $ctl = "control-payload-$($script:n)"
      & tmux new-window -d -t $h.Hold "printf '\033]52;c;$([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($ctl)))\a'; sleep 60"
      $sw = [Diagnostics.Stopwatch]::StartNew(); $seen = ''
      while ($sw.Elapsed.TotalSeconds -lt 5 -and $seen -notmatch $ctl) { $seen = Get-Buffers; Start-Sleep -Milliseconds 100 }
      $seen | Should -Match $ctl -Because 'the terminal must accept OSC 52, or a clean result below proves nothing'
      $h.S = Start-Ctop $fx '-Keep inf'
      Wait-Screen $h.S '(?m)^evil-cwd ' 30 | Should -Not -BeNullOrEmpty
      Wait-Screen $h.S '(?m)^evil-title ' 5 | Should -Not -BeNullOrEmpty
      $h
    }
    function Stop-Hostile($h) {
      if (-not $h) { return }
      if ($h.Prev) { & tmux set-option -g set-clipboard $h.Prev }   # later tests share this private server
      if ($h.S) { Stop-Ctop $h.S }; Stop-Ctop $h.Hold
    }
    function Get-Buffers { (& tmux list-buffers -F '#{buffer_sample}' 2>$null) -join "`n" }
  }
  # Each view in its own test: a failure in one cannot hide the other. The clipboard is checked once the
  # view has had time to draw, before anything is read off the screen.
  It 'does not let a cwd set the clipboard in peek (OSC 52)' {
    $h = $null
    try {
      $h = Start-Hostile 'osc-peek'
      & tmux send-keys -t $h.S Home Enter          # peek on evil-cwd: its cwd, in full
      Start-Sleep -Milliseconds 1500
      Get-Buffers | Should -Not -Match 'pwned-by' -Because 'peek drew the cwd'
      Wait-Screen $h.S 'ctop — evil-cwd' 5 | Should -Not -BeNullOrEmpty -Because 'the check above must have been made on peek'
    } finally { Stop-Hostile $h }
  }
  It 'does not let a title or cwd set the clipboard in the closed-sessions log (OSC 52)' {
    $h = $null
    try {
      $h = Start-Hostile 'osc-log'
      & tmux send-keys -t $h.S x                   # the closed-sessions log: both titles and cwds
      Start-Sleep -Milliseconds 1500
      Get-Buffers | Should -Not -Match 'pwned-by' -Because 'the closed log drew the titles and cwds'
      Wait-Screen $h.S 'closed sessions' 5 | Should -Not -BeNullOrEmpty -Because 'the check above must have been made on the closed log'
    } finally { Stop-Hostile $h }
  }
}

Describe 'a snapshot (-Snapshot)' -Tag Integration -Skip:$script:noTmux {
  # Not in tmux: a snapshot is for pipes and files, where there is no console to size the window by.
  BeforeAll {
    function Invoke-Snapshot($fx, [string[]]$more) {
      $out = Join-Path $TestDrive "snap-$([guid]::NewGuid()).txt"; $err = "$out.err"
      $cmd = "$($fx.Env) '$($script:pwsh)' -NoProfile -File '$($script:ctop)' -ClosedLog '$($fx.Log)' -Snapshot $($more -join ' ') >'$out' 2>'$err' </dev/null; echo `$?"
      $sw = [Diagnostics.Stopwatch]::StartNew()
      $code = (& sh -c $cmd | Select-Object -Last 1)
      @{ Code = [int]$code; Ms = $sw.ElapsedMilliseconds; Text = [IO.File]::ReadAllText($out); Err = [IO.File]::ReadAllText($err) }
    }
  }
  It 'prints one frame, every session listed, as plain text within the width, and exits 0' {
    $now = [DateTimeOffset]::UtcNow
    $fx = New-Fixture (Join-Path $TestDrive 'snap') @(for ($i = 0; $i -lt 70; $i++) { $now.AddMinutes(-2 - $i) }) -Turns 1
    $x = Invoke-Snapshot $fx @('-Keep', 'inf', '-MaxWidth', '120')
    $x.Code | Should -Be 0 -Because $x.Err
    $x.Err.Trim() | Should -BeNullOrEmpty
    $lines = $x.Text -split "`r?`n"
    $lines[0] | Should -Match 'ctop'
    $x.Text | Should -Match '(?m)^live-one '
    foreach ($i in 0, 35, 69) { $x.Text | Should -Match ('(?m)^h{0:d3} ' -f $i) -Because 'a snapshot lists every row, not a screenful' }
    $x.Text | Should -Not -Match "[\x00-\x08\x0B-\x1F\x7F]" -Because 'plain text: no colors, no cursor movement'
    foreach ($l in $lines) { Get-CellWidthForTest $l | Should -BeLessOrEqual 120 }
    $lines[1] | Should -Match 'hidden \d+ cols' -Because 'at 120 columns some columns do not fit, and the strip says so'
  }
  It 'writes nothing: no scan cache, no closed log entries' {
    $fx = New-Fixture (Join-Path $TestDrive 'snap-ro') @([DateTimeOffset]::UtcNow.AddMinutes(-3)) -Turns 1
    $before = [IO.File]::ReadAllText($fx.Log)
    $x = Invoke-Snapshot $fx @('-Keep', 'inf')
    $x.Code | Should -Be 0 -Because $x.Err
    Test-Path -LiteralPath (Join-Path $fx.Cfg 'ctop-scancache.json') | Should -BeFalse
    [IO.File]::ReadAllText($fx.Log) | Should -BeExactly $before
  }
  It 'says why when the roster cannot be read, and still exits' {
    $fx = New-Fixture (Join-Path $TestDrive 'snap-bad') @() -NoLive
    Set-Content -LiteralPath $fx.Fake -Value "#!/bin/sh`necho not-json"
    $x = Invoke-Snapshot $fx @()
    $x.Text | Should -Match "claude agents --json' failed"
    $x.Code | Should -Be 0
  }
}

Describe 'copying a contact' -Tag Integration -Skip:$script:noTmux {
  It 'puts the selected session''s contact on the clipboard with n, and its ID with d (OSC 52 into tmux)' {
    $fx = New-Fixture (Join-Path $TestDrive 'contact') @()
    $script:n++; $hold = "ctop-it-$PID-$($script:n)-hold"
    & tmux new-session -d -s $hold -x 80 -y 10 'sleep 120'    # a server, so the option below sticks
    $prev = & tmux show-options -gv set-clipboard; $s = $null
    $buffers = { (& tmux list-buffers -F '#{buffer_name}' 2>$null) | ForEach-Object { (& tmux show-buffer -b $_ 2>$null) -join "`n" } }
    try {
      & tmux set-option -g set-clipboard on
      & tmux show-options -gv set-clipboard | Should -Be 'on'
      $s = Start-Ctop $fx '-Keep inf'
      Wait-Screen $s '(?m)^live-one ' 30 | Should -Not -BeNullOrEmpty
      & tmux send-keys -t $s Home n
      $sw = [Diagnostics.Stopwatch]::StartNew(); $got = ''
      while ($sw.Elapsed.TotalSeconds -lt 5 -and $got -notmatch 'Claude Code session') { $got = (& $buffers) -join "`n---`n"; Start-Sleep -Milliseconds 100 }
      $got | Should -Match '(?m)^Name: +live-one +\(address: @live-one\)'
      $got | Should -Match '(?m)^Session ID: +11111111-1111-4111-8111-111111111111'
      Wait-Screen $s '(copied|sent) contact' 5 | Should -Not -BeNullOrEmpty   # the flash says what was copied
      & tmux send-keys -t $s d
      $sw.Restart()
      while ($sw.Elapsed.TotalSeconds -lt 5 -and -not ((& $buffers) -contains '11111111-1111-4111-8111-111111111111')) { Start-Sleep -Milliseconds 100 }
      (& $buffers) | Should -Contain '11111111-1111-4111-8111-111111111111'
    } finally {
      & tmux set-option -g set-clipboard $prev
      if ($s) { Stop-Ctop $s }; Stop-Ctop $hold
    }
  }
}

Describe 'wide characters in a row' -Tag Integration -Skip:$script:noTmux {
  It 'keeps the columns after a CJK name in line with the other rows (a wide character takes two cells)' {
    $fx = New-Fixture (Join-Path $TestDrive 'cjk') @() -NoLive
    $at = [DateTimeOffset]::UtcNow.AddMinutes(-3).ToString('o')
    $recs = foreach ($n in 'plain-name', "$([char]0x65E5)$([char]0x672C)$([char]0x8A9E)-name") {
      @{ closedAt = $at; why = 'closed'; name = $n; title = 't'; sessionId = [guid]::NewGuid().ToString(); cwd = '/w'
         pid = 1; startedAt = 1793400000000; kind = 'interactive' } | ConvertTo-Json -Compress
    }
    [IO.File]::WriteAllLines($fx.Log, [string[]]$recs, [Text.UTF8Encoding]::new($false))
    $s = Start-Ctop $fx '-Keep inf'
    try {
      Wait-Screen $s '(?m)^plain-name ' 30 | Should -Not -BeNullOrEmpty
      Wait-Screen $s '(?m)^\S+-name .*gone[\s\S]*^\S+-name .*gone' 10 | Should -Not -BeNullOrEmpty
      $lines = (Get-Screen $s) -split "`n"
      $plain = @($lines | Where-Object { $_ -like 'plain-name *' })[0]
      $wide = @($lines | Where-Object { $_ -like "$([char]0x65E5)*" })[0]
      # three wide characters: three characters fewer in the text for the same cell position on screen
      ($wide.IndexOf('gone') + 3) | Should -Be $plain.IndexOf('gone') -Because "`n$plain`n$wide"
    } finally { Stop-Ctop $s }
  }
}

Describe 'a gone session whose transcript moves' -Tag Integration -Skip:$script:noTmux {
  It 'reads the new file when it is another file of the same size and time, also when only the case differs' {
    $fx = New-Fixture (Join-Path $TestDrive 'mv') @([DateTimeOffset]::UtcNow.AddMinutes(-3)) -NoLive -Turns 1
    $sid = '00000000-0000-4000-8000-000000000000'                 # h000, under projects/-w-p0
    $old = Join-Path $fx.Cfg "projects/-w-p0/$sid.jsonl"
    $when = [IO.File]::GetLastWriteTimeUtc($old)
    # the same transcript, its last reply spelled differently (same length): only the file tells them apart
    $move = { param($from, $dir, $reply)
      $to = Join-Path $fx.Cfg "projects/$dir/$sid.jsonl"
      New-Item -ItemType Directory -Force -Path (Split-Path $to) | Out-Null
      [IO.File]::WriteAllText($to, ([IO.File]::ReadAllText($from) -replace '"text":"[A-Za-z]{4}"', "`"text`":`"$reply`""))
      [IO.File]::SetLastWriteTimeUtc($to, $when); Remove-Item -LiteralPath $from
      $to
    }
    $s = Start-Ctop $fx '-Keep inf -RosterInterval 0.5'
    try {
      Wait-Screen $s '(?m)^h000 .*text: done' 30 | Should -Not -BeNullOrEmpty
      $new = & $move $old '-w-moved' 'DONE'                       # another directory (the session moved)
      Wait-Screen $s '(?m)^h000 .*text: DONE' 10 | Should -Not -BeNullOrEmpty -Because 'the row must follow its transcript to the new file'
      $null = & $move $new '-W-MOVED' 'Done'                       # a directory that differs only in case (Linux: another one)
      Wait-Screen $s '(?m)^h000 .*text: Done' 10 | Should -Not -BeNullOrEmpty -Because 'on Linux -w-moved and -W-MOVED are different directories'
    } finally { Stop-Ctop $s }
  }
}

Describe 'tree cost of a session that leaves' -Tag Integration -Skip:$script:noTmux {
  BeforeAll {
    # Expected dollars, worked out by hand rather than with ctop's code: a New-Transcript turn holds two
    # claude-sonnet-5-5 replies (list price per million: in $2, out $10, cache read $0.10, 5-minute cache
    # write $2.50), with no message id, so each counts once:
    #   (10+10)·2 + (200+300)·10 + (30000+31000)·0.1 + (500+200)·2.5 = 12,890 per million = $0.01289 a turn
    function Usd([int]$turns) { '${0:N2}' -f ($turns * 0.01289) }
  }
  It 'still counts its subagents once it is gone, and follows a subagent transcript that grows after it left' {
    $fx = New-Fixture (Join-Path $TestDrive 'tc') @()    # the session's own transcript: 25 turns
    $sid = '11111111-1111-4111-8111-111111111111'
    $sub = Join-Path $fx.Cfg "projects/-w/$sid/subagents"
    New-Item -ItemType Directory -Force -Path $sub | Out-Null
    $agent = Join-Path $sub 'agent-a1b2c3d4.jsonl'
    New-Transcript $agent $sid 5                          # its subagent: 5 turns
    $tree = { param($own, $agentTurns) [regex]::Escape("TREE COST    $(Usd ($own + $agentTurns)) at list price:  this session $(Usd $own) · 1 subagent $(Usd $agentTurns)") }
    $s = Start-Ctop $fx '-Keep inf -RosterInterval 0.5'
    try {
      Wait-Screen $s '(?m)^live-one ' 30 | Should -Not -BeNullOrEmpty
      & tmux send-keys -t $s Home Enter
      Wait-Screen $s (& $tree 25 5) 10 | Should -Not -BeNullOrEmpty -Because 'while live'
      & tmux send-keys -t $s Escape
      Set-Content -LiteralPath $fx.RosterFile -Value '[]'               # it leaves
      Wait-Screen $s '(?m)^live-one +.*gone' 15 | Should -Not -BeNullOrEmpty
      & tmux send-keys -t $s Home Enter
      Wait-Screen $s 'ctop — live-one' 5 | Should -Not -BeNullOrEmpty
      Wait-Screen $s (& $tree 25 5) 5 | Should -Not -BeNullOrEmpty -Because 'its subagents still cost what they cost'
      # the subagent carries on after its session left (a background agent finishing): 20 more turns
      $lines = [IO.File]::ReadAllLines($agent)
      [IO.File]::AppendAllLines($agent, [string[]]($lines * 4))
      Wait-Screen $s (& $tree 25 25) 10 | Should -Not -BeNullOrEmpty -Because 'the gone row follows its subagent transcripts'
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
  It 'does not take a frozen half-drawn screen (strip new, footer old) for a key response' {
    $script:n++
    $s = "ctop-it-$PID-$($script:n)"
    & tmux new-session -d -s $s -x 200 -y 20 "echo 'strip  keep 14d '; echo 'footer  +/- keep 30d '; sleep 60"
    try {
      Start-Sleep -Milliseconds 300
      { Measure-KeyResponse $s '-' '30d' '14d' 2 } | Should -Throw -ExpectedMessage '*before the key*'
      { Measure-KeyResponse $s '+' '14d' '30d' 2 } | Should -Throw -ExpectedMessage '*before the key*'
    } finally { Stop-Ctop $s }
  }
  It 'does not take a frozen screen for a key response' {
    $script:n++
    $s = "ctop-it-$PID-$($script:n)"
    & tmux new-session -d -s $s -x 200 -y 20 "echo 'strip  keep 30d '; echo 'footer  +/- keep 30d '; sleep 60"
    try {
      Start-Sleep -Milliseconds 300
      Measure-KeyResponse $s '-' '30d' '14d' 2 | Should -BeNullOrEmpty
    } finally { Stop-Ctop $s }
  }
  It 'accepts a clean exit' {
    $script:n++
    $s = "ctop-it-$PID-$($script:n)"
    & tmux new-session -d -s $s -x 200 -y 20 "echo 'frame 5ms'; true; echo CTOP-EXITED `$?; sleep 30"
    try { Test-CleanExit (Wait-Exit $s 10) | Should -BeTrue } finally { Stop-Ctop $s }
  }
}
