# Cline sessions, read from Cline's own files: <sessions>/<id>/<id>.json (the manifest) and
# <id>.messages.json (the conversation, with each reply's metrics). The file shapes follow Cline's source
# (cline/cline a6507a6: session-manifest.ts, session-data.ts, messages.ts) and the manifests seen on
# Windows on 2026-11-01 (docs/research/other-agents.md). No SQLite, no cline command.
BeforeAll {
  . (Join-Path $PSScriptRoot 'Import-Ctop.ps1')
  function Iso([datetime]$t) { $t.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ') }
  # one session folder: its manifest, and its messages file when $messages is given
  function New-ClineSession([string]$root, [string]$id, [hashtable]$fields, $messages = $null) {
    $dir = Join-Path $root $id; New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $m = [ordered]@{ version = 1; session_id = $id; source = 'vscode'; pid = $PID; started_at = (Iso (Get-Date).AddMinutes(-10)); status = 'idle'
                     interactive = $true; provider = 'anthropic'; model = 'claude-sonnet-5'; cwd = $root; workspace_root = $root
                     enable_tools = $true; enable_spawn = $false; enable_teams = $false; prompt = "fix the bug`nand more"
                     messages_path = (Join-Path $dir "$id.messages.json") }
    foreach ($k in $fields.Keys) { $m[$k] = $fields[$k] }
    [IO.File]::WriteAllText((Join-Path $dir "$id.json"), ($m | ConvertTo-Json -Depth 6))
    if ($null -ne $messages) {
      $doc = [ordered]@{ version = 1; updated_at = (Iso (Get-Date)); agent = 'lead'; sessionId = $id; messages = @($messages) }
      [IO.File]::WriteAllText((Join-Path $dir "$id.messages.json"), ($doc | ConvertTo-Json -Depth 12))
    }
    return $dir
  }
  function Reply($content, [hashtable]$metrics) {
    $r = [ordered]@{ role = 'assistant'; content = $content; modelInfo = @{ id = 'claude-sonnet-5'; provider = 'anthropic' }; ts = 1793562130000 }
    if ($metrics) { $r.metrics = $metrics }
    $r
  }
  function Prompt([string]$text) { [ordered]@{ role = 'user'; content = @(@{ type = 'text'; text = $text }) } }
  function Reset-Cline {
    $script:ClineManifests = @{}; $script:ClineMsgCache = @{}; $script:History = @{}; $script:BranchCache = @{}
    $script:FreshIds = [Collections.Generic.HashSet[string]]::new(); $script:KeepMin = 60
  }
}

Describe 'Get-ClineSessionsDir (where Cline keeps its sessions)' {
  BeforeEach { $saved = @{}; foreach ($n in 'CLINE_SESSION_DATA_DIR', 'CLINE_DATA_DIR', 'CLINE_DIR') { $saved[$n] = [Environment]::GetEnvironmentVariable($n); [Environment]::SetEnvironmentVariable($n, $null) } }
  AfterEach { foreach ($n in $saved.Keys) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) } }
  It 'is ~/.cline/data/sessions by default' { Get-ClineSessionsDir | Should -Be (Join-Path (Join-Path (Join-Path $HOME '.cline') 'data') 'sessions') }
  It 'follows CLINE_DIR' { $env:CLINE_DIR = 'X'; Get-ClineSessionsDir | Should -Be (Join-Path (Join-Path 'X' 'data') 'sessions') }
  It 'follows CLINE_DATA_DIR before CLINE_DIR' { $env:CLINE_DIR = 'X'; $env:CLINE_DATA_DIR = 'D'; Get-ClineSessionsDir | Should -Be (Join-Path 'D' 'sessions') }
  It 'follows CLINE_SESSION_DATA_DIR before both' { $env:CLINE_DIR = 'X'; $env:CLINE_DATA_DIR = 'D'; $env:CLINE_SESSION_DATA_DIR = 'S'; Get-ClineSessionsDir | Should -Be 'S' }
}

Describe 'ConvertFrom-IsoTime' {
  It 'reads an ISO string (Windows PowerShell 5.1 leaves it one) as local time' {
    $t = ConvertFrom-IsoTime '2026-11-01T19:42:09.114Z'
    $t.Kind | Should -Be 'Local'
    $t.ToUniversalTime() | Should -Be ([datetime]::new(2026, 11, 1, 19, 42, 9, 114, [DateTimeKind]::Utc))
  }
  It 'takes a DateTime as it is (PowerShell 7 has parsed it already)' {
    (ConvertFrom-IsoTime ([datetime]::new(2026, 11, 1, 19, 42, 9, [DateTimeKind]::Utc))).ToUniversalTime() | Should -Be ([datetime]::new(2026, 11, 1, 19, 42, 9, [DateTimeKind]::Utc))
  }
  It 'gives $null for nothing or nonsense' { ConvertFrom-IsoTime $null | Should -BeNullOrEmpty; ConvertFrom-IsoTime 'soon' | Should -BeNullOrEmpty }
}

