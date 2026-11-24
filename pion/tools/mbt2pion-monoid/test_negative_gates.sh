#!/bin/sh
# Wave M1.1 Negative Mutation CI Gates (plan_wave_m1_v3.md §6 #12c)
# Deliberately executes all 4 negative mutations and asserts EVERY ONE exits non-zero
# while `--mode publish` NEVER pollutes `--out`:
#   (a) Mutate `api_map.json`:
#       (a1) delete a string-offset `unit` annotation -> publish exits non-zero & --out untouched
#       (a2) tamper with a signature in `api_map.json` -> `--check` exits non-zero
#   (b) Mutate an upstream function body anchored by a declaration-granularity overlay
#       (preserving line shape) -> first prove valid overlay succeeds, then mutated source
#       fails with `MBT2PION_OVERLAY_STALE_SOURCE` & --out untouched
#   (c) Toggle platform branch (`native` vs `wasm32`) -> `--check` exits non-zero
#   (d) Drop or tautologize a pilot test assertion -> Differential Oracle (`oracle.py`) turns RED!
#
# Environment:
#   MBT2PION_BIN   Path to compiled `mbt2pion` binary (or MBT2PION_CLI_DIR)
#   MBT_COMPAT_DIR Path to `mbt_compat` package directory

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
export PATH="$HOME/.pion/bin:$HOME/.moon/bin:/opt/homebrew/bin:$PATH"
PIONC="${PIONC:-$(command -v pionc)}"
MOON="${MOON:-$(command -v moon)}"

if [ -z "${MBT_COMPAT_DIR:-}" ] || [ ! -d "$MBT_COMPAT_DIR" ]; then
  echo "ERROR: set MBT_COMPAT_DIR to the mbt_compat package directory" >&2
  exit 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/m11-neg-gates.XXXXXX")"
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

SENTINEL_DIR="$WORK/publish_sentinel"
mkdir -p "$SENTINEL_DIR"
printf 'UNTOUCHED_SENTINEL_V1\n' > "$SENTINEL_DIR/sentinel.pion"
SENTINEL_SHA="$(shasum -a 256 "$SENTINEL_DIR/sentinel.pion" | awk '{print $1}')"

verify_sentinel_untouched() {
  NOW_COUNT="$(ls -1 "$SENTINEL_DIR" | wc -l | tr -d ' ')"
  NOW_SHA="$(shasum -a 256 "$SENTINEL_DIR/sentinel.pion" | awk '{print $1}')"
  if [ "$NOW_COUNT" -ne 1 ] || [ "$NOW_SHA" != "$SENTINEL_SHA" ]; then
    echo "FAIL: --mode publish polluted --out ($1): count=$NOW_COUNT sha=$NOW_SHA" >&2
    exit 1
  fi
}

# =============================================================================
# Baseline clean publish for --check comparisons
# =============================================================================
BASE_SRC="$WORK/base_src"
BASE_OUT="$WORK/base_out"
mkdir -p "$BASE_SRC" "$BASE_OUT"
cp "$SCRIPT_DIR/pilot/mbt_transpile_src/pilot_core.mbt" "$BASE_SRC/pilot_core.mbt"

sh "$SCRIPT_DIR/regen.sh" \
  --src "$BASE_SRC" \
  --out "$BASE_OUT" \
  --target native \
  --mode publish \
  --mbt-compat "$MBT_COMPAT_DIR"

# Confirm clean baseline passes --check
sh "$SCRIPT_DIR/regen.sh" \
  --src "$BASE_SRC" \
  --out "$BASE_OUT" \
  --target native \
  --check \
  --mbt-compat "$MBT_COMPAT_DIR"
echo "[neg-gate] baseline clean publish + --check OK"

# =============================================================================
# (a) Mutate api_map.json: (a1) drop unit tag on offset param, (a2) tamper signature
# =============================================================================
BAD_UNIT_MAP="$WORK/bad_unit_api_map.json"
TAMPER_SIG_MAP="$WORK/tamper_sig_api_map.json"
python3 - "$SCRIPT_DIR/api_map.json" "$BAD_UNIT_MAP" "$TAMPER_SIG_MAP" << 'PY'
import json, sys

with open(sys.argv[1]) as f:
    doc = json.load(f)

