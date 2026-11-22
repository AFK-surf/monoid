// What a Windows host runs to take this machine's station away: the app's 卸载本机 Station (win_station.c) and its own
// uninstaller (windows/setup.c) for a station the person keeps no app of. bin/stillfail.ps1's `uninstall`, its function
// word for word (scripts/station_uninstall_test.c holds them the same): not the release's own script, which a station
// installed before it carries without, and which is gone where its release was removed by hand. Its tasks, what runs
// of it, its command, its release; its data kept and said taken away (<data>\uninstalled). In plain C with nothing of
// a platform's, so the test links it on every system.
#ifndef MB_STATION_UNINSTALL_H
#define MB_STATION_UNINSTALL_H
#include <stdlib.h>
#include <string.h>

// bin/stillfail.ps1's `function Uninstall`, as it is there
static const char station_uninstall_ps[] =
    "function Uninstall([bool] $purge) {\n"
    "  $ProgressPreference = 'SilentlyContinue'\n"
    "  $full = try { [IO.Path]::GetFullPath($data).TrimEnd('\\', '/') } catch { '' }\n"
    "  if (-not $full -or $full -eq [IO.Path]::GetPathRoot($full).TrimEnd('\\', '/') -or $full -eq $env:USERPROFILE.TrimEnd('\\', '/')) {\n"
    "    [Console]::Error.WriteLine(\"stillfail uninstall: refusing to remove $data\"); exit 2\n"
    "  }\n"
    "  $product = 'stillfail'; $productName = 'still.fail'\n"
    "  if ((Split-Path -Leaf $full) -eq '.monoid') { $product = 'monoid'; $productName = 'monoid' }\n"
    "  $apart = $full -ne (Join-Path $env:USERPROFILE \".$product\")\n"
    "  $kept = $null\n"
    "  try { $kept = Get-Content -Raw (Join-Path $full 'windows.json') | ConvertFrom-Json } catch {}\n"
    "  $task = if ($kept.task) { $kept.task } else { \"$productName station\" }\n"
    "  $bin = if ($kept.bin) { $kept.bin } else { Join-Path $env:USERPROFILE '.local\\bin' }\n"
    "  $app = Join-Path $full 'app'\n"
    "  foreach ($name in @($task, \"$task update\", \"$task elevation\")) {\n"
    "    $t = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue\n"
    "    if (-not $t) { continue }\n"
    "    if ($apart -and -not (@($t.Actions) | Where-Object { ([string]$_.Execute + ' ' + [string]$_.Arguments).Contains($full) })) { continue }\n"
    "    Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue\n"
    "    try { Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop } catch { [Console]::Error.WriteLine(\"stillfail uninstall: task $name not removed: $($_.Exception.Message)\") }\n"
    "  }\n"
    "  if (-not $apart -and (Get-Service -Name 'StillfailScreenService' -ErrorAction SilentlyContinue)) {\n"
    "    $svcBin = 'C:\\Program Files\\still.fail\\screen-service\\stillfail-screen-svc.exe'\n"
    "    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)\n"
    "    if ($isAdmin -and (Test-Path -LiteralPath $svcBin)) {\n"
    "      & $svcBin uninstall | Out-Null\n"
    "    } else {\n"
    "      [Console]::Error.WriteLine('stillfail uninstall: StillfailScreenService is still installed (run `stillfail screen-service uninstall` as administrator to remove it)')\n"
    "    }\n"
    "  }\n"
    "  # What still runs of it: the launcher by its pid as it said it, and whatever runs from its release (by <app> in their\n"
    "  # command lines, as install.ps1 ends them before it replaces a release).\n"
    "  $said = $null\n"
    "  try { $said = Get-Content (Join-Path $full 'run\\station.json') -Raw | ConvertFrom-Json } catch {}\n"
    "  $ours = { Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and ($_.CommandLine.Contains($app) -or ($said.pid -and $_.ProcessId -eq [int]$said.pid -and $_.CommandLine.Contains($full))) -and $_.Name -in 'node.exe', 'stillfail-station.exe', 'stillfail-station-w.exe', 'stillfail-reader.exe' } }\n"
    "  & $ours | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }\n"
    "  $deadline = (Get-Date).AddSeconds(5)\n"
    "  while ((& $ours) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }\n"
    "  # its command (install.ps1's WriteCmd): where it runs this release\n"
    "  $cmd = Join-Path $bin \"$product.cmd\"\n"
    "  if (Test-Path -LiteralPath $cmd) {\n"
    "    $runs = Get-Content -Raw -LiteralPath $cmd -ErrorAction SilentlyContinue\n"
    "    if ($runs -and ($runs.Contains($app) -or $runs.Contains(\"%USERPROFILE%\\.$product\\app\"))) { Remove-Item -LiteralPath $cmd -Force -ErrorAction SilentlyContinue }\n"
    "  }\n"
    "  if (-not $kept.bin -and (Test-Path -LiteralPath $bin) -and -not (Get-ChildItem -Force -LiteralPath $bin)) {\n"
    "    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')\n"
    "    if ($userPath -and (($userPath -split ';') -contains $bin)) {\n"
    "      [Environment]::SetEnvironmentVariable('Path', ((@($userPath -split ';') | Where-Object { $_ -and $_ -ne $bin }) -join ';'), 'User')\n"
    "    }\n"
    "    Remove-Item -LiteralPath $bin -Force -ErrorAction SilentlyContinue\n"
    "  }\n"
    "  # (out of the release: this script and its command are in it)\n"
    "  Set-Location $env:TEMP\n"
    "  if ($purge) {\n"
    "    Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue\n"
    "    Write-Host \"stillfail: uninstalled, $full removed\"\n"
    "  } else {\n"
    "    foreach ($part in @('app', 'app.failed', 'node', 'helper', 'run', 'windows.json')) {\n"
    "      Remove-Item -LiteralPath (Join-Path $full $part) -Recurse -Force -ErrorAction SilentlyContinue\n"
    "    }\n"
    "    Get-ChildItem -LiteralPath $full -Directory -Filter 'app.old*' -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue\n"
    "    if (Test-Path -LiteralPath $full) { New-Item -ItemType File -Force (Join-Path $full 'uninstalled') | Out-Null }\n"
    "    Write-Host \"stillfail: uninstalled; chats, memory and secrets kept in $full\"\n"
    "  }\n"
    "  exit 0\n"
    "}\n";

