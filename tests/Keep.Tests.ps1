# The "keep" window: how long gone sessions and stopped subagents stay listed. One setting for both,
# adjusted at runtime with + / -, seeded at startup from the closed-sessions log.
#   0  = keep nothing (rows go the moment they stop / leave)
#   -1 = keep forever (shown as ∞)
BeforeAll { . (Join-Path $PSScriptRoot 'Import-Ctop.ps1') }

Describe 'ConvertTo-KeepMinutes' {
  It 'reads <Text> as <Minutes> minutes' -ForEach @(
    @{ Text = '0';       Minutes = 0 }
    @{ Text = '15';      Minutes = 15 }
    @{ Text = '15m';     Minutes = 15 }
    @{ Text = '90m';     Minutes = 90 }
    @{ Text = '2h';      Minutes = 120 }
    @{ Text = '1.5h';    Minutes = 90 }
    @{ Text = '1d';      Minutes = 1440 }
    @{ Text = '1w';      Minutes = 10080 }
    @{ Text = ' 2H ';    Minutes = 120 }
    @{ Text = '2 h';     Minutes = 120 }
    @{ Text = 'inf';     Minutes = -1 }
    @{ Text = 'INF';     Minutes = -1 }
    @{ Text = 'forever'; Minutes = -1 }
    @{ Text = 'all';     Minutes = -1 }
    @{ Text = '∞';       Minutes = -1 }
    @{ Text = '1h30m';   Minutes = 90 }
    @{ Text = '1d1h';    Minutes = 1500 }
    @{ Text = '1d 12h';  Minutes = 2160 }
  ) {
    ConvertTo-KeepMinutes $Text | Should -Be $Minutes
  }

  It 'rejects <Text>' -ForEach @(
    @{ Text = '' }, @{ Text = '   ' }, @{ Text = 'abc' }, @{ Text = '-5' }, @{ Text = '5x' }, @{ Text = 'h' }, @{ Text = '1h30' }
    @{ Text = 'h1' }, @{ Text = '1h x' }, @{ Text = '30 inf' }
  ) {
    # the message, not just "it threw": a missing function throws too
    { ConvertTo-KeepMinutes $Text } | Should -Throw -ExpectedMessage "*not a keep duration*"
  }
}

Describe 'Format-Keep' {
  It 'shows <Minutes> as <Text>' -ForEach @(
    @{ Minutes = 0;     Text = '0' }
    @{ Minutes = 15;    Text = '15m' }
    @{ Minutes = 45;    Text = '45m' }
    @{ Minutes = 60;    Text = '1h' }
    @{ Minutes = 90;    Text = '1h30m' }
    @{ Minutes = 720;   Text = '12h' }
    @{ Minutes = 1440;  Text = '1d' }
    @{ Minutes = 1500;  Text = '1d1h' }
    @{ Minutes = 10080; Text = '7d' }
    @{ Minutes = 43200; Text = '30d' }
    @{ Minutes = -1;    Text = '∞' }
  ) {
    Format-Keep $Minutes | Should -Be $Text
  }

  It 'round-trips <Minutes> through ConvertTo-KeepMinutes' -ForEach @(
    @{ Minutes = 90 }, @{ Minutes = 1500 }, @{ Minutes = 61 }, @{ Minutes = 10081 }
  ) {
    ConvertTo-KeepMinutes (Format-Keep $Minutes) | Should -Be $Minutes
  }

  It 'round-trips every ladder step through ConvertTo-KeepMinutes' {
    $m = 0
    while ($true) {
      ConvertTo-KeepMinutes (Format-Keep $m) | Should -Be $m
      if ($m -eq -1) { break }
      $m = Step-Keep $m 1
    }
  }
}

Describe 'Step-Keep' {
  It 'walks the whole ladder up from 0 to ∞' {
    $seen = @(0)
    $m = 0
    while ($m -ne -1) { $m = Step-Keep $m 1; $seen += $m }
    $seen | Should -Be @(0, 15, 30, 45, 60, 120, 240, 480, 720, 1440, 2880, 4320, 10080, 20160, 43200, -1)
  }

  It 'walks back down from ∞ to 0' {
    $seen = @(-1)
    $m = -1
    while ($m -ne 0) { $m = Step-Keep $m -1; $seen += $m }
    $seen | Should -Be @(-1, 43200, 20160, 10080, 4320, 2880, 1440, 720, 480, 240, 120, 60, 45, 30, 15, 0)
  }

  It 'stops at the ends: down from 0 stays 0, up from ∞ stays ∞' {
    Step-Keep 0 -1  | Should -Be 0
    Step-Keep -1 1  | Should -Be -1
  }

  It 'moves an off-ladder value <Start> to <Up> (up) and <Down> (down)' -ForEach @(
    @{ Start = 20;    Up = 30;  Down = 15 }
    @{ Start = 100;   Up = 120; Down = 60 }
    @{ Start = 50000; Up = -1;  Down = 43200 }
    @{ Start = 1;     Up = 15;  Down = 0 }
  ) {
    Step-Keep $Start 1  | Should -Be $Up
    Step-Keep $Start -1 | Should -Be $Down
  }
}

