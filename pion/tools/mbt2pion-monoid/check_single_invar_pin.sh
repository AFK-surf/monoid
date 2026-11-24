#!/bin/sh
# CI gate: verify EVERY AFK-surf/invar dependency across ALL pion/**/pion.toml
# (including workspace-inherited dependencies and local `path =` identity checks)
# and pion/**/pion.lock files (key-order-independent full TOML table parsing,
# enforcing `ref == "rev:" + rev` on every invar entry) is pinned to the exact
# same single 40-char commit SHA, matching `manifest.toml`'s `invar_lock_sha`.
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
MANIFEST="$REPO_ROOT/pion/tools/mbt2pion-monoid/manifest.toml"

python3 - "$REPO_ROOT" "$MANIFEST" << 'PY'
import os, re, subprocess, sys

try:
    import tomllib
except ImportError:
    tomllib = None

repo_root = os.path.realpath(sys.argv[1])
manifest_path = sys.argv[2]
pion_dir = os.path.join(repo_root, "pion")
HEX40 = re.compile(r"^[0-9a-f]{40}$")

toml_entries = []  # (rev, rel)
lock_entries = []  # (rev, rel)
errors = []


def strip_toml_comment(raw):
    """Strip unquoted `# ...` TOML comments while preserving '...' and \"...\" strings."""
    out = []
    in_double = False
    in_single = False
    escaped = False
    for ch in raw:
        if in_double:
            out.append(ch)
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_double = False
        elif in_single:
            out.append(ch)
            if ch == "'":
                in_single = False
        else:
            if ch == "#":
                break
            if ch == '"':
                in_double = True
            elif ch == "'":
                in_single = True
            out.append(ch)
    return "".join(out)


def unquote_toml_str(val):
    val = val.strip()
    if len(val) >= 2 and val[0] == '"' and val[-1] == '"':
        return val[1:-1]
    if len(val) >= 2 and val[0] == "'" and val[-1] == "'":
        return val[1:-1]
    return val


def parse_lock_blocks_fallback(text):
    """Key-order-independent TOML [[...]] array-of-tables fallback parser (comment-aware)."""
    blocks = []
    cur = None
    for raw in text.splitlines():
        line = strip_toml_comment(raw).strip()
        if not line:
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
            cur[k.strip()] = unquote_toml_str(v)
    if cur is not None:
        blocks.append(cur)
    return blocks


def normalize_git_repo(url):
    """Canonicalize Git remote URLs (https/http/ssh/git/SCP, case, trailing slash, .git)."""
    s = str(url or "").strip().lower()
    for prefix in ("https://", "http://", "ssh://", "git://"):
        if s.startswith(prefix):
            s = s[len(prefix):]
            break
    if "@" in s:
        user_part, rest = s.split("@", 1)
        if "/" not in user_part:
            s = rest
    m_scp = re.match(r"^([^/:]+):([^0-9/].*)$", s)
    if m_scp:
        s = f"{m_scp.group(1)}/{m_scp.group(2)}"
    s = re.sub(r"^([^/:]+):\d+/", r"\1/", s)
    while s.endswith("/"):
        s = s[:-1]
    if s.endswith(".git"):
        s = s[:-4]
    return s


def is_invar_repo(url):
    return normalize_git_repo(url) == "github.com/afk-surf/invar"