Describe 'Read-ClineManifests' {
  BeforeAll {
    Reset-Cline
    $root = Join-Path $TestDrive 'sessions'
    New-ClineSession $root '1793562129035_phf3k' @{} | Out-Null
    $half = Join-Path $root '1793562129036_half1'; New-Item -ItemType Directory -Force -Path $half | Out-Null
    [IO.File]::WriteAllText((Join-Path $half '1793562129036_half1.json'), '{"version":1,"session_id":"1793562129036_ha')   # being written
    $odd = Join-Path $root 'other'; New-Item -ItemType Directory -Force -Path $odd | Out-Null
    [IO.File]::WriteAllText((Join-Path $odd 'notes.json'), '{"session_id":"x","pid":1,"status":"idle"}')               # not <folder>/<folder>.json
    [IO.File]::WriteAllText((Join-Path $root 'sessions.index.json'), '{}')
  }
  It 'returns the complete manifests and skips the rest' {
    $r = @(Read-ClineManifests $root)
    $r.Count | Should -Be 1
    $r[0].M.session_id | Should -Be '1793562129035_phf3k'
    $r[0].M.status | Should -Be 'idle'
  }
  It 'keeps the last good copy of a manifest caught half-written' {
    $f = Join-Path $root '1793562129035_phf3k/1793562129035_phf3k.json'
    [IO.File]::WriteAllText($f, '{"version":1,"session_id":"1793562129035_ph')
    $r = @(Read-ClineManifests $root)
    $r.Count | Should -Be 1
    $r[0].M.status | Should -Be 'idle'
  }
  It 'returns nothing, and does not fail, when the folder does not exist' { @(Read-ClineManifests (Join-Path $TestDrive 'nope')).Count | Should -Be 0 }
}

Describe 'Read-ClineMessages (tokens, cost, state and last action from the conversation)' {
  BeforeEach { Reset-Cline }
  It 'sums the replies'' metrics, takes CTX from the newest one, and counts prompts and tool calls' {
    $msgs = @(
      (Prompt 'fix the bug'),
      (Reply @(@{ type = 'text'; text = 'looking' }, @{ type = 'tool_use'; id = 't1'; name = 'read_file'; input = @{ path = 'src/a.ts' } }) @{ inputTokens = 100; outputTokens = 20; cacheReadTokens = 1000; cacheWriteTokens = 50; cost = 0.25 }),
      [ordered]@{ role = 'user'; content = @(@{ type = 'tool_result'; tool_use_id = 't1'; name = 'read_file'; content = 'x' }) },
      (Reply @(@{ type = 'tool_use'; id = 't2'; name = 'read_file'; input = @{ path = 'src/b.ts' } }) @{ inputTokens = 200; outputTokens = 30; cacheReadTokens = 2000; cacheWriteTokens = 300; cost = 0.5 }),
      [ordered]@{ role = 'user'; content = @(@{ type = 'tool_result'; tool_use_id = 't2'; name = 'read_file'; content = 'y' }) },
      (Reply @(@{ type = 'text'; text = "fixed`nit" }) @{ inputTokens = 300; outputTokens = 40; cacheReadTokens = 3000; cacheWriteTokens = 0; cost = 0.75 })
    )
    $dir = New-ClineSession (Join-Path $TestDrive 's1') 'a_one' @{} $msgs
    $a = Read-ClineMessages (Join-Path $dir 'a_one.messages.json')
    $a.Cost | Should -Be 1.5
    $a.InTok | Should -Be 600; $a.OutTok | Should -Be 90; $a.CacheR | Should -Be 6000; $a.CacheW | Should -Be 350
    $a.Ctx | Should -Be 3                       # 300 + 3000 + 0, in thousands
    $a.Turns | Should -Be 1; $a.Tools | Should -Be 2
    $a.ToolMix | Should -Be 'read_file 2'
    $a.Model | Should -Be 'sonnet-5'
    $a.State | Should -Be 'idle'
    $a.Last | Should -Be 'fixed it'
  }
  It 'is working while a tool call is the newest message, and names the tool and its first argument' {
    $dir = New-ClineSession (Join-Path $TestDrive 's2') 'a_two' @{} @((Prompt 'go'), (Reply @(@{ type = 'tool_use'; id = 't'; name = 'execute_command'; input = @{ command = 'npm test'; requires_approval = $false } }) $null))
    $a = Read-ClineMessages (Join-Path $dir 'a_two.messages.json')
    $a.State | Should -Be 'working'
    $a.Last | Should -Be 'execute_command: npm test'
    $a.Cost | Should -Be 0
  }
  It 'is thinking after a prompt' {
    $dir = New-ClineSession (Join-Path $TestDrive 's3') 'a_three' @{} @((Prompt 'go'))
    (Read-ClineMessages (Join-Path $dir 'a_three.messages.json')).State | Should -Be 'thinking'
  }
  It 'ignores a cost that is not a number' {
    $dir = New-ClineSession (Join-Path $TestDrive 's4') 'a_four' @{} @((Prompt 'go'), (Reply @(@{ type = 'text'; text = 'ok' }) @{ inputTokens = 1; cost = 'NaN' }))
    (Read-ClineMessages (Join-Path $dir 'a_four.messages.json')).Cost | Should -Be 0
  }
  It 'gives empty fields, and does not fail, when there is no messages file' {
    $a = Read-ClineMessages (Join-Path $TestDrive 'nope.messages.json')
    $a.State | Should -Be '-'; $a.Cost | Should -Be 0
  }
}

