// The source's side of a directory mirrored on another station for its remote tasks (station_task's `dir`): each start
// brings the mirror up to date before the command runs there (`sync_dir`, from `sync_of`).
//
// - Which files: in a Git work tree what `git ls-files -co --exclude-standard` names (tracked, and untracked but not
//   ignored), so node_modules, target and dist stay home; elsewhere every file but `ignored_dirs`. `.git` is not
//   synced, neither are nested repositories. A submodule's files are not sent either (one is tens of thousands of
//   them): it goes as its path, the commit checked out here (else the index's) and its URL (`.gitmodules`, the
//   repository's own config before it, a relative one against `origin`), which the target checks out in the mirror
//   before a task runs (dirsync.mbt `submodules_script`); one with no URL is left out. A symbolic link goes as a link
//   when what it names stays inside the directory, and is left out (said in `skipped`) when it leads out.
// - Compared by content: a file's id is its Git blob id (sha1 of "blob <size>\0" and its bytes), free from the index
//   for a clean tracked file the mirror has as it is, hashed for the rest (also a clean one that would be sent: with a
//   filter or eol conversion its bytes are not what the index names). The target keeps the last synced source state
//   and answers with it and what is there now (a file a command changed is hashed again). The source plans its changes
//   against the last synced state; the target preserves remote-only changes and refuses conflicting changes
//   (dirsync.mbt, the target's side).
// - Sent: only contents the mirror has nowhere, as pieces packed into zstd-compressed requests (`sync.put`), each
//   within the transport's 1 MiB message; then the plan (`sync.commit`), in pages as well. The target lands each
//   request's packed bytes in a file and its program unpacks them (dirsync.mbt `put_blobs`).
// - Written there: a changed file goes to a temporary file renamed over it, with its exec bit; a file that left the set
//   is removed if it did not change remotely; an existing remote result at a new path is checked too. An unchanged
//   file keeps its mtime, so incremental builds there see exactly what changed.
//
// Every file is listed, hashed, read and packed by the shell (client/shell `fs.scan`, `zstd.pack`, `proc.run` for
// git), off this program's thread, its bytes never through it: Node only carries the requests (`ask`) and a packed
// request's file (`syncPut`, one at a time with the station's other bulk requests: jobs/dirsync.ts `Bulk`).
// station/test/dirsync-reference.ts is the TypeScript this was, which the tests compare it with.

///|
/// Directories a walk outside Git leaves out, wherever they are: version control, dependencies and build output.
let ignored_dirs : Array[String] = [
  ".git", ".hg", ".svn", ".jj", "node_modules", "target", "dist", "build", ".gradle", ".next", ".turbo", ".cache", "__pycache__",
  ".venv",
]

///|
let ignored_files : Array[String] = [".DS_Store"]

///|
/// At most this many files in a directory synced.
let max_files : Int = 200000

///|
/// A walk outside Git lists at most this many entries (directories too), at most this deep.
let walk_entries : Int = 2 * max_files

///|
let walk_depth : Int = 64

///|
/// A file goes in pieces of at most this much.
let piece_bytes : Int = 512 * 1024

///|
/// To a station from before bytes went after a request (mesh/peer.ts): a request's packed data at most (base64 of the
/// compressed pieces); with the rest of the request it stays within the transport's message (1 MiB).
let body_bytes : Int = 720 * 1024

///|
/// Paths given the shell at once to list or hash (`fs.scan`, 8 at a time there).
let scan_batch : Int = 2000

///|
/// How long a git asked for what a directory has may take (a deadline: it is waited on by nothing else).
let git_ms : Double = 3600000.0

///|
/// A file of the directory: `indexed` when its id is the Git index's (a clean tracked file), not yet its bytes' hash.
priv struct Local {
  path : String
  mut hash : String
  mut mode : String
  mut size : Int
  mut indexed : Bool
}

///|
priv struct Listing {
  mut files : Array[Local]
  git : Bool
  prefix : String
  skipped : Array[(String, String)]
  /// The submodules to check out there: path, commit, URL.
  submodules : Array[(String, String, String)]
}

