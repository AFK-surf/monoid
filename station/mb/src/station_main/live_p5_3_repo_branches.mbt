// Daily local branch cleanup for shared clones in `<data>/repos` and 30-day bundle retention in `<data>/repo-bundles`
// (station/src/ops/repo-branches.ts). Reclaims branches whose tip is on a remote, upstream-applied (cherry / merge-tree),
// process-file-only, or stale unpushed (> 14 days, archived into a verified git bundle before deletion).

///|
/// How often Upkeep cleans local branches in shared clones (once per day; also runs on the first round after startup).
let p53_repo_branches_every_ms : Double = 24.0 * 3600000.0

///|
/// Minimum age since a branch was last touched before it may be pruned (24h).
let p53_branch_min_age_ms : Double = 24.0 * 3600000.0

///|
/// Age threshold for archiving and deleting stale unpushed branches without a same-named remote branch (14 days).
let p53_stale_branch_ms : Double = 14.0 * 24.0 * 3600000.0

///|
/// Retention window for git bundles created from pruned stale unpushed branches (30 days).
let p53_repo_bundle_ms : Double = 30.0 * 24.0 * 3600000.0

///|
/// Max local branches processed per shared clone per cleanup round.
let p53_repo_branches_max_per_repo : Int = 500

///|
/// Longer deadline for `git gc --auto` after deleting local branches (5 minutes).
let p53_repo_gc_timeout_ms : Int = 300000

///|
/// Process-file directory segments created by agents rather than project deliverables (per requester:
/// 「agent自己的历史报告/临时记录/交接账本之类的」). Never includes `.claude`, `.codex`, `docs/`, etc.
let p53_process_dir_segments : Array[String] = [".agent", "scratch", "scratchpad", "tmp", ".tmp"]

///|
let p53_process_file_prefixes : Array[String] = [
  "HANDOFF", "HANDOVER", "LEDGER", "NOTES", "NOTE", "REPORT", "PLAN", "TODO", "PROGRESS", "STATUS", "SUMMARY",
  "JOURNAL", "WORKLOG",
]

///|
let p53_process_file_exts : Array[String] = [".md", ".txt", ".log", ".json"]

///|
fn p53_is_process_stem_char(c : Int) -> Bool {
  (c >= 0x30 && c <= 0x39) ||
  (c >= 0x41 && c <= 0x5A) ||
  (c >= 0x61 && c <= 0x7A) ||
  c == 0x2D ||
  c == 0x5F ||
  c == 0x2E
}

///|
/// Whether a repository-relative path is a temporary/process artifact (ops/repo-branches.ts `isProcessFile`).
fn p53_is_process_file(rel_path : String) -> Bool {
  let parts : Array[String] = []
  let mut start = 0
  let n = rel_path.length()
  for i in 0..<=n {
    let is_sep = i == n || rel_path.unsafe_charcode_at(i) == 0x2F || rel_path.unsafe_charcode_at(i) == 0x5C
    if is_sep {
      if i > start {
        let seg = rel_path[start:i].to_owned()
        if seg != "." {
          parts.push(seg)
        }
      }
      start = i + 1
    }
  }
  if parts.length() == 0 {
    return false
  }
  for seg in parts {
    if p53_process_dir_segments.contains(seg) {
      return true
    }
  }
  let base = parts[parts.length() - 1]
  let lower = base.to_lower()
  if lower.has_suffix(".log") {
    return true
  }
  let mut matched_ext_len = 0
  for ext in p53_process_file_exts {
    if lower.has_suffix(ext) {
      matched_ext_len = ext.length()
      break
    }
  }
  if matched_ext_len == 0 {
    return false
  }
  let stem = base[:base.length() - matched_ext_len].to_owned()
  let upper_stem = stem.to_upper()
  for pref in p53_process_file_prefixes {
    if upper_stem.has_prefix(pref) {
      let mut ok = true
      for i in pref.length()..<stem.length() {
        if !p53_is_process_stem_char(stem.unsafe_charcode_at(i)) {
          ok = false
          break
        }
      }
      if ok {
        return true
      }
    }
  }
  false
}

