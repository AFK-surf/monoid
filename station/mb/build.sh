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
# --harness builds the tests' program instead (src/reader_harness: every package's harness, `--builder harness-*`,
# station/test/mb-*.test.ts), into _build/stillfail-reader-harness-TARGET by default: kept out of the reader every
# station runs, built the same way, with the same MBC_STORE.
#   build.sh [--harness] [TARGET] [OUT]
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$D/../.." && pwd)"
pkg=reader name=stillfail-reader
if [ "${1:-}" = --harness ]; then
  pkg=reader_harness name=stillfail-reader-harness
  shift
fi
[ -n "${MBUI_TOOLS:-}" ] && export MOON_HOME=$MBUI_TOOLS/moon PATH=$MBUI_TOOLS/moon/bin:$PATH
default_target=darwin-arm64
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) default_target=linux-x64 ;;
  Linux-aarch64|Linux-arm64) default_target=linux-arm64 ;;
esac
target=${1:-$default_target}
out=${2:-$D/_build/$name-$target}
case "$target" in
  darwin-arm64) cc=(cc -arch arm64 -mmacosx-version-min=11.0); ar=(ar); part=shell-apple; init_flags="-O0"
    libs=(-framework SystemConfiguration -framework Security -framework CoreFoundation -framework Foundation -liconv -lobjc -Wl,-dead_strip) ;;
  # zig cc turns on UBSan in every unit at -O0 while the -O2 link leaves its runtime out: -fno-sanitize=undefined on
  # moonbit_init, and on every unit when opt is -O0 (flags, cflags below).
  linux-x64) cc=(zig cc -target x86_64-linux-gnu.2.28); ar=(zig ar); part=shell-station; init_flags="-O0 -fno-sanitize=undefined"
    libs=(-lunwind -lutil -lrt -lpthread -lm -ldl -lc -Wl,--gc-sections -s) ;;
  linux-arm64) cc=(zig cc -target aarch64-linux-gnu.2.28); ar=(zig ar); part=shell-station; init_flags="-O0 -fno-sanitize=undefined"
    libs=(-lunwind -lutil -lrt -lpthread -lm -ldl -lc -Wl,--gc-sections -s) ;;
  win32-x64) cc=(zig cc -target x86_64-windows-gnu); ar=(zig ar); part=shell-station; init_flags="-O0 -fno-sanitize=undefined"
    libs=(-lshell32 -liphlpapi -lbcrypt -ladvapi32 -lkernel32 -lntdll -luserenv -lws2_32 -ldbghelp -lunwind -s) ;;
  *) echo "build.sh: no target $target" >&2; exit 2 ;;
esac
shell_lib=${SHELL_LIB:-$(node "$ROOT/scripts/native.ts" path $part $target)/libstillfail_shell.a}

work="$D/_build/link-$pkg-$target-$$"
rm -rf "$work"
mkdir -p "$work/runtime" "$work/obj" "$D/_build" "$(dirname "$out")"
# On GitHub's hosted macOS runner (3 cores, cold store), a branch's reader compiles at -O0 (~30 s) within the
# job's 5 minutes; main and self-hosted runners stay -O2. STATION_READER_OPT says it otherwise.
opt=-O2
if [ "${RUNNER_ENVIRONMENT:-}" = github-hosted ] && [ "${GITHUB_REF:-}" != refs/heads/main ]; then
  opt=-O0
fi
opt=${STATION_READER_OPT:-$opt}
if [ -z "${MBC_STORE:-}" ]; then
  if [ -d "$HOME/stillfail-ci" ]; then
    export MBC_STORE="$HOME/stillfail-ci/reader-mbc-store"
  else
    export MBC_STORE="${XDG_CACHE_HOME:-$HOME/.cache}/stillfail-reader-mbc"
  fi
fi
mkdir -p "$MBC_STORE"
# A first link for Windows makes zig build MinGW's CRT, its import libraries, libunwind and compiler_rt from source
# (~85 s on a hosted runner with ~/.cache/zig cold, the final link's 4 s otherwise): an empty program linked so in the
# background puts them in zig's cache while moon, cprep and mbc's split run here, mostly on one core; the final link
# waits for it.
warm_pid=
trap '[ -z "${warm_pid:-}" ] || kill "$warm_pid" 2>/dev/null || true; rm -rf "$work"' EXIT
if [ "$target" = win32-x64 ]; then
  printf 'int main(void){return 0;}\n' | "${cc[@]}" "$opt" -x c - -o "$work/warm.exe" "${libs[@]}" >/dev/null 2>&1 &
  warm_pid=$!