///|
fn Listing::to_json(self : Listing) -> Json {
  {
    "files": Json::array(
      self.files.map(f => {
        let m : Map[String, Json] = { "path": jstr(f.path), "hash": jstr(f.hash), "mode": jstr(f.mode), "size": jnum(f.size.to_double()) }
        if f.indexed {
          m["indexed"] = jbool(true)
        }
        Json::object(m)
      }),
    ),
    "git": jbool(self.git),
    "prefix": jstr(self.prefix),
    "skipped": Json::array(self.skipped.map(s => { "path": jstr(s.0), "why": jstr(s.1) })),
    "submodules": Json::array(self.submodules.map(s => { "path": jstr(s.0), "id": jstr(s.1), "url": jstr(s.2) })),
  }
}

///|
/// What a path of the directory is on disk, as `fs.scan` with `hash` said it.
priv enum OnDisk {
  Got(Local)
  /// Left out, and why.
  Left(String)
  /// Not there (or a directory).
  Gone
}

///|
fn on_disk(path : String, st : Json) -> OnDisk {
  if st is Null {
    return Gone
  }
  match kind_of_stat(st) {
    "link" => {
      let target = text_of(st, "link")
      if !link_inside(path, target) {
        Left("symbolic link leading out of the directory")
      } else {
        Got({ path, hash: text_blob_id(target), mode: link_mode, size: bytes_len(target), indexed: false })
      }
    }
    "dir" => Gone
    "file" => {
      let size = num_of(st.value("size")).unwrap_or(0.0)
      if size > max_file {
        Left("larger than 1 GiB")
      } else {
        Got({ path, hash: text_of(st, "hash"), mode: mode_of_bits(num_of(st.value("mode")).unwrap_or(0.0)), size: size.to_int(), indexed: false })
      }
    }
    _ => Left("not a regular file")
  }
}

///|
/// What the shell says of each of `paths` (relative to `dir`), in their order: lstat's, with each file's blob id and
/// each link's target where `hash`.
async fn Actors::scan(self : Actors, dir : String, paths : Array[String], hash : Bool) -> Array[Json] raise {
  let out : Array[Json] = []
  let mut i = 0
  while i < paths.length() {
    let end = if i + scan_batch < paths.length() { i + scan_batch } else { paths.length() }
    let abs = paths[i:end].iter().map(p => jstr(self.rjoin([dir, p]))).collect()
    match self.fs("fs.scan", { "paths": Json::array(abs), "hash": jbool(hash), "most": jnum(max_file) }) {
      Array(got) if got.length() == end - i => out.append(got)
      _ => raise refusal("the files of \{dir} could not be listed")
    }
    i = end
  }
  out
}

///|
/// `git -C dir args` (GIT_OPTIONAL_LOCKS=0: a status of ours takes no lock a person's git would wait on): its output;
/// None when it did not end well (not started, not a work tree, a code not 0).
async fn Actors::git_out(self : Actors, dir : String, args : Array[String]) -> String? raise {
  let all = [jstr("-C"), jstr(dir)]
  all.append(args.map(jstr))
  match
    self.fs("proc.run", {
      "command": jstr("git"),
      "args": Json::array(all),
      "env": { "GIT_OPTIONAL_LOCKS": "0" },
      "timeoutMs": jnum(git_ms),
      "maxBytes": jnum(1073741824.0),
    }) {
    String(s) => Some(s)
    _ => None
  }
}

///|
async fn Actors::git_list(self : Actors, dir : String, args : Array[String]) -> Array[String] raise {
  guard self.git_out(dir, args) is Some(out) else { raise refusal("git \{args.join(" ")} failed in \{dir}") }
  out.split("\u{0}").filter(s => s != "").map(s => s.to_string()).collect()
}

///|
fn too_many(dir : String) -> Error {
  refusal("\{dir} has more than \{max_files} files to sync")
}

