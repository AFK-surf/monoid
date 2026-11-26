// A source session's directory mirrored on this station for its remote tasks (dirsync_source.mbt, whose head says how
// a sync goes, is the source's side): the target's side here, what the mirror has, the contents sent unpacked into it
// and how a plan is carried out in it. Every file operation is the shell's (off this program's thread): Node only lands a request's
// packed pieces in a file as they come off the transport (remote.ts `answer`), never a piece's write, stat or rename.

///|
let file_mode : String = "100644"

///|
let exec_mode : String = "100755"

///|
let link_mode : String = "120000"

///|
/// Reuse key separating regular files from symlinks that happen to share the same Git blob id.
fn reuse_key(hash : String, mode : String) -> String {
  (if mode == link_mode { "link:" } else { "file:" }) + hash
}

///|
fn is_enoent_error(msg : String) -> Bool {
  msg.contains("ENOENT") || msg.contains("No such file or directory") || msg.contains("cannot find the file")
}

///|
/// A page of a manifest or a plan, as JSON, at most about this much.
let page_bytes : Int = 512 * 1024

///|
/// A request's pieces at most, and their bytes unpacked at most (as the source packs them: dirsync_source.mbt).
let max_pieces : Int = 2000

///|
let max_raw : Int = 16 * 1024 * 1024

///|
fn mode_of_bits(mode : Double) -> String {
  if (mode.to_int() & 0o111) != 0 {
    exec_mode
  } else {
    file_mode
  }
}

///|
/// A content's id as Git has it, of a link's target (its text).
fn text_blob_id(text : String) -> String {
  @replica.sha1_hex("blob \{bytes_len(text)}\u{0}\{text}")
}

///|
fn is_blob_id(s : String) -> Bool {
  s.length() == 40 && s.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
}

///|
/// Whether a link at `path` (relative, / between parts) naming `target` stays inside the directory (the source's
/// listing and the target's writing both ask).
fn link_inside(path : String, target : String) -> Bool {
  if target == "" || target.has_prefix("/") || target.has_prefix("\\") {
    return false
  }
  if target.length() >= 2 && target.unsafe_charcode_at(1) == ':'.to_int() {
    let c = target.unsafe_charcode_at(0)
    if (c >= 'A'.to_int() && c <= 'Z'.to_int()) || (c >= 'a'.to_int() && c <= 'z'.to_int()) {
      return false
    }
  }
  let parts : Array[String] = path.split("/").map(p => p.to_string()).collect()
  ignore(parts.pop())
  for part in target.replace_all(old="\\", new="/").split("/") {
    let part = part.to_string()
    if part == "" || part == "." {
      continue
    }
    if part == ".." {
      if parts.length() == 0 {
        return false
      }
      ignore(parts.pop())
    } else {
      parts.push(part)
    }
  }
  true
}

///|
/// The blob id of the file at `path`, `size` bytes long (refused when it reads otherwise).
async fn Actors::file_id(self : Actors, path : String, size : Double) -> String raise {
  match self.fs("fs.gitblob", { "path": jstr(path), "size": jnum(size) }) {
    String(s) => s
    _ => raise FsError("\{path} changed while it was read")
  }
}

///|
async fn Actors::read_link(self : Actors, path : String) -> String raise {
  match self.fs("fs.readlink", { "path": jstr(path) }) {
    String(s) => s
    _ => raise FsError("ENOENT: no such file or directory, readlink '\{path}'")
  }
}

///|
/// A mirror's manifest: {dir, name, version, files: {path: [id, mode, size, mtime, ino, ctime]}}; None when there is
/// none (or it does not read).
async fn Actors::read_manifest(self : Actors, path : String) -> Json? raise {
  guard self.read_text(path) is Some(text) else { return None }
  match (try Some(@json.parse(text)) catch { _ => None }) {
    Some(Object(m) as v) if m.get("files") is Some(Object(_)) => Some(v)
    _ => None
  }
}

///|
fn files_of(manifest : Json?) -> Map[String, Json] {
  match manifest {
    Some(m) =>
      match field_of(m, "files") {
        Object(f) => f.copy()
        _ => {}
      }
    None => {}
  }
}