Describe 'Resolve-Keep (command-line parameters)' {
  It 'defaults to 15 minutes' {
    Resolve-Keep -Keep '' -SubagentWindowSeconds $null | Should -Be 15
  }
  It 'takes -Keep (or its alias -Linger) when given' {
    Resolve-Keep -Keep '2d' -SubagentWindowSeconds $null | Should -Be 2880
    Resolve-Keep -Keep '30' -SubagentWindowSeconds $null | Should -Be 30
  }
  It 'prefers -Keep over the old -SubagentWindow' {
    Resolve-Keep -Keep '1h' -SubagentWindowSeconds 900 | Should -Be 60
  }
  It 'converts the old -SubagentWindow seconds <Seconds> to <Minutes>' -ForEach @(
    @{ Seconds = 900;  Minutes = 15 }
    @{ Seconds = 3600; Minutes = 60 }
    @{ Seconds = 30;   Minutes = 1 }    # rounds up: never turns a non-zero window into "keep nothing"
    @{ Seconds = 0;    Minutes = -1 }   # its old meaning: until the parent goes away = forever
  ) {
    Resolve-Keep -Keep '' -SubagentWindowSeconds $Seconds | Should -Be $Minutes
  }
}

Describe 'Test-KeepWindow' {
  BeforeAll { $now = [datetime]'2026-10-31T12:00:00' }

  It 'keeps nothing at 0, even something that left this instant' {
    Test-KeepWindow -At $now -Now $now -KeepMinutes 0 | Should -BeFalse
  }
  It 'keeps everything at ∞, however old' {
    Test-KeepWindow -At $now.AddDays(-400) -Now $now -KeepMinutes -1 | Should -BeTrue
  }
  It 'keeps an entry exactly at the window edge, drops it just past' {
    Test-KeepWindow -At $now.AddMinutes(-15) -Now $now -KeepMinutes 15 | Should -BeTrue
    Test-KeepWindow -At $now.AddMinutes(-15).AddSeconds(-1) -Now $now -KeepMinutes 15 | Should -BeFalse
  }
  It 'keeps an entry stamped in the future (clock skew)' {
    Test-KeepWindow -At $now.AddMinutes(5) -Now $now -KeepMinutes 15 | Should -BeTrue
  }
}

Describe 'Test-SubagentListed' {
  BeforeAll { $now = [datetime]'2026-10-31T12:00:00' }

  It 'always lists a working agent, whatever the window or its age' {
    Test-SubagentListed -LastWrite $now.AddHours(-5) -Now $now -KeepMinutes 0 -State 'working' -Finished $false | Should -BeTrue
  }
  It 'treats a working agent that Claude Code marked finished as stopped' {
    Test-SubagentListed -LastWrite $now.AddHours(-5) -Now $now -KeepMinutes 15 -State 'working' -Finished $true | Should -BeFalse
  }
  It 'lists a stopped agent within the window, drops it after' {
    Test-SubagentListed -LastWrite $now.AddMinutes(-10) -Now $now -KeepMinutes 15 -State 'idle' -Finished $true | Should -BeTrue
    Test-SubagentListed -LastWrite $now.AddMinutes(-20) -Now $now -KeepMinutes 15 -State 'idle' -Finished $true | Should -BeFalse
  }
  It 'drops a stopped agent at once when the window is 0' {
    Test-SubagentListed -LastWrite $now -Now $now -KeepMinutes 0 -State 'idle' -Finished $false | Should -BeFalse
  }
  It 'keeps a stopped agent forever at ∞' {
    Test-SubagentListed -LastWrite $now.AddDays(-20) -Now $now -KeepMinutes -1 -State 'idle' -Finished $true | Should -BeTrue
  }
  It 'keeps a thinking agent listed for at least 15 minutes even when the window is 0' {
    Test-SubagentListed -LastWrite $now.AddMinutes(-10) -Now $now -KeepMinutes 0 -State 'thinking' -Finished $false | Should -BeTrue
    Test-SubagentListed -LastWrite $now.AddMinutes(-16) -Now $now -KeepMinutes 0 -State 'thinking' -Finished $false | Should -BeFalse
  }
  It 'keeps a thinking agent for the whole window when it is longer than 15 minutes' {
    Test-SubagentListed -LastWrite $now.AddMinutes(-50) -Now $now -KeepMinutes 60 -State 'thinking' -Finished $false | Should -BeTrue
  }
}

