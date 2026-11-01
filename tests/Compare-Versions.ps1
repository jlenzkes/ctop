# A/B: the same inputs through two versions of ctop, side by side: a base (a git ref, by default main,
# or a .ps1 file) and the ctop.ps1 in this checkout. Each check is a yes/no property of what ctop does,
# not a timing threshold. Prints a table; exits 1 if THIS checkout's ctop fails a check (the base's results
# are for comparison only). Linux (or WSL), with tmux; on a private tmux server, so your own sessions are
# left alone. About two minutes.
#   ./tests/Compare-Versions.ps1                 # against main
#   ./tests/Compare-Versions.ps1 -Base ce70e6d   # against a commit
#   ./tests/Compare-Versions.ps1 -Base ./old-ctop.ps1
param([string]$Base = 'main')
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$pwsh = (Get-Process -Id $PID).Path
$tmuxExe = (Get-Command tmux -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $tmuxExe -or $IsWindows) { Write-Error 'needs tmux, on Linux or WSL'; exit 2 }
$sock = "ctop-ab-$PID"
function tmux { & $tmuxExe -L $sock @args }
$work = Join-Path ([IO.Path]::GetTempPath()) "ctop-ab-$PID"; New-Item -ItemType Directory -Force -Path $work | Out-Null
$sid = '11111111-1111-4111-8111-111111111111'
$results = [Collections.Generic.List[object]]::new()
function Record($check, $which, $ver, $ok, $detail) { $results.Add([pscustomobject]@{ Check = $check; Which = $which; Version = $ver; Holds = [bool]$ok; Detail = $detail }) }

# the base version, as a file
if (Test-Path -LiteralPath $Base -PathType Leaf) { $basePath = (Resolve-Path -LiteralPath $Base).ProviderPath }
else {
  $basePath = Join-Path $work 'base-ctop.ps1'
  & sh -c "git -C '$repo' show '${Base}:ctop.ps1' > '$basePath'"
  if ($LASTEXITCODE) { Write-Error "cannot read ctop.ps1 at '$Base' (in a shallow clone: git fetch --depth=1 origin main, then -Base FETCH_HEAD)"; exit 2 }
}
$current = Join-Path $repo 'ctop.ps1'

# a config dir + fake claude reporting one live session (pid: this process)
function New-Fx([string]$name) {
  $root = Join-Path $work $name; $cfg = Join-Path $root 'cfg'; $bin = Join-Path $root 'bin'
  New-Item -ItemType Directory -Force -Path $bin, (Join-Path $cfg 'projects/-w') | Out-Null
  $start = [DateTimeOffset]::UtcNow.AddHours(-1).ToUnixTimeMilliseconds()
  $roster = '[{"sessionId":"' + $sid + '","name":"live-one","kind":"interactive","cwd":"/w","pid":' + $PID + ',"startedAt":' + $start + ',"status":"idle"}]'
  [IO.File]::WriteAllText((Join-Path $bin 'claude'), "#!/bin/sh`necho '$roster'`n"); & chmod +x (Join-Path $bin 'claude')
  $t = Join-Path $cfg "projects/-w/$sid.jsonl"
  $reply = @{ type = 'assistant'; sessionId = $sid; timestamp = [DateTime]::UtcNow.ToString('o'); message = @{ role = 'assistant'; model = 'claude-sonnet-5-5'; usage = @{ input_tokens = 1000; output_tokens = 1000 }; content = @(@{ type = 'text'; text = 'done' }) } }
  [IO.File]::WriteAllText($t, ($reply | ConvertTo-Json -Compress -Depth 8) + "`n")
  [IO.File]::WriteAllText((Join-Path $root 'closed.jsonl'), '')
  @{ Root = $root; Cfg = $cfg; Transcript = $t; Env = "CLAUDE_CONFIG_DIR='$cfg' PATH='${bin}:$env:PATH'"; Log = (Join-Path $root 'closed.jsonl') }
}
$n = 0
function Start-In([string]$script, $fx) {
  $script:n++; $s = "ab$script:n"
  tmux new-session -d -s $s -x 200 -y 50 'sleep 600'
  tmux resize-window -t $s -x 200 -y 50 2>$null
  tmux respawn-pane -k -t $s "$($fx.Env) '$pwsh' -NoProfile -File '$script' -ClosedLog '$($fx.Log)' -NoColor; echo CTOP-EXITED `$?; sleep 600"
  return $s
}
function Screen($s) { (tmux capture-pane -p -t $s) -join "`n" }
function Wait-For($s, [string]$rx, [double]$sec) { $sw = [Diagnostics.Stopwatch]::StartNew(); while ($sw.Elapsed.TotalSeconds -lt $sec) { if ((Screen $s) -match $rx) { return $sw.Elapsed.TotalSeconds }; Start-Sleep -Milliseconds 100 }; $null }