# (a1) Add/mutate a symbol with an offset-like Int param missing `unit`
doc_unit = json.loads(json.dumps(doc))
if isinstance(doc_unit.get("symbols"), list):
    doc_unit["symbols"].append({
        "src_pkg": "text",
        "src_name": "mutated_slice_probe",
        "kind": "fn",
        "params": [{"name": "byte_offset", "ty": "Int"}]
    })
with open(sys.argv[2], "w") as f:
    json.dump(doc_unit, f, indent=2)

# (a2) Tamper one signature in api_map.json
doc_sig = json.loads(json.dumps(doc))
if isinstance(doc_sig.get("symbols"), list) and len(doc_sig["symbols"]) > 0:
    doc_sig["symbols"][0]["target_name"] = "TAMPERED_SIGNATURE_NAME"
with open(sys.argv[3], "w") as f:
    json.dump(doc_sig, f, indent=2)
PY

if sh "$SCRIPT_DIR/regen.sh" \
  --src "$BASE_SRC" \
  --out "$SENTINEL_DIR" \
  --target native \
  --mode publish \
  --api-map "$BAD_UNIT_MAP" \
  --mbt-compat "$MBT_COMPAT_DIR" >"$WORK/neg_a1.log" 2>&1; then
  echo "FAIL (a1): missing unit annotation in api_map.json was NOT rejected!" >&2
  cat "$WORK/neg_a1.log" >&2
  exit 1
fi
verify_sentinel_untouched "gate (a1)"

if sh "$SCRIPT_DIR/regen.sh" \
  --src "$BASE_SRC" \
  --out "$BASE_OUT" \
  --target native \
  --api-map "$TAMPER_SIG_MAP" \
  --check \
  --mbt-compat "$MBT_COMPAT_DIR" >"$WORK/neg_a2.log" 2>&1; then
  echo "FAIL (a2): tampered api_map.json signature was NOT rejected by --check!" >&2
  cat "$WORK/neg_a2.log" >&2
  exit 1
fi
echo "[neg-gate] PASS (a): api_map.json missing unit + tampered signature both rejected (--out untouched)"

# =============================================================================
# (b) Mutate upstream function body anchored by declaration-granularity overlay
# =============================================================================
OV_SRC="$WORK/ov_src"
OV_DIR="$WORK/ov_dir"
OV_OUT_OK="$WORK/ov_out_ok"
mkdir -p "$OV_SRC" "$OV_DIR" "$OV_OUT_OK"
cp "$SCRIPT_DIR/pilot/mbt_transpile_src/pilot_core.mbt" "$OV_SRC/pilot_core.mbt"

# Probe real hashes via a dummy overlay run in audit mode
cat > "$OV_DIR/pilot_guard.json" << 'EOF'
{
  "id": "ov-film-facts-guard",
  "source_file": "pilot_core.mbt",
  "decl_identity": "fn:film_facts_guard",
  "target": "native",
  "normalized_source_cst_hash": "0000000000000000000000000000000000000000000000000000000000000000",
  "pre_overlay_generated_hash": "0000000000000000000000000000000000000000000000000000000000000000",
  "replacement": "pub fn film_facts_guard(w : Double, h : Double) -> String {\n  if !(w > 0.0 && h > 0.0) { \"\" } else { \"ok\" }\n}",
  "reason": "negative-gate-overlay-anchor-test",
  "behavior_test": "pilot/run_pilot.sh::guard_init_order",
  "upstream_issue_or_removal_condition": "remove after Wave M1.2"
}
EOF

# Step b.1: extract exact source CST hash from audit report (real probes, 100% aligned with publish)
sh "$SCRIPT_DIR/regen.sh" --src "$OV_SRC" --out "$WORK/ov_probe1" --target native --mode audit \
  --overlay-dir "$OV_DIR" --report "$WORK/ov_probe1.json" --mbt-compat "$MBT_COMPAT_DIR" >/dev/null 2>&1 || true
SRC_HASH="$(python3 -c '
import json, re, sys
d = json.load(open(sys.argv[1]))
for x in d.get("diagnostics", []):
    if x.get("code") == "MBT2PION_OVERLAY_STALE_SOURCE":
        m = re.search(r"got ([0-9a-f]+)", x.get("message", ""))
        if m:
            print(m.group(1))
            sys.exit(0)
sys.exit(1)
' "$WORK/ov_probe1.json")"

