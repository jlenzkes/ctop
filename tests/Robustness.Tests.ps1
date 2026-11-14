# What ctop must not do to the files it watches, or to its own cache, when things go wrong.
BeforeAll {
  . (Join-Path $PSScriptRoot 'Import-Ctop.ps1')
  # Move-Over on Windows PowerShell 5.1 compiles ctop's C# helper (CtopCon) into the config dir. Not in
  # TestDrive: the loaded DLL stays locked until the process ends, and Pester could not delete TestDrive.
  $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path -Parent $PSScriptRoot) 'ctop.ps1'), [ref]$null, [ref]$null)
  $script:ConSrc = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:ConSrc' }, $true).Right.Expression.Value
  $script:ConfigDir = Join-Path ([IO.Path]::GetTempPath()) 'ctop-tests-con'; $ConfigDir = $script:ConfigDir
  New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
}

Describe 'files other programs write are opened sharing delete' {
  BeforeEach { $script:f = Join-Path $TestDrive "f-$([guid]::NewGuid().ToString('N')).json"; [IO.File]::WriteAllText($script:f, "ref: refs/heads/main`nmore") }
  It 'lets another program delete a file ctop holds open' {
    $fs = Open-Shared $script:f
    try {
      { [IO.File]::Delete($script:f) } | Should -Not -Throw
    } finally { $fs.Dispose() }
    Test-Path -LiteralPath $script:f | Should -BeFalse
  }
  # ReplaceFile (File.Replace) and git succeed against a file held this way (measured 2026-11-13). Node's
  # fs.rename (EPERM) and MoveFileEx with REPLACE_EXISTING (.NET File.Move overwrite, Python os.replace) do
  # not: Windows refuses those over any open file, whatever it shares.
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
  It 'finds a line holding a string, reading through Open-Shared' {
    Test-SharedContains $script:f 'heads/main' | Should -BeTrue
    Test-SharedContains $script:f 'heads/other' | Should -BeFalse
  }
  It 'finds nothing in a file that is gone, rather than throwing (Get-Spawner has no catch)' {
    { Test-SharedContains (Join-Path $TestDrive 'gone.jsonl') 'x' } | Should -Not -Throw
    Test-SharedContains (Join-Path $TestDrive 'gone.jsonl') 'x' | Should -BeFalse
  }
  It 'opens other programs'' files only through Open-Shared (every other read is of ctop''s own files)' {
    $lines = Get-Content (Join-Path (Split-Path -Parent $PSScriptRoot) 'ctop.ps1') | Where-Object { $_ -notmatch '^\s*#' }
    $reads = @($lines | Where-Object { $_ -match 'Get-Content\b|(^|[\s(|;{])gc\s+[-$''"]|Select-String\b|\bsls\s|ReadAll(Text|Lines|Bytes)\(|OpenRead\(|\[IO\.File\]::Open\(|StreamReader\]::new\(\$(path|file)' })
    $own = 'Get-Content -LiteralPath \$script:(ScanCachePath|ClosedLogPath)|ReadAllText\(\(Resolve-Path -LiteralPath \$path\)|ReadAllLines\(\$Path\)|ReadAllText\("/proc/|\[IO\.File\]::Open\(\$path, \[IO\.FileMode\]::Open, \[IO\.FileAccess\]::Read, \[IO\.FileShare\]''ReadWrite, Delete''\)'
    @($reads | Where-Object { $_ -notmatch $own }) | Should -BeNullOrEmpty -Because 'the scan cache, the closed log, a pricing file, /proc, and Open-Shared itself are the only other reads'
  }
}

Describe 'Move-Over' {
  BeforeEach {
    $script:src = Join-Path $TestDrive "s-$([guid]::NewGuid().ToString('N'))"; $script:dst = "$($script:src).dst"
    [IO.File]::WriteAllText($script:src, 'new')
  }
  It 'creates the target' {
    Move-Over $script:src $script:dst
    [IO.File]::ReadAllText($script:dst) | Should -Be 'new'
    Test-Path -LiteralPath $script:src | Should -BeFalse
  }
  It 'replaces the target' {
    [IO.File]::WriteAllText($script:dst, 'old')
    Move-Over $script:src $script:dst
    [IO.File]::ReadAllText($script:dst) | Should -Be 'new'
  }
  It 'throws, and leaves the target as it was, when the target is held open (Windows)' -Skip:(-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
    [IO.File]::WriteAllText($script:dst, 'old')
    $fs = [IO.File]::Open($script:dst, 'Open', 'Read', 'Read')
    try { { Move-Over $script:src $script:dst } | Should -Throw } finally { $fs.Dispose() }
    [IO.File]::ReadAllText($script:dst) | Should -Be 'old'
  }
  # Tells the one-step rename from File.Replace by behaviour: ReplaceFile succeeds over a file held with
  # delete sharing (as Open-Shared holds it), MoveFileEx with replace-existing does not (measured 2026-11-13).
  # So a Move-Over that fell back to File.Replace on this runtime would succeed here.
  It 'renames in one step on this runtime, not through File.Replace (Windows)' -Skip:(-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
    [IO.File]::WriteAllText($script:dst, 'old')
    $fs = Open-Shared $script:dst
    try { { Move-Over $script:src $script:dst } | Should -Throw } finally { $fs.Dispose() }
    [IO.File]::ReadAllText($script:dst) | Should -Be 'old'
  }
  It 'replaces through MoveFileEx, as on Windows PowerShell 5.1 (Windows)' -Skip:(-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path -Parent $PSScriptRoot) 'ctop.ps1'), [ref]$null, [ref]$null)
    $assign = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:ConSrc' }, $true)
    $csrc = $assign.Right.Expression.Value
    if (-not ('CtopConFsTest.Fs' -as [type])) { Add-Type -TypeDefinition ($csrc -replace 'namespace CtopCon', 'namespace CtopConFsTest') }
    [IO.File]::WriteAllText($script:dst, 'old')
    [CtopConFsTest.Fs]::MoveOver($script:src, $script:dst) | Should -BeTrue
    [IO.File]::ReadAllText($script:dst) | Should -Be 'new'
  }
}