///|
/// What of `dir` is synced: Git's files in a work tree, a walk without `ignored_dirs` elsewhere.
async fn Actors::list_local(self : Actors, dir : String) -> Listing raise {
  match self.fs("fs.scan", { "paths": [jstr(dir)], "follow": jbool(true) }) {
    Array([Null]) => raise refusal("ENOENT: no such file or directory, stat '\{dir}'")
    Array([st]) if kind_of_stat(st) == "dir" => ()
    Array([_]) => raise refusal("\{dir} is not a directory")
    _ => raise refusal("\{dir} could not be read")
  }
  let mut tree : Array[String]? = None
  if self.git_out(dir, ["rev-parse", "--is-inside-work-tree", "--show-prefix"]) is Some(out) {
    let lines = out.split("\n").map(s => s.to_string()).collect()
    tree = Some(lines)
    // A directory its work tree ignores (a build directory) has no files Git names: walked.
    if lines[0] == "true" && lines.length() > 1 && lines[1] != "" {
      match self.fs("proc.run", { "command": jstr("git"), "args": [jstr("-C"), jstr(dir), jstr("check-ignore"), jstr("-q"), jstr(".")], "env": { "GIT_OPTIONAL_LOCKS": "0" }, "timeoutMs": jnum(git_ms), "code": jbool(true) }) {
        { "code": Number(0, ..), .. } => tree = None
        _ => ()
      }
    }
  }
  let files : Array[Local] = []
  let skipped : Array[(String, String)] = []
  let take = (path : String, got : OnDisk) => match got {
    Got(l) => files.push(l)
    Left(why) => skipped.push((path, why))
    Gone => ()
  }
  if tree is Some(lines) && lines[0] == "true" {
    let prefix = if lines.length() > 1 { lines[1] } else { "" }
    let modified : Map[String, Bool] = {}
    for p in self.git_list(dir, ["ls-files", "-z", "-m"]) {
      modified[p] = true
    }
    let seen : Map[String, Bool] = {}
    let hash : Array[String] = []
    let clean : Array[(String, String, String)] = []
    let links : Array[(String, String)] = []
    for line in self.git_list(dir, ["ls-files", "-z", "-s"]) {
      guard line.find("\t") is Some(tab) else { continue }
      let head = line.view(end_offset=tab).split(" ").map(s => s.to_string()).collect()
      let path = line.view(start_offset=tab + 1).to_string()
      if seen.contains(path) {
        continue
      }
      seen[path] = true
      let mode = head[0]
      let id = if head.length() > 1 { head[1] } else { "" }
      let stage = if head.length() > 2 { head[2] } else { "" }
      if mode == "160000" {
        links.push((path, id))
        continue
      }
      // A clean tracked file is what the index says; a changed one (or one in a conflict), or a link, is hashed.
      if modified.contains(path) || stage != "0" || mode == link_mode || (mode != file_mode && mode != exec_mode) {
        hash.push(path)
        continue
      }
      clean.push((path, id, mode))
      if clean.length() > max_files {
        raise too_many(dir)
      }
    }
    // Each one's size, by the shell (8 at a time there).
    let sizes = self.scan(dir, clean.map(c => c.0), false)
    for i, c in clean {
      let st = sizes[i]
      if st is Null {
        continue
      }
      if kind_of_stat(st) != "file" {
        hash.push(c.0)
      } else {
        files.push({ path: c.0, hash: c.1, mode: c.2, size: num_of(st.value("size")).unwrap_or(0.0).to_int(), indexed: true })
      }
    }
    if files.length() > max_files {
      raise too_many(dir)
    }
    for path in self.git_list(dir, ["ls-files", "-z", "-o", "--exclude-standard"]) {
      if path.has_suffix("/") {
        skipped.push((path.view(end_offset=path.length() - 1).to_string(), "nested repository"))
      } else {
        hash.push(path)
      }
    }
    if files.length() + hash.length() > max_files {
      raise too_many(dir)
    }
    let got = self.scan(dir, hash, true)
    for i, path in hash {
      take(path, on_disk(path, got[i]))
    }
    let submodules = self.submodules_of(dir, prefix, links, skipped)
    files.sort_by((a, b) => @search.compare_units(a.path, b.path))
    return { files, git: true, prefix, skipped, submodules }
  }
  // Walked bounded (as station/src/ops/walk.ts `walkBounded` walks, breadth first): a directory on another file system
  // mounted in it is left out (said in `skipped`), no link followed. What would leave the listing short is an error,
  // never a listing short of files, whose absence the mirror would take for files removed.
  let found : Array[String] = []
  let root_dev = match self.fs("fs.scan", { "paths": [jstr(dir)], "follow": jbool(true) }) {
    Array([st]) => num_of(st.value("dev")).unwrap_or(0.0)
    _ => 0.0
  }
  let queue : Array[(String, String, Int)] = [(dir, "", 0)]
  let mut head = 0
  // (the root is an entry visited)
  let mut visited = 1
  let mut deeper = false
  let entries_over = () => refusal("\{dir} has more than \{walk_entries} entries to walk")
  while head < queue.length() {
    let (path, rel, depth) = queue[head]
    head += 1
    if visited >= walk_entries {
      raise entries_over()
    }
    let listed : Array[(String, String)] = match self.fs("fs.readdir", { "path": jstr(path), "types": jbool(true) }) {
      Array(rows) =>
        rows.filter_map(r => match r {
          Array([String(n), String(k), ..]) => Some((n, k))
          _ => None
        })
      _ => raise refusal("\{path} could not be read")
    }
    // The directories' own lstat (their device), as the walk takes each.
    let dirs = listed.filter(e => e.1 == "dir").map(e => e.0)
    let stats : Map[String, Json] = {}
    for i, st in self.scan(path, dirs, false) {
      stats[dirs[i]] = st
    }
    for e in listed {
      let (name, kind) = e
      if visited >= walk_entries {
        raise entries_over()
      }
      let mut directory = kind == "dir"
      let mut dev = root_dev
      if directory {
        // (one gone since it was listed is passed over)
        guard stats.get(name) is Some(st) && !(st is Null) else { continue }
        directory = kind_of_stat(st) == "dir"
        dev = num_of(st.value("dev")).unwrap_or(0.0)
      }
      visited += 1
      let rel2 = if rel == "" { name } else { "\{rel}/\{name}" }
      if !directory {
        if !ignored_files.contains(name) {
          found.push(rel2)
          if found.length() > max_files {
            raise too_many(dir)
          }
        }
        continue
      }
      if ignored_dirs.contains(name) {
        continue
      }
      if dev != root_dev {
        skipped.push((rel2, "another file system"))
        continue
      }
      if depth + 1 >= walk_depth {
        deeper = true
        continue
      }
      queue.push((self.rjoin([path, name]), rel2, depth + 1))
    }
  }
  if deeper {
    raise refusal("\{dir} is deeper than \{walk_depth} directories")
  }
  let got = self.scan(dir, found, true)
  for i, path in found {
    take(path, on_disk(path, got[i]))
  }
  files.sort_by((a, b) => @search.compare_units(a.path, b.path))
  { files, git: false, prefix: "", skipped, submodules: [] }
}