///|
fn entry_of_stat(hash : String, mode : String, st : Json) -> Json {
  Json::array([jstr(hash), jstr(mode), st.value("size").unwrap_or(jnum(0.0)), st.value("mtimeMs").unwrap_or(jnum(0.0)), st.value("ino").unwrap_or(jnum(0.0)), st.value("ctimeMs").unwrap_or(jnum(0.0))])
}

///|
fn entry_at(e : Json, i : Int) -> Json {
  match e {
    Array(a) if i < a.length() => a[i]
    _ => Json::null()
  }
}

///|
/// Whether two entries name the same content and mode.
fn same_content(a : Json?, b : Json?) -> Bool {
  match (a, b) {
    (Some(x), Some(y)) => entry_at(x, 0) == entry_at(y, 0) && entry_at(x, 1) == entry_at(y, 1)
    (None, None) => true
    _ => false
  }
}

///|
/// What the mirror has of the files it was given, now (as the station's TypeScript had it, `actual`): one a command changed is hashed again,
/// one it removed (or made something else) is no longer there; those in `verify` checked by content even where their
/// stat matches.
async fn Actors::actual(self : Actors, mirror : String, files : Map[String, Json], verify? : Map[String, Bool] = {}) -> Map[String, Json] raise {
  let out : Map[String, Json] = {}
  for path, e in files {
    let abs = self.rjoin([mirror, path])
    guard self.lstat(abs) is Some(st) else { continue }
    let same = !verify.contains(path) &&
      st.value("size") == Some(entry_at(e, 2)) &&
      st.value("mtimeMs") == Some(entry_at(e, 3)) &&
      st.value("ino") == Some(entry_at(e, 4)) &&
      st.value("ctimeMs") == Some(entry_at(e, 5))
    match kind_of_stat(st) {
      "link" =>
        out[path] = if entry_at(e, 1) == jstr(link_mode) && same {
          e
        } else {
          entry_of_stat(text_blob_id(self.read_link(abs)), link_mode, st)
        }
      "file" => {
        let mode = mode_of_bits(num_of(st.value("mode")).unwrap_or(0.0))
        out[path] = if entry_at(e, 1) == jstr(mode) && same {
          e
        } else {
          entry_of_stat(self.file_id(abs, num_of(st.value("size")).unwrap_or(0.0)), mode, st)
        }
      }
      _ => ()
    }
  }
  out
}

///|
/// sync.begin: what the mirror has now of what its manifest says, and the conflict base, written beside the sync
/// (actual.json, base.json); the manifest's version.
async fn Actors::sync_begin(self : Actors, manifest_path : String, mirror_root : String, syncing : String) -> Double raise {
  let manifest = self.read_manifest(manifest_path)
  let kept = files_of(manifest)
  let files = if manifest is None { {} } else { self.actual(mirror_root, kept) }
  let base = kept.copy()
  // Refresh the stat only where the content is still the source's: a changed file keeps the original content as its
  // conflict base.
  for path, current in files {
    if base.get(path) is Some(before) && same_content(Some(before), Some(current)) {
      base[path] = current
    }
  }
  self.write_json(self.rjoin([syncing, "actual.json"]), Json::object(files))
  self.write_json(self.rjoin([syncing, "base.json"]), Json::object(base))
  match manifest {
    Some(m) => num_of(m.value("version")).unwrap_or(0.0)
    None => 0.0
  }
}

///|
/// The manifest's entries as pages give them: [path, id, mode], by path.
fn listed_entries(files : Map[String, Json]) -> Array[Json] {
  let paths = files.keys().collect()
  paths.sort_by(@search.compare_units)
  paths.map(p => Json::array([jstr(p), entry_at(files[p], 0), entry_at(files[p], 1)]))
}

