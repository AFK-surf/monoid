# still.fail's command line on Windows (bin/stillfail is Unix's; stillfail.cmd beside this runs it), from a clone or from
# an installed release (~\.stillfail\app, see cloud/src/install.ts's install.ps1):
#   stillfail start [--port N]                    runs the station in this window (the installed one runs at logon)
#   stillfail status                              where the station is: its workspace and cloud, whether it is online
#   stillfail update [--beta|--stable]            updates this station to its cloud's latest release, on its channel
#   stillfail station enroll <cloud-origin> <token> [--provider comma]
#   stillfail station id
#   stillfail lock status|reset                   the workspace lock on this station
#   stillfail lock reset --workspace <id>         the lock of a workspace it joined
#   stillfail screen-service install|uninstall|status
#                                                 optional LocalSystem service for UAC, elevated windows, and lock screen
#   stillfail uninstall [--purge]                 stops the station for good: its scheduled tasks, its processes, its
#                                                 release and ~\.local\bin's command gone; its chats, memory and secrets
#                                                 kept in the data (<data>\uninstalled says so) unless --purge
# The data is in $env:STILLFAIL_DATA, default ~\.stillfail (another product's own: below).
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSScriptRoot
# From a release in another product's data directory beside still.fail's (~\.monoid\app, as its app and its command run
# it: client/i18n/brand.ts), that product's.
$own = Join-Path $env:USERPROFILE '.stillfail'
$release = try { [IO.Path]::GetFullPath($here).TrimEnd('\', '/') } catch { '' }
$userDir = try { [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\', '/') } catch { '' }
if ($release -and $userDir -and (Split-Path -Leaf $release) -eq 'app') {
  $dir = Split-Path -Parent $release
  if ((Split-Path -Parent $dir) -eq $userDir -and (Split-Path -Leaf $dir) -match '^\.[^.]') { $own = $dir }
}
$data = if ($env:STILLFAIL_DATA) { $env:STILLFAIL_DATA } else { $own }
$station = if ($env:STILLFAIL_STATION_BIN) { $env:STILLFAIL_STATION_BIN } else { Join-Path $here 'mesh\target\release\stillfail-station.exe' }
$usage = 'usage: stillfail start [--port N] | stillfail status | stillfail update [--beta|--stable] | stillfail station enroll <cloud-origin> <token> [--provider comma] | stillfail station id | stillfail lock status | stillfail lock reset [--workspace <id>] | stillfail screen-service install|uninstall|status | stillfail uninstall [--purge] | stillfail admin <command>'
$a = @($args)

function Run([string[]] $more) {
  & $station @more
  exit $LASTEXITCODE
}

# The station here taken away (the app's 卸载本机 Station does the same: apps/mbui/src/host/win_station.c, and the app's
# own uninstaller: apps/mbui/windows/setup.c). Its tasks as install.ps1 named them (cloud/src/install-windows.ts,
# windows.json for a station apart): for a data directory of its own ($env:STILLFAIL_DATA, a test's), only a task that
# runs that directory, never the person's own station beside it.
function Uninstall([bool] $purge) {
  $ProgressPreference = 'SilentlyContinue'
  $full = try { [IO.Path]::GetFullPath($data).TrimEnd('\', '/') } catch { '' }
  if (-not $full -or $full -eq [IO.Path]::GetPathRoot($full).TrimEnd('\', '/') -or $full -eq $env:USERPROFILE.TrimEnd('\', '/')) {
    [Console]::Error.WriteLine("stillfail uninstall: refusing to remove $data"); exit 2
  }
  $product = 'stillfail'; $productName = 'still.fail'
  if ((Split-Path -Leaf $full) -eq '.monoid') { $product = 'monoid'; $productName = 'monoid' }
  $apart = $full -ne (Join-Path $env:USERPROFILE ".$product")
  $kept = $null
  try { $kept = Get-Content -Raw (Join-Path $full 'windows.json') | ConvertFrom-Json } catch {}
  $task = if ($kept.task) { $kept.task } else { "$productName station" }
  $bin = if ($kept.bin) { $kept.bin } else { Join-Path $env:USERPROFILE '.local\bin' }
  $app = Join-Path $full 'app'
  foreach ($name in @($task, "$task update", "$task elevation")) {
    $t = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if (-not $t) { continue }
    if ($apart -and -not (@($t.Actions) | Where-Object { ([string]$_.Execute + ' ' + [string]$_.Arguments).Contains($full) })) { continue }
    Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    try { Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop } catch { [Console]::Error.WriteLine("stillfail uninstall: task $name not removed: $($_.Exception.Message)") }
  }
  if (-not $apart -and (Get-Service -Name 'StillfailScreenService' -ErrorAction SilentlyContinue)) {
    $svcBin = 'C:\Program Files\still.fail\screen-service\stillfail-screen-svc.exe'
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin -and (Test-Path -LiteralPath $svcBin)) {
      & $svcBin uninstall | Out-Null
    } else {
      [Console]::Error.WriteLine('stillfail uninstall: StillfailScreenService is still installed (run `stillfail screen-service uninstall` as administrator to remove it)')
    }
  }
  # What still runs of it: the launcher by its pid as it said it, and whatever runs from its release (by <app> in their
  # command lines, as install.ps1 ends them before it replaces a release).
  $said = $null
  try { $said = Get-Content (Join-Path $full 'run\station.json') -Raw | ConvertFrom-Json } catch {}
  $ours = { Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and ($_.CommandLine.Contains($app) -or ($said.pid -and $_.ProcessId -eq [int]$said.pid -and $_.CommandLine.Contains($full))) -and $_.Name -in 'node.exe', 'stillfail-station.exe', 'stillfail-station-w.exe', 'stillfail-reader.exe' } }
  & $ours | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  $deadline = (Get-Date).AddSeconds(5)
  while ((& $ours) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
  # its command (install.ps1's WriteCmd): where it runs this release
  $cmd = Join-Path $bin "$product.cmd"
  if (Test-Path -LiteralPath $cmd) {
    $runs = Get-Content -Raw -LiteralPath $cmd -ErrorAction SilentlyContinue
    if ($runs -and ($runs.Contains($app) -or $runs.Contains("%USERPROFILE%\.$product\app"))) { Remove-Item -LiteralPath $cmd -Force -ErrorAction SilentlyContinue }
  }
  if (-not $kept.bin -and (Test-Path -LiteralPath $bin) -and -not (Get-ChildItem -Force -LiteralPath $bin)) {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath -and (($userPath -split ';') -contains $bin)) {
      [Environment]::SetEnvironmentVariable('Path', ((@($userPath -split ';') | Where-Object { $_ -and $_ -ne $bin }) -join ';'), 'User')
    }
    Remove-Item -LiteralPath $bin -Force -ErrorAction SilentlyContinue
  }
  # (out of the release: this script and its command are in it)
  Set-Location $env:TEMP
  if ($purge) {
    Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "stillfail: uninstalled, $full removed"
  } else {
    foreach ($part in @('app', 'app.failed', 'app.before-replace', 'node', 'helper', 'run', 'windows.json')) {
      Remove-Item -LiteralPath (Join-Path $full $part) -Recurse -Force -ErrorAction SilentlyContinue
    }
    Get-ChildItem -LiteralPath $full -Directory -Filter 'app.old*' -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $full) { New-Item -ItemType File -Force (Join-Path $full 'uninstalled') | Out-Null }
    Write-Host "stillfail: uninstalled; chats, memory and secrets kept in $full"
  }
  exit 0
}

switch ("$($a[0]) $($a[1])".Trim()) {
  { $a[0] -eq 'uninstall' } {
    if ($a.Count -eq 1) { Uninstall $false }
    if ($a.Count -eq 2 -and $a[1] -eq '--purge') { Uninstall $true }
    [Console]::Error.WriteLine('usage: stillfail uninstall [--purge]'); exit 2
  }
  { $a[0] -eq 'start' } { Run (@('run', '--app', $here, '--data', $data) + $a[1..($a.Count)]) }
  { $a[0] -eq 'status' -or $_ -eq 'station status' } { Run @('status', '--data', $data) }
  'station id' { Run @('id', '--data', $data) }
  { $_ -eq 'lock status' -or $_ -eq 'lock reset' } { Run (@('lock', $a[1]) + $(if ($a.Count -gt 2) { $a[2..($a.Count - 1)] } else { @() }) + @('--data', $data)) }
  { $_ -like 'station enroll*' } { Run (@('enroll') + $a[2..($a.Count)] + @('--data', $data)) }
  { $a[0] -eq 'replace' } {
    $rest = if ($a.Count -gt 1) { $a[1..($a.Count - 1)] } else { @() }
    $app = $here
    $mode = ''; $source = $null; $dist = $null; $mainF = $null; $readerF = $null; $note = $null
    $noHold = $false; $clear = $false; $hold = $false; $waits = @()
    for ($i = 0; $i -lt $rest.Count; $i++) {
      switch ($rest[$i]) {
        '--status' { $mode = 'status' }
        '--revert' { $mode = 'revert' }
        '--restore' { $mode = 'restore' }
        '--wait' { $mode = 'wait' }
        '--clear' { $clear = $true }
        '--hold' { $hold = $true }
        '--no-hold' { $noHold = $true }
        '--dist' { $i++; $dist = $rest[$i] }
        '--main' { $i++; $mainF = $rest[$i] }
        '--reader' { $i++; $readerF = $rest[$i] }
        '--note' { $i++; $note = $rest[$i] }
        '--until-pr' { $i++; $waits += "pr:$($rest[$i])" }
        '--until-fix' { $i++; $waits += "fix:$($rest[$i])" }
        '--until-commit' { $i++; $waits += "commit:$($rest[$i])" }
        '--until-version' { $i++; $waits += "version:$($rest[$i])" }
        '--until-after' { $i++; $waits += "after:$($rest[$i])" }
        default {
          if ($rest[$i].StartsWith('--')) { [Console]::Error.WriteLine("stillfail replace: unknown option $($rest[$i])"); exit 2 }
          if ($source) { [Console]::Error.WriteLine("stillfail replace: unexpected argument $($rest[$i])"); exit 2 }
          $source = $rest[$i]
        }
      }
    }
    if ($mode -eq 'status') { Run @('update', '--replace-status', '--app', $app, '--data', $data) }
    if ($mode -eq 'wait') {
      if (-not $clear -and -not $hold -and $waits.Count -eq 0) {
        [Console]::Error.WriteLine('usage: stillfail replace --wait (--until-pr N | --until-fix FB-N | --until-commit SHA | --until-version V | --until-after V | --hold | --clear)')
        exit 2
      }
      $uargs = @('update', '--replace-wait', '--data', $data)
      if ($clear) { $uargs += '--clear' }
      if ($hold) { $uargs += '--hold' }
      foreach ($w in $waits) { $uargs += @('--until', $w) }
      Run $uargs
    }
    if ($mode -eq 'restore') {
      if (-not (Test-Path -LiteralPath $station)) { [Console]::Error.WriteLine("stillfail replace --restore: no $station"); exit 1 }
      $plan = & $station update --app $app --data $data
      if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
      $script = $null
      foreach ($line in @($plan)) {
        $key, $value = $line -split '=', 2
        if ($key -eq 'script') { $script = $value }
        elseif ($key -in 'STILLFAIL_ORIGIN', 'STILLFAIL_CHANNEL', 'STILLFAIL_RELEASE_SHA256', 'STILLFAIL_NODE_SHA256', 'STILLFAIL_INSTALL_LANG', 'STILLFAIL_ARCHIVE') { Set-Item -Path "env:$key" -Value $value }
      }
      if (-not $script) { [Console]::Error.WriteLine('stillfail replace --restore: no installer to run'); exit 1 }
      $env:STILLFAIL_DATA = $data
      & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script
      exit $LASTEXITCODE
    }
    # Handover helper via Windows launcher named pipe (mirrors install-windows.ts).
    $run = Join-Path $data 'run'
    $said = $null; $proc = $null
    try { $said = Get-Content (Join-Path $run 'station.json') -Raw | ConvertFrom-Json } catch {}
    if ($said -and $said.pid) {
      $p = Get-CimInstance Win32_Process -Filter ('ProcessId=' + [int]$said.pid) -ErrorAction SilentlyContinue
      if ($p -and $p.Name -like 'stillfail-station*') { $proc = $p }
    }
    function AskPipe([string]$op) {
      try {
        $pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', ('stillfail-launcher-' + $proc.ProcessId), [System.IO.Pipes.PipeDirection]::Out)
        $pipe.Connect(5000)
        $line = [Text.Encoding]::UTF8.GetBytes('{"op":"' + $op + '"}' + [char]10)
        $pipe.Write($line, 0, $line.Length); $pipe.Flush(); $pipe.Dispose()
        return $true
      } catch { return $false }
    }
    function WaitHandover($started) {
      $deadline = (Get-Date).AddSeconds(180)
      while ((Get-Date) -lt $deadline) {
        Start-Sleep 1
        $now = try { Get-Content (Join-Path $run 'station.json') -Raw | ConvertFrom-Json } catch { $null }
        if ($now -and $now.startedAt -ne $started) { return $true }
        if (Test-Path (Join-Path $run 'handoff-failed')) { return $false }
      }
      return $false
    }
    $backup = Join-Path $data 'app.before-replace'
    if ($mode -eq 'revert') {
      if (-not (Test-Path -LiteralPath $backup)) { [Console]::Error.WriteLine("stillfail replace --revert: no backup at $backup"); exit 1 }
      $aside = $app + '.old-' + (Get-Date -Format 'yyyyMMddHHmmss')
      Move-Item $app $aside
      Move-Item $backup $app
      if ($proc -and $said.handoff -eq 1) {
        Remove-Item (Join-Path $run 'handoff-failed') -ErrorAction SilentlyContinue
        if (-not (AskPipe 'handover') -or -not (WaitHandover $said.startedAt)) {
          Move-Item $app $backup
          Move-Item $aside $app
          [Console]::Error.WriteLine('stillfail replace --revert: handoff failed; kept previous build'); exit 1
        }
      }
      Remove-Item $aside -Recurse -Force -ErrorAction SilentlyContinue
      & $station update --replace-reconcile-revert --data $data
      Write-Host 'stillfail replace: reverted to official backup'
      exit 0
    }
    $stage = Join-Path ([IO.Path]::GetTempPath()) ('stillfail-replace-' + [guid]::NewGuid().ToString('N'))
    $pargs = @('update', '--replace-prepare', '--app', $app, '--data', $data, '--stage', $stage)
    if ($source) { $pargs += @('--source', $source) }
    if ($dist) { $pargs += @('--dist', $dist) }
    if ($mainF) { $pargs += @('--main', $mainF) }
    if ($readerF) { $pargs += @('--reader', $readerF) }
    if ($note) { $pargs += @('--note', $note) }
    & $station @pargs | Out-Null
    if ($LASTEXITCODE -ne 0) { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue; exit $LASTEXITCODE }
    $createdBackup = $false
    if (-not (Test-Path -LiteralPath $backup) -and -not (Test-Path -LiteralPath (Join-Path $app 'OVERRIDE')) -and (Test-Path -LiteralPath $app)) {
      Copy-Item -LiteralPath $app -Destination $backup -Recurse -Force
      $createdBackup = $true
    }
    $aside = $app + '.old-' + (Get-Date -Format 'yyyyMMddHHmmss')
    if (Test-Path -LiteralPath $app) { Move-Item $app $aside }
    Move-Item $stage $app
    $cfgFile = if ($env:STILLFAIL_CONFIG) { $env:STILLFAIL_CONFIG } else { Join-Path $data 'config.json' }
    $savedCfg = $null
    if (Test-Path -LiteralPath $cfgFile) {
      $savedCfg = Join-Path ([IO.Path]::GetTempPath()) ('stillfail-cfg-' + [guid]::NewGuid().ToString('N') + '.json')
      Copy-Item -LiteralPath $cfgFile -Destination $savedCfg -Force
    }
    if (-not $noHold) {
      $uargs = @('update', '--replace-wait', '--direct', '--app', $app, '--data', $data)
      if ($waits.Count -gt 0) { foreach ($w in $waits) { $uargs += @('--until', $w) } } else { $uargs += '--hold' }
      & $station @uargs
      if ($LASTEXITCODE -ne 0) {
        $failed = $app + '.failed'
        Remove-Item $failed -Recurse -Force -ErrorAction SilentlyContinue
        Move-Item $app $failed
        Move-Item $aside $app
        Remove-Item $failed -Recurse -Force -ErrorAction SilentlyContinue
        if ($createdBackup) { Remove-Item $backup -Recurse -Force -ErrorAction SilentlyContinue }
        if ($savedCfg) { Copy-Item -LiteralPath $savedCfg -Destination $cfgFile -Force; Remove-Item $savedCfg -Force -ErrorAction SilentlyContinue } else { Remove-Item $cfgFile -Force -ErrorAction SilentlyContinue }
        exit $LASTEXITCODE
      }
    }
    if ($proc -and $said.handoff -eq 1) {
      Remove-Item (Join-Path $run 'handoff-failed') -ErrorAction SilentlyContinue
      if (-not (AskPipe 'handover') -or -not (WaitHandover $said.startedAt)) {
        $failed = $app + '.failed'
        Remove-Item $failed -Recurse -Force -ErrorAction SilentlyContinue
        Move-Item $app $failed
        Move-Item $aside $app
        Remove-Item $failed -Recurse -Force -ErrorAction SilentlyContinue
        if ($createdBackup) { Remove-Item $backup -Recurse -Force -ErrorAction SilentlyContinue }
        if ($savedCfg) { Copy-Item -LiteralPath $savedCfg -Destination $cfgFile -Force; Remove-Item $savedCfg -Force -ErrorAction SilentlyContinue } else { Remove-Item $cfgFile -Force -ErrorAction SilentlyContinue }
        [Console]::Error.WriteLine('stillfail replace: handoff failed; rolled back to previous build'); exit 1
      }
    }
    Remove-Item $aside -Recurse -Force -ErrorAction SilentlyContinue
    if ($savedCfg) { Remove-Item $savedCfg -Force -ErrorAction SilentlyContinue }
    Write-Host "stillfail replace: replaced $app"
    exit 0
  }
  { $a[0] -eq 'update' } {
    # The channel's latest release, verified by this release's station (its `update`: its signature, newer than this
    # one) and installed by the installer this release carries, told what it must hash to (scripts/release-sign.ts).
    # Not the cloud's installer: whoever serves it could put anything here. The station only says what to run: the
    # installer ends what runs from the release, which it is.
    if ($a.Count -gt 2 -or ($a.Count -eq 2 -and $a[1] -notin '--beta', '--stable')) { [Console]::Error.WriteLine('usage: stillfail update [--beta|--stable]'); exit 2 }
    if (-not (Test-Path -LiteralPath $station)) { [Console]::Error.WriteLine("stillfail update: $here is not an installed release (no $station)"); exit 1 }
    $plan = & $station update @($a[1..($a.Count)] | Where-Object { $_ }) --app $here --data $data
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    $script = $null
    foreach ($line in @($plan)) {
      $key, $value = $line -split '=', 2
      if ($key -eq 'script') { $script = $value }
      elseif ($key -in 'STILLFAIL_ORIGIN', 'STILLFAIL_CHANNEL', 'STILLFAIL_RELEASE_SHA256', 'STILLFAIL_NODE_SHA256', 'STILLFAIL_INSTALL_LANG', 'STILLFAIL_ARCHIVE') { Set-Item -Path "env:$key" -Value $value }
    }
    if (-not $script) { [Console]::Error.WriteLine('stillfail update: no installer to run'); exit 1 }
    $env:STILLFAIL_DATA = $data
    & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script
    exit $LASTEXITCODE
  }
  { $a[0] -eq 'screen-service' } {
    $sub = if ($a.Count -ge 2) { $a[1] } else { '' }
    if ($sub -notin 'install', 'uninstall', 'status') { [Console]::Error.WriteLine('usage: stillfail screen-service install|uninstall|status'); exit 2 }
    $svcBin = @(
      (Join-Path $here 'station\stillfail-screen-svc.exe'),
      (Join-Path $here 'station\native\screen\target\release\stillfail-screen-svc.exe'),
      'C:\Program Files\still.fail\screen-service\stillfail-screen-svc.exe'
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $svcBin) { [Console]::Error.WriteLine("stillfail screen-service: stillfail-screen-svc.exe not found in $here"); exit 1 }
    if ($sub -eq 'status') {
      & $svcBin status
      exit $LASTEXITCODE
    }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $svcArgs = if ($sub -eq 'install') { @('install', '--user-sid', $sid) } else { @('uninstall') }
    if ($isAdmin) {
      & $svcBin @svcArgs
      exit $LASTEXITCODE
    }
    $p = Start-Process -FilePath $svcBin -ArgumentList $svcArgs -Verb RunAs -PassThru -Wait
    if ($p.ExitCode -ne 0) { exit $p.ExitCode }
    & $svcBin status
    exit 0
  }
  { $a[0] -eq 'admin' } {
    # As bin/stillfail's: Node's admin CLI (station\admin-cli.js in a release, bin\admin-cli.ts in a clone); the MoonBit
    # reader's port only with STILLFAIL_ADMIN_ENGINE=moonbit, or where there is no Node or no admin CLI. Both are told
    # the data as STILLFAIL_DATA (the reader as --data too); a --data of the person's own, after it, wins in either.
    $env:STILLFAIL_DATA = $data
    if (-not $env:STILLFAIL_CMD) { $env:STILLFAIL_CMD = (Split-Path -Leaf $own).TrimStart('.') }
    # (always an array: one argument alone would be splatted a character at a time)
    $rest = @(if ($a.Count -gt 1) { $a[1..($a.Count - 1)] })
    $reader = if ($env:STILLFAIL_MB_READER) { $env:STILLFAIL_MB_READER } else { Join-Path $here 'station\stillfail-reader.exe' }
    $engine = if ($env:STILLFAIL_ADMIN_ENGINE) { $env:STILLFAIL_ADMIN_ENGINE } else { '' }
    if ($engine -cnotin '', 'node', 'moonbit') { [Console]::Error.WriteLine("stillfail admin: STILLFAIL_ADMIN_ENGINE must be node or moonbit, not $engine"); exit 2 }
    # Started by .NET, not `&`: PowerShell 5.1 drops an empty argument and the quotes inside one, and under Stop makes a
    # redirected stderr an error. Each argument quoted as CommandLineToArgvW reads it back; the child has this
    # process's stdin, stdout and stderr, and its exit code is the command's.
    function QuoteArg([string] $s) {
      if ($s -ne '' -and $s -notmatch '[\s"]') { return $s }
      $s = [regex]::Replace($s, '(\\*)"', { param($m) $m.Groups[1].Value * 2 + '\"' })
      $s = [regex]::Replace($s, '(\\+)\z', { param($m) $m.Groups[1].Value * 2 })
      return '"' + $s + '"'
    }
    function RunNative([string] $file, [string[]] $argv) {
      $start = New-Object System.Diagnostics.ProcessStartInfo $file
      $start.UseShellExecute = $false
      # (Set-Location moves PowerShell's location, not the process's: a relative --data is the person's location's)
      $start.WorkingDirectory = $ExecutionContext.SessionState.Path.CurrentFileSystemLocation.ProviderPath
      $start.Arguments = (@($argv) | ForEach-Object { QuoteArg $_ }) -join ' '
      $child = [System.Diagnostics.Process]::Start($start)
      $child.WaitForExit()
      exit $child.ExitCode
    }
    if ($engine -cne 'moonbit') {
      # Node: STILLFAIL_NODE, else the release's own, else the PATH's.
      $node = @($env:STILLFAIL_NODE, (Join-Path $here 'node\node.exe')) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
      if (-not $node) { $found = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1; $node = if ($found) { $found.Source } else { $null } }
      $built = Join-Path $here 'station\admin-cli.js'
      $src = Join-Path $here 'bin\admin-cli.ts'
      $entry = if (Test-Path -LiteralPath $built) { $built } elseif (Test-Path -LiteralPath $src) { $src } else { $null }
      if ($node -and $entry) { RunNative $node (@($entry) + $rest) }
      if ($engine -ceq 'node') { [Console]::Error.WriteLine("stillfail admin: STILLFAIL_ADMIN_ENGINE=node, but no Node with admin-cli in $here\station or $here\bin (unset it to use $reader)"); exit 1 }
    }
    if (Test-Path -LiteralPath $reader -PathType Leaf) { RunNative $reader (@('admin', '--data', $data) + $rest) }
    if ($engine -ceq 'moonbit') { [Console]::Error.WriteLine("stillfail admin: STILLFAIL_ADMIN_ENGINE=moonbit, but $reader is not there (unset it to use Node's admin-cli)") }
    else { [Console]::Error.WriteLine("stillfail admin: neither Node with admin-cli (in $here\station or $here\bin) nor $reader is here; reinstall still.fail") }
    exit 1
  }
  default { [Console]::Error.WriteLine($usage); exit 2 }
}
