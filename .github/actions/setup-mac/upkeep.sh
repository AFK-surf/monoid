#!/bin/sh
# Hourly disk cleanup for persistent self-hosted runners on macos-ci (Mini1).
# Removes stale MoonBit cache units, old runner logs, timed-out temp directories,
# and Shutdown iOS Simulator wallpaper caches.
set -u

# station/mb/build.sh writes compiled MoonBit units to ~/stillfail-ci/reader-mbc-store.
# libs/mbui/tools/mbc/mbc.mbt touches each unit directory on use. Delete units unused for 12 hours.
if [ -d "$HOME/stillfail-ci/reader-mbc-store" ]; then
  find "$HOME/stillfail-ci/reader-mbc-store" -name '*.lock' -mmin +120 -delete 2>/dev/null || true
  find "$HOME/stillfail-ci/reader-mbc-store" -mindepth 2 -maxdepth 2 -type d -mmin +720 -exec rm -rf {} + 2>/dev/null || true
fi

# Delete closed Worker_*.log files after 1 day and older runner diagnostic logs after 3 days.
for diag in "$HOME"/actions-runner*/_diag; do
  [ -d "$diag" ] || continue
  find "$diag" -maxdepth 1 -type f -name 'Worker_*.log' -mtime +1 -delete 2>/dev/null || true
  find "$diag" -maxdepth 2 -type f -mtime +3 -delete 2>/dev/null || true
done

# Delete temp directories left behind when a CI job hits its timeout.
find "${TMPDIR:-/tmp}" -mindepth 1 -maxdepth 1 \( \
  -name 'selfhost-side-*' -o \
  -name 'release-delta-old-*' -o \
  -name 'stillfail-native-*' -o \
  -name 'stillfail-prebuild-*' -o \
  -name 'stillfail-store-sync-*' -o \
  -name 'download-artifact.*' \
\) -mmin +240 -exec rm -rf {} + 2>/dev/null || true

# Delete CoreSimulator temp directories whose simulator UUID no longer exists.
devs="$HOME/Library/Developer/CoreSimulator/Devices"
for simtmp in /private/var/tmp/com.apple.CoreSimulator.SimDevice.*; do
  [ -d "$simtmp" ] || continue
  [ -n "$(find "$simtmp" -maxdepth 0 -mmin +240 2>/dev/null)" ] || continue
  uuid=${simtmp##*.SimDevice.}
  if [ ! -d "$devs/$uuid" ]; then
    rm -rf "$simtmp" 2>/dev/null || true
  fi
done

# Delete unavailable simulator devices and PosterBoard wallpaper caches on Shutdown devices (state == 1).
# Skip without waiting if an iOS test holds ~/.mbui-ios-sim.lock.
lock=${MBUI_IOS_LOCK:-$HOME/.mbui-ios-sim.lock}
if mkdir "$lock" 2>/dev/null; then
  (
    trap 'rm -rf "$lock" 2>/dev/null || true' EXIT INT TERM
    printf 'setup-mac upkeep\npid %s\n' "$$" > "$lock/owner" 2>/dev/null || true
    xcrun simctl delete unavailable >/dev/null 2>&1 || true
    for dev in "$devs"/*; do
      [ -f "$dev/device.plist" ] || continue
      state=$(plutil -extract state raw -o - "$dev/device.plist" 2>/dev/null || true)
      [ "$state" = 1 ] || continue
      rm -rf "$dev/data/Library/Application Support/PRBPosterExtensionDataStore" \
             "$dev/data/Library/Application Support/com.apple.PosterKit/trash" 2>/dev/null || true
    done
  )
fi