///|
/// A page of `all` from `after`: as many as page_bytes of UTF-8 JSON (including frame overhead), and where the next
/// starts (null at the end).
fn page_of(all : Array[Json], after : Int, budget? : Int = page_bytes) -> Json {
  let entries : Array[Json] = []
  let frame_base = bytes_len("{\"entries\":[],\"next\":}")
  let mut entries_bytes = 0
  let mut i = after
  while i < all.length() {
    let item_bytes = bytes_len(js_text(all[i]))
    let comma = if entries.length() > 0 { 1 } else { 0 }
    let next_bytes = bytes_len(if i + 1 < all.length() { (i + 1).to_string() } else { "null" })
    if frame_base + entries_bytes + comma + item_bytes + next_bytes > budget && entries.length() > 0 {
      break
    }
    entries.push(all[i])
    entries_bytes += comma + item_bytes
    i += 1
  }
  { "entries": Json::array(entries), "next": if i < all.length() { jnum(i.to_double()) } else { Json::null() } }
}

///|
/// Checks a plan's part as it comes: [path, id, mode] to have, paths to remove.
fn plan_part(request : Json) -> Json raise {
  let set = match field_of(request, "set") {
    Null => []
    Array(a) => a
    _ => raise refusal("bad plan")
  }
  let remove = match field_of(request, "remove") {
    Null => []
    Array(a) => a
    _ => raise refusal("bad plan")
  }
  for s in set {
    guard s is Array([String(_), String(id), String(mode), ..]) && is_blob_id(id) && (mode == file_mode || mode == exec_mode || mode == link_mode) else {
      raise refusal("bad plan")
    }
  }
  if !remove.iter().all(r => r is String(_)) {
    raise refusal("bad plan")
  }
  { "set": Json::array(set), "remove": Json::array(remove) }
}

///|
/// Removes the empty directories from `path`'s up to the mirror's.
async fn Actors::prune_empty(self : Actors, mirror : String, path : String) -> Unit {
  let mut d = self.rdirname(path)
  while d.length() > mirror.length() && d.has_prefix(mirror) {
    // (a folder that is not empty is not removed: fs.remove without `recursive`)
    match (try self.lstat(d) catch { _ => None }) {
      Some(st) if kind_of_stat(st) == "dir" => ()
      _ => return
    }
    try self.remove(d) catch { _ => return }
    d = self.rdirname(d)
  }
}