///|
/// Whether `git status --porcelain --untracked-files=all` output has no tracked changes and only process-file
/// untracked entries (or is completely empty).
fn p53_status_has_only_process_untracked(status_out : String) -> Bool {
  for raw in status_out.split("\n") {
    let line = raw.trim_end(chars="\r").to_owned()
    if line == "" {
      continue
    }
    if !line.has_prefix("?? ") {
      return false
    }
    let rel = line[3:].to_owned().trim().to_owned()
    if !p53_is_process_file(rel) {
      return false
    }
  }
  true
}

///|
async fn p53_run_repo_git_with_timeout(
  host : @host.Host,
  dir : String,
  args : Array[String],
  timeout_ms : Int,
) -> (Bool, String) {
  let pairs = [
    ("GIT_TERMINAL_PROMPT", "0"),
    ("GIT_SSH_COMMAND", "ssh -oBatchMode=yes -oStrictHostKeyChecking=accept-new"),
  ]
  let git = find_command("git", pairs).unwrap_or("git")
  let full = ["-C", dir] + args
  let proc = spawn(host, git, full, env=pairs, stdout=Piped, stderr=Ignored) catch {
    _ => return (false, "")
  }
  let late = Ref(false)
  let killer = host.rt.fork(name="repo git check deadline", async fn() {
    @effect.sleep(timeout_ms) // timer: a deadline to a process (git check/bundle/gc given timeout_ms at most)
    late.val = true
    ignore(kill(proc.pid, "SIGKILL"))
  })
  let (code, _, out, _) = proc.finished()
  killer.interrupt()
  (!late.val && code == Some(0), @utf8.decode_lossy(out))
}

///|
fn p53_parse_unix_sec(s : String) -> Double? {
  let t = s.trim().to_owned()
  if t == "" {
    return None
  }
  let mut acc = 0.0
  for i in 0..<t.length() {
    let c = t.unsafe_charcode_at(i)
    if c < 0x30 || c > 0x39 {
      return None
    }
    acc = acc * 10.0 + (c - 0x30).to_double()
  }
  if acc > 0.0 {
    Some(acc)
  } else {
    None
  }
}

///|
fn p53_utc_bundle_stamp(ms : Double) -> String {
  let iso = iso_time(ms)
  let trimmed = match iso.find(".") {
    Some(dot) => iso[:dot].to_owned() + "Z"
    None => iso
  }
  trimmed.replace_all(old=":", new="-")
}

///|
async fn p53_unique_bundle_stem(host : @host.Host, dir : String, ms : Double) -> String {
  let base = p53_utc_bundle_stamp(ms)
  for i in 0..<100 {
    let stem = if i == 0 { base } else { "\{base}-\{i}" }
    let b = @nodepath.join(sep(), [dir, "\{stem}.bundle"])
    let t = @nodepath.join(sep(), [dir, "\{stem}.txt"])
    if jtext(p53_lstat(host, b), "kind") is None && jtext(p53_lstat(host, t), "kind") is None {
      return stem
    }
  }
  "\{base}-\{wall_ms()}"
}

///|
async fn p53_branch_last_changed_ms(host : @host.Host, repo_path : String, ref_name : String) -> Double {
  // Check `git reflog exists` first (`git reflog show` falls back to commit date when no reflog exists),
  // and use `--date=unix --format=%gd` (`<name>@{<unix>}`) because `%ct` prints the commit's committer date,
  // not the reflog entry timestamp when the branch ref was created/updated.
  let (has_log, _) = p53_run_repo_git(host, repo_path, ["reflog", "exists", ref_name])
  if has_log {
    let (ok, out) = p53_run_repo_git(host, repo_path, ["reflog", "show", "-1", "--date=unix", "--format=%gd", ref_name])
    if ok {
      match out.find("@{") {
        Some(open_i) => {
          let rest = out[open_i + 2:].to_owned()
          match rest.find("}") {
            Some(close_i) =>
              match p53_parse_unix_sec(rest[:close_i].to_owned()) {
                Some(sec) => return sec * 1000.0
                None => ()
              }
            None => ()
          }
        }
        None => ()
      }
    }
  }
  let ref_path = @nodepath.join(sep(), [repo_path, ".git", ref_name])
  match jnum_of(p53_lstat(host, ref_path), "mtimeMs") {
    Some(m) => m
    None => 0.0
  }
}

