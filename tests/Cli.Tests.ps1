# The command line: what ctop accepts and refuses. Runs ctop as a process; no terminal needed.
Describe 'the command line' {
  BeforeAll {
    $ctop = Join-Path (Split-Path -Parent $PSScriptRoot) 'ctop.ps1'
    $onWindows = $IsWindows -or $env:OS -eq 'Windows_NT'
    # run ctop with these arguments, input from nothing, and give back exit code and all output (bounded)
    function Invoke-Ctop([string[]]$argv) {
      $psi = [Diagnostics.ProcessStartInfo]::new()
      $psi.FileName = (Get-Process -Id $PID).Path
      $quoted = @($argv | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } })
      $psi.Arguments = '-NoProfile -NonInteractive ' + $(if ($onWindows) { '-ExecutionPolicy Bypass ' }) + "-File `"$ctop`" " + ($quoted -join ' ')
      $psi.UseShellExecute = $false; $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
      $p = [Diagnostics.Process]::Start($psi)
      $p.StandardInput.Close()
      $out = $p.StandardOutput.ReadToEndAsync(); $err = $p.StandardError.ReadToEndAsync()
      if (-not $p.WaitForExit(30000)) { try { $p.Kill() } catch {}; throw "ctop $($argv -join ' ') did not exit within 30 s" }
      $p.WaitForExit()
      @{ Code = $p.ExitCode; Text = ($out.Result + $err.Result) }
    }
  }
  It 'refuses <Name>, naming it, and starts nothing' -ForEach @(
    @{ Name = 'a misspelled flag';   Argv = @('-Snapshott');       Says = 'Snapshott' }
    @{ Name = 'a flag it lacks';     Argv = @('-Bogus');           Says = 'Bogus' }
    @{ Name = 'a stray word';        Argv = @('foo');              Says = 'foo' }
    @{ Name = 'a bare number (no flag names it: it set -Tick)'; Argv = @('500'); Says = '500' }
    @{ Name = 'a -HighlightModel that is not a regular expression'; Argv = @('-Version', '-HighlightModel', '['); Says = 'HighlightModel' }
    @{ Name = 'a -SelectBg that is not an SGR code'; Argv = @('-Version', '-SelectBg', '1m;31'); Says = 'SelectBg' }
  ) {
    $x = Invoke-Ctop $Argv
    $x.Code | Should -Not -Be 0
    $x.Text | Should -Match $Says
    $x.Text | Should -Not -Match "\x1b\[(2J|H|\?25l)" -Because 'it must not start drawing (clear screen, cursor home, hide cursor)'
  }
  It 'accepts -Sort cache' {
    $x = Invoke-Ctop @('-Version', '-Sort', 'cache')
    $x.Code | Should -Be 0 -Because $x.Text
  }
  It 'names the same build in -Version, .NOTES and the newest CHANGELOG.md entry' {
    $r = Invoke-Ctop @('-Version')
    ($r.Text.Trim() -match '^ctop (\d{4}\.\d{2}\.\d{2}\.\d+)$') | Should -BeTrue -Because $r.Text
    $v = $Matches[1]   # (plain -match: Should -Match leaves $Matches unset here)
    ((Get-Content -Raw $ctop) -cmatch 'VERSION (\d{4}\.\d{2}\.\d{2}\.\d+)') | Should -BeTrue
    $Matches[1] | Should -Be $v
    $first = Get-Content (Join-Path (Split-Path -Parent $ctop) 'CHANGELOG.md') | Where-Object { $_ -match '^## ' } | Select-Object -First 1
    $first | Should -Match ('^## ' + [regex]::Escape($v) + '(\s|$)')
  }
  It 'still runs a correct command line (-Version)' {
    $x = Invoke-Ctop @('-Version')
    $x.Code | Should -Be 0
    $x.Text | Should -Match '^ctop \d{4}\.\d{2}\.\d{2}\.\d+'
  }
}
