# This machine's station taken away on Windows, for real (a CI runner's: never a person's machine): as the app's
# 卸载本机 Station and its uninstaller run it (src/host/station_uninstall.h, its command said by
# scripts/station_uninstall_test.c's `command`) and as `stillfail uninstall [--purge]` runs it through the release's
# stillfail.cmd, which it removes as it runs (cmd reading on in a copy of it: no "The batch file cannot be found"). Each station a data directory of the run's own, with a task of the run's
# own, a stand-in for its launcher running from its release, and its command in a folder of the run's own
# (windows.json's `task` and `bin`, as install.ps1 keeps a station apart): the runner's own are never touched.
#   powershell -File scripts/station_uninstall_win.ps1 <station_uninstall_test.exe>
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$exe = (Resolve-Path $args[0]).Path
# (the temporary folder as its short name: no space in a path cmd is given)
$base = Join-Path ([IO.Path]::GetTempPath()) ('sfu-' + $PID)
$task = "sfu-$PID station"
function Fail([string]$why) { [Console]::Error.WriteLine("station uninstall (windows): $why"); exit 1 }
if ($base.Contains(' ')) { Fail "a space in $base" }

# a station in <base>\<name>: its release (the repository's command in it), its Node, Helper, run, an app.old, its
# data (mesh\cloud.json), its command, and a launcher's stand-in running from its release (its pid in run\station.json)
function Station([string]$name) {
  $root = Join-Path $base $name
  $d = Join-Path $root '.stillfail'
  $bin = Join-Path $root 'bin'
  foreach ($dir in 'app\bin', 'app\mesh\target\release', 'run', 'node\v24', 'helper', 'mesh', 'app.old-1') { New-Item -ItemType Directory -Force (Join-Path $d $dir) | Out-Null }
  New-Item -ItemType Directory -Force $bin | Out-Null
  Copy-Item (Join-Path $repo 'bin\stillfail.ps1'), (Join-Path $repo 'bin\stillfail.cmd') (Join-Path $d 'app\bin')
  Set-Content (Join-Path $d 'mesh\cloud.json') '{"workspace":"ws1"}'
  @{ task = $task; bin = $bin } | ConvertTo-Json | Set-Content (Join-Path $d 'windows.json')
  Set-Content (Join-Path $bin 'stillfail.cmd') ('@"' + (Join-Path $d 'app\bin\stillfail.cmd') + '" %*') -Encoding ASCII
  $launcher = Join-Path $d 'app\mesh\target\release\stillfail-station.exe'
  Copy-Item (Join-Path $env:SystemRoot 'System32\PING.EXE') $launcher
  $p = Start-Process -FilePath $launcher -ArgumentList '-n', '600', '127.0.0.1' -WindowStyle Hidden -PassThru
  Set-Content (Join-Path $d 'run\station.json') ('{"pid":' + $p.Id + '}')
  return @{ data = $d; bin = $bin; process = $p }
}
# its tasks as install.ps1 and the station register them (run at sign-in, its update's), running what is in `data`
function Tasks([string]$data) {
  foreach ($name in $task, "$task update") {
    $action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument ('/c rem "' + $data + '"')
    Register-ScheduledTask -TaskName $name -Action $action -Force | Out-Null
  }
}
function Has([string]$name) { [bool](Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) }
# taken away, its data kept: what it says of it
function Gone($s, [string]$how) {
  $d = $s.data
  if (Has $task) { Fail "${how}: its task is still there" }
  if (Has "$task update") { Fail "${how}: its update's task is still there" }
  if (Get-Process -Id $s.process.Id -ErrorAction SilentlyContinue) { Fail "${how}: its launcher still runs" }
  foreach ($part in 'app', 'app.old-1', 'node', 'helper', 'run', 'windows.json') { if (Test-Path (Join-Path $d $part)) { Fail "${how}: $part is still there" } }
  if (-not (Test-Path (Join-Path $d 'mesh\cloud.json'))) { Fail "${how}: its data went with it" }
  if (-not (Test-Path (Join-Path $d 'uninstalled'))) { Fail "${how}: not said taken away" }
  if (Test-Path (Join-Path $s.bin 'stillfail.cmd')) { Fail "${how}: its command is still there" }
}
function ByApp([string]$data) {
  $command = & $exe command $data
  if ($LASTEXITCODE -ne 0) { Fail "no command for $data" }
  $parts = $command -split ' '
  $said = & $parts[0] $parts[1..($parts.Count - 1)] 2>&1 | Out-String
  $code = $LASTEXITCODE
  Write-Host "the host's command for ${data}: $code`n$said"
  if ($code -ne 0) { Fail "the host's command exited $code" }
}

try {
  # The app's way: another station's tasks (they run another directory) are left as they are; its own go.
  $one = Station 'one'
  $other = Station 'other'
  Tasks $one.data
  ByApp $other.data
  if (-not (Has $task)) { Fail "a station apart took away another's task" }
  ByApp $one.data
  Gone $one 'the app'
  Write-Host "station uninstall (windows): the app's, its tasks, launcher, release and command gone, its data kept"

  # The command's way, through the release's stillfail.cmd, which it removes as it runs: no 'batch file cannot be
  # found' after, and its exit code
  $two = Station 'two'
  Tasks $two.data
  $env:STILLFAIL_DATA = $two.data
  $command = Join-Path $two.data 'app\bin\stillfail.cmd'
  $said = & cmd.exe /c ($command + ' uninstall --nothing 2>&1')
  Write-Host "stillfail uninstall --nothing: $LASTEXITCODE`n$($said -join "`n")"
  if ($LASTEXITCODE -ne 2) { Fail "an unknown option exited $LASTEXITCODE, not 2" }
  $said = & cmd.exe /c ($command + ' uninstall 2>&1')
  $code = $LASTEXITCODE
  Write-Host "stillfail uninstall: $code`n$($said -join "`n")"
  if ($code -ne 0) { Fail "stillfail uninstall exited $code" }
  if (($said -join "`n") -match 'cannot be found|cannot find|batch') { Fail 'cmd read on in the removed stillfail.cmd' }
  if (-not (($said -join "`n") -match 'uninstalled; chats')) { Fail 'stillfail uninstall said nothing of what it did' }
  Gone $two 'stillfail uninstall'

  $three = Station 'three'
  $env:STILLFAIL_DATA = $three.data
  & cmd.exe /c ((Join-Path $three.data 'app\bin\stillfail.cmd') + ' uninstall --purge 2>&1') | Out-Null
  if ($LASTEXITCODE -ne 0) { Fail "stillfail uninstall --purge exited $LASTEXITCODE" }
  if (Test-Path $three.data) { Fail '--purge left the data' }
  if (Get-Process -Id $three.process.Id -ErrorAction SilentlyContinue) { Fail '--purge: its launcher still runs' }
  Write-Host 'station uninstall (windows): stillfail uninstall through its own stillfail.cmd, its exit code; --purge its data too'
} finally {
  Remove-Item Env:STILLFAIL_DATA -ErrorAction SilentlyContinue
  foreach ($name in $task, "$task update") { Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue }
  Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($base) } | Stop-Process -Force -ErrorAction SilentlyContinue
  Remove-Item -Recurse -Force $base -ErrorAction SilentlyContinue
}