try {
  foreach ($v in @(@{ Name = 'base'; Path = $basePath }, @{ Name = 'current'; Path = $current })) {
    $ver = (& $pwsh -NoProfile -File $v.Path -Version)
    Write-Host "  checking $($v.Name): $ver"

    # A. reading a transcript hangs forever (it is a FIFO nobody writes: opening it never returns).
    #    Does q still quit? Nothing here depends on speed: the hang is unbounded.
    $fx = New-Fx "A-$($v.Name)"; Remove-Item $fx.Transcript; & mkfifo $fx.Transcript
    $s = Start-In $v.Path $fx
    Start-Sleep -Seconds 4
    tmux send-keys -t $s q
    $t = Wait-For $s 'CTOP-EXITED 0' 20
    Record 'A. q quits while reading a transcript hangs forever' $v.Name $ver ($null -ne $t) $(if ($null -ne $t) { 'exited 0 after {0:N1} s' -f $t } else { 'still running 20 s after q' })
    # release whatever is blocked on the FIFO: a read-write open never blocks, and is the writer it waits for
    try { [IO.File]::Open($fx.Transcript, 'Open', 'ReadWrite', 'ReadWrite').Dispose() } catch {}
    tmux kill-session -t $s

    # B. one frame as text, output to a pipe
    $fx = New-Fx "B-$($v.Name)"
    $out = & sh -c "$($fx.Env) '$pwsh' -NoProfile -File '$($v.Path)' -ClosedLog '$($fx.Log)' -Snapshot -MaxWidth 160 </dev/null 2>&1; echo EXIT=`$?"
    $text = ($out -join "`n")
    Record 'B. -Snapshot prints the session to a pipe' $v.Name $ver ($text -match '(?m)^live-one ' -and $text -match 'EXIT=0') ((($out | Select-Object -Last 2) -join ' | ') -replace '\s+', ' ')

    # C. a question waiting on you
    $fx = New-Fx "C-$($v.Name)"
    $ask = @{ type = 'assistant'; sessionId = $sid; timestamp = [DateTime]::UtcNow.ToString('o'); message = @{ role = 'assistant'; model = 'claude-sonnet-5-5'; content = @(@{ type = 'tool_use'; id = 'toolu_q'; name = 'AskUserQuestion'; input = @{ questions = @(@{ question = 'Which database?'; header = 'DB'; multiSelect = $false; options = @(@{ label = 'SQLite'; description = 'fast' }) }) } }) } }
    [IO.File]::AppendAllText($fx.Transcript, ($ask | ConvertTo-Json -Compress -Depth 12) + "`n")
    $s = Start-In $v.Path $fx
    $row = if (Wait-For $s '(?m)^live-one ' 30) { ((Screen $s) -split "`n" | Where-Object { $_ -match '^live-one ' } | Select-Object -First 1) } else { '' }
    Record 'C. the table shows the question waiting on you' $v.Name $ver ($row -match 'asks: Which database\?') ([regex]::Match($row, '(idle|working)\s+.*?\s{2,}(\S.{0,40})').Groups[2].Value.Trim())
    tmux kill-session -t $s

    # D. n copies a contact (OSC 52 into the terminal's clipboard; tmux keeps it as a paste buffer)
    $fx = New-Fx "D-$($v.Name)"
    tmux new-session -d -s "hold$($v.Name)" 'sleep 600'; tmux set-option -g set-clipboard on
    while (tmux list-buffers 2>$null) { tmux delete-buffer 2>$null }
    $s = Start-In $v.Path $fx
    $null = Wait-For $s '(?m)^live-one ' 30
    tmux send-keys -t $s Home n; Start-Sleep -Seconds 2
    $buf = ((tmux list-buffers -F '#{buffer_name}' 2>$null) | ForEach-Object { (tmux show-buffer -b $_) -join "`n" }) -join "`n---`n"
    Record 'D. n copies a contact with the session''s @address' $v.Name $ver ($buf -match '@live-one') $(if ($buf) { ($buf -split "`n")[0] } else { 'nothing copied' })
    tmux kill-session -t $s; tmux kill-session -t "hold$($v.Name)"

    # E. the scan cache loads when priced by a pricing file (a version that is not a number); functions
    #    loaded from the version under test, nothing of it run
    $probe = @'
param($file, $cache)
$ast = [Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
foreach ($f in $ast.FindAll({ param($x) $x -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) { . ([scriptblock]::Create($f.Extent.Text)) }
$script:ScanCache = @{}; $script:ScanCachePath = $cache; $script:CacheDays = 2; $script:PriceVer = 'file-0123456789abcdef'; $script:ScanVer = 4
$e = @{ Path = '/x.jsonl'; Head = 'AAAA'; Used = (Get-Date).ToUniversalTime().Ticks; PriceVer = 'file-0123456789abcdef'; ScanVer = 4; ToolCounts = @{}; Cost = 1.5 }
[IO.File]::WriteAllText($cache, (@{ k1 = $e; k2 = $e.Clone() } | ConvertTo-Json -Depth 5))
Load-ScanCache
$script:ScanCache.Count
'@
    $pf = Join-Path $work "probe-$($v.Name).ps1"; Set-Content -LiteralPath $pf -Value $probe
    $kept = & $pwsh -NoProfile -File $pf $v.Path (Join-Path $work "cache-$($v.Name).json")
    Record 'E. a scan cache priced by a pricing file loads' $v.Name $ver ("$kept" -eq '2') "$kept of 2 entries kept"

    # F. -PricingFile sets the cost (1000 in + 1000 out at $4 / $20 per million = $0.024, shown $0.02)
    $fx = New-Fx "F-$($v.Name)"; $prices = Join-Path $fx.Root 'p.json'
    [IO.File]::WriteAllText($prices, '[{"Match":"sonnet-5-5","In":4,"W5":5,"W1h":8,"Read":0.2,"Out":20}]')
    $out = & sh -c "$($fx.Env) '$pwsh' -NoProfile -File '$($v.Path)' -ClosedLog '$($fx.Log)' -Snapshot -MaxWidth 400 -PricingFile '$prices' </dev/null 2>&1; echo EXIT=`$?"
    $row = ($out | Where-Object { $_ -match '^live-one ' } | Select-Object -First 1)
    Record 'F. -PricingFile prices with the file''s rates' $v.Name $ver ("$row" -match '\$0\.02\b') $(if ($row) { ([regex]::Match($row, '\$[\d.]+')).Value } else { (($out | Select-Object -First 1) -replace '\s+', ' ') })

    # G. a misspelled flag is refused, not ignored
    $out = & sh -c "'$pwsh' -NoProfile -File '$($v.Path)' -Snapshott </dev/null 2>&1; echo EXIT=`$?"
    $text = ($out -join "`n")
    $said = ($out | Where-Object { $_ -match 'Snapshott' } | Select-Object -First 1)
    Record 'G. a misspelled flag (-Snapshott) is refused, naming it' $v.Name $ver ($text -notmatch 'EXIT=0' -and $said) $(if ($said) { "$said" -replace '\x1b\[[0-9;]*m', '' -replace '\s+', ' ' } else { ((($out | Select-Object -Last 1)) -replace '\s+', ' ') + ' (Snapshott not mentioned)' })

    # H. a bare number is refused, not taken as -Tick
    $fx = New-Fx "H-$($v.Name)"
    $out = & sh -c "$($fx.Env) '$pwsh' -NoProfile -File '$($v.Path)' -ClosedLog '$($fx.Log)' -Snapshot 500 </dev/null 2>&1; echo EXIT=`$?"
    $text = ($out -join "`n")
    $said = ($out | Where-Object { $_ -match '500' } | Select-Object -First 1)
    Record 'H. a stray value (500) is refused, naming it' $v.Name $ver ($text -notmatch 'EXIT=0' -and $said) $(if ($said) { "$said" -replace '\x1b\[[0-9;]*m', '' -replace '\s+', ' ' } else { ((($out | Select-Object -Last 1)) -replace '\s+', ' ') + ' (500 not mentioned)' })
  }
}
finally {
  tmux kill-server 2>$null
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
$results | Sort-Object Check, @{ Expression = { $_.Which -ne 'base' } } | Format-Table Check, Which, Version, Holds, Detail -AutoSize -Wrap | Out-String -Width 220 | Write-Host
$failed = @($results | Where-Object { $_.Which -eq 'current' -and -not $_.Holds })
if ($failed) { $failed | ForEach-Object { Write-Host "FAIL (this checkout): $($_.Check)" -ForegroundColor Red }; exit 1 }
Write-Host 'this checkout holds every check'
exit 0   # not the exit code of the last program run above (a check that expects a refusal)
