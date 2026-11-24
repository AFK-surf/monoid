#!/bin/sh
# CI gate: verify EVERY AFK-surf/invar dependency across ALL pion/**/pion.toml and
# pion/**/pion.lock files (key-order-independent full TOML table parsing, checking
# both `rev` and `ref = "rev:<sha>"`) is pinned to the exact same single 40-char
# commit SHA, matching `manifest.toml`'s `invar_lock_sha`.
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
MANIFEST="$REPO_ROOT/pion/tools/mbt2pion-monoid/manifest.toml"

python3 - "$REPO_ROOT" "$MANIFEST" << 'PY'
import os, re, sys

try:
    import tomllib
except ImportError:
    tomllib = None

repo_root, manifest_path = sys.argv[1], sys.argv[2]
pion_dir = os.path.join(repo_root, "pion")
HEX40 = re.compile(r"^[0-9a-f]{40}$")

toml_entries = []  # (rev, rel)
lock_entries = []  # (rev, rel)
errors = []

def parse_lock_blocks_fallback(text):
    """Key-order-independent TOML [[...]] array-of-tables fallback parser."""
    blocks = []
    cur = None
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[[") and line.endswith("]]"):
            if cur is not None:
                blocks.append(cur)
            cur = {}
            continue
        if line.startswith("["):
            if cur is not None:
                blocks.append(cur)
            cur = None
            continue
        if cur is not None and "=" in line:
            k, v = line.split("=", 1)
            k = k.strip()
            v = v.strip().strip('"').strip("'")
            cur[k] = v
    if cur is not None:
        blocks.append(cur)
    return blocks

for root, _dirs, files in os.walk(pion_dir):
    for fn in sorted(files):
        full = os.path.join(root, fn)
        rel = os.path.relpath(full, repo_root)
        if fn == "pion.toml":
            txt = open(full, "r", encoding="utf-8").read()
            for lineno, line in enumerate(txt.splitlines(), 1):
                if "AFK-surf/invar.git" not in line:
                    continue
                m = re.search(r'rev\s*=\s*"([0-9a-f]{40})"', line)
                if not m:
                    errors.append(f"{rel}:{lineno}: AFK-surf/invar dependency without valid 40-char hex rev: {line.strip()}")
                else:
                    toml_entries.append((m.group(1), rel))
        elif fn == "pion.lock":
            txt = open(full, "r", encoding="utf-8").read()
            if "AFK-surf/invar.git" not in txt:
                continue
            tables = []
            if tomllib is not None:
                data = tomllib.loads(txt)
                for key in ("git", "package", "packages"):
                    val = data.get(key)
                    if isinstance(val, list):
                        tables.extend(t for t in val if isinstance(t, dict))
            else:
                tables = parse_lock_blocks_fallback(txt)
            for idx, tbl in enumerate(tables):
                git_url = str(tbl.get("git", ""))
                if "AFK-surf/invar.git" not in git_url:
                    continue
                rev = str(tbl.get("rev", ""))
                if not HEX40.match(rev):
                    errors.append(f"{rel} table#{idx}: AFK-surf/invar lock entry missing valid 40-char hex rev (got {rev!r})")
                    continue
                ref = str(tbl.get("ref", ""))
                if ref.startswith("rev:") and ref[4:] != rev:
                    errors.append(f"{rel} table#{idx}: AFK-surf/invar lock entry ref ({ref!r}) != rev ({rev!r})")
                    continue
                lock_entries.append((rev, rel))

if errors:
    for e in errors:
        print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)

if not toml_entries or not lock_entries:
    print(f"ERROR: expected AFK-surf/invar entries in both pion.toml ({len(toml_entries)}) and pion.lock ({len(lock_entries)})", file=sys.stderr)
    sys.exit(1)

all_revs = sorted({r for r, _ in toml_entries} | {r for r, _ in lock_entries})
if len(all_revs) != 1:
    print("ERROR: multiple AFK-surf/invar pins detected across pion/**/pion.{toml,lock}:", file=sys.stderr)
    for r, rel in toml_entries + lock_entries:
        print(f"  {r} {rel}", file=sys.stderr)
    sys.exit(1)

unique_rev = all_revs[0]

if os.path.isfile(manifest_path):
    mtxt = open(manifest_path, "r", encoding="utf-8").read()
    m = re.search(r'^invar_lock_sha\s*=\s*"([0-9a-f]{40})"', mtxt, flags=re.M)
    if not m or m.group(1) != unique_rev:
        got = m.group(1) if m else "<missing>"
        print(f"ERROR: manifest.toml invar_lock_sha ({got}) != workspace pin ({unique_rev})", file=sys.stderr)
        sys.exit(1)

print(f"OK: all {len(toml_entries)} pion.toml + {len(lock_entries)} pion.lock AFK-surf/invar entries + manifest.toml pinned to single rev {unique_rev}")
PY
