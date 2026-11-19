#!/bin/bash
# station/mb/build.sh with every tool it runs made up (moon, mbc, cc, ar, getconf: none compiles anything): the jobs it
# gives mbc (every core alone, shared among the readers scripts/native.ts builds side by side, MBC_JOBS over both),
# moonbit.h taken from the store by its content (so two moons of one machine, ci-1's runners, compile the same units),
# MoonBit's runtime archived once and kept in MBC_STORE until what it is made of changes, and moon's lock left by a
# build gone taken over.
#   bash scripts/station-mb-build-test.sh [BUILD_SH]     (BUILD_SH: another build.sh to hold to the same, e.g. an older one)
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
build=${1:-$here/station/mb/build.sh}
t=$(mktemp -d)
pids=()
trap 'for p in ${pids[@]+"${pids[@]}"}; do kill "$p" 2>/dev/null; done; rm -rf "$t"' EXIT
fail() { echo "station-mb-build-test: $*" >&2; exit 1; }

# The tree build.sh is run in: its own place, libs/mbui/scripts/mbc beside it, the tools on PATH.
mkdir -p "$t/root/station/mb/src/reader" "$t/root/libs/mbui/scripts" "$t/bin" "$t/moon/lib/runtime" "$t/moon/include" "$t/log" \
  "$t/root/rules/src" "$t/root/libs/base/src" "$t/root/libs/mbui/src/effect" "$t/root/libs/mbui/src/halt"
# (what the prepared C's key reads: build.sh's own tree's files)
for f in station/mb/moon.mod station/mb/moon.work station/mb/src/reader/reader.mbt rules/moon.mod rules/src/a.mbt libs/base/moon.mod libs/base/src/a.mbt \
  libs/mbui/moon.mod libs/mbui/scripts/mbc-stub.sh libs/mbui/src/effect/a.mbt libs/mbui/src/halt/a.mbt; do
  echo "$f" > "$t/root/$f"
done
cp "$build" "$t/root/station/mb/build.sh"
echo 'int moonbit_x;' > "$t/moon/lib/runtime/runtime.c"
echo 'int moonbit_y;' > "$t/moon/lib/runtime/other.c"
echo '#define MOONBIT 1' > "$t/moon/include/moonbit.h"
: > "$t/shell.a"

cat > "$t/bin/moon" <<'EOF'
#!/bin/bash
# (moon build of the reader: its C; of cprep, into --target-dir: a cprep that copies the C as it is)
[ "${1:-}" = version ] && { echo "moon made-up"; exit 0; }
dir= prev=
for a in "$@"; do [ "$prev" = --target-dir ] && dir=$a; prev=$a; done
if [ -n "$dir" ]; then
  mkdir -p "$dir/native/release/build/station/cprep"
  printf '#!/bin/sh\ncp "$1" "$2"\n' > "$dir/native/release/build/station/cprep/cprep.exe"
  chmod +x "$dir/native/release/build/station/cprep/cprep.exe"
  exit 0
