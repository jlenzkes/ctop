<#
.SYNOPSIS
  Reports what coding agents that can run Claude leave on this computer, for ctop's design: Claude Code,
  VS Code's Copilot (its chats and its Claude agent), Cline and Roo Code. Read-only.

.DESCRIPTION
  For each agent: where its files are, how many, how recent, their field names, and a few values that say
  nothing about your work (ids, status, model, entrypoint, token counts, times). Never prints prompts,
  replies, file contents, titles or command lines, only the names of the fields that hold them.
  Paths under your home folder are shown as ~ unless -ShowHome.

  Run it while an agent is working (and again once it has finished) to see what changes:
    pwsh -File ./tools/Probe-AgentSources.ps1 -OutFile probe.txt

.PARAMETER Newest
  How many of the newest sessions/chats/tasks of each kind to describe. Default 3.
.PARAMETER OutFile
  Also write the report to this file.
.PARAMETER ShowHome
  Print paths in full instead of with ~ for your home folder.
.PARAMETER ClaudeConfigDir
  Claude Code's folder. Default: $env:CLAUDE_CONFIG_DIR, else ~/.claude.
.PARAMETER ClineDir
  Cline's folder. Default: $env:CLINE_DIR, else ~/.cline.
.PARAMETER VSCodeUserDir
  VS Code "User" folders to look in. Default: the usual places for VS Code, Insiders, VSCodium and the
  VS Code server (remote / WSL) on this OS; the report says which exist.
.PARAMETER NoProcesses
  Skip the process table.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
  [int]$Newest = 3,
  [string]$OutFile,
  [switch]$ShowHome,
  [string]$ClaudeConfigDir,
  [string]$ClineDir,
  [string[]]$VSCodeUserDir,
  [switch]$NoProcesses
)
$ErrorActionPreference = 'Stop'
$ProbeVersion = '2026.11.01.1'
$onWindows = $IsWindows -or $env:OS -eq 'Windows_NT'
$onMac = (-not $onWindows) -and $IsMacOS
$homeDir = [Environment]::GetFolderPath('UserProfile')
if (-not $homeDir) { $homeDir = $env:HOME }
$out = [Collections.Generic.List[string]]::new()

