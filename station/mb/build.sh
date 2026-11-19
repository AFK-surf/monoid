#!/bin/bash
# Builds the station's reader in MoonBit (station/mb) for TARGET (this machine's by default: darwin-arm64, linux-x64,
# linux-arm64, win32-x64), on a Mac or a Linux x86-64 machine, into OUT (default _build/stillfail-reader-TARGET).
# MoonBit makes the program's C here (with mbc-stub.sh so moon skips its host compile and link); src/cprep makes it
# ready for mbui's mbc (a result of what raises named by its definition, a function of 200 KB or more, a coroutine's
# state machine, not optimised, #line's paths relative), which splits it into units and compiles them in parallel across all cores
# (moonbit_init at -O0, unchanged units kept in MBC_STORE), then links for each target (zig cc for Linux, glibc 2.28
# on, and for Windows, MinGW's), with MoonBit's runtime from its source, its reference cycles collected
# (MOONBIT_TRIAL_DELETION) on the system allocator. Linked to the shell's static library (client/shell), which
# SHELL_LIB names, or scripts/native.ts gets for the target (shell-apple on the Mac, shell-station elsewhere).
# MBUI_TOOLS, as apps/mbui's scripts have it, says where moon is when it is not on PATH.
#   build.sh [TARGET] [OUT]
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$D/../.." && pwd)"
[ -n "${MBUI_TOOLS:-}" ] && export MOON_HOME=$MBUI_TOOLS/moon PATH=$MBUI_TOOLS/moon/bin:$PATH
default_target=darwin-arm64
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) default_target=linux-x64 ;;
  Linux-aarch64|Linux-arm64) default_target=linux-arm64 ;;
esac
target=${1:-$default_target}
out=${2:-$D/_build/stillfail-reader-$target}
case "$target" in
  darwin-arm64) cc=(cc -arch arm64 -mmacosx-version-min=11.0); ar=(ar); part=shell-apple; init_flags="-O0"
    libs=(-framework SystemConfiguration -framework Security -framework CoreFoundation -framework Foundation -liconv -lobjc -Wl,-dead_strip) ;;
  # zig cc turns on UBSan at -O0 while the -O2 link leaves its runtime out: -fno-sanitize=undefined on moonbit_init.
  linux-x64) cc=(zig cc -target x86_64-linux-gnu.2.28); ar=(zig ar); part=shell-station; init_flags="-O0 -fno-sanitize=undefined"
    libs=(-lunwind -lutil -lrt -lpthread -lm -ldl -lc -Wl,--gc-sections -s) ;;
  linux-arm64) cc=(zig cc -target aarch64-linux-gnu.2.28); ar=(zig ar); part=shell-station; init_flags="-O0 -fno-sanitize=undefined"
    libs=(-lunwind -lutil -lrt -lpthread -lm -ldl -lc -Wl,--gc-sections -s) ;;
  win32-x64) cc=(zig cc -target x86_64-windows-gnu); ar=(zig ar); part=shell-station; init_flags="-O0 -fno-sanitize=undefined"
    libs=(-lshell32 -liphlpapi -lbcrypt -ladvapi32 -lkernel32 -lntdll -luserenv -lws2_32 -ldbghelp -lunwind -s) ;;
  *) echo "build.sh: no target $target" >&2; exit 2 ;;
esac
shell_lib=${SHELL_LIB:-$(node "$ROOT/scripts/native.ts" path $part $target)/libstillfail_shell.a}

work="$D/_build/link-$target-$$"
rm -rf "$work"
mkdir -p "$work/runtime" "$work/obj" "$D/_build" "$(dirname "$out")"
trap 'rm -rf "$work"' EXIT

# Serialize moon's C generation (and any first-time build of mbc) across concurrent target builds, copying reader.c into
# this build's own directory before releasing the lock so another target's `moon build` never rewrites reader.c under cc.
# (a lock's holder gone: no such process, not merely another user's, which kill -0 cannot signal)
gone() { [ "${1:-0}" -gt 0 ] 2>/dev/null && ! kill -0 "$1" 2>/dev/null && ! ps -p "$1" >/dev/null 2>&1; }
lock="$D/_build/moon-gen.lock"
while ! mkdir "$lock" 2>/dev/null; do
  pid=$(cat "$lock/pid" 2>/dev/null || echo 0)
  if gone "$pid"; then rm -rf "$lock"; continue; fi
  sleep 0.1