fi

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
  held_gen=
  trap '[ -z "${held_gen:-}" ] || rm -rf "$held_gen"; rm -rf "$lock"' EXIT
  "$ROOT/libs/mbui/scripts/mbc" path >/dev/null
  cd "$D"
  # The prepared C is one for every target: a target built after another of the same sources and moon takes it as it
  # was made (prepped-$pkg.key, by content, not by git), not making it again (moon build and cprep, ~40 s each).
  # moon version --all ends each line with the tool's path, which differs between ci-1's runners (each its own
  # MOON_HOME): without it, the runners share reader-mbc-prepped and cprep.
  gen_key=$( {
    moon version --all | sed 's|)[[:space:]].*$|)|'
    "$ROOT/libs/mbui/scripts/mbc" key
    find "$D/moon.mod" "$D/moon.work" "$D/build.sh" "$ROOT/rules/moon.mod" "$ROOT/libs/mbui/moon.mod" \
      "$ROOT/libs/mbui/scripts/mbc-stub.sh" "$ROOT/libs/base/moon.mod" "$D/src" "$ROOT/rules/src" "$ROOT/libs/base/src" "$ROOT/libs/mbui/src/effect" \
      "$ROOT/libs/mbui/src/halt" -type f ! -name '*_test.mbt' ! -name '*_wbtest.mbt' ! -name pkg.generated.mbti \
      | LC_ALL=C sort | xargs shasum | sed "s|  $ROOT/|  |"
  } | shasum | awk '{print $1}')
  prepped="$D/_build/prepped-$pkg.c"
  # On a CI machine that keeps ~/stillfail-ci (ci-1, Mini1), the prepared C is shared by its runners, each with a
  # checkout of its own (main's natives and natives-win-reader-main made it one after the other, ~30 s each): kept by
  # gen_key beside the units' store, never in MBC_STORE, which GitHub's runners save to the Actions cache (120 MB).
  # Made by one runner at a time (gen-$pkg-$gen_key.lock), each looking again once it holds the lock.
  shared_prepped=
  if [ -d "$HOME/stillfail-ci" ]; then
    prepped_dir="$HOME/stillfail-ci/reader-mbc-prepped"
    mkdir -p "$prepped_dir"
    shared_prepped="$prepped_dir/prepped-$pkg-$gen_key.c"
    if [ ! -f "$shared_prepped" ]; then
      gen_lock="$prepped_dir/gen-$pkg-$gen_key.lock"
      while ! mkdir "$gen_lock" 2>/dev/null; do
        pid=$(cat "$gen_lock/pid" 2>/dev/null || echo 0)
        if gone "$pid"; then rm -rf "$gen_lock"; continue; fi
        sleep 0.1
      done
      held_gen=$gen_lock
      echo "$$" > "$gen_lock/pid"
    fi
    if [ -f "$shared_prepped" ]; then
      touch -c "$shared_prepped" 2>/dev/null || true
      cp "$shared_prepped" "$work/reader.c"
      echo "build.sh: $pkg.c as this machine prepared it for $gen_key" >&2
      exit 0
    fi
  fi
  if [ -z "$shared_prepped" ] && [ -f "$prepped" ] && [ "$(cat "$D/_build/prepped-$pkg.key" 2>/dev/null)" = "$gen_key" ]; then
    cp "$prepped" "$work/reader.c"
    echo "build.sh: $pkg.c as prepared for $gen_key" >&2
    exit 0
  fi
  # cprep compiled for this machine, kept in MBC_STORE by what it is made of (moon, the machine, its sources): made
  # only where none is kept, beside the reader's moon build (src/cprep reads only moonbitlang/core, in a target
  # directory of its own in $work), not after it (~70 s of one core on a hosted Mac, 2026-11-19).
  cprep_key=$({
    moon version --all | sed 's|)[[:space:]].*$|)|'
    uname -sm
    if [ -d "$D/src/cprep" ]; then
      find "$D/src/cprep" -type f ! -name '*_test.mbt' ! -name '*_wbtest.mbt' ! -name pkg.generated.mbti \
        | LC_ALL=C sort | xargs shasum | sed "s|  $ROOT/|  |"
    fi
  } | shasum | awk '{print $1}')
  cprep_bin="$MBC_STORE/cprep-$cprep_key.exe"
  cprep_pid=
  trap '[ -z "${cprep_pid:-}" ] || kill "$cprep_pid" 2>/dev/null || true; [ -z "${held_gen:-}" ] || rm -rf "$held_gen"; rm -rf "$lock"' EXIT
  if [ ! -x "$cprep_bin" ]; then
    env -u MOON_CC -u MOON_AR moon build --target native --release --target-dir "$work/cprep" src/cprep >"$work/cprep-build.log" 2>&1 &
    cprep_pid=$!
  else
    touch -c "$cprep_bin" 2>/dev/null || true
  fi
  # moon writes to a file of its own, shown only where it failed: the targets build at once on one stderr, which
  # another build leaves non-blocking, and moon aborts on the EAGAIN a full pipe gives as it writes a warning
  # (2026-11-15, CI's win32-x64 reader: "internal rendering error: Os { code: 35 }").
  if ! MOON_CC="$ROOT/libs/mbui/scripts/mbc-stub.sh" MOON_AR="$ROOT/libs/mbui/scripts/mbc-stub.sh" \
    moon build --target native --release "src/$pkg" >"$work/moon.log" 2>&1; then
    cat "$work/moon.log" >&2
    exit 1
  fi
  if [ -n "$cprep_pid" ]; then
    if ! wait "$cprep_pid"; then
      cat "$work/cprep-build.log" >&2
      exit 1
    fi
    cprep_pid=
    cp "$work/cprep/native/release/build/station/cprep/cprep.exe" "$cprep_bin.$$" \
      && mv -f "$cprep_bin.$$" "$cprep_bin"
  fi
  if [ -n "$shared_prepped" ]; then
    "$cprep_bin" "$D/_build/native/release/build/station/$pkg/$pkg.c" "$shared_prepped.tmp.$$" >&2
    mv -f "$shared_prepped.tmp.$$" "$shared_prepped"
    cp "$shared_prepped" "$work/reader.c"
    exit 0
  fi
  "$cprep_bin" "$D/_build/native/release/build/station/$pkg/$pkg.c" "$prepped.tmp.$$" >&2
  rm -f "$D/_build/prepped-$pkg.key"
  mv "$prepped.tmp.$$" "$prepped"
  echo "$gen_key" > "$D/_build/prepped-$pkg.key"
  cp "$prepped" "$work/reader.c"
)

