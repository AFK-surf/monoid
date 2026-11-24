#!/bin/sh
# Full Production `@ui.css(...)` Corpus Batch 3-Engine Parity Gate (Wave M1.2 Track B)
# Exercises:
#   1. `extract_css_corpus.py --self-test` (including EOF-token closing `)` regression & non-static fail-loud)
#   2. `extract_css_corpus.py --check` (read-only byte-equality of frozen 2,096 callsites / 1,237 distinct manifest)
#   3. Negative check: dropping 1 callsite from manifest fails `--check`
#   4. Single-batch 3-engine parity (`moon wasm-gc` vs `pion native` vs `pion wasm32`) across all 1,237
#      distinct decoded CSS strings (all 32 Patch fields x base + 7 states, IEEE-754 Double bits,
#      exact errors + AFirstLine fail-loud) + negative check proving mutating 1 state field fails!

set -eu

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

echo "=== [1/4] Extractor self-tests (EOF-token closing ')', raw #|, trailing comma, non-static fail-loud) ==="
python3 "$SCRIPT_DIR/extract_css_corpus.py" --self-test

echo "=== [2/4] Frozen corpus manifest --check (2,096 callsites / 1,237 distinct) ==="
python3 "$SCRIPT_DIR/extract_css_corpus.py" --check

echo "=== [3/4] Negative check: dropping 1 callsite from manifest MUST fail --check ==="
python3 - "$SCRIPT_DIR/css_corpus_manifest.json" "$WORK/dropped_one_manifest.json" << 'PY'
import json, sys
doc = json.load(open(sys.argv[1], "r", encoding="utf-8"))
doc["callsites"] = doc["callsites"][:-1]
doc["callsites_total"] = len(doc["callsites"])
with open(sys.argv[2], "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
if python3 "$SCRIPT_DIR/extract_css_corpus.py" --check --manifest "$WORK/dropped_one_manifest.json" >"$WORK/neg_drop.log" 2>&1; then
  echo "FAIL (neg-drop-callsite): dropping 1 callsite was NOT rejected by extract_css_corpus.py --check!" >&2
  exit 1
fi
echo "[css-corpus] PASS (neg-drop-callsite): dropping 1 callsite rejected by --check"

echo "=== [4/4] Single-batch 3-engine parity across all 1,237 distinct decoded CSS strings + state-mutation negative check ==="
python3 "$SCRIPT_DIR/css_corpus_oracle.py" \
  --manifest "$SCRIPT_DIR/css_corpus_manifest.json" \
  --repo-root "$REPO_ROOT" \
  --moon-bin "$MOON" \
  --pionc-bin "$PIONC" \
  --invar-rev "$INVAR_REV" \
  --mbt-compat-dir "$MBT_COMPAT_DIR" \
  --verify-negative

echo "=== ALL FULL PRODUCTION @ui.css CORPUS PARITY GATES PASSED ==="
