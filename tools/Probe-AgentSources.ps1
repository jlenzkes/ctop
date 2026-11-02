<#
.SYNOPSIS
  Reports what coding agents that can run Claude leave on this computer, for ctop's design: Claude Code,
  VS Code's Copilot (its chats and its Claude agent), Cline, Roo Code and Zoo Code. Read-only.

.DESCRIPTION
  For each agent: where its files are, how many, how recent, their field names, and a few values that say
  nothing about your work (ids, status, model, entrypoint, token counts, times). Never prints prompts,
  replies, file contents, titles or command lines, only the names of the fields that hold them.
  Paths under your home folder are shown as ~ unless -ShowHome.
  The probe itself writes nothing but -OutFile. If the cline command is installed it runs
  `cline history --json`, and Cline opening its own database can create or touch its sessions.db-wal and
  sessions.db-shm files (seen on Windows, 2026-11-01).

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
.PARAMETER WatchSeconds
  After the report, keep watching for this many seconds and print each change as it happens, with its
  time: Copilot chat files (each new log entry, and a request's state), Claude Code's live-session
  entries and transcripts, Cline's session manifests. Start it, then use the agent:
    pwsh -File ./tools/Probe-AgentSources.ps1 -WatchSeconds 180 -OutFile probe-watch.txt
#>
[CmdletBinding(PositionalBinding = $false)]
param(
  [int]$Newest = 3,
  [string]$OutFile,
  [switch]$ShowHome,
  [string]$ClaudeConfigDir,
  [string]$ClineDir,
  [string[]]$VSCodeUserDir,
  [switch]$NoProcesses,
  [int]$WatchSeconds = 0
)
$ErrorActionPreference = 'Stop'
$ProbeVersion = '2026.11.02.2'
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
  if ($v -is [datetime]) { return $v.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ') }   # PowerShell 7 turns ISO date strings into dates
  if ($v -is [string]) {
    if ($v.Length -le 80 -and $v -notmatch '[\r\n\\]' -and $v -notmatch '^(/|~|[A-Za-z]:)') { return '"' + $v + '"' }
    return "(text, $($v.Length) chars)"
  }
  if ($v -is [array]) { return "(list of $(@($v).Count))" }
  return '(object)'
}
# Copilot's ResponseModelState (src/vs/workbench/contrib/chat/common/chatService/chatService.ts)
function State-Name($n) { $names = @('Pending', 'Complete', 'Cancelled', 'Failed', 'NeedsInput'); if ($n -is [int] -or $n -is [long]) { if ($n -ge 0 -and $n -lt $names.Count) { return "$n $($names[$n])" } }; Safe $n }
# A transcript line's own metadata: the named fields at its top level only (a tool's input can carry fields of
# the same names, and they are content), each shown only when it looks like a label, else as (other). Lines
# over 256 KB are not parsed: @{} (their metadata is not counted).
function Get-LineMeta([string]$line, [string[]]$keys) {
  $r = @{}
  if ($line.Length -gt 262144) { return $r }
  $o = $null; try { $o = ConvertFrom-Json -InputObject $line -ErrorAction Stop } catch { return $r }
  if ($null -eq $o -or $o -is [array]) { return $r }
  $names = @($o.PSObject.Properties.Name)
  foreach ($k in $keys) {
    if ($names -notcontains $k) { continue }
    $v = $o.$k
    if ($v -is [string]) { $r[$k] = if ($v -match '^[A-Za-z0-9._-]{1,40}$') { $v } else { '(other)' } }
  }
  return $r
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
          $meta = Get-LineMeta $line @('entrypoint', 'version', 'userType', 'type')
          foreach ($k in 'entrypoint', 'version', 'userType') {
            if ($meta.ContainsKey($k)) { $vals["$k=$($meta[$k])"] = 1 + [int]$vals["$k=$($meta[$k])"] }
          }
          if ($meta.ContainsKey('type')) { $types[$meta.type] = 1 + [int]$types[$meta.type] }
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
      $kinds = @{}; $paths = @{}; $states = @{}; $models = @{}; $pushed = [Collections.Generic.List[object]]::new()
      foreach ($l in $lines) {
        $e = try { ConvertFrom-Json -InputObject $l } catch { $null }
        if (-not $e) { continue }
        $kinds[[string]$e.kind] = 1 + [int]$kinds[[string]$e.kind]
        if ($e.k) {
          $p = (@($e.k) | ForEach-Object { if ($_ -is [int] -or $_ -is [long]) { '*' } else { $_ } }) -join '/'
          $paths[$p] = 1 + [int]$paths[$p]
          $leaf = @($e.k)[-1]
          if ($leaf -eq 'modelState' -and $e.v) { $sn = State-Name $e.v.value; $states[$sn] = 1 + [int]$states[$sn] }
          if ($leaf -eq 'modelId' -and $e.v -is [string]) { $models[$e.v] = 1 }
          if ([string]$e.kind -eq '2') {   # a new request pushed
            foreach ($item in @($e.v)) { if ($item -and $item.modelId -is [string]) { $models[$item.modelId] = 1 }; if ($item -and @($e.k)[-1] -eq 'requests') { $pushed.Add($item) } }
          }
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
          if ($last.modelState) { Say "        last request modelState: $(State-Name $last.modelState.value)  completedAt=$(Safe $last.modelState.completedAt)" }
          foreach ($r in $reqs) { if ($r.modelId -is [string]) { $models[$r.modelId] = 1 } }
        }
      }
      if ($paths.Count) { Say "        later changes, by path: $((@($paths.Keys | Sort-Object | Select-Object -First 25 | ForEach-Object { "$_ ($($paths[$_]))" })) -join ', ')" }
      foreach ($item in @($pushed | Select-Object -Last 2)) {
        Show-Fields $item $reqAllow '        request added later: '
        Say "        request added later, modelState: $(if ($item.modelState) { State-Name $item.modelState.value } else { '(none)' })"
      }
      if ($states.Count) { Say "        modelState values set later: $((@($states.Keys | Sort-Object | ForEach-Object { "$_ ($($states[$_]))" })) -join ', ')" }
      if ($models.Count) { Say "        modelId values: $((@($models.Keys | Sort-Object | ForEach-Object { Safe $_ })) -join ', ')" }
    } else {
      $o = Read-Json $f.FullName
      if (-not $o) { Say '        (too big or unreadable)'; continue }
      Say "        session fields: $(Keys $o)"
      $reqs = @($o.requests)
      Say "        requests: $($reqs.Count)"
      if ($reqs.Count) { Show-Fields $reqs[-1] $reqAllow '        last request: '; if ($reqs[-1].modelState) { Say "        last request modelState: $(State-Name $reqs[-1].modelState.value)" } }
    }
  }
  $gs = Join-Path $u 'globalStorage'
  $ext = @(Get-ChildItem -LiteralPath $gs -Directory -ErrorAction SilentlyContinue | Where-Object Name -match '(?i)claude|anthropic|cline|roo|zoo|copilot|kilo')
  Say "    globalStorage folders of interest: $(if ($ext) { (@($ext.Name) | Sort-Object) -join ', ' } else { 'none' })"
  # Roo's task layout: Roo Code, Zoo Code (Roo's community fork), Kilo Code, the older Cline extension
  foreach ($e in $ext) { if ($e.Name -match '(?i)roo-cline|zoo-code|saoudrizwan\.claude-dev|kilo') { $rooDirs.Add($e.FullName) } }
}

