# What ctop must not do to the files it watches, or to its own cache, when things go wrong.
BeforeAll {
  . (Join-Path $PSScriptRoot 'Import-Ctop.ps1')
  # Move-Over on Windows PowerShell 5.1 compiles ctop's C# helper (CtopCon) into the config dir. Not in
  # TestDrive, so a loaded DLL that stays locked until the process ends cannot keep Pester from deleting
  # TestDrive.
  $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path -Parent $PSScriptRoot) 'ctop.ps1'), [ref]$null, [ref]$null)
  $script:ConSrc = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:ConSrc' }, $true).Right.Expression.Value
  $script:ConfigDir = Join-Path ([IO.Path]::GetTempPath()) 'ctop-tests-con'; $ConfigDir = $script:ConfigDir
  New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
}

# First in the file: once CtopCon is loaded (Move-Over loads it on 5.1), Import-ConType returns before compiling.
Describe 'compiling the console helper' {
  It 'is compiled under a name of its own and renamed into place, never written straight into the shared DLL (Windows)' -Skip:(-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
    if ('CtopCon.Con' -as [type]) { Set-ItResult -Skipped -Because 'CtopCon is already loaded in this process'; return }
    $keep = $script:ConfigDir; $script:ConfigDir = Join-Path $TestDrive "cfg-$([guid]::NewGuid().ToString('N'))"; $ConfigDir = $script:ConfigDir
    New-Item -ItemType Directory -Path $ConfigDir | Out-Null
    try {
      Mock Add-Type { $script:CompiledTo = $OutputAssembly; throw 'no compiler here' } -ParameterFilter { $OutputAssembly }
      Mock Add-Type { throw 'no compiler here' } -ParameterFilter { -not $OutputAssembly }   # nor in memory (the fallback)
      Import-ConType | Should -BeFalse
      Should -Invoke Add-Type -Exactly 1 -ParameterFilter { -not $OutputAssembly }   # the fallback was tried
      # the leaf: it compiles from inside the folder, under a bare name (a full path would never equal it)
      Split-Path -Leaf $script:CompiledTo | Should -Not -Be (Split-Path -Leaf (Get-ConDllPath))
      Split-Path -Leaf $script:CompiledTo | Should -BeLike 'ctop-con-tmp-*.dll'
    } finally { $script:ConfigDir = $keep; $ConfigDir = $keep }
  }
  It 'compiles once, not three times, when the compile fails' {
    $d = Join-Path $TestDrive "dll-$([guid]::NewGuid().ToString('N'))"; New-Item -ItemType Directory -Path $d | Out-Null
    Mock Add-Type { throw 'no compiler here' } -ParameterFilter { $OutputAssembly }
    Import-HelperDll 'public class CtopNeverX { }' (Join-Path $d 'ctop-x-00000000-desktop.dll') 'ctop-x' 'CtopNeverX' | Should -BeFalse
    Should -Invoke Add-Type -Exactly 1 -ParameterFilter { $OutputAssembly }
  }
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
    $own = 'Get-Content -LiteralPath \$script:(ScanCachePath|ClosedLogPath)|ReadAllText\(\(Resolve-Path -LiteralPath \$path\)|ReadAllLines\(\$Path\)|ReadAllText\("/proc/|ReadAllBytes\(\$(dll|aside)\)|\[IO\.File\]::Open\(\$path, \[IO\.FileMode\]::Open, \[IO\.FileAccess\]::Read, \[IO\.FileShare\]''ReadWrite, Delete''\)'
    @($reads | Where-Object { $_ -notmatch $own }) | Should -BeNullOrEmpty -Because 'the scan cache, the closed log, a pricing file, /proc, a helper DLL, and Open-Shared itself are the only other reads'
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
    $ed = if ($PSVersionTable.PSEdition -eq 'Core') { "core$([Environment]::Version.Major)" } else { 'desktop' }
    Split-Path -Leaf (Get-ConDllPath) | Should -Match "^ctop-con-[0-9A-F]{8}-$ed\.dll$"
  }
  It 'deletes the old DLLs of this runtime, and leaves the other runtime''s' {
    $d = Join-Path $TestDrive "dll-$([guid]::NewGuid().ToString('N'))"; New-Item -ItemType Directory -Path $d | Out-Null
    foreach ($n in 'ctop-con-AAAAAAAA-core.dll', 'ctop-con-BBBBBBBB-core.dll', 'ctop-con-CCCCCCCC-desktop.dll', 'ctop-con-DDDDDDDD.dll', 'other.dll',
                   'ctop-con-tmp-1-old.dll', 'ctop-con-tmp-2-new.dll') {
      [IO.File]::WriteAllText((Join-Path $d $n), 'x')
    }
    (Get-Item -LiteralPath (Join-Path $d 'ctop-con-tmp-1-old.dll')).LastWriteTimeUtc = [datetime]::UtcNow.AddHours(-1)   # a killed compile
    Remove-OldConDlls (Join-Path $d 'ctop-con-AAAAAAAA-core.dll')
    @(Get-ChildItem -LiteralPath $d -Name | Sort-Object) | Should -Be @('ctop-con-AAAAAAAA-core.dll', 'ctop-con-CCCCCCCC-desktop.dll', 'ctop-con-tmp-2-new.dll', 'other.dll')
  }
  It 'loads on this runtime, so Move-Over renames in one step rather than falling back (Windows)' -Skip:(-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
    Import-ConType | Should -BeTrue
    [CtopCon.Fs].GetMethod('MoveOver') | Should -Not -BeNullOrEmpty
  }
}