// PowerShell's command line that runs it on `data` (UTF-8, the station's data directory: %USERPROFILE%\.stillfail or
// \.monoid): -EncodedCommand (UTF-16LE, base64), so the path goes in as a value whatever it holds, never as words of a
// command line. malloc'd; NULL for no data.
static char *station_uninstall_command(const char *data) {
  if (!data || !*data) return NULL;
  // the script: the path between PowerShell's single quotes (each one in it doubled), then the function, then its call
  size_t n = strlen(data), q = 0;
  for (size_t i = 0; i < n; i++) q += data[i] == '\'';
  const char *head = "$data = '", *mid = "'\n", *tail = "Uninstall $false\n";
  size_t sn = strlen(head) + n + q + strlen(mid) + sizeof station_uninstall_ps - 1 + strlen(tail);
  char *script = (char *)malloc(sn + 1);
  if (!script) return NULL;
  char *p = script;
  memcpy(p, head, strlen(head)), p += strlen(head);
  for (size_t i = 0; i < n; i++) {
    *p++ = data[i];
    if (data[i] == '\'') *p++ = '\'';
  }
  memcpy(p, mid, strlen(mid)), p += strlen(mid);
  memcpy(p, station_uninstall_ps, sizeof station_uninstall_ps - 1), p += sizeof station_uninstall_ps - 1;
  memcpy(p, tail, strlen(tail)), p += strlen(tail);
  *p = 0;
  // UTF-8 to UTF-16LE (a code point past the BMP as its pair)
  unsigned char *u = (unsigned char *)malloc(sn * 4 + 4);
  size_t un = 0;
  if (!u) {
    free(script);
    return NULL;
  }
  for (const unsigned char *s = (const unsigned char *)script; *s;) {
    unsigned int c = *s++;
    int more = c >= 0xF0 ? 3 : c >= 0xE0 ? 2 : c >= 0xC0 ? 1 : 0;
    c &= more == 3 ? 0x07 : more == 2 ? 0x0F : more == 1 ? 0x1F : 0x7F;
    for (; more > 0 && (*s & 0xC0) == 0x80; more--) c = (c << 6) | (*s++ & 0x3F);
    if (c >= 0x10000) {
      c -= 0x10000;
      unsigned int hi = 0xD800 + (c >> 10), lo = 0xDC00 + (c & 0x3FF);
      u[un++] = (unsigned char)hi, u[un++] = (unsigned char)(hi >> 8);
      u[un++] = (unsigned char)lo, u[un++] = (unsigned char)(lo >> 8);
    } else {
      u[un++] = (unsigned char)c, u[un++] = (unsigned char)(c >> 8);
    }
  }
  free(script);
  static const char b64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  const char *cmd = "powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ";
  char *out = (char *)malloc(strlen(cmd) + (un + 2) / 3 * 4 + 1);
  if (!out) {
    free(u);
    return NULL;
  }
  char *o = out + strlen(cmd);
  memcpy(out, cmd, strlen(cmd));
  for (size_t i = 0; i < un; i += 3) {
    unsigned int v = (unsigned int)u[i] << 16 | (i + 1 < un ? (unsigned int)u[i + 1] << 8 : 0) | (i + 2 < un ? u[i + 2] : 0);
    *o++ = b64[v >> 18 & 63];
    *o++ = b64[v >> 12 & 63];
    *o++ = i + 1 < un ? b64[v >> 6 & 63] : '=';
    *o++ = i + 2 < un ? b64[v & 63] : '=';
  }
  *o = 0;
  free(u);
  return out;
}
#endif
