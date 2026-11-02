# CTOP_TRACE also records the errors ctop swallows ($ErrorActionPreference SilentlyContinue, empty catch
# blocks), so a real bug can be found instead of showing only as '-'.
BeforeAll {
  . (Join-Path $PSScriptRoot 'Import-Ctop.ps1')
  function Swallow([string]$text) { try { throw $text } catch {} }
  function Read-Trace { if (Test-Path -LiteralPath $env:CTOP_TRACE) { @(Get-Content -LiteralPath $env:CTOP_TRACE | Where-Object { $_ -match 'swallowed error' }) } else { @() } }
}

Describe 'Write-SwallowedErrors' {
  BeforeEach {
    $saved = $env:CTOP_TRACE
    $env:CTOP_TRACE = Join-Path $TestDrive ("trace-{0}.txt" -f [guid]::NewGuid())
    $script:ErrSeen = @{}
    $script:ErrMark = if ($Error.Count) { $Error[0] } else { $null }   # what was there before is not ctop's
  }
  AfterEach { $env:CTOP_TRACE = $saved }
  It 'writes a swallowed error to the trace, with its message' {
    Swallow 'disk said no'
    Write-SwallowedErrors
    $t = @(Read-Trace)
    $t.Count | Should -Be 1
    $t[0] | Should -Match 'swallowed error, line \d+: disk said no$'
  }
  It 'writes each error once, however often it happens, and numbers alone do not make it new' {
    Swallow 'no process 4242'; Swallow 'no process 4243'; Swallow 'no process 4242'
    Write-SwallowedErrors
    Swallow 'no process 77'
    Write-SwallowedErrors
    $t = @(Read-Trace)
    $t.Count | Should -Be 1
    $t[0] | Should -Match 'no process 4242$'
  }
  It 'writes only what is new since the last call, oldest first' {
    Swallow 'first'
    Write-SwallowedErrors
    Swallow 'second'; Swallow 'third'
    Write-SwallowedErrors
    Write-SwallowedErrors
    $t = @(Read-Trace)
    $t.Count | Should -Be 3
    $t[1] | Should -Match 'second$'
    $t[2] | Should -Match 'third$'
  }
  It 'leaves out errors from before ctop started' {
    Swallow 'from your own session'
    $script:ErrMark = $Error[0]
    Write-SwallowedErrors
    @(Read-Trace).Count | Should -Be 0
  }
  It 'writes nothing, and keeps nothing, without CTOP_TRACE' {
    $env:CTOP_TRACE = $null
    Swallow 'unseen'
    Write-SwallowedErrors
    $script:ErrSeen.Count | Should -Be 0
  }
  It 'keeps control characters out of the trace' {
    Swallow "two`nlines`e[31m"
    Write-SwallowedErrors
    @(Read-Trace)[0] | Should -Match 'two lines \[31m$'
  }
}