///|
/// Carries out a plan in the mirror (`name` in `work`, as the TypeScript's `apply` did): every new content made beside it first (in
/// `scratch`, from `blobs` or from a file of the mirror with the same id), then the files that left removed, then the
/// new ones renamed into place. `files` (what the mirror has) is updated as it goes, also when it stops part way.
async fn Actors::apply_plan(
  self : Actors,
  work : String,
  name : String,
  scratch : String,
  blobs : String,
  files : Map[String, Json],
  set : Array[(String, String, String)],
  remove : Array[String],
  removed_ok : Map[String, Bool],
) -> (Int, Int) raise {
  let mirror = self.file_path(work, name, true)
  self.mkdirs(mirror)
  self.mkdirs(scratch)
  let by_hash : Map[String, String] = {}
  for path, e in files {
    if entry_at(e, 0) is String(h) && entry_at(e, 1) is String(m) {
      by_hash[reuse_key(h, m)] = path
    }
  }
  let uses : Map[String, Int] = {}
  for s in set {
    uses[s.1] = uses.get(s.1).unwrap_or(0) + 1
  }
  let ready : Array[(String, String, String, String?)] = []
  for i, s in set {
    let (path, hash, mode) = s
    if files.get(path) is Some(now) && entry_at(now, 0) == jstr(hash) && (entry_at(now, 1) == jstr(link_mode)) == (mode == link_mode) {
      // The same content: a mode to set, if any.
      ready.push((path, hash, mode, None))
      continue
    }
    let temp = self.rjoin([scratch, i.to_string()])
    self.remove(temp)
    let blob = self.rjoin([blobs, hash])
    let has_blob = self.there(blob)
    let from = if has_blob { None } else { by_hash.get(reuse_key(hash, mode)) }
    if !has_blob && from is None {
      raise refusal("the content of \{path} was not sent")
    }
    if mode == link_mode {
      let target = match from {
        Some(f) => self.read_link(self.rjoin([mirror, f]))
        None => self.read_text(blob).unwrap_or("")
      }
      if !link_inside(path, target) {
        raise refusal("\{path} is a symbolic link leading out of the directory")
      }
      ignore(self.fs("fs.symlink", { "target": jstr(target), "path": jstr(temp) }))
    } else {
      let left = uses.get(hash).unwrap_or(1) - 1
      uses[hash] = left
      match from {
        None =>
          if left == 0 {
            self.rename(blob, temp)
          } else {
            ignore(self.fs("fs.copy", { "from": jstr(blob), "to": jstr(temp) }))
          }
        Some(f) => ignore(self.fs("fs.copy", { "from": jstr(self.rjoin([mirror, f])), "to": jstr(temp) }))
      }
      ignore(self.fs("fs.chmod", { "path": jstr(temp), "mode": jnum(if mode == exec_mode { 0o755.to_double() } else { 0o644.to_double() }) }))
    }
    ready.push((path, hash, mode, Some(temp)))
  }
  let mut removed = 0
  for path in remove {
    // (the link itself let go, never what it names; reject traversal / symlink parent escapes before checking `files`)
    let abs = try self.file_path(mirror, path, false, allow_leaf_link=true) catch {
      e => raise refusal("cannot remove \{path} on the target: \{FsError::of(e)}; clean the mirror or replace the symbolic link on the target")
    }
    let had_file = files.contains(path)
    let st = try self.lstat(abs) catch {
      e => {
        let msg = FsError::of(e)
        if is_enoent_error(msg) {
          None
        } else {
          raise refusal("cannot remove \{path} on the target: \{msg}; check permissions or clean the mirror")
        }
      }
    }
    match st {
      Some(s) if kind_of_stat(s) != "file" && kind_of_stat(s) != "link" => ()
      _ =>
        try self.remove(abs) catch {
          e => {
            let msg = FsError::of(e)
            if !is_enoent_error(msg) {
              raise refusal("cannot remove \{path} on the target: \{msg}; check permissions or clean the mirror")
            }
          }
        }
    }
    removed_ok[path] = true
    if had_file {
      files.remove(path)
      removed += 1
    }
    self.prune_empty(mirror, abs)
  }
  let mut written = 0
  for r in ready {
    let (path, hash, mode, temp) = r
    // A link synced before may be replaced (renamed over, the link itself) or kept as it is; never set a mode through.
    let abs = try self.file_path(mirror, path, true, allow_leaf_link=temp is Some(_) || mode == link_mode) catch {
      e => raise refusal("cannot write \{path} on the target: \{FsError::of(e)}")
    }
    match temp {
      None => {
        if mode != link_mode && entry_at(files[path], 1) != jstr(mode) {
          ignore(self.fs("fs.chmod", { "path": jstr(abs), "mode": jnum(if mode == exec_mode { 0o755.to_double() } else { 0o644.to_double() }) }))
        }
        guard self.lstat(abs) is Some(st) else { raise FsError("ENOENT: no such file or directory, lstat '\{abs}'") }
        files[path] = entry_of_stat(hash, mode, st)
      }
      Some(t) => {
        match self.lstat(abs) {
          Some(st) if kind_of_stat(st) == "dir" =>
            try self.remove(abs) catch { _ => raise refusal("cannot write \{path} on the target: a directory is there") }
          // (a link let go first, as a directory is: renaming over one is not alike on every system)
          Some(st) if kind_of_stat(st) == "link" =>
            try self.remove(abs) catch { e => raise refusal("cannot write \{path} on the target: \{FsError::of(e)}") }
          _ => ()
        }
        self.rename(t, abs)
        guard self.lstat(abs) is Some(st) else { raise FsError("ENOENT: no such file or directory, lstat '\{abs}'") }
        files[path] = entry_of_stat(hash, mode, st)
        written += 1
      }
    }
  }
  (written, removed)
}

