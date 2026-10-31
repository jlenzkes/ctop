# Stopping a roster poll ends everything it started (Windows only: it needs cmd.exe and Win32_Process).
# Runs in both Windows CI jobs: PowerShell 7 takes Kill($true), Windows PowerShell 5.1 the parent-id walk.
BeforeDiscovery { $script:notWindows = [Environment]::OSVersion.Platform -ne 'Win32NT' }
BeforeAll { . (Join-Path $PSScriptRoot 'Import-Ctop.ps1') }

Describe 'Stop-RosterPoll' -Skip:$script:notWindows {
  BeforeAll {
    # a poll started the way Start-RosterPoll starts one, with any command line
    function Start-FakePoll([string]$cmdArgs) {
      $psi = [Diagnostics.ProcessStartInfo]::new('cmd.exe', $cmdArgs)
      $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
      $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
      $proc = [Diagnostics.Process]::Start($psi)
      @{ Proc = $proc; Out = $proc.StandardOutput.ReadToEndAsync(); Err = $proc.StandardError.ReadToEndAsync(); Started = [Diagnostics.Stopwatch]::StartNew() }
    }
    # the ping.exe processes started by $rootId: waits until there are $n of them (or 10 s)
    function Get-Kids([int]$rootId) { @(Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId = $rootId AND Name = 'PING.EXE'" | ForEach-Object { [int]$_.ProcessId }) }
    function Wait-Kids([int]$rootId, [int]$n) {
      $sw = [Diagnostics.Stopwatch]::StartNew()
      do { $k = Get-Kids $rootId; if ($k.Count -ge $n) { return $k }; Start-Sleep -Milliseconds 100 } while ($sw.Elapsed.TotalSeconds -lt 10)
      return $k
    }
    # whatever happened, leave nothing of this test running
    function Remove-Test([int]$rootId, [int[]]$kids) {
      @($rootId) + @($kids) + @(Get-Kids $rootId) | Select-Object -Unique | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }
    }
    function Get-Alive([int[]]$ids) { @($ids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue }) }
  }

  It 'ends a child that still holds the output open after its parent exited (the poll never completes)' {
    $p = Start-FakePoll '/d /c start /b ping -n 60 127.0.0.1'     # cmd starts ping (sharing its stdout) and exits
    $root = $p.Proc.Id; $kids = @()
    try {
      $kids = Wait-Kids $root 1
      $kids.Count | Should -Be 1
      $p.Proc.WaitForExit(5000) | Should -BeTrue
      $p.Out.IsCompleted | Should -BeFalse -Because 'ping still holds the pipe: the poll hangs'
      Stop-RosterPoll $p
      Start-Sleep -Milliseconds 500
      Get-Alive $kids | Should -BeNullOrEmpty
    } finally { Remove-Test $root $kids }
  }
  It 'ends a hung parent and its child together' {
    $p = Start-FakePoll '/d /c "start /b ping -n 60 127.0.0.1 & ping -n 60 127.0.0.1 >nul"'   # cmd waits on the second
    $root = $p.Proc.Id; $kids = @()
    try {
      $kids = Wait-Kids $root 2
      $kids.Count | Should -Be 2 -Because 'both pings must be running before the stop, or a clean result proves less'
      Stop-RosterPoll $p                 # it disposes the Process object: ask by pid from here on
      Start-Sleep -Milliseconds 500
      Get-Alive @($root) | Should -BeNullOrEmpty
      Get-Alive $kids | Should -BeNullOrEmpty
    } finally { Remove-Test $root $kids }
  }
}

# Runs everywhere: Win32_Process is mocked, so this is the walk's logic only.
Describe 'Get-ProcessDescendants (which processes a stopped poll takes with it)' {
  BeforeAll {
    $t0 = [datetime]'2026-10-31T12:00:00'
    function Proc([int]$id, [int]$parent, [double]$sec) { [pscustomobject]@{ ProcessId = $id; ParentProcessId = $parent; CreationDate = $t0.AddSeconds($sec) } }
    # Pester mocks only commands that exist; off Windows there is no Get-CimInstance
    if (-not (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) { function Get-CimInstance { param($ClassName, $Property, $Filter) } }
    function Ids($found) { @($found | ForEach-Object { if ($_ -is [int]) { $_ } else { $_.Id } }) }
  }
  It 'follows children and grandchildren started by the poll' {
    Mock Get-CimInstance { @((Proc 100 1 0), (Proc 200 100 5), (Proc 201 100 6), (Proc 300 200 7), (Proc 999 1 1)) }
    $d = Ids (Get-ProcessDescendants 100 $t0)
    ($d | Sort-Object) -join ',' | Should -Be '200,201,300'
  }
  It 'does not follow a process whose parent id names a different, later process (a reused pid)' {
    # 300 was started at T+2 by an earlier process 200, which exited; the poll's own child got pid 200 at T+5.
    # 300 is older than the current 200, so 200 cannot be its parent.
    Mock Get-CimInstance { @((Proc 100 1 0), (Proc 200 100 5), (Proc 300 200 2)) }
    $d = Ids (Get-ProcessDescendants 100 $t0)
    $d -join ',' | Should -Be '200'
  }
  It 'ignores a process older than the poll even when its parent id matches' {
    Mock Get-CimInstance { @((Proc 100 1 0), (Proc 200 100 -10)) }
    @(Get-ProcessDescendants 100 $t0).Count | Should -Be 0
  }
}
