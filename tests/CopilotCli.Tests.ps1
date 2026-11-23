# GitHub Copilot CLI sessions, read from $COPILOT_HOME/session-state/<id>/: workspace.yaml and events.jsonl,
# with inuse.<pid>.lock naming the process that has the session open. The shapes follow `copilot help config`
# (CLI 1.0.114) and 130 real sessions seen on Windows on 2026-11-22.
BeforeAll {
  . (Join-Path $PSScriptRoot 'Import-Ctop.ps1')
  function J($o) { ConvertTo-Json -InputObject $o -Depth 20 -Compress }
  function Iso([datetime]$t) { $t.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ') }
  # an event line as the CLI writes it: type first
  function Ev([string]$type, [hashtable]$data, [datetime]$at = (Get-Date)) {
    '{"type":' + (J $type) + ',"data":' + (J $data) + ',"id":"' + [guid]::NewGuid() + '","timestamp":"' + (Iso $at) + '","parentId":null}'
  }
  function Usage([string]$model, [long]$in, [long]$out, [long]$cr = 0, [long]$cw = 0, [hashtable]$more = @{}) {
    $u = @{ model = $model; inputTokens = $in; outputTokens = $out; cacheReadTokens = $cr; cacheWriteTokens = $cw; cost = 0.0; isByok = $true; maxPromptTokens = 128000; cachePolicyTtlSeconds = 300 }
    foreach ($k in $more.Keys) { $u[$k] = $more[$k] }
    Ev 'session.usage_record' @{ usage = $u }
  }
  function Start-Ev([string]$model = 'claude-opus-5-5') { Ev 'session.start' @{ sessionId = 'x'; startTime = (Iso (Get-Date).AddMinutes(-10)); selectedModel = $model; reasoningEffort = 'medium'; context = @{ cwd = 'C:\work'; branch = 'main' } } (Get-Date).AddMinutes(-10) }
  # one session folder; $lines: the event lines (each ends with a newline); $lock: a pid to hold it
  function New-CliSession([string]$root, [string]$id, [string[]]$lines, $lock = $null, [string]$yaml = $null) {
    $dir = Join-Path $root $id; New-Item -ItemType Directory -Force -Path $dir | Out-Null
    if (-not $yaml) { $yaml = "id: $id`ncwd: C:\work`nbranch: main`nclient_name: github/cli`nname: Review the change`ncreated_at: $(Iso (Get-Date).AddMinutes(-10))`n" }
    [IO.File]::WriteAllText((Join-Path $dir 'workspace.yaml'), $yaml)
    if ($lines) { [IO.File]::WriteAllText((Join-Path $dir 'events.jsonl'), (($lines -join "`n") + "`n")) }
    if ($null -ne $lock) { [IO.File]::WriteAllText((Join-Path $dir "inuse.$lock.lock"), "$lock") }
    return $dir
  }
  function Reset-CopilotCli {
    $script:CopilotCliScans = @{}; $script:CopilotCliActs = @{}; $script:CopilotCliYamls = @{}; $script:CopilotCliDirs = @{}; $script:CopilotCliDeadLocks = @{}
    $script:History = @{}; $script:BranchCache = @{}; $script:FreshIds = [Collections.Generic.HashSet[string]]::new(); $script:KeepMin = 60
    $script:PriceVer = 'test'; $script:PriceFrom = 'test table'
    $script:Pricing = @(@{ Match = 'opus-5-5'; In = 4; W5 = 5; W1h = 8; Read = 0.2; Out = 20 })   # the built-in table's row
  }
  function Scan([string]$path) { Get-CopilotCliSummary (Update-CopilotCliScan ([IO.FileInfo]::new($path))) }
  $alive = { param($id) (Get-Date).AddHours(-5) }   # every pid names a process started long ago
  $none = { param($id) $null }                       # no process has any pid
}

Describe 'Get-CopilotCliHome (where the CLI keeps its sessions)' {
  BeforeEach { $saved = [Environment]::GetEnvironmentVariable('COPILOT_HOME'); [Environment]::SetEnvironmentVariable('COPILOT_HOME', $null) }
  AfterEach { [Environment]::SetEnvironmentVariable('COPILOT_HOME', $saved) }
  It 'is ~/.copilot by default' { Get-CopilotCliHome | Should -Be (Join-Path $HOME '.copilot') }
  It 'follows COPILOT_HOME' { $env:COPILOT_HOME = 'X'; Get-CopilotCliHome | Should -Be 'X' }
}

Describe 'Read-CopilotCliYaml' {
  It 'reads plain, quoted and block values, and leaves nested lines alone' {
    $p = Join-Path $TestDrive 'w.yaml'
    [IO.File]::WriteAllText($p, "id: abc`r`ncwd: C:\dev\src\ctop`nname: ""a \""quoted\"" title""`nbranch: 'it''s'`nsummary: |-`n  first line`n  second line`nnested:`n  key: x`nclient_name: github/cli`n")
    $y = Read-CopilotCliYaml $p
    $y.id | Should -Be 'abc'; $y.cwd | Should -Be 'C:\dev\src\ctop'
    $y.name | Should -Be 'a "quoted" title'; $y.branch | Should -Be "it's"
    $y.summary | Should -Be "first line`nsecond line"
    $y.client_name | Should -Be 'github/cli'
    $y.ContainsKey('key') | Should -BeFalse
  }
  It 'gives $null for a file that is not there' { Read-CopilotCliYaml (Join-Path $TestDrive 'nope.yaml') | Should -BeNullOrEmpty }
}

Describe 'Get-CopilotCliModel' {
  It 'drops the provider and claude-' {
    Get-CopilotCliModel 'claude-opus-5-5' | Should -Be 'opus-5-5'
    Get-CopilotCliModel 'Anthropic/claude-sonnet-5-5' | Should -Be 'sonnet-5-5'
    Get-CopilotCliModel 'customendpoint/example (local proxy)/gemini-4-argon' | Should -Be 'gemini-4-argon'
  }
}

Describe 'Update-CopilotCliScan: what a session log says' {
  BeforeEach { Reset-CopilotCli; $dir = Join-Path $TestDrive ([guid]::NewGuid()); New-Item -ItemType Directory -Path $dir | Out-Null; $p = Join-Path $dir 'events.jsonl' }
  It 'is working while a tool runs, thinking while a model call is out, idle after the turn' {
    [IO.File]::WriteAllText($p, ((Start-Ev), (Ev 'user.message' @{ content = 'review the change' }), (Ev 'assistant.turn_start' @{ turnId = '0' }),
      (Ev 'assistant.message' @{ content = ''; toolRequests = @(@{ toolCallId = 't1'; name = 'view' }) }),
      (Ev 'tool.execution_start' @{ toolCallId = 't1'; toolName = 'view'; arguments = @{ path = 'C:\work\a.ps1' } }) -join "`n") + "`n")
    $a = Scan $p
    $a.State | Should -Be 'working'; $a.Last | Should -Be 'view: C:\work\a.ps1'; $a.Turns | Should -Be 1; $a.Tools | Should -Be 1
    [IO.File]::AppendAllText($p, ((Ev 'tool.execution_complete' @{ toolCallId = 't1'; success = $true; result = @{ content = ('x' * 5000) } }), (Ev 'assistant.turn_end' @{ turnId = '0' }), (Ev 'assistant.turn_start' @{ turnId = '1' }) -join "`n") + "`n")
    (Scan $p).State | Should -Be 'thinking'
    [IO.File]::AppendAllText($p, ((Ev 'assistant.message' @{ content = 'VERDICT: APPROVE' }), (Ev 'assistant.turn_end' @{ turnId = '1' }) -join "`n") + "`n")
    $a = Scan $p
    $a.State | Should -Be 'idle'; $a.Last | Should -Be 'VERDICT: APPROVE'
    $a.Model | Should -Be 'opus-5-5'; $a.Effort | Should -Be 'medium'; $a.Cwd | Should -Be 'C:\work'
  }
  It 'is waiting while a permission is asked, thinking right after a prompt' {
    [IO.File]::WriteAllText($p, ((Start-Ev), (Ev 'user.message' @{ content = 'go' }) -join "`n") + "`n")
    (Scan $p).State | Should -Be 'thinking'
    [IO.File]::AppendAllText($p, ((Ev 'assistant.turn_start' @{ turnId = '0' }), (Ev 'tool.execution_start' @{ toolCallId = 't9'; toolName = 'powershell'; arguments = @{ command = 'rm x' } }), (Ev 'permission.requested' @{ requestId = 'r1' }) -join "`n") + "`n")
    (Scan $p).State | Should -Be 'waiting'
    [IO.File]::AppendAllText($p, (Ev 'permission.completed' @{ requestId = 'r1'; result = @{ kind = 'denied' } }) + "`n")
    (Scan $p).State | Should -Be 'working'
  }
  It 'counts your prompts, not autopilot''s continuations or messages from another agent' {
    [IO.File]::WriteAllText($p, ((Start-Ev), (Ev 'user.message' @{ content = 'one'; parentAgentTaskId = 'p1' }), (Ev 'user.message' @{ content = 'go on'; source = 'autopilot'; isAutopilotContinuation = $true }),
      (Ev 'user.message' @{ content = 'done'; source = 'agent-1234' }), (Ev 'user.message' @{ content = 'two' }) -join "`n") + "`n")
    $a = Scan $p
    $a.Turns | Should -Be 2; $a.First | Should -Be 'one'
  }
  It 'prices each call from its tokens: inputTokens holds the cache reads and writes; the cache write at its TTL' {
    [IO.File]::WriteAllText($p, ((Start-Ev),
      (Usage 'claude-opus-5-5' 100000 1000 90000 9000),                                            # fresh 1,000
      (Usage 'claude-opus-5-5' 10000 0 0 10000 @{ cachePolicyTtlSeconds = 3600 }) -join "`n") + "`n")   # a 1-hour write
    $a = Scan $p
    # (1,000 x 4 + 9,000 x 5 + 90,000 x 0.2 + 1,000 x 20) / 1e6 = 0.087; 10,000 x 8 / 1e6 = 0.08
    $a.Cost | Should -BeGreaterThan 0.16699; $a.Cost | Should -BeLessThan 0.16701
    $a.InTok | Should -Be 110000; $a.CacheR | Should -Be 90000; $a.CacheW | Should -Be 19000; $a.Calls | Should -Be 2
    $a.Ctx | Should -Be 10; $a.CtxLimit | Should -Be 128000
  }
  It 'counts calls on a model with no price, and calls Copilot bills, without pricing them' {
    [IO.File]::WriteAllText($p, ((Start-Ev), (Usage 'customendpoint/proxy/gemini-4-argon' 5000 10), (Usage 'claude-opus-5-5' 5000 10 0 0 @{ isByok = $false; cost = 1.0 }) -join "`n") + "`n")
    $a = Scan $p
    $a.Cost | Should -Be 0; $a.Unpriced | Should -Be 1; $a.UnpricedModels | Should -Be 'gemini-4-argon'; $a.Billed | Should -Be 1
    Format-CopilotCliCost $a | Should -Match '^none priced; partial: 1 of 2 model calls on a model with no price \(gemini-4-argon\); 1 of 2 billed by Copilot'
  }
  It 'takes CTX from the session''s own calls, not a subagent''s' {
    [IO.File]::WriteAllText($p, ((Start-Ev), (Usage 'claude-opus-5-5' 50000 10), (Usage 'claude-haiku-5-5' 9000 10 0 0 @{ parentToolCallId = 'task1' }) -join "`n") + "`n")
    $a = Scan $p
    $a.Ctx | Should -Be 50; $a.Model | Should -Be 'opus-5-5'
  }
  It 'reads only whole lines, and the rest once it is written' {
    $line = Ev 'user.message' @{ content = 'half' }
    [IO.File]::WriteAllText($p, (Start-Ev) + "`n" + $line.Substring(0, 20))
    (Scan $p).Turns | Should -Be 0
    [IO.File]::AppendAllText($p, $line.Substring(20) + "`n")
    (Scan $p).Turns | Should -Be 1
  }
  It 'reads a log again from the start when it was replaced' {
    [IO.File]::WriteAllText($p, ((Start-Ev), (Ev 'user.message' @{ content = 'one' }), (Ev 'user.message' @{ content = 'two' }) -join "`n") + "`n")
    (Scan $p).Turns | Should -Be 2
    [IO.File]::WriteAllText($p, ((Start-Ev 'claude-sonnet-5-5'), (Ev 'user.message' @{ content = 'only one, and a longer log than before' }), (Ev 'assistant.message' @{ content = 'and a reply' }) -join "`n") + "`n")
    $a = Scan $p
    $a.Turns | Should -Be 1; $a.Model | Should -Be 'sonnet-5-5'
  }
  It 'records the shutdown, and a resume opens the session again' {
    [IO.File]::WriteAllText($p, ((Start-Ev), (Ev 'user.message' @{ content = 'go' }), (Ev 'session.shutdown' @{ shutdownType = 'routine' }) -join "`n") + "`n")
    $a = Scan $p
    $a.ShutdownAt | Should -Not -BeNullOrEmpty; $a.ShutdownType | Should -Be 'routine'; $a.State | Should -Be 'idle'
    [IO.File]::AppendAllText($p, (Ev 'session.resume' @{ selectedModel = 'claude-opus-5-5' }) + "`n")
    (Scan $p).ShutdownAt | Should -BeNullOrEmpty
  }
  # A resume after an abrupt stop: a prompt, the process killed (no shutdown), then `copilot --resume` with no
  # model call yet must not stay thinking. The resume event as the CLI writes it (CLI 1.0.103, seen 2026-11-22):
  # {"type":"session.resume","data":{"resumeTime":…,
  # "context":{"cwd":…},"eventsFileSizeBytes":…,"eventCount":…,"selectedModel":…,"alreadyInUse":false,"sessionWasActive":false}}
  It 'takes its state from the resumed run: what was pending before a resume is dropped' {
    [IO.File]::WriteAllText($p, ((Start-Ev), (Ev 'user.message' @{ content = 'go' }), (Ev 'permission.requested' @{ requestId = 'r1' }),
      (Ev 'tool.execution_start' @{ toolCallId = 't1'; toolName = 'shell' }), (Ev 'user.message' @{ content = 'and then' }) -join "`n") + "`n")
    (Scan $p).State | Should -Be 'waiting'
    [IO.File]::AppendAllText($p, (Ev 'session.resume' @{ resumeTime = (Iso (Get-Date)); context = @{ cwd = 'C:\work' }; selectedModel = 'claude-opus-5-5'; alreadyInUse = $false; sessionWasActive = $false }) + "`n")
    (Scan $p).State | Should -Be 'idle'
    [IO.File]::AppendAllText($p, (Ev 'user.message' @{ content = 'resumed prompt' }) + "`n")
    (Scan $p).State | Should -Be 'thinking'
  }
  It 'is idle after a prompt, an abrupt stop and a resume with no model call yet' {
    [IO.File]::WriteAllText($p, ((Start-Ev), (Ev 'user.message' @{ content = 'one' }), (Ev 'session.resume' @{ selectedModel = 'claude-opus-5-5' }) -join "`n") + "`n")
    $a = Scan $p
    $a.State | Should -Be 'idle'; $a.Turns | Should -Be 1
  }
  It 'notes that a copilot -p run is headless' {
    [IO.File]::WriteAllText($p, ((Start-Ev), (Ev 'system.message' @{ role = 'system'; content = 'You are the GitHub Copilot CLI. You are running in non-interactive mode and have no way to communicate with the user.' }) -join "`n") + "`n")
    (Scan $p).Headless | Should -BeTrue
  }
}

Describe 'Update-CopilotCliRoster' {
  BeforeAll {
    Mock Get-GitInfo { @{ Branch = ''; Worktree = $false; Main = '' } }
    Reset-CopilotCli
    $root = Join-Path $TestDrive 'home'
    $env:COPILOT_HOME = $root
    $st = Join-Path $root 'session-state'
    $now = Get-Date
    $run = @((Start-Ev), (Ev 'system.message' @{ content = 'You are running in non-interactive mode' }), (Ev 'user.message' @{ content = 'Read the file C:/jobs/q3/prompt.md' }),
             (Ev 'assistant.turn_start' @{ turnId = '0' }), (Ev 'tool.execution_start' @{ toolCallId = 't1'; toolName = 'view'; arguments = @{ path = 'C:/jobs/q3/prompt.md' } }),
             (Usage 'claude-opus-5-5' 20000 100 0 20000))
    New-CliSession $st 'aaaaaaaa-live' $run 4242 | Out-Null
    New-CliSession $st 'bbbbbbbb-done' @((Start-Ev), (Ev 'user.message' @{ content = 'p' }), (Ev 'session.shutdown' @{ shutdownType = 'routine' } $now.AddMinutes(-5))) | Out-Null
    $stale = New-CliSession $st 'cccccccc-dead' @((Start-Ev), (Ev 'user.message' @{ content = 'p' })) 999   # killed: its lock stayed
    [IO.File]::SetLastWriteTime((Join-Path $stale 'inuse.999.lock'), $now.AddHours(-1))
    New-CliSession $st 'dddddddd-old' @((Start-Ev), (Ev 'user.message' @{ content = 'p' }), (Ev 'session.shutdown' @{ shutdownType = 'routine' })) | Out-Null
    [IO.File]::SetLastWriteTime((Join-Path $st 'dddddddd-old/events.jsonl'), $now.AddDays(-3))
    New-CliSession $st 'eeeeeeee-empty' @() 4242 | Out-Null                                              # opened, nothing asked
    New-CliSession $st 'ffffffff-noprompt' @((Start-Ev)) 4242 | Out-Null
    # pid 999 is a process started after its lock was written (an hour ago): not the process that wrote it
    $getStart = { param($id) if ($id -eq 999) { Get-Date } else { (Get-Date).AddHours(-5) } }
    Update-CopilotCliRoster $getStart 60000
    $byId = @{}; foreach ($e in @($script:CopilotCliRows)) { $byId[$e.Id] = $e }
  }
  AfterAll { $env:COPILOT_HOME = $null }
  It 'lists a session held by a live process as live, whatever its KIND' {
    $byId['aaaaaaaa-live'].GoneAt | Should -BeNullOrEmpty
    $byId['aaaaaaaa-live'].Pid | Should -Be 4242
    $byId['aaaaaaaa-live'].Act.Headless | Should -BeTrue
  }
  It 'lists an ended session as gone at its shutdown' {
    $byId['bbbbbbbb-done'].GoneAt.ToString('yyyy-MM-ddTHH:mm') | Should -Be $now.AddMinutes(-5).ToString('yyyy-MM-ddTHH:mm')
  }
  It 'does not take a stale lock''s reused pid for the session''s process' {
    $byId['cccccccc-dead'].GoneAt | Should -Not -BeNullOrEmpty
    $byId['cccccccc-dead'].Pid | Should -BeNullOrEmpty
  }
  It 'leaves out a session that ended before the keep window, and one nothing was asked in' {
    $byId.ContainsKey('dddddddd-old') | Should -BeFalse
    $byId.ContainsKey('eeeeeeee-empty') | Should -BeFalse
    $byId.ContainsKey('ffffffff-noprompt') | Should -BeFalse
  }
  It 'makes rows: VIA copilot-cli, KIND headless, the title from workspace.yaml, the cost from its tokens' {
    $r = New-CopilotCliRow $byId['aaaaaaaa-live'] $false
    $r.NAME | Should -Be 'cpcli-aaaaaaaa'; $r.VIA | Should -Be 'copilot-cli'; $r.KIND | Should -Be 'headless'
    $r.STATE | Should -Be 'working'; $r.PID | Should -Be 4242; $r.TITLE | Should -Be 'Review the change'
    $r.'LAST ACTION' | Should -Be 'view: C:/jobs/q3/prompt.md'
    $r.COST | Should -Be '$0.10'   # 20,000 written x $5 + 100 out x $20, per million
    $r.CTX | Should -Be '20K'; $r.MODEL | Should -Be 'opus-5-5'; $r._Agent | Should -Be 'copilot-cli'
    (New-CopilotCliRow $byId['bbbbbbbb-done'] $false).STATE | Should -Match '^gone '
  }
  It 'peeks, and gives a contact block with the CLI''s resume command, not Claude Code''s' {
    Mock Get-WindowWidth { 120 }
    $r = New-CopilotCliRow $byId['bbbbbbbb-done'] $false
    $text = (@(Build-Peek $r) | ForEach-Object { if ($_ -is [hashtable]) { $_.Text } else { $_ } }) -join "`n"
    $text | Should -Match 'a GitHub Copilot CLI session run by the copilot command'
    $text | Should -Match 'ENDED .*\(routine\)'
    $text | Should -Not -Match 'claude --resume'
    $c = Format-Contact $r 'box'
    $c | Should -Match '^GitHub Copilot CLI session \(the copilot command\)'
    $c | Should -Match 'copilot --resume bbbbbbbb-done'
    $c | Should -Not -Match 'claude --resume'
  }
  It 'with keep 0, lists only the live session' {
    $script:KeepMin = 0
    try { Update-CopilotCliRoster $getStart 60000; @($script:CopilotCliRows | ForEach-Object { $_.Id }) | Should -Be @('aaaaaaaa-live') }
    finally { $script:KeepMin = 60 }
  }
  It 'sees a session end: its lock let go, its log ending in a shutdown' {
    $d = Join-Path $st 'aaaaaaaa-live'
    Remove-Item (Join-Path $d 'inuse.4242.lock')
    [IO.File]::AppendAllText((Join-Path $d 'events.jsonl'), (Ev 'session.shutdown' @{ shutdownType = 'routine' }) + "`n")
    Update-CopilotCliRoster $getStart 60000
    $e = @($script:CopilotCliRows | Where-Object { $_.Id -eq 'aaaaaaaa-live' })[0]
    $e.GoneAt | Should -Not -BeNullOrEmpty
    $e.Act.State | Should -Be 'idle'
  }
}

# A copilot process has a readable start time on Windows, Linux and macOS, so a pid whose start time can't be
# read is not shown to be the lock's owner.
Describe 'Get-CopilotCliOwner: a process whose start time cannot be read' {
  BeforeEach { Reset-CopilotCli; $lf = Join-Path $TestDrive 'inuse.4242.lock'; [IO.File]::WriteAllText($lf, '4242') }
  It 'is not the owner' {
    Get-CopilotCliOwner @([IO.FileInfo]::new($lf)) { param($id) 'unknown' } | Should -BeNullOrEmpty
  }
  It 'is the owner when its start time is read and is before the lock' {
    Get-CopilotCliOwner @([IO.FileInfo]::new($lf)) { param($id) (Get-Date).AddHours(-1) } | Should -Be 4242
  }
  It 'leaves Test-ProcessSince taking an unreadable start time as live for its other callers (a Claude Code registry entry, a Cline session)' {
    Test-ProcessSince 4242 (Get-Date) { param($id) 'unknown' } | Should -BeTrue
    Test-ProcessSince 4242 (Get-Date) { param($id) 'unknown' } -Verified | Should -BeFalse
  }
}

# While events.jsonl is held exclusively, its row must come back once the file is let go: the roster must not
# record the new length as read.
Describe 'Update-CopilotCliRoster: a log that cannot be read for a moment' {
  BeforeEach {
    Reset-CopilotCli
    $root = Join-Path $TestDrive ([guid]::NewGuid()); $env:COPILOT_HOME = $root
    $dir = New-CliSession (Join-Path $root 'session-state') 'locked01' @((Start-Ev), (Ev 'user.message' @{ content = 'one' }))
    $p = Join-Path $dir 'events.jsonl'
    # whether this platform keeps a shared reader out of a file held with FileShare.None
    $probe = [IO.File]::Open($p, 'Open', 'ReadWrite', 'None')
    $enforced = $false; try { (Open-Shared $p).Dispose() } catch { $enforced = $true } finally { $probe.Dispose() }
  }
  AfterAll { $env:COPILOT_HOME = $null }
  It 'keeps the last read while the log is held, does not count it as read, and reads it once it is let go' {
    if (-not $enforced) { Set-ItResult -Skipped -Because 'this platform does not keep a reader out of a file held with FileShare.None'; return }
    Update-CopilotCliRoster $none 60000
    @($script:CopilotCliRows)[0].Act.Turns | Should -Be 1
    $before = $script:CopilotCliActs[$p].Length
    [IO.File]::AppendAllText($p, (Ev 'user.message' @{ content = 'two' }) + "`n")
    $fs = [IO.File]::Open($p, 'Open', 'ReadWrite', 'None')
    try {
      Update-CopilotCliRoster $none 60000
      @($script:CopilotCliRows).Count | Should -Be 1
      @($script:CopilotCliRows)[0].Act.Turns | Should -Be 1
      $script:CopilotCliActs[$p].Length | Should -Be $before
      Update-CopilotCliRoster $none 60000   # still held: still the last read
      @($script:CopilotCliRows)[0].Act.Turns | Should -Be 1
    } finally { $fs.Dispose() }
    Update-CopilotCliRoster $none 60000
    @($script:CopilotCliRows)[0].Act.Turns | Should -Be 2
  }
  It 'lists a log first seen while it is held once it is let go' {
    if (-not $enforced) { Set-ItResult -Skipped -Because 'this platform does not keep a reader out of a file held with FileShare.None'; return }
    $fs = [IO.File]::Open($p, 'Open', 'ReadWrite', 'None')
    try { Update-CopilotCliRoster $none 60000; @($script:CopilotCliRows).Count | Should -Be 0 } finally { $fs.Dispose() }
    Update-CopilotCliRoster $none 60000
    @($script:CopilotCliRows)[0].Act.Turns | Should -Be 1
    [IO.File]::WriteAllText($p, ((Start-Ev 'claude-sonnet-5-5'), (Ev 'user.message' @{ content = 'a different log, and longer than the first' }), (Ev 'user.message' @{ content = 'two' }) -join "`n") + "`n")
    Update-CopilotCliRoster $none 60000   # and its head was taken: a replaced log is still seen as one
    @($script:CopilotCliRows)[0].Act.Model | Should -Be 'sonnet-5-5'
  }
  It 'keeps the last workspace.yaml while it is held, and reads it once it is let go' {
    if (-not $enforced) { Set-ItResult -Skipped -Because 'this platform does not keep a reader out of a file held with FileShare.None'; return }
    $yp = Join-Path $dir 'workspace.yaml'
    Update-CopilotCliRoster $none 60000
    @($script:CopilotCliRows)[0].Y.name | Should -Be 'Review the change'
    [IO.File]::WriteAllText($yp, "name: A new title`nclient_name: vscode`n")
    $fs = [IO.File]::Open($yp, 'Open', 'ReadWrite', 'None')
    try { Update-CopilotCliRoster $none 60000; @($script:CopilotCliRows)[0].Y.name | Should -Be 'Review the change' } finally { $fs.Dispose() }
    Update-CopilotCliRoster $none 60000
    @($script:CopilotCliRows)[0].Y.name | Should -Be 'A new title'
  }
}

Describe 'Update-CopilotCliRoster: a long history is read a little at a time' {
  BeforeAll {
    Reset-CopilotCli; $script:KeepMin = -1
    $root = Join-Path $TestDrive 'long'; $env:COPILOT_HOME = $root
    for ($i = 0; $i -lt 5; $i++) {
      New-CliSession (Join-Path $root 'session-state') "old$i" @((Start-Ev), (Ev 'user.message' @{ content = "p$i" }), (Usage 'claude-opus-5-5' 1000 0), (Ev 'session.shutdown' @{})) | Out-Null
    }
  }
  AfterAll { $env:COPILOT_HOME = $null }
  It 'with no time to spare, reads one ended session a call and counts the rest' {
    Update-CopilotCliRoster $none 0
    @($script:CopilotCliRows).Count | Should -Be 1
    $script:CopilotCliPending | Should -Be 4
  }
  It 'has read everything once the calls catch up' {
    for ($n = 0; $n -lt 10 -and $script:CopilotCliPending; $n++) { Update-CopilotCliRoster $none 0 }
    $script:CopilotCliPending | Should -Be 0
    @($script:CopilotCliRows).Count | Should -Be 5
  }
}

Describe 'Build-Rows: Copilot CLI sessions are listed with the rest' {
  BeforeAll {
    Mock Get-GitInfo { @{ Branch = ''; Worktree = $false; Main = '' } }
    Reset-CopilotCli; $script:KeepMin = 60
    $root = Join-Path $TestDrive 'rows'; $env:COPILOT_HOME = $root
    $st = Join-Path $root 'session-state'
    New-CliSession $st 'live0001' @((Start-Ev), (Ev 'user.message' @{ content = 'go' })) 77 | Out-Null
    New-CliSession $st 'gone0001' @((Start-Ev), (Ev 'user.message' @{ content = 'go' }), (Ev 'session.shutdown' @{})) | Out-Null
    $script:Departed = @{}; $script:KeptGone = @(); $script:Roster = @(); $script:ClineRows = @(); $script:CopilotRows = @()
    $script:ShowGone = $true; $script:ShowSubagents = $false
    $script:GoneRows = @{}; $script:AgentRows = @{}; $script:HistoryAt = Get-Date; $script:GoneCheckedAt = Get-Date; $script:GoneBuildMs = 60000
    $script:RefreshIds = [Collections.Generic.HashSet[string]]::new()
    Update-CopilotCliRoster $alive 60000
  }
  AfterAll { $env:COPILOT_HOME = $null; $script:CopilotCliRows = @() }
  It 'builds a row for each, live and gone, and reuses the gone one while its log is unchanged' {
    $rows = @(Build-Rows)
    @($rows | ForEach-Object { $_.NAME }) | Sort-Object | Should -Be @('cpcli-gone0001', 'cpcli-live0001')
    $gone = @($rows | Where-Object { $_.NAME -eq 'cpcli-gone0001' })[0]
    $again = @(Build-Rows | Where-Object { $_.NAME -eq 'cpcli-gone0001' })[0]
    [object]::ReferenceEquals($gone, $again) | Should -BeTrue
  }
  # a cached gone row follows workspace.yaml: its client when it changes, its title when it is deleted
  It 'rebuilds a gone row when workspace.yaml changes, its title kept' {
    $yp = Join-Path $st 'gone0001/workspace.yaml'
    $null = @(Build-Rows)
    [IO.File]::WriteAllText($yp, "id: gone0001`ncwd: C:\work`nbranch: another-branch`nclient_name: vscode`nname: Review the change`n")
    Update-CopilotCliRoster $alive 60000
    $r = @(Build-Rows | Where-Object { $_.NAME -eq 'cpcli-gone0001' })[0]
    $r._CopilotCli.Y.client_name | Should -Be 'vscode'
    $r.BRANCH | Should -Be 'another-branch'
  }
  It 'drops what workspace.yaml said once it is deleted: the title falls back to the first prompt' {
    $null = @(Build-Rows)
    Remove-Item (Join-Path $st 'gone0001/workspace.yaml')
    Update-CopilotCliRoster $alive 60000
    $r = @(Build-Rows | Where-Object { $_.NAME -eq 'cpcli-gone0001' })[0]
    $r.TITLE | Should -Be 'go'
    $r._CopilotCli.Y.Count | Should -Be 0
    $live = @(Build-Rows | Where-Object { $_.NAME -eq 'cpcli-live0001' })[0]
    $live.TITLE | Should -Be 'Review the change'
  }
  It 'shows the branch workspace.yaml recorded when the folder is not a git repository (git lookup gives -)' {
    Mock Get-GitInfo { @{ Branch = '-'; Worktree = $false; Main = '' } }
    $e = @($script:CopilotCliRows | Where-Object { $_.Id -eq 'live0001' })[0]
    (New-CopilotCliRow $e $false).BRANCH | Should -Be 'main'
  }
  # a linked worktree whose HEAD can't be read shows the recorded branch, not wt:-
  It 'shows the branch workspace.yaml recorded, marked wt:, in a linked worktree whose HEAD git lookup can''t read' {
    Mock Get-GitInfo { @{ Branch = '-'; Worktree = $true; Main = 'C:\main' } }
    $e = @($script:CopilotCliRows | Where-Object { $_.Id -eq 'live0001' })[0]
    (New-CopilotCliRow $e $false).BRANCH | Should -Be 'wt:main'
    Mock Get-GitInfo { @{ Branch = 'live-branch'; Worktree = $true; Main = 'C:\main' } }
    (New-CopilotCliRow $e $false).BRANCH | Should -Be 'wt:live-branch'   # git's branch, when it gives one
  }
}

# A newest log that can't be read must not take the call's one guaranteed read of an ended log (and its time),
# or an older readable log stays pending for as long as the newest is held.
Describe 'Update-CopilotCliRoster: a log that cannot be read does not hold up the others' {
  BeforeEach {
    Reset-CopilotCli; $script:KeepMin = -1
    $root = Join-Path $TestDrive ([guid]::NewGuid()); $env:COPILOT_HOME = $root
    $st = Join-Path $root 'session-state'
    $olders = @(foreach ($n in 'older001', 'older002') {
      $d = New-CliSession $st $n @((Start-Ev), (Ev 'user.message' @{ content = $n }), (Ev 'session.shutdown' @{}))
      [IO.File]::SetLastWriteTimeUtc((Join-Path $d 'events.jsonl'), [datetime]::UtcNow.AddMinutes(-2)); $d })
    $newDir = New-CliSession $st 'newest01' @((Start-Ev), (Ev 'user.message' @{ content = 'newest' }), (Ev 'session.shutdown' @{}))
    $newLog = Join-Path $newDir 'events.jsonl'
    $probe = [IO.File]::Open($newLog, 'Open', 'ReadWrite', 'None')
    $enforced = $false; try { (Open-Shared $newLog).Dispose() } catch { $enforced = $true } finally { $probe.Dispose() }
  }
  AfterAll { $env:COPILOT_HOME = $null }
  It 'with no time to spare, still reads a readable log while the newest is held, and retries the held one' {
    if (-not $enforced) { Set-ItResult -Skipped -Because 'this platform does not keep a reader out of a file held with FileShare.None'; return }
    $fs = [IO.File]::Open($newLog, 'Open', 'ReadWrite', 'None')
    try {
      Update-CopilotCliRoster $none 0
      # the two older logs are equally old: which one the call reads first is the folder's order (on Linux, not by name)
      $first = @($script:CopilotCliRows | ForEach-Object { $_.Id })
      $first.Count | Should -Be 1
      $first[0] | Should -BeIn @('older001', 'older002')
      Update-CopilotCliRoster $none 0
      @($script:CopilotCliRows | ForEach-Object { $_.Id }) | Sort-Object | Should -Be @('older001', 'older002')
      $script:CopilotCliPending | Should -Be 0
    } finally { $fs.Dispose() }
    Update-CopilotCliRoster $none 0   # let go: read on the very next call
    @($script:CopilotCliRows | ForEach-Object { $_.Id }) | Sort-Object | Should -Be @('newest01', 'older001', 'older002')
    $script:CopilotCliPending | Should -Be 0
  }
  It 'does not count the time a failed read took against the readable logs' {
    # the newest log's head can't be read, and finding that out takes longer than the whole budget
    Mock Get-HeadPrint -ParameterFilter { $path -eq $newLog } { Start-Sleep -Milliseconds 400; '' }
    Update-CopilotCliRoster $none 300
    @($script:CopilotCliRows | ForEach-Object { $_.Id }) | Sort-Object | Should -Be @('older001', 'older002')
    $script:CopilotCliPending | Should -Be 0
  }
}

# In a linked worktree whose HEAD is held or empty, Get-GitInfo keeps Worktree (what .git already said), so a
# new row shows wt: and the recorded branch; and a cached gone row takes git's branch once HEAD can be read
# again, because its cache key includes what git said. Real files here, no mock of Get-GitInfo.
Describe 'a Copilot CLI session in a linked git worktree whose HEAD cannot be read' {
  BeforeEach {
    Reset-CopilotCli
    $work = Join-Path $TestDrive ([guid]::NewGuid())
    $linked = Join-Path $work 'linked'; $gitdir = Join-Path $work 'main/.git/worktrees/linked'
    foreach ($d in $linked, $gitdir) { [void][IO.Directory]::CreateDirectory($d) }
    [IO.File]::WriteAllText((Join-Path $linked '.git'), "gitdir: $gitdir`n")
    $head = Join-Path $gitdir 'HEAD'
    [IO.File]::WriteAllText($head, "ref: refs/heads/live-branch`n")
    $root = Join-Path $work 'copilot'; $env:COPILOT_HOME = $root
    New-CliSession (Join-Path $root 'session-state') 'wt000001' @((Start-Ev), (Ev 'user.message' @{ content = 'go' }), (Ev 'session.shutdown' @{})) $null `
      "id: wt000001`ncwd: $linked`nbranch: recorded-branch`nclient_name: github/cli`nname: In a worktree`n" | Out-Null
    $script:Departed = @{}; $script:KeptGone = @(); $script:Roster = @(); $script:ClineRows = @(); $script:CopilotRows = @()
    $script:ShowGone = $true; $script:ShowSubagents = $false
    $script:GoneRows = @{}; $script:AgentRows = @{}; $script:HistoryAt = Get-Date; $script:GoneCheckedAt = Get-Date; $script:GoneBuildMs = 60000
    $script:RefreshIds = [Collections.Generic.HashSet[string]]::new()
    $probe = [IO.File]::Open($head, 'Open', 'ReadWrite', 'None')
    $enforced = $false; try { (Open-Shared $head).Dispose() } catch { $enforced = $true } finally { $probe.Dispose() }
  }
  AfterAll { $env:COPILOT_HOME = $null; $script:CopilotCliRows = @() }
  It 'keeps the worktree marker when HEAD is empty: branch -, the main repository still named, and the row shows wt: and the recorded branch' {
    [IO.File]::WriteAllText($head, '')
    $g = Get-GitInfo $linked
    $g.Worktree | Should -BeTrue
    $g.Branch | Should -Be '-'
    $g.Main | Should -Be (Join-Path $work 'main')
    Update-CopilotCliRoster $none 60000
    (New-CopilotCliRow @($script:CopilotCliRows)[0] $false).BRANCH | Should -Be 'wt:recorded-branch'
  }
  It 'keeps the worktree marker while another program holds HEAD' {
    if (-not $enforced) { Set-ItResult -Skipped -Because 'this platform does not keep a reader out of a file held with FileShare.None'; return }
    $fs = [IO.File]::Open($head, 'Open', 'ReadWrite', 'None')
    try {
      $g = Get-GitInfo $linked
      Update-CopilotCliRoster $none 60000
      $row = New-CopilotCliRow @($script:CopilotCliRows)[0] $false
    } finally { $fs.Dispose() }
    $g.Worktree | Should -BeTrue
    $g.Branch | Should -Be '-'
    $row.BRANCH | Should -Be 'wt:recorded-branch'
  }
  It 'gives a detached HEAD''s first 7 characters, and - for a HEAD too short to be a commit, marked as a worktree either way' {
    [IO.File]::WriteAllText($head, "d24fceb6a51392390f0e80071af43004405016a1`n")
    $g = Get-GitInfo $linked; $g.Branch | Should -Be 'd24fceb'; $g.Worktree | Should -BeTrue
    $script:BranchCache = @{}
    [IO.File]::WriteAllText($head, "d24`n")
    $g = Get-GitInfo $linked; $g.Branch | Should -Be '-'; $g.Worktree | Should -BeTrue
  }
  It 'in a main checkout (not a worktree), an empty HEAD gives - and no worktree' {
    $plain = Join-Path $work 'plain'; [void][IO.Directory]::CreateDirectory((Join-Path $plain '.git'))
    [IO.File]::WriteAllText((Join-Path $plain '.git/HEAD'), '')
    $g = Get-GitInfo $plain
    $g.Branch | Should -Be '-'; $g.Worktree | Should -BeFalse; $g.Main | Should -Be ''
  }
  It 'a cached gone row takes git''s branch once HEAD can be read again, with its log and workspace.yaml unchanged; then it is reused again' {
    [IO.File]::Delete($head)   # missing: Get-GitInfo keeps Worktree here, so this tests the cache alone
    Update-CopilotCliRoster $none 60000
    $first = @(Build-Rows | Where-Object { $_.NAME -eq 'cpcli-wt000001' })[0]
    $first.BRANCH | Should -Be 'wt:recorded-branch'
    [IO.File]::WriteAllText($head, "ref: refs/heads/live-branch`n")
    $script:BranchCache = @{}   # what a roster poll does
    Update-CopilotCliRoster $none 60000
    $next = @(Build-Rows | Where-Object { $_.NAME -eq 'cpcli-wt000001' })[0]
    $next.BRANCH | Should -Be 'wt:live-branch'
    $again = @(Build-Rows | Where-Object { $_.NAME -eq 'cpcli-wt000001' })[0]
    [object]::ReferenceEquals($next, $again) | Should -BeTrue   # git unchanged: the row is not rebuilt
    $script:BranchCache = @{}
    $null = @(Build-Rows)
    $script:BranchCache.Count | Should -Be 0   # and git is not asked again for a row that has its branch
  }
  It 'does not ask git again for a cached gone row outside any repository' {
    $out = Join-Path $work 'elsewhere'; [void][IO.Directory]::CreateDirectory($out)
    [IO.File]::WriteAllText((Join-Path $root 'session-state/wt000001/workspace.yaml'), "id: wt000001`ncwd: $out`nbranch: recorded-branch`n")
    Update-CopilotCliRoster $none 60000
    $first = @(Build-Rows | Where-Object { $_.NAME -eq 'cpcli-wt000001' })[0]
    $script:BranchCache = @{}
    $again = @(Build-Rows | Where-Object { $_.NAME -eq 'cpcli-wt000001' })[0]
    [object]::ReferenceEquals($first, $again) | Should -BeTrue
    $script:BranchCache.Count | Should -Be 0
  }
  # Not every first line of 7 or more characters is a detached commit ("ref: refs/heads/" is not "ref: re", nor
  # "not-a-commit" "not-a-c"): only what git itself takes as HEAD gives a branch: "ref:", optional
  # spaces, then refs/<something>, or a whole 40- or 64-character hexadecimal commit id (git's validate_headref
  # and parse_loose_ref_contents). Anything else gives '-' and keeps the worktree.
  It 'reads HEAD <Name> as <Want>, marked as a worktree with its main repository' -TestCases @(
    @{ Name = 'ref: refs/heads/ (no name)';       Body = "ref: refs/heads/`n";            Want = '-' }
    @{ Name = 'ref: refs/heads/ and spaces';      Body = "ref: refs/heads/   `n";         Want = '-' }
    @{ Name = 'not-a-commit';                     Body = 'not-a-commit';                  Want = '-' }
    @{ Name = 'six characters';                   Body = 'abc123';                        Want = '-' }
    @{ Name = 'ref: refs/ alone';                 Body = "ref: refs/`n";                  Want = '-' }
    @{ Name = 'ref: outside refs/';               Body = "ref: heads/live-branch`n";      Want = '-' }
    @{ Name = '39 hex characters';                Body = ('d' * 39) + "`n";               Want = '-' }
    @{ Name = '41 hex characters';                Body = ('d' * 41) + "`n";               Want = '-' }
    @{ Name = '40 characters, one not hex';       Body = ('d' * 39) + "g`n";              Want = '-' }
    @{ Name = 'a branch';                         Body = "ref: refs/heads/live-branch`n"; Want = 'live-branch' }
    @{ Name = 'a branch, no space after ref:';    Body = "ref:refs/heads/live-branch`n";  Want = 'live-branch' }
    @{ Name = 'a branch with trailing spaces';    Body = "ref: refs/heads/live-branch  `n"; Want = 'live-branch' }
    @{ Name = 'a ref outside refs/heads/';        Body = "ref: refs/remotes/origin/x`n";  Want = 'refs/remotes/origin/x' }
    @{ Name = 'a SHA-1 commit';                   Body = "d24fceb6a51392390f0e80071af43004405016a1`n"; Want = 'd24fceb' }
    @{ Name = 'a SHA-1 commit in capitals';       Body = "D24FCEB6A51392390F0E80071AF43004405016A1`n"; Want = 'D24FCEB' }
    # checked against git 2.56.1: git's whitespace is ASCII
    # space, tab, newline and carriage return only (its own isspace: not \v, not \f, not U+00A0); the whole file
    # is HEAD, its trailing whitespace dropped and a NUL ending it; the target must pass check_refname_format;
    # a detached id is exactly the repository's hash width (no config here: SHA-1, 40).
    @{ Name = 'a branch ending in U+00A0';        Body = "ref: refs/heads/topic$([char]0xA0)`n"; Want = "topic$([char]0xA0)" }
    @{ Name = 'a branch starting with U+00A0';    Body = "ref: refs/heads/$([char]0xA0)topic`n"; Want = "$([char]0xA0)topic" }
    @{ Name = 'U+00A0 after ref:';                Body = "ref:$([char]0xA0)refs/heads/main`n"; Want = '-' }
    @{ Name = 'a vertical tab after ref:';        Body = "ref:`vrefs/heads/main`n";       Want = '-' }
    @{ Name = 'a form feed after the target';     Body = "ref: refs/heads/main`f";        Want = '-' }
    @{ Name = 'a tab and spaces around the target'; Body = "ref:`t refs/heads/main`t `n";  Want = 'main' }
    @{ Name = 'a CRLF line end';                  Body = "ref: refs/heads/main`r`n";      Want = 'main' }
    @{ Name = 'ref: then a newline, then the target'; Body = "ref:`n refs/heads/main`n";  Want = 'main' }
    @{ Name = 'a second line after the target';   Body = "ref: refs/heads/old`njunk`n";   Want = '-' }
    @{ Name = 'a NUL after the target';           Body = "ref: refs/heads/main$([char]0)junk`n"; Want = 'main' }
    @{ Name = 'a space, then a NUL';              Body = "ref: refs/heads/main $([char]0)junk`n"; Want = '-' }
    @{ Name = 'a control character in the name';  Body = "ref: refs/heads/ma$([char]1)in`n"; Want = '-' }
    @{ Name = 'a byte order mark first';          Body = "$([char]0xFEFF)ref: refs/heads/main`n"; Want = '-' }
    @{ Name = 'refs/heads/foo..bar';              Body = "ref: refs/heads/foo..bar`n";    Want = '-' }
    @{ Name = 'refs/heads/old branch';            Body = "ref: refs/heads/old branch`n";  Want = '-' }
    @{ Name = 'a name ending in .lock';           Body = "ref: refs/heads/x.lock`n";      Want = '-' }
    @{ Name = 'a part starting with .';           Body = "ref: refs/heads/.x`n";          Want = '-' }
    @{ Name = 'a name ending in .';               Body = "ref: refs/heads/x.`n";          Want = '-' }
    @{ Name = 'a doubled /';                      Body = "ref: refs/heads//x`n";          Want = '-' }
    @{ Name = 'a name with @{';                   Body = "ref: refs/heads/a@{b`n";        Want = '-' }
    @{ Name = 'a name with *';                    Body = "ref: refs/heads/a*b`n";         Want = '-' }
    @{ Name = 'a name with ~';                    Body = "ref: refs/heads/a~b`n";         Want = '-' }
    @{ Name = 'a name with ^';                    Body = "ref: refs/heads/a^b`n";         Want = '-' }
    @{ Name = 'a name with :';                    Body = "ref: refs/heads/a:b`n";         Want = '-' }
    @{ Name = 'a name with ?';                    Body = "ref: refs/heads/a?b`n";         Want = '-' }
    @{ Name = 'a name with [';                    Body = "ref: refs/heads/a[b`n";         Want = '-' }
    @{ Name = 'a name with \';                    Body = "ref: refs/heads/a\b`n";         Want = '-' }
    @{ Name = 'a name with DEL';                  Body = "ref: refs/heads/a$([char]0x7F)b`n"; Want = '-' }
    @{ Name = 'a valid name with dots and @';     Body = "ref: refs/heads/v1.2/a.b@c`n";  Want = 'v1.2/a.b@c' }
    @{ Name = 'a one-part ref under refs/';       Body = "ref: refs/x`n";                 Want = 'refs/x' }
    @{ Name = '64 hex characters in a SHA-1 repository'; Body = ('0123abcd' * 8) + "`n"; Want = '-' }
    @{ Name = 'a SHA-1 commit, then a note';      Body = ('d' * 40) + " note`n";          Want = 'ddddddd' }
    @{ Name = 'a SHA-1 commit, then a NUL';       Body = ('d' * 40) + "$([char]0)junk";   Want = 'ddddddd' }
    @{ Name = 'a SHA-1 commit, then a vertical tab'; Body = ('d' * 40) + "`vx`n";         Want = '-' }
  ) {
    [IO.File]::WriteAllText($head, $Body)
    $g = Get-GitInfo $linked
    $g.Branch | Should -BeExactly $Want
    $g.Worktree | Should -BeTrue
    $g.Main | Should -Be (Join-Path $work 'main')
  }
  It 'in a main checkout, a HEAD that is not a ref or a commit id gives -' {
    $plain = Join-Path $work 'plain'; [void][IO.Directory]::CreateDirectory((Join-Path $plain '.git'))
    [IO.File]::WriteAllText((Join-Path $plain '.git/HEAD'), "not-a-commit`n")
    $g = Get-GitInfo $plain
    $g.Branch | Should -Be '-'; $g.Worktree | Should -BeFalse
  }
  # The hash width is the repository's: extensions.objectformat = sha256 (git init --object-format=sha256
  # writes it) in the config of the common directory, which a linked worktree's gitdir names in its commondir
  # file ("../..", as git worktree add writes it). git takes the value only as "sha256", quoted or not.
  It 'in a SHA-256 repository, takes a 64-character id and not a 40-character one, in a linked worktree and a main checkout' {
    [IO.File]::WriteAllText((Join-Path $work 'main/.git/config'), "[core]`n`trepositoryformatversion = 1`n[extensions]`n`tobjectformat = sha256`n")
    [IO.File]::WriteAllText((Join-Path $gitdir 'commondir'), "../..`n")
    [IO.File]::WriteAllText($head, ('0123abcd' * 8) + "`n")
    (Get-GitInfo $linked).Branch | Should -BeExactly '0123abc'
    $script:BranchCache = @{}
    [IO.File]::WriteAllText($head, ('d' * 40) + "`n")
    $g = Get-GitInfo $linked; $g.Branch | Should -Be '-'; $g.Worktree | Should -BeTrue; $g.Main | Should -Be (Join-Path $work 'main')
    $script:BranchCache = @{}
    [IO.File]::WriteAllText($head, "ref: refs/heads/live-branch`n")
    (Get-GitInfo $linked).Branch | Should -Be 'live-branch'
    $plain = Join-Path $work 'plain'; [void][IO.Directory]::CreateDirectory((Join-Path $plain '.git'))
    [IO.File]::WriteAllText((Join-Path $plain '.git/config'), "[Extensions]`n`tObjectFormat = `"sha256`" ; a comment`n")
    [IO.File]::WriteAllText((Join-Path $plain '.git/HEAD'), ('0123abcd' * 8) + "`n")
    (Get-GitInfo $plain).Branch | Should -BeExactly '0123abc'
    $script:BranchCache = @{}
    [IO.File]::WriteAllText((Join-Path $plain '.git/HEAD'), ('d' * 40) + "`n")
    (Get-GitInfo $plain).Branch | Should -Be '-'
  }
  It 'reads a repository as SHA-1 when objectformat is in another section, is not sha256, or the config cannot be read' {
    $plain = Join-Path $work 'plain'; [void][IO.Directory]::CreateDirectory((Join-Path $plain '.git'))
    $cfg = Join-Path $plain '.git/config'; $ph = Join-Path $plain '.git/HEAD'
    [IO.File]::WriteAllText($ph, ('d' * 40) + "`n")
    foreach ($text in "[extensions `"x`"]`n`tobjectformat = sha256`n", "[core]`n`tobjectformat = sha256`n", "[extensions]`n`tobjectformat = sha1`n") {
      [IO.File]::WriteAllText($cfg, $text); $script:BranchCache = @{}
      (Get-GitInfo $plain).Branch | Should -Be 'ddddddd' -Because $text
    }
    if (-not $enforced) { Set-ItResult -Skipped -Because 'this platform does not keep a reader out of a file held with FileShare.None'; return }
    [IO.File]::WriteAllText($cfg, "[extensions]`n`tobjectformat = sha256`n")
    $fs = [IO.File]::Open($cfg, 'Open', 'ReadWrite', 'None')
    try { $script:BranchCache = @{}; $g = Get-GitInfo $plain } finally { $fs.Dispose() }
    $g.Branch | Should -Be 'ddddddd'
  }
  It 'a cached gone row whose HEAD was <Name> takes git''s branch once HEAD is valid, with its log and workspace.yaml unchanged' -TestCases @(
    @{ Name = 'ref: refs/heads/ (no name)'; Body = 'ref: refs/heads/' }
    @{ Name = 'not-a-commit';               Body = 'not-a-commit' }
    # these three must not stay wt:foo..bar, wt:old, wt:bbbbbbb
    @{ Name = 'refs/heads/foo..bar';        Body = 'ref: refs/heads/foo..bar' }
    @{ Name = 'refs/heads/old branch';      Body = 'ref: refs/heads/old branch' }
    @{ Name = 'a target with a second line'; Body = "ref: refs/heads/old`njunk`n" }
    @{ Name = '64 hex in a SHA-1 repository'; Body = 'b' * 64 }
    @{ Name = '40 hex in a SHA-256 repository'; Body = 'b' * 40; Sha256 = $true }
  ) {
    if ($Sha256) {
      [IO.File]::WriteAllText((Join-Path $work 'main/.git/config'), "[extensions]`n`tobjectformat = sha256`n")
      [IO.File]::WriteAllText((Join-Path $gitdir 'commondir'), "../..`n")
    }
    [IO.File]::WriteAllText($head, $Body)
    Update-CopilotCliRoster $none 60000
    $first = @(Build-Rows | Where-Object { $_.NAME -eq 'cpcli-wt000001' })[0]
    $first.BRANCH | Should -Be 'wt:recorded-branch'   # git's '-': the branch workspace.yaml recorded
    [IO.File]::WriteAllText($head, "ref: refs/heads/live-branch`n")
    $script:BranchCache = @{}   # what a roster poll does
    Update-CopilotCliRoster $none 60000
    $next = @(Build-Rows | Where-Object { $_.NAME -eq 'cpcli-wt000001' })[0]
    $next.BRANCH | Should -Be 'wt:live-branch'
    $script:BranchCache = @{}
    $again = @(Build-Rows | Where-Object { $_.NAME -eq 'cpcli-wt000001' })[0]
    [object]::ReferenceEquals($next, $again) | Should -BeTrue
    $script:BranchCache.Count | Should -Be 0   # settled: git is not asked again
  }
}
