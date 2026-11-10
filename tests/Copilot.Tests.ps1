# GitHub Copilot chats, read from VS Code's chat files: User/workspaceStorage/<id>/chatSessions/<id>.jsonl
# (and globalStorage/emptyWindowChatSessions), a mutation log replayed in order. The format follows VS Code's
# source (microsoft/vscode 1306698: objectMutationLog.ts, chatSessionOperationLog.ts, chatService.ts) and
# the chat files seen on Windows on 2026-11-01 (docs/research/other-agents.md).
BeforeAll {
  . (Join-Path $PSScriptRoot 'Import-Ctop.ps1')
  function J($o) { ConvertTo-Json -InputObject $o -Depth 20 -Compress }
  function Now-Ms([int]$minutesAgo = 0) { [DateTimeOffset]::UtcNow.AddMinutes(-$minutesAgo).ToUnixTimeMilliseconds() }
  function New-Request([string]$id, [string]$text, [int]$state = 0, [hashtable]$more = @{}) {
    $r = [ordered]@{ requestId = $id; timestamp = (Now-Ms); message = @{ text = $text; parts = @() }; modelId = 'anthropic/Anthropic/claude-haiku-4-5-20251001'
                     response = @(); modelState = @{ value = $state } }
    foreach ($k in $more.Keys) { $r[$k] = $more[$k] }
    $r
  }
  function New-Session([string]$id, $requests = @(), [hashtable]$more = @{}) {
    $s = [ordered]@{ version = 3; sessionId = $id; creationDate = (Now-Ms 30); requests = @($requests); responderUsername = 'GitHub Copilot'; initialLocation = 'panel' }
    foreach ($k in $more.Keys) { $s[$k] = $more[$k] }
    $s
  }
  # a chat file: lines of the log, each a hashtable entry
  function Write-Chat([string]$path, [object[]]$entries, [switch]$Append) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    $text = (@($entries | ForEach-Object { J $_ }) -join "`n") + "`n"
    if ($Append) { [IO.File]::AppendAllText($path, $text) } else { [IO.File]::WriteAllText($path, $text) }
  }
  function Reset-Copilot { $script:CopilotFiles = @{}; $script:CopilotFolders = @{}; $script:History = @{}; $script:BranchCache = @{}; $script:FreshIds = [Collections.Generic.HashSet[string]]::new(); $script:KeepMin = 15 }
  function Read-Chat([string]$path) { Read-CopilotChat ([IO.FileInfo]::new($path)) }
  # Build-Rows with no Claude Code sessions: only the Cline and Copilot rows
  function Reset-BuildRows {
    $script:Departed = @{}; $script:KeptGone = @(); $script:Roster = @(); $script:ClineRows = @()
    $script:ShowGone = $true; $script:ShowSubagents = $false
    $script:GoneRows = @{}; $script:AgentRows = @{}; $script:HistoryAt = Get-Date; $script:GoneCheckedAt = Get-Date; $script:GoneBuildMs = 60000
    $script:FreshIds = [Collections.Generic.HashSet[string]]::new(); $script:RefreshIds = [Collections.Generic.HashSet[string]]::new()
  }
}

Describe 'Get-VSCodeUserDirs (where VS Code keeps its user data)' {
  BeforeEach { $saved = @{}; foreach ($n in 'VSCODE_PORTABLE', 'VSCODE_APPDATA', 'XDG_CONFIG_HOME') { $saved[$n] = [Environment]::GetEnvironmentVariable($n); [Environment]::SetEnvironmentVariable($n, $null) } }
  AfterEach { foreach ($n in $saved.Keys) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) } }
  It 'follows VSCODE_PORTABLE first: <portable>/user-data/User' {
    $env:VSCODE_PORTABLE = 'P'; $env:VSCODE_APPDATA = 'A'
    $d = @(Get-VSCodeUserDirs); $d.Count | Should -Be 1
    $d[0].Dir | Should -Be ([IO.Path]::Combine('P', 'user-data', 'User'))
  }
  It 'follows VSCODE_APPDATA: <appdata>/Code/User and <appdata>/Code - Insiders/User' {
    $env:VSCODE_APPDATA = 'A'
    @(Get-VSCodeUserDirs | ForEach-Object { $_.Dir }) | Should -Be @(([IO.Path]::Combine('A', 'Code', 'User')), ([IO.Path]::Combine('A', 'Code - Insiders', 'User')))
  }
  It 'uses XDG_CONFIG_HOME, else ~/.config, on Linux' -Skip:($IsWindows -or $env:OS -eq 'Windows_NT' -or $IsMacOS) {
    $env:XDG_CONFIG_HOME = '/x'
    (@(Get-VSCodeUserDirs))[0].Dir | Should -Be '/x/Code/User'
    $env:XDG_CONFIG_HOME = $null
    (@(Get-VSCodeUserDirs))[0].Dir | Should -Be (Join-Path $HOME '.config/Code/User')
  }
}

