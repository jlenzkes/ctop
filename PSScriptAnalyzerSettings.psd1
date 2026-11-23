# Settings for Invoke-ScriptAnalyzer, used by CI and for local runs:
#   Invoke-ScriptAnalyzer -Path ./ctop.ps1 -Settings ./PSScriptAnalyzerSettings.psd1
@{
  # CI fails on errors only. Warnings (unapproved verbs, Write-Host, etc.) are reported locally
  # but not enforced: ctop is a single interactive script, not a module.
  Severity = @('Error')
}
