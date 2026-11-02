# tools/Probe-AgentSources.ps1: reports the shape of each agent's files, and never their content.
# Fixtures for every source carry a planted secret in each content field; it must not appear.
Describe 'the agent probe' {
  BeforeAll {
    $probe = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools/Probe-AgentSources.ps1'
    $secret = 'SECRET-7f3a'
    $root = Join-Path $TestDrive 'home'
    function Put([string]$rel, $obj, [switch]$Raw) {
      $p = Join-Path $root $rel; New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p) | Out-Null
      $text = if ($Raw) { [string]$obj } else { ConvertTo-Json -InputObject $obj -Depth 12 -Compress }   # -InputObject: a one-item list stays a list
      [IO.File]::WriteAllText($p, $text)
    }
    # Claude Code: a registry entry and a transcript written by the SDK
    Put 'claude/sessions/4242.json' @{ pid = 4242; sessionId = 's1'; kind = 'interactive'; entrypoint = 'sdk-ts'; status = 'busy'; version = '2.1.316'; name = "$secret-name"; cwd = "/w/$secret" }
    Put 'claude/projects/-w/s1.jsonl' ((@(
      @{ type = 'user'; entrypoint = 'sdk-ts'; version = '2.1.316'; userType = 'external'; message = @{ role = 'user'; content = "$secret prompt" } }
      @{ type = 'assistant'; entrypoint = 'sdk-ts'; version = '2.1.316'; message = @{ role = 'assistant'; content = @(@{ type = 'text'; text = "$secret reply" }) } }
      # a tool call whose input has fields named like the line's own metadata (Sol, PR #3/#4 finding 1):
      # no top-level entrypoint, version or userType on this line, so only the nested ones could match
      @{ type = 'assistant'; message = @{ role = 'assistant'; content = @(@{ type = 'tool_use'; name = 'Bash'; input = @{ entrypoint = "$secret-ep"; userType = "$secret-ut"; version = "$secret-v" } }) } }
    ) | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress }) -join "`n") -Raw
    # VS Code: a Copilot chat as a mutation log (kind 0 = whole session, then kind 1 sets)
    $session = @{ version = 3; sessionId = 'c1'; customTitle = "$secret title"; requests = @(
      @{ requestId = 'r1'; modelId = 'copilot/claude-sonnet-4.5'; timestamp = 1793500000000; message = @{ text = "$secret question" }
         response = @(@{ value = "$secret answer" }); promptTokens = 1200; completionTokens = 300; copilotCredits = 1; modelState = @{ value = 1; completedAt = 1793500005000 } }
    ) }
    Put 'vscode/User/workspaceStorage/abc123/chatSessions/c1.jsonl' ((@(
      (@{ kind = 0; v = $session } | ConvertTo-Json -Depth 12 -Compress)
      (@{ kind = 2; k = @('requests'); v = @(@{ requestId = 'r2'; modelId = 'copilot/claude-opus-4.6'; message = @{ text = "$secret second question" }; modelState = @{ value = 0 } }) } | ConvertTo-Json -Depth 12 -Compress)
      (@{ kind = 1; k = @('requests', 1, 'modelState'); v = @{ value = 0 } } | ConvertTo-Json -Depth 12 -Compress)
    )) -join "`n") -Raw
    # Roo Code: a task in the extension's global storage
    $roo = 'vscode/User/globalStorage/rooveterinaryinc.roo-cline/tasks'
    Put "$roo/_index.json" @{ version = 1; items = @(@{ id = 't1' }) }
    Put "$roo/t1/history_item.json" @{ id = 't1'; number = 1; ts = 1793500000000; task = "$secret task"; tokensIn = 10; tokensOut = 20; totalCost = 0.12; status = 'active'; workspace = "/w/$secret" }
    Put "$roo/t1/ui_messages.json" @(@{ ts = 1; type = 'say'; say = 'text'; text = "$secret said" }, @{ ts = 2; type = 'ask'; ask = 'followup'; text = "$secret asked" })
    # Zoo Code (Roo's community fork): the same task layout under its own extension folder
    Put 'vscode/User/globalStorage/zoocodeorganization.zoo-code/tasks/z1/history_item.json' @{ id = 'z1'; number = 1; ts = 1793500000000; task = "$secret zoo task"; tokensIn = 1; tokensOut = 2; totalCost = 0.05; status = 'completed' }
    # Cline: a session manifest and its messages
    Put 'cline/data/sessions/k1/k1.json' @{ version = 1; session_id = 'k1'; source = 'vscode'; pid = 777; started_at = '2026-11-01T10:00:00Z'; status = 'running'; interactive = $true
                                             provider = 'anthropic'; model = 'claude-sonnet-4-5'; cwd = "/w/$secret"; workspace_root = '/w'; enable_tools = $true; enable_spawn = $false; enable_teams = $false; prompt = "$secret first prompt" }
    Put 'cline/data/sessions/k1/k1.messages.json' @{ version = 1; updated_at = '2026-11-01T10:01:00Z'; agent = 'lead'; sessionId = 'k1'; messages = @(
      @{ role = 'user'; content = "$secret msg" },
      @{ role = 'assistant'; ts = 1793500000000; content = @(@{ type = 'text'; text = "$secret reply" }, @{ type = 'tool_use'; id = 't1'; name = 'read_file'; input = @{ path = "/w/$secret" } })
         modelInfo = @{ id = 'claude-sonnet-4-5'; provider = 'anthropic' }; metrics = @{ inputTokens = 10; outputTokens = 2; cacheReadTokens = 300; cacheWriteTokens = 4; cost = 0.01 } }) }

    $pwsh = (Get-Process -Id $PID).Path
    $onWindows = $IsWindows -or $env:OS -eq 'Windows_NT'
    # a cline command whose history lists one session, prompt and title included (they must not show)
    $bin = Join-Path $TestDrive 'bin'; New-Item -ItemType Directory -Force -Path $bin | Out-Null
    $rowsJson = '[{"sessionId":"k1","source":"cli","pid":4321,"status":"idle","provider":"anthropic","model":"claude-opus-5-5","startedAt":"2026-11-01T11:00:00Z","prompt":"' + $secret + ' p","metadata":{"title":"' + $secret + ' t"}}]'
    if ($onWindows) { [IO.File]::WriteAllText((Join-Path $bin 'cline.cmd'), "@echo off`r`necho $rowsJson`r`n") }
    else { $f = Join-Path $bin 'cline'; [IO.File]::WriteAllText($f, "#!/bin/sh`necho '$rowsJson'`n"); & chmod +x $f }
    $oldPath = $env:PATH; $env:PATH = $bin + [IO.Path]::PathSeparator + $env:PATH
    $outFile = Join-Path $TestDrive 'probe.txt'
    $args1 = @('-NoProfile', '-NonInteractive') + $(if ($onWindows) { @('-ExecutionPolicy', 'Bypass') } else { @() }) +
             @('-File', $probe, '-NoProcesses', '-ClaudeConfigDir', (Join-Path $root 'claude'), '-ClineDir', (Join-Path $root 'cline'),
               '-VSCodeUserDir', (Join-Path $root 'vscode/User'), '-OutFile', $outFile)
    try {
      $script:stdout = (& $pwsh @args1 2>&1) -join "`n"
      $script:report = if (Test-Path -LiteralPath $outFile) { [IO.File]::ReadAllText($outFile) } else { '' }
      # watch: start it, change a chat and a Cline manifest while it runs
      $watchOut = Join-Path $TestDrive 'watch.txt'
      $args2 = @($args1 | ForEach-Object { if ($_ -eq $outFile) { $watchOut } else { $_ } }) + @('-WatchSeconds', '8')
      $psi = [Diagnostics.ProcessStartInfo]::new($pwsh); $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
      $psi.Arguments = (@($args2 | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' ')
      $wp = [Diagnostics.Process]::Start($psi); $wo = $wp.StandardOutput.ReadToEndAsync(); $we = $wp.StandardError.ReadToEndAsync()
      $sw = [Diagnostics.Stopwatch]::StartNew()
      while (-not ($wo.IsCompleted) -and -not (Test-Path -LiteralPath $watchOut) -and $sw.Elapsed.TotalSeconds -lt 30) { Start-Sleep -Milliseconds 100 }
      Start-Sleep -Seconds 3
      $chatFile = Join-Path $root 'vscode/User/workspaceStorage/abc123/chatSessions/c1.jsonl'
      [IO.File]::AppendAllText($chatFile, "`n" + (@{ kind = 1; k = @('requests', 1, 'modelState'); v = @{ value = 1; completedAt = 1793500009000 } } | ConvertTo-Json -Depth 8 -Compress))
      # a transcript line written while it watches: top-level entrypoint sdk-ts, and a tool input with its own
      $tline = @{ type = 'assistant'; entrypoint = 'sdk-ts'; message = @{ role = 'assistant'; content = @(@{ type = 'tool_use'; name = 'Bash'; input = @{ entrypoint = "$secret-wep" } }) } } | ConvertTo-Json -Depth 8 -Compress
      [IO.File]::AppendAllText((Join-Path $root 'claude/projects/-w/s1.jsonl'), "`n" + $tline)
      $man = Join-Path $root 'cline/data/sessions/k1/k1.json'
      [IO.File]::WriteAllText($man, ([IO.File]::ReadAllText($man) -replace '"running"', '"idle"'))
      if (-not $wp.WaitForExit(60000)) { $wp.Kill(); throw 'the watch did not end' }
      $script:watch = $wo.Result + $we.Result
    } finally { $env:PATH = $oldPath }
  }
  It 'runs and writes the report it prints' {
    $script:report | Should -Not -BeNullOrEmpty -Because $script:stdout
    ($script:report -replace "`r", '').Trim() | Should -Be ($script:stdout -replace "`r", '').Trim() -Because 'the same report (line endings aside: CRLF on Windows)'
  }
  It 'never prints the content of prompts, replies, titles or paths' {
    $script:report | Should -Not -Match $secret
  }
  It 'reads a transcript line''s own entrypoint, version and userType, never fields of the same name inside a tool''s input' {
    $script:report | Should -Not -Match $secret
    $script:watch | Should -Not -Match $secret
    $script:report | Should -Match 'entrypoint=sdk-ts \(2\)'
    $script:watch | Should -Match 'claude transcript \w+: .*s1\.jsonl.*entrypoint: sdk-ts\s*$|claude transcript \w+: .*s1\.jsonl.*entrypoint: sdk-ts\r?\n'
  }
  It 'reports Claude Code: the registry entry and who wrote the transcript' {
    $script:report | Should -Match 'entrypoint="sdk-ts"\s+status="busy"'
    $script:report | Should -Match 'entrypoint=sdk-ts \(2\)'
  }
  It 'reports a Copilot chat: model ids, the latest state, and the log''s shape' {
    $script:report | Should -Match 'Copilot chats .*: 1'
    $script:report | Should -Match 'modelId="copilot/claude-sonnet-4\.5"'
    $script:report | Should -Match 'modelId values: .*"copilot/claude-opus-4\.6"'
    $script:report | Should -Match 'modelState values set later: 0 Pending \(1\)'
    $script:report | Should -Match 'request added later, modelState: 0 Pending'
    $script:report | Should -Match 'requests/\*/modelState \(1\)'
  }
  It 'names a Copilot reply''s parts by kind and field names, not their text' {
    $script:report | Should -Match 'reply parts: \(no kind\) 1 \(fields: value\)'
  }
  It 'reports a Roo task: status, cost, and whether it is waiting on you' {
    $script:report | Should -Match 'rooveterinaryinc\.roo-cline'
    $script:report | Should -Match 'status="active".*totalCost=0\.12'
    $script:report | Should -Match 'type="ask"\s+ask="followup"'
  }
  It 'reports a Zoo Code task (Roo''s fork, same layout)' {
    $script:report | Should -Match 'zoocodeorganization\.zoo-code'
    $script:report | Should -Match 'status="completed".*totalCost=0\.05'
  }
  It 'reports a Cline session from its manifest, and says when sqlite3 is missing' {
    $script:report | Should -Match 'status="running"\s+source="vscode"\s+pid=777'
    $script:report | Should -Match 'messages\.json: fields agent, messages, sessionId, updated_at, version'
    $script:report | Should -Match 'sessions\.db: not found'
    $script:report | Should -Match 'started_at="?2026-11-01T10:00:00' -Because 'a date, not (object): PowerShell 7 reads ISO strings as dates'
  }
  It 'sums up a Cline messages file by counts and field names, not its text' {
    $script:report | Should -Match 'messages: 2\s+roles: "assistant" 1, "user" 1'
    $script:report | Should -Match 'content blocks: "text" 1, "tool_use" 1, \(plain text\) 1'
    $script:report | Should -Match 'with metrics: 1\s+metrics fields: cacheReadTokens, cacheWriteTokens, cost, inputTokens, outputTokens\s+modelInfo fields: id, provider\s+with ts: 1'
  }
  It 'reads cline history --json when cline is installed, showing status and model, not the prompt or title' {
    $script:report | Should -Match 'cline history --json: 1 rows'
    $script:report | Should -Match 'sessionId="k1"\s+source="cli"\s+pid=4321\s+status="idle"'
  }
  It 'watches: prints each change as it happens, with the request''s new state, and no content' {
    $script:watch | Should -Match 'copilot chat changed: c1\.jsonl'
    $script:watch | Should -Match 'kind 1 requests/\*/modelState\s+modelState=1 Complete'
    $script:watch | Should -Match 'cline manifest changed: k1\.json\s+status="idle"'
    $script:watch | Should -Match 'watch ended'
    $script:watch | Should -Not -Match $secret
  }
}
