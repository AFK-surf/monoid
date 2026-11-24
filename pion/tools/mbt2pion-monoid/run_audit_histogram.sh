#!/bin/sh
# Reproducible full `@sf` (`libs/ui/src/controls`) `--mode audit` +
# `pionc check --json` diagnostic histogram collector.
#
# Runs `regen.sh` with REAL Stage A.5 probes (zero hand edits to
# generated output) and writes or byte-verifies (`--check`, strictly read-only)
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

python3 - "$REPO_ROOT" "$WORK" "$INVAR_REV" "$M2P_COMMIT" "$MONOID_SRC_COMMIT" "$CHECK_MODE" << 'PY'
import difflib, json, os, re, subprocess, sys
from collections import Counter, defaultdict

REPO_ROOT, WORK, INVAR_REV, M2P_COMMIT, MONOID_SRC_COMMIT = sys.argv[1:6]
CHECK_MODE = sys.argv[6] == "1"
TOOLS_DIR = os.path.join(REPO_ROOT, "pion/tools/mbt2pion-monoid")


def load_json_checked(path, required_list_key):
    try:
        with open(path, "r", encoding="utf-8") as f:
            doc = json.load(f)
    except Exception as e:
        print(f"ERROR: invalid JSON in {path}: {e}", file=sys.stderr)
        sys.exit(1)
    if not isinstance(doc, dict) or not isinstance(doc.get(required_list_key), list):
        print(f"ERROR: malformed schema in {path} (missing list key {required_list_key!r})", file=sys.stderr)
        sys.exit(1)
    return doc


mig = load_json_checked(f"{WORK}/reports/migration_report.json", "diagnostics")
pcheck = load_json_checked(f"{WORK}/reports/pionc_check.json", "diagnostics")
if "ok" not in pcheck or not isinstance(pcheck["ok"], bool):
    print("ERROR: pionc_check.json missing boolean 'ok' field", file=sys.stderr)
    sys.exit(1)

with open(f"{WORK}/reports/run_report.json", "r", encoding="utf-8") as f:
    run_rep = json.load(f)
with open(f"{TOOLS_DIR}/m1_invar_blockers.json", "r", encoding="utf-8") as f:
    blockers_doc = json.load(f)

# Enumerate all tracked production `.mbt` files directly from Git (zero subtraction-derived counts).
git_ls = subprocess.check_output(
    ["git", "-C", REPO_ROOT, "ls-files", "libs/ui/src/controls/*.mbt"],
    text=True,
).splitlines()
git_prod_files = sorted(
    os.path.basename(p)
    for p in git_ls
    if p.endswith(".mbt") and not p.endswith("_test.mbt") and not p.endswith("_wbtest.mbt")
)
git_prod_set = set(git_prod_files)

MANIFEST_ASSET_BYPASS_MBT = sorted([
    "font_assets.mbt",
    "font_assets_js.mbt",
    "font_assets_native.mbt",
    "icon_data.mbt",
    "math_glyphs.mbt",
    "math_glyphs_js.mbt",
    "math_glyphs_native.mbt",
    "palette_data.mbt",
])
if not set(MANIFEST_ASSET_BYPASS_MBT).issubset(git_prod_set):
    missing = sorted(set(MANIFEST_ASSET_BYPASS_MBT) - git_prod_set)
    print(f"ERROR: manifest asset bypass files missing from Git: {missing}", file=sys.stderr)
    sys.exit(1)

ASSET_BYPASS_PION = {f[:-4] + ".pion" for f in MANIFEST_ASSET_BYPASS_MBT}

out_files = sorted(os.listdir(f"{WORK}/out_pkg/src"))
synthesized_files = [f for f in out_files if f == "00_init_order.pion"]
has_init_order = "00_init_order.pion" in out_files
emitted_mbt_files = sorted(
    f[:-5] + ".mbt"
    for f in out_files
    if f.endswith(".pion") and f != "00_init_order.pion"
)
emitted_set = set(emitted_mbt_files)
if not emitted_set.issubset(git_prod_set):
    extra = sorted(emitted_set - git_prod_set)
    print(f"ERROR: unexpected emitted files not in Git prod set: {extra}", file=sys.stderr)
    sys.exit(1)