Describe 'ConvertFrom-RosterPoll (a failed poll is not an empty roster)' {
  It 'accepts a clean exit with a JSON array of sessions' {
    $r = ConvertFrom-RosterPoll -ExitCode 0 -Stdout '[{"sessionId":"a","kind":"interactive"},{"sessionId":"b","kind":"background"}]' -Stderr ''
    $r.Ok | Should -BeTrue
    $r.Why | Should -BeNullOrEmpty
    @($r.Sessions).Count | Should -Be 2
    $r.Sessions[0].sessionId | Should -Be 'a'
  }
  It 'accepts a single-session array as one session' {
    $r = ConvertFrom-RosterPoll -ExitCode 0 -Stdout '[{"sessionId":"a"}]' -Stderr ''
    $r.Ok | Should -BeTrue
    @($r.Sessions).Count | Should -Be 1
  }
  It 'accepts [] as a real, empty roster' {
    $r = ConvertFrom-RosterPoll -ExitCode 0 -Stdout "  [ ]`n" -Stderr ''
    $r.Ok | Should -BeTrue
    @($r.Sessions).Count | Should -Be 0
  }
  It 'fails on a non-zero exit, with the first stderr line as the reason' {
    $r = ConvertFrom-RosterPoll -ExitCode 1 -Stdout '' -Stderr "`n  supervisor unavailable  `nmore detail`n"
    $r.Ok | Should -BeFalse
    $r.Why | Should -Be 'exit 1: supervisor unavailable'
  }
  It 'fails on a non-zero exit even when stdout holds a valid array' {
    (ConvertFrom-RosterPoll -ExitCode 2 -Stdout '[]' -Stderr '').Ok | Should -BeFalse
    (ConvertFrom-RosterPoll -ExitCode 2 -Stdout '[]' -Stderr '').Why | Should -Be 'exit 2'
  }
  It 'cuts a long stderr reason to 120 characters' {
    $r = ConvertFrom-RosterPoll -ExitCode 1 -Stdout '' -Stderr ('x' * 500)
    $r.Why.Length | Should -BeLessOrEqual 120
    $r.Why | Should -BeLike 'exit 1: xxx*…'
  }
  It 'fails with "<Why>" on stdout <Name>' -ForEach @(
    @{ Name = 'empty';        Stdout = '';                 Why = 'no output' }
    @{ Name = 'whitespace';   Stdout = "  `n ";            Why = 'no output' }
    @{ Name = 'html';         Stdout = '<html>oops</html>'; Why = 'output is not a JSON array' }
    @{ Name = 'an object';    Stdout = '{"error":"x"}';    Why = 'output is not a JSON array' }
    @{ Name = 'truncated';    Stdout = '[{"sessionId":';   Why = 'invalid JSON' }
  ) {
    $r = ConvertFrom-RosterPoll -ExitCode 0 -Stdout $Stdout -Stderr ''
    $r.Ok | Should -BeFalse
    $r.Why | Should -Be $Why
  }
}

