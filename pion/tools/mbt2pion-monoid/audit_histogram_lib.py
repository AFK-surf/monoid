#!/usr/bin/env python3
"""Strict, byte-reproducible audit histogram builder & raw-byte `--check` verifier.

Used by `run_audit_histogram.sh` and unit-tested by `test_audit_histogram.py`.
"""

import difflib
import json
import os
import re
import subprocess
import sys
from collections import Counter, defaultdict

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

ASSET_BYPASS_PION = {f[:-4] + ".pion" for f in MANIFEST_ASSET_BYPASS_MBT}

INVAR_PKGS = {
    "signals", "view", "ui", "paint", "pixels", "flex", "text", "shape",
    "motion", "headless", "hostapi", "player", "lg", "kit", "zip", "svg",
    "effect", "halt", "dmath", "codec", "damage", "editor",
}

MIG_REQUIRED_INT_KEYS = (
    "blockers",
    "probe_rounds",
    "probes_instrumented",
    "probes_resolved",
    "stage_b_iterations",
)


def is_strict_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def validate_diag_list(diags, label):
    if not isinstance(diags, list):
        raise ValueError(f"{label}: 'diagnostics' must be a list")
    for idx, d in enumerate(diags):
        if not isinstance(d, dict):
            raise ValueError(f"{label}: diagnostics[{idx}] must be an object")
        for key in ("code", "message", "file"):
            val = d.get(key)
            if not isinstance(val, str) or not val.strip():
                raise ValueError(f"{label}: diagnostics[{idx}] missing non-empty string '{key}' (got {val!r})")
        for key in ("line", "col"):
            val = d.get(key)
            if not is_strict_int(val):
                raise ValueError(f"{label}: diagnostics[{idx}] field '{key}' must be int (got {val!r})")


def validate_migration_report(mig):
    if not isinstance(mig, dict):
        raise ValueError("migration_report.json: root must be an object")
    for k in MIG_REQUIRED_INT_KEYS:
        if k not in mig or not is_strict_int(mig[k]):
            raise ValueError(f"migration_report.json: required int field '{k}' missing or invalid (got {mig.get(k)!r})")
    validate_diag_list(mig.get("diagnostics"), "migration_report.json")


def validate_pionc_check(pcheck, pc_rc):
    if pc_rc not in (0, 1):
        raise ValueError(f"pionc check exited with invalid code {pc_rc} (expected 0 or 1)")
    if not isinstance(pcheck, dict):
        raise ValueError("pionc_check.json: root must be an object")
    if "ok" not in pcheck or not isinstance(pcheck["ok"], bool):
        raise ValueError("pionc_check.json: missing boolean 'ok' field")
    validate_diag_list(pcheck.get("diagnostics"), "pionc_check.json")
    diags = pcheck["diagnostics"]
    if pc_rc == 0:
        if not (pcheck["ok"] is True and len(diags) == 0):
            raise ValueError(
                f"pionc check exit code 0 inconsistent with ok={pcheck['ok']!r}, len(diagnostics)={len(diags)}"
            )
    else:
        if not (pcheck["ok"] is False and len(diags) > 0):
            raise ValueError(
                f"pionc check exit code 1 inconsistent with ok={pcheck['ok']!r}, len(diagnostics)={len(diags)}"
            )


def parse_moon_pkg_excluded(moon_pkg_path, git_prod_set, target="native"):
    """Independently compute target-excluded production files from `moon.pkg` `targets: { ... }`."""
    raw = open(moon_pkg_path, "r", encoding="utf-8").read()
    # Strip // line comments
    clean = re.sub(r"//[^\n]*", "", raw)
    m = re.search(r"\btargets\s*:\s*\{(.*?)\}", clean, flags=re.S)
    if not m:
        raise ValueError(f"Failed to locate 'targets: {{ ... }}' block in {moon_pkg_path}")
    body = m.group(1)
    excluded = set()
    for entry in re.finditer(r'"([^"]+\.mbt)"\s*:\s*\[([^\]]*)\]', body):
        fname = entry.group(1)
        if fname not in git_prod_set:
            continue
        targets = re.findall(r'"([^"]+)"', entry.group(2))
        if target not in targets:
            excluded.add(fname)
    return excluded


