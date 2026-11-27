#!/usr/bin/env bash
# Build `stillfail-station-pion` (`pion/station-main/packages/station_main`) linked against real `libstillfail_shell.a`.
# Supports: darwin-arm64, linux-x64 (glibc 2.28), linux-arm64 (glibc 2.28), win32-x64 (MinGW GNU).
#
# Usage:
#   bash pion/station-main/scripts/build.sh [target] [out]
#
# Environment:
#   SHELL_LIB           Override path to libstillfail_shell.a (default: scripts/native.ts path ...)
#   PIONC               Override path to pionc binary (default: ../station/scripts/ensure-pionc.sh)
#   PION_TOOLCHAIN_DIR  Override pion toolchain cache dir
#   ZIG_BIN             Override path to zig binary
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT="$(cd "$MAIN_DIR/../.." && pwd)"
STATION_PION_DIR="$ROOT/pion/station"

default_target="darwin-arm64"
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) default_target="linux-x64" ;;
  Linux-aarch64|Linux-arm64) default_target="linux-arm64" ;;
esac

target="${1:-$default_target}"
default_ext=""
[ "$target" = "win32-x64" ] && default_ext=".exe"
out="${2:-$MAIN_DIR/_build/stillfail-station-pion-$target$default_ext}"

# Reuse pion/station's pinned pionc toolchain (single toolchain pin across sibling workspaces).
ENV_OUT="$(sh "$STATION_PION_DIR/scripts/ensure-pionc.sh" --print-env)" || exit $?
eval "$ENV_OUT"
PION_SHA="$PION_BUILD_SHA"

if [ "${PION_REQUIRE_PINNED:-0}" = "1" ] && [ "$PION_BUILD_SHA" != "$PION_PINNED_SHA" ]; then
  echo "build.sh: PION_REQUIRE_PINNED=1 refuses non-pinned toolchain ($PION_BUILD_SHA != $PION_PINNED_SHA)" >&2
  exit 1
fi

with_lock() {
  local lock_file="$1"
  shift
  mkdir -p "$(dirname "$lock_file")"
  if command -v flock >/dev/null 2>&1; then
    (
      exec 9>"$lock_file" && flock 9 && exec "$@"
    )
  elif command -v perl >/dev/null 2>&1; then
    perl -MFcntl=:flock,F_SETFD -e '
      my $lf = shift @ARGV;
      open my $fh, ">>", $lf or die "open $lf: $!";
      fcntl($fh, F_SETFD, 0) or die "fcntl F_SETFD $lf: $!";
      flock($fh, LOCK_EX) or die "flock $lf: $!";
      exec @ARGV or die "exec $ARGV[0]: $!";
    ' "$lock_file" "$@"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c '
import fcntl, os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o666)
fcntl.flock(fd, fcntl.LOCK_EX)
os.set_inheritable(fd, True)
os.execvp(sys.argv[2], sys.argv[2:])
' "$lock_file" "$@"
  else
    echo "build.sh: flock, perl, or python3 is required to serialize shared build steps" >&2
    exit 1
  fi
}

ensure_zig() {
  local zver="0.16.0"
  if [ -n "${ZIG_BIN:-}" ] && [ -x "$ZIG_BIN" ]; then
    printf '%s\n' "$ZIG_BIN"
    return 0
  fi
  if command -v zig >/dev/null 2>&1; then
    local path_zig
    path_zig="$(command -v zig)"
    if [ "${PION_REQUIRE_PINNED:-0}" != "1" ] || [ "$("$path_zig" version 2>/dev/null || true)" = "$zver" ]; then
      printf '%s\n' "$path_zig"
      return 0
    fi
    echo "build.sh: ignoring PATH zig ($path_zig) whose version != $zver under PION_REQUIRE_PINNED=1" >&2
  fi
  if [ "$(uname -s)-$(uname -m)" != "Linux-x86_64" ]; then
    echo "build.sh: zig $zver is required for target $target (install zig $zver or set ZIG_BIN)" >&2
    return 1
  fi
  local zsha="70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00"
  local zbase="${XDG_CACHE_HOME:-$HOME/.cache}/pion-station-zig/$zver"
  local zdir="$zbase/zig-x86_64-linux-$zver"
  local zbin="$zdir/zig"
  if [ ! -x "$zbin" ]; then
    with_lock "$zbase.flock" bash -euo pipefail -c '
      zver="$1"; zsha="$2"; zbase="$3"; zdir="$4"; zbin="$5"
      if [ -x "$zbin" ]; then exit 0; fi
      mkdir -p "$zbase"
      stage="$(mktemp -d "$zbase/.stage.XXXXXX")"
      trap '\''rm -rf "$stage"'\'' EXIT
      tmp="$stage/zig.tar.xz"
      echo "build.sh: downloading zig $zver..." >&2
      curl -fsSL --retry 5 --retry-all-errors --speed-limit 1024 --speed-time 20 \
        -o "$tmp" "https://ziglang.org/download/$zver/zig-x86_64-linux-$zver.tar.xz"
      echo "$zsha  $tmp" | sha256sum -c --quiet
      tar -xf "$tmp" -C "$stage"
      rm -rf "$zdir"
      mv "$stage/zig-x86_64-linux-$zver" "$zdir"
    ' _ "$zver" "$zsha" "$zbase" "$zdir" "$zbin" || return 1
  fi
  if [ ! -x "$zbin" ]; then
    echo "build.sh: zig install failed: $zbin" >&2
    return 1
  fi
  printf '%s\n' "$zbin"
}

