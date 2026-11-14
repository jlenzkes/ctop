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
  AfterEach { $env:CLAUDE_CODE_AUTO_COMPACT_WINDOW = $null; $env:CLAUDE_CODE_DISABLE_1M_CONTEXT = $null }

  It 'is about 967K by default on a native 1M model: <Model>' -ForEach @(
    @{ Model = 'claude-opus-5-5' }, @{ Model = 'claude-opus-4-7' }, @{ Model = 'claude-sonnet-5' }
    @{ Model = 'claude-haiku-5-5' }, @{ Model = 'claude-fable-5-2' }, @{ Model = 'claude-opus-4-8-20260101' }
  ) {
    $c = Get-CompactCeiling $Model '' 100
    $c.Tokens | Should -Be 967000
    $c.Source | Should -Match 'default'
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
}

Describe 'Format-Ceiling' {
  It 'is <Want> for <Tokens> tokens' -ForEach @(
    @{ Tokens = 967000; Want = '/967K' }, @{ Tokens = 200000; Want = '/200K' }, @{ Tokens = 1000000; Want = '/1M' }
    @{ Tokens = 250000; Want = '/250K' }
  ) {
    Format-Ceiling $Tokens | Should -Be $Want
  }
}

Describe 'CTX''s second line' {
  BeforeEach {
    $script:CeilingCache = @{}
    $script:ClaudeHome = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
    $script:ManagedSettingsPath = Join-Path $TestDrive 'no-managed.json'
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
  It 'says in the hover box where the ceiling comes from' {
    $r = [pscustomobject]@{ NAME = 'a'; CTX = '806K'; VIA = 'cli'; _Act = @{ Model = 'claude-opus-5-5'; Ctx = 806; Cwd = '' } }
    (Get-HoverParts $r 'CTX').Value | Should -Match '^806K tokens in context; compacts at about 967K \(Claude Code''s default'
  }
}
