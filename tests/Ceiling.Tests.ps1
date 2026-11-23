# The auto-compact ceiling under CTX: the documented rule (code.claude.com/docs/en/model-config, "Default
# auto-compact thresholds" and "Set the auto-compact window", read 2026-11-13), from the model, the user's
# settings files and the environment ctop runs in.
BeforeAll {
  . (Join-Path $PSScriptRoot 'Import-Ctop.ps1')
  function Settings([string]$dir, [string]$json) {
    $null = New-Item -ItemType Directory -Force -Path $dir
    Set-Content -LiteralPath (Join-Path $dir 'settings.json') -Value $json -Encoding UTF8
  }
}

Describe 'Get-CompactCeiling' {
  BeforeEach {
    $script:CeilingCache = @{}
    $script:ClaudeHome = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
    $script:ManagedSettingsPath = Join-Path $TestDrive 'no-managed.json'
    $env:CLAUDE_CODE_AUTO_COMPACT_WINDOW = $null; $env:CLAUDE_CODE_DISABLE_1M_CONTEXT = $null
  }
  AfterEach { $env:CLAUDE_CODE_AUTO_COMPACT_WINDOW = $null; $env:CLAUDE_CODE_DISABLE_1M_CONTEXT = $null; Remove-Item -LiteralPath $script:ManagedSettingsPath -ErrorAction SilentlyContinue }

  It 'is about 967K by default on a native 1M model: <Model>' -ForEach @(
    @{ Model = 'claude-opus-5-5' }, @{ Model = 'claude-opus-4-7' }, @{ Model = 'claude-sonnet-5' }
    @{ Model = 'claude-haiku-5-5' }, @{ Model = 'claude-fable-5-2' }, @{ Model = 'claude-opus-4-8-20260101' }
  ) {
    $c = Get-CompactCeiling $Model '' 100
    $c.Tokens | Should -Be 967000
    $c.Source | Should -Match 'default'
  }
  # Mythos is Fable's counterpart, 1M context, by its short name and its full one
  It 'is about 967K on Mythos, by its short or full name: <Model>' -ForEach @(@{ Model = 'mythos-5-2' }, @{ Model = 'claude-mythos-5-2' }, @{ Model = 'claude-mythos-5-1' }) {
    (Get-CompactCeiling $Model '' 100).Tokens | Should -Be 967000
  }
  It 'takes the short model name ctop keeps (<Model>) as the Claude model' -ForEach @(@{ Model = 'opus-5-5' }, @{ Model = 'fable-5-2' }) {
    (Get-CompactCeiling $Model '' 100).Tokens | Should -Be 967000
  }
  It 'is 200K by default on <Model>' -ForEach @(@{ Model = 'claude-opus-4-6' }, @{ Model = 'claude-sonnet-4-6' }, @{ Model = 'claude-haiku-4-5-20251001' }) {
    (Get-CompactCeiling $Model '' 100).Tokens | Should -Be 200000
  }
  It 'takes a 4.6 model past 200K as running its [1m] variant' {
    (Get-CompactCeiling 'claude-opus-4-6' '' 350).Tokens | Should -Be 1000000
  }
  It 'is 200K on a native 1M model with CLAUDE_CODE_DISABLE_1M_CONTEXT=1' {
    $env:CLAUDE_CODE_DISABLE_1M_CONTEXT = '1'
    (Get-CompactCeiling 'claude-opus-5-5' '' 100).Tokens | Should -Be 200000
  }
  It 'takes the top-level autoCompactWindow from user settings' {
    Settings $script:ClaudeHome '{ "autoCompactWindow": 500000 }'
    $c = Get-CompactCeiling 'claude-opus-5-5' '' 100
    $c.Tokens | Should -Be 500000
    $c.Source | Should -Match 'autoCompactWindow'
  }
  It 'prefers the model''s own window to the top-level one in the same file' {
    Settings $script:ClaudeHome '{ "autoCompactWindow": 500000, "modelSettings": { "claude-opus-5-5": { "autoCompactWindow": 300000 } } }'
    (Get-CompactCeiling 'claude-opus-5-5-20260101' '' 100).Tokens | Should -Be 300000
    (Get-CompactCeiling 'claude-sonnet-5' '' 100).Tokens | Should -Be 500000
  }
  It 'treats "auto" as the default' {
    Settings $script:ClaudeHome '{ "modelSettings": { "claude-opus-5-5": { "autoCompactWindow": "auto" } } }'
    (Get-CompactCeiling 'claude-opus-5-5' '' 100).Tokens | Should -Be 967000
  }
  It 'lets a project''s settings outrank the user''s, and its local settings outrank both' {
    Settings $script:ClaudeHome '{ "autoCompactWindow": 500000 }'
    $proj = Join-Path $TestDrive ('p' + [guid]::NewGuid().ToString('n'))
    Settings (Join-Path $proj '.claude') '{ "autoCompactWindow": 400000 }'
    (Get-CompactCeiling 'claude-opus-5-5' $proj 100).Tokens | Should -Be 400000
    Set-Content -LiteralPath (Join-Path $proj '.claude/settings.local.json') -Value '{ "autoCompactWindow": 250000 }' -Encoding UTF8
    $script:CeilingCache = @{}
    (Get-CompactCeiling 'claude-opus-5-5' $proj 100).Tokens | Should -Be 250000
  }
  It 'lets the environment variable outrank every settings file: <Value>' -ForEach @(
    @{ Value = '200000'; Want = 200000 }, @{ Value = '300k'; Want = 300000 }, @{ Value = '1M'; Want = 1000000 }
  ) {
    # a window set to 1M is capped at the model's window (1M): it is not the 967K default
    Settings $script:ClaudeHome '{ "autoCompactWindow": 500000 }'
    $env:CLAUDE_CODE_AUTO_COMPACT_WINDOW = $Value
    (Get-CompactCeiling 'claude-opus-5-5' '' 100).Tokens | Should -Be $Want
  }
  It 'ignores an environment value that is no token count, and clamps one out of range (<Value>)' -ForEach @(
    @{ Value = 'lots'; Want = 967000 }, @{ Value = '200'; Want = 100000 }, @{ Value = '5000000'; Want = 1000000 }
  ) {
    $env:CLAUDE_CODE_AUTO_COMPACT_WINDOW = $Value
    (Get-CompactCeiling 'claude-opus-5-5' '' 100).Tokens | Should -Be $Want
  }
  It 'caps a window at the model''s context window' {
    Settings $script:ClaudeHome '{ "autoCompactWindow": 900000 }'
    (Get-CompactCeiling 'claude-opus-4-6' '' 100).Tokens | Should -Be 200000
  }
  It 'is none for a model that is not Claude, or no model' -ForEach @(@{ Model = 'gpt-5' }, @{ Model = '' }) {
    Get-CompactCeiling $Model '' 100 | Should -BeNullOrEmpty
  }
  # an explicit [1m] ID below 200K has its 1M window, and a 700K window on it is not capped at 200K
  It 'gives an explicit [1m] ID its 1M window below 200K: <Model>' -ForEach @(
    @{ Model = 'claude-opus-4-6[1m]' }, @{ Model = 'sonnet-4-6[1m]' }, @{ Model = 'claude-opus-4-6-20260101[1M]' }
  ) {
    $c = Get-CompactCeiling $Model '' 120
    $c.Tokens | Should -Be 1000000
    $c.Source | Should -Match '\[1m\]'
  }
  It 'caps a window set on an explicit [1m] ID at 1M, not 200K' {
    $env:CLAUDE_CODE_AUTO_COMPACT_WINDOW = '700000'
    (Get-CompactCeiling 'opus-4-6[1m]' '' 120).Tokens | Should -Be 700000
    (Get-CompactCeiling 'opus-4-6' '' 120).Tokens | Should -Be 200000   # without [1m] or context past 200K: 200K
  }
  It 'holds an explicit [1m] ID at 200K with CLAUDE_CODE_DISABLE_1M_CONTEXT=1' {
    $env:CLAUDE_CODE_DISABLE_1M_CONTEXT = '1'
    (Get-CompactCeiling 'opus-4-6[1m]' '' 120).Tokens | Should -Be 200000
  }
  It 'finds the model''s own window under its name without [1m]' {
    Settings $script:ClaudeHome '{ "modelSettings": { "claude-opus-4-6": { "autoCompactWindow": 600000 } } }'
    (Get-CompactCeiling 'opus-4-6[1m]' '' 120).Tokens | Should -Be 600000
  }
  # the two variables count in a settings file's env block too
  It 'reads CLAUDE_CODE_DISABLE_1M_CONTEXT and CLAUDE_CODE_AUTO_COMPACT_WINDOW from a settings file''s env block' {
    Settings $script:ClaudeHome '{ "env": { "CLAUDE_CODE_DISABLE_1M_CONTEXT": "1" } }'
    (Get-CompactCeiling 'fable-5-2' '' 120).Tokens | Should -Be 200000
    $script:CeilingCache = @{}
    Settings $script:ClaudeHome '{ "env": { "CLAUDE_CODE_DISABLE_1M_CONTEXT": "1", "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "150000" } }'
    $c = Get-CompactCeiling 'fable-5-2' '' 120
    $c.Tokens | Should -Be 150000
    $c.Source | Should -Match 'CLAUDE_CODE_AUTO_COMPACT_WINDOW.*settings\.json'
  }
  It 'lets the variable in an env block outrank autoCompactWindow, even a managed one (the variable outranks the setting)' {
    Set-Content -LiteralPath $script:ManagedSettingsPath -Value '{ "autoCompactWindow": 600000 }' -Encoding UTF8
    Settings $script:ClaudeHome '{ "env": { "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "450000" } }'
    (Get-CompactCeiling 'fable-5-2' '' 120).Tokens | Should -Be 450000
  }
  It 'takes a variable from the highest-precedence file that sets it: managed over project over user' {
    Settings $script:ClaudeHome '{ "env": { "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "450000" } }'
    $proj = Join-Path $TestDrive ('p' + [guid]::NewGuid().ToString('n'))
    Settings (Join-Path $proj '.claude') '{ "env": { "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "350000" } }'
    (Get-CompactCeiling 'fable-5-2' $proj 120).Tokens | Should -Be 350000
    Set-Content -LiteralPath $script:ManagedSettingsPath -Value '{ "env": { "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "250000" } }' -Encoding UTF8
    $script:CeilingCache = @{}
    (Get-CompactCeiling 'fable-5-2' $proj 120).Tokens | Should -Be 250000
  }
  It 'lets a settings file''s env block outrank ctop''s own environment, as Claude Code does with a shell export' {
    $env:CLAUDE_CODE_AUTO_COMPACT_WINDOW = '300000'
    Settings $script:ClaudeHome '{ "env": { "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "450000" } }'
    (Get-CompactCeiling 'fable-5-2' '' 120).Tokens | Should -Be 450000
    $script:CeilingCache = @{}
    Settings $script:ClaudeHome '{ "env": { "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "" } }'   # "" cancels the export
    (Get-CompactCeiling 'fable-5-2' '' 120).Tokens | Should -Be 967000
  }
  # a failed read must not store the file's new write time with no settings, or the file's settings are not
  # read again until its write time changes
  It 'reads a settings file again once a failed first read of it can succeed' {
    Settings $script:ClaudeHome '{ "autoCompactWindow": 450000 }'
    $script:FailRead = $true
    Mock Read-SharedText -ParameterFilter { $script:FailRead } { throw 'locked' }
    (Get-CompactCeiling 'fable-5-2' '' 120).Tokens | Should -Be 967000   # nothing read yet: the default
    $script:FailRead = $false
    foreach ($e in @($script:CeilingCache.Values)) { $e.At = [datetime]::UtcNow.AddSeconds(-10) }   # past the 5 s re-check
    (Get-CompactCeiling 'fable-5-2' '' 120).Tokens | Should -Be 450000
  }
  # a rewrite that keeps the write time is still read
  It 'reads a settings file again when its length changes under the same write time' {
    Settings $script:ClaudeHome '{"autoCompactWindow":450000}'
    $f = Join-Path $script:ClaudeHome 'settings.json'
    $t = (Get-Item -LiteralPath $f).LastWriteTimeUtc
    (Get-CompactCeiling 'fable-5-2' '' 120).Tokens | Should -Be 450000
    Settings $script:ClaudeHome '{ "autoCompactWindow": 250000 }'
    (Get-Item -LiteralPath $f).LastWriteTimeUtc = $t
    foreach ($e in @($script:CeilingCache.Values)) { $e.At = [datetime]::UtcNow.AddSeconds(-10) }
    (Get-CompactCeiling 'fable-5-2' '' 120).Tokens | Should -Be 250000
  }
  # while an editor rewrites the file, an empty or blank one is not a settings file that sets nothing: taken as
  # one, CTX would go from /600K to /967K, and that file's state would be kept as read
  It 'keeps the last good settings while a rewrite leaves the file <Case>, and reads the finished file' -ForEach @(
    @{ Case = 'empty'; Body = '' }, @{ Case = 'blank'; Body = "  `r`n " }, @{ Case = 'null'; Body = 'null' }, @{ Case = 'an array'; Body = '[]' }
    # PowerShell 7's ConvertFrom-Json hands back a one-object array's object, so these would be taken as
    # settings (and [{}] as settings that set nothing)
    @{ Case = 'an array of {}'; Body = '[{}]' }, @{ Case = 'an array of one settings object'; Body = '[{"autoCompactWindow":500000}]' }
    @{ Case = 'an array in an array'; Body = '[[{"autoCompactWindow":500000}]]' }, @{ Case = 'an array of two objects'; Body = '[{},{}]' }
    @{ Case = 'a number'; Body = '500000' }, @{ Case = 'a string'; Body = '"500000"' }, @{ Case = 'true'; Body = 'true' }
  ) {
    $f = Join-Path $script:ClaudeHome 'settings.json'
    Settings $script:ClaudeHome '{"autoCompactWindow":600000}'
    (Get-CompactCeiling 'fable-5-2' '' 120).Tokens | Should -Be 600000
    $held = [IO.File]::Open($f, 'Truncate', 'Write', 'ReadWrite')   # the writer has the file open, as an editor saving it
    try {
      $b = [Text.Encoding]::UTF8.GetBytes($Body); $held.Write($b, 0, $b.Length); $held.Flush()
      [IO.File]::SetLastWriteTimeUtc($f, [datetime]::UtcNow.AddSeconds(10))
      foreach ($e in @($script:CeilingCache.Values)) { $e.At = [datetime]::UtcNow.AddSeconds(-10) }
      $gen = $script:CeilingGen
      (Get-CompactCeiling 'fable-5-2' '' 120).Tokens | Should -Be 600000
      $script:CeilingGen | Should -Be $gen -Because 'nothing new was read'
      $held.Position = 0
      $b = [Text.Encoding]::UTF8.GetBytes('{"autoCompactWindow":450000}'); $held.Write($b, 0, $b.Length); $held.SetLength($b.Length); $held.Flush()
    } finally { $held.Dispose() }
    foreach ($e in @($script:CeilingCache.Values)) { $e.At = [datetime]::UtcNow.AddSeconds(-10) }
    (Get-CompactCeiling 'fable-5-2' '' 120).Tokens | Should -Be 450000
  }
  # a rejected file must not be taken as read, or a valid one of its length and write time is not
  It 'reads a settings file again after a rejected root, even when the fixed file keeps its length and write time (<Case>)' -ForEach @(
    @{ Case = 'an array of one settings object'; Body = '[{"autoCompactWindow":500000}]' }, @{ Case = 'an array of {}'; Body = '[{}]' }
  ) {
    $f = Join-Path $script:ClaudeHome 'settings.json'
    Settings $script:ClaudeHome '{"autoCompactWindow":600000}'
    (Get-CompactCeiling 'fable-5-2' '' 120).Tokens | Should -Be 600000
    $t = [datetime]::UtcNow.AddSeconds(10)
    $Body = $Body.PadRight(28)   # at least as long as the fixed file below, which is padded to its length
    [IO.File]::WriteAllText($f, $Body); [IO.File]::SetLastWriteTimeUtc($f, $t)
    foreach ($e in @($script:CeilingCache.Values)) { $e.At = [datetime]::UtcNow.AddSeconds(-10) }
    $gen = $script:CeilingGen
    (Get-CompactCeiling 'fable-5-2' '' 120).Tokens | Should -Be 600000
    $script:CeilingGen | Should -Be $gen -Because 'nothing new was read'
    [IO.File]::WriteAllText($f, '{"autoCompactWindow":450000}'.PadRight($Body.Length)); [IO.File]::SetLastWriteTimeUtc($f, $t)
    foreach ($e in @($script:CeilingCache.Values)) { $e.At = [datetime]::UtcNow.AddSeconds(-10) }
    (Get-CompactCeiling 'fable-5-2' '' 120).Tokens | Should -Be 450000
  }
  It 'starts from no settings when the file is blank at its first read, and reads it once it is written' {
    $f = Join-Path $script:ClaudeHome 'settings.json'
    Settings $script:ClaudeHome '{}'
    [IO.File]::WriteAllText($f, '')
    (Get-CompactCeiling 'fable-5-2' '' 120).Tokens | Should -Be 967000
    [IO.File]::WriteAllText($f, '{"autoCompactWindow":450000}')
    [IO.File]::SetLastWriteTimeUtc($f, [datetime]::UtcNow.AddSeconds(10))
    foreach ($e in @($script:CeilingCache.Values)) { $e.At = [datetime]::UtcNow.AddSeconds(-10) }
    (Get-CompactCeiling 'fable-5-2' '' 120).Tokens | Should -Be 450000
  }
  It 'takes a complete {} as settings that set nothing, and a deleted file as none' {
    $f = Join-Path $script:ClaudeHome 'settings.json'
    Settings $script:ClaudeHome '{"autoCompactWindow":600000}'
    (Get-CompactCeiling 'fable-5-2' '' 120).Tokens | Should -Be 600000
    [IO.File]::WriteAllText($f, '{}')
    [IO.File]::SetLastWriteTimeUtc($f, [datetime]::UtcNow.AddSeconds(10))
    foreach ($e in @($script:CeilingCache.Values)) { $e.At = [datetime]::UtcNow.AddSeconds(-10) }
    (Get-CompactCeiling 'fable-5-2' '' 120).Tokens | Should -Be 967000
    Settings $script:ClaudeHome '{"autoCompactWindow":600000}'
    [IO.File]::SetLastWriteTimeUtc($f, [datetime]::UtcNow.AddSeconds(20))
    foreach ($e in @($script:CeilingCache.Values)) { $e.At = [datetime]::UtcNow.AddSeconds(-10) }
    (Get-CompactCeiling 'fable-5-2' '' 120).Tokens | Should -Be 600000
    Remove-Item -LiteralPath $f
    foreach ($e in @($script:CeilingCache.Values)) { $e.At = [datetime]::UtcNow.AddSeconds(-10) }
    (Get-CompactCeiling 'fable-5-2' '' 120).Tokens | Should -Be 967000
  }
}