///|
/// sync.commit, its last part (remote.ts `syncCommit` as it was): the plan checked against what the mirror has (a
/// task's output changed meanwhile is never overwritten) and carried out; the manifest written, with the submodules
/// the source named (`submodules_part`), whose checkouts the mirror no longer has a submodule for removed first.
async fn Actors::sync_commit(
  self : Actors,
  work : String,
  mirror : String,
  syncing : String,
  manifest_path : String,
  version0 : Json,
  dir : String,
  submodules : Array[(String, String, String)],
) -> Json raise {
  let manifest = self.read_manifest(manifest_path)
  let version = match manifest {
    Some(m) => num_of(m.value("version")).unwrap_or(0.0)
    None => 0.0
  }
  if Some(version) != num_of(Some(version0)) {
    raise refusal("the mirror changed while this sync went on; start again")
  }
  let set : Array[(String, String, String)] = []
  let remove : Array[String] = []
  for line in self.read_text(self.rjoin([syncing, "plan.jsonl"])).unwrap_or("").split("\n") {
    let line = line.to_string()
    if line == "" {
      continue
    }
    let p = @json.parse(line) catch { _ => raise refusal("bad plan") }
    match field_of(p, "set") {
      Array(a) =>
        for s in a {
          if s is Array([String(path), String(hash), String(mode), ..]) {
            set.push((path, hash, mode))
          }
        }
      _ => ()
    }
    match field_of(p, "remove") {
      Array(a) =>
        for r in a {
          if r is String(path) {
            remove.push(path)
          }
        }
      _ => ()
    }
  }
  let base = match self.read_json(self.rjoin([syncing, "base.json"])) {
    Object(b) => b.copy()
    _ => {}
  }
  let root = self.rjoin([work, mirror])
  // A submodule the source no longer has: its checkout goes (its files were never the manifest's), so that what is
  // synced in its place, if anything, finds nothing there.
  if self.there(root) {
    let kept : Map[String, Bool] = {}
    for s in submodules {
      kept[s.0] = true
    }
    for path in submodules_of_manifest(manifest) {
      if kept.contains(path) {
        continue
      }
      let abs = try self.file_path(root, path, false) catch { _ => continue }
      match (try self.lstat(abs) catch { _ => None }) {
        Some(st) if kind_of_stat(st) == "dir" => self.remove(abs, recursive=true)
        _ => ()
      }
    }
  }
  // Read again at commit: a task's output may have changed while the source sent its files.
  let verify : Map[String, Bool] = {}
  for s in set {
    verify[s.0] = true
  }
  for r in remove {
    verify[r] = true
  }
  let files = self.actual(root, base, verify~)
  let untracked : Map[String, Json] = {}
  if self.there(root) {
    for s in set {
      let path = s.0
      if base.contains(path) || files.contains(path) {
        continue
      }
      let conflict = "sync conflict at \{path}: an existing remote path would be overwritten"
      let abs = try self.file_path(root, path, false) catch { _ => raise refusal(conflict) }
      match self.lstat(abs) {
        Some(st) if kind_of_stat(st) != "file" => raise refusal(conflict)
        Some(_) => untracked[path] = Json::array([jstr(""), jstr(""), jnum(0.0), jnum(0.0), jnum(0.0)])
        None => ()
      }
    }
  }
  for path, e in self.actual(root, untracked) {
    files[path] = e
  }
  let safe_set : Array[(String, String, String)] = []
  let safe_remove : Array[String] = []
  for s in set {
    let (path, hash, mode) = s
    let before = base.get(path)
    let current = files.get(path)
    let wanted = Some(Json::array([jstr(hash), jstr(mode)]))
    // Old sources send a plan against the actual mirror: an unchanged source must not reset remote output.
    if same_content(before, wanted) && !same_content(before, current) {
      continue
    }
    if !same_content(before, current) && !same_content(current, wanted) {
      raise refusal("sync conflict at \{path}: source and remote both changed; preserve the remote result and reconcile the files")
    }
    safe_set.push(s)
  }
  for path in remove {
    if !base.contains(path) {
      continue
    }
    if files.contains(path) && !same_content(base.get(path), files.get(path)) {
      raise refusal("sync conflict at \{path}: the remote file changed before removal")
    }
    safe_remove.push(path)
  }
  let next_base = base.copy()
  let removed_ok : Map[String, Bool] = {}
  let finish = async fn() raise {
    for s in safe_set {
      if same_content(files.get(s.0), Some(Json::array([jstr(s.1), jstr(s.2)]))) {
        next_base[s.0] = files[s.0]
      }
    }
    for path in safe_remove {
      if removed_ok.contains(path) {
        next_base.remove(path)
      }
    }
    let m : Map[String, Json] = { "dir": jstr(dir), "name": jstr(mirror), "version": jnum(version + 1.0), "files": Json::object(next_base) }
    if submodules.length() > 0 {
      m["submodules"] = Json::array(submodules.map(s => Json::array([jstr(s.0), jstr(s.1), jstr(s.2)])))
    }
    self.write_whole(manifest_path, js_text(Json::object(m)))
  }
  let (written, removed) = try {
    self.apply_plan(work, mirror, self.rjoin([syncing, "scratch"]), self.rjoin([syncing, "blobs"]), files, safe_set, safe_remove, removed_ok)
  } catch {
    e => {
      finish()
      raise e
    }
  }
  finish()
  { "written": jnum(written.to_double()), "removed": jnum(removed.to_double()), "version": jnum(version + 1.0) }
}