Describe 'ConvertFrom-FileUri (workspace.json''s folder)' {
  It 'reads a Windows drive path' { ConvertFrom-FileUri 'file:///c%3A/dev/src/ctop' | Should -Be 'c:\dev\src\ctop' }
  It 'reads a Unix path with escapes' { ConvertFrom-FileUri 'file:///home/u/my%20work' | Should -Be '/home/u/my work' }
  It 'gives nothing for a remote URI' { ConvertFrom-FileUri 'vscode-remote://ssh-remote+box/home/u' | Should -Be '' }
}

Describe 'Read-CopilotChat (replaying the mutation log)' {
  BeforeEach { Reset-Copilot; $dir = Join-Path $TestDrive ([guid]::NewGuid()) }
  It 'rebuilds the session: initial, pushes, sets, deletes' {
    $p = Join-Path $dir 'c1.jsonl'
    Write-Chat $p @(
      @{ kind = 0; v = (New-Session 'c1' @() @{ customTitle = 'old title' }) },
      @{ kind = 2; k = @('requests'); v = @((New-Request 'r1' 'first question' 0)) },
      @{ kind = 1; k = @('requests', 0, 'modelState'); v = @{ value = 1; completedAt = (Now-Ms) } },
      @{ kind = 1; k = @('requests', 0, 'promptTokens'); v = 1000 },
      @{ kind = 1; k = @('requests', 0, 'completionTokens'); v = 50 },
      @{ kind = 1; k = @('requests', 0, 'response'); v = @(@{ value = 'the first answer' }) },
      @{ kind = 3; k = @('customTitle') },
      @{ kind = 1; k = @('customTitle'); v = 'New title' }
    )
    $a = Read-Chat $p
    $a.Title | Should -Be 'New title'
    $a.Turns | Should -Be 1
    $a.ChatState | Should -Be 1
    $a.InTok | Should -Be 1000; $a.OutTok | Should -Be 50
    $a.Last | Should -Be 'the first answer'
    $a.Model | Should -Be 'haiku-4-5-20251001'
    $a.SessionId | Should -Be 'c1'
  }
  It 'cuts the array at i before a push' {
    $p = Join-Path $dir 'c2.jsonl'
    Write-Chat $p @(
      @{ kind = 0; v = (New-Session 'c2' @((New-Request 'a' 'one' 1), (New-Request 'b' 'two' 1), (New-Request 'c' 'three' 1))) },
      @{ kind = 2; k = @('requests'); v = @((New-Request 'd' 'retry of two' 0)); i = 1 }
    )
    $a = Read-Chat $p
    $a.Turns | Should -Be 2
    $a.ChatState | Should -Be 0
    $a.Last | Should -Be 'prompt: retry of two'
  }
  It 'reads only what was appended, and waits for a line still being written' {
    $p = Join-Path $dir 'c3.jsonl'
    Write-Chat $p @(@{ kind = 0; v = (New-Session 'c3' @((New-Request 'a' 'q' 1))) })
    $null = Read-Chat $p
    $off = $script:CopilotFiles[(Get-Item $p).FullName].Offset
    Write-Chat $p @(@{ kind = 2; k = @('requests'); v = @((New-Request 'b' 'second' 0)) }) -Append
    [IO.File]::AppendAllText($p, (J @{ kind = 1; k = @('requests', 1, 'modelState'); v = @{ value = 1 } }).Substring(0, 20))   # half a line
    $a = Read-Chat $p
    $a.Turns | Should -Be 2
    $a.ChatState | Should -Be 0 -Because 'the half-written line is not applied yet'
    $script:CopilotFiles[(Get-Item $p).FullName].Offset | Should -BeGreaterThan $off
    [IO.File]::AppendAllText($p, (J @{ kind = 1; k = @('requests', 1, 'modelState'); v = @{ value = 1 } }).Substring(20) + "`n")
    (Read-Chat $p).ChatState | Should -Be 1
  }
  It 'reads a compacted file (VS Code rewrote it as one new initial entry) from the start' {
    $p = Join-Path $dir 'c4.jsonl'
    Write-Chat $p @(@{ kind = 0; v = (New-Session 'c4' @((New-Request 'a' 'q' 0))) }, @{ kind = 1; k = @('customTitle'); v = ('x' * 500) })
    $null = Read-Chat $p
    Write-Chat $p @(@{ kind = 0; v = (New-Session 'c4' @((New-Request 'a' 'q' 1), (New-Request 'b' 'q2' 1)) @{ customTitle = 'compacted' }) })
    $a = Read-Chat $p
    $a.Turns | Should -Be 2; $a.Title | Should -Be 'compacted'
  }
  It 'reads a larger compacted file whose start did not change from the start, not as an append (Sol, step 3 F2)' {
    # VS Code rewrote the log as one bigger initial entry: the first 256 bytes are the same, and the old
    # offset now points into the middle of that entry
    $p = Join-Path $dir 'c4b.jsonl'
    $t = Now-Ms 30
    $sess = { param($state, $reply) [ordered]@{ version = 3; sessionId = 'c4b'; creationDate = $t; customTitle = ('t' * 300)
                                                requests = @((New-Request 'a' 'question' $state @{ response = @($reply) })) } }
    Write-Chat $p @([ordered]@{ kind = 0; v = (& $sess 0 @()) })
    (Read-Chat $p).ChatState | Should -Be 0
    $old = $script:CopilotFiles[(Get-Item $p).FullName].Offset
    Write-Chat $p @([ordered]@{ kind = 0; v = (& $sess 1 @{ value = ('final answer ' * 200) }) })
    (Get-Item $p).Length | Should -BeGreaterThan $old
    $a = Read-Chat $p
    $a.ChatState | Should -Be 1
    $a.Last | Should -Match '^final answer'
    $script:CopilotFiles[(Get-Item $p).FullName].Failed | Should -BeNullOrEmpty
  }
  It 'reads such a file from the start when its one line has no newline at the end' {
    $p = Join-Path $dir 'c4c.jsonl'
    $t = Now-Ms 30
    $sess = { param($state, $reply) [ordered]@{ version = 3; sessionId = 'c4c'; creationDate = $t; customTitle = ('t' * 300)
                                                requests = @((New-Request 'a' 'question' $state @{ response = @($reply) })) } }
    Write-Chat $p @([ordered]@{ kind = 0; v = (& $sess 0 @()) })
    $null = Read-Chat $p
    [IO.File]::WriteAllText($p, (J ([ordered]@{ kind = 0; v = (& $sess 1 @{ value = 'done now' }) })))
    $a = Read-Chat $p
    $a.ChatState | Should -Be 1
    $a.Last | Should -Be 'done now'
  }
  It 'reads such a file from the start when the old offset lands on a { inside it (Sol, step 3 round 2, F2)' {
    # Sol's boundary case: the replacement has no final newline, and the old offset falls exactly on the
    # opening brace of a nested object, so the tail looks like a line still being written
    $p = Join-Path $dir 'c4d.jsonl'
    $t = Now-Ms 30
    $sess = { param($state, $resp) [ordered]@{ version = 3; sessionId = 'c4d'; creationDate = $t; customTitle = ('t' * 300)
                                               requests = @((New-Request 'a' 'question' $state @{ response = @($resp) })) } }
    Write-Chat $p @([ordered]@{ kind = 0; v = (& $sess 0 @(@{ value = 'partial' })) })
    $null = Read-Chat $p
    $off = [int]$script:CopilotFiles[(Get-Item $p).FullName].Offset
    $text = $null
    for ($k = 0; $k -lt 400 -and -not $text; $k++) {   # pad the first reply until the second one's { is at the old offset
      $cand = J ([ordered]@{ kind = 0; v = (& $sess 1 @(@{ value = ('x' * $k) }, @{ value = 'final answer' })) })
      if ($cand.Length -gt $off -and $cand[$off] -eq '{' -and $cand[$off - 1] -ne "`n") { $text = $cand }
    }
    $text | Should -Not -BeNullOrEmpty -Because 'the test needs a layout with { at the old offset'
    [IO.File]::WriteAllText($p, $text)   # no final newline
    $a = Read-Chat $p
    $a.ChatState | Should -Be 1
    $a.Last | Should -Match 'final answer$'   # the reply's two pieces, joined
    (Read-Chat $p).ChatState | Should -Be 1
  }
  It 'reads a file rewritten to exactly the length read before from the start' {
    $p = Join-Path $dir 'c4e.jsonl'
    $t = Now-Ms 30
    $sess = { param($state, $word) [ordered]@{ version = 3; sessionId = 'c4e'; creationDate = $t; customTitle = ('t' * 300)
                                               requests = @((New-Request 'a' 'question' $state @{ response = @(@{ value = $word }) })) } }
    Write-Chat $p @([ordered]@{ kind = 0; v = (& $sess 0 'aaaa') })
    $null = Read-Chat $p
    $len = (Get-Item $p).Length
    Write-Chat $p @([ordered]@{ kind = 0; v = (& $sess 1 'bbbb') })
    (Get-Item $p).Length | Should -Be $len
    [IO.File]::SetLastWriteTimeUtc($p, [datetime]::UtcNow.AddSeconds(5))
    $a = Read-Chat $p
    $a.ChatState | Should -Be 1
    $a.Last | Should -Be 'bbbb'
  }
  It 'reads a rewrite exactly as long as what was read, followed by an append, from the start (Sol, step 3 round 3, F2)' {
    # Sol's case: the old log is an initial entry plus mutations; VS Code compacts it into one initial entry
    # with its newline, exactly as long as the offset read up to, then appends a line before ctop reads
    # again. The start, the newline before the offset and the appended line all look like an append.
    $p = Join-Path $dir 'c4f.jsonl'
    $t = Now-Ms 30
    $sess = { param($state, $resp, $pad) [ordered]@{ version = 3; sessionId = 'c4f'; creationDate = $t; customTitle = ('t' * 300)
                                                     requests = @((New-Request 'a' 'question' $state @{ response = @($resp); pad = $pad })) } }
    $entries = @([ordered]@{ kind = 0; v = (& $sess 0 @{ value = 'partial' } '') })
    for ($i = 1; $i -le 60; $i++) { $entries += [ordered]@{ kind = 1; k = @('requests', 0, 'completionTokens'); v = $i } }
    Write-Chat $p $entries
    (Read-Chat $p).ChatState | Should -Be 0
    $off = [int]$script:CopilotFiles[(Get-Item $p).FullName].Offset
    $base = (J ([ordered]@{ kind = 0; v = (& $sess 1 @{ value = 'final answer' } '') })).Length
    $line = J ([ordered]@{ kind = 0; v = (& $sess 1 @{ value = 'final answer' } ('p' * ($off - 1 - $base))) })
    ($line.Length + 1) | Should -Be $off -Because 'the rewrite must end exactly at the old offset'
    [IO.File]::WriteAllText($p, $line + "`n" + (J ([ordered]@{ kind = 1; k = @('customTitle'); v = 'renamed' })) + "`n")
    $a = Read-Chat $p
    $a.ChatState | Should -Be 1
    $a.Last | Should -Be 'final answer'
    $a.Title | Should -Be 'renamed'
  }
  It 'keeps the last good read of a broken file, and does not parse that version again' {
    $p = Join-Path $dir 'c5.jsonl'
    Write-Chat $p @(@{ kind = 0; v = (New-Session 'c5' @((New-Request 'a' 'good' 1))) })
    $null = Read-Chat $p
    [IO.File]::AppendAllText($p, '{"kind":1,"k":["requests",0,"mo' + "`n")
    $a = Read-Chat $p
    $a.Turns | Should -Be 1
    Test-ClineFresh $script:CopilotFiles[(Get-Item $p).FullName] (Get-Item $p) | Should -BeTrue
  }
  It 'reads an older whole-session .json file' {
    $p = Join-Path $dir 'c6.json'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    [IO.File]::WriteAllText($p, (J (New-Session 'c6' @((New-Request 'a' 'from json' 1)))))
    (Read-Chat $p).Title | Should -Be 'from json'
  }
  It 'prefers the session''s credits total to the sum of its requests'' credits' {
    $p = Join-Path $dir 'c7.jsonl'
    Write-Chat $p @(@{ kind = 0; v = (New-Session 'c7' @((New-Request 'a' 'q' 1 @{ copilotCredits = 1 }), (New-Request 'b' 'q' 1 @{ copilotCredits = 1; sessionCopilotCredits = 2.5 }))) })
    (Read-Chat $p).Credits | Should -Be 2.5
    Write-Chat $p @(@{ kind = 0; v = (New-Session 'c7' @((New-Request 'a' 'q' 1 @{ copilotCredits = 1 }), (New-Request 'b' 'q' 1 @{ copilotCredits = 0.5 }))) })
    (Read-Chat $p).Credits | Should -Be 1.5
  }
  It 'prices a chat on an API key from its tokens, in dollars, when it used no Copilot credits' {
    $script:Pricing = @(@{ Match = 'opus-5-5'; In = 4; W5 = 5; W1h = 8; Read = 0.2; Out = 20 })   # the built-in table's row
    # the user runs Claude in Copilot on an Anthropic API key: billed per token, not in credits
    $p = Join-Path $dir 'c7b.jsonl'
    Write-Chat $p @(@{ kind = 0; v = (New-Session 'c7b' @((New-Request 'a' 'q' 1 @{ modelId = 'anthropic/claude-opus-5-5'; promptTokens = 1000000; completionTokens = 100000 }))) })
    $a = Read-Chat $p
    $a.Cost | Should -Be 6.0 -Because 'opus-5-5: 1M input at $4 plus 100K output at $20 a million'
    $a.CostFrom | Should -Be 'tokens'
    Format-CopilotCost $a | Should -Match ('^' + [regex]::Escape(('${0:N2}' -f 6)) + " \(tokens at the model's API price, an upper estimate")
  }
  It 'prices a chat that used Copilot credits from the credits, and shows its token price beside them' {
    $script:Pricing = @(@{ Match = 'opus-5-5'; In = 4; W5 = 5; W1h = 8; Read = 0.2; Out = 20 })   # the built-in table's row
    $p = Join-Path $dir 'c7c.jsonl'
    Write-Chat $p @(@{ kind = 0; v = (New-Session 'c7c' @((New-Request 'a' 'q' 1 @{ modelId = 'copilot/claude-opus-5-5'; promptTokens = 1000000; completionTokens = 0; sessionCopilotCredits = 300 }))) })
    $a = Read-Chat $p
    $a.Cost | Should -Be 3.0 -Because '300 credits at $0.01'
    $a.CostFrom | Should -Be 'credits'
    $t = Format-CopilotCost $a
    $t | Should -Match '\(300 Copilot credits at \$0\.01 each\)'
    $t | Should -Match ('its tokens at the API price: ' + [regex]::Escape(('${0:N2}' -f 4)))
  }
  It 'leaves COST empty for a model ctop has no price for and no credits' {
    $p = Join-Path $dir 'c7d.jsonl'
    Write-Chat $p @(@{ kind = 0; v = (New-Session 'c7d' @((New-Request 'a' 'q' 1 @{ modelId = 'copilot/gpt-5.6-sol-gov'; promptTokens = 1000 }))) })
    $a = Read-Chat $p
    $a.Cost | Should -Be 0
    Format-CopilotCost $a | Should -Be 'none recorded'
  }
  It 'takes CTX from contextUsage when the request has it' {
    $p = Join-Path $dir 'c8.jsonl'
    Write-Chat $p @(@{ kind = 0; v = (New-Session 'c8' @((New-Request 'a' 'q' 1 @{ promptTokens = 9000; contextUsage = @{ currentTokens = 42000; tokenLimit = 200000 } }))) })
    $a = Read-Chat $p
    $a.Ctx | Should -Be 42; $a.CtxLimit | Should -Be 200000
  }
  It 'shows the reply''s text whole, not its last piece (an inline file reference splits it)' {
    # seen on the user's machine (2026-11-10): LAST ACTION read "** is a PowerShell", "'s `allow_reuse_ad"
    $p = Join-Path $dir 'c9b.jsonl'
    $resp = @(@{ kind = 'toolInvocationSerialized'; toolId = 'copilot_readFile' }, @{ value = 'Here: **' },
              @{ kind = 'inlineReference'; inlineReference = @{ scheme = 'file'; path = '/c:/dev/src/ctop/ctop.ps1' } },
              @{ value = '** is a PowerShell script.' })
    Write-Chat $p @(@{ kind = 0; v = (New-Session 'c9b' @((New-Request 'a' 'q' 1 @{ response = $resp }))) })
    (Read-Chat $p).Last | Should -Be 'Here: **ctop.ps1** is a PowerShell script.'
  }
  It 'shows a tool call as the last action, and counts tools' {
    $p = Join-Path $dir 'c9.jsonl'
    Write-Chat $p @(@{ kind = 0; v = (New-Session 'c9' @((New-Request 'a' 'q' 1 @{ response = @(@{ value = 'let me look' }, @{ kind = 'toolInvocationSerialized'; toolId = 'copilot_readFile' }) }))) })
    $a = Read-Chat $p
    $a.Last | Should -Be 'tool: copilot_readFile'; $a.Tools | Should -Be 1
  }
  It 'reads a 3 MB session entry (Windows PowerShell 5.1''s JSON reader has limits)' {
    $p = Join-Path $dir 'big.jsonl'
    $big = 'y' * 3MB
    Write-Chat $p @(@{ kind = 0; v = (New-Session 'big' @((New-Request 'a' 'big one' 1 @{ response = @(@{ value = $big }) }))) })
    $a = Read-Chat $p
    $a.Turns | Should -Be 1
    $a.Title | Should -Be 'big one'
  }
}