moon_home=${MOON_HOME:-$(dirname "$(dirname "$(command -v moon)")")}

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
flags=(-I"$moon_inc" "$opt" -fwrapv -fno-strict-aliasing -ffp-contract=off -Wno-unused-value -DMOONBIT_TRIAL_DELETION=1)
cflags="-I\"$moon_inc\" $opt -fwrapv -fno-strict-aliasing -ffp-contract=off -Wno-unused-value -DMOONBIT_TRIAL_DELETION=1"
if [ "${cc[0]}" = zig ] && [ "$opt" = -O0 ]; then
  flags+=(-fno-sanitize=undefined)
  cflags="$cflags -fno-sanitize=undefined"
fi

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
  # (each waited for by its own pid: a bare wait would take the Windows warm-up's too)
  rt_pids=()
  for c in "$moon_home"/lib/runtime/*.c; do
    "${cc[@]}" "${flags[@]}" -c "$c" -o "$work/runtime/$(basename "$c" .c).o" 2> /dev/null &
    rt_pids+=($!)
  done
  for p in ${rt_pids[@]+"${rt_pids[@]}"}; do wait "$p" || true; done
  "${ar[@]}" rcs "$work/libruntime.a" "$work"/runtime/*.o
  cp "$work/libruntime.a" "$rt_cache.$$" && mv "$rt_cache.$$" "$rt_cache"
fi
[ -z "$warm_pid" ] || wait "$warm_pid" || true
"${cc[@]}" "${flags[@]}" -o "$out" "${objs[@]}" ${link_extra[@]+"${link_extra[@]}"} \
  "$rt_cache" "$shell_lib" "${libs[@]}"
# Units unused for 12 hours leave the store (mbc touches a unit's directory on each use), as CI's upkeep.sh removes
# them: where nothing else does (a person's machine, a station whose agents build), it held 35 GiB.
find "$MBC_STORE" -mindepth 2 -maxdepth 2 -type d -mmin +720 -exec rm -rf {} + 2>/dev/null || true
echo "$out"