Describe 'Update-ClineRoster and New-ClineRow' {
  BeforeAll {
    Mock Get-GitInfo { @{ Branch = '-'; Worktree = $false; Main = '' } }
    Reset-Cline
    $root = Join-Path $TestDrive 'roster'
    $env:CLINE_SESSION_DATA_DIR = $root
    $now = Get-Date
    New-ClineSession $root '1_idle1' @{ status = 'idle'; pid = 101 } @((Prompt 'hello'), (Reply @(@{ type = 'text'; text = 'hi' }) @{ inputTokens = 10; cost = 0.1 })) | Out-Null
    New-ClineSession $root '2_runs1' @{ status = 'running'; pid = 102 } @((Prompt 'go'), (Reply @(@{ type = 'tool_use'; id = 't'; name = 'write_to_file'; input = @{ path = 'a.txt' } }) $null)) | Out-Null
    New-ClineSession $root '3_dead1' @{ status = 'running'; pid = 103 } | Out-Null                                             # its window closed
    New-ClineSession $root '4_fail1' @{ status = 'failed'; pid = 101; exit_code = 1; ended_at = (Iso $now.AddMinutes(-5)) } | Out-Null
    New-ClineSession $root '5_done1' @{ status = 'completed'; pid = 101; exit_code = 0; ended_at = (Iso $now.AddDays(-3)) } | Out-Null   # outside the keep window
    New-ClineSession $root '6_reus1' @{ status = 'idle'; pid = 104; started_at = (Iso $now.AddDays(-2)) } | Out-Null      # its pid now names a newer process
    New-ClineSession $root '7_head1' @{ status = 'idle'; pid = 101; interactive = $false } | Out-Null                    # headless: listed with -All
    $starts = @{ 101 = $now.AddHours(-5); 102 = $now.AddHours(-5); 104 = $now.AddHours(-1) }
    $getStart = { param($id) $starts[$id] }.GetNewClosure()
    Update-ClineRoster $getStart
    $byId = @{}; foreach ($e in $script:ClineRows) { $byId[[string]$e.M.session_id] = $e }
  }
  AfterAll { $env:CLINE_SESSION_DATA_DIR = $null }
  It 'lists open sessions whose process is there as live' {
    $byId['1_idle1'].GoneAt | Should -BeNullOrEmpty
    $byId['2_runs1'].GoneAt | Should -BeNullOrEmpty
  }
  It 'lists an open session whose process has gone as gone' { $byId['3_dead1'].GoneAt | Should -Not -BeNullOrEmpty }
  It 'lists an ended session as gone at its end time, inside the keep window' {
    $byId['4_fail1'].GoneAt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm') | Should -Be $now.AddMinutes(-5).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm')
  }
  It 'leaves out a session that ended before the keep window' { $byId.ContainsKey('5_done1') | Should -BeFalse }
  It 'does not take a reused pid for the session''s process' { $byId['6_reus1'].GoneAt | Should -Not -BeNullOrEmpty }
  It 'leaves out a headless session unless -All' { $byId.ContainsKey('7_head1') | Should -BeFalse }
  It 'makes rows: VIA cline, STATE from Cline''s status and the conversation, cost as Cline reports it' {
    $r1 = New-ClineRow $byId['1_idle1'] $false
    $r1.VIA | Should -Be 'cline'; $r1.STATE | Should -Be 'idle'; $r1.NAME | Should -Be 'cline-idle1'
    $r1.COST | Should -Be '$0.10'; $r1.TITLE | Should -Be 'fix the bug'; $r1.MODEL | Should -Be 'sonnet-5'
    $r1.'CPU(s)' | Should -Be '-'; $r1._Agent | Should -Be 'cline'
    $r2 = New-ClineRow $byId['2_runs1'] $false
    $r2.STATE | Should -Be 'working'; $r2.'LAST ACTION' | Should -Be 'write_to_file: a.txt'
    (New-ClineRow $byId['4_fail1'] $false).STATE | Should -Match '^gone '
  }
  It 'peeks and gives a contact block without Claude Code''s resume command' {
    Mock Get-WindowWidth { 120 }
    $r = New-ClineRow $byId['4_fail1'] $false
    $text = (@(Build-Peek $r) | ForEach-Object { if ($_ -is [hashtable]) { $_.Text } else { $_ } }) -join "`n"
    $text | Should -Match 'Cline recorded it as failed, exit code 1'
    $text | Should -Not -Match 'claude --resume'
    $c = Format-Contact $r 'box'
    $c | Should -Match '^Cline session \(VS Code\)'
    $c | Should -Not -Match 'claude --resume'
  }
}

