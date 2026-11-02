# Claude Code's live-session registry (<config>/sessions/<pid>.json): what ctop reads when there is no
# claude command (VS Code alone, running its own Claude agent), and what labels a session's VIA.
BeforeAll { . (Join-Path $PSScriptRoot 'Import-Ctop.ps1') }

Describe 'Read-SessionRegistry' {
  BeforeAll {
    $dir = Join-Path $TestDrive 'sessions'; New-Item -ItemType Directory -Force -Path $dir | Out-Null
    function Put([string]$name, [string]$text) { [IO.File]::WriteAllText((Join-Path $dir $name), $text) }
    Put '4242.json' '{"pid":4242,"sessionId":"s-good","kind":"interactive","entrypoint":"sdk-ts","status":"busy","startedAt":1793570000000,"name":"one"}'
    Put '4343.json' '{"pid":4343,"sessionId":"s-half'                         # being written
    Put '4444.json' '{"kind":"interactive"}'                                  # no pid, no session
    Put '4242.0123abcd.key' 'not-json secret'                                 # a secret beside it: never read
    Put 'notes.json.bak' '{"pid":1,"sessionId":"x"}'
  }
  It 'returns the complete entries and skips the rest' {
    $r = @(Read-SessionRegistry $dir)
    $r.Count | Should -Be 1
    $r[0].sessionId | Should -Be 's-good'
    $r[0].entrypoint | Should -Be 'sdk-ts'
  }
  It 'returns nothing, and does not fail, when the folder does not exist' {
    @(Read-SessionRegistry (Join-Path $TestDrive 'nope')).Count | Should -Be 0
  }
}

Describe 'Test-RegistryLive (a leftover entry, or its pid given to another process)' {
  BeforeAll {
    $began = [DateTimeOffset]::new(2026, 11, 1, 12, 0, 0, [TimeSpan]::Zero)
    $entry = [pscustomobject]@{ pid = 77; sessionId = 's'; startedAt = $began.ToUnixTimeMilliseconds() }
    $at = $began.LocalDateTime
  }
  It 'is not live when no process has the pid' { Test-RegistryLive $entry { param($id) $null } | Should -BeFalse }
  It 'is live when the process started before the session did' { Test-RegistryLive $entry { param($id) $at.AddMinutes(-3) } | Should -BeTrue }
  It 'is live when the process started with it (within 5 s after)' { Test-RegistryLive $entry { param($id) $at.AddSeconds(4) } | Should -BeTrue }
  It 'is not live when the process started after the session (the pid was reused)' { Test-RegistryLive $entry { param($id) $at.AddMinutes(10) } | Should -BeFalse }
  It 'is live when the start time cannot be read (the process is there)' { Test-RegistryLive $entry { param($id) 'unknown' } | Should -BeTrue }
  It 'is live when the entry has no start time' {
    Test-RegistryLive ([pscustomobject]@{ pid = 77; sessionId = 's' }) { param($id) $at } | Should -BeTrue
  }
}

Describe 'Get-RegistryRoster (the real process table)' {
  It 'lists the session of a running process and drops a dead or reused pid' {
    $script:ConfigDir = Join-Path $TestDrive 'cfg'
    $dir = Join-Path $script:ConfigDir 'sessions'; New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    [IO.File]::WriteAllText((Join-Path $dir "$PID.json"), ('{"pid":' + $PID + ',"sessionId":"s-live","kind":"interactive","startedAt":' + $now + '}'))
    # pid 2147483000: nothing runs there
    [IO.File]::WriteAllText((Join-Path $dir '2147483000.json'), ('{"pid":2147483000,"sessionId":"s-dead","kind":"interactive","startedAt":' + $now + '}'))
    # this process, but the entry says the session began years before it: a leftover whose pid was reused
    [IO.File]::WriteAllText((Join-Path $dir 'old.json'), ('{"pid":' + $PID + ',"sessionId":"s-reused","kind":"interactive","startedAt":1577836800000}'))
    @(Get-RegistryRoster | ForEach-Object { $_.sessionId }) | Should -Be @('s-live')
  }
}

Describe 'Get-EntrypointLabel (VIA)' {
  It 'reads <In> as <Out>' -ForEach @(
    @{ In = 'claude-vscode'; Out = 'vscode' }
    @{ In = 'sdk-ts';        Out = 'sdk' }
    @{ In = 'sdk-py';        Out = 'sdk' }
    @{ In = 'cli';           Out = 'cli' }
    @{ In = 'remote';        Out = 'remote' }
    @{ In = '';              Out = '-' }
    @{ In = "evil$([char]27)[31mred"; Out = 'evilred' }
    @{ In = 'a-very-long-entrypoint-name'; Out = 'a-very-long-' }
  ) {
    Get-EntrypointLabel $In | Should -BeExactly $Out
  }
}

Describe 'Read-ClosedHistory keeps what a gone session ran in (VIA after a restart)' {
  It 'restores entrypoint from the closed log' {
    $log = Join-Path $TestDrive 'closed-via.jsonl'
    [IO.File]::WriteAllText($log, (@{ closedAt = '2026-11-01T22:00:00Z'; why = 'closed'; name = 'n1'; sessionId = 's-via'; pid = 77; startedAt = 1793500000000
                                     kind = 'interactive'; entrypoint = 'sdk-ts' } | ConvertTo-Json -Compress) + "`n")
    $h = Read-ClosedHistory $log
    $h['s-via'].Session.entrypoint | Should -Be 'sdk-ts'
    Get-EntrypointLabel ([string]$h['s-via'].Session.entrypoint) | Should -Be 'sdk'
  }
}

Describe 'Get-RegistryRoster: an entry caught half-written is not a session that ended (Sol, PR #3/#4 finding 5)' {
  BeforeAll {
    $script:ConfigDir = Join-Path $TestDrive 'cfg-half'; $ConfigDir = $script:ConfigDir
    $reg = Join-Path $ConfigDir 'sessions'; New-Item -ItemType Directory -Force -Path $reg | Out-Null
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $good = '{"pid":' + $PID + ',"sessionId":"s-live","kind":"interactive","entrypoint":"sdk-ts","status":"idle","startedAt":' + $now + '}'
    $file = Join-Path $reg "$PID.json"
  }
  It 'keeps the session while its entry cannot be read and its process still runs' {
    [IO.File]::WriteAllText($file, $good)
    $script:Roster = @(Get-RegistryRoster)
    @($script:Roster).Count | Should -Be 1
    [IO.File]::WriteAllText($file, $good.Substring(0, 30))   # being rewritten
    $r = @(Get-RegistryRoster)
    $r.Count | Should -Be 1
    $r[0].sessionId | Should -Be 's-live'
  }
  It 'drops it once its process is gone, readable or not' {
    $dead = 2147483000
    $script:Roster = @([pscustomobject]@{ pid = $dead; sessionId = 's-dead'; kind = 'interactive'; startedAt = $now })
    [IO.File]::WriteAllText((Join-Path $reg "$dead.json"), '{"pid":2147483000,"sessionId":"s-de')
    @(Get-RegistryRoster | Where-Object { $_.sessionId -eq 's-dead' }).Count | Should -Be 0
  }
  It 'does not invent a session from an unreadable entry it never knew' {
    $script:Roster = @()
    [IO.File]::WriteAllText($file, $good.Substring(0, 30))
    @(Get-RegistryRoster).Count | Should -Be 0
  }
}
