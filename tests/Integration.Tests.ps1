# End to end: the real ctop.ps1 in a terminal (tmux), against a fake `claude` that prints a fixed roster
# and a scratch config dir holding synthetic transcripts and a closed-sessions history.
# Needs tmux (Linux). Run alone with:  Invoke-Pester ./tests -TagFilter Integration
BeforeDiscovery { $script:noTmux = -not (Get-Command tmux -ErrorAction SilentlyContinue) -or $IsWindows }

BeforeAll {
  $script:ctop = Join-Path (Split-Path -Parent $PSScriptRoot) 'ctop.ps1'
  $script:pwsh = (Get-Process -Id $PID).Path
  $script:n = 0

  # a synthetic transcript: prompt, tool call + result, reply; repeated to ~60 KB
  function New-Transcript([string]$path, [string]$sid) {
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
    $lines = for ($i = 0; $i -lt 25; $i++) { $turn }
    [IO.File]::WriteAllLines($path, [string[]]$lines)
  }

  # A config dir with one live session (pid: this test process, so the OS columns resolve) and one
  # closed session per entry of $closedAt, each with its transcript on disk. A transcript stops changing
  # when its session closes, so its write time is set to the close time (IDLE then reads like real
  # history). Returns what Start-Ctop needs, plus each history row's name -> close time.
  function New-Fixture([string]$root, [DateTimeOffset[]]$closedAt) {
    $cfg = Join-Path $root 'cfg'; $bin = Join-Path $root 'bin'
    New-Item -ItemType Directory -Force -Path $bin, (Join-Path $cfg 'projects/-w') | Out-Null
    $live = @{ pid = $PID; cwd = $root; kind = 'interactive'; startedAt = [DateTimeOffset]::UtcNow.AddHours(-1).ToUnixTimeMilliseconds()
               sessionId = '11111111-1111-4111-8111-111111111111'; name = 'live-one'; status = 'idle' }
    $rosterFile = Join-Path $root 'roster.json'
    ConvertTo-Json -InputObject @($live) -Depth 5 | Set-Content -LiteralPath $rosterFile
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
      New-Transcript $tf $sid
      [IO.File]::SetLastWriteTimeUtc($tf, $closedAt[$i].UtcDateTime)
      $name = 'h{0:d3}' -f $i; $closed[$name] = $closedAt[$i]
      @{ closedAt = $closedAt[$i].ToString('o'); why = 'closed'; name = $name; title = "history $i"
         sessionId = $sid; cwd = "/w/p$($i % 12)"; pid = 50000 + $i; startedAt = 1793400000000; kind = 'interactive' } | ConvertTo-Json -Compress
    }
    $closedLog = Join-Path $root 'closed.jsonl'
    [IO.File]::WriteAllLines($closedLog, [string[]]$log)
    return @{ Cfg = $cfg; Log = $closedLog; Env = "CLAUDE_CONFIG_DIR='$cfg' PATH='${bin}:$env:PATH'"; Closed = $closed }
  }

  function Start-Ctop($fx, [string]$ctopArgs, [int]$height = 50) {
    $script:n++
    $s = "ctop-it-$PID-$($script:n)"
    $cmd = "$($fx.Env) '$($script:pwsh)' -NoProfile -File '$($script:ctop)' -ClosedLog '$($fx.Log)' -NoColor $ctopArgs; echo CTOP-EXITED; sleep 60"
    & tmux new-session -d -s $s -x 200 -y $height $cmd
    return $s
  }
  function Get-Screen([string]$s) { (& tmux capture-pane -p -t $s) -join "`n" }
  function Wait-Screen([string]$s, [string]$pattern, [double]$seconds) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $seconds) {
      if ((Get-Screen $s) -match $pattern) { return $sw.Elapsed.TotalSeconds }
      Start-Sleep -Milliseconds 100
    }
    return $null
  }
  function Stop-Ctop([string]$s) { & tmux kill-session -t $s 2>$null }
  # median of the frame times ctop reports on its strip, sampled over ~5 s
  function Get-MedianFrame([string]$s) {
    $ms = for ($i = 0; $i -lt 12; $i++) {
      if ((Get-Screen $s) -match 'frame +(\d+)ms') { [int]$Matches[1] }
      Start-Sleep -Milliseconds 400
    }
    $median = @($ms | Sort-Object)[[math]::Floor(@($ms).Count / 2)]
    Write-Host "    frame ms: $($ms -join ' ')  (median $median)"
    return $median
  }
}

