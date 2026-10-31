# Reading transcripts: JSON string values pulled out by regex must be unescaped, and cached scan state
# from an older scan format is redone.
BeforeAll { . (Join-Path $PSScriptRoot 'Import-Ctop.ps1') }

Describe 'Unescape-Json' {
  It 'turns <Raw> into <Text>' -ForEach @(
    @{ Raw = 'plain text';            Text = 'plain text' }
    @{ Raw = 'a full \"repo\" please'; Text = 'a full "repo" please' }
    @{ Raw = 'line one\nline two';    Text = "line one`nline two" }
    @{ Raw = 'C:\\dev\\src';          Text = 'C:\dev\src' }
    @{ Raw = 'caf\u00e9';             Text = 'café' }
    @{ Raw = 'tab\there';             Text = "tab`there" }
    @{ Raw = '';                      Text = '' }
  ) {
    Unescape-Json $Raw | Should -BeExactly $Text
  }
  It 'returns text that is not a valid JSON string body unchanged' {
    Unescape-Json 'bad \x escape' | Should -BeExactly 'bad \x escape'
  }
}

Describe 'Update-Scan: titles' {
  BeforeAll {
    $script:ScanCache = @{}; $script:ScanVerified = @{}; $script:PriceVer = 2; $script:ScanVer = 2
  }
  It 'reads a first prompt containing quotes as plain text' {
    $f = Join-Path $TestDrive 's1.jsonl'
    $line = @{ type = 'user'; sessionId = 's1'; timestamp = '2026-10-31T05:19:00Z'; message = @{ role = 'user'; content = 'Please turn this one file into a full "repo" by adding a README' } } | ConvertTo-Json -Compress -Depth 5
    Set-Content -LiteralPath $f -Value $line
    $st = Update-Scan (Get-Item -LiteralPath $f) 's1'
    $st.First | Should -BeExactly 'Please turn this one file into a full "repo" by adding a README'
  }
  It 'takes a first prompt in a non-Latin script as the title: <Name>' -ForEach @(
    @{ Name = 'Hebrew';   Text = (-join @(0x05EA, 0x05E7, 0x05DF, 0x0020, 0x05D0, 0x05EA, 0x0020, 0x05D4, 0x05D1, 0x05D3, 0x05D9, 0x05E7, 0x05D5, 0x05EA | ForEach-Object { [char]$_ })) }
    @{ Name = 'Chinese';  Text = (-join @(0x4FEE, 0x590D, 0x6D4B, 0x8BD5, 0x7528, 0x4F8B | ForEach-Object { [char]$_ })) }
    @{ Name = 'Russian';  Text = (-join @(0x0438, 0x0441, 0x043F, 0x0440, 0x0430, 0x0432, 0x044C, 0x0020, 0x0442, 0x0435, 0x0441, 0x0442, 0x044B | ForEach-Object { [char]$_ })) }
  ) {
    $f = Join-Path $TestDrive "nl-$Name.jsonl"
    Set-Content -LiteralPath $f -Encoding utf8 -Value (@{ type = 'user'; sessionId = 'n'; message = @{ role = 'user'; content = $Text } } | ConvertTo-Json -Compress -Depth 5)
    (Update-Scan (Get-Item -LiteralPath $f) "nl-$Name").First | Should -BeExactly $Text
  }
  It 'stamps new scan state with the current scan version' {
    $f = Join-Path $TestDrive 's2.jsonl'
    Set-Content -LiteralPath $f -Value (@{ type = 'user'; sessionId = 's2'; message = @{ role = 'user'; content = 'hello there' } } | ConvertTo-Json -Compress -Depth 5)
    (Update-Scan (Get-Item -LiteralPath $f) 's2').ScanVer | Should -Be $script:ScanVer
  }
}