///|
/// Cleans eligible local branches in one shared clone `repo_path` under `<data>/repos/<repo_name>`
/// (ops/repo-branches.ts `pruneRepoBranchesIn`).
async fn p53_prune_repo_branches_in(
  host : @host.Host,
  data : String,
  repo_name : String,
  repo_path : String,
  now : Double,
  max_branches? : Int = p53_repo_branches_max_per_repo,
) -> Json? {
  // 2. Protected branches: every branch checked out by any worktree registration (including missing/locked) + main HEAD.
  let (wt_ok, wt_out) = p53_run_repo_git(host, repo_path, ["worktree", "list", "--porcelain"])
  if !wt_ok {
    return None
  }
  let protected_refs : Set[String] = Set::new()
  for raw in wt_out.split("\n") {
    let line = raw.trim().to_owned()
    if line.has_prefix("branch refs/heads/") {
      protected_refs.add(line["branch ".length():].to_owned().trim().to_owned())
    }
  }
  let (head_ok, head_out) = p53_run_repo_git(host, repo_path, ["symbolic-ref", "-q", "HEAD"])
  if head_ok {
    let head_ref = head_out.trim().to_owned()
    if head_ref.has_prefix("refs/heads/") {
      protected_refs.add(head_ref)
    }
  }

  // Enumerate local branches: refname, sha, committer unix timestamp.
  let (refs_ok, refs_out) = p53_run_repo_git(
    host,
    repo_path,
    ["for-each-ref", "--format=%(refname)\t%(objectname)\t%(committerdate:unix)", "refs/heads"],
  )
  if !refs_ok {
    return None
  }
  let branches : Array[(String, String, String, Double)] = []
  for raw in refs_out.split("\n") {
    let line = raw.trim_end(chars="\r").to_owned()
    if line == "" {
      continue
    }
    let cols : Array[String] = line.split("\t").map(s => s.to_owned()).collect()
    if cols.length() < 3 {
      continue
    }
    let ref_name = cols[0]
    let sha = cols[1]
    if !ref_name.has_prefix("refs/heads/") || sha == "" {
      continue
    }
    let short_name = ref_name["refs/heads/".length():].to_owned()
    let commit_ms = match p53_parse_unix_sec(cols[2]) {
      Some(sec) => sec * 1000.0
      None => 0.0
    }
    branches.push((ref_name, short_name, sha, commit_ms))
  }

  // Enumerate remote branch names once for step 7 (fail closed if listing fails).
  let (rem_refs_ok, rem_refs_out) = p53_run_repo_git(host, repo_path, ["for-each-ref", "--format=%(refname)", "refs/remotes"])
  let remote_names : Set[String] = Set::new()
  if rem_refs_ok {
    for raw in rem_refs_out.split("\n") {
      let line = raw.trim().to_owned()
      if !line.has_prefix("refs/remotes/") {
        continue
      }
      let rest = line["refs/remotes/".length():].to_owned()
      match rest.find("/") {
        Some(slash) if slash > 0 => {
          let name = rest[slash + 1:].to_owned()
          if name != "" && name != "HEAD" {
            remote_names.add(name)
          }
        }
        _ => ()
      }
    }
  }

  // 4. Default branch: refs/remotes/origin/HEAD, else origin/main, else origin/master.
  let mut default_branch : String? = None
  let (sym_ok, sym_out) = p53_run_repo_git(host, repo_path, ["symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD"])
  if sym_ok && sym_out.trim().to_owned() != "" {
    default_branch = Some(sym_out.trim().to_owned())
  } else {
    let (m_ok, _) = p53_run_repo_git(host, repo_path, ["rev-parse", "--verify", "-q", "refs/remotes/origin/main"])
    if m_ok {
      default_branch = Some("origin/main")
    } else {
      let (ms_ok, _) = p53_run_repo_git(host, repo_path, ["rev-parse", "--verify", "-q", "refs/remotes/origin/master"])
      if ms_ok {
        default_branch = Some("origin/master")
      }
    }
  }
  let mut default_tree : String? = None
  match default_branch {
    Some(db) => {
      let (t_ok, t_out) = p53_run_repo_git(host, repo_path, ["rev-parse", "-q", "\{db}^{tree}"])
      if t_ok && t_out.trim().to_owned() != "" {
        default_tree = Some(t_out.trim().to_owned())
      }
    }
    None => ()
  }

  let mut deleted_remote = 0
  let mut deleted_cherry = 0
  let mut deleted_merged = 0
  let mut deleted_process_only = 0
  let mut deleted_stale_bundled = 0
  let mut bundle_path : String? = None
  let stale_batch : Array[(String, String, String)] = []
  let mut processed = 0

  for b in branches {
    if processed >= max_branches {
      break
    }
    let (ref_name, short_name, sha, commit_ms) = b
    if protected_refs.contains(ref_name) {
      continue
    }
    processed += 1

    // 3. Too fresh (< 24h) -> skip.
    let last_changed = p53_branch_last_changed_ms(host, repo_path, ref_name)
    if now - last_changed < p53_branch_min_age_ms {
      continue
    }

    // 5a. Tip already on a remote.
    let (on_rem_ok, on_rem_out) = p53_run_repo_git(host, repo_path, ["rev-list", "--count", "-n", "1", ref_name, "--not", "--remotes"])
    if on_rem_ok && on_rem_out.trim().to_owned() == "0" {
      let (del_ok, _) = p53_run_repo_git(host, repo_path, ["update-ref", "-d", ref_name, sha])
      if del_ok {
        deleted_remote += 1
      }
      continue
    }

    // 5b-d require a known default branch.
    let mut handled = false
    match default_branch {
      Some(db) => {
        // 5b. Patch already upstream (`git cherry` has no `+` line).
        let (ch_ok, ch_out) = p53_run_repo_git(host, repo_path, ["cherry", db, ref_name])
        if ch_ok {
          let mut has_plus = false
          for raw in ch_out.split("\n") {
            if raw.has_prefix("+") {
              has_plus = true
              break
            }
          }
          if !has_plus {
            let (del_ok, _) = p53_run_repo_git(host, repo_path, ["update-ref", "-d", ref_name, sha])
            if del_ok {
              deleted_cherry += 1
            }
            handled = true
          }
        }
        // 5c. Merge-tree produces identical tree to default branch.
        if !handled {
          match default_tree {
            Some(dt) => {
              let (mt_ok, mt_out) = p53_run_repo_git(host, repo_path, ["merge-tree", "--write-tree", db, ref_name])
              let first_line = mt_out.split("\n").head().map(v => v.trim().to_owned()).unwrap_or("")
              if mt_ok && first_line == dt {
                let (del_ok, _) = p53_run_repo_git(host, repo_path, ["update-ref", "-d", ref_name, sha])
                if del_ok {
                  deleted_merged += 1
                }
                handled = true
              }
            }
            None => ()
          }
        }
        // 5d. Empty diff or only process files since merge-base with default branch.
        if !handled {
          let (mb_ok, mb_out) = p53_run_repo_git(host, repo_path, ["merge-base", db, ref_name])
          let base_sha = if mb_ok { mb_out.trim().to_owned() } else { "" }
          if base_sha != "" {
            let (df_ok, df_out) = p53_run_repo_git(host, repo_path, ["-c", "core.quotepath=false", "diff", "--name-only", base_sha, ref_name])
            if df_ok {
              let mut all_process = true
              for raw in df_out.split("\n") {
                let p = raw.trim_end(chars="\r").to_owned()
                if p != "" && !p53_is_process_file(p) {
                  all_process = false
                  break
                }
              }
              if all_process {
                let (del_ok, _) = p53_run_repo_git(host, repo_path, ["update-ref", "-d", ref_name, sha])
                if del_ok {
                  deleted_process_only += 1
                }
                handled = true
              }
            }
          }
        }
      }
      None => ()
    }
    if handled {
      continue
    }

    // 7. Stale unpushed branch (> 14 days, no same-named remote branch) -> archive into bundle before deleting.
    if rem_refs_ok && !remote_names.contains(short_name) && commit_ms > 0.0 && now - commit_ms >= p53_stale_branch_ms {
      stale_batch.push((ref_name, short_name, sha))
    }
  }

  // Create & verify one bundle per clone per round for all stale unpushed branches.
  if stale_batch.length() > 0 {
    let bundle_dir = @nodepath.join(sep(), [data, "repo-bundles", repo_name])
    let mk_ok = try {
      ignore(host.shell("fs.mkdir", { "path": Json::string(bundle_dir), "recursive": Json::boolean(true) }))
      true
    } catch {
      _ => false
    }
    if mk_ok {
      let stem = p53_unique_bundle_stem(host, bundle_dir, now)
      let b_file = @nodepath.join(sep(), [bundle_dir, "\{stem}.bundle"])
      let m_file = @nodepath.join(sep(), [bundle_dir, "\{stem}.txt"])
      let create_args : Array[String] = ["bundle", "create", b_file]
      for sb in stale_batch {
        create_args.push(sb.0)
      }
      create_args.push("--not")
      create_args.push("--remotes")
      let (cr_ok, _) = p53_run_repo_git(host, repo_path, create_args)
      if !cr_ok {
        slice_log("warn", "upkeep", "creating git bundle for stale branches failed; keeping branches", jobj_of([("repo", jstr(repo_name)), ("count", ji(stale_batch.length()))]))
        p53_remove(host, b_file)
      } else {
        let (vf_ok, _) = p53_run_repo_git(host, repo_path, ["bundle", "verify", b_file])
        if !vf_ok {
          slice_log("warn", "upkeep", "verifying git bundle for stale branches failed; keeping branches", jobj_of([("repo", jstr(repo_name)), ("bundle", jstr(b_file))]))
          p53_remove(host, b_file)
        } else {
          let lines : Array[String] = []
          for sb in stale_batch {
            lines.push("\{sb.1} \{sb.2}")
          }
          lines.push("# Restore: git fetch \{b_file} 'refs/heads/*:refs/heads/*'")
          let content = lines.join("\n") + "\n"
          let wrote = write_text_mode(m_file, content, 0)
          if !wrote {
            slice_log("warn", "upkeep", "writing git bundle manifest failed; keeping branches", jobj_of([("repo", jstr(repo_name)), ("bundle", jstr(b_file))]))
            p53_remove(host, b_file)
            p53_remove(host, m_file)
          } else {
            bundle_path = Some(b_file)
            for sb in stale_batch {
              let (del_ok, _) = p53_run_repo_git(host, repo_path, ["update-ref", "-d", sb.0, sb.2])
              if del_ok {
                deleted_stale_bundled += 1
              }
            }
          }
        }
      }
    }
  }

  let total_deleted = deleted_remote + deleted_cherry + deleted_merged + deleted_process_only + deleted_stale_bundled
  if total_deleted > 0 {
    let (gc_ok, _) = p53_run_repo_git_with_timeout(host, repo_path, ["gc", "--auto"], p53_repo_gc_timeout_ms)
    if !gc_ok {
      slice_log("warn", "upkeep", "git gc --auto failed after branch cleanup", jobj_of([("repo", jstr(repo_name))]))
    }
    slice_log(
      "info",
      "upkeep",
      "cleaned local branches in shared clone",
      jobj_of([
        ("repo", jstr(repo_name)),
        ("remote", ji(deleted_remote)),
        ("cherry", ji(deleted_cherry)),
        ("merged", ji(deleted_merged)),
        ("processOnly", ji(deleted_process_only)),
        ("staleBundled", ji(deleted_stale_bundled)),
        ("bundle", jstr(bundle_path.unwrap_or(""))),
      ]),
    )
  }

  Some(
    jobj_of([
      ("repo", jstr(repo_name)),
      ("deletedRemote", ji(deleted_remote)),
      ("deletedCherry", ji(deleted_cherry)),
      ("deletedMerged", ji(deleted_merged)),
      ("deletedProcessOnly", ji(deleted_process_only)),
      ("deletedStaleBundled", ji(deleted_stale_bundled)),
      ("bundlePath", match bundle_path { Some(p) => jstr(p); None => Json::null() }),
    ]),
  )
}