///|
/// sync.changes: the synced files a finished task's command changed in its mirror (1000 at most).
async fn Actors::sync_changes(self : Actors, manifest_path : String, base : String) -> Json raise {
  let manifest = self.read_manifest(manifest_path)
  let kept = files_of(manifest)
  let now = if manifest is None { {} } else { self.actual(base, kept) }
  let changes : Array[Json] = []
  let mut more = false
  let paths = kept.keys().collect()
  paths.sort_by(@search.compare_units)
  for path in paths {
    let was = kept[path]
    let is_ = now.get(path)
    if is_ is Some(i) && same_content(Some(i), Some(was)) {
      continue
    }
    if changes.length() == 1000 {
      more = true
      break
    }
    let change : Map[String, Json] = {
      "path": jstr(path),
      "old": entry_at(was, 0),
      "mode": entry_at(was, 1),
      "hash": match is_ { Some(i) => entry_at(i, 0); None => Json::null() },
      "newMode": match is_ { Some(i) => entry_at(i, 1); None => Json::null() },
    }
    if is_ is Some(i) && entry_at(i, 1) == jstr(link_mode) {
      change["link"] = jstr(self.read_link(self.rjoin([base, path])))
    }
    changes.push(Json::object(change))
  }
  { "changes": Json::array(changes), "more": jbool(more) }
}