# ctop.ps1 stands alone. With no config folder (a machine with only VS Code and Copilot has no
# ~/.claude), or in a snapshot, the console helper is compiled in memory rather than not loaded: the mouse works.
Describe 'the console helper with no config folder to keep it in' {
  BeforeAll {
    function InChild([string]$cfg, [string]$code) {
      $code = "`$ErrorActionPreference = 'Stop'; . '$(Join-Path $PSScriptRoot 'Import-Ctop.ps1')'; " +
              "`$ast = [System.Management.Automation.Language.Parser]::ParseFile('$(Join-Path (Split-Path -Parent $PSScriptRoot) 'ctop.ps1')', [ref]`$null, [ref]`$null); " +
              "`$script:ConSrc = `$ast.Find({ param(`$n) `$n -is [System.Management.Automation.Language.AssignmentStatementAst] -and `$n.Left.Extent.Text -eq '`$script:ConSrc' }, `$true).Right.Expression.Value; " +
              "`$ConfigDir = '$cfg'; $code"
      $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
      @(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $enc 2>&1 | ForEach-Object { "$_" })
    }
  }
  It 'loads it in memory when the config folder does not exist, and creates no folder (Windows)' -Skip:(-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
    $cfg = Join-Path $TestDrive "absent-$([guid]::NewGuid().ToString('N'))"
    $out = InChild $cfg "Import-ConType; [bool]('CtopCon.Con' -as [type]); [bool][CtopCon.Fs].GetMethod('MoveOver')"
    $out[0..2] | Should -Be @('True', 'True', 'True') -Because ($out -join "`n")
    Test-Path -LiteralPath $cfg | Should -BeFalse
  }
  It 'loads it in memory in a snapshot, and writes no DLL into the config folder (Windows)' -Skip:(-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
    $cfg = Join-Path $TestDrive "empty-$([guid]::NewGuid().ToString('N'))"; New-Item -ItemType Directory -Path $cfg | Out-Null
    $out = InChild $cfg "`$script:ReadOnly = `$true; Import-ConType; [bool]('CtopCon.Con' -as [type])"
    $out[0..1] | Should -Be @('True', 'True') -Because ($out -join "`n")
    @(Get-ChildItem -LiteralPath $cfg -Force).Count | Should -Be 0
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

# A ctop that reads a damaged helper DLL must not delete it by name: by then another ctop may have deleted it too
# and renamed a whole DLL into place, which would be deleted and, with no compiler, lost. The interposition here:
# right after the damaged bytes are read, the file is replaced by a whole DLL; no compiler.
Describe 'repairing a damaged helper DLL another ctop has replaced' {
  BeforeAll {
    $src = (Get-Command Import-HelperDll).ScriptBlock.ToString()
    if (-not $src.Contains('[IO.File]::ReadAllBytes($dll)')) { throw 'Import-HelperDll no longer reads its DLL at the hooked call' }
    $script:Hooked = [scriptblock]::Create($src.Replace('[IO.File]::ReadAllBytes($dll)', '(Read-AndReplace $dll)'))
  }
  BeforeEach {
    $script:d = Join-Path $TestDrive "r7b-$([guid]::NewGuid().ToString('N'))"; New-Item -ItemType Directory -Path $script:d | Out-Null
    $script:ns = 'R7b' + [guid]::NewGuid().ToString('N')
    $script:dll = Join-Path $script:d 'ctop-r7b-00000000-x.dll'
    $script:Reads = 0; $script:Compiles = 0
    [IO.File]::WriteAllText($script:dll, 'not a DLL')
  }
  It 'keeps the whole DLL put in place after the damaged one was read, and loads it, where nothing compiles' {
    $repl = Join-Path $script:d 'replacement.bin'
    Push-Location -LiteralPath $script:d
    try { Add-Type -TypeDefinition "namespace $($script:ns) { public class T { } }" -OutputAssembly 'replacement.bin' -OutputType Library } finally { Pop-Location }
    $want = [Convert]::ToBase64String([IO.File]::ReadAllBytes($repl))
    function Read-AndReplace($p) {
      $b = [IO.File]::ReadAllBytes($p)
      if (++$script:Reads -eq 1) { [IO.File]::Delete($p); [IO.File]::Move($repl, $p) }
      , $b
    }
    function Add-Type { $script:Compiles++ }   # no compiler
    & $script:Hooked 'class X { }' $script:dll 'ctop-r7b' "$($script:ns).T" | Should -BeTrue
    [IO.File]::Exists($script:dll) | Should -BeTrue -Because 'the replacement is kept'
    [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:dll)) | Should -Be $want
    $script:Compiles | Should -Be 0
    @(Get-ChildItem -LiteralPath $script:d -Name) | Should -Be @('ctop-r7b-00000000-x.dll') -Because 'nothing is left aside'
  }
  It 'deletes the damaged DLL it read, leaving nothing aside' {
    function Read-AndReplace($p) { $script:Reads++; , [IO.File]::ReadAllBytes($p) }
    function Add-Type { $script:Compiles++ }   # no compiler
    & $script:Hooked 'class X { }' $script:dll 'ctop-r7b' "$($script:ns).T" | Should -BeFalse
    @(Get-ChildItem -LiteralPath $script:d -Name) | Should -BeNullOrEmpty
    $script:Compiles | Should -Be 1
  }
}