# ---- Roo Code (and the older Cline extension, same task layout) --------------------------------
Say ''
Say '== Roo Code, Zoo Code, Kilo Code, older Cline (VS Code globalStorage tasks)'
if (-not $rooDirs.Count) { Say '  no roo-cline, zoo-code, saoudrizwan.claude-dev or kilo folder in the VS Code folders above' }
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
  # Cline's CLI lists sessions as JSON (apps/cli/src/commands/history.ts): the same rows, without SQLite
  $cl = Get-Command cline -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($cl) {
    # (rows are unrolled with ForEach-Object: Windows PowerShell 5.1 returns a JSON list as one object)
    $rows = $null; $why = ''
    try {
      $psi = [Diagnostics.ProcessStartInfo]::new()
      if ($cl.Source -match '\.(cmd|bat)$') { $psi.FileName = $env:ComSpec; $psi.Arguments = "/d /c `"`"$($cl.Source)`" history --json --limit $Newest`"" }
      else { $psi.FileName = $cl.Source; $psi.Arguments = "history --json --limit $Newest" }
      $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
      $pr = [Diagnostics.Process]::Start($psi); $pr.StandardInput.Close()
      $so = $pr.StandardOutput.ReadToEndAsync(); $null = $pr.StandardError.ReadToEndAsync()
      if (-not $pr.WaitForExit(30000)) { try { $pr.Kill() } catch {}; $why = 'did not finish within 30 s' }
      else { $text = $so.Result; $start = $text.IndexOf('['); if ($start -ge 0) { $rows = @(ConvertFrom-Json -InputObject $text.Substring($start) | ForEach-Object { $_ }) } else { $why = "exit $($pr.ExitCode), no JSON list in its output" } }
    } catch { $why = $_.Exception.Message }
    if ($null -ne $rows) {
      Say "    cline history --json: $($rows.Count) rows"
      foreach ($row in $rows) { Show-Fields $row @('sessionId', 'session_id', 'source', 'pid', 'status', 'provider', 'model', 'startedAt', 'started_at', 'endedAt', 'ended_at', 'exitCode', 'interactive') '      ' }
    } else { Say "    cline history --json: not read ($why)" }
  }
  $sdir = if ($env:CLINE_SESSION_DATA_DIR) { $env:CLINE_SESSION_DATA_DIR } else { Join-Path $dataDir 'sessions' }
  $idxFile = Join-Path $sdir 'sessions.index.json'
  Say "    data/sessions/sessions.index.json (file fallback): $(if (Test-Path -LiteralPath $idxFile) { 'exists' } else { 'not found' })"
  $sess = @(Get-ChildItem -LiteralPath $sdir -Directory -ErrorAction SilentlyContinue)
  Show-Files 'session folders' $sess '    '
  foreach ($s in (Newest $sess)) {
    Say "      $($s.Name)  changed $(Show-Time $s.LastWriteTimeUtc)  files: $((@(Get-ChildItem -LiteralPath $s.FullName -File -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name) ($(Show-Time $_.LastWriteTimeUtc))" })) -join ', ')"
    $m = Read-Json (Join-Path $s.FullName "$($s.Name).json") 2MB
    if ($m) {
      Show-Fields $m @('status', 'source', 'pid', 'interactive', 'provider', 'model', 'started_at', 'ended_at', 'exit_code', 'version') '        manifest: '
      if ($m.metadata) { Say "        manifest metadata fields: $(Keys $m.metadata)" }
    }
    $msgs = Read-Json (Join-Path $s.FullName "$($s.Name).messages.json")
    if ($null -ne $msgs) {
      if ($msgs -is [array]) { Say "        messages.json: a list of $(@($msgs).Count); last item fields: $(Keys @($msgs)[-1])" }
      else {
        Say "        messages.json: fields $(Keys $msgs)"
        # what ctop reads from it, as counts and field names only (no text): roles, content block types,
        # and the replies' metrics (tokens, cost) and modelInfo
        $list = @($msgs.messages | Where-Object { $null -ne $_ })
        if ($list.Count) {
          $roles = @{}; $types = @{}; $mk = @{}; $ik = @{}; $withMetrics = 0; $withTs = 0
          foreach ($x in $list) {
            $roles[(Safe $x.role)] = 1 + [int]$roles[(Safe $x.role)]
            if ($x.content -is [string]) { $types['(plain text)'] = 1 + [int]$types['(plain text)'] }
            else { foreach ($b in @($x.content)) { if ($b -and $b.type) { $types[(Safe $b.type)] = 1 + [int]$types[(Safe $b.type)] } } }
            if ($x.metrics) { $withMetrics++; foreach ($n in $x.metrics.PSObject.Properties.Name) { $mk[$n] = 1 } }
            if ($x.modelInfo) { foreach ($n in $x.modelInfo.PSObject.Properties.Name) { $ik[$n] = 1 } }
            if ($null -ne $x.ts) { $withTs++ }
          }
          $fmt = { param($h) $k = [string[]]@($h.Keys); [Array]::Sort($k, [StringComparer]::Ordinal); (@($k | ForEach-Object { "$_ $($h[$_])" })) -join ', ' }   # ordinal: the same order everywhere
          Say "        messages: $($list.Count)   roles: $(& $fmt $roles)"
          Say "        content blocks: $(& $fmt $types)"
          Say "        with metrics: $withMetrics   metrics fields: $((@($mk.Keys) | Sort-Object) -join ', ')   modelInfo fields: $((@($ik.Keys) | Sort-Object) -join ', ')   with ts: $withTs"
        }
      }
    }
  }
}

