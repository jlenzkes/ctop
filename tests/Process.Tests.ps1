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
    # the ping.exe processes started by $rootId, once they are there
    function Wait-Kids([int]$rootId) {
      $sw = [Diagnostics.Stopwatch]::StartNew()
      do {
        $k = @(Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId = $rootId AND Name = 'PING.EXE'" | ForEach-Object { [int]$_.ProcessId })
        if ($k.Count) { return $k }
        Start-Sleep -Milliseconds 100
      } while ($sw.Elapsed.TotalSeconds -lt 10)
      return @()
    }
    function Get-Alive([int[]]$ids) { @($ids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue }) }
  }

  It 'ends a child that still holds the output open after its parent exited (the poll never completes)' {
    $p = Start-FakePoll '/d /c start /b ping -n 60 127.0.0.1'     # cmd starts ping (sharing its stdout) and exits
    $kids = Wait-Kids $p.Proc.Id
    try {
      $kids.Count | Should -BeGreaterThan 0
      $p.Proc.WaitForExit(5000) | Should -BeTrue
      $p.Out.IsCompleted | Should -BeFalse -Because 'ping still holds the pipe: the poll hangs'
      Stop-RosterPoll $p
      Start-Sleep -Milliseconds 500
      Get-Alive $kids | Should -BeNullOrEmpty
    } finally { $kids | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue } }
  }
  It 'ends a hung parent and its child together' {
    $p = Start-FakePoll '/d /c "start /b ping -n 60 127.0.0.1 & ping -n 60 127.0.0.1 >nul"'   # cmd waits on the second
    $kids = Wait-Kids $p.Proc.Id
    try {
      $kids.Count | Should -BeGreaterThan 0
      Stop-RosterPoll $p
      Start-Sleep -Milliseconds 500
      $p.Proc.HasExited | Should -BeTrue
      Get-Alive $kids | Should -BeNullOrEmpty
    } finally { $kids | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue } }
  }
}
