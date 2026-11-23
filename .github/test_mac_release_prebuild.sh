#!/bin/bash
# Exercise the background build's ordering and failures without building an app or touching the real cache.
set -eu
script=$(cd "$(dirname "$0")" && pwd)/mac-release-prebuild.sh
app_mac=$(cd "$(dirname "$0")/.." && pwd)/apps/mbui/scripts/mac.sh
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
case_dir() {
  export GITHUB_WORKSPACE="$root/$1/work" RUNNER_TEMP="$root/$1/temp" RUNNER_TOOL_CACHE="$root/$1/tools"
  mkdir -p "$GITHUB_WORKSPACE/apps/mbui/scripts" "$GITHUB_WORKSPACE/libs/ui/scripts" \
    "$GITHUB_WORKSPACE/apps/mbui/_build" "$RUNNER_TEMP" "$RUNNER_TOOL_CACHE"
  cat > "$GITHUB_WORKSPACE/apps/mbui/scripts/env.sh" <<'EOF'
A="$GITHUB_WORKSPACE/apps/mbui"
MBUI_DIR="$GITHUB_WORKSPACE/libs/ui"
export A MBUI_DIR
EOF
  cat > "$GITHUB_WORKSPACE/apps/mbui/scripts/core.sh" <<'EOF'
#!/bin/bash
set -eu
[ "$MACOSX_DEPLOYMENT_TARGET" = 12.0 ]
[ "$CARGO_TARGET_DIR" = "$GITHUB_WORKSPACE/apps/mbui/out/core-target-macos12.0" ]
case "$*" in
  'apple-native aarch64-apple-darwin')
    [ "${FAIL_CORE:-0}" = 0 ] || exit 7
    mkdir -p "$GITHUB_WORKSPACE/apps/mbui/out/core"
    if [ ! -e "$RUNNER_TEMP/core-finished" ]; then
      touch "$RUNNER_TEMP/core-finished"
      [ ! -p "$RUNNER_TEMP/core-signal" ] || printf 'ready\n' > "$RUNNER_TEMP/core-signal"
    fi
    ;;
  'hermes apple')
    [ ! -e "$RUNNER_TEMP/mac-prebuild/packages-pending" ] || exit 11
    [ "${FAIL_HBC:-0}" = 0 ] || exit 9
    touch "$RUNNER_TEMP/bytecode-built"
    ;;
  *) exit 10 ;;
esac
EOF
  cp "$app_mac" "$GITHUB_WORKSPACE/apps/mbui/scripts/mac.sh"
  cat > "$GITHUB_WORKSPACE/libs/ui/scripts/chk" <<'EOF'
#!/bin/bash
[ "$1" = logwait ] && [ "$2" = --gone ] || exit 12
while [ -e "$3" ]; do sleep 0.1; done
EOF
  chmod +x "$GITHUB_WORKSPACE/libs/ui/scripts/chk"
  cat > "$GITHUB_WORKSPACE/libs/ui/scripts/mac.sh" <<'EOF'
#!/bin/bash
set -eu
[ "$*" = build ]
[ "$APP" = stillfail ] && [ "$MODE" = release ]
[ "$MOON_HOME" = "$RUNNER_TOOL_CACHE/moon-ci" ]
touch "$RUNNER_TEMP/app-built"
[ "${FAIL_APP:-0}" = 0 ] || exit 8
[ "${SAY_NEWER:-0}" = 0 ] || echo "ld: warning: object file (x.o) was built for newer macOS version (15.0) than being linked (12.0)"
# (the app, with libghostty-vt's calls unless NO_GHOSTTY: the app's mac.sh fails one without them)
exe="$A/_build/native/release/build/stillfail/stillfail/stillfail.exe"
mkdir -p "$(dirname "$exe")"
if [ "${NO_GHOSTTY:-0}" = 0 ]; then c='int ghostty_terminal_new(void) { return 0; } int main(void) { return 0; }'; else c='int main(void) { return 0; }'; fi
printf '%s\n' "$c" | cc -x c - -o "$exe"
EOF
}
case_dir exit_race
mkdir -p "$RUNNER_TEMP/mac-prebuild"
printf '99999999\n' > "$RUNNER_TEMP/mac-prebuild/pid"
: > "$RUNNER_TEMP/mac-prebuild/log"
# The worker can write its result and exit after wait checks the file but before it probes the PID.
kill() {
  [ "$1" = -0 ] && [ "$2" = 99999999 ] || return 2
  printf '0\n' > "$RUNNER_TEMP/mac-prebuild/status"
  return 1
}
export -f kill
bash "$script" wait
unset -f kill