///|
/// `git config -z` entries of `args` (--get-regexp's): key → value; none where git found none.
async fn Actors::git_config(self : Actors, dir : String, args : Array[String]) -> Map[String, String] raise {
  let all = ["config", "-z"]
  all.append(args)
  let out : Map[String, String] = {}
  guard self.git_out(dir, all) is Some(text) else { return out }
  for entry in text.split("\u{0}") {
    let entry = entry.to_string()
    match entry.find("\n") {
      Some(nl) => out[entry.view(end_offset=nl).to_string()] = entry.view(start_offset=nl + 1).to_string()
      None => if entry != "" { out[entry] = "" }
    }
  }
  out
}

///|
/// A submodule's URL as Git takes it: one relative to the superproject's (`./`, `../`) against `base` (its origin's
/// URL; none without one), each `../` taking off the last part of it.
fn submodule_url(url : String, base : String) -> String {
  if !url.has_prefix("./") && !url.has_prefix("../") {
    return url
  }
  if base == "" {
    return ""
  }
  let mut b = base
  while b.has_suffix("/") {
    b = b.view(end_offset=b.length() - 1).to_string()
  }
  let mut u = url
  while true {
    if u.has_prefix("./") {
      u = u.view(start_offset=2).to_string()
    } else if u.has_prefix("../") {
      u = u.view(start_offset=3).to_string()
      // (a part goes up to its `/`, or up to the `:` of `host:path`, which `host:` keeps)
      let cut = match b.rev_find("/") {
        Some(i) if i > 0 && !(b.view(end_offset=i).to_string().has_suffix("/")) => Some(i)
        _ => b.rev_find(":").map(i => i + 1)
      }
      match cut {
        Some(i) => b = b.view(end_offset=i).to_string()
        None => return ""
      }
    } else {
      break
    }
  }
  if b.has_suffix(":") { b + u } else { b + "/" + u }
}

