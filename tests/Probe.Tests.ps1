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
    ) | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress }) -join "`n") -Raw
    # VS Code: a Copilot chat as a mutation log (kind 0 = whole session, then kind 1 sets)
    $session = @{ version = 3; sessionId = 'c1'; customTitle = "$secret title"; requests = @(
      @{ requestId = 'r1'; modelId = 'copilot/claude-sonnet-4.5'; timestamp = 1793500000000; message = @{ text = "$secret question" }
         response = @(@{ value = "$secret answer" }); promptTokens = 1200; completionTokens = 300; copilotCredits = 1; modelState = @{ value = 1; completedAt = 1793500005000 } }
    ) }
    Put 'vscode/User/workspaceStorage/abc123/chatSessions/c1.jsonl' ((@(
      (@{ kind = 0; v = $session } | ConvertTo-Json -Depth 12 -Compress)
      (@{ kind = 2; k = @('requests'); v = @(@{ requestId = 'r2'; modelId = 'copilot/claude-opus-4.6'; message = @{ text = "$secret second question" } }) } | ConvertTo-Json -Depth 12 -Compress)
      (@{ kind = 1; k = @('requests', 1, 'modelState'); v = @{ value = 0 } } | ConvertTo-Json -Depth 12 -Compress)
    )) -join "`n") -Raw
    # Roo Code: a task in the extension's global storage
    $roo = 'vscode/User/globalStorage/rooveterinaryinc.roo-cline/tasks'
    Put "$roo/_index.json" @{ version = 1; items = @(@{ id = 't1' }) }
    Put "$roo/t1/history_item.json" @{ id = 't1'; number = 1; ts = 1793500000000; task = "$secret task"; tokensIn = 10; tokensOut = 20; totalCost = 0.12; status = 'active'; workspace = "/w/$secret" }
    Put "$roo/t1/ui_messages.json" @(@{ ts = 1; type = 'say'; say = 'text'; text = "$secret said" }, @{ ts = 2; type = 'ask'; ask = 'followup'; text = "$secret asked" })
    # Cline: a session manifest and its messages
    Put 'cline/data/sessions/k1/k1.json' @{ version = 1; session_id = 'k1'; source = 'vscode'; pid = 777; started_at = '2026-11-01T10:00:00Z'; status = 'running'; interactive = $true
                                             provider = 'anthropic'; model = 'claude-sonnet-4-5'; cwd = "/w/$secret"; workspace_root = '/w'; enable_tools = $true; enable_spawn = $false; enable_teams = $false; prompt = "$secret first prompt" }
    Put 'cline/data/sessions/k1/k1.messages.json' @(@{ role = 'user'; content = "$secret msg" })

    $pwsh = (Get-Process -Id $PID).Path
    $onWindows = $IsWindows -or $env:OS -eq 'Windows_NT'
    $outFile = Join-Path $TestDrive 'probe.txt'
    $args1 = @('-NoProfile', '-NonInteractive') + $(if ($onWindows) { @('-ExecutionPolicy', 'Bypass') } else { @() }) +
             @('-File', $probe, '-NoProcesses', '-ClaudeConfigDir', (Join-Path $root 'claude'), '-ClineDir', (Join-Path $root 'cline'),
               '-VSCodeUserDir', (Join-Path $root 'vscode/User'), '-OutFile', $outFile)
    $script:stdout = (& $pwsh @args1 2>&1) -join "`n"
    $script:report = if (Test-Path -LiteralPath $outFile) { [IO.File]::ReadAllText($outFile) } else { '' }
  }
  It 'runs and writes the report it prints' {
    $script:report | Should -Not -BeNullOrEmpty -Because $script:stdout
    $script:report.Trim() | Should -Be ($script:stdout.Trim() -replace "`r", '')
  }
  It 'never prints the content of prompts, replies, titles or paths' {
    $script:report | Should -Not -Match $secret
  }
  It 'reports Claude Code: the registry entry and who wrote the transcript' {
    $script:report | Should -Match 'entrypoint="sdk-ts"\s+status="busy"'
    $script:report | Should -Match 'entrypoint=sdk-ts \(2\)'
  }
  It 'reports a Copilot chat: model ids, the latest state, and the log''s shape' {
    $script:report | Should -Match 'Copilot chats .*: 1'
    $script:report | Should -Match 'modelId="copilot/claude-sonnet-4\.5"'
    $script:report | Should -Match 'modelId values: .*"copilot/claude-opus-4\.6"'
    $script:report | Should -Match 'modelState values set later: 0 \(1\)'
    $script:report | Should -Match 'requests/\*/modelState \(1\)'
  }
  It 'reports a Roo task: status, cost, and whether it is waiting on you' {
    $script:report | Should -Match 'rooveterinaryinc\.roo-cline'
    $script:report | Should -Match 'status="active".*totalCost=0\.12'
    $script:report | Should -Match 'type="ask"\s+ask="followup"'
  }
  It 'reports a Cline session from its manifest, and says when sqlite3 is missing' {
    $script:report | Should -Match 'status="running"\s+source="vscode"\s+pid=777'
    $script:report | Should -Match 'messages\.json: a list of 1'
    $script:report | Should -Match 'sessions\.db: not found'
  }
}