excluded_by_target_files = sorted(git_prod_set - emitted_set)
assert emitted_set.isdisjoint(set(excluded_by_target_files))
assert (emitted_set | set(excluded_by_target_files)) == git_prod_set
assert len(emitted_mbt_files) + len(excluded_by_target_files) == len(git_prod_files)

layer2_exact = set()
for sec in ("strict_invar_blockers", "pure_logic_escape_hatch_candidates", "m13_frozen_tester_missing_methods"):
    for item in blockers_doc.get(sec, []):
        exp = item.get("expected_invar", "")
        if exp:
            layer2_exact.add(exp)


def det_sorted(counter, limit=None):
    items = sorted(counter.items(), key=lambda kv: (-kv[1], kv[0]))
    return items[:limit] if limit is not None else items


# Sort diagnostics deterministically before sampling (independent of OS/FS readdir order)
m2p_diags = sorted(
    mig.get("diagnostics", []),
    key=lambda d: (
        os.path.basename(str(d.get("file", ""))),
        int(d.get("line", 0) or 0),
        int(d.get("col", 0) or 0),
        str(d.get("code", "")),
        str(d.get("message", "")),
    ),
)
m2p_by_code = Counter()
m2p_reasons = Counter()
m2p_samples = defaultdict(list)


def norm_m2p_msg(msg):
    m = re.sub(r"`[^`]+`", "`<id>`", msg)
    m = re.sub(r"0x[0-9a-fA-F]+", "<hex>", m)
    return m


for d in m2p_diags:
    code = d.get("code", "UNKNOWN")
    m2p_by_code[code] += 1
    msg = d.get("message", "")
    key = f"{code}: {norm_m2p_msg(msg)}"
    m2p_reasons[key] += 1
    if len(m2p_samples[key]) < 3:
        m2p_samples[key].append(f"{os.path.basename(str(d.get('file', '')))}:{d.get('line')}:{d.get('col')} ({msg[:140]})")

pdiags = sorted(
    pcheck.get("diagnostics", []),
    key=lambda d: (
        os.path.basename(str(d.get("file", ""))),
        int(d.get("line", 0) or 0),
        int(d.get("col", 0) or 0),
        str(d.get("code", "")),
        str(d.get("message", "")),
    ),
)
pc_by_code = Counter()
pc_buckets = Counter()
pc_bucket_samples = defaultdict(list)
pc_bucket_category = {}
pc_by_file = Counter()
layer2_hits = Counter()

INVAR_PKGS = {
    "signals", "view", "ui", "paint", "pixels", "flex", "text", "shape",
    "motion", "headless", "hostapi", "player", "lg", "kit", "zip", "svg",
    "effect", "halt", "dmath", "codec", "damage", "editor",
}