case "$target" in
  darwin-arm64)
    qbe_target="arm64_apple"
    cc=(cc -arch arm64 -mmacosx-version-min=11.0)
    cc_extra=(-ffunction-sections -fdata-sections)
    part="shell-apple-station"
    libs=(-framework CoreServices -framework SystemConfiguration -framework Security -framework CoreFoundation -framework Foundation -liconv -lobjc -Wl,-dead_strip)
    ;;
  linux-x64)
    zig_exe="$(ensure_zig)"
    qbe_target="amd64_sysv"
    cc=("$zig_exe" cc -target x86_64-linux-gnu.2.28)
    cc_extra=(-fno-sanitize=undefined -ffunction-sections -fdata-sections)
    part="shell-station"
    libs=(-lunwind -lutil -lrt -lpthread -lm -ldl -lc -Wl,--gc-sections -s)
    ;;
  linux-arm64)
    zig_exe="$(ensure_zig)"
    qbe_target="arm64"
    cc=("$zig_exe" cc -target aarch64-linux-gnu.2.28)
    cc_extra=(-fno-sanitize=undefined -ffunction-sections -fdata-sections)
    part="shell-station"
    libs=(-lunwind -lutil -lrt -lpthread -lm -ldl -lc -Wl,--gc-sections -s)
    ;;
  win32-x64)
    zig_exe="$(ensure_zig)"
    qbe_target="amd64_win"
    cc=("$zig_exe" cc -target x86_64-windows-gnu)
    cc_extra=(-fno-sanitize=undefined -ffunction-sections -fdata-sections)
    part="shell-station"
    libs=(-lshell32 -liphlpapi -lbcrypt -ladvapi32 -lkernel32 -lntdll -luserenv -lws2_32 -ldbghelp -lunwind -Wl,--gc-sections -Wl,--stack,16777216 -s)
    ;;
  *)
    echo "build.sh: unsupported target '$target' (expected darwin-arm64, linux-x64, linux-arm64, win32-x64)" >&2
    exit 2
    ;;
esac

if [ "${PION_REQUIRE_PINNED:-0}" = "1" ] && [ "$target" != "darwin-arm64" ]; then
  zig_ver="$("$zig_exe" version)"
  if [ "$zig_ver" != "0.16.0" ]; then
    echo "build.sh: PION_REQUIRE_PINNED=1 requires zig 0.16.0 (got '$zig_ver' from $zig_exe)" >&2
    exit 1
  fi
fi

if [ -n "${SHELL_LIB:-}" ]; then
  shell_lib="$SHELL_LIB"
else
  shell_dir="$(node "$ROOT/scripts/native.ts" path "$part" "$target")"
  shell_lib="$shell_dir/libstillfail_shell.a"
fi
if [ ! -f "$shell_lib" ]; then
  echo "build.sh: missing shell static library: $shell_lib" >&2
  exit 1
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/pion-station-main-build-$target.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$(dirname "$out")"

cat > "$work/target-cc.sh" <<EOF
#!/bin/sh
exec $(printf '%q ' "${cc[@]}" "${cc_extra[@]}") "\$@"
EOF
chmod +x "$work/target-cc.sh"

PION_BUILD_LOCK="${XDG_CACHE_HOME:-$HOME/.cache}/pion-station-build.flock"
with_lock "$PION_BUILD_LOCK" env CC="$work/target-cc.sh" "$PIONC" build --release --target "$qbe_target" \
  --emit-staticlib "$work/libstation_main.a" \
  "$MAIN_DIR/packages/station_main"

rt_extra=()
if [ "$target" = "linux-x64" ] || [ "$target" = "win32-x64" ]; then
  rt_extra+=('-D__builtin_cpu_supports(x)=0')
fi

"${cc[@]}" -std=c11 -O2 "${cc_extra[@]}" ${rt_extra[@]+"${rt_extra[@]}"} -I"$PION_RT_DIR" \
  -c "$PION_RT_DIR/pion_rt.c" -o "$work/pion_rt.o"
"${cc[@]}" -std=c11 -O2 "${cc_extra[@]}" -Wall -Wextra -Werror \
  -DSTH_TARGET_NAME="\"$target\"" \
  -DSTH_PION_SHA="\"$PION_SHA\"" \
  -c "$STATION_PION_DIR/packages/host_shim/native/station_host.c" -o "$work/station_host.o"
"${cc[@]}" -std=c11 -O2 "${cc_extra[@]}" -Wall -Wextra -Werror \
  -c "$STATION_PION_DIR/packages/sqlite_ffi/native/station_sqlite.c" -o "$work/station_sqlite.o"
"${cc[@]}" -std=c11 -O2 "${cc_extra[@]}" -Wall -Wextra -Werror \
  -c "$MAIN_DIR/packages/station_sys/native/station_sys.c" -o "$work/station_sys.o"
"${cc[@]}" -std=c11 -O2 "${cc_extra[@]}" -Wall -Wextra -Werror \
  -c "$MAIN_DIR/packages/station_sys/native/station_sqlite_ext.c" -o "$work/station_sqlite_ext.o"
"${cc[@]}" -std=c11 -O2 "${cc_extra[@]}" -Wall -Wextra -Werror \
  -c "$STATION_PION_DIR/packages/builders_replica/native/carry_fs.c" -o "$work/carry_fs.o"

"${cc[@]}" -O2 "${cc_extra[@]}" -o "$out" \
  "$work/libstation_main.a" \
  "$work/pion_rt.o" \
  "$work/station_host.o" \
  "$work/station_sqlite.o" \
  "$work/station_sys.o" \
  "$work/station_sqlite_ext.o" \
  "$work/carry_fs.o" \
  "$shell_lib" \
  "${libs[@]}"

echo "$out"