function Say([string]$text = '') { $out.Add($text) }
function Show-Path([string]$p) {
  if (-not $p) { return '' }
  if (-not $ShowHome -and $homeDir -and $p.StartsWith($homeDir, [StringComparison]::OrdinalIgnoreCase)) { return '~' + $p.Substring($homeDir.Length) }
  $p
}
function Show-Time($t) { if ($null -eq $t) { return '-' }; ([datetime]$t).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss') + 'Z' }
function Show-Size([long]$n) { if ($n -ge 1MB) { '{0:N1} MB' -f ($n / 1MB) } elseif ($n -ge 1KB) { '{0:N1} KB' -f ($n / 1KB) } else { "$n B" } }
# A value that says nothing about your work: short, one line, not a path. Anything else: its type.
function Safe($v) {
  if ($null -eq $v) { return 'null' }
  if ($v -is [bool] -or $v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) { return [string]$v }
  if ($v -is [string]) {
    if ($v.Length -le 80 -and $v -notmatch '[\r\n\\]' -and $v -notmatch '^(/|~|[A-Za-z]:)') { return '"' + $v + '"' }
    return "(text, $($v.Length) chars)"
  }
  if ($v -is [array]) { return "(list of $(@($v).Count))" }
  return '(object)'
}
function Keys($o) { if ($null -eq $o) { return '-' }; (@($o.PSObject.Properties.Name) | Sort-Object) -join ', ' }
# Show the allowed fields of an object, Safe-formatted, plus the names of all its fields
function Show-Fields($o, [string[]]$allow, [string]$indent) {
  if ($null -eq $o) { Say "${indent}(nothing)"; return }
  $parts = foreach ($k in $allow) { if ($o.PSObject.Properties.Name -contains $k) { "$k=$(Safe $o.$k)" } }
  if ($parts) { Say ("${indent}" + ($parts -join '  ')) }
  Say "${indent}fields: $(Keys $o)"
}
# Read a whole file another program may be writing; $null if it is too big or unreadable
function Read-Text([string]$path, [long]$max = 20MB) {
  try {
    $fi = Get-Item -LiteralPath $path
    if ($fi.Length -gt $max) { return $null }
    $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
    try { $sr = [IO.StreamReader]::new($fs); return $sr.ReadToEnd() } finally { $fs.Dispose() }
  } catch { return $null }
}
function Read-Json([string]$path, [long]$max = 20MB) {
  $t = Read-Text $path $max
  if ($null -eq $t) { return $null }
  try { $o = ConvertFrom-Json -InputObject $t } catch { return $null }
  if ($t.TrimStart().StartsWith('[')) { return , @($o) }   # a list stays a list, even of one (return unrolls lists)
  return $o
}
function Newest($items) { @($items | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First $Newest) }
function Show-Files([string]$label, $files, [string]$indent) {
  $files = @($files)
  if (-not $files.Count) { Say "${indent}${label}: none"; return }
  $n = Newest $files
  Say "${indent}${label}: $($files.Count), newest changed $(Show-Time $n[0].LastWriteTimeUtc)"
}

Say "Agent probe $ProbeVersion   $(Show-Time ([datetime]::UtcNow))"
Say "OS: $([Environment]::OSVersion.VersionString)$(if ($onMac) { ' (macOS)' })   PowerShell $($PSVersionTable.PSVersion)"
Say ''
Say '== Commands on PATH'
foreach ($c in 'claude', 'code', 'code-insiders', 'codium', 'cline', 'sqlite3', 'node') {
  $cmd = Get-Command $c -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  Say ("  {0,-14} {1}" -f $c, $(if ($cmd) { Show-Path $cmd.Source } else { 'not found' }))
}

# ---- Claude Code ------------------------------------------------------------------------------
Say ''
Say '== Claude Code'
$cdir = if ($ClaudeConfigDir) { $ClaudeConfigDir } elseif ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $homeDir '.claude' }
Say "  folder: $(Show-Path $cdir)  $(if (Test-Path -LiteralPath $cdir) { 'exists' } else { 'not found' })"
if (Test-Path -LiteralPath $cdir) {
  # live-session registry (what `claude agents --json` reads); .key files are secrets and are not opened
  $reg = @(Get-ChildItem -LiteralPath (Join-Path $cdir 'sessions') -Filter '*.json' -File -ErrorAction SilentlyContinue)
  Show-Files 'sessions/*.json (live-session registry)' $reg '  '
  foreach ($f in (Newest $reg)) {
    $o = Read-Json $f.FullName 1MB
    Say "    $($f.Name)  changed $(Show-Time $f.LastWriteTimeUtc)"
    if ($o) { Show-Fields $o @('kind', 'entrypoint', 'status', 'version', 'peerProtocol', 'nameSource', 'pid', 'startedAt') '      ' }
  }
  $tx = @(Get-ChildItem -LiteralPath (Join-Path $cdir 'projects') -Filter '*.jsonl' -File -Recurse -ErrorAction SilentlyContinue)
  Show-Files 'projects/**/*.jsonl (transcripts)' $tx '  '
  foreach ($f in (Newest $tx)) {
    Say "    $(Show-Path $f.FullName)  $(Show-Size $f.Length)  changed $(Show-Time $f.LastWriteTimeUtc)"
    # who wrote it: entrypoint (cli, sdk-…, remote, …), version, userType; counted over the first 2000 lines
    $vals = @{}; $types = @{}
    try {
      $fs = [IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite'); $sr = [IO.StreamReader]::new($fs)
      try {
        for ($i = 0; $i -lt 2000 -and $null -ne ($line = $sr.ReadLine()); $i++) {
          foreach ($k in 'entrypoint', 'version', 'userType') {
            if ($line -match ('"' + $k + '":"([^"]{1,40})"')) { $vals["$k=$($Matches[1])"] = 1 + [int]$vals["$k=$($Matches[1])"] }
          }
          if ($line -match '^\{"type":"([a-z_-]{1,30})"' -or $line -match '"type":"(user|assistant|system|attachment|summary)"') { $types[$Matches[1]] = 1 + [int]$types[$Matches[1]] }
        }
      } finally { $fs.Dispose() }
    } catch {}
    Say "      $((@($vals.Keys | Sort-Object | ForEach-Object { "$_ ($($vals[$_]))" })) -join '  ')"
    if ($types.Count) { Say "      line types: $((@($types.Keys | Sort-Object | ForEach-Object { "$_ $($types[$_])" })) -join ', ')" }
  }
}

# ---- processes --------------------------------------------------------------------------------
Say ''
Say '== Processes (agents and their markers)'
if ($NoProcesses) { Say '  skipped (-NoProcesses)' }
elseif ($onWindows) {
  $rx = '(?i)claude-agent-sdk|@anthropic-ai|\\claude(\.exe)?\b|claude-code|saoudrizwan|roo-cline|rooveterinary|\\cline\b'
  $procs = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CommandLine -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match $rx })
  if (-not $procs) { Say '  none whose command line names Claude, the Claude Agent SDK, Cline or Roo' }
  foreach ($p in $procs) {
    $marks = @([regex]::Matches([string]$p.CommandLine, $rx) | ForEach-Object { $_.Value.Trim('\') } | Sort-Object -Unique)
    Say ("  pid {0,-7} parent {1,-7} {2,-20} markers: {3}" -f $p.ProcessId, $p.ParentProcessId, $p.Name, ($marks -join ', '))
  }
  Say "  (another process's environment, e.g. AI_AGENT, is not readable here on Windows)"
}
elseif (Test-Path '/proc/self/environ') {
  $found = 0
  foreach ($d in Get-ChildItem /proc -Directory -ErrorAction SilentlyContinue | Where-Object Name -match '^\d+$') {
    $envText = try { [IO.File]::ReadAllText("$($d.FullName)/environ") } catch { $null }
    if (-not $envText) { continue }
    $vars = @($envText.Split([char]0) | Where-Object { $_ -match '^(AI_AGENT|CLAUDE_CODE_ENTRYPOINT|CLAUDE_AGENT_SDK_VERSION|CLAUDECODE)=' })
    if (-not $vars) { continue }
    $comm = try { ([IO.File]::ReadAllText("$($d.FullName)/comm")).Trim() } catch { '?' }
    $ppid = try { ((([IO.File]::ReadAllText("$($d.FullName)/stat")) -split '\) ', 2)[1] -split ' ')[1] } catch { '?' }
    Say ("  pid {0,-7} parent {1,-7} {2,-16} {3}" -f $d.Name, $ppid, $comm, ($vars -join '  '))
    $found++
  }
  if (-not $found) { Say '  none of your processes has AI_AGENT, CLAUDE_CODE_ENTRYPOINT, CLAUDE_AGENT_SDK_VERSION or CLAUDECODE set' }
}
else { Say '  not read on this OS (no /proc)' }

# ---- VS Code: Copilot chats, extensions' storage ------------------------------------------------
Say ''
Say '== VS Code'
$userDirs = if ($VSCodeUserDir) { $VSCodeUserDir } else {
  $names = 'Code', 'Code - Insiders', 'VSCodium'
  $bases = if ($onWindows) { @($env:APPDATA) } elseif ($onMac) { @(Join-Path $homeDir 'Library/Application Support') } else { @($(if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $homeDir '.config' })) }
  @(foreach ($b in $bases) { if ($b) { foreach ($n in $names) { Join-Path (Join-Path $b $n) 'User' } } }) +
  @((Join-Path $homeDir '.vscode-server/data/User'), (Join-Path $homeDir '.vscode-server-insiders/data/User'))
}
$rooDirs = [Collections.Generic.List[string]]::new()
foreach ($u in $userDirs) {
  if (-not (Test-Path -LiteralPath $u)) { Say "  $(Show-Path $u): not found"; continue }
  Say "  $(Show-Path $u): exists"
  $chat = @(Get-ChildItem -LiteralPath (Join-Path $u 'workspaceStorage') -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Get-ChildItem -LiteralPath (Join-Path $_.FullName 'chatSessions') -File -ErrorAction SilentlyContinue })
  foreach ($g in 'emptyWindowChatSessions', 'transferredChatSessions') { $chat += @(Get-ChildItem -LiteralPath (Join-Path (Join-Path $u 'globalStorage') $g) -File -ErrorAction SilentlyContinue) }
  Show-Files 'Copilot chats (chatSessions/*.json, *.jsonl)' $chat '    '
  foreach ($f in (Newest $chat)) {
    Say "      $($f.Name)  $(Show-Size $f.Length)  changed $(Show-Time $f.LastWriteTimeUtc)  in $(Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent $f.FullName)))"
    $reqAllow = @('modelId', 'timestamp', 'promptTokens', 'completionTokens', 'copilotCredits', 'sessionCopilotCredits', 'requestSource', 'responseTimestamp')
    if ($f.Extension -eq '.jsonl') {
      # a mutation log: line 1 {kind:0, v:<session>}, then kind 1 set / 2 push / 3 delete at path k
      $text = Read-Text $f.FullName
      if ($null -eq $text) { Say '        (too big or unreadable)'; continue }
      $lines = @($text -split "`n" | Where-Object { $_.Trim() })
      $first = try { ConvertFrom-Json -InputObject $lines[0] } catch { $null }
      $kinds = @{}; $paths = @{}; $states = @{}; $models = @{}
      foreach ($l in $lines) {
        $e = try { ConvertFrom-Json -InputObject $l } catch { $null }
        if (-not $e) { continue }
        $kinds[[string]$e.kind] = 1 + [int]$kinds[[string]$e.kind]
        if ($e.k) {
          $p = (@($e.k) | ForEach-Object { if ($_ -is [int] -or $_ -is [long]) { '*' } else { $_ } }) -join '/'
          $paths[$p] = 1 + [int]$paths[$p]
          $leaf = @($e.k)[-1]
          if ($leaf -eq 'modelState' -and $e.v) { $states[[string]$e.v.value] = 1 + [int]$states[[string]$e.v.value] }
          if ($leaf -eq 'modelId' -and $e.v -is [string]) { $models[$e.v] = 1 }
          if ([string]$e.kind -eq '2') { foreach ($item in @($e.v)) { if ($item -and $item.modelId -is [string]) { $models[$item.modelId] = 1 } } }   # a new request pushed
        }
      }
      Say "        log entries by kind: $((@($kinds.Keys | Sort-Object | ForEach-Object { "$_=$($kinds[$_])" })) -join '  ')"
      if ($first -and $first.v) {
        Say "        session fields: $(Keys $first.v)"
        $reqs = @($first.v.requests)
        Say "        requests in first entry: $($reqs.Count)"
        if ($reqs.Count) {
          $last = $reqs[-1]
          Show-Fields $last $reqAllow '        last request: '
          if ($last.modelState) { Say "        last request modelState: $(Safe $last.modelState.value)  completedAt=$(Safe $last.modelState.completedAt)" }
          foreach ($r in $reqs) { if ($r.modelId -is [string]) { $models[$r.modelId] = 1 } }
        }
      }
      if ($paths.Count) { Say "        later changes, by path: $((@($paths.Keys | Sort-Object | Select-Object -First 25 | ForEach-Object { "$_ ($($paths[$_]))" })) -join ', ')" }
      if ($states.Count) { Say "        modelState values set later: $((@($states.Keys | Sort-Object | ForEach-Object { "$_ ($($states[$_]))" })) -join ', ')" }
      if ($models.Count) { Say "        modelId values: $((@($models.Keys | Sort-Object | ForEach-Object { Safe $_ })) -join ', ')" }
    } else {
      $o = Read-Json $f.FullName
      if (-not $o) { Say '        (too big or unreadable)'; continue }
      Say "        session fields: $(Keys $o)"
      $reqs = @($o.requests)
      Say "        requests: $($reqs.Count)"
      if ($reqs.Count) { Show-Fields $reqs[-1] $reqAllow '        last request: '; if ($reqs[-1].modelState) { Say "        last request modelState: $(Safe $reqs[-1].modelState.value)" } }
    }
  }
  $gs = Join-Path $u 'globalStorage'
  $ext = @(Get-ChildItem -LiteralPath $gs -Directory -ErrorAction SilentlyContinue | Where-Object Name -match '(?i)claude|anthropic|cline|roo|copilot|kilo')
  Say "    globalStorage folders of interest: $(if ($ext) { (@($ext.Name) | Sort-Object) -join ', ' } else { 'none' })"
  foreach ($e in $ext) { if ($e.Name -match '(?i)roo-cline|saoudrizwan\.claude-dev|kilo') { $rooDirs.Add($e.FullName) } }
}