Describe 'Update-CopilotRoster and New-CopilotRow' {
  BeforeAll {
    Mock Get-GitInfo { @{ Branch = '-'; Worktree = $false; Main = '' } }
    $root = Join-Path $TestDrive 'appdata'
    $user = Join-Path $root 'Code/User'
    $ws = Join-Path $user 'workspaceStorage/ws1'
    New-Item -ItemType Directory -Force -Path $ws | Out-Null
    [IO.File]::WriteAllText((Join-Path $ws 'workspace.json'), '{"folder":"file:///home/u/proj%20a"}')
    function Put([string]$rel, [object[]]$entries, [int]$minutesAgo = 0) {
      $p = Join-Path $user $rel; Write-Chat $p $entries
      [IO.File]::SetLastWriteTime($p, (Get-Date).AddMinutes(-$minutesAgo))
    }
    Put 'workspaceStorage/ws1/chatSessions/aaaaaaaa-working.jsonl' @(@{ kind = 0; v = (New-Session 'aaaaaaaa-working' @((New-Request 'a' 'fix the build' 0))) })
    Put 'workspaceStorage/ws1/chatSessions/bbbbbbbb-asks.jsonl' @(@{ kind = 0; v = (New-Session 'bbbbbbbb-asks' @((New-Request 'a' 'may I?' 4))) })
    Put 'globalStorage/emptyWindowChatSessions/cccccccc-done.jsonl' @(@{ kind = 0; v = (New-Session 'cccccccc-done' @((New-Request 'a' 'hello' 1 @{ sessionCopilotCredits = 150; response = @(@{ value = 'hi there' }) }))) }) 5
    Put 'globalStorage/emptyWindowChatSessions/dddddddd-old.jsonl' @(@{ kind = 0; v = (New-Session 'dddddddd-old' @((New-Request 'a' 'long ago' 1))) }) 180
    Put 'globalStorage/emptyWindowChatSessions/eeeeeeee-stuck.jsonl' @(@{ kind = 0; v = (New-Session 'eeeeeeee-stuck' @((New-Request 'a' 'stuck' 0))) }) 20
    Put 'globalStorage/emptyWindowChatSessions/ffffffff-empty.jsonl' @(@{ kind = 0; v = (New-Session 'ffffffff-empty' @()) })
    $up = { param($p) $p -eq 'Code' }
    $down = { param($p) $false }
  }
  BeforeEach { Reset-Copilot; $env:VSCODE_APPDATA = $root; $savedPortable = $env:VSCODE_PORTABLE; $env:VSCODE_PORTABLE = $null }
  AfterEach { $env:VSCODE_APPDATA = $null; $env:VSCODE_PORTABLE = $savedPortable }
  It 'lists the chats VS Code has open lately as live, with their state' {
    Update-CopilotRoster $up
    $rows = @($script:CopilotRows | ForEach-Object { New-CopilotRow $_ $false })
    $by = @{}; foreach ($r in $rows) { $by[$r._SessionId] = $r }
    $by['aaaaaaaa-working'].STATE | Should -Be 'working'
    $by['aaaaaaaa-working'].VIA | Should -Be 'copilot'
    $by['aaaaaaaa-working'].CWD | Should -Be (Normalize-Path '/home/u/proj a')   # (\home\u\proj a on Windows)
    $by['aaaaaaaa-working'].NAME | Should -Be 'copilot-aaaaaaaa'
    $by['bbbbbbbb-asks'].STATE | Should -Be 'waiting'
    $by['cccccccc-done'].STATE | Should -Be 'idle'
    $by['cccccccc-done'].COST | Should -Be ('${0:N2}' -f 1.5) -Because '150 Copilot credits at $0.01 each'
    $by['cccccccc-done'].'LAST ACTION' | Should -Be 'hi there'
    $by['eeeeeeee-stuck'].STATE | Should -Be 'stalled' -Because 'Pending, and not written for 20 min'
    $by.ContainsKey('dddddddd-old') | Should -BeFalse -Because 'finished, three hours ago, outside the keep window'
    $by.ContainsKey('ffffffff-empty') | Should -BeFalse -Because 'nothing asked yet'
  }
  It 'lists them as gone, from when they were last written, once VS Code is not running' {
    Update-CopilotRoster $down
    $rows = @($script:CopilotRows | ForEach-Object { New-CopilotRow $_ $false })
    $done = $rows | Where-Object { $_._SessionId -eq 'cccccccc-done' }
    $done.STATE | Should -Match '^gone 5m'
    @($rows | Where-Object { -not $_._Gone }).Count | Should -Be 0
    @($rows | Where-Object { $_._SessionId -eq 'eeeeeeee-stuck' }).Count | Should -Be 0 -Because 'written 20 min ago: outside the 15 min keep window'
  }
  It 'reads a little at a time when there is no time to spare, and catches up' {
    Update-CopilotRoster $up 0
    $script:CopilotPending | Should -BeGreaterThan 0
    for ($n = 0; $n -lt 10 -and $script:CopilotPending; $n++) { Update-CopilotRoster $up 0 }
    $script:CopilotPending | Should -Be 0
    @($script:CopilotRows).Count | Should -Be 4
  }
  It 'peeks and gives a contact block, with dollars and the credits behind them, and no resume command' {
    Mock Get-WindowWidth { 140 }
    Update-CopilotRoster $up
    $r = New-CopilotRow (@($script:CopilotRows | Where-Object { $_.Act.SessionId -eq 'cccccccc-done' })[0]) $false
    $text = (@(Build-Peek $r) | ForEach-Object { if ($_ -is [hashtable]) { $_.Text } else { $_ } }) -join "`n"
    $text | Should -Match ([regex]::Escape(('${0:N2}' -f 1.5)) + ' \(150 Copilot credits at \$0\.01 each\)')
    $text | Should -Match 'the chat file says: Complete'
    $text | Should -Not -Match 'claude --resume'
    $c = Format-Contact $r 'box'
    $c | Should -Match '^GitHub Copilot chat \(VS Code\)'
    $c | Should -Not -Match 'claude --resume'
  }
}

