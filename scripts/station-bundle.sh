#!/bin/sh
# Lays out the still.fail station's release in DIR/stillfail for PLATFORM (default darwin-arm64): the station in
# MoonBit (station/mb, scripts/native.ts `reader`: one program, no Node and no Node addon in the release) with the
# launcher that runs it and its other native parts, prebuilt (scripts/native.ts: launcher, runner), and the files it
# finds beside itself (station/package.json `build`: the skills, the agents' bridges and hooks, the phones' and
# Linux screens' helpers). scripts/release.sh packs it for install.sh. The layout:
#   stillfail/bin/stillfail                               (the command people and services run)
#   stillfail/bin/install.{zh,en}.sh                      (the installer the station updates itself by, verified with
#                                                          the release: scripts/installers.ts, scripts/release-sign.ts)
#   stillfail/mesh/target/release/stillfail-station       (the launcher, with the Rust station's command line and path:
#                                                          what the installer, bin/stillfail, the desktop app and
#                                                          services run; it runs station/stillfail-reader)
#   stillfail/station/{stillfail-reader, stillfail-runner, skills/, *-bridge.mjs, *-hook.mjs, scrcpy-server}
#                                                         (and on linux-* linux-portal.py, linux-x11.py; on darwin-arm64
#                                                          "still.fail Helper.app": the station's macOS app for what
#                                                          macOS grants §4; on win32-x64 stillfail-screen.exe: the
#                                                          desktop's screen, and agent-desktop.exe: its apps'
#                                                          accessibility trees, which the Helper carries on macOS)
#   stillfail/dist/admin/posthog.json                     (only the PostHog key the station reports errors with, when
#                                                          $STILLFAIL_POSTHOG names one: scripts/posthog-key.ts; the
#                                                          station finds its release as dist/admin's parent's parent)
#   stillfail/VERSION, BUILD                              (the commit; the commits in its history: version 0.1.<BUILD>)
# No NODE_VERSION: the installer gets and links a Node only for a release that names one (one from before, rolled back
# to: cloud/src/install.ts), and the launcher runs Node only for a release with station/main.js.
# On darwin-arm64 the native parts are signed when $STILLFAIL_SIGN_STATION is set (the station release job).
# On win32-x64 the executables are .exe, and the command is bin/stillfail.cmd (bin/stillfail.ps1 behind it); its
# installers are bin/install.{zh,en}.ps1.
#   station-bundle.sh DIR [darwin-arm64|linux-x64|linux-arm64|win32-x64]
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
out=${1:?usage: station-bundle.sh DIR [PLATFORM]}
platform=${2:-darwin-arm64}
case "$platform" in
  darwin-arm64|linux-x64|linux-arm64|win32-x64) ;;
  *) echo "no such platform: $platform" >&2; exit 1 ;;
esac
# Written afresh here, so a release never carries what an older build left in dist/admin (its page), nor an old key.
node "$root/scripts/posthog-key.ts" >&2
native() { node "$root/scripts/native.ts" file "$1" "$platform"; }
x=; [ "$platform" = win32-x64 ] && x=.exe
launcher="$(native launcher)"
runner="$(native runner)"
helper=; [ "$platform" = darwin-arm64 ] && helper="$(native helper)"
# The station in MoonBit (station/mb).
reader="$(native reader)"
screen=; [ "$platform" = win32-x64 ] && screen="$(native screen)"
tree=; [ "$platform" = win32-x64 ] && tree="$(native agent-desktop)"
# The build's output is the complete set of files the station finds beside itself, not a previous build's leftovers.
rm -rf "$root/station/dist"
(cd "$root/station" && pnpm run build >&2)
app="$out/stillfail"
rm -rf "$app"
mkdir -p "$app/bin" "$app/mesh/target/release" "$app/dist" "$app/station"
if [ "$platform" = win32-x64 ]; then
  cp "$root/bin/stillfail.cmd" "$root/bin/stillfail.ps1" "$app/bin/"
else
  cp "$root/bin/stillfail" "$app/bin/"
fi
node "$root/scripts/installers.ts" "$app/bin" "$platform"
cp -R "$root/dist/admin" "$app/dist/admin"
cp "$launcher" "$app/mesh/target/release/stillfail-station$x"
# And on Windows the launcher with no window beside it (what install.ps1's scheduled task runs; scripts/native.ts keeps
# it in the launcher's artifact).
[ "$platform" = win32-x64 ] && cp "$(dirname "$launcher")/stillfail-station-w.exe" "$app/mesh/target/release/"
cp "$runner" "$reader" "$app/station/"
[ -z "$helper" ] || cp -R "$helper" "$app/station/"
[ -z "$screen" ] || cp "$screen" "$app/station/"
[ -z "$tree" ] || cp "$tree" "$app/station/"
# macOS asks "find devices on local networks?" (the mesh's mDNS) for the launcher: the station and everything it
# starts are its. Ad hoc, the grant was its hash's: each new launcher asked again, and every station it started while
# unanswered put up one more. The station release job signs the native parts ($STILLFAIL_SIGN_STATION: .github/sign-station.sh), so
# a grant stays. Not signed is a warning, not a release missed: they are put again as they were (ad hoc), which works.
if [ "$platform" = darwin-arm64 ] && [ -n "${STILLFAIL_SIGN_STATION:-}" ]; then
  # The Helper's agent-desktop before the Helper, which seals it.
  hm="$app/station/still.fail Helper.app/Contents/MacOS"
  sh "$root/.github/sign-station.sh" "$app/mesh/target/release/stillfail-station" fail.still.station \
    "$app/station/$(basename "$runner")" fail.still.runner \
    "$app/station/stillfail-reader" fail.still.reader \
    "$hm/agent-desktop" fail.still.agent-desktop "$hm/agent-desktop-macos-helper" fail.still.agent-desktop-macos-helper \
    "$app/station/still.fail Helper.app" fail.still.helper >&2 ||
    { echo "::warning::the station's native parts were not signed (.github/sign-station.sh): ad hoc" >&2
      cp "$launcher" "$app/mesh/target/release/stillfail-station"; cp "$runner" "$reader" "$app/station/"
      rm -rf "$app/station/still.fail Helper.app"; cp -R "$helper" "$app/station/"; }
fi
# Every file the build lays out (station/package.json `build`), in new directories too: naming them here one by one
# left released stations without some.
cp -R "$root/station/dist/." "$app/station/"
case "$platform" in linux-*) ;; *) rm -f "$app/station/linux-portal.py" "$app/station/linux-x11.py" ;; esac
git -C "$root" rev-parse HEAD > "$app/VERSION"
git -C "$root" rev-list --count HEAD > "$app/BUILD"