case_dir dead_worker
mkdir -p "$RUNNER_TEMP/mac-prebuild"
printf '99999999\n' > "$RUNNER_TEMP/mac-prebuild/pid"
: > "$RUNNER_TEMP/mac-prebuild/log"
if bash "$script" wait; then echo 'a worker that exited without a result was not reported' >&2; exit 1; fi

case_dir order
echo 12.0 > "$GITHUB_WORKSPACE/apps/mbui/_build/.macos-min"
mkfifo "$RUNNER_TEMP/core-signal"
bash "$script" start
read -r ready < "$RUNNER_TEMP/core-signal"
[ "$ready" = ready ]
[ -f "$RUNNER_TEMP/core-finished" ] && [ ! -e "$RUNNER_TEMP/app-built" ]
bash "$script" ready
bash "$script" packages
bash "$script" wait
[ -f "$RUNNER_TEMP/app-built" ]
[ -f "$RUNNER_TEMP/bytecode-built" ] || { echo 'core bytecode was not prepared before packaging' >&2; exit 1; }
[ -f "$RUNNER_TEMP/mac-prebuild/built" ] || { echo 'a whole build did not say built (MBUI_BUILT)' >&2; exit 1; }

# No Moon build for this macOS restored (none, or another's): what was built for another goes, the marker is written,
# the core just built is kept, and the app is built here all the same.
for before in none 11.0; do
  case_dir "uncached-$before"
  mkdir -p "$GITHUB_WORKSPACE/apps/mbui/out/mbc"
  touch "$GITHUB_WORKSPACE/apps/mbui/_build/old-unit" "$GITHUB_WORKSPACE/apps/mbui/out/mbc/old-object"
  [ "$before" = none ] || echo "$before" > "$GITHUB_WORKSPACE/apps/mbui/_build/.macos-min"
  bash "$script" start
  bash "$script" ready
  bash "$script" packages
  bash "$script" wait
  [ "$(cat "$GITHUB_WORKSPACE/apps/mbui/_build/.macos-min")" = 12.0 ] || { echo "uncached-$before: no marker for 12.0" >&2; exit 1; }
  [ ! -e "$GITHUB_WORKSPACE/apps/mbui/_build/old-unit" ] && [ ! -e "$GITHUB_WORKSPACE/apps/mbui/out/mbc/old-object" ] || { echo "uncached-$before: another macOS's build kept" >&2; exit 1; }
  [ -d "$GITHUB_WORKSPACE/apps/mbui/out/core" ] && [ -f "$RUNNER_TEMP/core-finished" ] || { echo "uncached-$before: the core built was taken away" >&2; exit 1; }
  [ -f "$RUNNER_TEMP/app-built" ] && [ -f "$RUNNER_TEMP/bytecode-built" ] || { echo "uncached-$before: the app was not built" >&2; exit 1; }
done

case_dir core_failure
export FAIL_CORE=1
bash "$script" start
if bash "$script" wait; then echo 'native failure was not reported' >&2; exit 1; fi
unset FAIL_CORE

case_dir app_failure
echo 12.0 > "$GITHUB_WORKSPACE/apps/mbui/_build/.macos-min"
export FAIL_APP=1
bash "$script" start
bash "$script" ready
bash "$script" packages
if bash "$script" wait; then echo 'app failure was not reported' >&2; exit 1; fi
[ ! -e "$RUNNER_TEMP/mac-prebuild/built" ] || { echo 'a failed build said built' >&2; exit 1; }
unset FAIL_APP

case_dir newer_macos
echo 12.0 > "$GITHUB_WORKSPACE/apps/mbui/_build/.macos-min"
export SAY_NEWER=1
bash "$script" start
bash "$script" ready
bash "$script" packages
if bash "$script" wait; then echo 'a build for a newer macOS was not reported' >&2; exit 1; fi
[ ! -e "$RUNNER_TEMP/mac-prebuild/built" ] || { echo 'a build for a newer macOS said built' >&2; exit 1; }
unset SAY_NEWER

case_dir no_terminal
echo 12.0 > "$GITHUB_WORKSPACE/apps/mbui/_build/.macos-min"
export NO_GHOSTTY=1
bash "$script" start
bash "$script" ready
bash "$script" packages
if bash "$script" wait; then echo 'an app without libghostty-vt was not reported' >&2; exit 1; fi
unset NO_GHOSTTY

case_dir bytecode_failure
echo 12.0 > "$GITHUB_WORKSPACE/apps/mbui/_build/.macos-min"
export FAIL_HBC=1
bash "$script" start
bash "$script" ready
bash "$script" packages
if bash "$script" wait; then echo 'bytecode failure was not reported' >&2; exit 1; fi
unset FAIL_HBC
echo 'Mac prebuild ordering and failure handling passed'