# ---- Roo Code (and the older Cline extension, same task layout) --------------------------------
Say ''
Say '== Roo Code / older Cline (VS Code globalStorage tasks)'
if (-not $rooDirs.Count) { Say '  no roo-cline, saoudrizwan.claude-dev or kilo folder in the VS Code folders above' }
foreach ($r in $rooDirs) {
  Say "  $(Show-Path $r)"
  $tasks = Join-Path $r 'tasks'
  $idx = Join-Path $tasks '_index.json'
  if (Test-Path -LiteralPath $idx) { $io = Read-Json $idx; Say "    tasks/_index.json: fields $(Keys $io)" } else { Say '    tasks/_index.json: not found' }
  $tdirs = @(Get-ChildItem -LiteralPath $tasks -Directory -ErrorAction SilentlyContinue)
  Show-Files 'task folders' $tdirs '    '
  foreach ($t in (Newest $tdirs)) {
    Say "      $($t.Name)  changed $(Show-Time $t.LastWriteTimeUtc)  files: $((@(Get-ChildItem -LiteralPath $t.FullName -File -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name) ($(Show-Time $_.LastWriteTimeUtc))" })) -join ', ')"
    $h = Read-Json (Join-Path $t.FullName 'history_item.json') 2MB
    if ($h) { Show-Fields $h @('status', 'mode', 'tokensIn', 'tokensOut', 'cacheReads', 'cacheWrites', 'totalCost', 'ts', 'number') '        history_item: ' }
    $ui = Read-Json (Join-Path $t.FullName 'ui_messages.json')
    if ($ui) {
      $all = @($ui)
      Say "        ui_messages: $($all.Count)"
      foreach ($m in @($all | Select-Object -Last 3)) { Show-Fields $m @('type', 'ask', 'say', 'ts', 'partial') '          ' }
    }
  }
}

