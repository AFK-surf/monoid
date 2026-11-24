#!/bin/sh
# CI gate: verify EVERY AFK-surf/invar dependency across ALL pion/**/pion.toml
# (supporting inline tables, string path shorthands, and sub-tables; enforcing
# strict confinement to pion/ and blocking vendored invar packages) and
# pion/**/pion.lock files (enforcing `ref == "rev:" + rev` on every invar entry)
# is pinned to the exact same single 40-char commit SHA, matching `manifest.toml`.
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
pion_dir = os.path.realpath(os.path.join(repo_root, "pion"))
HEX40 = re.compile(r"^[0-9a-f]{40}$")

# Static known AFK-surf/invar package names (verified disjoint from monoid pion/ local packages)
KNOWN_INVAR_PKGS = {
    "halt", "dmath", "codec", "zip", "signals", "headless", "headless_core",
    "text", "textdiff", "effect", "flex", "font", "shape", "pixels", "paint",
    "damage", "skia", "svg", "view", "ui", "lg", "kit", "hostapi", "motion",
    "player", "editor", "code_field", "icons", "nav", "terminal", "figure", "media",
}

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


def parse_toml_doc(txt):
    if tomllib is not None:
        return tomllib.loads(txt)
    return None


def read_package_name_and_meta(pt_path):
    """Read [package] name, repository, homepage and [workspace] members from a pion.toml."""
    txt = open(pt_path, "r", encoding="utf-8", errors="replace").read()
    pkg_name = None
    urls = []
    members = []
    doc = parse_toml_doc(txt)
    if doc is not None:
        pkg = doc.get("package")
        if isinstance(pkg, dict):
            if isinstance(pkg.get("name"), str):
                pkg_name = pkg["name"]
            for k in ("repository", "homepage"):
                if isinstance(pkg.get(k), str):
                    urls.append(pkg[k])
        ws = doc.get("workspace")
        if isinstance(ws, dict):
            wsp = ws.get("package")
            if isinstance(wsp, dict):
                for k in ("repository", "homepage"):
                    if isinstance(wsp.get(k), str):
                        urls.append(wsp[k])
            if isinstance(ws.get("members"), list):
                members = [str(m) for m in ws["members"]]
        return pkg_name, urls, members

    section = ""
    for raw_l in txt.splitlines():
        l = strip_toml_comment(raw_l).strip()
        if not l:
            continue
        if l.startswith("[") and l.endswith("]"):
            section = l[1:-1].strip()
            continue
        if section == "package":
            mn = re.match(r'^name\s*=\s*(?:"([^"]+)"|\'([^\']+)\')', l)
            if mn:
                pkg_name = mn.group(1) if mn.group(1) is not None else mn.group(2)
        if section in ("package", "workspace.package"):
            mu = re.match(r'^(?:repository|homepage)\s*=\s*(?:"([^"]+)"|\'([^\']+)\')', l)
            if mu:
                urls.append(mu.group(1) if mu.group(1) is not None else mu.group(2))
        if section == "workspace":
            mm = re.match(r'^members\s*=\s*\[(.*)\]', l)
            if mm:
                members.extend(re.findall(r'"([^"]+)"|\'([^\']+)\'', mm.group(1)))
                members = [x[0] or x[1] if isinstance(x, tuple) else x for x in members]
    return pkg_name, urls, members


def parse_pion_toml_deps(txt):
    """Extract ALL dependency entries from [dependencies], [dev-dependencies], and [workspace.dependencies].

    Handles:
      1. Inline table: `dep = { path = "..." }` / `dep = { git = "...", rev = "..." }`
      2. String path shorthand: `dep = "../some/pkg"`
      3. Sub-table: `[dependencies.dep]` / `[dev-dependencies.dep]` / `[workspace.dependencies.dep]`

    Returns list of (lineno, dep_name, dep_dict).
    """
    # Build line-number map for clear diagnostics
    line_map = {}
    section_l = ""
    for lineno, raw_line in enumerate(txt.splitlines(), 1):
        line = strip_toml_comment(raw_line).strip()
        if not line:
            continue
        if line.startswith("[") and not line.startswith("[[") and line.endswith("]"):
            section_l = line[1:-1].strip()
            for prefix in ("dependencies.", "dev-dependencies.", "workspace.dependencies."):
                if section_l.startswith(prefix):
                    dn = section_l[len(prefix):].strip().strip('"').strip("'")
                    line_map[(prefix[:-1], dn)] = lineno
            continue
        if section_l in ("dependencies", "dev-dependencies", "workspace.dependencies"):
            mk = re.match(r'^([A-Za-z0-9_.-]+|"[^"]+")\s*=', line)
            if mk:
                dn = unquote_toml_str(mk.group(1))
                line_map[(section_l, dn)] = lineno

    doc = parse_toml_doc(txt)
    if doc is not None:
        entries = []
        tables = [
            ("dependencies", doc.get("dependencies")),
            ("dev-dependencies", doc.get("dev-dependencies")),
            ("workspace.dependencies", (doc.get("workspace") or {}).get("dependencies") if isinstance(doc.get("workspace"), dict) else None),
        ]
        for sec_name, tbl in tables:
            if not isinstance(tbl, dict):
                continue
            for dep_name, val in tbl.items():
                ln = line_map.get((sec_name, dep_name), 1)
                if isinstance(val, str):
                    entries.append((ln, dep_name, {"path": val}))
                elif isinstance(val, dict):
                    entries.append((ln, dep_name, {str(k): str(v) for k, v in val.items()}))
        return entries

    # Python 3.9 comment-aware fallback parser
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
            m_tbl = re.match(r'^([A-Za-z0-9_.-]+|"[^"]+")\s*=\s*\{(.*)\}\s*$', line)
            if m_tbl:
                dep_name = unquote_toml_str(m_tbl.group(1))
                body = m_tbl.group(2)
                d = {}
                for km in re.finditer(r'([A-Za-z0-9_-]+)\s*=\s*(?:"([^"]*)"|\'([^\']*)\'|(true|false))', body):
                    val = km.group(2) if km.group(2) is not None else (km.group(3) if km.group(3) is not None else km.group(4))
                    d[km.group(1)] = val
                entries.append((lineno, dep_name, d))
                continue
            m_str = re.match(r'^([A-Za-z0-9_.-]+|"[^"]+")\s*=\s*(?:"([^"]*)"|\'([^\']*)\')\s*$', line)
            if m_str:
                dep_name = unquote_toml_str(m_str.group(1))
                sval = m_str.group(2) if m_str.group(2) is not None else m_str.group(3)
                entries.append((lineno, dep_name, {"path": sval}))
    flush_sub()
    return entries