///|
/// The submodules among `links` (path, the index's commit) as the target is to check them out: the commit checked out
/// in each (a submodule moved on and not yet staged is built at it here), else the index's, and its URL. One with no
/// URL is left out, said in `skipped`.
async fn Actors::submodules_of(self : Actors, dir : String, prefix : String, links : Array[(String, String)], skipped : Array[(String, String)]) -> Array[(String, String, String)] raise {
  let out : Array[(String, String, String)] = []
  if links.length() == 0 {
    return out
  }
  // `.gitmodules` as the index has it (its paths from the work tree's top), the repository's own URLs before it.
  let listed = self.git_config(dir, ["--blob", ":.gitmodules", "--get-regexp", "^submodule\\..*\\.(path|url)$"])
  let own = self.git_config(dir, ["--get-regexp", "^submodule\\..*\\.url$"])
  let origin = self.git_out(dir, ["config", "--get", "remote.origin.url"]).unwrap_or("").trim_space().to_string()
  let named : Map[String, String] = {}
  for key, value in listed {
    if key.has_prefix("submodule.") && key.has_suffix(".path") {
      named[value] = key.view(start_offset=10, end_offset=key.length() - 5).to_string()
    }
  }
  let heads = self.scan(dir, links.map(l => "\{l.0}/.git"), false)
  for i, link in links {
    let (path, index_id) = link
    let url = match named.get(prefix + path) {
      Some(name) => {
        let given = match own.get("submodule.\{name}.url") {
          Some(u) => u
          None => listed.get("submodule.\{name}.url").unwrap_or("")
        }
        submodule_url(given, origin)
      }
      None => ""
    }
    if url == "" {
      skipped.push((path, "submodule with no URL in .gitmodules"))
      continue
    }
    let mut id = index_id
    if !(heads[i] is Null) {
      match self.git_out(self.rjoin([dir, path]), ["rev-parse", "-q", "--verify", "HEAD^{commit}"]) {
        Some(h) if is_blob_id(h.trim_space().to_string()) => id = h.trim_space().to_string()
        _ => ()
      }
    }
    out.push((path, id, url))
  }
  out
}

///|
/// Pages of a manifest or of the base (`sync.manifest`, `sync.base`): path → (id, mode), in their order.
async fn sync_pages(ask : async (String, Map[String, Json]) -> Json raise, method : String, id : String) -> Map[String, (String, String)] raise {
  let out : Map[String, (String, String)] = {}
  let mut after = Some(0.0)
  while after is Some(a) {
    let page = ask(method, { "id": jstr(id), "after": jnum(a) })
    match field_of(page, "entries") {
      Array(entries) =>
        for e in entries {
          if e is Array([String(path), String(hash), String(mode), ..]) {
            out[path] = (hash, mode)
          }
        }
      _ => ()
    }
    after = match field_of(page, "next") {
      Number(n, ..) => Some(n)
      _ => None
    }
  }
  out
}