done
echo "$$" > "$lock/pid"
(
  trap 'rm -rf "$lock"' EXIT
  "$ROOT/libs/mbui/scripts/mbc" path >/dev/null
  cd "$D"
  # The prepared C is one for every target: a target built after another of the same sources and moon takes it as it
  # was made (prepped-reader.key, by content, not by git), not making it again (moon build and cprep, ~40 s each).
  gen_key=$( {
    moon version --all
    "$ROOT/libs/mbui/scripts/mbc" key
    find "$D/moon.mod" "$D/moon.work" "$D/build.sh" "$ROOT/rules/moon.mod" "$ROOT/libs/mbui/moon.mod" \
      "$ROOT/libs/mbui/scripts/mbc-stub.sh" "$ROOT/libs/base/moon.mod" "$D/src" "$ROOT/rules/src" "$ROOT/libs/base/src" "$ROOT/libs/mbui/src/effect" \
      "$ROOT/libs/mbui/src/halt" -type f ! -name '*_test.mbt' ! -name '*_wbtest.mbt' ! -name pkg.generated.mbti \
      | LC_ALL=C sort | xargs shasum | sed "s|  $ROOT/|  |"
  } | shasum | awk '{print $1}')
  prepped="$D/_build/prepped-reader.c"
  if [ -f "$prepped" ] && [ "$(cat "$D/_build/prepped-reader.key" 2>/dev/null)" = "$gen_key" ]; then
    cp "$prepped" "$work/reader.c"
    echo "build.sh: reader.c as prepared for $gen_key" >&2
    exit 0
  fi
  # moon writes to a file of its own, shown only where it failed: the targets build at once on one stderr, which
  # another build leaves non-blocking, and moon aborts on the EAGAIN a full pipe gives as it writes a warning
  # (2026-11-15, CI's win32-x64 reader: "internal rendering error: Os { code: 35 }").
  if ! MOON_CC="$ROOT/libs/mbui/scripts/mbc-stub.sh" MOON_AR="$ROOT/libs/mbui/scripts/mbc-stub.sh" \
    moon build --target native --release src/reader >"$work/moon.log" 2>&1; then
    cat "$work/moon.log" >&2
    exit 1
  fi
  # (cprep compiled for this machine, in a build directory of its own: the reader's is moon's with the stand-ins)
  if ! env -u MOON_CC -u MOON_AR moon build --target native --release --target-dir "$D/_build/cprep" src/cprep >"$work/cprep-build.log" 2>&1; then
    cat "$work/cprep-build.log" >&2
    exit 1
  fi
  "$D/_build/cprep/native/release/build/station/cprep/cprep.exe" \
    "$D/_build/native/release/build/station/reader/reader.c" "$prepped.tmp.$$" >&2
  rm -f "$D/_build/prepped-reader.key"
  mv "$prepped.tmp.$$" "$prepped"
  echo "$gen_key" > "$D/_build/prepped-reader.key"
  cp "$prepped" "$work/reader.c"
)

moon_home=${MOON_HOME:-$(dirname "$(dirname "$(command -v moon)")")}

if [ -z "${MBC_STORE:-}" ]; then
  if [ -d "$HOME/stillfail-ci" ]; then
    export MBC_STORE="$HOME/stillfail-ci/reader-mbc-store"
  else
    export MBC_STORE="${XDG_CACHE_HOME:-$HOME/.cache}/stillfail-reader-mbc"
  fi
fi
mkdir -p "$MBC_STORE"