# Step b.2: plug real SRC_HASH to extract exact pre-overlay generated hash
python3 - "$OV_DIR/pilot_guard.json" "$SRC_HASH" << 'PY'
import json, sys
p, h = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d["normalized_source_cst_hash"] = h
json.dump(d, open(p, "w"), indent=2)
PY

sh "$SCRIPT_DIR/regen.sh" --src "$OV_SRC" --out "$WORK/ov_probe2" --target native --mode audit \
  --overlay-dir "$OV_DIR" --report "$WORK/ov_probe2.json" --mbt-compat "$MBT_COMPAT_DIR" >/dev/null 2>&1 || true
GEN_HASH="$(python3 -c '
import json, re, sys
d = json.load(open(sys.argv[1]))
for x in d.get("diagnostics", []):
    if x.get("code") == "MBT2PION_OVERLAY_STALE_GEN":
        m = re.search(r"got ([0-9a-f]+)", x.get("message", ""))
        if m:
            print(m.group(1))
            sys.exit(0)
sys.exit(1)
' "$WORK/ov_probe2.json")"

python3 - "$OV_DIR/pilot_guard.json" "$GEN_HASH" << 'PY'
import json, sys
p, h = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d["pre_overlay_generated_hash"] = h
json.dump(d, open(p, "w"), indent=2)
PY

# Prove valid overlay succeeds cleanly in --mode publish (with real probes)!
sh "$SCRIPT_DIR/regen.sh" --src "$OV_SRC" --out "$OV_OUT_OK" --target native --mode publish \
  --overlay-dir "$OV_DIR" --mbt-compat "$MBT_COMPAT_DIR"

# Now mutate upstream function body semantics while keeping identical line shape (`>` -> `>=`)
python3 - "$OV_SRC/pilot_core.mbt" << 'PY'
import sys
p = sys.argv[1]
txt = open(p).read()
assert 'guard w > 0.0 && h > 0.0 else { "" }' in txt
open(p, "w").write(txt.replace('guard w > 0.0 && h > 0.0 else { "" }', 'guard w >= 0.0 && h >= 0.0 else { "" }', 1))
PY

if sh "$SCRIPT_DIR/regen.sh" \
  --src "$OV_SRC" \
  --out "$SENTINEL_DIR" \
  --target native \
  --mode publish \
  --overlay-dir "$OV_DIR" \
  --report "$WORK/ov_mut_report.json" \
  --mbt-compat "$MBT_COMPAT_DIR" >"$WORK/neg_b.log" 2>&1; then
  echo "FAIL (b): mutated upstream function under overlay was NOT rejected!" >&2
  cat "$WORK/neg_b.log" >&2
  exit 1
fi
grep -q "MBT2PION_OVERLAY_STALE_SOURCE" "$WORK/ov_mut_report.json" || {
  echo "FAIL (b): expected MBT2PION_OVERLAY_STALE_SOURCE diagnostic!" >&2
  cat "$WORK/ov_mut_report.json" >&2
  exit 1
}
verify_sentinel_untouched "gate (b)"
echo "[neg-gate] PASS (b): overlay stale source CST hash rejected (MBT2PION_OVERLAY_STALE_SOURCE, --out untouched)"

# =============================================================================
# (c) Toggle platform branch (native vs wasm32) -> --check MUST exit non-zero
# =============================================================================
if sh "$SCRIPT_DIR/regen.sh" \
  --src "$BASE_SRC" \
  --out "$BASE_OUT" \
  --target wasm32 \
  --check \
  --mbt-compat "$MBT_COMPAT_DIR" >"$WORK/neg_c.log" 2>&1; then
  echo "FAIL (c): platform branch toggle (native -> wasm32) was NOT rejected by --check!" >&2
  cat "$WORK/neg_c.log" >&2
  exit 1
fi
echo "[neg-gate] PASS (c): platform branch toggle (native vs wasm32) rejected by --check"

# =============================================================================
# (d) Drop or tautologize a pilot test assertion -> Differential Oracle turns RED
# =============================================================================
INVAR_REV="$(grep 'AFK-surf/invar\.git' "$REPO_ROOT/pion/ui/pion.toml" | head -n 1 | sed -n 's/.*rev *= *"\([0-9a-f]\{40\}\)".*/\1/p')"