///|
/// Builds `sync.commit` request payloads whose final serialized UTF-8 JSON bytes stay within `budget` (covering `id`,
/// `set`, `remove`, `final`, and `submodules` plus JSON frame overhead). A single item (or `submodules` alone) larger
/// than `budget` is placed in its own page so pagination always makes progress.
fn sync_commit_pages(
  id : String,
  set : Array[Json],
  remove : Array[String],
  submodules : Array[(String, String, String)],
  budget? : Int = page_bytes,
) -> Array[Map[String, Json]] {
  // Base frame with `"final":false` (1 byte larger than `"final":true`).
  let frame_base = bytes_len(js_text({ "id": jstr(id), "set": Json::array([]), "remove": Json::array([]), "final": jbool(false) }))
  let pages : Array[(Array[Json], Array[Json], Int)] = [([], [], frame_base)]
  for item in set {
    let n = bytes_len(js_text(item))
    let cur = pages[pages.length() - 1]
    let comma = if cur.0.length() > 0 { 1 } else { 0 }
    if cur.2 + comma + n > budget && (cur.0.length() > 0 || cur.1.length() > 0) {
      pages.push(([item], [], frame_base + n))
    } else {
      cur.0.push(item)
      pages[pages.length() - 1] = (cur.0, cur.1, cur.2 + comma + n)
    }
  }
  for path in remove {
    let item = jstr(path)
    let n = bytes_len(js_text(item))
    let cur = pages[pages.length() - 1]
    let comma = if cur.1.length() > 0 { 1 } else { 0 }
    if cur.2 + comma + n > budget && (cur.0.length() > 0 || cur.1.length() > 0) {
      pages.push(([], [item], frame_base + n))
    } else {
      cur.1.push(item)
      pages[pages.length() - 1] = (cur.0, cur.1, cur.2 + comma + n)
    }
  }
  let subs_json = Json::array(submodules.map(s => Json::array([jstr(s.0), jstr(s.1), jstr(s.2)])))
  if submodules.length() > 0 {
    let last = pages[pages.length() - 1]
    // `"final":true` is 1 byte shorter than `"final":false`.
    let with_subs = last.2 - 1 + bytes_len(",\"submodules\":") + bytes_len(js_text(subs_json))
    if with_subs > budget && (last.0.length() > 0 || last.1.length() > 0) {
      pages.push(([], [], frame_base))
    }
  }
  let out : Array[Map[String, Json]] = []
  for i, page in pages {
    let is_last = i == pages.length() - 1
    let commit : Map[String, Json] = {
      "id": jstr(id),
      "set": Json::array(page.0),
      "remove": Json::array(page.1),
      "final": jbool(is_last),
    }
    if is_last && submodules.length() > 0 {
      commit["submodules"] = subs_json
    }
    out.push(commit)
  }
  out
}