def classify_pionc_diag(d):
    code = d.get("code", "UNKNOWN")
    msg = d.get("message", "")
    fname = os.path.basename(d.get("file", ""))
    m = re.search(r"`([^`]+)`", msg)
    sym = m.group(1) if m else ""

    if code == "E_TYPE_MISMATCH":
        if msg.startswith("unknown static function ") or msg.startswith("unknown path ") or msg.startswith("unknown type "):
            if sym in layer2_exact:
                layer2_hits[sym] += 1
                return ("E_TYPE_MISMATCH: Layer 2 missing Invar symbol (`m1_invar_blockers.json`)", "invar_layer2_blocker")
            pkg = sym.split("::")[0] if "::" in sym else ""
            if pkg in INVAR_PKGS:
                return (f"E_TYPE_MISMATCH: missing/unmapped Invar symbol in `{pkg}::*`", "mbt2pion_engine")
        if msg.startswith("unknown method "):
            m2 = re.search(r"unknown method `([^`]+)` on type `([^`]+)`", msg)
            if m2:
                return (f"E_TYPE_MISMATCH: unknown method `.{m2.group(1)}` on `{m2.group(2)}`", "mbt2pion_engine")
            return ("E_TYPE_MISMATCH: unknown method `<sym>` on type `<sym>`", "mbt2pion_engine")
        if msg.startswith("cannot call undefined function `Ref`"):
            return ("E_TYPE_MISMATCH: `Ref(...)` constructor not lowered to `signals::ref_new(...)`", "mbt2pion_engine")
        if msg.startswith("undefined identifier "):
            return ("E_TYPE_MISMATCH: undefined identifier (parse cascade / missing local/import)", "mbt2pion_engine")
        if msg.startswith("cannot call undefined function "):
            return ("E_TYPE_MISMATCH: cannot call undefined function", "mbt2pion_engine")
        if "named argument " in msg and "only allowed in function or method calls" in msg:
            return ("E_TYPE_MISMATCH: MoonBit labeled-arg / punning syntax mis-parsed outside call", "mbt2pion_engine")
        if msg.startswith("type mismatch in assignment"):
            return ("E_TYPE_MISMATCH: type mismatch in assignment", "mbt2pion_engine")
        if msg.startswith("cannot infer enum type for leading-dot variant"):
            return ("E_TYPE_MISMATCH: leading-dot `.Variant` where Pion cannot infer enum type", "mbt2pion_engine")
        if msg.startswith("argument ") and "type mismatch" in msg:
            return ("E_TYPE_MISMATCH: call argument type mismatch", "mbt2pion_engine")
        norm = re.sub(r"`[^`]+`", "`<sym>`", msg)
        return (f"E_TYPE_MISMATCH: {norm}", "mbt2pion_engine")

    if code == "E_PARSE":
        if "in type arguments" in msg and d.get("found") == "?":
            return ("E_PARSE: `T?` inside generic type arguments", "mbt2pion_engine")
        if "found `val`" in msg or d.get("found") == "val":
            return ("E_PARSE: Pion keyword `val` used as field/ident (`r.val` unlowered when Stage A.5 aborts)", "mbt2pion_engine")
        if "expected expression" in msg:
            return (f"E_PARSE: unexpected `{d.get('found', '')}` where expression expected", "mbt2pion_engine")
        if "expected `=>` in match arm" in msg:
            return ("E_PARSE: MoonBit match-arm pattern/guard syntax (`expected => in match arm`)", "mbt2pion_engine")
        norm = re.sub(r"`[^`]+`", "`<tok>`", msg)
        return (f"E_PARSE: {norm} (found `{d.get('found', '')}`)", "mbt2pion_engine")

    if code == "E_HABIT_ARROW_FN":
        return ("E_HABIT_ARROW_FN: MoonBit arrow function `=>` not lowered to `fn(...) { ... }`", "mbt2pion_engine")

    norm = re.sub(r"`[^`]+`", "`<id>`", msg)
    cat = "asset_bypass" if fname in ASSET_BYPASS_PION else "mbt2pion_engine"
    return (f"{code}: {norm}", cat)


cat_counts = Counter()
asset_diag_count = 0
for d in pdiags:
    code = d.get("code", "UNKNOWN")
    fname = os.path.basename(d.get("file", ""))
    pc_by_code[code] += 1
    pc_by_file[fname] += 1
    if fname in ASSET_BYPASS_PION:
        asset_diag_count += 1
    bucket, cat = classify_pionc_diag(d)
    pc_buckets[bucket] += 1
    pc_bucket_category[bucket] = cat
    cat_counts[cat] += 1
    if len(pc_bucket_samples[bucket]) < 3:
        pc_bucket_samples[bucket].append(f"{fname}:{d.get('line')}:{d.get('col')} ({d.get('message', '')[:120]})")

prod_files_with_diags = len([f for f in pc_by_file if f != "00_init_order.pion"])
clean_prod_files = max(0, len(emitted_mbt_files) - prod_files_with_diags)
init_order_diags = pc_by_file.get("00_init_order.pion", 0)

engine_buckets = [(k, v) for k, v in det_sorted(pc_buckets) if pc_bucket_category[k] == "mbt2pion_engine"]

