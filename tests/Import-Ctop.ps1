# Defines ctop.ps1's top-level functions in the caller's scope WITHOUT running the script: no parameter
# binding, no `claude` lookup, no main loop. Test files dot-source it in BeforeAll:
#   BeforeAll { . (Join-Path $PSScriptRoot 'Import-Ctop.ps1') }
$ctopPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'ctop.ps1'
$parseErrors = $null
$ctopAst = [System.Management.Automation.Language.Parser]::ParseFile($ctopPath, [ref]$null, [ref]$parseErrors)
if ($parseErrors) { throw "ctop.ps1 does not parse: $($parseErrors[0].Message) (line $($parseErrors[0].Extent.StartLineNumber))" }
# $false: don't descend into script blocks, so only top-level definitions are found
foreach ($def in $ctopAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
  . ([scriptblock]::Create($def.Extent.Text))
}