///|
/// Brings the mirror on `station` of the task `key` up to date with `dir`: what it did (the `Synced` the start says);
/// null when the task started already (nothing synced: a start asked again returns the job that started).
async fn Actors::sync_dir(self : Actors, station : String, workspace : String, session : String, key : String, dir : String) -> Json raise {
  let t0 = self.remote_now()
  let ask = async fn(method : String, more : Map[String, Json]) -> Json raise {
    let request : Map[String, Json] = { "workspace": jstr(workspace), "session": jstr(session), "key": jstr(key), "method": jstr(method) }
    for k, v in more {
      request[k] = v
    }
    self.ask(station, Json::object(request))
  }
  let begun = ask("sync.begin", { "safe": jnum(1.0) })
  if field_of(begun, "started") is True {
    return Json::null()
  }
  if field_of(begun, "safe") != jnum(1.0) {
    raise refusal("the target cannot protect remote results during sync; update that station before starting")
  }
  let id = match field_of(begun, "id") {
    String(s) => s
    Null => ""
    v => js_text(v)
  }
  let listing = self.list_local(dir)
  let there = sync_pages(ask, "sync.manifest", id)
  let base = sync_pages(ask, "sync.base", id)
  // Compared with the last source version, not the mirror's possibly newer task output.
  let same = (f : Local) => base.get(f.path) is Some((h, m)) && h == f.hash && m == f.mode
  // What would go with the index's id is hashed first: with a Git filter or eol conversion (a .bat checked out with
  // CRLF, LFS) the bytes on disk are not what the index names, and what the mirror has may be them already.
  let again = listing.files.filter(f => f.indexed && !same(f))
  let gone : Map[String, Bool] = {}
  let got = self.scan(dir, again.map(f => f.path), true)
  for i, f in again {
    match on_disk(f.path, got[i]) {
      Got(l) => {
        f.hash = l.hash
        f.mode = l.mode
        f.size = l.size
        f.indexed = false
      }
      Left(why) => {
        gone[f.path] = true
        listing.skipped.push((f.path, why))
      }
      Gone => gone[f.path] = true
    }
  }
  if gone.length() > 0 {
    listing.files = listing.files.filter(f => !gone.contains(f.path))
  }
  let have : Map[String, Bool] = {}
  for _, e in there {
    have[reuse_key(e.0, e.1)] = true
  }
  let set : Array[Json] = []
  let need : Map[String, Local] = {}
  for f in listing.files {
    if same(f) {
      continue
    }
    set.push(Json::array([jstr(f.path), jstr(f.hash), jstr(f.mode)]))
    if !have.contains(reuse_key(f.hash, f.mode)) && !need.contains(f.hash) {
      need[f.hash] = f
    }
  }
  let local : Map[String, Bool] = {}
  for f in listing.files {
    local[f.path] = true
  }
  let remove = base.keys().filter(p => !local.contains(p)).collect()
  let sent = self.send_blobs(station, { "workspace": jstr(workspace), "session": jstr(session), "key": jstr(key) }, id, dir, need.values().collect())
  let commits = sync_commit_pages(id, set, remove, listing.submodules)
  let mut answer = Json::null()
  for commit in commits {
    answer = ask("sync.commit", commit)
  }
  let skipped = listing.skipped
  {
    "files": jnum(listing.files.length().to_double()),
    "git": jbool(listing.git),
    "sent": sent,
    "written": jnum(num_of(answer.value("written")).unwrap_or(0.0)),
    "removed": jnum(num_of(answer.value("removed")).unwrap_or(0.0)),
    "skipped": Json::array(skipped[0:if skipped.length() < 50 { skipped.length() } else { 50 }].iter().map(s => ({ "path": jstr(s.0), "why": jstr(s.1) } : Json)).collect()),
    "skippedCount": jnum(skipped.length().to_double()),
    "submodules": jnum(listing.submodules.length().to_double()),
    "prefix": jstr(listing.prefix),
    "ms": jnum(self.remote_now() - t0),
  }
}

///|
/// A piece of a content to send: its id, its size, where it starts and how long it is, the file (`abs`, `path` as the
/// directory names it) and whether it is a link's target.
priv struct Piece {
  hash : String
  size : Int
  offset : Int
  length : Int
  abs : String
  path : String
  link : Bool
}

///|
/// A sync's contents on their way.
priv struct Sending {
  station : String
  /// What every request of the sync says (its workspace, session and task).
  base : Map[String, Json]
  id : String
  /// The shell's ids of the files as their pieces are packed (`pack.open`).
  pack : Json
  /// Whether the station takes the packed pieces after the request: until its transport says it does not (NoBytes,
  /// the first request not sent).
  mut after : Bool
  /// How much a request's pieces shrink, from the last one (assumed not at all at first).
  mut ratio : Double
  mut batch : Array[Piece]
  mut raw : Int
  mut bytes : Double
  mut packed : Double
  mut requests : Int
}

///|
/// Sends the contents in `need` in packed requests, each of max_raw at most, its packed pieces after it; to a station
/// from before, each within body_bytes, base64 in it. Each file is checked to be still what was hashed as it is packed.
async fn Actors::send_blobs(self : Actors, station : String, base : Map[String, Json], id : String, dir : String, need : Array[Local]) -> Json raise {
  let pack = field_of(self.fs("pack.open", {}), "id")
  let s : Sending = { station, base, id, pack, after: true, ratio: 1.0, batch: [], raw: 0, bytes: 0.0, packed: 0.0, requests: 0 }
  defer (try { ignore(self.fs("pack.close", { "id": pack })) } catch { _ => () })
  for f in need {
    let abs = self.rjoin([dir, f.path])
    if f.mode == link_mode {
      self.add_piece(s, { hash: f.hash, size: f.size, offset: 0, length: f.size, abs, path: f.path, link: true })
      continue
    }
    let mut offset = 0
    while true {
      let length = if f.size - offset < piece_bytes { f.size - offset } else { piece_bytes }
      self.add_piece(s, { hash: f.hash, size: f.size, offset, length, abs, path: f.path, link: false })
      offset += length
      if offset >= f.size {
        break
      }
    }
  }
  self.flush_pieces(s, s.batch)
  { "files": jnum(need.length().to_double()), "bytes": jnum(s.bytes), "packed": jnum(s.packed), "requests": jnum(s.requests.to_double()) }
}

