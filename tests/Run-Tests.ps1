# Runs the Pester suite the way CI does, and holds each job to the coverage it claims:
#   -Integration Expect : the integration tests must run here, none skipped (a missing tmux fails the run)
#   -Integration Skip   : leave them out (Windows, images without tmux)
# Prints how many ran, failed and were skipped, by kind. Needs Pester 5.9.1.
param([ValidateSet('Expect', 'Skip')][string]$Integration = 'Expect')

Import-Module Pester -RequiredVersion 5.9.1 -ErrorAction Stop
$c = New-PesterConfiguration
$c.Run.Path = Join-Path $PSScriptRoot '.'
$c.Run.PassThru = $true
$c.Output.Verbosity = 'Detailed'
if ($Integration -eq 'Skip') { $c.Filter.ExcludeTag = 'Integration' }
$r = Invoke-Pester -Configuration $c

# by file: the Integration tag sits on the Describe blocks, not on each test
$it = @($r.Tests | Where-Object { $_.ScriptBlock.File -like '*Integration.Tests.ps1' })
$unit = @($r.Tests | Where-Object { $_.ScriptBlock.File -notlike '*Integration.Tests.ps1' })
function Count($tests, [string]$result) { @($tests | Where-Object { $_.Result -eq $result }).Count }
Write-Host ''
Write-Host ("unit:        {0} passed, {1} failed, {2} skipped" -f (Count $unit 'Passed'), (Count $unit 'Failed'), (Count $unit 'Skipped'))
Write-Host ("integration: {0} passed, {1} failed, {2} skipped, {3} not run   (expected: {4})" -f (Count $it 'Passed'), (Count $it 'Failed'), (Count $it 'Skipped'), (Count $it 'NotRun'), $Integration)

$problems = @()
if ($r.FailedCount -gt 0 -or $r.FailedBlocksCount -gt 0 -or $r.FailedContainersCount -gt 0) { $problems += "$($r.FailedCount) test(s) failed" }
if ((Count $unit 'Passed') -eq 0) { $problems += 'no unit test ran' }
if ($Integration -eq 'Expect') {
  if ((Count $it 'Passed') -eq 0) { $problems += 'no integration test ran, though this job expects them' }
  if ((Count $it 'Skipped') -gt 0) { $problems += "$((Count $it 'Skipped')) integration test(s) skipped, though this job expects them (is tmux installed?)" }
}
if ($problems) { $problems | ForEach-Object { Write-Host "FAIL: $_" -ForegroundColor Red }; exit 1 }
