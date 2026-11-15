// A source session's directory mirrored on this station for its remote tasks (station/src/jobs/dirsync.ts, whose head
// says how a sync goes): the target's side here, what the mirror has and how a plan is carried out in it. Every file
// operation is the shell's (off this program's thread); the bytes of the contents sent stay Node's (`putBlobs`).

///|
let file_mode : String = "100644"

///|
let exec_mode : String = "100755"

///|
let link_mode : String = "120000"

///|
/// A page of a manifest or a plan, as JSON, at most about this much.
let page_bytes : Int = 512 * 1024

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
/// Whether a link at `path` (relative, / between parts) naming `target` stays inside the directory (dirsync.ts
/// `linkInside`).
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
/// What the mirror has of the files it was given, now (dirsync.ts `actual`): one a command changed is hashed again,
/// one it removed (or made something else) is no longer there; those in `verify` checked by content even where their
/// stat matches.
async fn Actors::actual(self : Actors, mirror : String, files : Map[String, Json], verify? : Map[String, Bool] = {}) -> Map[String, Json] raise {
  let out : Map[String, Json] = {}
  for path, e in files {
    let abs = rjoin([mirror, path])
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
  self.write_json(rjoin([syncing, "actual.json"]), Json::object(files))
  self.write_json(rjoin([syncing, "base.json"]), Json::object(base))
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
/// A page of `all` from `after`: as many as about page_bytes of JSON, and where the next starts (null at the end).
fn page_of(all : Array[Json], after : Int) -> Json {
  let entries : Array[Json] = []
  let mut size = 0
  let mut i = after
  while i < all.length() {
    let n = bytes_len(js_text(all[i])) + 1
    if size + n > page_bytes && entries.length() > 0 {
      break
    }
    entries.push(all[i])
    size += n
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
  let mut d = rdirname(path)
  while d.length() > mirror.length() && d.has_prefix(mirror) {
    // (a folder that is not empty is not removed: fs.remove without `recursive`)
    match (try self.lstat(d) catch { _ => None }) {
      Some(st) if kind_of_stat(st) == "dir" => ()
      _ => return
    }
    try self.remove(d) catch { _ => return }
    d = rdirname(d)
  }
}

///|
/// Carries out a plan in the mirror (`name` in `work`, dirsync.ts `apply`): every new content made beside it first (in
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
) -> (Int, Int) raise {
  let mirror = self.file_path(work, name, true)
  self.mkdirs(mirror)
  self.mkdirs(scratch)
  let by_hash : Map[String, String] = {}
  for path, e in files {
    if entry_at(e, 0) is String(h) {
      by_hash[h] = path
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
    let temp = rjoin([scratch, i.to_string()])
    self.remove(temp)
    let blob = rjoin([blobs, hash])
    let has_blob = self.there(blob)
    let from = if has_blob { None } else { by_hash.get(hash) }
    if !has_blob && from is None {
      raise refusal("the content of \{path} was not sent")
    }
    if mode == link_mode {
      let target = match from {
        Some(f) => self.read_link(rjoin([mirror, f]))
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
        Some(f) => ignore(self.fs("fs.copy", { "from": jstr(rjoin([mirror, f])), "to": jstr(temp) }))
      }
      ignore(self.fs("fs.chmod", { "path": jstr(temp), "mode": jnum(if mode == exec_mode { 0o755.to_double() } else { 0o644.to_double() }) }))
    }
    ready.push((path, hash, mode, Some(temp)))
  }
  let mut removed = 0
  for path in remove {
    if !files.contains(path) {
      continue
    }
    let abs = try {
      self.file_path(mirror, path, false)
    } catch {
      _ => {
        files.remove(path)
        continue
      }
    }
    match (try self.lstat(abs) catch { _ => None }) {
      Some(st) if kind_of_stat(st) == "file" || kind_of_stat(st) == "link" => try self.remove(abs) catch { _ => () }
      _ => ()
    }
    files.remove(path)
    removed += 1
    self.prune_empty(mirror, abs)
  }
  let mut written = 0
  for r in ready {
    let (path, hash, mode, temp) = r
    let abs = try self.file_path(mirror, path, true) catch {
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
/// task's output changed meanwhile is never overwritten) and carried out; the manifest written.
async fn Actors::sync_commit(self : Actors, work : String, mirror : String, syncing : String, manifest_path : String, version0 : Json, dir : String) -> Json raise {
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
  for line in self.read_text(rjoin([syncing, "plan.jsonl"])).unwrap_or("").split("\n") {
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
  let base = match self.read_json(rjoin([syncing, "base.json"])) {
    Object(b) => b.copy()
    _ => {}
  }
  let root = rjoin([work, mirror])
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
    if files.contains(path) && !same_content(base.get(path), files.get(path)) {
      raise refusal("sync conflict at \{path}: the remote file changed before removal")
    }
    safe_remove.push(path)
  }
  let next_base = base.copy()
  let finish = async fn() raise {
    for s in safe_set {
      if same_content(files.get(s.0), Some(Json::array([jstr(s.1), jstr(s.2)]))) {
        next_base[s.0] = files[s.0]
      }
    }
    for path in safe_remove {
      if !files.contains(path) {
        next_base.remove(path)
      }
    }
    let m : Json = { "dir": jstr(dir), "name": jstr(mirror), "version": jnum(version + 1.0), "files": Json::object(next_base) }
    self.write_whole(manifest_path, js_text(m))
  }
  let (written, removed) = try {
    self.apply_plan(work, mirror, rjoin([syncing, "scratch"]), rjoin([syncing, "blobs"]), files, safe_set, safe_remove)
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
      change["link"] = jstr(self.read_link(rjoin([base, path])))
    }
    changes.push(Json::object(change))
  }
  { "changes": Json::array(changes), "more": jbool(more) }
}