Describe 'Format-Ceiling' {
  It 'is <Want> for <Tokens> tokens' -ForEach @(
    @{ Tokens = 967000; Want = '/967K' }, @{ Tokens = 200000; Want = '/200K' }, @{ Tokens = 1000000; Want = '/1M' }
    @{ Tokens = 250000; Want = '/250K' }
    # 999,500 to 999,999 round to /1M, not /1000K: six characters in CTX's five
    @{ Tokens = 999500; Want = '/1M' }, @{ Tokens = 999999; Want = '/1M' }, @{ Tokens = 999499; Want = '/999K' }
  ) {
    Format-Ceiling $Tokens | Should -Be $Want
  }
}

Describe 'CTX''s second line' {
  BeforeEach {
    $script:CeilingCache = @{}; $script:RowCache = @{}
    $script:ClaudeHome = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
    $script:ManagedSettingsPath = Join-Path $TestDrive ('managed-' + [guid]::NewGuid().ToString('n') + '.json')
    $script:Color = $false
  }
  It 'shows the ceiling under the context size on a Claude Code row' {
    $cols = @([pscustomobject]@{ Name = 'CTX'; Width = 5; Align = 'R'; Fixed = 5 })
    $r = [pscustomobject]@{ CTX = '806K'; VIA = 'vscode'; _Act = @{ Model = 'claude-opus-5-5'; Ctx = 806; Cwd = '' } }
    $lines = Format-Row $cols $r '  ' 2
    $lines.Count | Should -Be 2
    $lines[0].Trim() | Should -Be '806K'
    $lines[1].Trim() | Should -Be '/967K'
  }
  It 'shows none on a <Via> row' -ForEach @(@{ Via = 'copilot' }, @{ Via = 'cline' }) {
    $cols = @([pscustomobject]@{ Name = 'CTX'; Width = 5; Align = 'R'; Fixed = 5 })
    $r = [pscustomobject]@{ CTX = '80K'; VIA = $Via; _Act = @{ Model = 'claude-opus-5-5'; Ctx = 80; Cwd = '' } }
    @(Format-Row $cols $r '  ' 2).Count | Should -Be 1
  }
  # the formatted row's cache key holds the ceiling, or a row would keep /600K after a change to 450K
  It 'formats the row again when the ceiling changes, under the same cache signature' {
    $script:RowCache = @{}
    Set-Content -LiteralPath $script:ManagedSettingsPath -Value '{ "autoCompactWindow": 600000 }' -Encoding UTF8
    $cols = @([pscustomobject]@{ Name = 'CTX'; Width = 5; Align = 'R'; Fixed = 5 })
    $r = [pscustomobject]@{ CTX = '120K'; VIA = 'cli'; _Act = @{ Model = 'fable-5-2'; Ctx = 120; Cwd = '' } }
    (Get-RowLines $cols $r '  ' 2 'same')[1].Trim() | Should -Be '/600K'
    Set-Content -LiteralPath $script:ManagedSettingsPath -Value '{ "autoCompactWindow": 450000 }' -Encoding UTF8
    $script:CeilingCache = @{}
    (Get-RowLines $cols $r '  ' 2 'same')[1].Trim() | Should -Be '/450K'
  }
  It 'redraws a table row whose lines it kept when a settings file changes' {
    $script:Columns = @(@{ Name = 'NAME'; Fixed = 0; Min = 6; Flex = 1; Align = 'L'; Priority = 100 }, @{ Name = 'CTX'; Fixed = 5; Align = 'R'; Priority = 80 })
    $script:HighWater = @{}; $script:AutoWidth = @{}; $script:HiddenCols = @(); $script:Layouts = @('wrap'); $script:LayoutMode = 0; $script:Compact = $false
    $script:FixedSize = @{ W = 60; H = 20 }; $WrapLines = 2; $MaxWidth = 0
    $settings = Join-Path $script:ClaudeHome 'settings.json'
    Settings $script:ClaudeHome '{ "autoCompactWindow": 600000 }'
    $r = [pscustomobject]@{ NAME = 'a'; CTX = '120K'; VIA = 'cli'; _Act = @{ Model = 'fable-5-2'; Ctx = 120; Cwd = '' }; _Dirty = $true; _Lines = $null; _LinesSig = $null; _Widths = $null }
    ((Render-Table @($r) '') -join "`n") | Should -Match '/600K'
    Set-Content -LiteralPath $settings -Value '{ "autoCompactWindow": 450000 }' -Encoding UTF8
    (Get-Item -LiteralPath $settings).LastWriteTimeUtc = [datetime]::UtcNow.AddSeconds(5)   # a later write time
    foreach ($e in @($script:CeilingCache.Values)) { if ($e -is [hashtable] -and $e.ContainsKey('At')) { $e.At = [datetime]::UtcNow.AddSeconds(-10) } }   # past the 5 s re-check
    ((Render-Table @($r) '') -join "`n") | Should -Match '/450K'
    $script:FixedSize = $null
  }
  # from /600K, a change to 450K read while the file is locked must not show /967K, nor keep it after the lock
  # goes until the file's write time changes again
  It 'shows the new ceiling once a changed settings file that could not be read can be' {
    $script:Columns = @(@{ Name = 'NAME'; Fixed = 0; Min = 6; Flex = 1; Align = 'L'; Priority = 100 }, @{ Name = 'CTX'; Fixed = 5; Align = 'R'; Priority = 80 })
    $script:HighWater = @{}; $script:AutoWidth = @{}; $script:HiddenCols = @(); $script:Layouts = @('wrap'); $script:LayoutMode = 0; $script:Compact = $false
    $script:FixedSize = @{ W = 60; H = 20 }; $WrapLines = 2; $MaxWidth = 0
    $settings = Join-Path $script:ClaudeHome 'settings.json'
    Settings $script:ClaudeHome '{ "autoCompactWindow": 600000 }'
    $r = [pscustomobject]@{ NAME = 'a'; CTX = '120K'; VIA = 'cli'; _Act = @{ Model = 'fable-5-2'; Ctx = 120; Cwd = '' }; _Dirty = $true; _Lines = $null; _LinesSig = $null; _Widths = $null }
    ((Render-Table @($r) '') -join "`n") | Should -Match '/600K'
    Set-Content -LiteralPath $settings -Value '{ "autoCompactWindow": 450000 }' -Encoding UTF8
    (Get-Item -LiteralPath $settings).LastWriteTimeUtc = [datetime]::UtcNow.AddSeconds(5)
    $script:FailRead = $true
    Mock Read-SharedText -ParameterFilter { $script:FailRead } { throw 'locked' }
    foreach ($e in @($script:CeilingCache.Values)) { $e.At = [datetime]::UtcNow.AddSeconds(-10) }
    ((Render-Table @($r) '') -join "`n") | Should -Match '/600K'   # the last settings read, while the new ones can't be
    $script:FailRead = $false
    foreach ($e in @($script:CeilingCache.Values)) { $e.At = [datetime]::UtcNow.AddSeconds(-10) }
    ((Render-Table @($r) '') -join "`n") | Should -Match '/450K'
    $script:FixedSize = $null
  }
  # the row's CWD, not the transcript's cwd as written (Git Bash: /c/dev/x, or none yet): the row's is the
  # normalized one, or the registry's
  It 'looks for project settings in the row''s CWD: <Case>' -ForEach @(
    @{ Case = 'the transcript has no cwd yet'; Act = ''; Shown = 'proj' }
    @{ Case = 'the transcript''s cwd is in another form (Git Bash)'; Act = '/x/not-this-form'; Shown = 'proj' }
    @{ Case = 'the row shows no CWD'; Act = 'proj'; Shown = '-' }
  ) {
    $proj = Join-Path $TestDrive ('p' + [guid]::NewGuid().ToString('n'))
    Settings (Join-Path $proj '.claude') '{ "autoCompactWindow": 400000 }'
    $r = [pscustomobject]@{ CTX = '120K'; VIA = 'cli'; CWD = $(if ($Shown -eq 'proj') { $proj } else { $Shown }); _Act = @{ Model = 'fable-5-2'; Ctx = 120; Cwd = $(if ($Act -eq 'proj') { $proj } else { $Act }) } }
    (Get-RowCeiling $r).Tokens | Should -Be 400000
  }
  It 'says in the hover box where the ceiling comes from' {
    $r = [pscustomobject]@{ NAME = 'a'; CTX = '806K'; VIA = 'cli'; _Act = @{ Model = 'claude-opus-5-5'; Ctx = 806; Cwd = '' } }
    (Get-HoverParts $r 'CTX').Value | Should -Match '^806K tokens in context; compacts at about 967K \(Claude Code''s default'
  }
}