///|
/// sync.put: pieces sent (`index`: [id, size, offset, length] each) unpacked into `blobs`, each content in its own
/// file, complete when its last piece came and its id checked. Their packed bytes are in the file at `packed` (Node
/// landed them there), or base64 in `data` from a station from before. A piece that came already (a request asked
/// again) is skipped; how many pieces there were.
async fn Actors::put_blobs(self : Actors, blobs : String, index : Json, packed : String?, data : Json) -> Int raise {
  guard index is Array(index) && index.length() <= max_pieces else { raise refusal("bad pieces") }
  let pieces : Array[(String, Double, Double, Int)] = []
  let mut total = 0.0
  for p in index {
    guard p is Array([String(hash), size, offset, length, ..]) &&
      is_blob_id(hash) &&
      as_u64(size) is Some(size) &&
      as_u64(offset) is Some(offset) &&
      as_u64(length) is Some(length) else {
      raise refusal("bad piece")
    }
    if size > max_file || offset + length > size {
      raise refusal("bad piece")
    }
    total += length
    pieces.push((hash, size, offset, length.to_int()))
  }
  if total > max_raw.to_double() {
    raise refusal("too much in one request")
  }
  let unpack = async fn(args : Map[String, Json], bytes : Bytes?) -> Bytes raise {
    let (_, out) = try {
      match bytes {
        Some(b) => self.host.shell("zstd.unpack", Json::object(args), bytes=b)
        None => self.host.shell("zstd.unpack", Json::object(args))
      }
    } catch {
      e => raise refusal(FsError::of(e))
    }
    out.unwrap_or(b"")
  }
  let raw = match packed {
    Some(path) => unpack({ "path": jstr(path), "most": jnum(max_raw.to_double()) }, None)
    None => {
      // (STANDARD base64 as the Rust decoded it: padded, nothing else in it)
      let text = str_of(Some(data)).unwrap_or("")
      let bytes = if text.length() % 4 != 0 {
        raise refusal("Invalid input length or symbol")
      } else {
        @base64.decode(text) catch { _ => raise refusal("Invalid input length or symbol") }
      }
      unpack({ "most": jnum(max_raw.to_double()) }, Some(bytes))
    }
  }
  if raw.length().to_double() != total {
    raise refusal("pieces do not match their data")
  }
  self.mkdirs(blobs)
  let mut at = 0
  for p in pieces {
    let (hash, size, offset, length) = p
    let piece = raw[at:at + length].to_owned()
    at += length
    let done = self.rjoin([blobs, hash])
    if self.there(done) {
      continue
    }
    let part = "\{done}.part"
    let verify_and_commit = async fn() -> Unit raise {
      match self.lstat(part) {
        Some(st) if kind_of_stat(st) == "file" && num_of(st.value("size")).unwrap_or(-1.0) == size => {
          let got_id = self.file_id(part, size)
          if got_id != hash {
            self.remove(part)
            raise refusal("a content sent does not match its id")
          }
          self.rename(part, done)
        }
        Some(_) => {
          self.remove(part)
          raise refusal("a content sent does not match its id")
        }
        None => raise refusal("cannot verify staged blob on the target; check permissions or retry")
      }
    }
    let part_st = self.lstat(part)
    let has = match part_st {
      Some(st) => {
        if kind_of_stat(st) != "file" {
          self.remove(part)
          raise refusal("a content sent does not match its id")
        }
        let sz = num_of(st.value("size")).unwrap_or(0.0)
        if sz > size {
          self.remove(part)
          raise refusal("a content sent does not match its id")
        }
        if sz == size {
          verify_and_commit()
          continue
        }
        sz
      }
      None => 0.0
    }
    let end = offset + length.to_double()
    if end <= has && !(offset == 0.0 && has == 0.0) {
      continue
    }
    if offset != has {
      raise refusal("a content's pieces came out of order")
    }
    // (from its start a new file, else after what it has: openSync's "w" and "a")
    ignore(self.fs("fs.put", { "path": jstr(part), "offset": jnum(offset), "truncate": jbool(true), "nofollow": jbool(true) }, bytes=piece))
    if end == size {
      verify_and_commit()
    }
  }
  pieces.length()
}

///|
/// Whether `path` names a place inside the mirror for a submodule: relative, / between its parts, none of them empty,
/// `.`, `..` or `.git`, nothing a shell or Git would take otherwise.
fn submodule_path_ok(path : String) -> Bool {
  if path == "" || path.has_prefix("/") || path.has_prefix("-") {
    return false
  }
  for c in path {
    if c.to_int() < 0x20 || c == '\\' || c == ':' {
      return false
    }
  }
  path.split("/").map(p => p.to_string()).all(p => p != "" && p != "." && p != ".." && p != ".git")
}

///|
/// The submodules a sync's last part names (dirsync_source.mbt `submodules_of`): [path, commit, URL] each, checked; none
/// from a source from before.
fn submodules_part(request : Json) -> Array[(String, String, String)] raise {
  let out : Array[(String, String, String)] = []
  match field_of(request, "submodules") {
    Null => ()
    Array(a) =>
      for s in a {
        guard s is Array([String(path), String(id), String(url), ..]) &&
          submodule_path_ok(path) &&
          is_blob_id(id) &&
          url != "" &&
          !url.has_prefix("-") &&
          !url.iter().any(c => c.to_int() < 0x20) else {
          raise refusal("bad submodule")
        }
        out.push((path, id, url))
      }
    _ => raise refusal("bad submodule")
  }
  out
}

///|
/// The submodules a mirror's manifest keeps: path, commit, URL.
fn submodules_kept(manifest : Json?) -> Array[(String, String, String)] {
  let out : Array[(String, String, String)] = []
  guard manifest is Some(m) && field_of(m, "submodules") is Array(a) else { return out }
  for s in a {
    if s is Array([String(path), String(id), String(url), ..]) && submodule_path_ok(path) && is_blob_id(id) {
      out.push((path, id, url))
    }
  }
  out
}