Describe 'Update-CopilotRoster: an unanswered chat older than an hour, on a fresh start (Sol, step 3 F3)' {
  BeforeAll {
    Mock Get-GitInfo { @{ Branch = '-'; Worktree = $false; Main = '' } }
    $root = Join-Path $TestDrive 'cold'
    $user = Join-Path $root 'Code/User'
    function Put([string]$name, [object[]]$entries, [int]$minutesAgo) {
      $p = Join-Path $user "globalStorage/emptyWindowChatSessions/$name.jsonl"; Write-Chat $p $entries
      [IO.File]::SetLastWriteTime($p, (Get-Date).AddMinutes(-$minutesAgo))
    }
    Put 'aaaaaaaa-asks' @(@{ kind = 0; v = (New-Session 'aaaaaaaa-asks' @((New-Request 'a' 'may I run it?' 4))) }) 90
    Put 'bbbbbbbb-done' @(@{ kind = 0; v = (New-Session 'bbbbbbbb-done' @((New-Request 'a' 'long ago' 1))) }) 90
    Put 'cccccccc-done' @(@{ kind = 0; v = (New-Session 'cccccccc-done' @((New-Request 'a' 'longer ago' 1))) }) 300
    $up = { param($p) $p -eq 'Code' }
    $down = { param($p) $false }
  }
  BeforeEach { Reset-Copilot; $env:VSCODE_APPDATA = $root; $savedPortable = $env:VSCODE_PORTABLE; $env:VSCODE_PORTABLE = $null }
  AfterEach { $env:VSCODE_APPDATA = $null; $env:VSCODE_PORTABLE = $savedPortable }
  It 'lists it as waiting from the first roster update, and leaves the finished ones out' {
    Update-CopilotRoster $up
    $script:CopilotPending | Should -Be 0
    $rows = @($script:CopilotRows | ForEach-Object { New-CopilotRow $_ $false })
    @($rows | ForEach-Object { $_._SessionId }) | Should -Be @('aaaaaaaa-asks')
    $rows[0].STATE | Should -Be 'waiting'
  }
  It 'finds it within a few calls when there is no time to spare, counting what is left as pending' {
    Update-CopilotRoster $up 0
    $script:CopilotPending | Should -BeGreaterThan 0
    for ($n = 0; $n -lt 5 -and $script:CopilotPending; $n++) { Update-CopilotRoster $up 0 }
    $script:CopilotPending | Should -Be 0
    @($script:CopilotRows | ForEach-Object { $_.Act.SessionId }) | Should -Be @('aaaaaaaa-asks')
  }
  It 'does not read the finished ones again, and keeps only their summary' {
    Update-CopilotRoster $up
    $f = Get-Item (Join-Path $user 'globalStorage/emptyWindowChatSessions/bbbbbbbb-done.jsonl')
    $c = $script:CopilotFiles[$f.FullName]
    $c.Result.ChatState | Should -Be 1
    $c.Session | Should -BeNullOrEmpty -Because 'an old finished chat is not listed: its replayed session is not kept'
    Mock Read-CopilotChat -ParameterFilter { $f.Name -notlike 'aaaaaaaa*' } { throw 'read again' }
    Update-CopilotRoster $up
    Should -Invoke Read-CopilotChat -Times 0 -ParameterFilter { $f.Name -notlike 'aaaaaaaa*' }
    @($script:CopilotRows).Count | Should -Be 1
  }
  It 'does not read old chats while VS Code is not running' {
    Update-CopilotRoster $down
    @($script:CopilotRows).Count | Should -Be 0
    $script:CopilotFiles.Count | Should -Be 0
  }
}