///|
/// Cleans local branches across all shared clones in `<data>/repos` (ops/repo-branches.ts `pruneAllRepoBranches`).
async fn P53Upkeep::prune_all_repo_branches(self : P53Upkeep, now : Double) -> Array[Json] {
  let bus = self.bus
  let host = bus.host
  let data = bus.data
  if bus.hub_clones_active() {
    return []
  }
  guard p53_realpath(host, data) is Some(real_data) else { return [] }
  guard p53_realpath(host, @nodepath.join(sep(), [real_data, "repos"])) is Some(real_repos) else { return [] }
  if !p53_inside(real_repos, real_data) {
    return []
  }
  ignore(p53_prune_repo_worktrees(host, data))
  let out : Array[Json] = []
  for name in p53_names(host, real_repos) {
    if bus.hub_clones_active() {
      break
    }
    if name.has_prefix(".") {
      continue
    }
    let repo_path = @nodepath.join(sep(), [real_repos, name])
    if jtext(p53_lstat(host, repo_path), "kind") != Some("dir") {
      continue
    }
    guard p53_realpath(host, repo_path) is Some(real_repo) else { continue }
    if !p53_inside(real_repo, real_data) {
      continue
    }
    match p53_prune_repo_branches_in(host, data, name, real_repo, now) {
      Some(summary) => out.push(summary)
      None => ()
    }
  }
  out
}

