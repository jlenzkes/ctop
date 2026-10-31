# Windows PowerShell 5.1 reads a .ps1 without a byte-order mark in the ANSI code page, so the non-ASCII
# characters ctop draws with (— … █ ▒ ∞) become other characters and the script stops parsing
# (about_Character_Encoding; PSScriptAnalyzer rule UseBOMForUnicodeEncodedFile). Every non-ASCII .ps1
# here must start with the UTF-8 BOM, whatever editor saved it last.
Describe 'file encoding' {
  It '<Name> starts with a UTF-8 BOM (it contains non-ASCII characters)' -ForEach @(
    Get-ChildItem -Path (Split-Path -Parent $PSScriptRoot) -Recurse -Include *.ps1, *.psd1 -File |
      Where-Object { [IO.File]::ReadAllBytes($_.FullName) | Where-Object { $_ -gt 127 } | Select-Object -First 1 } |
      ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
  ) {
    $b = [IO.File]::ReadAllBytes($Path)
    ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) | Should -BeTrue
  }
}
