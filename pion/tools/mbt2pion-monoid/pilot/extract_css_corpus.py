#!/usr/bin/env python3
"""Deterministic full-production `@ui.css(...)` corpus extractor & manifest verifier.

Scans 100% of non-test `.mbt` files under `libs/ui/src/controls/` and `apps/mbui/src/`,
handling ordinary string literals, parenthesized `#|` raw strings, trailing commas,
and EOF-token callsites (where `)` is the exact final byte of the file with no newline).

Fails loudly (non-zero exit) on any unparsed or non-static `@ui.css(...)` callsite.
"""

import argparse
import difflib
import json
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "../../../.."))
DEFAULT_MANIFEST = os.path.join(SCRIPT_DIR, "css_corpus_manifest.json")


def decode_mbt_string(raw, file_label, line_no):
    """Decode MoonBit double-quoted string literal body (without outer quotes)."""
    out = []
    i = 0
    n = len(raw)
    while i < n:
        c = raw[i]
        if c != "\\":
            out.append(c)
            i += 1
            continue
        if i + 1 >= n:
            raise ValueError(f"{file_label}:{line_no}: unterminated escape in string literal")
        esc = raw[i + 1]
        if esc == '"':
            out.append('"')
            i += 2
        elif esc == "\\":
            out.append("\\")
            i += 2
        elif esc == "n":
            out.append("\n")
            i += 2
        elif esc == "r":
            out.append("\r")
            i += 2
        elif esc == "t":
            out.append("\t")
            i += 2
        elif esc == "b":
            out.append("\b")
            i += 2
        elif esc == "f":
            out.append("\f")
            i += 2
        elif esc == "0":
            out.append("\0")
            i += 2
        elif esc == "{":
            raise ValueError(f"{file_label}:{line_no}: non-static string interpolation \\{{...}} in @ui.css(...)")
        else:
            raise ValueError(f"{file_label}:{line_no}: unsupported escape \\{esc} in @ui.css(...)")
    return "".join(out)


def skip_ws_and_comments(src, i):
    n = len(src)
    while i < n:
        c = src[i]
        if c in " \t\r\n":
            i += 1
        elif c == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                i += 1
        else:
            break
    return i


def parse_css_call_arg(src, open_paren_idx, file_label, line_no):
    """Parse argument of `@ui.css(...)` starting at `open_paren_idx` (pointing to `(`).

    Returns (kind, decoded_text, close_paren_idx, is_eof_token).
    Raises ValueError on any non-static or malformed callsite.
    """
    n = len(src)
    i = skip_ws_and_comments(src, open_paren_idx + 1)
    if i >= n:
        raise ValueError(f"{file_label}:{line_no}: unclosed @ui.css( at EOF")

    # Case 1: Parenthesized raw string `@ui.css(( #|... ))` or direct `#|...`
    if src[i] == "(" or (src[i] == "#" and i + 1 < n and src[i + 1] == "|"):
        extra_paren = False
        if src[i] == "(":
            extra_paren = True
            i = skip_ws_and_comments(src, i + 1)
        if not (i + 1 < n and src[i] == "#" and src[i + 1] == "|"):
            raise ValueError(f"{file_label}:{line_no}: non-static expression inside @ui.css((...))")
        raw_lines = []
        while i + 1 < n and src[i] == "#" and src[i + 1] == "|":
            i += 2
            start = i
            while i < n and src[i] != "\n":
                i += 1
            line_body = src[start:i]
            if line_body.endswith("\r"):
                line_body = line_body[:-1]
            raw_lines.append(line_body)
            if i < n and src[i] == "\n":
                i += 1
            i = skip_ws_and_comments(src, i)
        if extra_paren:
            if i >= n or src[i] != ")":
                raise ValueError(f"{file_label}:{line_no}: expected closing ')' for raw string in @ui.css((...))")
            i = skip_ws_and_comments(src, i + 1)
        if i < n and src[i] == ",":
            i = skip_ws_and_comments(src, i + 1)
        if i >= n or src[i] != ")":
            raise ValueError(f"{file_label}:{line_no}: expected closing ')' for @ui.css(...) raw string")
        is_eof = (i == n - 1) or (src[i + 1:].strip() == "")
        return ("raw", "\n".join(raw_lines), i, is_eof)

    # Case 2: Ordinary double-quoted string literal `"..."` (with optional trailing comma)
    if src[i] == '"':
        i += 1
        start = i
        while i < n:
            if src[i] == "\\":
                i += 2
                continue
            if src[i] == '"':
                break
            i += 1
        if i >= n or src[i] != '"':
            raise ValueError(f"{file_label}:{line_no}: unterminated string literal in @ui.css(...)")
        decoded = decode_mbt_string(src[start:i], file_label, line_no)
        i = skip_ws_and_comments(src, i + 1)
        kind = "ordinary"
        if i < n and src[i] == ",":
            kind = "trailing"
            i = skip_ws_and_comments(src, i + 1)
        if i >= n or src[i] != ")":
            raise ValueError(f"{file_label}:{line_no}: expected ')' after string literal in @ui.css(...)")
        is_eof = (i == n - 1) or (src[i + 1:].strip() == "")
        return (kind, decoded, i, is_eof)

    raise ValueError(f"{file_label}:{line_no}: non-static @ui.css(...) argument starting with {src[i:i+24]!r}")