fi
mkdir -p _build/native/release/build/station/reader
echo 'int main(void){return 0;}' > _build/native/release/build/station/reader/reader.c
EOF
cat > "$t/bin/getconf" <<'EOF'
#!/bin/bash
echo "${CORES:-16}"
EOF
cat > "$t/root/libs/mbui/scripts/mbc" <<'EOF'
#!/bin/bash
[ "$1" = path ] && { echo /made-up/mbc; exit 0; }
[ "$1" = key ] && { echo made-up-mbc; exit 0; }
obj= j=none prev=
for a in "$@"; do
  case "$a" in --obj=*) obj=${a#--obj=} ;; -j=*) j=${a#-j=} ;; --cflags=*) echo "${a#--cflags=}" > "$LOG/cflags" ;; esac
  [ "$prev" = -j ] && j=$a
  prev=$a
done
echo "$j" > "$LOG/jobs"
mkdir -p "$obj"; echo unit > "$obj/unit.o"; echo "$obj/unit.o"
EOF
cat > "$t/bin/cc" <<'EOF'
#!/bin/bash
[ "${1:-}" = --version ] && { echo "made-up cc 1"; exit 0; }
[ "${1:-}" = -dumpmachine ] && { echo arm64-apple-darwin; exit 0; }
out= c=
prev=
for a in "$@"; do
  [ "$prev" = -o ] && out=$a
  [ "$prev" = -c ] && c=$a
  prev=$a
done
if [ -n "$c" ]; then
  echo "$c" >> "$LOG/runtime-compiles"
  cat "$c" > "$out"
else
  printf '%s\n' "$@" > "$out"
fi
EOF
cat > "$t/bin/zig" <<'EOF'
#!/bin/bash
# (zig cc / zig ar: the made-up cc and ar)
tool=$1; shift
exec "$(dirname "$0")/$tool" "$@"
EOF
cat > "$t/bin/ar" <<'EOF'
#!/bin/bash
lib=$2; shift 2
cat "$@" > "$lib"
EOF
chmod +x "$t/bin/zig" "$t/bin/moon" "$t/bin/getconf" "$t/bin/cc" "$t/bin/ar" "$t/root/libs/mbui/scripts/mbc"

export PATH="$t/bin:$PATH" MOON_HOME="$t/moon" SHELL_LIB="$t/shell.a" MBC_STORE="$t/store" LOG="$t/log"
unset MBUI_TOOLS MBC_JOBS STILLFAIL_NATIVE_ONE STILLFAIL_NATIVE_READERS STATION_READER_OPT RUNNER_ENVIRONMENT GITHUB_REF
run() { bash "$t/root/station/mb/build.sh" "${TARGET:-darwin-arm64}" "$t/out/$1" > "$t/log/build-$1.out" 2>&1; }
fresh() { rm -rf "$t/log"; mkdir -p "$t/log"; }
compiles() { [ -f "$t/log/runtime-compiles" ] && grep -c . "$t/log/runtime-compiles" || echo 0; }
jobs() { cat "$t/log/jobs" 2>/dev/null || echo "no compile"; }
# (a build that does not end in 20 s is waiting on a lock that is never let go)
bounded() {
  local p=$1 name=$2
  for _ in $(seq 1 200); do kill -0 "$p" 2>/dev/null || { wait "$p"; return $?; }; sleep 0.1; done
  kill "$p"; fail "$name: not ended in 20 s (a lock never let go?)"
}

# 1. mbc's jobs: every core for a build alone, shared by the readers side by side (2 at least; three where only
#    STILLFAIL_NATIVE_ONE says there are several: scripts/native.ts's three), MBC_JOBS over all.
fresh; CORES=16 run alone || fail "a build alone: $(cat "$t/log/build-alone.out")"
[ "$(jobs)" = 16 ] || fail "a build alone on 16 cores: mbc compile -j $(jobs), not 16"
fresh; TARGET=linux-x64 CORES=16 STILLFAIL_NATIVE_ONE=1 run third || fail "one of three: $(cat "$t/log/build-third.out")"
[ "$(jobs)" = 6 ] || fail "several parts side by side (STILLFAIL_NATIVE_ONE alone) on 16 cores: mbc compile -j $(jobs), not 6"
fresh; TARGET=linux-x64 CORES=12 STILLFAIL_NATIVE_ONE=1 run third12 || fail "one of three on 12: $(cat "$t/log/build-third12.out")"
[ "$(jobs)" = 4 ] || fail "several parts side by side (STILLFAIL_NATIVE_ONE alone) on 12 cores: mbc compile -j $(jobs), not 4"
fresh; CORES=16 STILLFAIL_NATIVE_ONE=1 STILLFAIL_NATIVE_READERS=2 run two || fail "one of two: $(cat "$t/log/build-two.out")"
[ "$(jobs)" = 8 ] || fail "one of two readers side by side on 16 cores: mbc compile -j $(jobs), not 8"
fresh; CORES=16 STILLFAIL_NATIVE_ONE=1 STILLFAIL_NATIVE_READERS=1 run onereader || fail "one reader: $(cat "$t/log/build-onereader.out")"
[ "$(jobs)" = 16 ] || fail "the one reader of several parts on 16 cores: mbc compile -j $(jobs), not 16"
fresh; TARGET=linux-x64 CORES=3 STILLFAIL_NATIVE_ONE=1 run few || fail "one of three on 3: $(cat "$t/log/build-few.out")"
[ "$(jobs)" = 2 ] || fail "several parts side by side (STILLFAIL_NATIVE_ONE alone) on 3 cores: mbc compile -j $(jobs), not 2"
fresh; CORES=3 STILLFAIL_NATIVE_ONE=1 run mac || fail "darwin-arm64 among several: $(cat "$t/log/build-mac.out")"
[ "$(jobs)" = 3 ] || fail "darwin-arm64, the Apple parts' one reader (STILLFAIL_NATIVE_ONE alone) on 3 cores: mbc compile -j $(jobs), not 3"
fresh; STATION_READER_OPT=-O0 run o0 || fail "STATION_READER_OPT=-O0: $(cat "$t/log/build-o0.out")"
grep -q -- ' -O0 ' "$t/log/cflags" || fail "STATION_READER_OPT=-O0: mbc's cflags $(cat "$t/log/cflags")"
fresh; run o2 || fail "-O2 by default: $(cat "$t/log/build-o2.out")"
grep -q -- ' -O2 ' "$t/log/cflags" || fail "-O2 by default: mbc's cflags $(cat "$t/log/cflags")"
fresh; RUNNER_ENVIRONMENT=github-hosted GITHUB_REF=refs/heads/x run hosted || fail "a branch on GitHub's runner: $(cat "$t/log/build-hosted.out")"
grep -q -- ' -O0 ' "$t/log/cflags" || fail "a branch on GitHub's runner: mbc's cflags $(cat "$t/log/cflags"), not -O0"
fresh; RUNNER_ENVIRONMENT=github-hosted GITHUB_REF=refs/heads/main run hostedmain || fail "main on GitHub's runner: $(cat "$t/log/build-hostedmain.out")"
grep -q -- ' -O2 ' "$t/log/cflags" || fail "main on GitHub's runner: mbc's cflags $(cat "$t/log/cflags"), not -O2"
fresh; CORES=16 STILLFAIL_NATIVE_ONE=1 STILLFAIL_NATIVE_READERS=3 run three || fail "one of three: $(cat "$t/log/build-three.out")"
[ "$(jobs)" = 6 ] || fail "one of three readers side by side on 16 cores: mbc compile -j $(jobs), not 6"
fresh; CORES=4 STILLFAIL_NATIVE_READERS=3 run three4 || fail "one of three on 4: $(cat "$t/log/build-three4.out")"
[ "$(jobs)" = 2 ] || fail "one of three readers side by side on 4 cores: mbc compile -j $(jobs), not 2"
fresh; CORES=16 STILLFAIL_NATIVE_ONE=1 MBC_JOBS=5 run said || fail "MBC_JOBS: $(cat "$t/log/build-said.out")"
[ "$(jobs)" = 5 ] || fail "MBC_JOBS=5: mbc compile -j $(jobs), not 5"
for n in alone third said; do grep -q 'unit.o' "$t/out/$n" || fail "build $n: not linked with its units"; done

# 2. The runtime: compiled once, then taken from MBC_STORE; compiled again once one of its files or headers changed.
rm -rf "$t/store"; fresh
run first || fail "first build: $(cat "$t/log/build-first.out")"
[ "$(compiles)" = 2 ] || fail "first build: $(compiles) runtime files compiled, not 2"
grep -q "^$t/store/libruntime-darwin-arm64-" "$t/out/first" || fail "first build: not linked with the runtime kept in MBC_STORE"
fresh
run again || fail "second build: $(cat "$t/log/build-again.out")"
[ "$(compiles)" = 0 ] || fail "second build, nothing changed: $(compiles) runtime files compiled again, not 0"
grep -q "^$t/store/libruntime-darwin-arm64-" "$t/out/again" || fail "second build: not linked with the kept runtime"
echo 'int moonbit_x2;' > "$t/moon/lib/runtime/runtime.c"
fresh
run changed || fail "build after the runtime changed: $(cat "$t/log/build-changed.out")"
[ "$(compiles)" = 2 ] || fail "the runtime changed: $(compiles) runtime files compiled, not 2"
echo '#define MOONBIT 2' > "$t/moon/include/moonbit.h"
fresh
run header || fail "build after a header changed: $(cat "$t/log/build-header.out")"
[ "$(compiles)" = 2 ] || fail "a runtime header changed: $(compiles) runtime files compiled, not 2"

# 3. Two moons with the same moonbit.h (ci-1's runners, each its own _tool/moon-ci): the same command for mbc, so the
#    same units, and the same runtime kept.
cp -R "$t/moon" "$t/moon2"
fresh; run home1 || fail "MOON_HOME one: $(cat "$t/log/build-home1.out")"
c1=$(cat "$t/log/cflags")
fresh; MOON_HOME="$t/moon2" run home2 || fail "MOON_HOME two: $(cat "$t/log/build-home2.out")"
c2=$(cat "$t/log/cflags")
[ "$c1" = "$c2" ] || fail "two moons of one moonbit.h: mbc given other cflags ($c1 / $c2)"
case "$c1" in *"$t/moon"*) fail "mbc's cflags name a moon's own directory: $c1" ;; esac
[ "$(compiles)" = 0 ] || fail "the second moon, its runtime the same: $(compiles) runtime files compiled, not 0"

# 4. moon's lock left by a build gone (killed where no trap ran): taken over, not waited on.
sh -c 'exit 0' & dead=$!; wait "$dead"
mkdir -p "$t/root/station/mb/_build/moon-gen.lock"; echo "$dead" > "$t/root/station/mb/_build/moon-gen.lock/pid"
fresh
run stale & p=$!; pids=("$p")
bounded "$p" "a build after one gone left moon's lock" || fail "a build after one gone left moon's lock: $(cat "$t/log/build-stale.out")"
pids=()
[ ! -e "$t/root/station/mb/_build/moon-gen.lock" ] || fail "moon's lock left after a build ended"

echo "station-mb-build-test: mbc's jobs by the builds side by side, the runtime kept until it changes, a gone build's lock taken over"