# moonbit.h from a directory of the store named by its content, not moon's: each runner of a machine has a moon of its
# own (CI's ci-1: actions-runner-<n>/_tool/moon-ci), and a unit's command and the headers it read are its key in the
# store, so no runner took another's units (2026-11-17).
moon_inc_key=$(shasum "$moon_home/include/moonbit.h" | awk '{print $1}')
moon_inc="$MBC_STORE/moon-include-$moon_inc_key"
if [ ! -f "$moon_inc/moonbit.h" ]; then
  tmp_inc="$moon_inc.tmp.$$"
  rm -rf "$tmp_inc"
  mkdir -p "$tmp_inc"
  cp "$moon_home"/include/*.h "$tmp_inc/"
  mv "$tmp_inc" "$moon_inc" 2>/dev/null || rm -rf "$tmp_inc"
fi
# On GitHub's hosted macOS runner (3 cores, cold store), a branch's reader compiles at -O0 (~30 s) within the
# job's 5 minutes; main and self-hosted runners stay -O2. STATION_READER_OPT says it otherwise.
opt=-O2
if [ "${RUNNER_ENVIRONMENT:-}" = github-hosted ] && [ "${GITHUB_REF:-}" != refs/heads/main ]; then
  opt=-O0
fi
opt=${STATION_READER_OPT:-$opt}
flags=(-I"$moon_inc" "$opt" -fwrapv -fno-strict-aliasing -ffp-contract=off -Wno-unused-value -DMOONBIT_TRIAL_DELETION=1)
cflags="-I\"$moon_inc\" $opt -fwrapv -fno-strict-aliasing -ffp-contract=off -Wno-unused-value -DMOONBIT_TRIAL_DELETION=1"

# mbc's jobs: the machine's cores shared by the readers built side by side (STILLFAIL_NATIVE_READERS, as CI's natives
# jobs say it; where scripts/native.ts only says it builds several, STILLFAIL_NATIVE_ONE, 3 for its three side by side
# on Linux, 1 for darwin-arm64, the one reader of its Apple parts: 3 there gave -j 1 on macos-26's 3 cores, 134032580996
# cut at its 5 minutes), 2 each at least: not each every core (48 zig cc on ci-1's 16 threads, a unit of 159 s and
# main's natives job cut at its 5 minutes, 44012291121), not one after another (each one's slowest units left alone:
# 193 s for three on Studio, 133 s side by side), not a third each for two (4 of 16 threads idle, 133865942310 cut at
# 271 s). MBC_JOBS says it otherwise.
cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
npar=${STILLFAIL_NATIVE_READERS:-$([ "${STILLFAIL_NATIVE_ONE:-}" = 1 ] && [ "$target" != darwin-arm64 ] && echo 3 || echo 1)}
[ "$npar" -ge 1 ] 2>/dev/null || npar=1
if [ -n "${MBC_JOBS:-}" ]; then
  mbc_jobs=$MBC_JOBS
else
  mbc_jobs=$(( (cores + npar - 1) / npar ))
  [ "$npar" -le 1 ] || [ "$mbc_jobs" -ge 2 ] || mbc_jobs=2
fi

extras=()
for c in "$D"/src/*/*.c; do
  [ "$c" = "$D/src/cprep/io.c" ] && continue # (cprep's own, no part of the reader)
  extras+=("--extra=$c")
done

"$ROOT/libs/mbui/scripts/mbc" compile \
  "--cc=${cc[*]}" \
  "--cflags=$cflags" \
  "--init-flags=$init_flags" \
  -j "$mbc_jobs" \
  "--obj=$work/obj" \
  "--link-flags=$work/link-flags.txt" \
  "${extras[@]}" \
  "$work/reader.c" > "$work/objs.txt"

objs=()
while IFS= read -r o; do
  [ -n "$o" ] && objs+=("$o")
done < "$work/objs.txt"

link_extra=()
if [ -s "$work/link-flags.txt" ]; then
  # shellcheck disable=SC2206
  link_extra=($(cat "$work/link-flags.txt"))
fi

# MoonBit's runtime for the target: each of its files that builds there (the others are moonbitlang/async's, which the
# program does not use, and which on Windows build with MSVC only), in an archive the link takes what it needs from,
# kept in MBC_STORE by what it is made of (the compiler, its flags, the runtime's sources and headers): made again only
# when one of them changed, its files compiled side by side.
rt_key=$({
  echo "$target"; echo "${cc[*]}"; echo "${flags[*]}"; echo "${ar[*]}"
  "${cc[@]}" --version 2>&1 | head -1
  for f in "$moon_home"/lib/runtime/*.c "$moon_home"/include/*.h; do
    [ -f "$f" ] && { echo "${f#"$moon_home"/}"; cat "$f"; }
  done
} | cksum | tr ' ' -)
rt_cache="$MBC_STORE/libruntime-$target-$rt_key.a"
if [ ! -s "$rt_cache" ]; then
  for c in "$moon_home"/lib/runtime/*.c; do
    "${cc[@]}" "${flags[@]}" -c "$c" -o "$work/runtime/$(basename "$c" .c).o" 2> /dev/null &
  done
  wait
  "${ar[@]}" rcs "$work/libruntime.a" "$work"/runtime/*.o
  cp "$work/libruntime.a" "$rt_cache.$$" && mv "$rt_cache.$$" "$rt_cache"
fi
"${cc[@]}" "${flags[@]}" -o "$out" "${objs[@]}" ${link_extra[@]+"${link_extra[@]}"} \
  "$rt_cache" "$shell_lib" "${libs[@]}"
echo "$out"