Describe 'Update-ClineRoster: a long history is read a little at a time' {
  BeforeAll {
    Mock Get-GitInfo { @{ Branch = '-'; Worktree = $false; Main = '' } }
    Reset-Cline; $script:KeepMin = -1   # keep everything: every ended session is listed
    $root = Join-Path $TestDrive 'long'
    $env:CLINE_SESSION_DATA_DIR = $root
    for ($i = 0; $i -lt 6; $i++) {
      New-ClineSession $root ("1_old{0}" -f $i) @{ status = 'completed'; pid = 1; exit_code = 0; ended_at = (Iso (Get-Date).AddHours(-$i - 1)) } @((Prompt 'p'), (Reply @(@{ type = 'text'; text = "done $i" }) @{ inputTokens = 1; cost = 0.5 })) | Out-Null
    }
    $none = { param($id) $null }
  }
  AfterAll { $env:CLINE_SESSION_DATA_DIR = $null }
  It 'with no time to spare, still reads one manifest a call, and says how many are left' {
    Update-ClineRoster $none 0
    @($script:ClineRows).Count | Should -Be 1
    $script:ClinePending | Should -Be 5
  }
  It 'reads an ended session''s conversation within the budget, and one a call at least' {
    Update-ClineRoster $none 0
    # two manifests are known now; the first call's session has its conversation read already
    @($script:ClineRows | Where-Object { $_.Act.Cost -eq 0.5 }).Count | Should -BeGreaterOrEqual 1
    $script:ClinePending | Should -BeGreaterThan 0
  }
  It 'has read everything once the calls catch up' {
    for ($n = 0; $n -lt 20 -and $script:ClinePending; $n++) { Update-ClineRoster $none 0 }
    $script:ClinePending | Should -Be 0
    @($script:ClineRows).Count | Should -Be 6
    @($script:ClineRows | Where-Object { $_.Act.Cost -eq 0.5 }).Count | Should -Be 6
  }
}

