# End to end: the real ctop.ps1 in a terminal (tmux), against a fake `claude` that prints a fixed roster
# and a scratch config dir holding synthetic transcripts and a long closed-sessions history.
# Needs tmux (Linux / macOS). Run alone with:  Invoke-Pester ./tests -TagFilter Integration
BeforeDiscovery { $script:noTmux = -not (Get-Command tmux -ErrorAction SilentlyContinue) -or $IsWindows }

Describe 'ctop under a long history' -Tag Integration -Skip:$script:noTmux {
  BeforeAll {
    $script:ctop = Join-Path (Split-Path -Parent $PSScriptRoot) 'ctop.ps1'
    $script:pwsh = (Get-Process -Id $PID).Path
    $root = Join-Path $TestDrive 'h'
    $script:cfg = $cfg = Join-Path $root 'cfg'
    $bin = Join-Path $root 'bin'
    New-Item -ItemType Directory -Force -Path $bin, (Join-Path $cfg 'projects/-w') | Out-Null

    # one live session (pid: this test process, so the OS columns resolve)
    $live = @{ pid = $PID; cwd = $root; kind = 'interactive'; startedAt = [DateTimeOffset]::UtcNow.AddHours(-1).ToUnixTimeMilliseconds()
               sessionId = '11111111-1111-4111-8111-111111111111'; name = 'live-one'; status = 'idle' }
    $rosterFile = Join-Path $root 'roster.json'
    ConvertTo-Json -InputObject @($live) -Depth 5 | Set-Content -LiteralPath $rosterFile
    $fake = Join-Path $bin 'claude'
    Set-Content -LiteralPath $fake -Value "#!/bin/sh`ncat '$rosterFile'"
    & chmod +x $fake

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
    New-Transcript (Join-Path $cfg "projects/-w/$($live.sessionId).jsonl") $live.sessionId

    # 300 closed sessions over the last 30 days, each with its transcript still on disk
    $rand = [Random]::new(7)
    $now = [DateTimeOffset]::UtcNow
    $script:closedLog = Join-Path $root 'closed.jsonl'
    $log = for ($i = 0; $i -lt 300; $i++) {
      $sid = [guid]::new(('{0:x8}-0000-4000-8000-{1:x12}' -f $i, $i)).ToString()
      $dir = Join-Path $cfg "projects/-w-p$($i % 12)"
      New-Item -ItemType Directory -Force -Path $dir | Out-Null
      $closedAt = $now.AddMinutes(-1 - $rand.NextDouble() * 30 * 1440)
      $tf = Join-Path $dir "$sid.jsonl"
      New-Transcript $tf $sid
      # a transcript stops changing when its session closes: IDLE then reads minutes or more, like real
      # history (written seconds ago, all 300 rows' IDLE would tick every second and re-render them all)
      [IO.File]::SetLastWriteTimeUtc($tf, $closedAt.UtcDateTime)
      @{ closedAt = $closedAt.ToString('o'); why = 'closed'; name = ('h{0:d3}' -f $i); title = "history $i"
         sessionId = $sid; cwd = "/w/p$($i % 12)"; pid = 50000 + $i; startedAt = 1793400000000; kind = 'interactive' } | ConvertTo-Json -Compress
    }
    [IO.File]::WriteAllLines($script:closedLog, [string[]]$log)

    $script:env = "CLAUDE_CONFIG_DIR='$cfg' PATH='${bin}:$env:PATH'"
    $script:n = 0
    function Start-Ctop([string]$ctopArgs) {
      $script:n++
      $s = "ctop-it-$PID-$($script:n)"
      $cmd = "$($script:env) '$($script:pwsh)' -NoProfile -File '$($script:ctop)' -ClosedLog '$($script:closedLog)' -NoColor $ctopArgs; echo CTOP-EXITED; sleep 60"
      & tmux new-session -d -s $s -x 200 -y 50 $cmd
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
  }

  It 'shows the live session within 2 s of starting, while the history is still loading (cold cache)' {
    Remove-Item -LiteralPath (Join-Path $cfg 'ctop-scancache.json') -ErrorAction SilentlyContinue
    # baseline: what starting pwsh and parsing ctop.ps1 costs on this machine
    $sw = [Diagnostics.Stopwatch]::StartNew(); & $script:pwsh -NoProfile -File $script:ctop -Version | Out-Null; $base = $sw.Elapsed.TotalSeconds
    $sw.Restart()
    $s = Start-Ctop '-Keep inf'
    try {
      Wait-Screen $s 'live-one' 60 | Should -Not -BeNullOrEmpty
      $took = $sw.Elapsed.TotalSeconds
      Write-Host ("    pwsh start {0:N1} s, live session shown after {1:N1} s" -f $base, $took)
      $took | Should -BeLessThan ($base + 2)
    } finally { Stop-Ctop $s }
  }

  It 'lists the whole history at keep ∞' {
    $s = Start-Ctop '-Keep inf'
    try {
      Wait-Screen $s 'live-one' 60 | Should -Not -BeNullOrEmpty
      Wait-Screen $s 'gone 300' 30 | Should -Not -BeNullOrEmpty
    } finally { Stop-Ctop $s }
  }

  It 'quits on q within 2 s with 300 gone rows listed' {
    $s = Start-Ctop '-Keep inf'
    try {
      Wait-Screen $s 'gone 300' 60 | Should -Not -BeNullOrEmpty
      Start-Sleep -Seconds 3   # past the first scans: steady state
      & tmux send-keys -t $s q
      Wait-Screen $s 'CTOP-EXITED' 2 | Should -Not -BeNullOrEmpty
    } finally { Stop-Ctop $s }
  }

  It 'applies every one of five quick + presses' {
    $s = Start-Ctop '-Keep 0'
    try {
      Wait-Screen $s 'live-one' 60 | Should -Not -BeNullOrEmpty
      & tmux send-keys -t $s + + + + +   # 0 → 15m → 30m → 45m → 1h → 2h
      Wait-Screen $s 'keep 2h ' 5 | Should -Not -BeNullOrEmpty
      Start-Sleep -Milliseconds 800
      (Get-Screen $s) | Should -Match 'keep 2h '   # and not past it
    } finally { Stop-Ctop $s }
  }

  It 'applies every one of five quick - presses under full load (300 gone rows)' {
    $s = Start-Ctop '-Keep inf'
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
    $s = Start-Ctop '-Keep inf'
    try {
      Wait-Screen $s 'gone 300' 60 | Should -Not -BeNullOrEmpty
      Start-Sleep -Seconds 10   # past warm-up (first scans, first full render)
      $ms = for ($i = 0; $i -lt 12; $i++) {
        if ((Get-Screen $s) -match 'frame +(\d+)ms') { [int]$Matches[1] }
        Start-Sleep -Milliseconds 400
      }
      $median = @($ms | Sort-Object)[[math]::Floor(@($ms).Count / 2)]
      Write-Host "    frame ms: $($ms -join ' ')  (median $median)"
      $median | Should -BeLessThan 250
    } finally { Stop-Ctop $s }
  }
}
