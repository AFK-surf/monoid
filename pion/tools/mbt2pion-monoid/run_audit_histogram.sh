#!/bin/sh
# Reproducible full `@sf` (`libs/ui/src/controls`) `--mode audit` +
# `pionc check --json` diagnostic histogram collector.
#
# Runs `regen.sh` with REAL Stage A.5 probes (zero hand edits to
# generated output) and writes or raw-byte-verifies (`--check`, strictly read-only)
# `audit_254_histogram.json` and `audit_254_summary.md`.
#
# Usage:
#   MBT2PION_BIN=<path> MBT_COMPAT_DIR=<dir> sh pion/tools/mbt2pion-monoid/run_audit_histogram.sh [--check]

set -eu

CHECK_MODE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK_MODE=1; shift 1 ;;
    -h|--help)
      sed -n '2,10p' "$0"
      exit 0
      ;;
    *)
      echo "run_audit_histogram.sh: unknown argument: $1" >&2
      exit 64
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
export PATH="$HOME/.pion/bin:$HOME/.moon/bin:$PATH"
if [ -d /opt/homebrew/bin ]; then
  export PATH="/opt/homebrew/bin:$PATH"
fi
PIONC="${PIONC:-$(command -v pionc)}"

if [ -z "${MBT_COMPAT_DIR:-}" ] || [ ! -d "$MBT_COMPAT_DIR" ]; then
  echo "ERROR: set MBT_COMPAT_DIR to the mbt_compat package directory" >&2
  exit 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/m12-audit-hist.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

if [ -z "${MBT2PION_BIN:-}" ]; then
  if [ -n "${MBT2PION_CLI_DIR:-}" ] && [ -d "$MBT2PION_CLI_DIR" ]; then
    MBT2PION_BIN="$WORK/mbt2pion"
    "$PIONC" build "$MBT2PION_CLI_DIR" -o "$MBT2PION_BIN"
  else
    echo "ERROR: set MBT2PION_BIN (or MBT2PION_CLI_DIR)" >&2
    exit 2
  fi
fi
export MBT2PION_BIN

MANIFEST="$SCRIPT_DIR/manifest.toml"
INVAR_REV="$(grep 'AFK-surf/invar\.git' "$REPO_ROOT/pion/ui/pion.toml" | head -n 1 | sed -n 's/.*rev *= *"\([0-9a-f]\{40\}\)".*/\1/p')"
M2P_COMMIT="$(sed -n 's/^mbt2pion_commit *= *"\([0-9a-f]\{40\}\)".*/\1/p' "$MANIFEST" | head -n 1)"
MONOID_SRC_COMMIT="$(sed -n 's/^monoid_source_commit *= *"\([0-9a-f]\{40\}\)".*/\1/p' "$MANIFEST" | head -n 1)"

if [ "${#INVAR_REV}" -ne 40 ] || [ "${#M2P_COMMIT}" -ne 40 ] || [ "${#MONOID_SRC_COMMIT}" -ne 40 ]; then
  echo "ERROR: failed to resolve 40-char SHAs (invar=$INVAR_REV mbt2pion=$M2P_COMMIT monoid=$MONOID_SRC_COMMIT)" >&2
  exit 1
fi

if [ -z "${INVAR_DIR:-}" ]; then
  if [ ! -d "$HOME/.cache/pion/git/checkouts/$INVAR_REV" ]; then
    "$PIONC" fetch "$REPO_ROOT/pion/ui" >/dev/null
  fi
  INVAR_DIR="$HOME/.cache/pion/git/checkouts/$INVAR_REV"
fi

OUT_PKG="$WORK/out_pkg"
mkdir -p "$OUT_PKG/src" "$WORK/reports"