Describe 'Read-ClosedHistory (seeding gone rows from the closed-sessions log)' {
  BeforeEach { $log = Join-Path $TestDrive "closed-$([guid]::NewGuid()).jsonl" }

  It 'returns nothing for a missing file' {
    (Read-ClosedHistory -Path (Join-Path $TestDrive 'nope.jsonl')).Count | Should -Be 0
  }
  It 'returns nothing for an empty file' {
    Set-Content -LiteralPath $log -Value '' -NoNewline
    (Read-ClosedHistory -Path $log).Count | Should -Be 0
  }
  It 'builds one entry per session, with the fields a gone row needs' {
    Set-Content -LiteralPath $log -Value @(
      '{"closedAt":"2026-10-30T10:00:00.0000000+00:00","why":"closed","name":"alpha","title":"T","sessionId":"s1","cwd":"/w/a","pid":11,"startedAt":1793400000000,"kind":"interactive"}'
    )
    $h = Read-ClosedHistory -Path $log
    $h.Count | Should -Be 1
    $e = $h['s1']
    $e.GoneAt | Should -Be ([DateTimeOffset]'2026-10-30T10:00:00+00:00').LocalDateTime
    $e.Cleared | Should -BeFalse
    $e.Successor | Should -Be ''
    $e.Session.sessionId | Should -Be 's1'
    $e.Session.name | Should -Be 'alpha'
    $e.Session.cwd | Should -Be '/w/a'
    $e.Session.pid | Should -Be 11
    $e.Session.startedAt | Should -Be 1793400000000
    $e.Session.kind | Should -Be 'interactive'
    $e.Session.title | Should -Be 'T'   # shown when the transcript (and its title) is gone
  }
  It 'keeps the newest entry when a session id appears more than once, whatever the line order' {
    Set-Content -LiteralPath $log -Value @(
      '{"closedAt":"2026-10-30T12:00:00+00:00","why":"closed","name":"new","sessionId":"s1"}'
      '{"closedAt":"2026-10-30T09:00:00+00:00","why":"closed","name":"old","sessionId":"s1"}'
    )
    (Read-ClosedHistory -Path $log)['s1'].Session.name | Should -Be 'new'
  }
  It 'marks a /clear as cleared and keeps its successor' {
    Set-Content -LiteralPath $log -Value '{"closedAt":"2026-10-30T10:00:00+00:00","why":"cleared","sessionId":"s1","successor":"s2"}'
    $e = (Read-ClosedHistory -Path $log)['s1']
    $e.Cleared | Should -BeTrue
    $e.Successor | Should -Be 's2'
  }
  It 'defaults kind to interactive for entries written before it was logged' {
    Set-Content -LiteralPath $log -Value '{"closedAt":"2026-10-30T10:00:00+00:00","why":"closed","sessionId":"s1"}'
    (Read-ClosedHistory -Path $log)['s1'].Session.kind | Should -Be 'interactive'
  }
  It 'skips malformed lines and entries without a session id or time' {
    Set-Content -LiteralPath $log -Value @(
      'not json'
      '{"closedAt":"2026-10-30T10:00:00+00:00","why":"closed"}'
      '{"why":"closed","sessionId":"s2"}'
      '{"closedAt":"not a date","sessionId":"s3"}'
      '{"closedAt":"2026-10-30T10:00:00+00:00","why":"closed","sessionId":"s4"}'
      ''
    )
    $h = Read-ClosedHistory -Path $log
    @($h.Keys) | Should -Be @('s4')
  }
  It 'reads a file that starts with a UTF-8 byte-order mark (as Windows PowerShell 5.1 writes it)' {
    $bom = [byte[]](0xEF, 0xBB, 0xBF)
    $body = [Text.Encoding]::UTF8.GetBytes('{"closedAt":"2026-10-30T10:00:00+00:00","why":"closed","sessionId":"s1"}' + "`n")
    [IO.File]::WriteAllBytes($log, $bom + $body)
    (Read-ClosedHistory -Path $log).ContainsKey('s1') | Should -BeTrue
  }
}

Describe 'Update-Departed (who left the roster)' {
  BeforeAll {
    function S([string]$id, $procId = $null) { [pscustomobject]@{ sessionId = $id; pid = $procId; name = "n-$id"; cwd = '/w' } }
    $now = [datetime]'2026-10-31T12:00:00'
  }

  It 'records a session that left, and returns it for the closed log' {
    $d = @{}
    $left = @(Update-Departed -Departed $d -OldRoster @((S 'a' 1), (S 'b' 2)) -Live @((S 'a' 1)) -Now $now)
    $d.Keys | Should -Be @('b')
    $d['b'].GoneAt | Should -Be $now
    $d['b'].Cleared | Should -BeFalse
    $left.Count | Should -Be 1
    $left[0].Session.sessionId | Should -Be 'b'
    $left[0].Why | Should -Be 'closed'
  }
  It 'treats a new session id on the same pid as a /clear, with the successor' {
    $d = @{}
    $left = @(Update-Departed -Departed $d -OldRoster @((S 'a' 7)) -Live @((S 'z' 7)) -Now $now)
    $d['a'].Cleared | Should -BeTrue
    $d['a'].Successor | Should -Be 'z'
    $left[0].Why | Should -Be 'cleared'
    $left[0].Successor | Should -Be 'z'
  }
  It 'does not record or return a session twice' {
    $d = @{}
    Update-Departed -Departed $d -OldRoster @((S 'b' 2)) -Live @() -Now $now | Out-Null
    $again = @(Update-Departed -Departed $d -OldRoster @((S 'b' 2)) -Live @() -Now $now.AddMinutes(1))
    $again.Count | Should -Be 0
    $d['b'].GoneAt | Should -Be $now
  }
  It 'forgets a gone session that is live again (resumed)' {
    $d = @{ b = @{ Session = (S 'b'); GoneAt = $now.AddDays(-1); Cleared = $false; Successor = '' } }
    Update-Departed -Departed $d -OldRoster @() -Live @((S 'b' 3)) -Now $now | Out-Null
    $d.ContainsKey('b') | Should -BeFalse
  }
  It 'never prunes by age: the keep window is applied when drawing, so it can be widened later' {
    $d = @{ old = @{ Session = (S 'old'); GoneAt = $now.AddDays(-40); Cleared = $false; Successor = '' } }
    Update-Departed -Departed $d -OldRoster @() -Live @() -Now $now | Out-Null
    $d.ContainsKey('old') | Should -BeTrue
  }
}

