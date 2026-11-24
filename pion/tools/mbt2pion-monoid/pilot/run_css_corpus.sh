#!/bin/sh
# Full Production `@ui.css(...)` Corpus Batch 3-Engine Parity Gate (Wave M1.2 Track B)
# Usage:
#   sh pion/tools/mbt2pion-monoid/pilot/run_css_corpus.sh [--live-only]
#
# Modes:
#   default      Runs extractor self-tests, frozen manifest raw-byte `--check`
#                (2,096 callsites / 1,237 distinct), drop-1 negative check, and
#                batch 3-engine parity + real style_css.pion mutation negative check.
#   --live-only  For product-tree PRs (`apps/mbui/src/**`, `libs/ui/src/**` without
#                `pion/**` changes): runs extractor self-tests, extracts all current
#                production `@ui.css(...)` callsites live, and runs full 3-engine
#                batch parity + real mutation negative check without failing on
#                frozen manifest drift.

set -eu

LIVE_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --live-only) LIVE_ONLY=1; shift 1 ;;
    -h|--help)
      sed -n '2,15p' "$0"
      exit 0
      ;;
    *)
      echo "run_css_corpus.sh: unknown argument: $1" >&2
      exit 64
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$TOOLS_DIR/../../.." && pwd)"

export PATH="$HOME/.pion/bin:$HOME/.moon/bin:$PATH"
if [ -d /opt/homebrew/bin ]; then
  export PATH="/opt/homebrew/bin:$PATH"
fi
PIONC="${PIONC:-$(command -v pionc)}"
MOON="${MOON:-$(command -v moon)}"

if [ -z "${MBT_COMPAT_DIR:-}" ] || [ ! -d "$MBT_COMPAT_DIR" ]; then
  echo "ERROR: set MBT_COMPAT_DIR to the mbt_compat package directory" >&2
  exit 2
fi

INVAR_REV="$(grep 'AFK-surf/invar\.git' "$REPO_ROOT/pion/ui/pion.toml" | head -n 1 | sed -n 's/.*rev *= *"\([0-9a-f]\{40\}\)".*/\1/p')"
if [ "${#INVAR_REV}" -ne 40 ]; then
  echo "ERROR: failed to resolve 40-char INVAR_REV" >&2
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/m12-css-corpus-gate.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

echo "=== [1/4] Extractor self-tests (EOF, raw #|, trailing comma, @ui .css(v), string interp, CRLF) ==="
python3 "$SCRIPT_DIR/extract_css_corpus.py" --self-test

if [ "$LIVE_ONLY" -eq 1 ]; then
  echo "=== [2/4] Live extraction from current working tree (--live-only mode) ==="
  MANIFEST_ARG="$WORK/live_css_corpus_manifest.json"
  python3 "$SCRIPT_DIR/extract_css_corpus.py" --write --manifest "$MANIFEST_ARG"
  echo "=== [3/4] Skipped frozen manifest drop-1 check (--live-only mode) ==="
  LIVE_FLAG="--live"
else
  MANIFEST_ARG="$SCRIPT_DIR/css_corpus_manifest.json"
  LIVE_FLAG=""
  echo "=== [2/4] Frozen corpus manifest raw-byte --check (2,096 callsites / 1,237 distinct) ==="
  python3 "$SCRIPT_DIR/extract_css_corpus.py" --check

  echo "=== [3/4] Negative check: dropping 1 callsite from manifest MUST fail --check ==="
  python3 - "$SCRIPT_DIR/css_corpus_manifest.json" "$WORK/dropped_one_manifest.json" << 'PY'
import json, sys
doc = json.load(open(sys.argv[1], "r", encoding="utf-8"))
doc["callsites"] = doc["callsites"][:-1]
doc["callsites_total"] = len(doc["callsites"])
with open(sys.argv[2], "wb") as f:
    f.write((json.dumps(doc, indent=2, ensure_ascii=False) + "\n").encode("utf-8"))
PY
  if python3 "$SCRIPT_DIR/extract_css_corpus.py" --check --manifest "$WORK/dropped_one_manifest.json" >"$WORK/neg_drop.log" 2>&1; then
    echo "FAIL (neg-drop-callsite): dropping 1 callsite was NOT rejected by extract_css_corpus.py --check!" >&2
    exit 1
  fi
  echo "[css-corpus] PASS (neg-drop-callsite): dropping 1 callsite rejected by --check"
fi

echo "=== [4/4] Single-batch 3-engine parity across all distinct decoded CSS strings + real source mutation negative check ==="
python3 "$SCRIPT_DIR/css_corpus_oracle.py" \
  --manifest "$MANIFEST_ARG" \
  --repo-root "$REPO_ROOT" \
  --moon-bin "$MOON" \
  --pionc-bin "$PIONC" \
  --invar-rev "$INVAR_REV" \
  --mbt-compat-dir "$MBT_COMPAT_DIR" \
  $LIVE_FLAG \
  --verify-negative

echo "=== ALL FULL PRODUCTION @ui.css CORPUS PARITY GATES PASSED ==="