def inspect_local_path_identity(target_dir):
    """Resolve target directory's git remote and pion.toml identity (NEVER naive substring!).

    Returns a non-empty reason string if `target_dir` belongs to `AFK-surf/invar`,
    otherwise returns None. Legitimate local packages (`sf`, `mbt_compat`, etc.)
    return None even if their directory name contains 'invar'.
    """
    real_target = os.path.realpath(target_dir)
    if not os.path.isdir(real_target):
        return None

    # 1. Walk upward from real_target to find a `.git` repo/worktree, stopping
    #    at repo_root (monoid itself) so monoid's own `.git` is not misread.
    cur = real_target
    found_git_root = None
    while True:
        if cur == repo_root:
            break
        if os.path.exists(os.path.join(cur, ".git")):
            found_git_root = cur
            break
        parent = os.path.dirname(cur)
        if parent == cur:
            break
        cur = parent

    if found_git_root is not None:
        try:
            proc = subprocess.run(
                ["git", "-C", found_git_root, "config", "--get-regexp", r"^remote\..*\.url$"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=10,
            )
            if proc.returncode == 0:
                for line in proc.stdout.splitlines():
                    parts = line.strip().split(None, 1)
                    if len(parts) == 2 and is_invar_repo(parts[1]):
                        return f"git remote {parts[0]}={parts[1]}"
        except Exception:
            pass
        # Also inspect `.git/config` directly in case git config failed on a bare/synthetic repo
        git_cfg = os.path.join(found_git_root, ".git", "config")
        if os.path.isfile(git_cfg):
            try:
                cfg_txt = open(git_cfg, "r", encoding="utf-8", errors="replace").read()
                for m in re.finditer(r"^\s*url\s*=\s*(.+)$", cfg_txt, flags=re.M):
                    u = m.group(1).strip()
                    if is_invar_repo(u):
                        return f".git/config remote url={u}"
            except Exception:
                pass

    # 2. Check target's `[package]` metadata (`repository`, `homepage`) — NEVER `[dependencies]` `git = ...`
    #    (a monoid workspace's `[workspace.dependencies]` depends on invar, it is NOT invar itself!).
    checked = set()
    cur = real_target
    for _ in range(6):
        if cur in checked or cur == repo_root:
            break
        checked.add(cur)
        pt = os.path.join(cur, "pion.toml")
        if os.path.isfile(pt):
            try:
                pt_txt = open(pt, "r", encoding="utf-8", errors="replace").read()
                in_pkg = False
                for raw_l in pt_txt.splitlines():
                    l = strip_toml_comment(raw_l).strip()
                    if not l:
                        continue
                    if l.startswith("[") and l.endswith("]"):
                        in_pkg = l[1:-1].strip() in ("package", "workspace.package")
                        continue
                    if in_pkg:
                        m = re.match(r'^(?:repository|homepage)\s*=\s*(?:"([^"]+)"|\'([^\']+)\')', l)
                        if m:
                            u = m.group(1) if m.group(1) is not None else m.group(2)
                            if is_invar_repo(u):
                                return f"{os.path.relpath(pt, repo_root)} [package] metadata url={u}"
            except Exception:
                pass
        if found_git_root is not None and cur == found_git_root:
            break
        parent = os.path.dirname(cur)
        if parent == cur:
            break
        cur = parent

    return None


def parse_pion_toml_deps(txt):
    """Extract dependency entries from [dependencies], [dev-dependencies], and [workspace.dependencies].

    Returns list of (lineno, dep_name, dep_dict).
    """
    entries = []
    section = ""
    cur_sub_dep = None
    cur_sub_line = 0
    cur_sub_dict = None

    def flush_sub():
        nonlocal cur_sub_dep, cur_sub_line, cur_sub_dict
        if cur_sub_dep is not None and cur_sub_dict is not None:
            entries.append((cur_sub_line, cur_sub_dep, cur_sub_dict))
        cur_sub_dep = None
        cur_sub_line = 0
        cur_sub_dict = None

    for lineno, raw_line in enumerate(txt.splitlines(), 1):
        line = strip_toml_comment(raw_line).strip()
        if not line:
            continue
        if line.startswith("[") and not line.startswith("[[") and line.endswith("]"):
            flush_sub()
            section = line[1:-1].strip()
            for prefix in ("dependencies.", "dev-dependencies.", "workspace.dependencies."):
                if section.startswith(prefix):
                    cur_sub_dep = section[len(prefix):].strip().strip('"').strip("'")
                    cur_sub_line = lineno
                    cur_sub_dict = {}
                    break
            continue
        if cur_sub_dep is not None:
            if "=" in line:
                k, v = line.split("=", 1)
                cur_sub_dict[k.strip()] = unquote_toml_str(v)
            continue
        if section in ("dependencies", "dev-dependencies", "workspace.dependencies"):
            m = re.match(r'^([A-Za-z0-9_.-]+|"[^"]+")\s*=\s*\{(.*)\}\s*$', line)
            if m:
                dep_name = unquote_toml_str(m.group(1))
                body = m.group(2)
                d = {}
                for km in re.finditer(r'([A-Za-z0-9_-]+)\s*=\s*(?:"([^"]*)"|\'([^\']*)\'|(true|false))', body):
                    val = km.group(2) if km.group(2) is not None else (km.group(3) if km.group(3) is not None else km.group(4))
                    d[km.group(1)] = val
                entries.append((lineno, dep_name, d))
    flush_sub()
    return entries


for root, _dirs, files in os.walk(pion_dir):
    for fn in sorted(files):
        full = os.path.join(root, fn)
        rel = os.path.relpath(full, repo_root)
        if fn == "pion.toml":
            txt = open(full, "r", encoding="utf-8").read()
            deps = parse_pion_toml_deps(txt)
            for lineno, dep_name, d in deps:
                if "git" in d:
                    git_url = d["git"]
                    if not is_invar_repo(git_url):
                        continue
                    rev_val = d.get("rev", "")
                    if not HEX40.match(rev_val):
                        errors.append(
                            f"{rel}:{lineno}: AFK-surf/invar dependency {dep_name!r} without valid 40-char hex rev (got {rev_val!r})"
                        )
                    else:
                        toml_entries.append((rev_val, rel))
                elif "path" in d:
                    dep_path = d["path"]
                    target_dir = os.path.normpath(os.path.join(os.path.dirname(full), dep_path))
                    reason = inspect_local_path_identity(target_dir)
                    if reason is not None:
                        errors.append(
                            f"{rel}:{lineno}: local path dependency {dep_name!r} ({dep_path!r}) points to AFK-surf/invar ({reason}); local path invar bypass forbidden"
                        )
        elif fn == "pion.lock":
            txt = open(full, "r", encoding="utf-8").read()
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
                if not is_invar_repo(git_url):
                    continue
                rev = str(tbl.get("rev", ""))
                if not HEX40.match(rev):
                    errors.append(
                        f"{rel} table#{idx}: AFK-surf/invar lock entry missing valid 40-char hex rev (got {rev!r})"
                    )
                    continue
                ref = str(tbl.get("ref", ""))
                expected_ref = f"rev:{rev}"
                if ref != expected_ref:
                    errors.append(
                        f"{rel} table#{idx}: AFK-surf/invar lock entry ref ({ref!r}) != expected {expected_ref!r} (non-rev pin forbidden)"
                    )
                    continue
                lock_entries.append((rev, rel))

if errors:
    for e in errors:
        print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)

if not toml_entries or not lock_entries:
    print(
        f"ERROR: expected AFK-surf/invar entries in both pion.toml ({len(toml_entries)}) and pion.lock ({len(lock_entries)})",
        file=sys.stderr,
    )
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

print(
    f"OK: all {len(toml_entries)} pion.toml + {len(lock_entries)} pion.lock AFK-surf/invar entries + manifest.toml pinned to single rev {unique_rev}"
)
PY