Describe 'Build-Rows: a gone chat''s row follows its chat file once it is read (Sol, step 3 F1)' {
  BeforeAll {
    Mock Get-GitInfo { @{ Branch = '-'; Worktree = $false; Main = '' } }
    $root = Join-Path $TestDrive 'f1'
    $user = Join-Path $root 'Code/User'
    function Put([string]$name, [double]$credits, [string]$reply) {
      $p = Join-Path $user "globalStorage/emptyWindowChatSessions/$name.jsonl"
      Write-Chat $p @(@{ kind = 0; v = (New-Session $name @((New-Request 'a' 'q' 1 @{ sessionCopilotCredits = $credits; response = @(@{ value = $reply }) }))) })
    }
    $down = { param($p) $false }
  }
  BeforeEach { Reset-Copilot; Reset-BuildRows; $env:VSCODE_APPDATA = $root; $savedPortable = $env:VSCODE_PORTABLE; $env:VSCODE_PORTABLE = $null }
  AfterEach { $env:VSCODE_APPDATA = $null; $env:VSCODE_PORTABLE = $savedPortable }
  It 'shows the final reply and credits after a read that had to wait for the budget' {
    foreach ($n in 'aaaaaaaa-one', 'bbbbbbbb-two') { Put $n 2500 'old reply' }
    Update-CopilotRoster $down
    $rows = @(Build-Rows); $rows.Count | Should -Be 2
    @($rows | Where-Object { $_.COST -eq ('${0:N2}' -f 25) }).Count | Should -Be 2
    Start-Sleep -Milliseconds 20
    foreach ($n in 'aaaaaaaa-one', 'bbbbbbbb-two') { Put $n 12500 'final reply' }
    Update-CopilotRoster $down 0        # one chat is read; the other shows its last read, and is pending
    $script:CopilotPending | Should -Be 1
    $null = @(Build-Rows)
    for ($n = 0; $n -lt 5 -and $script:CopilotPending; $n++) { Update-CopilotRoster $down 0 }
    $script:CopilotPending | Should -Be 0
    $rows = @(Build-Rows)
    @($rows | ForEach-Object { $_.'LAST ACTION' }) | Should -Be @('final reply', 'final reply')
    @($rows | ForEach-Object { $_.COST }) | Should -Be @(('${0:N2}' -f 125), ('${0:N2}' -f 125))
  }
  It 'builds an unchanged gone row once, and reuses it' {
    Put 'cccccccc-same' 0.5 'same reply'
    Update-CopilotRoster $down
    $a = @(Build-Rows) | Where-Object { $_._SessionId -eq 'cccccccc-same' }
    Update-CopilotRoster $down
    $b = @(Build-Rows) | Where-Object { $_._SessionId -eq 'cccccccc-same' }
    [object]::ReferenceEquals($a, $b) | Should -BeTrue
  }
}