///|
fn submodules_of_manifest(manifest : Json?) -> Array[String] {
  submodules_kept(manifest).map(s => s.0)
}

///|
/// A word for sh, as it is.
fn sh_word(s : String) -> String {
  "'" + s.replace_all(old="'", new="'\\''") + "'"
}

///|
/// Where this station may have a submodule's commits already, by its URL's last parts: its shared clones
/// (`<data>/repos/<owner>/<name>`, `<data>/repos/<name>`, as sessions keep them).
fn Actors::submodule_clones(self : Actors, url : String) -> Array[String] {
  let mut u = url
  while u.has_suffix("/") {
    u = u.view(end_offset=u.length() - 1).to_string()
  }
  if u.has_suffix(".git") {
    u = u.view(end_offset=u.length() - 4).to_string()
  }
  let parts = u.replace_all(old=":", new="/").split("/").map(p => p.to_string()).filter(p => p != "").collect()
  let ok = (p : String) => p != "." && p != ".." && !p.contains("\\")
  if parts.length() == 0 || !ok(parts[parts.length() - 1]) {
    return []
  }
  let name = parts[parts.length() - 1]
  let repos = self.rjoin([self.rdirname(self.remote.root), "repos"])
  let out : Array[String] = []
  if parts.length() >= 2 && ok(parts[parts.length() - 2]) {
    out.push(self.rjoin([repos, parts[parts.length() - 2], name]))
  }
  out.push(self.rjoin([repos, name]))
  out
}

///|
/// What checks out a submodule in the mirror, as a task's command's first lines (sh, in the mirror): its path, its
/// commit and URL, then the clones where it may be already. Nothing done where it is at that commit already (its
/// build output kept); else its commit fetched (only it, `--depth 1`) from a clone that has it, or from its URL, and
/// checked out over what is there. One that cannot be leaves the task running without it, said in its log.
let submodule_fn : String =
  #|sf_submodule() {
  #|  p=$1 id=$2 url=$3; shift 3
  #|  if [ -e "$p/.git" ] && [ "$(git -C "$p" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null)" = "$id" ]; then return 0; fi
  #|  { mkdir -p "$p" && { [ -e "$p/.git" ] || git -C "$p" init -q; }; } || { echo "still.fail: submodule $p could not be made here; the task runs without it" >&2; return 0; }
  #|  for r in "$@"; do
  #|    if [ -d "$r" ] && git -C "$r" cat-file -e "$id^{commit}" 2>/dev/null && git -C "$p" -c protocol.ext.allow=never -c uploadpack.allowAnySHA1InWant=true fetch -q --no-tags --depth 1 "$r" "$id" 2>/dev/null; then url=; break; fi
  #|  done
  #|  if [ -n "$url" ] && ! git -C "$p" -c protocol.ext.allow=never fetch -q --no-tags --depth 1 "$url" "$id"; then
  #|    echo "still.fail: submodule $p could not be fetched at $id from $url; the task runs without it" >&2; return 0
  #|  fi
  #|  if git -C "$p" -c advice.detachedHead=false checkout -q -f --detach "$id"; then echo "still.fail: submodule $p checked out at $id"
  #|  else echo "still.fail: submodule $p could not be checked out at $id; the task runs without it" >&2; fi
  #|}

///|
/// A task's command in a mirror with submodules (its manifest's): first their checkout (`submodule_fn`), then it as
/// it was. None where the mirror has none.
async fn Actors::with_submodules(self : Actors, manifest_path : String, command : String) -> String? raise {
  let kept = submodules_kept(self.read_manifest(manifest_path))
  if kept.length() == 0 {
    return None
  }
  // (in a subshell of their own: nothing they set is the command's)
  let lines = ["# still.fail: the mirror's Git submodules first (station_task dir)", "(", submodule_fn]
  for s in kept {
    let words = [sh_word(s.0), sh_word(s.1), sh_word(s.2)]
    words.append(self.submodule_clones(s.2).map(sh_word))
    lines.push("sf_submodule " + words.join(" "))
  }
  lines.push(")")
  lines.push(command)
  Some(lines.join("\n"))
}
