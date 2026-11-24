#!/usr/bin/env python3
"""Unit tests for audit_histogram_lib.py strict reconciliation, schema, exit-code, and raw-byte checks."""

import json
import os
import subprocess
import sys
import tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "../../.."))
sys.path.insert(0, SCRIPT_DIR)

import audit_histogram_lib as lib


def expect_value_error(fn, substr):
    try:
        fn()
    except ValueError as e:
        assert substr in str(e), f"expected {substr!r} in error {str(e)!r}"
        return
    raise AssertionError(f"expected ValueError containing {substr!r}, but succeeded")


def main():
    git_ls = subprocess.check_output(
        ["git", "-C", REPO_ROOT, "ls-files", "libs/ui/src/controls/*.mbt"],
        text=True,
    ).splitlines()
    git_prod_files = sorted(
        os.path.basename(p)
        for p in git_ls
        if p.endswith(".mbt") and not p.endswith("_test.mbt") and not p.endswith("_wbtest.mbt")
    )
    moon_pkg_path = os.path.join(REPO_ROOT, "libs/ui/src/controls/moon.pkg")
    blockers_doc = json.load(open(os.path.join(SCRIPT_DIR, "m1_invar_blockers.json"), "r", encoding="utf-8"))

    # Independent moon.pkg target exclusion must yield exactly the 2 JS-only files
    excl = lib.parse_moon_pkg_excluded(moon_pkg_path, set(git_prod_files), target="native")
    assert sorted(excl) == ["font_assets_js.mbt", "math_glyphs_js.mbt"], f"unexpected excluded: {excl}"

    valid_out_files = ["00_init_order.pion"] + [
        f[:-4] + ".pion" for f in git_prod_files if f not in excl
    ]
    valid_mig = {
        "blockers": 1,
        "probe_rounds": 1,
        "probes_instrumented": 2,
        "probes_resolved": 0,
        "stage_b_iterations": 0,
        "diagnostics": [{"code": "MBT2PION_PROBE_MISMATCH", "message": "m", "file": "a.mbt", "line": 1, "col": 1}],
    }
    valid_pcheck_fail = {
        "ok": False,
        "diagnostics": [{"code": "E_PARSE", "message": "err", "file": "a.pion", "line": 1, "col": 1}],
    }
    common_kwargs = dict(
        git_prod_files=git_prod_files,
        moon_pkg_path=moon_pkg_path,
        out_files=valid_out_files,
        mig=valid_mig,
        pcheck=valid_pcheck_fail,
        pc_rc=1,
        blockers_doc=blockers_doc,
        invar_rev="339c271e0bd4ea9e2680f13adcec8075d6da9cf3",
        m2p_commit="6d22ff1f90bd19012a5997f7fdfdc56ee3012408",
        monoid_src_commit="41601bf576e9798f57b9853ef390bd4b52aa9953",
    )

    # Positive control
    jtxt, mtxt, meta = lib.build_histogram_texts(**common_kwargs)
    assert meta["emitted"] == 253 and meta["excluded"] == 2 and meta["prod_total"] == 255

    # 1. Dropping ordinary file `reader_marks.pion` MUST fail reconciliation (never miscounted as JS-only!)
    dropped = [f for f in valid_out_files if f != "reader_marks.pion"]
    expect_value_error(
        lambda: lib.build_histogram_texts(**{**common_kwargs, "out_files": dropped}),
        "reader_marks.mbt",
    )

    # 2a. rc=1 with ok=true / empty diagnostics MUST fail
    expect_value_error(
        lambda: lib.build_histogram_texts(**{**common_kwargs, "pcheck": {"ok": True, "diagnostics": []}, "pc_rc": 1}),
        "exit code 1 inconsistent",
    )
    # 2b. rc=1 with {} MUST fail
    expect_value_error(
        lambda: lib.build_histogram_texts(**{**common_kwargs, "pcheck": {}, "pc_rc": 1}),
        "missing boolean 'ok'",
    )

    # 3. rc=0 with non-empty diagnostics MUST fail
    expect_value_error(
        lambda: lib.build_histogram_texts(**{**common_kwargs, "pcheck": {"ok": True, "diagnostics": valid_pcheck_fail["diagnostics"]}, "pc_rc": 0}),
        "exit code 0 inconsistent",
    )

    # 4. Missing diagnostic fields or null counter MUST fail (no UNKNOWN / null fallback)
    bad_mig_null = {**valid_mig, "blockers": None}
    expect_value_error(
        lambda: lib.build_histogram_texts(**{**common_kwargs, "mig": bad_mig_null}),
        "required int field 'blockers'",
    )
    bad_pcheck_diag = {"ok": False, "diagnostics": [{"message": "err", "file": "a.pion", "line": 1, "col": 1}]}
    expect_value_error(
        lambda: lib.build_histogram_texts(**{**common_kwargs, "pcheck": bad_pcheck_diag}),
        "missing non-empty string 'code'",
    )

    # 5. Raw-byte --check MUST reject CRLF drift
    with tempfile.TemporaryDirectory() as td:
        p_lf = os.path.join(td, "ok.json")
        p_crlf = os.path.join(td, "crlf.json")
        open(p_lf, "wb").write(jtxt.encode("utf-8"))
        open(p_crlf, "wb").write(jtxt.replace("\n", "\r\n").encode("utf-8"))
        assert lib.compare_raw_bytes("ok.json", p_lf, jtxt) is None
        err = lib.compare_raw_bytes("crlf.json", p_crlf, jtxt)
        assert err is not None and "CRLF" in err, f"expected CRLF raw byte drift error, got {err!r}"

    print("OK: all test_audit_histogram.py unit tests passed (missing emitted file, rc/ok mismatch, schema strictness, CRLF raw-byte check)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
