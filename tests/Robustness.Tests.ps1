# What ctop must not do to the files it watches, or to its own cache, when things go wrong.
BeforeAll { . (Join-Path $PSScriptRoot 'Import-Ctop.ps1') }

Describe 'files other programs write are opened sharing delete' {
  BeforeEach { $script:f = Join-Path $TestDrive "f-$([guid]::NewGuid().ToString('N')).json"; [IO.File]::WriteAllText($script:f, "ref: refs/heads/main`nmore") }
  It 'lets another program delete a file ctop holds open' {
    $fs = Open-Shared $script:f
    try {
      { [IO.File]::Delete($script:f) } | Should -Not -Throw
    } finally { $fs.Dispose() }
    Test-Path -LiteralPath $script:f | Should -BeFalse
  }
  It 'lets another program rename a file over one ctop holds open (as git does with HEAD)' {
    $new = "$($script:f).lock"; [IO.File]::WriteAllText($new, 'ref: refs/heads/other')
    $fs = Open-Shared $script:f
    try {
      { [IO.File]::Replace($new, $script:f, [NullString]::Value) } | Should -Not -Throw
    } finally { $fs.Dispose() }
    [IO.File]::ReadAllText($script:f) | Should -Be 'ref: refs/heads/other'
  }
  It 'reads the whole text, or the first line' {
    Read-SharedText $script:f | Should -Be "ref: refs/heads/main`nmore"
    Read-SharedText $script:f -FirstLine | Should -Be 'ref: refs/heads/main'
  }
  It 'opens files only through Open-Shared' {
    $src = Get-Content -Raw (Join-Path (Split-Path -Parent $PSScriptRoot) 'ctop.ps1')
    ([regex]::Matches($src, '\[IO\.File\]::Open\(')).Count | Should -Be 1 -Because 'the one inside Open-Shared'
  }
}

Describe 'Save-ScanCache' {
  BeforeEach {
    $script:ScanCachePath = Join-Path $TestDrive "cache-$([guid]::NewGuid().ToString('N')).json"
    $script:CacheDays = 2
    $now = (Get-Date).ToUniversalTime().Ticks
    $script:ScanCache = @{ a = @{ Path = '/a.jsonl'; Used = $now } }
  }
  It 'writes a cache that reads back, and leaves no temporary file' {
    Save-ScanCache
    (Get-Content -Raw $script:ScanCachePath | ConvertFrom-Json).a.Path | Should -Be '/a.jsonl'
    @(Get-ChildItem -LiteralPath $TestDrive -Filter '*.tmp').Count | Should -Be 0
  }
  It 'replaces an existing cache (PowerShell passes $null to .NET as an empty string)' {
    [IO.File]::WriteAllText($script:ScanCachePath, '{"old":{"Path":"/old.jsonl"}}')
    Save-ScanCache
    $c = Get-Content -Raw $script:ScanCachePath | ConvertFrom-Json
    $c.a.Path | Should -Be '/a.jsonl'
    $c.old | Should -BeNullOrEmpty
  }
  It 'leaves the old cache whole when the write dies half-way' {
    [IO.File]::WriteAllText($script:ScanCachePath, '{"old":{"Path":"/old.jsonl"}}')
    Mock Set-Content { [IO.File]::WriteAllText($LiteralPath, '{"a":{"Pa'); throw 'killed mid-write' }
    Save-ScanCache
    Get-Content -Raw $script:ScanCachePath | Should -Be '{"old":{"Path":"/old.jsonl"}}'
    @(Get-ChildItem -LiteralPath $TestDrive -Filter '*.tmp').Count | Should -Be 0
  }
}