Describe 'Update-ClineRoster: what changed is read again, and a bad file does not hold up the rest (Sol, PR #3/#4 findings 2 and 3)' {
  BeforeAll {
    Mock Get-GitInfo { @{ Branch = '-'; Worktree = $false; Main = '' } }
    $alive = { param($id) (Get-Date).AddHours(-5) }
  }
  BeforeEach { Reset-Cline; $script:KeepMin = -1 }
  AfterEach { $env:CLINE_SESSION_DATA_DIR = $null }
  It 'reads an ended session''s final conversation, not the one it cached while the session ran' {
    $root = Join-Path $TestDrive ("stale-" + [guid]::NewGuid()); $env:CLINE_SESSION_DATA_DIR = $root
    New-ClineSession $root '9_stale' @{ status = 'running'; pid = 101 } @((Prompt 'go'), (Reply @(@{ type = 'text'; text = 'still working' }) @{ inputTokens = 1; cost = 0.25 })) | Out-Null
    Update-ClineRoster $alive
    $script:ClineRows[0].Act.Cost | Should -Be 0.25
    # it ends: the conversation gets its last reply, and the manifest says completed
    New-ClineSession $root '9_stale' @{ status = 'completed'; pid = 101; exit_code = 0; ended_at = (Iso (Get-Date)) } @((Prompt 'go'), (Reply @(@{ type = 'text'; text = 'still working' }) @{ inputTokens = 1; cost = 0.25 }), (Prompt 'and?'), (Reply @(@{ type = 'text'; text = 'all done' }) @{ inputTokens = 1; cost = 1.0 })) | Out-Null
    for ($i = 0; $i -lt 3; $i++) { Update-ClineRoster $alive }
    $script:ClineRows[0].GoneAt | Should -Not -BeNullOrEmpty
    $script:ClineRows[0].Act.Cost | Should -Be 1.25
    $script:ClineRows[0].Act.Last | Should -Be 'all done'
    $script:ClinePending | Should -Be 0
  }
  It 'counts a changed ended conversation as still to read when there is no time for it, and reads it on a later call' {
    $root = Join-Path $TestDrive ("stale2-" + [guid]::NewGuid()); $env:CLINE_SESSION_DATA_DIR = $root
    foreach ($n in 1, 2) { New-ClineSession $root "8_end$n" @{ status = 'completed'; pid = 1; ended_at = (Iso (Get-Date)) } @((Prompt 'p'), (Reply @(@{ type = 'text'; text = 'one' }) @{ cost = 0.5 })) | Out-Null }
    Update-ClineRoster $alive    # everything read: no budget given
    foreach ($n in 1, 2) { New-ClineSession $root "8_end$n" @{ status = 'completed'; pid = 1; ended_at = (Iso (Get-Date)) } @((Prompt 'p'), (Reply @(@{ type = 'text'; text = 'two' }) @{ cost = 2.0 })) | Out-Null }
    Update-ClineRoster $alive 0  # no time: one file is read a call, the rest is counted (manifests were rewritten too)
    $script:ClinePending | Should -BeGreaterThan 0
    for ($n = 0; $n -lt 4 -and $script:ClinePending; $n++) { Update-ClineRoster $alive 0 }
    $script:ClinePending | Should -Be 0
    @($script:ClineRows | Where-Object { $_.Act.Cost -eq 2.0 }).Count | Should -Be 2
  }
  It 'does not parse an unchanged malformed manifest again, so older sessions still load' {
    $root = Join-Path $TestDrive ("bad-" + [guid]::NewGuid()); $env:CLINE_SESSION_DATA_DIR = $root
    New-ClineSession $root '7_good' @{ status = 'idle'; pid = 101 } | Out-Null
    $old = (Get-Date).AddMinutes(-10)
    [IO.File]::SetLastWriteTime((Join-Path $root '7_good/7_good.json'), $old)
    $bad = Join-Path $root '7_bad1'; New-Item -ItemType Directory -Force -Path $bad | Out-Null
    [IO.File]::WriteAllText((Join-Path $bad '7_bad1.json'), '{"version":1,"session_id":"7_ba')   # newest, and stays broken
    for ($i = 0; $i -lt 3; $i++) { Update-ClineRoster $alive 0 }
    @($script:ClineRows).Count | Should -Be 1
    $script:ClineRows[0].M.session_id | Should -Be '7_good'
    $script:ClinePending | Should -Be 0
    # once the broken one is rewritten whole, it is read
    New-ClineSession $root '7_bad1' @{ status = 'idle'; pid = 101 } | Out-Null
    Update-ClineRoster $alive 0
    @($script:ClineRows).Count | Should -Be 2
  }
  It 'does not keep an ended session with a malformed conversation pending forever' {
    $root = Join-Path $TestDrive ("badmsg-" + [guid]::NewGuid()); $env:CLINE_SESSION_DATA_DIR = $root
    $dir = New-ClineSession $root '6_badm' @{ status = 'completed'; pid = 1; ended_at = (Iso (Get-Date)) }
    [IO.File]::WriteAllText((Join-Path $dir '6_badm.messages.json'), '{"version":1,"messages":[{"ro')
    Update-ClineRoster $alive 0
    Update-ClineRoster $alive 0
    $script:ClinePending | Should -Be 0
    @($script:ClineRows).Count | Should -Be 1
  }
}