def extract_from_source(src, file_label):
    """Lex MoonBit source and extract every `@ui.css(...)` callsite."""
    calls = []
    n = len(src)
    i = 0
    line_no = 1

    while i < n:
        c = src[i]
        if c == "\n":
            line_no += 1
            i += 1
            continue
        # Skip line comments
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                i += 1
            continue
        # Skip raw string lines outside @ui.css
        if c == "#" and i + 1 < n and src[i + 1] == "|":
            while i < n and src[i] != "\n":
                i += 1
            continue
        # Skip string literals
        if c == '"' or (c == "b" and i + 1 < n and src[i + 1] == '"'):
            if c == "b":
                i += 1
            i += 1
            while i < n:
                if src[i] == "\\":
                    i += 2
                    continue
                if src[i] == '"':
                    i += 1
                    break
                if src[i] == "\n":
                    line_no += 1
                i += 1
            continue
        # Skip char literals
        if c == "'":
            i += 1
            while i < n:
                if src[i] == "\\":
                    i += 2
                    continue
                if src[i] == "'":
                    i += 1
                    break
                if src[i] == "\n":
                    line_no += 1
                i += 1
            continue

        # Match `@ui.css` followed by optional whitespace and `(`
        if src.startswith("@ui.css", i):
            after = i + len("@ui.css")
            # Ensure it's not `@ui.css_read` or another identifier
            if after < n and (src[after].isalnum() or src[after] == "_"):
                i = after
                continue
            j = skip_ws_and_comments(src, after)
            if j < n and src[j] == "(":
                kind, decoded, close_idx, is_eof = parse_css_call_arg(src, j, file_label, line_no)
                calls.append({
                    "file": file_label,
                    "line": line_no,
                    "kind": kind,
                    "text": decoded,
                    "eof_token": is_eof,
                })
                line_no += src[i:close_idx + 1].count("\n")
                i = close_idx + 1
                continue

        i += 1

    return calls


def walk_prod_mbt(root_dir, repo_root):
    files = []
    for cur, dirs, fns in os.walk(root_dir):
        dirs.sort()
        for fn in sorted(fns):
            if not fn.endswith(".mbt"):
                continue
            if fn.endswith("_test.mbt") or fn.endswith("_wbtest.mbt"):
                continue
            full = os.path.join(cur, fn)
            rel = os.path.relpath(full, repo_root).replace(os.sep, "/")
            files.append((rel, full))
    files.sort()
    return files


def extract_repo_corpus(repo_root):
    controls_files = walk_prod_mbt(os.path.join(repo_root, "libs/ui/src/controls"), repo_root)
    app_files = walk_prod_mbt(os.path.join(repo_root, "apps/mbui/src"), repo_root)

    all_calls = []
    controls_counts = {"ordinary": 0, "raw": 0, "trailing": 0}
    app_counts = {"ordinary": 0, "raw": 0, "trailing": 0}

    for rel, full in controls_files:
        src = open(full, "r", encoding="utf-8").read()
        for c in extract_from_source(src, rel):
            controls_counts[c["kind"]] += 1
            all_calls.append(c)

    for rel, full in app_files:
        src = open(full, "r", encoding="utf-8").read()
        for c in extract_from_source(src, rel):
            app_counts[c["kind"]] += 1
            all_calls.append(c)

    distinct_strings = sorted({c["text"] for c in all_calls})
    eof_count = sum(1 for c in all_calls if c["eof_token"])

    return {
        "schema_version": 1,
        "scope": ["libs/ui/src/controls", "apps/mbui/src"],
        "callsites_total": len(all_calls),
        "controls_callsites": sum(controls_counts.values()),
        "controls_by_kind": controls_counts,
        "app_callsites": sum(app_counts.values()),
        "app_by_kind": app_counts,
        "distinct_strings_total": len(distinct_strings),
        "eof_callsites_count": eof_count,
        "distinct_strings": distinct_strings,
        "callsites": all_calls,
    }