Describe 'Update-CopilotRoster: unanswered chats are looked for back 7 days, and the catch-up shows its progress (Sol, step 3 round 2, F3)' {
  BeforeAll {
    Mock Get-GitInfo { @{ Branch = '-'; Worktree = $false; Main = '' } }
    $root = Join-Path $TestDrive 'horizon'
    $user = Join-Path $root 'Code/User'
    function Put([string]$name, [int]$state, [double]$daysAgo, [int]$pad = 0) {
      $p = Join-Path $user "globalStorage/emptyWindowChatSessions/$name.jsonl"
      Write-Chat $p @(@{ kind = 0; v = (New-Session $name @((New-Request 'a' ('q' + ('x' * $pad)) $state))) })
      [IO.File]::SetLastWriteTime($p, (Get-Date).AddDays(-$daysAgo))
    }
    Put 'aaaaaaaa-6days' 4 6
    Put 'bbbbbbbb-8days' 4 8
    for ($i = 0; $i -lt 5; $i++) { Put "cccccccc-done$i" 1 (1 + $i / 10) 20000 }
    $up = { param($p) $p -eq 'Code' }
  }
  BeforeEach { Reset-Copilot; $env:VSCODE_APPDATA = $root; $savedPortable = $env:VSCODE_PORTABLE; $env:VSCODE_PORTABLE = $null }
  AfterEach { $env:VSCODE_APPDATA = $null; $env:VSCODE_PORTABLE = $savedPortable }
  It 'lists an unanswered chat from 6 days ago, and does not read one from 8 days ago' {
    Update-CopilotRoster $up ([int]::MaxValue)   # no time limit: on a cold start the budget ran out before the 6-day chat
    @($script:CopilotRows | ForEach-Object { $_.Act.SessionId }) | Should -Be @('aaaaaaaa-6days')
    $f8 = Get-Item (Join-Path $user 'globalStorage/emptyWindowChatSessions/bbbbbbbb-8days.jsonl')
    $script:CopilotFiles.ContainsKey($f8.FullName) | Should -BeFalse -Because 'older than 7 days and outside the keep window: not read'
  }
  It 'lists the 8-day-old one as gone, not live, once the keep window reaches back that far' {
    # seen on the user's machine (2026-11-10, -Keep inf): unanswered chats from 24 to 84 days ago were
    # listed as live (waiting, stalled), though live means written in the last 7 days
    $script:KeepMin = 14 * 1440
    Update-CopilotRoster $up ([int]::MaxValue)
    @($script:CopilotRows | Where-Object { -not $_.GoneAt } | ForEach-Object { $_.Act.SessionId }) | Should -Be @('aaaaaaaa-6days')
    $old = @($script:CopilotRows | Where-Object { $_.Act.SessionId -eq 'bbbbbbbb-8days' })
    $old.Count | Should -Be 1
    (New-CopilotRow $old[0] $false).STATE | Should -Match '^gone 8d'
  }
  It 'counts the megabytes still to read while it catches up, and clears the count when done' {
    Update-CopilotRoster $up 0
    $script:CopilotPending | Should -BeGreaterThan 0
    $s = $script:CopilotScan
    $s.Total | Should -BeGreaterThan 0
    $s.Done | Should -BeLessThan $s.Total
    Format-CopilotScan | Should -Match '^\d+(\.\d)?/\d+(\.\d)?MB'
    for ($n = 0; $n -lt 20 -and $script:CopilotPending; $n++) { Update-CopilotRoster $up 0 }
    $script:CopilotPending | Should -Be 0
    $script:CopilotScan | Should -BeNullOrEmpty
    Format-CopilotScan | Should -Be ''
  }
}

Describe 'Format-CopilotScan (the strip''s copilot cell)' {
  It 'shows MB read of the total, and a time left once there is a rate' {
    $script:CopilotScan = @{ Done = 35MB; Total = 120MB; Started = (Get-Date).AddSeconds(-10) }
    Format-CopilotScan | Should -Be '35/120MB ~24s'
  }
  It 'shows a tenth of a MB below 10 MB, and no time left before any is read' {
    $script:CopilotScan = @{ Done = 0; Total = 3.5MB; Started = (Get-Date) }
    Format-CopilotScan | Should -Be '0/3.5MB'
  }
  It 'shows nothing when nothing is being read' {
    $script:CopilotScan = $null
    Format-CopilotScan | Should -Be ''
  }
}