# Pass 1: collect all pion.lock entries first so we dynamically gather all locked AFK-surf/invar package names
all_toml_files = []
all_lock_files = []
for root, _dirs, files in os.walk(pion_dir):
    for fn in sorted(files):
        full = os.path.join(root, fn)
        rel = os.path.relpath(full, repo_root)
        if fn == "pion.toml":
            all_toml_files.append((full, rel))
        elif fn == "pion.lock":
            all_lock_files.append((full, rel))

invar_pkg_names = set(KNOWN_INVAR_PKGS)

for full, rel in all_lock_files:
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
        pkg_n = str(tbl.get("name", "")).strip()
        if pkg_n:
            invar_pkg_names.add(pkg_n)
        subdir = str(tbl.get("subdir", "")).strip()
        if subdir:
            invar_pkg_names.add(os.path.basename(subdir.rstrip("/")))
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


def check_local_path_dep(rel, lineno, dep_name, dep_path, toml_full):
    """Two-layer defense against local-path invar bypasses:
    1. Resolved realpath MUST stay strictly inside `repo_root/pion/` (blocks external checkouts,
       `~/.cache/pion/git/checkouts/<sha>/packages/*`, and symlinks escaping `pion/`).
    2. Inside `pion/`, inspect `.git` remote, `[package] repository/homepage`, and `[package] name`
       against `invar_pkg_names` (blocks vendored invar copies inside the monoid repo).
    """
    raw_target = os.path.normpath(os.path.join(os.path.dirname(toml_full), dep_path))
    real_target = os.path.realpath(raw_target)

    try:
        common = os.path.commonpath([real_target, pion_dir])
    except ValueError:
        common = ""
    if common != pion_dir:
        errors.append(
            f"{rel}:{lineno}: local path dependency {dep_name!r} ({dep_path!r} -> {real_target}) escapes pion/ workspace (forbidden)"
        )
        return

    # Inside pion/: check nested .git remote (stopping before repo_root)
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
                        errors.append(
                            f"{rel}:{lineno}: local path dependency {dep_name!r} ({dep_path!r}) points to AFK-surf/invar (git remote {parts[1]}); local path invar bypass forbidden"
                        )
                        return
        except Exception:
            pass
        git_cfg = os.path.join(found_git_root, ".git", "config")
        if os.path.isfile(git_cfg):
            cfg_txt = open(git_cfg, "r", encoding="utf-8", errors="replace").read()
            for m in re.finditer(r"^\s*url\s*=\s*(.+)$", cfg_txt, flags=re.M):
                u = m.group(1).strip()
                if is_invar_repo(u):
                    errors.append(
                        f"{rel}:{lineno}: local path dependency {dep_name!r} ({dep_path!r}) points to AFK-surf/invar (.git/config url={u}); local path invar bypass forbidden"
                    )
                    return

    # Check target's pion.toml [package] name & repository/homepage metadata
    target_toml = os.path.join(real_target, "pion.toml")
    if os.path.isfile(target_toml):
        pkg_name, urls, _members = read_package_name_and_meta(target_toml)
        for u in urls:
            if is_invar_repo(u):
                errors.append(
                    f"{rel}:{lineno}: local path dependency {dep_name!r} ({dep_path!r}) points to AFK-surf/invar ({os.path.relpath(target_toml, repo_root)} metadata url={u}); local path invar bypass forbidden"
                )
                return
        if pkg_name and pkg_name in invar_pkg_names:
            errors.append(
                f"{rel}:{lineno}: local path dependency {dep_name!r} ({dep_path!r}) points to vendored AFK-surf/invar package {pkg_name!r}; local path invar bypass forbidden"
            )
            return

    # Also check ancestor pion.toml metadata (up to pion_dir)
    cur = os.path.dirname(real_target)
    for _ in range(6):
        if cur == repo_root or len(cur) < len(pion_dir):
            break
        anc_toml = os.path.join(cur, "pion.toml")
        if os.path.isfile(anc_toml):
            _an, urls, _members = read_package_name_and_meta(anc_toml)
            for u in urls:
                if is_invar_repo(u):
                    errors.append(
                        f"{rel}:{lineno}: local path dependency {dep_name!r} ({dep_path!r}) points to AFK-surf/invar ({os.path.relpath(anc_toml, repo_root)} metadata url={u}); local path invar bypass forbidden"
                    )
                    return
        parent = os.path.dirname(cur)
        if parent == cur:
            break
        cur = parent


# Pass 2: inspect all pion/**/pion.toml
for full, rel in all_toml_files:
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
            check_local_path_dep(rel, lineno, dep_name, d["path"], full)

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