def run_self_test():
    # 1. Final-token-at-EOF regression (no trailing newline after `)`)
    eof_src = 'let s = @ui.css("row w=Full")'
    res = extract_from_source(eof_src, "eof_test.mbt")
    assert len(res) == 1, f"expected 1 EOF callsite, got {res}"
    assert res[0]["text"] == "row w=Full"
    assert res[0]["kind"] == "ordinary"
    assert res[0]["eof_token"] is True

    # 2. Parenthesized raw string `#|` at EOF
    raw_src = 'let s = @ui.css((\n  #|row h=S8\n))'
    res2 = extract_from_source(raw_src, "raw_test.mbt")
    assert len(res2) == 1 and res2[0]["kind"] == "raw" and res2[0]["text"] == "row h=S8" and res2[0]["eof_token"] is True

    # 3. Trailing comma callsite
    tr_src = 'let s = @ui.css(\n  "w=Full",\n)\nlet x = 1\n'
    res3 = extract_from_source(tr_src, "trailing_test.mbt")
    assert len(res3) == 1 and res3[0]["kind"] == "trailing" and res3[0]["text"] == "w=Full" and res3[0]["eof_token"] is False

    # 4. Comment and string-embedded `@ui.css(...)` MUST be ignored, `@ui.css_read(...)` ignored
    ign_src = '// @ui.css("nope")\nlet a = "@ui.css(\\"nope2\\")"\nlet b = @ui.css_read("ok")\n'
    assert extract_from_source(ign_src, "ignore_test.mbt") == []

    # 5. Non-static `@ui.css(dyn_var)` MUST fail loud
    failed = False
    try:
        extract_from_source("let s = @ui.css(dyn_var)\n", "nonstatic.mbt")
    except ValueError as e:
        assert "non-static" in str(e)
        failed = True
    assert failed, "expected non-static @ui.css(dyn_var) to raise ValueError"

    # 6. String interpolation inside `@ui.css(...)` MUST fail loud
    failed_interp = False
    try:
        extract_from_source('let s = @ui.css("w=\\{x}")\n', "interp.mbt")
    except ValueError as e:
        assert "interpolation" in str(e)
        failed_interp = True
    assert failed_interp, "expected interpolated @ui.css(...) to raise ValueError"

    print("OK: extract_css_corpus.py self-tests passed (EOF token, raw #|, trailing comma, comment/string skip, non-static fail-loud)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo-root", default=REPO_ROOT)
    ap.add_argument("--manifest", default=DEFAULT_MANIFEST)
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--compare-tsv", default="")
    args = ap.parse_args()

    if args.self_test:
        run_self_test()
        if not args.write and not args.check and not args.compare_tsv:
            return 0

    corpus = extract_repo_corpus(args.repo_root)
    text = json.dumps(corpus, indent=2, ensure_ascii=False) + "\n"

    if args.compare_tsv:
        expected_rows = []
        with open(args.compare_tsv, "r", encoding="utf-8") as f:
            for line in f:
                parts = line.rstrip("\n").split("\t")
                expected_rows.append((parts[0], int(parts[1]), parts[2], json.loads(parts[3])))
        actual_rows = [(c["file"], c["line"], c["kind"], c["text"]) for c in corpus["callsites"]]
        if actual_rows != expected_rows:
            print(f"ERROR: mismatch vs {args.compare_tsv}: actual={len(actual_rows)} expected={len(expected_rows)}", file=sys.stderr)
            for idx, (a, e) in enumerate(zip(actual_rows, expected_rows)):
                if a != e:
                    print(f"  first diff at row {idx}: actual={a!r} expected={e!r}", file=sys.stderr)
                    break
            return 1
        print(f"OK: 100% row-for-row match vs {args.compare_tsv} ({len(actual_rows)} callsites, {corpus['distinct_strings_total']} distinct, {corpus['eof_callsites_count']} EOF)")

    if args.write:
        with open(args.manifest, "w", encoding="utf-8") as f:
            f.write(text)
        print(f"OK: wrote {args.manifest} ({corpus['callsites_total']} callsites: {corpus['controls_callsites']} controls + {corpus['app_callsites']} apps, {corpus['distinct_strings_total']} distinct, {corpus['eof_callsites_count']} EOF)")

    if args.check:
        if not os.path.isfile(args.manifest):
            print(f"ERROR: manifest missing at {args.manifest}", file=sys.stderr)
            return 1
        committed = open(args.manifest, "r", encoding="utf-8").read()
        if committed != text:
            diff = "".join(difflib.unified_diff(
                committed.splitlines(keepends=True),
                text.splitlines(keepends=True),
                fromfile="committed/css_corpus_manifest.json",
                tofile="extracted/css_corpus_manifest.json",
                n=2,
            ))
            print(f"ERROR: css_corpus_manifest.json drift detected:\n{diff[:2000]}", file=sys.stderr)
            return 1
        print(f"OK (--check): byte-identical css_corpus_manifest.json ({corpus['callsites_total']} callsites, {corpus['distinct_strings_total']} distinct, {corpus['eof_callsites_count']} EOF)")

    return 0


if __name__ == "__main__":
    sys.exit(main())