sh "$SCRIPT_DIR/regen.sh" \
  --src "$REPO_ROOT/libs/ui/src/controls" \
  --out "$OUT_PKG/src" \
  --target native \
  --mode audit \
  --mbt-compat "$MBT_COMPAT_DIR" \
  --dep "signals=$INVAR_DIR/packages/signals" \
  --dep "view=$INVAR_DIR/packages/view" \
  --dep "ui=$INVAR_DIR/packages/ui" \
  --dep "paint=$INVAR_DIR/packages/paint" \
  --dep "pixels=$INVAR_DIR/packages/pixels" \
  --dep "flex=$INVAR_DIR/packages/flex" \
  --dep "text=$INVAR_DIR/packages/text" \
  --dep "shape=$INVAR_DIR/packages/shape" \
  --dep "motion=$INVAR_DIR/packages/motion" \
  --dep "headless=$INVAR_DIR/packages/headless" \
  --dep "hostapi=$INVAR_DIR/packages/hostapi" \
  --dep "player=$INVAR_DIR/packages/player" \
  --dep "lg=$INVAR_DIR/packages/lg" \
  --dep "kit=$INVAR_DIR/packages/kit" \
  --dep "zip=$INVAR_DIR/packages/zip" \
  --dep "svg=$INVAR_DIR/packages/svg" \
  --dep "halt=$INVAR_DIR/packages/halt" \
  --dep "dmath=$INVAR_DIR/packages/dmath" \
  --dep "codec=$INVAR_DIR/packages/codec" \
  --dep "damage=$INVAR_DIR/packages/damage" \
  --dep "editor=$INVAR_DIR/packages/editor" \
  --report "$WORK/reports/migration_report.json" \
  --drift-ledger "$WORK/reports/drift_ledger.json" \
  --run-report "$WORK/reports/run_report.json" \
  --no-fmt

cat > "$OUT_PKG/pion.toml" << EOF
[package]
name = "sf_audit_repro"
version = "0.1.0"

[dependencies]
mbt_compat = { path = "$MBT_COMPAT_DIR" }
signals = { path = "$INVAR_DIR/packages/signals" }
view = { path = "$INVAR_DIR/packages/view" }
ui = { path = "$INVAR_DIR/packages/ui" }
paint = { path = "$INVAR_DIR/packages/paint" }
pixels = { path = "$INVAR_DIR/packages/pixels" }
flex = { path = "$INVAR_DIR/packages/flex" }
text = { path = "$INVAR_DIR/packages/text" }
shape = { path = "$INVAR_DIR/packages/shape" }
motion = { path = "$INVAR_DIR/packages/motion" }
headless = { path = "$INVAR_DIR/packages/headless" }
hostapi = { path = "$INVAR_DIR/packages/hostapi" }
player = { path = "$INVAR_DIR/packages/player" }
lg = { path = "$INVAR_DIR/packages/lg" }
kit = { path = "$INVAR_DIR/packages/kit" }
zip = { path = "$INVAR_DIR/packages/zip" }
svg = { path = "$INVAR_DIR/packages/svg" }
halt = { path = "$INVAR_DIR/packages/halt" }
dmath = { path = "$INVAR_DIR/packages/dmath" }
codec = { path = "$INVAR_DIR/packages/codec" }
damage = { path = "$INVAR_DIR/packages/damage" }
editor = { path = "$INVAR_DIR/packages/editor" }
effect = { git = "https://github.com/AFK-surf/pion-packages.git", tag = "effect-v0.1.0", subdir = "packages/effect" }
EOF

# Never swallow compiler crashes via `|| true`: only exit 0 (clean) or 1 (diagnostics) are valid.
set +e
"$PIONC" check --json "$OUT_PKG" > "$WORK/reports/pionc_check.json" 2> "$WORK/reports/pionc_check.stderr"
PC_RC=$?
set -e
if [ "$PC_RC" -ne 0 ] && [ "$PC_RC" -ne 1 ]; then
  echo "ERROR: pionc check crashed with exit code $PC_RC" >&2
  cat "$WORK/reports/pionc_check.stderr" >&2
  exit 1
fi
if [ ! -s "$WORK/reports/pionc_check.json" ]; then
  echo "ERROR: pionc check produced empty JSON output (rc=$PC_RC)" >&2
  cat "$WORK/reports/pionc_check.stderr" >&2
  exit 1
fi

python3 "$SCRIPT_DIR/audit_histogram_lib.py" \
  "$REPO_ROOT" "$WORK" "$INVAR_REV" "$M2P_COMMIT" "$MONOID_SRC_COMMIT" "$PC_RC" "$CHECK_MODE"