Describe 'Load-ScanCache: scan format version' {
  BeforeEach {
    $script:ScanCache = @{}; $script:PriceVer = 2; $script:ScanVer = 2; $script:CacheDays = 2
    $script:ScanCachePath = Join-Path $TestDrive "cache-$([guid]::NewGuid()).json"
    $used = (Get-Date).ToUniversalTime().Ticks
    $entry = { param($ver) $e = @{ Path = '/x.jsonl'; Head = 'AAAA'; Used = $used; PriceVer = 2; ToolCounts = @{}; First = 'x' }; if ($null -ne $ver) { $e.ScanVer = $ver }; $e }
    @{ current = (& $entry 2); old = (& $entry 1); none = (& $entry $null) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:ScanCachePath
  }
  It 'keeps entries of the current scan version and drops older ones (they are rescanned once)' {
    Load-ScanCache
    @($script:ScanCache.Keys | Sort-Object) | Should -Be @('current')
  }
}

Describe 'ConvertTo-Hashtable (Windows PowerShell 5.1 has no ConvertFrom-Json -AsHashtable)' {
  It 'turns parsed JSON objects into hashtables, nested ones too, and keeps arrays and values' {
    $j = '{"a":{"Path":"/x","Used":5,"ToolCounts":{"Bash":2}},"b":{"List":[1,2],"Empty":{}}}' | ConvertFrom-Json
    $h = ConvertTo-Hashtable $j
    $h | Should -BeOfType [hashtable]
    $h.a | Should -BeOfType [hashtable]
    $h.a.Path | Should -Be '/x'
    $h.a.Used | Should -Be 5
    $h.a.ToolCounts | Should -BeOfType [hashtable]
    $h.a.ToolCounts.Bash | Should -Be 2
    @($h.b.List) | Should -Be @(1, 2)
    $h.b.Empty | Should -BeOfType [hashtable]
  }
}

Describe 'Update-Scan: what counts as a human prompt' {
  BeforeAll { $script:ScanVerified = @{}; $script:PriceVer = 2; $script:ScanVer = 2 }
  BeforeEach { $script:ScanCache = @{} }
  It 'counts a prompt that mentions tool_result as a turn, with its start and title' {
    $f = Join-Path $TestDrive 'p1.jsonl'
    Set-Content -LiteralPath $f -Value (@{ type = 'user'; sessionId = 'p1'; timestamp = '2026-10-31T05:19:00Z'; message = @{ role = 'user'; content = 'explain the tool_result field' } } | ConvertTo-Json -Compress -Depth 5)
    $st = Update-Scan (Get-Item -LiteralPath $f) 'p1'
    $st.Turns | Should -Be 1
    $st.TurnStart | Should -Not -BeNullOrEmpty
    $st.First | Should -Be 'explain the tool_result field'
  }
  It 'does not count a tool result as a turn' {
    $f = Join-Path $TestDrive 'p2.jsonl'
    $lines = @(
      (@{ type = 'user'; sessionId = 'p2'; timestamp = '2026-10-31T05:19:00Z'; message = @{ role = 'user'; content = 'list the files' } } | ConvertTo-Json -Compress -Depth 5)
      (@{ type = 'user'; sessionId = 'p2'; timestamp = '2026-10-31T05:19:05Z'; message = @{ role = 'user'; content = @(@{ type = 'tool_result'; tool_use_id = 't1'; content = 'a b c' }) } } | ConvertTo-Json -Compress -Depth 6)
    )
    Set-Content -LiteralPath $f -Value $lines
    (Update-Scan (Get-Item -LiteralPath $f) 'p2').Turns | Should -Be 1
  }
}

Describe 'Update-Scan: a transcript that is replaced, cut, or moves' {
  BeforeAll {
    $script:PriceVer = 2; $script:ScanVer = 2
    function Prompt([string]$text, [string]$ts = '2026-10-31T05:19:00Z') {
      @{ type = 'user'; sessionId = 's'; timestamp = $ts; message = @{ role = 'user'; content = $text } } | ConvertTo-Json -Compress -Depth 5
    }
    function Write-Lines([string]$path, [string[]]$lines, [datetime]$when) {
      [IO.File]::WriteAllText($path, (($lines -join "`n") + "`n"))
      [IO.File]::SetLastWriteTimeUtc($path, $when)
    }
  }
  BeforeEach { $script:ScanCache = @{}; $script:ScanVerified = @{} }

  It 'rescans a file replaced by one of the same length' {
    $f = Join-Path $TestDrive 'eq.jsonl'
    Write-Lines $f @(Prompt 'first prompt alpha') ([datetime]::UtcNow.AddMinutes(-2))
    (Update-Scan (Get-Item -LiteralPath $f) 'eq').First | Should -Be 'first prompt alpha'
    Write-Lines $f @(Prompt 'secnd prompt betaa') ([datetime]::UtcNow)   # same length, rewritten
    (Get-Item -LiteralPath $f).Length | Should -Be ([Text.Encoding]::UTF8.GetByteCount((Prompt 'first prompt alpha')) + 1)
    (Update-Scan (Get-Item -LiteralPath $f) 'eq').First | Should -Be 'secnd prompt betaa'
  }
  It 'rescans a file replaced by a longer one with a different start' {
    $f = Join-Path $TestDrive 'gt.jsonl'
    Write-Lines $f @(Prompt 'first prompt alpha') ([datetime]::UtcNow.AddMinutes(-2))
    Update-Scan (Get-Item -LiteralPath $f) 'gt' | Out-Null
    Write-Lines $f @((Prompt 'another opening' '2026-10-31T06:00:00Z'), (Prompt 'and more text here' '2026-10-31T06:01:00Z')) ([datetime]::UtcNow)
    $st = Update-Scan (Get-Item -LiteralPath $f) 'gt'
    $st.First | Should -Be 'another opening'
    $st.Turns | Should -Be 2
  }
  It 'keeps counting an appended file without rescanning it' {
    $f = Join-Path $TestDrive 'ap.jsonl'
    Write-Lines $f @(Prompt 'first message') ([datetime]::UtcNow.AddMinutes(-2))   # under 256 bytes: a short head
    $st1 = Update-Scan (Get-Item -LiteralPath $f) 'ap'
    [IO.File]::AppendAllText($f, (Prompt 'second message' '2026-10-31T05:20:00Z') + "`n")
    $st = Update-Scan (Get-Item -LiteralPath $f) 'ap'
    [object]::ReferenceEquals($st1, $st) | Should -BeTrue -Because 'an append continues the scan, it does not start over'
    $st.Turns | Should -Be 2
    $st.First | Should -Be 'first message'
  }
  It 'tells heads apart that differ only in letter case once encoded (Base64 is case-sensitive)' {
    $a = Join-Path $TestDrive 'ha.bin'; $z = Join-Path $TestDrive 'hz.bin'
    [IO.File]::WriteAllBytes($a, [Text.Encoding]::ASCII.GetBytes('ab@'))   # YWJA
    [IO.File]::WriteAllBytes($z, [Text.Encoding]::ASCII.GetBytes('abZ'))   # YWJa
    Get-HeadPrint $a | Should -BeExactly 'YWJA'
    Test-SameHead $z 'YWJA' | Should -BeFalse
    Test-SameHead $a 'YWJA' | Should -BeTrue
  }
  It 'rescans a grown file whose start changed only where the head print differs in case' {
    $f = Join-Path $TestDrive 'case.jsonl'
    # put an @ where its Base64 group differs from Z's only in the letter case of one character
    $pad = ''; while ((Prompt "$pad@ mark").IndexOf('@') % 3 -ne 2) { $pad += 'x' }
    Write-Lines $f @(Prompt "$pad@ mark") ([datetime]::UtcNow.AddMinutes(-2))
    (Update-Scan (Get-Item -LiteralPath $f) 'case').First | Should -Be "$pad@ mark"
    Write-Lines $f @((Prompt "${pad}Z mark"), (Prompt 'a second turn' '2026-10-31T05:20:00Z')) ([datetime]::UtcNow)
    $st = Update-Scan (Get-Item -LiteralPath $f) 'case'
    $st.First | Should -Be "${pad}Z mark"
    $st.Turns | Should -Be 2
  }
  It 'rescans a truncated file' {
    $f = Join-Path $TestDrive 'tr.jsonl'
    Write-Lines $f @((Prompt 'one'), (Prompt 'two')) ([datetime]::UtcNow.AddMinutes(-2))
    (Update-Scan (Get-Item -LiteralPath $f) 'tr').Turns | Should -Be 2
    Write-Lines $f @(Prompt 'one') ([datetime]::UtcNow)
    (Update-Scan (Get-Item -LiteralPath $f) 'tr').Turns | Should -Be 1
  }
  It 'starts over when the session''s transcript is now a different file' {
    $a = Join-Path $TestDrive 'mv-a.jsonl'; $b = Join-Path $TestDrive 'mv-b.jsonl'
    Write-Lines $a @(Prompt 'in the first directory') ([datetime]::UtcNow.AddMinutes(-2))
    Write-Lines $b @((Prompt 'in the second directory'), (Prompt 'still here')) ([datetime]::UtcNow)
    Update-Scan (Get-Item -LiteralPath $a) 'mv' | Out-Null
    $st = Update-Scan (Get-Item -LiteralPath $b) 'mv'
    $st.Path | Should -Be (Get-Item -LiteralPath $b).FullName
    $st.First | Should -Be 'in the second directory'
    $st.Turns | Should -Be 2
  }
  It 'does not read an unchanged file again' {
    $f = Join-Path $TestDrive 'un.jsonl'
    Write-Lines $f @(Prompt 'still the same') ([datetime]::UtcNow.AddMinutes(-2))
    $st1 = Update-Scan (Get-Item -LiteralPath $f) 'un'
    $off = $st1.Offset
    $st2 = Update-Scan (Get-Item -LiteralPath $f) 'un'
    [object]::ReferenceEquals($st1, $st2) | Should -BeTrue
    $st2.Offset | Should -Be $off
  }
}

Describe 'Get-LastAction: its tail cache' {
  BeforeAll {
    $script:PriceVer = 2; $script:ScanVer = 2
    function Reply([string]$text) {
      @{ type = 'assistant'; sessionId = 's'; timestamp = '2026-10-31T05:19:00Z'
         message = @{ role = 'assistant'; model = 'm'; content = @(@{ type = 'text'; text = $text }) } } | ConvertTo-Json -Compress -Depth 6
    }
  }
  BeforeEach { $script:ScanCache = @{}; $script:ScanVerified = @{}; $script:TailCache = @{} }
  It 'does not cut a character in half when it shortens LAST ACTION: <Name>' -ForEach @(
    @{ Name = 'a reply cut at 120';            Block = @{ type = 'text'; text = ('a' * 119) + [char]::ConvertFromUtf32(0x1F600) + 'tail' } }
    @{ Name = 'a command cut at 119';          Block = @{ type = 'tool_use'; id = 't1'; name = 'Bash'; input = @{ command = ('x' * 118) + [char]::ConvertFromUtf32(0x1F600) + ('y' * 20) } } }
    @{ Name = 'a path keeping its last 119';   Block = @{ type = 'tool_use'; id = 't2'; name = 'Read'; input = @{ file_path = '/' + ('x' * 10) + [char]::ConvertFromUtf32(0x1F600) + ('y' * 118) } } }
    @{ Name = 'a handback cut at 129';         Block = @{ type = 'tool_use'; id = 't3'; name = 'SubagentHandback'; input = @{ message = ('h' * 118) + [char]::ConvertFromUtf32(0x1F600) + ('z' * 20) } } }
  ) {
    $f = Join-Path $TestDrive "cut-$([guid]::NewGuid()).jsonl"
    $line = @{ type = 'assistant'; sessionId = 's'; timestamp = '2026-10-31T05:19:00Z'
               message = @{ role = 'assistant'; model = 'm'; content = @($Block) } } | ConvertTo-Json -Compress -Depth 8
    [IO.File]::WriteAllText($f, $line + "`n")
    $last = (Get-LastAction (Get-Item -LiteralPath $f) ([guid]::NewGuid().ToString())).Last
    $last | Should -Not -Be '-'
    $lone = $false
    for ($i = 0; $i -lt $last.Length; $i++) {
      if ([char]::IsHighSurrogate($last[$i])) { if ($i + 1 -ge $last.Length -or -not [char]::IsLowSurrogate($last[$i + 1])) { $lone = $true }; $i++ }
      elseif ([char]::IsLowSurrogate($last[$i])) { $lone = $true }
    }
    $lone | Should -BeFalse -Because "[$last]"
  }
  It 'reads the new transcript when a session''s transcript is another file of the same size and time' {
    $when = [datetime]::UtcNow.AddMinutes(-1)
    $a = Join-Path $TestDrive 'a.jsonl'; $b = Join-Path $TestDrive 'b.jsonl'
    [IO.File]::WriteAllText($a, (Reply 'alpha final') + "`n"); [IO.File]::SetLastWriteTimeUtc($a, $when)
    [IO.File]::WriteAllText($b, (Reply 'bravo final') + "`n"); [IO.File]::SetLastWriteTimeUtc($b, $when)
    (Get-LastAction (Get-Item -LiteralPath $a) 's').Last | Should -Be 'text: alpha final'
    (Get-LastAction (Get-Item -LiteralPath $b) 's').Last | Should -Be 'text: bravo final'
  }
}

Describe 'transcript identity is case-sensitive where the filesystem is' {
  BeforeDiscovery {
    # a case-sensitive filesystem holds a.x and A.x as two files (Linux); Windows and macOS by default do not
    $probe = Join-Path ([IO.Path]::GetTempPath()) "ctop-case-$PID"
    New-Item -ItemType Directory -Force -Path $probe | Out-Null
    [IO.File]::WriteAllText((Join-Path $probe 'a.x'), '1')
    $script:caseInsensitive = Test-Path -LiteralPath (Join-Path $probe 'A.x')
    Remove-Item -LiteralPath $probe -Recurse -Force
  }
  BeforeAll {
    $script:PriceVer = 2; $script:ScanVer = 2
    function Reply([string]$text) {
      @{ type = 'assistant'; sessionId = 's'; timestamp = '2026-10-31T05:19:00Z'
         message = @{ role = 'assistant'; model = 'm'; content = @(@{ type = 'text'; text = $text }) } } | ConvertTo-Json -Compress -Depth 6
    }
    function Prompt([string]$text) { @{ type = 'user'; sessionId = 's'; timestamp = '2026-10-31T05:19:00Z'; message = @{ role = 'user'; content = $text } } | ConvertTo-Json -Compress -Depth 5 }
  }
  BeforeEach { $script:ScanCache = @{}; $script:ScanVerified = @{}; $script:TailCache = @{} }
  It 'reads A.jsonl after a.jsonl of the same size and time as another file' -Skip:$script:caseInsensitive {
    $when = [datetime]::UtcNow.AddMinutes(-1)
    $lo = Join-Path $TestDrive 'c.jsonl'; $up = Join-Path $TestDrive 'C.jsonl'
    [IO.File]::WriteAllText($lo, (Reply 'alpha final') + "`n"); [IO.File]::SetLastWriteTimeUtc($lo, $when)
    [IO.File]::WriteAllText($up, (Reply 'bravo final') + "`n"); [IO.File]::SetLastWriteTimeUtc($up, $when)
    (Get-LastAction (Get-Item -LiteralPath $lo) 'k').Last | Should -Be 'text: alpha final'
    (Get-LastAction (Get-Item -LiteralPath $up) 'k').Last | Should -Be 'text: bravo final'
  }
  It 'starts the scan over when the transcript becomes a file whose name differs only in case' -Skip:$script:caseInsensitive {
    $lo = Join-Path $TestDrive 'd.jsonl'; $up = Join-Path $TestDrive 'D.jsonl'
    [IO.File]::WriteAllText($lo, (Prompt 'first prompt alpha') + "`n")
    [IO.File]::WriteAllText($up, (Prompt 'first prompt bravo') + "`n")
    (Update-Scan (Get-Item -LiteralPath $lo) 'k').First | Should -Be 'first prompt alpha'
    $st = Update-Scan (Get-Item -LiteralPath $up) 'k'
    $st.First | Should -Be 'first prompt bravo'
    $st.Path | Should -BeExactly $up
  }
}

Describe 'Get-LastAction: a question for you (AskUserQuestion)' {
  # The question's shape is the tool's own input schema: questions[] of question, header, options[] of
  # label/description, multiSelect. What an answer looks like is not assumed: any newer user entry (the
  # tool result) means it is no longer waiting.
  BeforeAll {
    $script:PriceVer = 2; $script:ScanVer = 2
    $ask = @{ type = 'tool_use'; id = 'toolu_q1'; name = 'AskUserQuestion'; input = @{ questions = @(
      @{ question = 'Which database should the tests use?'; header = 'Test DB'; multiSelect = $false
         options = @(@{ label = 'SQLite (Recommended)'; description = 'In memory, no setup' }, @{ label = 'Postgres'; description = 'Matches production' }) }
      @{ question = 'Which suites should run?'; header = 'Suites'; multiSelect = $true
         options = @(@{ label = 'unit'; description = 'fast' }, @{ label = 'integration'; description = 'needs tmux' }) }
    ) } }
    function Line($o) { $o | ConvertTo-Json -Compress -Depth 12 }
    function Write-T([string]$name, [object[]]$objs) {
      $f = Join-Path $TestDrive "$name.jsonl"
      [IO.File]::WriteAllLines($f, [string[]]@($objs | ForEach-Object { Line $_ }))
      Get-Item -LiteralPath $f
    }
    $asked = @{ type = 'assistant'; sessionId = 's'; timestamp = '2026-10-31T05:19:00Z'; message = @{ role = 'assistant'; model = 'm'; content = @($ask) } }
  }
  BeforeEach { $script:ScanCache = @{}; $script:ScanVerified = @{}; $script:TailCache = @{} }
  It 'shows the waiting question in LAST ACTION and keeps every question with its choices' {
    $a = Get-LastAction (Write-T 'pending' @($asked)) 'q1'
    $a.Last | Should -Be 'asks: Which database should the tests use? (+1 more)'
    @($a.Questions).Count | Should -Be 2
    $a.Questions[0].Text | Should -Be 'Which database should the tests use?'
    $a.Questions[0].Header | Should -Be 'Test DB'
    @($a.Questions[0].Options) | Should -Be @('SQLite (Recommended): In memory, no setup', 'Postgres: Matches production')
    $a.Questions[1].Multi | Should -BeTrue
  }
  It 'no longer shows it as waiting once a newer entry answers it' {
    $answer = @{ type = 'user'; sessionId = 's'; timestamp = '2026-10-31T05:20:00Z'; message = @{ role = 'user'; content = @(@{ type = 'tool_result'; tool_use_id = 'toolu_q1'; content = 'answered' }) } }
    $a = Get-LastAction (Write-T 'answered' @($asked, $answer)) 'q2'
    $a.Last | Should -Match '^asked: Which database'
    @($a.Questions).Count | Should -Be 0
  }
  It 'cleans control characters out of question text' {
    $evil = @{ type = 'assistant'; sessionId = 's'; message = @{ role = 'assistant'; model = 'm'; content = @(@{ type = 'tool_use'; id = 'toolu_q3'; name = 'AskUserQuestion'
               input = @{ questions = @(@{ question = "pick$([char]27)]52;c;eA==$([char]7) one"; header = 'h'; options = @(@{ label = "a$([char]10)b"; description = '' }) }) } }) } }
    $a = Get-LastAction (Write-T 'evil' @($evil)) 'q3'
    $a.Last | Should -Not -Match "[\x00-\x1F]"
    $a.Questions[0].Text | Should -Not -Match "[\x00-\x1F]"
    $a.Questions[0].Options[0] | Should -Not -Match "[\x00-\x1F]"
  }
}