///|
/// Removes `.bundle` and `.txt` files under `<data>/repo-bundles/<clone>` older than 30 days and prunes empty
/// `<clone>` subdirectories (ops/repo-branches.ts `pruneExpiredRepoBundles`).
async fn p53_prune_expired_repo_bundles(host : @host.Host, data : String, now : Double) -> Array[String] {
  guard p53_realpath(host, data) is Some(real_data) else { return [] }
  let bundles_dir = @nodepath.join(sep(), [real_data, "repo-bundles"])
  if jtext(p53_lstat(host, bundles_dir), "kind") != Some("dir") {
    return []
  }
  let gone : Array[String] = []
  for clone_name in p53_names(host, bundles_dir) {
    if clone_name.has_prefix(".") {
      continue
    }
    let clone_dir = @nodepath.join(sep(), [bundles_dir, clone_name])
    if jtext(p53_lstat(host, clone_dir), "kind") != Some("dir") {
      continue
    }
    let entries = p53_names(host, clone_dir)
    let mut remaining = entries.length()
    for file_name in entries {
      if !file_name.has_suffix(".bundle") && !file_name.has_suffix(".txt") {
        continue
      }
      let file_path = @nodepath.join(sep(), [clone_dir, file_name])
      let st = p53_lstat(host, file_path)
      if jtext(st, "kind") != Some("file") {
        continue
      }
      match jnum_of(st, "mtimeMs") {
        Some(at) if now - at >= p53_repo_bundle_ms => {
          p53_remove(host, file_path)
          if jtext(p53_lstat(host, file_path), "kind") is None {
            gone.push("\{clone_name}/\{file_name}")
            remaining -= 1
          }
        }
        _ => ()
      }
    }
    if remaining <= 0 {
      if p53_names(host, clone_dir).length() == 0 {
        p53_remove(host, clone_dir)
      }
    }
  }
  gone.sort_by(p53_units_order)
  gone
}
