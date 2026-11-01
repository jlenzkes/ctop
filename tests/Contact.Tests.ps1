# n / d: what is copied about a session so another Claude session can reach it.
BeforeAll { . (Join-Path $PSScriptRoot 'Import-Ctop.ps1') }

Describe 'Format-Contact' {
  BeforeAll {
    $uuid = '11111111-1111-4111-8111-111111111111'
    function Row([hashtable]$over) {
      $r = @{ NAME = 'api-worker'; KIND = 'interactive'; STATE = 'idle'; CWD = '/home/u/proj'; _SessionId = $uuid; _Parent = $null
              _Gone = $null; _Transcript = "/home/u/.claude/projects/-home-u-proj/$uuid.jsonl"
              _Src = [pscustomobject]@{ name = 'api-worker'; sessionId = $uuid; kind = 'interactive'; pid = 4242 } }
      foreach ($k in $over.Keys) { $r[$k] = $over[$k] }
      [pscustomobject]$r
    }
  }
  It 'gives a live session''s address, id, place and how to message it' {
    $t = Format-Contact (Row @{}) 'box1'
    $t | Should -Match '(?m)^Claude Code session$'
    $t | Should -Match '(?m)^Name: +api-worker +\(address: @api-worker\)$'
    $t | Should -Match "(?m)^Session ID: +$uuid$"
    $t | Should -Match '(?m)^Kind: +interactive$'
    $t | Should -Match '(?m)^State: +idle$'
    $t | Should -Match '(?m)^Directory: +/home/u/proj$'
    $t | Should -Match '(?m)^Machine: +box1$'
    $t | Should -Match '(?m)^Transcript: +/home/u/\.claude/projects/'
    $t | Should -Match 'message @api-worker'
    $t | Should -Not -Match 'claude attach'          # an interactive session lives in someone's terminal
  }
  It 'adds the attach command for a background session with a job id' {
    $r = Row @{ KIND = 'background'; _Src = [pscustomobject]@{ name = 'nightly'; sessionId = $uuid; kind = 'background'; id = 'bg7f3a'; pid = 1 }; NAME = 'nightly' }
    Format-Contact $r 'box1' | Should -Match '(?m)^Attach: +claude attach bg7f3a$'
  }
  It 'says a gone session is not running and gives its resume command instead of an address' {
    $t = Format-Contact (Row @{ _Gone = (Get-Date).AddMinutes(-5); STATE = 'gone 5m' }) 'box1'
    $t | Should -Match 'not running'
    $t | Should -Match "(?m)^Resume: +claude --resume $uuid$"
    $t | Should -Not -Match 'message @'
  }
  It 'has no address line for a session without a name' {
    $t = Format-Contact (Row @{ NAME = '-'; _Src = [pscustomobject]@{ sessionId = $uuid; kind = 'interactive' } }) 'box1'
    $t | Should -Match '(?m)^Name: +\(none\)'
    $t | Should -Not -Match '@'
    $t | Should -Match "(?m)^Session ID: +$uuid$"
  }
  It 'gives no address to an unnamed background session shown by its job id (the id is not a name)' {
    # Build-Rows shows an unnamed background session by its job id: NAME = id
    $r = Row @{ NAME = 'bg7f3a'; KIND = 'background'; _Src = [pscustomobject]@{ sessionId = $uuid; kind = 'background'; id = 'bg7f3a'; pid = 1 } }
    $t = Format-Contact $r 'box1'
    $t | Should -Not -Match '@'
    $t | Should -Match '(?m)^Name: +\(none\)'
    $t | Should -Match '(?m)^Attach: +claude attach bg7f3a$'
    $t | Should -Match '/rename'
  }
  It 'points a subagent at its parent session' {
    $parent = '22222222-2222-4222-8222-222222222222'
    $r = Row @{ NAME = '  └ Explore (a1b2c3d4)'; KIND = 'subagent'; STATE = 'working'; CWD = '-'; _Parent = $parent
                _SessionId = 'sub:/p/x/subagents/agent-a1b2c3d4e5f6.jsonl'; _Transcript = '/p/x/subagents/agent-a1b2c3d4e5f6.jsonl'; _Src = $null }
    $t = Format-Contact $r 'box1'
    $t | Should -Match '(?m)^Claude Code subagent$'
    $t | Should -Match '(?m)^Agent: +Explore \(a1b2c3d4\)$'
    $t | Should -Match '(?m)^Agent ID: +a1b2c3d4e5f6$'
    $t | Should -Match "(?m)^Parent session: +$parent$"
    $t | Should -Match 'through its parent session'
  }
  It 'removes control characters and escape sequences from session text' {
    $e = [char]27
    $t = Format-Contact (Row @{ NAME = "evil$e]52;c;cHduZWQ=$([char]7)"; CWD = "/tmp/a$e[2Jb" }) 'box1'
    $t | Should -Not -Match "[\x00-\x09\x0B-\x1F\x7F]"
    $t | Should -Not -Match 'cHduZWQ'                    # the OSC 52 payload goes with its sequence
  }
}

Describe 'Get-CopyId' {
  It 'gives a session''s full id' {
    $r = [pscustomobject]@{ _SessionId = '11111111-1111-4111-8111-111111111111'; _Parent = $null; _Transcript = '/p/11111111-1111-4111-8111-111111111111.jsonl' }
    (Get-CopyId $r).Text | Should -Be '11111111-1111-4111-8111-111111111111'
    (Get-CopyId $r).What | Should -Be 'session ID'
  }
  It 'gives a subagent''s agent id' {
    $r = [pscustomobject]@{ _SessionId = 'sub:/p/x/subagents/agent-a1b2c3d4e5f6.jsonl'; _Parent = '2'; _Transcript = '/p/x/subagents/agent-a1b2c3d4e5f6.jsonl' }
    (Get-CopyId $r).Text | Should -Be 'a1b2c3d4e5f6'
    (Get-CopyId $r).What | Should -Be 'agent ID'
  }
}
