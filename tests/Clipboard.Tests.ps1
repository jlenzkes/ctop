# t / y copy: how text reaches a clipboard on each platform. PowerShell's Set-Clipboard on Linux needs
# xclip and a display; without them it keeps the text inside the pwsh process (PowerShell 7.6.9,
# Clipboard.cs: _internalClipboard) and reports success, so ctop sends OSC 52 to the terminal instead.
BeforeAll { . (Join-Path $PSScriptRoot 'Import-Ctop.ps1') }

Describe 'Get-ClipboardPlan' {
  It 'uses Set-Clipboard alone on Windows' {
    Get-ClipboardPlan -OnWindows $true -Display '' -HasXclip $false | Should -Be @('native')
  }
  It 'sends OSC 52 with no display (SSH, containers), even when xclip is installed' {
    Get-ClipboardPlan -OnWindows $false -Display '' -HasXclip $true | Should -Be @('osc52')
  }
  It 'sends OSC 52 with a display but no xclip (Set-Clipboard would only keep it in-process)' {
    Get-ClipboardPlan -OnWindows $false -Display ':0' -HasXclip $false | Should -Be @('osc52')
  }
  It 'uses xclip (through Set-Clipboard) and OSC 52 with a display and xclip' {
    Get-ClipboardPlan -OnWindows $false -Display ':0' -HasXclip $true | Should -Be @('xclip', 'osc52')
  }
}

Describe 'Format-Osc52' {
  It 'wraps base64 of the UTF-8 text as ESC ] 52 ; c ; … BEL' {
    Format-Osc52 'hi' | Should -BeExactly "$([char]27)]52;c;aGk=$([char]7)"
  }
  It 'encodes non-ASCII as UTF-8' {
    Format-Osc52 'café' | Should -BeExactly "$([char]27)]52;c;Y2Fmw6k=$([char]7)"
  }
}

Describe 'Format-CopyFlash' {
  It 'says copied when the system clipboard was set' {
    Format-CopyFlash 'resume command' @('native') | Should -BeExactly 'copied resume command to clipboard'
  }
  It 'does not claim success for OSC 52, which the terminal may ignore' {
    Format-CopyFlash 'resume command' @('osc52') | Should -BeExactly 'sent resume command to the terminal clipboard (OSC 52; needs terminal support)'
  }
  It 'names both when both were used' {
    Format-CopyFlash 'transcript path' @('xclip', 'osc52') | Should -BeExactly 'copied transcript path to clipboard (xclip) and sent it to the terminal (OSC 52)'
  }
}