make_mutated_pilot() {
  MUT_WS="$1"
  mkdir -p "$MUT_WS/pilot/src"
  cp "$BASE_OUT"/*.pion "$MUT_WS/pilot/src/"
  cp "$SCRIPT_DIR/pilot/pion_pilot/src/main.pion" "$MUT_WS/pilot/src/main.pion"
  cat > "$MUT_WS/pion.toml" << EOF
[workspace]
members = ["pilot"]

[workspace.dependencies]
base64 = { git = "https://github.com/AFK-surf/pion-packages.git", tag = "base64-v0.1.0", subdir = "packages/base64" }
mbt_compat = { path = "$MBT_COMPAT_DIR" }
sf = { path = "$REPO_ROOT/pion/ui/packages/sf" }
signals = { git = "https://github.com/AFK-surf/invar.git", rev = "$INVAR_REV", subdir = "packages/signals" }
view = { git = "https://github.com/AFK-surf/invar.git", rev = "$INVAR_REV", subdir = "packages/view" }
ui = { git = "https://github.com/AFK-surf/invar.git", rev = "$INVAR_REV", subdir = "packages/ui" }
zip = { git = "https://github.com/AFK-surf/invar.git", rev = "$INVAR_REV", subdir = "packages/zip" }
pixels = { git = "https://github.com/AFK-surf/invar.git", rev = "$INVAR_REV", subdir = "packages/pixels" }
paint = { git = "https://github.com/AFK-surf/invar.git", rev = "$INVAR_REV", subdir = "packages/paint" }
EOF
  cat > "$MUT_WS/pilot/pion.toml" << EOF
[package]
name = "m11_neg_pilot"
version = "0.1.0"

[dependencies]
mbt_compat = { workspace = true }
sf = { workspace = true }
signals = { workspace = true }
view = { workspace = true }
ui = { workspace = true }
EOF
}

# (d1) Drop one assertion from `signal_by`
MUT_D1="$WORK/mut_d1"
make_mutated_pilot "$MUT_D1"
python3 - "$MUT_D1/pilot/src/main.pion" << 'PY'
import sys
p = sys.argv[1]
txt = open(p).read()
needle = '  check(world, "sig.one_wake_past_tol", wakes.v == 1)\n'
assert needle in txt
open(p, "w").write(txt.replace(needle, '', 1))
PY

if python3 "$SCRIPT_DIR/pilot/oracle.py" \
  --moon-dir "$SCRIPT_DIR/pilot/moon_pilot" \
  --pion-dir "$MUT_D1/pilot" \
  --moon-bin "$MOON" \
  --pionc-bin "$PIONC" \
  --no-bench >"$WORK/neg_d1.log" 2>&1; then
  echo "FAIL (d1): dropped assertion was NOT caught by differential oracle!" >&2
  cat "$WORK/neg_d1.log" >&2
  exit 1
fi

# (d2) Tautologize an assertion on a broken trace (`film_facts_guard` returns wrong value)
MUT_D2="$WORK/mut_d2"
make_mutated_pilot "$MUT_D2"
python3 - "$MUT_D2/pilot/src/main.pion" << 'PY'
import sys
p = sys.argv[1]
txt = open(p).read()
needle = '  check(world, "guard.false_branch", film_facts_guard(0.0, 10.0) == "")'
assert needle in txt
txt = txt.replace(needle, '  check(world, "guard.false_branch", true)', 1)
txt = txt.replace('trace(world, "guard.false", film_facts_guard(0.0, 10.0))', 'trace(world, "guard.false", "BROKEN_TAUTOLOGY")', 1)
open(p, "w").write(txt)
PY

if python3 "$SCRIPT_DIR/pilot/oracle.py" \
  --moon-dir "$SCRIPT_DIR/pilot/moon_pilot" \
  --pion-dir "$MUT_D2/pilot" \
  --moon-bin "$MOON" \
  --pionc-bin "$PIONC" \
  --no-bench >"$WORK/neg_d2.log" 2>&1; then
  echo "FAIL (d2): tautologized assertion with broken trace was NOT caught by differential oracle!" >&2
  cat "$WORK/neg_d2.log" >&2
  exit 1
fi
echo "[neg-gate] PASS (d): dropped assertion & tautologized broken assertion both caught by differential oracle"

echo "=== ALL 4 NEGATIVE MUTATION CI GATES PASSED (100% REJECTED, ZERO --out POLLUTION) ==="
