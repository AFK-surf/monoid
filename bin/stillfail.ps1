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
    foreach ($part in @('app', 'app.failed', 'node', 'helper', 'run', 'windows.json')) {
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
    $node = if ($env:STILLFAIL_NODE) { $env:STILLFAIL_NODE } else { Join-Path $here 'node\node.exe' }
    if (-not (Test-Path -LiteralPath $node)) { $cmd = Get-Command node -ErrorAction SilentlyContinue; $node = if ($cmd) { $cmd.Source } else { $null } }
    if (-not $node) { [Console]::Error.WriteLine('stillfail admin: node not found'); exit 1 }
    $built = Join-Path $here 'station\admin-cli.js'
    $src = Join-Path $here 'bin\admin-cli.ts'
    $entry = if (Test-Path -LiteralPath $built) { $built } elseif (Test-Path -LiteralPath $src) { $src } else { $null }
    if (-not $entry) { [Console]::Error.WriteLine("stillfail admin: admin-cli not found in $here\station or $here\bin"); exit 1 }
    $env:STILLFAIL_DATA = $data
    $rest = if ($a.Count -gt 1) { $a[1..($a.Count - 1)] } else { @() }
    & $node $entry @rest
    exit $LASTEXITCODE
  }
  default { [Console]::Error.WriteLine($usage); exit 2 }
}