Describe 'Get-KeptDeparted (gone rows inside the window)' {
  BeforeAll {
    $now = [datetime]'2026-10-31T12:00:00'
    $d = @{
      recent = @{ Session = [pscustomobject]@{ sessionId = 'recent' }; GoneAt = $now.AddMinutes(-5) }
      hour   = @{ Session = [pscustomobject]@{ sessionId = 'hour' };   GoneAt = $now.AddMinutes(-70) }
      week   = @{ Session = [pscustomobject]@{ sessionId = 'week' };   GoneAt = $now.AddDays(-6) }
    }
  }
  It 'returns only entries inside a <Keep>-minute window' -ForEach @(
    @{ Keep = 0;     Ids = @() }
    @{ Keep = 15;    Ids = @('recent') }
    @{ Keep = 120;   Ids = @('hour', 'recent') }
    @{ Keep = -1;    Ids = @('hour', 'recent', 'week') }
  ) {
    $ids = @(Get-KeptDeparted -Departed $d -Now $now -KeepMinutes $Keep | ForEach-Object { $_.Session.sessionId } | Sort-Object)
    $ids | Should -Be $Ids
  }
  It 'returns the most recently gone first (history loads, and is listed, newest first)' {
    @(Get-KeptDeparted -Departed $d -Now $now -KeepMinutes -1 | ForEach-Object { $_.Session.sessionId }) | Should -Be @('recent', 'hour', 'week')
  }
}

Describe 'Format-GoneNote (the peek line for a gone row)' {
  # exact text: fragment checks let a garbled sentence through once
  It 'reads right when <Case>' -ForEach @(
    @{ Case = 'closed, transcript on disk'; Cleared = $false; Successor = ''; Disk = $true
       Text = '  GONE         left the roster 5m ago (transcript still on disk; resume below)' }
    @{ Case = 'closed, transcript deleted'; Cleared = $false; Successor = ''; Disk = $false
       Text = '  GONE         left the roster 5m ago; its transcript is no longer on disk, so it cannot be resumed' }
    @{ Case = 'cleared, transcript on disk'; Cleared = $true; Successor = 'abcdef1234567890'; Disk = $true
       Text = '  CLEARED      /clear 5m ago — the process continues as session abcdef12…; this pre-clear conversation is still resumable (below)' }
    @{ Case = 'cleared, transcript deleted'; Cleared = $true; Successor = 'abcdef1234567890'; Disk = $false
       Text = '  CLEARED      /clear 5m ago — the process continued as session abcdef12…; the pre-clear transcript is no longer on disk, so it cannot be resumed' }
    @{ Case = 'cleared, successor not logged (older log entries)'; Cleared = $true; Successor = ''; Disk = $true
       Text = '  CLEARED      /clear 5m ago — the process continues as a new session id; this pre-clear conversation is still resumable (below)' }
    @{ Case = 'cleared, short successor id'; Cleared = $true; Successor = 'abc'; Disk = $true
       Text = '  CLEARED      /clear 5m ago — the process continues as session abc…; this pre-clear conversation is still resumable (below)' }
  ) {
    Format-GoneNote -Ago '5m' -Cleared $Cleared -Successor $Successor -HasTranscript $Disk | Should -BeExactly $Text
  }
}

Describe 'Test-KindListed (one rule for live and historical sessions)' {
  It 'lists <Kind> with -All:<All> -> <Listed>' -ForEach @(
    @{ Kind = 'interactive'; All = $false; Listed = $true }
    @{ Kind = 'background';  All = $false; Listed = $false }
    @{ Kind = 'background';  All = $true;  Listed = $true }
    @{ Kind = '';            All = $false; Listed = $false }
    @{ Kind = 'interactive'; All = $true;  Listed = $true }
  ) {
    Test-KindListed $Kind $All | Should -Be $Listed
  }
}
