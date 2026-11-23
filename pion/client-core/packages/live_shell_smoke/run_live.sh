#!/usr/bin/env sh
# Build and run `live_shell_smoke` linked against real Rust `libstillfail_shell` (`rusqlite` WAL + Tokio).
# Usage: sh pion/client-core/packages/live_shell_smoke/run_live.sh [target_dir]
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/../../../.." && pwd)"
TARGET_DIR="${1:-${CARGO_TARGET_DIR:-$ROOT/client/target}}"
LIB_DIR="$TARGET_DIR/debug"
PION_RT_DIR="${PION_RT_DIR:-$HOME/.pion/share/pion/runtime}"
OUT_DIR="${TMPDIR:-/tmp}/pion_live_shell_smoke_build"
rm -rf "$OUT_DIR" && mkdir -p "$OUT_DIR"

cc -O2 -Wall -Wextra -Werror -c "$ROOT/pion/base/packages/shell/native/shell_pion.c" -o "$OUT_DIR/shell_pion.o"
pionc build "$ROOT/pion/client-core/packages/live_shell_smoke" \
  -l "$OUT_DIR/shell_pion.o" \
  -l "$LIB_DIR/libstillfail_shell.so" \
  -o "$OUT_DIR/live_shell_smoke"
LD_LIBRARY_PATH="$LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$OUT_DIR/live_shell_smoke"