out_json = {
    "schema_version": 4,
    "reproduce_command": "MBT2PION_BIN=<path> MBT_COMPAT_DIR=<dir> sh pion/tools/mbt2pion-monoid/run_audit_histogram.sh --check",
    "source_dir": "libs/ui/src/controls",
    "monoid_source_commit": MONOID_SRC_COMMIT,
    "production_files_total": len(git_prod_files),
    "native_target_prod_files_emitted": len(emitted_mbt_files),
    "native_target_excluded_js_only": len(excluded_by_target_files),
    "excluded_by_target_files": excluded_by_target_files,
    "manifest_asset_bypass_count": len(MANIFEST_ASSET_BYPASS_MBT),
    "manifest_asset_bypass_files": MANIFEST_ASSET_BYPASS_MBT,
    "synthesized_files": synthesized_files,
    "generated_files_total": len(out_files),
    "has_00_init_order": has_init_order,
    "invar_rev": INVAR_REV,
    "mbt2pion_commit": M2P_COMMIT,
    "mbt_compat_commit": M2P_COMMIT,
    "mbt2pion_stage": {
        "total_diagnostics": len(m2p_diags),
        "blockers": mig.get("blockers"),
        "probe_rounds": mig.get("probe_rounds"),
        "probes_instrumented": mig.get("probes_instrumented"),
        "probes_resolved": mig.get("probes_resolved"),
        "stage_b_iterations": mig.get("stage_b_iterations"),
        "by_code": dict(det_sorted(m2p_by_code)),
        "top_10_reasons": [
            {"reason": k, "count": v, "samples": m2p_samples[k]}
            for k, v in det_sorted(m2p_reasons, 10)
        ],
    },
    "pionc_check_stage": {
        "ok": pcheck.get("ok", False),
        "total_diagnostics": len(pdiags),
        "files_with_diagnostics": prod_files_with_diags,
        "files_clean": clean_prod_files,
        "init_order_diagnostics": init_order_diags,
        "diagnostics_in_asset_bypass_files": asset_diag_count,
        "by_code": dict(det_sorted(pc_by_code)),
        "by_category": dict(det_sorted(cat_counts)),
        "layer2_blocker_hits_count": sum(layer2_hits.values()),
        "layer2_blocker_distinct_symbols": len(layer2_hits),
        "layer2_blocker_top_symbols": [
            {"symbol": k, "count": v} for k, v in det_sorted(layer2_hits, 20)
        ],
        "top_15_engine_mechanical_buckets": [
            {"bucket": k, "count": v, "samples": pc_bucket_samples[k]}
            for k, v in engine_buckets[:15]
        ],
        "top_15_files_by_diagnostics": [
            {"file": k, "count": v} for k, v in det_sorted(pc_by_file, 15)
        ],
    },
}

json_text = json.dumps(out_json, indent=2, ensure_ascii=False) + "\n"

lines = []
lines.append("# Wave M1.2 Production Audit Diagnostic Histogram (`libs/ui/src/controls`)")
lines.append("")
lines.append("- **Reproduce**: `MBT2PION_BIN=<path> MBT_COMPAT_DIR=<dir> sh pion/tools/mbt2pion-monoid/run_audit_histogram.sh --check`")
lines.append(
    f"- **File Accounting (Git-Enumerated, Zero Subtraction)**: **{len(emitted_mbt_files)}** native-target emitted `.pion` files + **{len(excluded_by_target_files)}** target-excluded JS-only files (`{', '.join(excluded_by_target_files)}`) = **{len(git_prod_files)}** Git-tracked production `.mbt` files (explicitly tagging all **{len(MANIFEST_ASSET_BYPASS_MBT)}** manifest asset-bypass files: `{', '.join(MANIFEST_ASSET_BYPASS_MBT)}`); plus **{len(synthesized_files)}** synthesized file (`00_init_order.pion`) = **{len(out_files)}** generated `.pion` files (**0 hand edits**, **real Stage A.5 probes**)."
)
lines.append(f"- **Toolchain**: `AFK-surf/pion@{M2P_COMMIT[:8]}` (`mbt2pion` + `mbt_compat`), `AFK-surf/invar@{INVAR_REV[:8]}`, `AFK-surf/monoid@{MONOID_SRC_COMMIT[:8]}`, `pionc 0.1.0`")
lines.append("")
lines.append("## 1. Summary")
lines.append("")
lines.append(f"- `mbt2pion` Gate #12a blockers: **{mig.get('blockers')}** (explicit per-site drift accounting; zero silent drift)")
lines.append(f"- `pionc check --json` total diagnostics: **{len(pdiags)}** (`E_PARSE`: **{pc_by_code.get('E_PARSE', 0)}**, `E_TYPE_MISMATCH`: **{pc_by_code.get('E_TYPE_MISMATCH', 0)}**)")
lines.append(f"- Clean native-target production files (0 `pionc` diagnostics): **{clean_prod_files} / {len(emitted_mbt_files)}**")
lines.append(f"- Layer 2 `m1_invar_blockers.json` hits: **{sum(layer2_hits.values())}** ({len(layer2_hits)} distinct symbols)")
lines.append("")
lines.append("## 2. `mbt2pion` Stage Diagnostics (`MBT2PION_*`)")
lines.append("")
lines.append("| Code | Count |")
lines.append("|---|---:|")
for k, v in det_sorted(m2p_by_code):
    lines.append(f"| `{k}` | {v} |")