$report = $out -join [Environment]::NewLine
if ($OutFile) { [IO.File]::WriteAllText($OutFile, $report + [Environment]::NewLine, [Text.UTF8Encoding]::new($false)) }
$report
if ($WatchSeconds -le 0) { return }

# ---- watch: each change as it happens -------------------------------------------------------------
$t0 = [Diagnostics.Stopwatch]::StartNew()
function W([string]$text) {
  $line = '{0}  +{1,6:N1}s  {2}' -f [datetime]::UtcNow.ToString('HH:mm:ss.fff'), $t0.Elapsed.TotalSeconds, $text
  [Console]::Out.WriteLine($line)
  if ($OutFile) { [IO.File]::AppendAllText($OutFile, $line + [Environment]::NewLine) }
}
if ($OutFile) { [IO.File]::AppendAllText($OutFile, [Environment]::NewLine + "== Watching for $WatchSeconds s (UTC)" + [Environment]::NewLine) }
[Console]::Out.WriteLine(''); [Console]::Out.WriteLine("== Watching for $WatchSeconds s (UTC). Use the agent now.")
function Get-ChatFiles {
  foreach ($u in $userDirs) {
    if (-not (Test-Path -LiteralPath $u)) { continue }
    Get-ChildItem -LiteralPath (Join-Path $u 'workspaceStorage') -Directory -ErrorAction SilentlyContinue | ForEach-Object { Get-ChildItem -LiteralPath (Join-Path $_.FullName 'chatSessions') -File -ErrorAction SilentlyContinue }
    foreach ($g in 'emptyWindowChatSessions', 'transferredChatSessions') { Get-ChildItem -LiteralPath (Join-Path (Join-Path $u 'globalStorage') $g) -File -ErrorAction SilentlyContinue }
  }
}
function Get-Seen($files) { $h = @{}; foreach ($f in $files) { $h[$f.FullName] = @{ Len = $f.Length; Time = $f.LastWriteTimeUtc } }; $h }
# the new bytes of a file another program is writing
function Read-From([string]$path, [long]$from) {
  try {
    $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
    try { if ($from -gt $fs.Length) { $from = 0 }; $null = $fs.Seek($from, 'Begin'); $sr = [IO.StreamReader]::new($fs); return $sr.ReadToEnd() } finally { $fs.Dispose() }
  } catch { return '' }
}
$chatSeen = Get-Seen (Get-ChatFiles)
$regDir = Join-Path $cdir 'sessions'; $projDir = Join-Path $cdir 'projects'
$regSeen = Get-Seen @(Get-ChildItem -LiteralPath $regDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
$txSeen = @{}; $txStart = [datetime]::UtcNow
$clineSess = if (Test-Path -LiteralPath $kdir) { $(if ($env:CLINE_SESSION_DATA_DIR) { $env:CLINE_SESSION_DATA_DIR } else { Join-Path $(if ($env:CLINE_DATA_DIR) { $env:CLINE_DATA_DIR } else { Join-Path $kdir 'data' }) 'sessions' }) }
$clineSeen = if ($clineSess) { Get-Seen @(Get-ChildItem -LiteralPath $clineSess -Filter '*.json' -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*.messages.json' -and $_.Name -notlike '*.compaction.json' }) } else { @{} }
$tick = 0
while ($t0.Elapsed.TotalSeconds -lt $WatchSeconds) {
  Start-Sleep -Milliseconds 1000; $tick++
  # Copilot chats: every second
  foreach ($f in @(Get-ChatFiles)) {
    $old = $chatSeen[$f.FullName]
    if ($old -and $old.Len -eq $f.Length -and $old.Time -eq $f.LastWriteTimeUtc) { continue }
    $from = if ($old) { [long]$old.Len } else { 0 }
    W "copilot chat $(if ($old) { 'changed' } else { 'new' }): $($f.Name)  $(Show-Size $f.Length) ($(if ($old) { '{0:+#;-#;0} B' -f ($f.Length - $old.Len) } else { 'new' }))"
    if ($f.Extension -eq '.jsonl') {
      foreach ($l in @((Read-From $f.FullName $from) -split "`n" | Where-Object { $_.Trim() })) {
        $e = try { ConvertFrom-Json -InputObject $l } catch { $null }
        if (-not $e) { W '    (a partial line)'; continue }
        $p = (@($e.k) | ForEach-Object { if ($_ -is [int] -or $_ -is [long]) { '*' } else { $_ } }) -join '/'
        $extra = ''
        if (@($e.k)[-1] -eq 'modelState' -and $e.v) { $extra = "  modelState=$(State-Name $e.v.value)" }
        if ([string]$e.kind -eq '2') { foreach ($item in @($e.v)) { if ($item -and $item.PSObject.Properties.Name -contains 'modelId') { $extra += "  modelId=$(Safe $item.modelId)  modelState=$(if ($item.modelState) { State-Name $item.modelState.value } else { '(none)' })" } } }
        if ([string]$e.kind -eq '0') { $extra = "  (whole session: $(@($e.v.requests).Count) requests)" }
        W "    kind $($e.kind) $(if ($p) { $p })$extra"
      }
    }
    $chatSeen[$f.FullName] = @{ Len = $f.Length; Time = $f.LastWriteTimeUtc }
  }
  # Claude Code registry: every second; transcripts and Cline: every 3 s
  $nowReg = @(Get-ChildItem -LiteralPath $regDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
  foreach ($f in $nowReg) {
    $old = $regSeen[$f.FullName]
    if ($old -and $old.Time -eq $f.LastWriteTimeUtc) { continue }
    $o = Read-Json $f.FullName 1MB
    W "claude live-session entry $(if ($old) { 'changed' } else { 'new' }): $($f.Name)  $(if ($o) { "kind=$(Safe $o.kind) entrypoint=$(Safe $o.entrypoint) status=$(Safe $o.status)" })"
    $regSeen[$f.FullName] = @{ Len = $f.Length; Time = $f.LastWriteTimeUtc }
  }
  foreach ($k in @($regSeen.Keys)) { if (-not (Test-Path -LiteralPath $k)) { W "claude live-session entry removed: $(Split-Path -Leaf $k)"; $regSeen.Remove($k) } }
  if ($tick % 3 -eq 0) {
    foreach ($f in @(Get-ChildItem -LiteralPath $projDir -Filter '*.jsonl' -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTimeUtc -gt $txStart })) {
      $old = $txSeen[$f.FullName]
      if ($old -and $old.Len -eq $f.Length) { continue }
      $from = if ($old) { [long]$old.Len } else { [Math]::Max(0, $f.Length - 65536) }
      $added = Read-From $f.FullName $from
      # each whole line's own entrypoint (the first line read from the middle of a file does not parse: skipped)
      $ep = @(foreach ($line in ($added -split "`r?`n")) { if ($line.Trim()) { $m = Get-LineMeta $line @('entrypoint'); if ($m.ContainsKey('entrypoint')) { $m.entrypoint } } }) | Sort-Object -Unique
      $ep = @($ep) -join ','
      W "claude transcript $(if ($old) { 'grew' } else { 'changed' }): $(Show-Path $f.FullName)  $(Show-Size $f.Length)  entrypoint: $(if ($ep) { $ep } else { '-' })"
      $txSeen[$f.FullName] = @{ Len = $f.Length; Time = $f.LastWriteTimeUtc }
    }
    if ($clineSess) {
      foreach ($f in @(Get-ChildItem -LiteralPath $clineSess -Filter '*.json' -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*.messages.json' -and $_.Name -notlike '*.compaction.json' })) {
        $old = $clineSeen[$f.FullName]
        if ($old -and $old.Time -eq $f.LastWriteTimeUtc) { continue }
        $m = Read-Json $f.FullName 2MB
        W "cline manifest $(if ($old) { 'changed' } else { 'new' }): $($f.Name)  $(if ($m) { "status=$(Safe $m.status) pid=$(Safe $m.pid) source=$(Safe $m.source) model=$(Safe $m.model)" })"
        $clineSeen[$f.FullName] = @{ Len = $f.Length; Time = $f.LastWriteTimeUtc }
      }
    }
  }
}
W 'watch ended'