# ---- Cline (current: ~/.cline) --------------------------------------------------------------------
Say ''
Say '== Cline'
$kdir = if ($ClineDir) { $ClineDir } elseif ($env:CLINE_DIR) { $env:CLINE_DIR } else { Join-Path $homeDir '.cline' }
Say "  folder: $(Show-Path $kdir)  $(if (Test-Path -LiteralPath $kdir) { 'exists' } else { 'not found' })"
if (Test-Path -LiteralPath $kdir) {
  # the same overrides Cline reads (sdk/packages/shared/src/storage/paths.ts)
  $dataDir = if ($env:CLINE_DATA_DIR) { $env:CLINE_DATA_DIR } else { Join-Path $kdir 'data' }
  $dbDir = if ($env:CLINE_DB_DATA_DIR) { $env:CLINE_DB_DATA_DIR } else { Join-Path $dataDir 'db' }
  foreach ($n in 'sessions.db', 'sessions.db-wal', 'sessions.db-shm') {
    $p = Join-Path $dbDir $n
    if (Test-Path -LiteralPath $p) { $fi = Get-Item -LiteralPath $p; Say "    $n  $(Show-Size $fi.Length)  changed $(Show-Time $fi.LastWriteTimeUtc)" } else { Say "    ${n}: not found" }
  }
  $db = Join-Path $dbDir 'sessions.db'
  $sq = Get-Command sqlite3 -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ((Test-Path -LiteralPath $db) -and $sq) {
    $cols = & $sq.Source -readonly $db 'PRAGMA table_info(sessions);' 2>&1
    Say "    sessions table columns: $((@($cols | ForEach-Object { ([string]$_ -split '\|')[1] })) -join ', ')"
    $rows = & $sq.Source -readonly -separator ' | ' $db "SELECT session_id, source, pid, status, provider, model, started_at, ended_at FROM sessions ORDER BY started_at DESC LIMIT $Newest;" 2>&1
    Say '    newest rows (session_id | source | pid | status | provider | model | started_at | ended_at):'
    foreach ($row in $rows) { Say "      $row" }
  } elseif (Test-Path -LiteralPath $db) { Say '    (sqlite3 not on PATH: the database was not read)' }
  $sdir = if ($env:CLINE_SESSION_DATA_DIR) { $env:CLINE_SESSION_DATA_DIR } else { Join-Path $dataDir 'sessions' }
  $idxFile = Join-Path $sdir 'sessions.index.json'
  Say "    data/sessions/sessions.index.json (file fallback): $(if (Test-Path -LiteralPath $idxFile) { 'exists' } else { 'not found' })"
  $sess = @(Get-ChildItem -LiteralPath $sdir -Directory -ErrorAction SilentlyContinue)
  Show-Files 'session folders' $sess '    '
  foreach ($s in (Newest $sess)) {
    Say "      $($s.Name)  changed $(Show-Time $s.LastWriteTimeUtc)  files: $((@(Get-ChildItem -LiteralPath $s.FullName -File -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name) ($(Show-Time $_.LastWriteTimeUtc))" })) -join ', ')"
    $m = Read-Json (Join-Path $s.FullName "$($s.Name).json") 2MB
    if ($m) { Show-Fields $m @('status', 'source', 'pid', 'interactive', 'provider', 'model', 'started_at', 'ended_at', 'exit_code', 'version') '        manifest: ' }
    $msgs = Read-Json (Join-Path $s.FullName "$($s.Name).messages.json")
    if ($null -ne $msgs) {
      if ($msgs -is [array]) { Say "        messages.json: a list of $(@($msgs).Count); last item fields: $(Keys @($msgs)[-1])" }
      else { Say "        messages.json: fields $(Keys $msgs)" }
    }
  }
}

$report = $out -join [Environment]::NewLine
if ($OutFile) { [IO.File]::WriteAllText($OutFile, $report + [Environment]::NewLine, [Text.UTF8Encoding]::new($false)) }
$report