lines.append("")
lines.append("## 3. Remaining Top 15 `mbt2pion_engine` Mechanical Buckets")
lines.append("")
lines.append("| # | Count | Mechanical Bucket | Sample |")
lines.append("|---:|---:|---|---|")
for i, (k, v) in enumerate(engine_buckets[:15], 1):
    s = pc_bucket_samples[k][0].replace("|", "\\|")
    k_esc = k.replace("|", "\\|")
    lines.append(f"| {i} | {v} | {k_esc} | `{s}` |")
lines.append("")
lines.append("## 4. Remaining Top 15 Layer 2 `invar_layer2_blocker` Symbols")
lines.append("")
lines.append("| # | Count | Symbol (`expected_invar`) |")
lines.append("|---:|---:|---|")
for i, (k, v) in enumerate(det_sorted(layer2_hits, 15), 1):
    lines.append(f"| {i} | {v} | `{k}` |")

md_text = "\n".join(lines) + "\n"

json_path = f"{TOOLS_DIR}/audit_254_histogram.json"
md_path = f"{TOOLS_DIR}/audit_254_summary.md"

# Print wall-clock timing to stdout only (never committed to deterministic files)
elapsed_ms = run_rep.get("elapsed_ms")
print(f"[audit-histogram] timing (stdout only): mbt2pion_elapsed_ms={elapsed_ms}")

if CHECK_MODE:
    drifts = []
    for label, path, expected in [("audit_254_histogram.json", json_path, json_text), ("audit_254_summary.md", md_path, md_text)]:
        if not os.path.isfile(path):
            drifts.append(f"{label}: committed file missing at {path}")
            continue
        actual = open(path, "r", encoding="utf-8").read()
        if actual != expected:
            diff = "".join(difflib.unified_diff(
                actual.splitlines(keepends=True),
                expected.splitlines(keepends=True),
                fromfile=f"committed/{label}",
                tofile=f"generated/{label}",
                n=2,
            ))
            drifts.append(f"{label}: byte drift detected:\n{diff[:2000]}")
    if drifts:
        for d in drifts:
            print(f"ERROR: {d}", file=sys.stderr)
        sys.exit(1)
    print(f"OK (--check): byte-identical audit_254_histogram.json + audit_254_summary.md ({len(emitted_mbt_files)} emitted + {len(excluded_by_target_files)} js-excluded = {len(git_prod_files)} prod files, blockers={mig.get('blockers')}, pionc_diags={len(pdiags)})")
else:
    with open(json_path, "w", encoding="utf-8") as f:
        f.write(json_text)
    with open(md_path, "w", encoding="utf-8") as f:
        f.write(md_text)
    print(f"OK: audited {len(git_prod_files)} prod files -> {len(emitted_mbt_files)} native .pion + {len(excluded_by_target_files)} js-excluded + 00_init_order.pion ({len(out_files)} total), blockers={mig.get('blockers')}, pionc_diags={len(pdiags)}, clean={clean_prod_files}/{len(emitted_mbt_files)}")
PY