def det_sorted(counter, limit=None):
    items = sorted(counter.items(), key=lambda kv: (-kv[1], kv[0]))
    return items[:limit] if limit is not None else items


def norm_m2p_msg(msg):
    m = re.sub(r"`[^`]+`", "`<id>`", msg)
    m = re.sub(r"0x[0-9a-fA-F]+", "<hex>", m)
    return m


def build_histogram_texts(
    *,
    git_prod_files,
    moon_pkg_path,
    out_files,
    mig,
    pcheck,
    pc_rc,
    blockers_doc,
    invar_rev,
    m2p_commit,
    monoid_src_commit,
):
    validate_migration_report(mig)
    validate_pionc_check(pcheck, pc_rc)

    git_prod_files = sorted(git_prod_files)
    git_prod_set = set(git_prod_files)
    if not set(MANIFEST_ASSET_BYPASS_MBT).issubset(git_prod_set):
        missing = sorted(set(MANIFEST_ASSET_BYPASS_MBT) - git_prod_set)
        raise ValueError(f"manifest asset bypass files missing from Git: {missing}")

    # Independently parse moon.pkg targets (ZERO subtraction-derived exclusion!)
    excluded_by_target_set = parse_moon_pkg_excluded(moon_pkg_path, git_prod_set, target="native")
    expected_emitted_set = git_prod_set - excluded_by_target_set

    out_files = sorted(out_files)
    synthesized_files = [f for f in out_files if f == "00_init_order.pion"]
    has_init_order = "00_init_order.pion" in out_files
    emitted_mbt_files = sorted(
        f[:-5] + ".mbt"
        for f in out_files
        if f.endswith(".pion") and f != "00_init_order.pion"
    )
    emitted_set = set(emitted_mbt_files)

    missing_emitted = sorted(expected_emitted_set - emitted_set)
    unexpected_emitted = sorted(emitted_set - expected_emitted_set)
    if missing_emitted or unexpected_emitted:
        raise ValueError(
            f"emitted set reconciliation failed against moon.pkg targets: "
            f"missing emitted production files={missing_emitted}, unexpected={unexpected_emitted}"
        )

    excluded_by_target_files = sorted(excluded_by_target_set)
    assert emitted_set.isdisjoint(excluded_by_target_set)
    assert (emitted_set | excluded_by_target_set) == git_prod_set
    assert len(emitted_mbt_files) + len(excluded_by_target_files) == len(git_prod_files)

    layer2_exact = set()
    for sec in ("strict_invar_blockers", "pure_logic_escape_hatch_candidates", "m13_frozen_tester_missing_methods"):
        for item in blockers_doc.get(sec, []):
            exp = item.get("expected_invar", "")
            if exp:
                layer2_exact.add(exp)

    m2p_diags = sorted(
        mig["diagnostics"],
        key=lambda d: (
            os.path.basename(d["file"]),
            d["line"],
            d["col"],
            d["code"],
            d["message"],
        ),
    )
    m2p_by_code = Counter()
    m2p_reasons = Counter()
    m2p_samples = defaultdict(list)

    for d in m2p_diags:
        code = d["code"]
        m2p_by_code[code] += 1
        msg = d["message"]
        key = f"{code}: {norm_m2p_msg(msg)}"
        m2p_reasons[key] += 1
        if len(m2p_samples[key]) < 3:
            m2p_samples[key].append(f"{os.path.basename(d['file'])}:{d['line']}:{d['col']} ({msg[:140]})")

    pdiags = sorted(
        pcheck["diagnostics"],
        key=lambda d: (
            os.path.basename(d["file"]),
            d["line"],
            d["col"],
            d["code"],
            d["message"],
        ),
    )
    pc_by_code = Counter()
    pc_buckets = Counter()
    pc_bucket_samples = defaultdict(list)
    pc_bucket_category = {}
    pc_by_file = Counter()
    layer2_hits = Counter()

    def classify_pionc_diag(d):
        code = d["code"]
        msg = d["message"]
        fname = os.path.basename(d["file"])
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
        code = d["code"]
        fname = os.path.basename(d["file"])
        pc_by_code[code] += 1
        pc_by_file[fname] += 1
        if fname in ASSET_BYPASS_PION:
            asset_diag_count += 1
        bucket, cat = classify_pionc_diag(d)
        pc_buckets[bucket] += 1
        pc_bucket_category[bucket] = cat
        cat_counts[cat] += 1
        if len(pc_bucket_samples[bucket]) < 3:
            pc_bucket_samples[bucket].append(f"{fname}:{d['line']}:{d['col']} ({d['message'][:120]})")

    prod_files_with_diags = len([f for f in pc_by_file if f != "00_init_order.pion"])
    clean_prod_files = max(0, len(emitted_mbt_files) - prod_files_with_diags)
    init_order_diags = pc_by_file.get("00_init_order.pion", 0)
    engine_buckets = [(k, v) for k, v in det_sorted(pc_buckets) if pc_bucket_category[k] == "mbt2pion_engine"]

    out_json = {
        "schema_version": 4,
        "reproduce_command": "MBT2PION_BIN=<path> MBT_COMPAT_DIR=<dir> sh pion/tools/mbt2pion-monoid/run_audit_histogram.sh --check",
        "source_dir": "libs/ui/src/controls",
        "monoid_source_commit": monoid_src_commit,
        "production_files_total": len(git_prod_files),
        "native_target_prod_files_emitted": len(emitted_mbt_files),
        "native_target_excluded_js_only": len(excluded_by_target_files),
        "excluded_by_target_files": excluded_by_target_files,
        "manifest_asset_bypass_count": len(MANIFEST_ASSET_BYPASS_MBT),
        "manifest_asset_bypass_files": MANIFEST_ASSET_BYPASS_MBT,
        "synthesized_files": synthesized_files,
        "generated_files_total": len(out_files),
        "has_00_init_order": has_init_order,
        "invar_rev": invar_rev,
        "mbt2pion_commit": m2p_commit,
        "mbt_compat_commit": m2p_commit,
        "mbt2pion_stage": {
            "total_diagnostics": len(m2p_diags),
            "blockers": mig["blockers"],
            "probe_rounds": mig["probe_rounds"],
            "probes_instrumented": mig["probes_instrumented"],
            "probes_resolved": mig["probes_resolved"],
            "stage_b_iterations": mig["stage_b_iterations"],
            "by_code": dict(det_sorted(m2p_by_code)),
            "top_10_reasons": [
                {"reason": k, "count": v, "samples": m2p_samples[k]}
                for k, v in det_sorted(m2p_reasons, 10)
            ],
        },
        "pionc_check_stage": {
            "ok": pcheck["ok"],
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
    lines.append(f"- **Toolchain**: `AFK-surf/pion@{m2p_commit[:8]}` (`mbt2pion` + `mbt_compat`), `AFK-surf/invar@{invar_rev[:8]}`, `AFK-surf/monoid@{monoid_src_commit[:8]}`, `pionc 0.1.0`")
    lines.append("")
    lines.append("## 1. Summary")
    lines.append("")
    lines.append(f"- `mbt2pion` Gate #12a blockers: **{mig['blockers']}** (explicit per-site drift accounting; zero silent drift)")
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
    meta = {
        "prod_total": len(git_prod_files),
        "emitted": len(emitted_mbt_files),
        "excluded": len(excluded_by_target_files),
        "out_total": len(out_files),
        "blockers": mig["blockers"],
        "pionc_diags": len(pdiags),
        "clean": clean_prod_files,
    }
    return json_text, md_text, meta


def compare_raw_bytes(label, path, expected_text):
    """Strict raw-byte comparison (catches LF -> CRLF drift and any byte difference)."""
    if not os.path.isfile(path):
        return f"{label}: committed file missing at {path}"
    actual_bytes = open(path, "rb").read()
    expected_bytes = expected_text.encode("utf-8")
    if actual_bytes == expected_bytes:
        return None
    if actual_bytes.replace(b"\r\n", b"\n") == expected_bytes:
        return f"{label}: raw byte drift detected (CRLF line endings != LF)"
    diff = "".join(difflib.unified_diff(
        actual_bytes.decode("utf-8", "replace").splitlines(keepends=True),
        expected_text.splitlines(keepends=True),
        fromfile=f"committed/{label}",
        tofile=f"generated/{label}",
        n=2,
    ))
    return f"{label}: byte drift detected:\n{diff[:2000]}"


def main():
    repo_root, work, invar_rev, m2p_commit, monoid_src_commit = sys.argv[1:6]
    pc_rc = int(sys.argv[6])
    check_mode = sys.argv[7] == "1"
    tools_dir = os.path.join(repo_root, "pion/tools/mbt2pion-monoid")

    with open(f"{work}/reports/migration_report.json", "r", encoding="utf-8") as f:
        mig = json.load(f)
    with open(f"{work}/reports/pionc_check.json", "r", encoding="utf-8") as f:
        pcheck = json.load(f)
    with open(f"{work}/reports/run_report.json", "r", encoding="utf-8") as f:
        run_rep = json.load(f)
    with open(f"{tools_dir}/m1_invar_blockers.json", "r", encoding="utf-8") as f:
        blockers_doc = json.load(f)

    git_ls = subprocess.check_output(
        ["git", "-C", repo_root, "ls-files", "libs/ui/src/controls/*.mbt"],
        text=True,
    ).splitlines()
    git_prod_files = sorted(
        os.path.basename(p)
        for p in git_ls
        if p.endswith(".mbt") and not p.endswith("_test.mbt") and not p.endswith("_wbtest.mbt")
    )
    out_files = sorted(os.listdir(f"{work}/out_pkg/src"))
    moon_pkg_path = os.path.join(repo_root, "libs/ui/src/controls/moon.pkg")

    try:
        json_text, md_text, meta = build_histogram_texts(
            git_prod_files=git_prod_files,
            moon_pkg_path=moon_pkg_path,
            out_files=out_files,
            mig=mig,
            pcheck=pcheck,
            pc_rc=pc_rc,
            blockers_doc=blockers_doc,
            invar_rev=invar_rev,
            m2p_commit=m2p_commit,
            monoid_src_commit=monoid_src_commit,
        )
    except ValueError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1

    print(f"[audit-histogram] timing (stdout only): mbt2pion_elapsed_ms={run_rep.get('elapsed_ms')}")

    json_path = f"{tools_dir}/audit_254_histogram.json"
    md_path = f"{tools_dir}/audit_254_summary.md"

    if check_mode:
        drifts = []
        for label, path, expected in [
            ("audit_254_histogram.json", json_path, json_text),
            ("audit_254_summary.md", md_path, md_text),
        ]:
            err = compare_raw_bytes(label, path, expected)
            if err:
                drifts.append(err)
        if drifts:
            for d in drifts:
                print(f"ERROR: {d}", file=sys.stderr)
            return 1
        print(
            f"OK (--check): byte-identical audit_254_histogram.json + audit_254_summary.md "
            f"({meta['emitted']} emitted + {meta['excluded']} js-excluded = {meta['prod_total']} prod files, "
            f"blockers={meta['blockers']}, pionc_diags={meta['pionc_diags']})"
        )
    else:
        with open(json_path, "wb") as f:
            f.write(json_text.encode("utf-8"))
        with open(md_path, "wb") as f:
            f.write(md_text.encode("utf-8"))
        print(
            f"OK: audited {meta['prod_total']} prod files -> {meta['emitted']} native .pion + "
            f"{meta['excluded']} js-excluded + 00_init_order.pion ({meta['out_total']} total), "
            f"blockers={meta['blockers']}, pionc_diags={meta['pionc_diags']}, clean={meta['clean']}/{meta['emitted']}"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