///|
/// A `sync.put` of `blobs` (their packed bytes Node's to add).
fn put_request(s : Sending, blobs : Array[Json]) -> Json {
  let request = s.base.copy()
  request["method"] = jstr("sync.put")
  request["id"] = jstr(s.id)
  request["blobs"] = Json::array(blobs)
  Json::object(request)
}

///|
async fn Actors::add_piece(self : Actors, s : Sending, piece : Piece) -> Unit raise {
  let budget = if s.after {
    max_raw.to_double()
  } else {
    let b = body_bytes.to_double() * 0.7 / s.ratio
    if b < max_raw.to_double() { b } else { max_raw.to_double() }
  }
  if s.batch.length() > 0 && ((s.raw + piece.length).to_double() > budget || s.batch.length() >= max_pieces) {
    let pieces = s.batch
    s.batch = []
    s.raw = 0
    self.flush_pieces(s, pieces)
  }
  s.batch.push(piece)
  s.raw += piece.length
  s.bytes += piece.length.to_double()
}

///|
/// `pieces` packed by the shell into a file of Node's and sent in one request (`sync.put`): after it, or, to a station
/// from before, base64 in it, in halves where that would not fit its message.
async fn Actors::flush_pieces(self : Actors, s : Sending, pieces : Array[Piece]) -> Unit raise {
  if pieces.length() == 0 {
    return
  }
  let out = match self.rnode("syncPacking", []) {
    String(p) => p
    _ => raise refusal("no place to pack a sync's pieces")
  }
  defer (try { self.remove(out) } catch { _ => () })
  let index = pieces.map(p => Json::array([jstr(p.abs), jnum(p.offset.to_double()), jnum(p.length.to_double()), jnum(p.size.to_double()), jstr(p.hash), jbool(p.link)]))
  let made = self.fs("zstd.pack", { "id": s.pack, "out": jstr(out), "pieces": Json::array(index) })
  if field_of(made, "changed") is Number(i, ..) {
    raise refusal("\{pieces[i.to_int()].path} changed while syncing; start again")
  }
  let raw = num_of(made.value("raw")).unwrap_or(0.0)
  let packed = num_of(made.value("packed")).unwrap_or(0.0)
  let blobs = pieces.map(p => Json::array([jstr(p.hash), jnum(p.size.to_double()), jnum(p.offset.to_double()), jnum(p.length.to_double())]))
  if s.after {
    let sent = try {
      ignore(self.rnode("syncPut", [jstr(s.station), put_request(s, blobs), jstr(out), jbool(true)]))
      true
    } catch {
      Asked(j) as e => if j.value("kind") is Some(String("NoBytes")) { false } else { raise e }
      e => raise e
    }
    if !sent {
      s.after = false
    }
  }
  if !s.after {
    // (base64's length of the packed bytes)
    let data = ((packed + 2.0) / 3.0).floor() * 4.0
    if data > body_bytes.to_double() && pieces.length() > 1 {
      let half = (pieces.length() + 1) / 2
      self.flush_pieces(s, pieces[0:half].to_array())
      self.flush_pieces(s, pieces[half:].to_array())
      return
    }
    ignore(self.rnode("syncPut", [jstr(s.station), put_request(s, blobs), jstr(out), jbool(false)]))
  }
  s.ratio = { let r = packed / (if raw > 1.0 { raw } else { 1.0 }); if r > 0.02 { r } else { 0.02 } }
  s.requests += 1
  s.packed += packed
}
