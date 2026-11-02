# -Snapshot: one frame, as text, to a pipe or a file. No terminal is involved, so these run everywhere,
# Windows included: ctop runs as a process against a fake `claude` (a shell script, or a .cmd on Windows)
# and a scratch config dir. (The tests where `ps` is slow are Linux-only: Integration.Tests.ps1.)
BeforeAll {
  $script:ctop = Join-Path (Split-Path -Parent $PSScriptRoot) 'ctop.ps1'
  $script:onWindows = $IsWindows -or $env:OS -eq 'Windows_NT'

  # a synthetic transcript: prompt, tool call + result, reply, $turns times
  function New-Transcript([string]$path, [string]$sid, [int]$turns) {
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
    [IO.File]::WriteAllLines($path, [string[]]@(for ($i = 0; $i -lt $turns; $i++) { $turn }))
  }
  # Point the fake claude at what it prints: a file (cat / type), or a fixed line (echo).
  function Set-FakeClaude($fx, [string]$printFile, [string]$printLine) {
    if ($script:onWindows) {
      $body = if ($printFile) { "@type `"$printFile`"" } else { "@echo $printLine" }
      [IO.File]::WriteAllText((Join-Path $fx.Bin 'claude.cmd'), "@echo off`r`n$body`r`n")
    } else {
      $f = Join-Path $fx.Bin 'claude'
      $body = if ($printFile) { "cat '$printFile'" } else { "echo '$printLine'" }
      [IO.File]::WriteAllText($f, "#!/bin/sh`n$body`n"); & chmod +x $f
    }
  }
  # A config dir with one live session (pid: this test process) and one closed session per entry of
  # $closedAt, each with a transcript whose write time is its close time. -NoLive: the roster is empty.
  function New-Fixture([string]$root, [DateTimeOffset[]]$closedAt, [int]$Turns = 25, [switch]$NoLive) {
    $cfg = Join-Path $root 'cfg'; $bin = Join-Path $root 'bin'
    New-Item -ItemType Directory -Force -Path $bin, (Join-Path $cfg 'projects/-w') | Out-Null
    $live = @{ pid = $PID; cwd = $root; kind = 'interactive'; startedAt = [DateTimeOffset]::UtcNow.AddHours(-1).ToUnixTimeMilliseconds()
               sessionId = '11111111-1111-4111-8111-111111111111'; name = 'live-one'; status = 'idle' }
    $rosterFile = Join-Path $root 'roster.json'
    [IO.File]::WriteAllText($rosterFile, $(if ($NoLive) { '[]' } else { ConvertTo-Json -InputObject @($live) -Depth 5 -Compress }))
    New-Transcript (Join-Path $cfg "projects/-w/$($live.sessionId).jsonl") $live.sessionId 25
    $log = for ($i = 0; $i -lt $closedAt.Count; $i++) {
      $sid = [guid]::new(('{0:x8}-0000-4000-8000-{1:x12}' -f $i, $i)).ToString()
      $dir = Join-Path $cfg "projects/-w-p$($i % 12)"
      New-Item -ItemType Directory -Force -Path $dir | Out-Null
      $tf = Join-Path $dir "$sid.jsonl"
      New-Transcript $tf $sid $Turns
      [IO.File]::SetLastWriteTimeUtc($tf, $closedAt[$i].UtcDateTime)
      @{ closedAt = $closedAt[$i].ToString('o'); why = 'closed'; name = ('h{0:d3}' -f $i); title = "history $i"
         sessionId = $sid; cwd = "/w/p$($i % 12)"; pid = 50000 + $i; startedAt = 1793400000000; kind = 'interactive' } | ConvertTo-Json -Compress
    }
    $closedLog = Join-Path $root 'closed.jsonl'
    [IO.File]::WriteAllLines($closedLog, [string[]]@($log | Where-Object { $_ }))
    $fx = @{ Cfg = $cfg; Bin = $bin; Log = $closedLog }
    Set-FakeClaude $fx $rosterFile ''
    return $fx
  }
  # ctop -Snapshot as a process, input from nothing, output to pipes: exit code, stdout, stderr (bounded)
  function Invoke-Snapshot($fx, [string[]]$more) {
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = (Get-Process -Id $PID).Path
    $quoted = @(foreach ($a in @('-ClosedLog', $fx.Log, '-Snapshot') + @($more)) { if ($a -match '\s') { '"' + $a + '"' } else { $a } })
    $psi.Arguments = '-NoProfile -NonInteractive ' + $(if ($script:onWindows) { '-ExecutionPolicy Bypass ' }) + "-File `"$($script:ctop)`" " + ($quoted -join ' ')
    $psi.UseShellExecute = $false; $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $psi.EnvironmentVariables['CLAUDE_CONFIG_DIR'] = $fx.Cfg
    $psi.EnvironmentVariables['CLINE_SESSION_DATA_DIR'] = if ($fx.Cline) { $fx.Cline } else { Join-Path $fx.Cfg 'no-cline' }   # not this machine's Cline
    $psi.EnvironmentVariables['VSCODE_APPDATA'] = if ($fx.VSCode) { $fx.VSCode } else { Join-Path $fx.Cfg 'no-vscode' }      # nor its VS Code chats
    $psi.EnvironmentVariables['VSCODE_PORTABLE'] = ''
    $psi.EnvironmentVariables['PATH'] = if ($fx.NoClaude) { $script:pathWithoutClaude } else { $fx.Bin + [IO.Path]::PathSeparator + $env:PATH }
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEndAsync(); $err = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit(60000)) { try { $p.Kill() } catch {}; throw "ctop -Snapshot $($more -join ' ') did not exit within 60 s" }
    $p.WaitForExit()
    @{ Code = $p.ExitCode; Text = $out.Result; Err = $err.Result }
  }
  # this PATH, less every folder holding a claude command (a real one may be installed where tests run)
  $script:pathWithoutClaude = @(foreach ($folder in ($env:PATH -split [IO.Path]::PathSeparator)) {
      if (-not $folder) { continue }
      $has = $false; foreach ($n in 'claude', 'claude.exe', 'claude.cmd') { if (Test-Path -LiteralPath (Join-Path $folder $n)) { $has = $true } }
      if (-not $has) { $folder }
    }) -join [IO.Path]::PathSeparator
  # cells on screen, for plain text (East Asian wide characters count two)
  function Get-CellWidthForTest([string]$t) { $t.Length + [regex]::Matches($t, '[ᄀ-ᅟ⺀-꓏가-힣豈-﫿＀-｠￠-￦]').Count }
}

Describe 'a snapshot (-Snapshot)' {
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
    $x.Text | Should -Not -Match "[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]" -Because 'plain text: no colors, no cursor movement'
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
  It 'prices with -PricingFile instead of the built-in table' {
    # the live session's 25 turns of claude-sonnet-5-5 cost $0.32 at the built-in rates (worked out by hand
    # in Integration.Tests.ps1, 'tree cost of a session that leaves'); every rate doubled, $0.64
    $fx = New-Fixture (Join-Path $TestDrive 'snap-price') @()
    $prices = Join-Path $TestDrive 'prices.json'
    [IO.File]::WriteAllText($prices, '[{"Match":"sonnet-5-5","In":4,"W5":5,"W1h":8,"Read":0.2,"Out":20}]')
    $base = Invoke-Snapshot $fx @('-MaxWidth', '400')
    $base.Text | Should -Match '(?m)^live-one .*\$0\.32\b' -Because $base.Err
    $x = Invoke-Snapshot $fx @('-MaxWidth', '400', '-PricingFile', $prices)
    $x.Code | Should -Be 0 -Because $x.Err
    $x.Text | Should -Match '(?m)^live-one .*\$0\.64\b'
  }
  It 'stops at once with exit 2 and the reason when the pricing file is wrong' {
    $fx = New-Fixture (Join-Path $TestDrive 'snap-badprice') @()
    $prices = Join-Path $TestDrive 'bad-prices.json'
    [IO.File]::WriteAllText($prices, '[{"Match":"sonnet-","In":1,"W5":1,"W1h":1,"Out":1}]')
    $x = Invoke-Snapshot $fx @('-PricingFile', $prices)
    $x.Code | Should -Be 2
    $x.Err | Should -Match '-PricingFile: pricing file entry 1: Read'
  }
  It 'lists the sessions in Claude Code''s registry when there is no claude command, with what each runs in' {
    # VS Code alone: its Claude agent writes <config>/sessions/<pid>.json; there is no claude to ask
    $fx = New-Fixture (Join-Path $TestDrive 'snap-noclaude') @() -NoLive
    $fx.NoClaude = $true
    $reg = Join-Path $fx.Cfg 'sessions'; New-Item -ItemType Directory -Force -Path $reg | Out-Null
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    [IO.File]::WriteAllText((Join-Path $reg "$PID.json"), ('{"pid":' + $PID + ',"sessionId":"11111111-1111-4111-8111-111111111111","name":"live-one","kind":"interactive","entrypoint":"sdk-ts","cwd":"/w","status":"waiting","startedAt":' + $now + '}'))
    $x = Invoke-Snapshot $fx @('-MaxWidth', '400')
    $x.Code | Should -Be 0 -Because $x.Err
    $x.Err.Trim() | Should -BeNullOrEmpty
    $row = @($x.Text -split "`r?`n" | Where-Object { $_ -match '^live-one ' })[0]
    $row | Should -Not -BeNullOrEmpty -Because $x.Text
    $row | Should -Match '\bwaiting\b' -Because 'its status comes from the registry'
    $row | Should -Match '\bsdk\b' -Because 'VIA: the Claude Agent SDK (entrypoint sdk-ts)'
  }
  It 'says there are no sessions when there is no claude command and no registry, and still exits 0' {
    $fx = New-Fixture (Join-Path $TestDrive 'snap-noclaude-empty') @() -NoLive
    $fx.NoClaude = $true
    $x = Invoke-Snapshot $fx @()
    $x.Code | Should -Be 0 -Because $x.Err
    $x.Text | Should -Match 'no Claude Code sessions running'
    $x.Text | Should -Not -Match "claude agents --json' failed"
  }
  It 'lists a Cline session, read from its manifest and messages file, with no claude command' {
    # VS Code with only Cline: <sessions>/<id>/<id>.json, its pid the window's extension host (here: this
    # process, which started before the session did: a later start would mean the pid was reused)
    $fx = New-Fixture (Join-Path $TestDrive 'snap-cline') @() -NoLive
    $fx.NoClaude = $true
    $fx.Cline = Join-Path $fx.Cfg 'cline-sessions'
    $id = '1793562129035_phf3k'; $dir = Join-Path $fx.Cline $id; New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $began = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $manifest = [ordered]@{ version = 1; session_id = $id; source = 'vscode'; pid = $PID; started_at = $began; status = 'running'; interactive = $true
                            provider = 'anthropic'; model = 'claude-sonnet-5'; cwd = '/w'; workspace_root = '/w'; enable_tools = $true; enable_spawn = $false
                            enable_teams = $false; prompt = 'tidy the logs'; messages_path = (Join-Path $dir "$id.messages.json") }
    [IO.File]::WriteAllText((Join-Path $dir "$id.json"), ($manifest | ConvertTo-Json))
    $msgs = [ordered]@{ version = 1; updated_at = $began; agent = 'lead'; sessionId = $id; messages = @(
        [ordered]@{ role = 'user'; content = @(@{ type = 'text'; text = 'tidy the logs' }) },
        [ordered]@{ role = 'assistant'; content = @(@{ type = 'tool_use'; id = 't1'; name = 'execute_command'; input = @{ command = 'ls logs' } })
                    modelInfo = @{ id = 'claude-sonnet-5'; provider = 'anthropic' }; metrics = @{ inputTokens = 900; outputTokens = 50; cacheReadTokens = 41000; cacheWriteTokens = 100; cost = 1.23 } }) }
    [IO.File]::WriteAllText((Join-Path $dir "$id.messages.json"), ($msgs | ConvertTo-Json -Depth 10))
    $x = Invoke-Snapshot $fx @('-MaxWidth', '400')
    $x.Code | Should -Be 0 -Because $x.Err
    $x.Err.Trim() | Should -BeNullOrEmpty
    $row = @($x.Text -split "`r?`n" | Where-Object { $_ -match '^cline-phf3k ' })[0]
    $row | Should -Not -BeNullOrEmpty -Because $x.Text
    $row | Should -Match '\bworking\b' -Because 'Cline says running, and the newest message is a tool call'
    $row | Should -Match '\bcline\b' -Because 'VIA'
    $row | Should -Match '\$1\.23' -Because 'the cost Cline recorded'
    $row | Should -Match '\b42K\b' -Because 'CTX: 900 + 41000 + 100'
    $row | Should -Match 'execute_command: ls logs'
  }
  It 'reads every Cline session''s conversation before it prints, however many there are (Sol, PR #3/#4 finding 4)' {
    # the per-frame read limit is for the live display; a snapshot prints one frame and exits
    $fx = New-Fixture (Join-Path $TestDrive 'snap-cline-many') @() -NoLive
    $fx.NoClaude = $true
    $fx.Cline = Join-Path $fx.Cfg 'cline-many'
    $filler = 'x' * 2000
    $replies = @(for ($k = 0; $k -lt 40; $k++) { [ordered]@{ role = 'assistant'; content = @(@{ type = 'text'; text = $filler }); metrics = @{ inputTokens = 1; cost = 0.01 } } })
    $msgText = [ordered]@{ version = 1; messages = $replies } | ConvertTo-Json -Depth 8
    $ended = [DateTime]::UtcNow.AddMinutes(-5).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    for ($n = 0; $n -lt 80; $n++) {
      $id = '17936{0:d8}_m{0:d4}' -f $n; $dir = Join-Path $fx.Cline $id; New-Item -ItemType Directory -Force -Path $dir | Out-Null
      $m = [ordered]@{ version = 1; session_id = $id; source = 'vscode'; pid = 1; started_at = $ended; ended_at = $ended; status = 'completed'; exit_code = 0
                       interactive = $true; provider = 'anthropic'; model = 'claude-sonnet-5'; cwd = '/w'; workspace_root = '/w'; enable_tools = $true
                       enable_spawn = $false; enable_teams = $false; messages_path = (Join-Path $dir "$id.messages.json") }
      [IO.File]::WriteAllText((Join-Path $dir "$id.json"), ($m | ConvertTo-Json))
      [IO.File]::WriteAllText((Join-Path $dir "$id.messages.json"), $msgText)
    }
    $x = Invoke-Snapshot $fx @('-MaxWidth', '400', '-Keep', 'inf')
    $x.Code | Should -Be 0 -Because $x.Err
    $rows = @($x.Text -split "`r?`n" | Where-Object { $_ -match '^cline-m\d{4} ' })
    $rows.Count | Should -Be 80
    @($rows | Where-Object { $_ -match '\$0\.40' }).Count | Should -Be 80 -Because 'every row''s cost is read: 40 replies at $0.01'
  }
  It 'lists a Copilot chat from VS Code''s chat files, with no claude command' {
    $fx = New-Fixture (Join-Path $TestDrive 'snap-copilot') @() -NoLive
    $fx.NoClaude = $true
    $fx.VSCode = Join-Path $fx.Cfg 'vscode-appdata'
    $dir = Join-Path $fx.VSCode 'Code/User/globalStorage/emptyWindowChatSessions'; New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $session = [ordered]@{ version = 3; sessionId = '4033627a-32bb-4f5e-a0dc-930c8e19319a'; creationDate = $ms; customTitle = 'Explain the build'; requests = @() }
    $req = [ordered]@{ requestId = 'r1'; timestamp = $ms; message = @{ text = 'explain it' }; modelId = 'anthropic/Anthropic/claude-haiku-4-5-20251001'; modelState = @{ value = 1; completedAt = $ms }
                       promptTokens = 28971; completionTokens = 112; sessionCopilotCredits = 2; response = @(@{ value = 'It builds in three steps.' }) }
    $log = @((@{ kind = 0; v = $session } | ConvertTo-Json -Depth 10 -Compress), (@{ kind = 2; k = @('requests'); v = @($req) } | ConvertTo-Json -Depth 10 -Compress)) -join "`n"
    [IO.File]::WriteAllText((Join-Path $dir '4033627a-32bb-4f5e-a0dc-930c8e19319a.jsonl'), $log + "`n")
    $x = Invoke-Snapshot $fx @('-MaxWidth', '400', '-Keep', 'inf')
    $x.Code | Should -Be 0 -Because $x.Err
    $row = @($x.Text -split "`r?`n" | Where-Object { $_ -match '^copilot-4033627a ' })[0]
    $row | Should -Not -BeNullOrEmpty -Because $x.Text
    $row | Should -Match '\bcopilot\b' -Because 'VIA'
    $row | Should -Match 'Explain the build'
    $row | Should -Match '\b2cr\b' -Because 'Copilot credits, not dollars'
    $row | Should -Match 'haiku-4-5-20251001'
    $row | Should -Match 'It builds in three steps\.'
  }
  It 'says why when the roster cannot be read, and still exits' {
    $fx = New-Fixture (Join-Path $TestDrive 'snap-bad') @() -NoLive
    Set-FakeClaude $fx '' 'not-json'
    $x = Invoke-Snapshot $fx @()
    $x.Text | Should -Match "claude agents --json' failed"
    $x.Code | Should -Be 0
  }
}