Describe 'ctop under a long history' -Tag Integration -Skip:$script:noTmux {
  BeforeAll {
    # 300 closed sessions over the last 30 days
    $rand = [Random]::new(7)
    $now = [DateTimeOffset]::UtcNow
    $script:fx = New-Fixture (Join-Path $TestDrive 'h') @(for ($i = 0; $i -lt 300; $i++) { $now.AddMinutes(-1 - $rand.NextDouble() * 30 * 1440) })
  }

  It 'shows the live session within 2 s of starting, while the history is still loading (cold cache)' {
    Remove-Item -LiteralPath (Join-Path $fx.Cfg 'ctop-scancache.json') -ErrorAction SilentlyContinue
    # baseline: what starting pwsh and parsing ctop.ps1 costs on this machine
    $sw = [Diagnostics.Stopwatch]::StartNew(); & $script:pwsh -NoProfile -File $script:ctop -Version | Out-Null; $base = $sw.Elapsed.TotalSeconds
    $sw.Restart()
    $s = Start-Ctop $fx '-Keep inf'
    try {
      Wait-Screen $s 'live-one' 60 | Should -Not -BeNullOrEmpty
      $took = $sw.Elapsed.TotalSeconds
      Write-Host ("    pwsh start {0:N1} s, live session shown after {1:N1} s" -f $base, $took)
      $took | Should -BeLessThan ($base + 2)
    } finally { Stop-Ctop $s }
  }

  It 'lists the whole history at keep ∞' {
    $s = Start-Ctop $fx '-Keep inf'
    try {
      Wait-Screen $s 'live-one' 60 | Should -Not -BeNullOrEmpty
      Wait-Screen $s 'gone 300' 30 | Should -Not -BeNullOrEmpty
    } finally { Stop-Ctop $s }
  }

  It 'quits on q within 2 s with 300 gone rows listed' {
    $s = Start-Ctop $fx '-Keep inf'
    try {
      Wait-Screen $s 'gone 300' 60 | Should -Not -BeNullOrEmpty
      Start-Sleep -Seconds 3   # past the first scans: steady state
      & tmux send-keys -t $s q
      Wait-Screen $s 'CTOP-EXITED' 2 | Should -Not -BeNullOrEmpty
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
      Wait-Screen $s 'gone 300' 60 | Should -Not -BeNullOrEmpty
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
      Wait-Screen $s 'gone 300' 60 | Should -Not -BeNullOrEmpty
      Start-Sleep -Seconds 10   # past warm-up (first scans, first full render)
      Get-MedianFrame $s | Should -BeLessThan 250
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
      Wait-Screen $s 'gone 300' 60 | Should -Not -BeNullOrEmpty
      Start-Sleep -Seconds 10
      $full = Get-MedianFrame $s
    } finally { Stop-Ctop $s }
    Write-Host "    a screenful: $base ms, 300 rows: $full ms"
    $full | Should -BeLessThan (1.5 * $base)
  }
}

Describe 'ages on rows that scroll into view' -Tag Integration -Skip:$script:noTmux {
  BeforeAll {
    # 60 sessions that closed 5–35 s ago: their ages tick every second, so a stale one shows
    $now = [DateTimeOffset]::UtcNow
    $script:fx2 = New-Fixture (Join-Path $TestDrive 'a') @(for ($i = 0; $i -lt 60; $i++) { $now.AddSeconds(-5 - $i / 2) })
  }

  It 'shows the current age on a row the moment it scrolls into view, after time off screen' {
    # 20 lines: most of the 60 rows are off screen. A 3 s tick keeps the frame drawn right after the key
    # on screen while it is read, so a row refreshed only by the NEXT frame would show its stale age.
    $s = Start-Ctop $fx2 '-Keep inf -Tick 3000' 20
    try {
      Wait-Screen $s 'gone 60 ' 60 | Should -Not -BeNullOrEmpty
      Start-Sleep -Seconds 6               # the bottom rows' ages move on while they are off screen
      & tmux send-keys -t $s End           # oldest gone is listed last; the key repaints at once
      Start-Sleep -Milliseconds 700
      $screen = Get-Screen $s
      $at = [DateTimeOffset]::UtcNow
      $line = ($screen -split "`n") | Where-Object { $_ -match '^h059\b' } | Select-Object -First 1
      $line | Should -Not -BeNullOrEmpty
      $line -match 'gone (\d+)s' | Should -BeTrue
      $expected = [int][math]::Floor(($at - $fx2.Closed['h059']).TotalSeconds)
      Write-Host "    h059 shows gone $($Matches[1])s, expected ~$($expected)s"
      [math]::Abs([int]$Matches[1] - $expected) | Should -BeLessOrEqual 1
    } finally { Stop-Ctop $s }
  }
}