Describe 'Load-ScanCache' {
  It 'clears what killed saves left before reading' {
    $script:ScanCachePath = Join-Path $TestDrive 'none.json'
    Mock Remove-StaleCacheTemps { } -Verifiable
    Load-ScanCache
    Should -InvokeVerifiable
  }
}

Describe 'the console helper DLL' {
  It 'is named by the runtime as well as the source (a DLL PowerShell 7 compiled does not load in 5.1)' {
    $ed = if ($PSVersionTable.PSEdition -eq 'Core') { 'core' } else { 'desktop' }
    Split-Path -Leaf (Get-ConDllPath) | Should -Match "^ctop-con-[0-9A-F]{8}-$ed\.dll$"
  }
  It 'deletes the old DLLs of this runtime, and leaves the other runtime''s' {
    $d = Join-Path $TestDrive "dll-$([guid]::NewGuid().ToString('N'))"; New-Item -ItemType Directory -Path $d | Out-Null
    foreach ($n in 'ctop-con-AAAAAAAA-core.dll', 'ctop-con-BBBBBBBB-core.dll', 'ctop-con-CCCCCCCC-desktop.dll', 'ctop-con-DDDDDDDD.dll', 'other.dll') {
      [IO.File]::WriteAllText((Join-Path $d $n), 'x')
    }
    Remove-OldConDlls (Join-Path $d 'ctop-con-AAAAAAAA-core.dll')
    @(Get-ChildItem -LiteralPath $d -Name | Sort-Object) | Should -Be @('ctop-con-AAAAAAAA-core.dll', 'ctop-con-CCCCCCCC-desktop.dll', 'other.dll')
  }
  It 'loads on this runtime, so Move-Over renames in one step rather than falling back (Windows)' -Skip:(-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
    Import-ConType | Should -BeTrue
    [CtopCon.Fs].GetMethod('MoveOver') | Should -Not -BeNullOrEmpty
  }
}

Describe 'Remove-StaleCacheTemps' {
  BeforeEach {
    $script:dir = Join-Path $TestDrive "c-$([guid]::NewGuid().ToString('N'))"; New-Item -ItemType Directory -Path $script:dir | Out-Null
    $script:ScanCachePath = Join-Path $script:dir 'ctop-scancache.json'
    [IO.File]::WriteAllText($script:ScanCachePath, '{}')
  }
  It 'deletes what a killed save left, and keeps a live ctop''s save and other files' {
    $alivePid = if ($IsWindows -or $env:OS -eq 'Windows_NT') { 4 } else { 1 }   # System / init: always running
    foreach ($n in 'ctop-scancache.json.999999999.tmp', 'ctop-scancache.json~RF2a4f.TMP', "ctop-scancache.json.$alivePid.tmp", 'ctop-scancache.json.bak', 'other.tmp') {
      [IO.File]::WriteAllText((Join-Path $script:dir $n), 'x')
    }
    Remove-StaleCacheTemps
    @(Get-ChildItem -LiteralPath $script:dir -Name | Sort-Object) | Should -Be @('ctop-scancache.json', "ctop-scancache.json.$alivePid.tmp", 'ctop-scancache.json.bak', 'other.tmp')
  }
  It 'deletes a live ctop''s save once it is a day old' {
    $alivePid = if ($IsWindows -or $env:OS -eq 'Windows_NT') { 4 } else { 1 }
    $f = Join-Path $script:dir "ctop-scancache.json.$alivePid.tmp"; [IO.File]::WriteAllText($f, 'x')
    (Get-Item -LiteralPath $f).LastWriteTimeUtc = [datetime]::UtcNow.AddDays(-2)
    Remove-StaleCacheTemps
    Test-Path -LiteralPath $f | Should -BeFalse
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
  It 'saves through one rename (Move-Over), not File.Replace, which is several steps a kill can split' {
    Mock Move-Over { [IO.File]::Copy($src, $dst, $true) } -Verifiable
    Save-ScanCache
    Should -InvokeVerifiable
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
