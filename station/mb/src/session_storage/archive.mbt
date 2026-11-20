// Cold storage for owned session workspaces and runtime transcripts (station/src/sessions/archive.ts, the Rust
// station's archive.rs): the same files byte for byte in format, the same temporaries (`.writing`, `.restoring`,
// `workspace.retiring`, `workspace.restored-old`), the same `archive.lock` and `<file>.jsonl.archive-lock`, the same
// `workspace-locks.json` and git worktree `locked` files with the same marker. The caller holds the room's lock and has
// stopped its actor; originals are removed only after a complete, checksummed archive has been read back. The bytes are
// station/packed's and the shell's (`zstd.*`, `tar.*`), asked here in this program.

///|
/// Path::with_extension: the file name's extension (after its last dot, not a leading one) replaced, or added.
pub fn Files::with_extension(self : Files, path : String, ext : String) -> String {
  let name = self.basename(path)
  let stem = match name.rev_find(".") {
    Some(dot) if dot > 0 => cut(name, 0, end=dot)
    _ => name
  }
  self.join([self.dirname(path), if ext == "" { stem } else { "\{stem}.\{ext}" }])
}

///|
/// Path::extension.
fn Files::extension(self : Files, path : String) -> String? {
  let name = self.basename(path)
  match name.rev_find(".") {
    Some(dot) if dot > 0 => Some(cut(name, dot + 1))
    _ => None
  }
}

///|
pub fn Files::workspace_archive(self : Files, room : String) -> String {
  self.join([room, "workspace.tar.zst"])
}

///|
/// Where a file is once put away.
pub fn packed_path(path : String) -> String {
  "\{path}.zst"
}

///|
/// A room's lock (`archive.lock` in it).
pub async fn Files::lock(self : Files, room : String) -> () -> Unit {
  self.file_lock(self.join([room, "archive.lock"]))
}

///|
/// `f` run under a room's lock.
pub async fn[T] Files::with_lock(self : Files, room : String, f : async () -> T) -> T {
  let release = self.lock(room)
  let out = f() catch {
    e => {
      release()
      raise e
    }
  }
  release()
  out
}

///|
/// `rm -r` that also takes directories their owner cannot write to: refused once, everything under `path` is given its
/// owner's write (and a directory's read and search) and it goes.
pub async fn Files::remove_tree(self : Files, path : String, force? : Bool = false) -> Unit {
  self.rm(path, recursive=true, force~) catch {
    e => {
      let code = code_of(e)
      if code != "EACCES" && code != "EPERM" {
        raise e
      }
      self.owner_writable(path)
      self.rm(path, recursive=true, force~)
    }
  }
}

///|
async fn Files::owner_writable(self : Files, path : String) -> Unit {
  guard self.lstat(path) is Some(there) else { return }
  if there.kind == "link" {
    return
  }
  let dir = there.kind == "dir"
  let need = if dir { 0o700 } else { 0o200 }
  if (there.mode & need) != need {
    self.chmod(path, (there.mode | need) & 0o7777) catch {
      e => if code_of(e) != "ENOENT" { raise e }
    }
  }
  if !dir {
    return
  }
  for name in self.entries(path) {
    self.owner_writable(self.join([path, name]))
  }
}

// ── transcripts ────────────────────────────────────────────────────────────────────────────────────────────────────

///|
pub async fn Files::pack_file(self : Files, path : String) -> Unit {
  self.pack_file_if(path, () => true)
}

///|
/// A transcript compressed in place, found as <original>.zst. A crash is retried safely: an original still there wins.
pub async fn Files::pack_file_if(self : Files, path : String, ready : async () -> Bool) -> Unit {
  let release = self.file_lock(self.with_extension(path, "jsonl.archive-lock"))
  defer release()
  if !(self.lkind(path) is Some("file")) {
    // Only the copy left: read through whole, its checksums verified.
    if self.there(packed_path(path)) {
      ignore(self.packed("check", [("path", js(packed_path(path)))]))
    }
    return
  }
  let dest = packed_path(path)
  let temp = self.with_extension(dest, "zst.writing")
  ensure(async fn() {
    ignore(self.packed("pack", [("path", js(path)), ("temp", js(temp))]))
    if !ready() {
      return
    }
    self.rename(temp, dest)
    self.unlink(path)
  }, async fn() { self.gone(temp) })
}

///|
/// A transcript put away before it was in segments put away again in segments: whether it was.
pub async fn Files::segment_file(self : Files, path : String) -> Bool {
  let release = self.file_lock(self.with_extension(path, "jsonl.archive-lock"))
  defer release()
  let source = packed_path(path)
  if self.there(path) || !self.there(source) {
    return false
  }
  let temp = self.with_extension(source, "zst.writing")
  ensure(async fn() {
    let said = self.packed("segment", [("path", js(path)), ("source", js(source)), ("temp", js(temp))])
    if !(get(said, "segmented") is Some(True)) {
      return false
    }
    self.rename(temp, source)
    true
  }, async fn() { self.gone(temp) })
}

///|
pub async fn Files::restore_file(self : Files, path : String) -> Unit {
  let release = self.file_lock(self.with_extension(path, "jsonl.archive-lock"))
  defer release()
  let source = packed_path(path)
  if !self.there(source) || self.there(path) {
    return
  }
  let temp = self.with_extension(path, "jsonl.restoring")
  ensure(async fn() {
    ignore(self.packed("restore", [("source", js(source)), ("temp", js(temp))]))
    self.rename(temp, path)
    self.unlink(source)
  }, async fn() { self.gone(temp) })
}

///|
/// ops/walk.ts's bounds on a walk of a tree the station does not own.
let walk_max_entries = 50_000

///|
let walk_max_depth = 32

///|
let walk_max_ms = 15_000L

///|
/// A directory's device (`fs.scan`): a walk stays on its root's file system.
async fn Files::dev_of(self : Files, path : String) -> Double? {
  match items(Some(self.sh("fs.scan", jo([("paths", ja([js(path)]))])))).get(0) {
    Some(Object(_) as v) => num(v, "dev")
    _ => None
  }
}

///|
/// Logical JSONL names under `dir` (those put away too), each once, walked as ops/walk.ts `walkBounded` walks: breadth
/// first, no link followed, on its root's file system, at most so many entries, so deep and so long; a path gone
/// meanwhile passed over, any other failure raised.
pub async fn Files::jsonl_files(self : Files, dir : String, out : Array[String]) -> Unit {
  let seen = Set::from_array(out)
  let until = @host.now() + walk_max_ms
  let gone = (e : Error) => if code_of(e) != "ENOENT" { raise e }
  guard self.lkind(dir) is Some(root_kind) else { return }
  let mut visited = 1
  if root_kind != "dir" {
    return
  }
  let root_dev = self.dev_of(dir)
  let queue = [(dir, 0)]
  let mut head = 0
  while head < queue.length() {
    let (at, depth) = queue[head]
    head += 1
    if visited >= walk_max_entries || @host.now() > until {
      return
    }
    let listed = match self.sh("fs.readdir", jo([("path", js(at)), ("types", jb(true))])) {
      Array(xs) => xs
      _ => {
        if self.lkind(at) is Some(_) {
          gone(fs_failed("EACCES", "scandir", at))
        }
        continue
      }
    }
    for entry in listed {
      if visited >= walk_max_entries || @host.now() > until {
        return
      }
      guard entry is Array([String(name), String(kind)]) else { continue }
      let path = self.join([at, name])
      visited += 1
      if kind == "file" {
        let logical = if self.extension(path) == Some("zst") { self.with_extension(path, "") } else { path }
        if self.extension(logical) == Some("jsonl") && !seen.contains(logical) {
          seen.add(logical)
          out.push(logical)
        }
      }
      if kind != "dir" {
        continue
      }
      if self.dev_of(path) != root_dev {
        continue
      }
      if depth + 1 >= walk_max_depth {
        continue
      }
      queue.push((path, depth + 1))
    }
  }
}

// ── git worktrees ──────────────────────────────────────────────────────────────────────────────────────────────────

///|
async fn Files::lock_worktrees(self : Files, dir : String, marker : String, locks : Array[String]) -> Unit {
  for entry in self.readdir_types(dir) {
    let (name, kind) = entry
    let path = self.join([dir, name])
    if name == ".git" {
      if kind != "file" {
        continue
      }
      let said = self.read_text(path).unwrap_or("").trim().to_string()
      guard said.strip_prefix("gitdir: ") is Some(rest) else { continue }
      let named = rest.to_string()
      let resolved = if @nodepath.is_absolute(self.sep, named) { self.join([named]) } else { self.join([dir, named]) }
      // Its repository has no record of it any more: nothing to lock.
      guard self.realpath(resolved) is Some(gitdir) else { continue }
      let locked = self.join([gitdir, "locked"])
      let made = try {
        self.write_text(locked, marker, exclusive=true, sync=true)
        true
      } catch {
        e => {
          if code_of(e) != "EEXIST" && self.lkind(locked) is None {
            raise e
          }
          false
        }
      }
      if made {
        locks.push(locked)
      } else if self.read_text(locked) == Some(marker) && !locks.contains(locked) {
        locks.push(locked)
      }
    } else if kind == "dir" {
      self.lock_worktrees(path, marker, locks)
    }
  }
}

///|
fn marker_of(room : String) -> String {
  "still.fail archived workspace: \{room}\n"
}

///|
fn strings_in(text : String?) -> Array[String] {
  match text {
    Some(t) =>
      (try @json.parse(t) catch { _ => Json::null() } noraise { v => v })
      |> fn(v) { items(Some(v)).filter_map(x => if x is String(s) { Some(s) } else { None }) }
    None => []
  }
}

///|
pub async fn Files::unlock_worktrees(self : Files, room : String) -> Unit {
  let path = self.join([room, "workspace-locks.json"])
  if !self.there(path) {
    return
  }
  for locked in strings_in(self.read_text(path)) {
    if self.read_text(locked) == Some(marker_of(room)) {
      self.unlink(locked)
    }
  }
  self.unlink(path)
}

///|
/// Collects worktree registration directories (`<common>/worktrees/<name>`) owned by `room`:
/// from `.git` files under `room` and from `workspace-locks.json` for packed rooms.
pub async fn Files::collect_worktree_registrations(self : Files, room : String) -> Array[String] {
  let found : Array[String] = []
  let add = async fn(candidate : String) {
    guard self.realpath(candidate) is Some(resolved) else { return }
    if self.basename(self.dirname(resolved)) != "worktrees" {
      return
    }
    if !found.contains(resolved) {
      found.push(resolved)
    }
  }
  let visited = Ref(0)
  async fn walk(dir : String, depth : Int) -> Unit {
    if depth > 64 || visited.val >= 200_000 {
      return
    }
    let entries = self.readdir_types(dir) catch { _ => return }
    for entry in entries {
      visited.val += 1
      if visited.val >= 200_000 {
        return
      }
      let (name, kind) = entry
      let path = self.join([dir, name])
      if name == ".git" && kind == "file" {
        let said = self.read_text(path).unwrap_or("").trim().to_owned()
        if said.strip_prefix("gitdir: ") is Some(rest) {
          let named = rest.to_owned()
          let resolved = if @nodepath.is_absolute(self.sep, named) { self.join([named]) } else { self.join([dir, named]) }
          add(resolved)
        }
      } else if kind == "dir" {
        walk(path, depth + 1)
      }
    }
  }
  walk(room, 0)
  let locks_path = self.join([room, "workspace-locks.json"])
  if self.there(locks_path) {
    for locked in strings_in(self.read_text(locks_path)) {
      if locked != "" {
        add(self.dirname(locked))
      }
    }
  }
  found
}

///|
/// Removes only the exact worktree registration directories in `admin_dirs` that belong to one of `room_paths`,
/// whose target `.git` file no longer exists, and that have no `locked` file remaining.
pub async fn Files::remove_worktree_registrations(
  self : Files,
  admin_dirs : Array[String],
  room_paths : Array[String],
) -> Array[String] {
  let rooms = room_paths.map(r => @nodepath.join(self.sep, [r]))
  let removed : Array[String] = []
  for admin_dir in admin_dirs {
    if self.basename(self.dirname(admin_dir)) != "worktrees" {
      continue
    }
    if self.lkind(admin_dir) != Some("dir") {
      continue
    }
    if self.lkind(self.join([admin_dir, "locked"])) is Some(_) {
      continue
    }
    let raw_target = self.read_text(self.join([admin_dir, "gitdir"])).unwrap_or("").trim().to_owned()
    if raw_target == "" || !@nodepath.is_absolute(self.sep, raw_target) {
      continue
    }
    let target = @nodepath.join(self.sep, [raw_target])
    let in_room = rooms.iter().any(r => target != r && self.within(target, r))
    if !in_room {
      continue
    }
    if self.lkind(target) is Some(_) {
      continue
    }
    try {
      self.remove_tree(admin_dir, force=true)
      removed.push(admin_dir)
    } catch {
      _ => ()
    }
  }
  removed
}

// ── workspaces ─────────────────────────────────────────────────────────────────────────────────────────────────────

///|
pub async fn Files::pack_workspace(self : Files, room : String) -> Unit {
  self.pack_workspace_if(room, () => true)
}

///|
pub async fn Files::pack_workspace_if(self : Files, room : String, ready : async () -> Bool) -> Unit {
  let archive = self.workspace_archive(room)
  if self.there(archive) {
    return
  }
  let workspace = self.join([room, "workspace"])
  if !self.is_dir(workspace) {
    return
  }
  let temp = self.join([room, "workspace.tar.zst.writing"])
  ensure(async fn() {
    let locks_path = self.join([room, "workspace-locks.json"])
    let locks = if self.there(locks_path) { strings_in(self.read_text(locks_path)) } else { [] }
    // Keep registered worktrees out of `git worktree prune` while their .git files are inside the archive.
    let mut locked : Error? = None
    self.lock_worktrees(workspace, marker_of(room), locks) catch {
      e => locked = Some(e)
    }
    self.write_text(locks_path, ja(locks.map(x => js(x))).stringify(), sync=true)
    if locked is Some(e) {
      raise e
    }
    ignore(self.packed("workspace.pack", [("dir", js(workspace)), ("out", js(temp))]))
    if !ready() {
      self.unlock_worktrees(room)
      return
    }
    self.rename(temp, archive)
    let retiring = self.join([room, "workspace.retiring"])
    if self.there(retiring) {
      raise failed("an earlier workspace retirement needs restoration")
    }
    self.rename(workspace, retiring)
    self.mkdir(workspace)
    match self.lstat(retiring) {
      Some(s) => self.chmod(workspace, s.mode & 0o7777)
      None => ()
    }
    self.remove_tree(retiring)
  }, async fn() { self.gone(temp) })
}

///|
/// Files created since the snapshot copied into the restored tree (archive.ts `overlay`).
async fn Files::overlay(self : Files, source : String, dest : String, refused : Map[String, String]) -> Unit {
  let mode = match self.lstat(dest) {
    Some(s) => s.mode & 0o7777
    None => 0o755
  }
  let opened = (mode & 0o700) != 0o700
  if opened {
    self.chmod(dest, mode | 0o700)
  }
  ensure(async fn() {
    for entry in self.readdir_types(source) {
      let (name, kind) = entry
      let from = self.join([source, name])
      let into = self.join([dest, name])
      let there = self.lkind(into)
      refused.remove(into)
      if kind == "dir" {
        if there is Some(k) && k != "dir" {
          raise failed("restore path conflict: \{into}")
        }
        self.mkdirs(into)
        self.overlay(from, into, refused)
      } else {
        if there is Some("dir") {
          raise failed("restore path conflict: \{into}")
        }
        if there is Some(_) {
          self.unlink(into)
        }
        if kind == "link" {
          let target = self.readlink(from).unwrap_or("")
          ignore(self.link(target, into))
        } else if kind == "file" {
          self.copy(from, into)
        } else {
          raise failed("cannot restore special file \{from}")
        }
      }
    }
  }, async fn() { if opened { self.chmod(dest, mode) } })
}

///|
pub async fn Files::restore_workspace(self : Files, room : String) -> Unit {
  let archive = self.workspace_archive(room)
  if !self.there(archive) {
    return self.unlock_worktrees(room)
  }
  let stage = self.join([room, "workspace.restoring"])
  if self.there(stage) {
    self.remove_tree(stage)
  }
  self.mkdir(stage)
  self.chmod(stage, 0o700)
  let refused : Map[String, String] = {}
  let made = self.packed("workspace.unpack", [("path", js(archive)), ("dest", js(stage))]) catch {
    e => raise failed("restoring the archived workspace: \{message_of(e)}")
  }
  for pair in items(get(made, "refused")) {
    if pair is Array([String(p), String(t)]) {
      refused[p] = t
    }
  }
  let workspace = self.join([room, "workspace"])
  let retiring = self.join([room, "workspace.retiring"])
  let old = self.join([room, "workspace.restored-old"])
  for live in [retiring, old, workspace] {
    if self.is_dir(live) {
      self.overlay(live, stage, refused)
    }
  }
  if self.there(old) {
    self.remove_tree(old)
  }
  if self.there(workspace) {
    self.rename(workspace, old)
  }
  self.rename(stage, workspace)
  for path, target in refused {
    let rel = if path.has_prefix(stage + self.sep) { cut(path, stage.length() + 1) } else { path }
    let at = self.join([workspace, rel])
    if self.lkind(at) is None {
      ignore(self.link(target, at)) catch { _ => () }
    }
  }
  if self.there(retiring) {
    self.remove_tree(retiring)
  }
  if self.there(old) {
    self.remove_tree(old)
  }
  self.unlink(archive)
  self.readings_gone(room)
  self.unlock_worktrees(room)
}

///|
/// What an archived workspace keeps once archived long enough: the files sent in its chat (`uploads/`), out of its
/// archive; the rest removed. The caller holds the room's lock.
pub async fn Files::empty_workspace(self : Files, room : String) -> Unit {
  let workspace = self.join([room, "workspace"])
  let archive = self.workspace_archive(room)
  let raw_room = @nodepath.join(self.sep, [room])
  let real_room = self.realpath(room).unwrap_or(raw_room)
  let worktrees = self.collect_worktree_registrations(room)
  self.mkdirs(workspace)
  if self.there(archive) {
    let stage = self.join([room, "workspace.emptying"])
    if self.there(stage) {
      self.remove_tree(stage)
    }
    self.mkdir(stage)
    self.chmod(stage, 0o700)
    ignore(self.packed("workspace.unpack", [("path", js(archive)), ("dest", js(stage)), ("prefix", js("uploads"))]))
    self.take_uploads(stage, workspace)
    self.unlink(archive)
    self.remove_tree(stage)
  }
  for left in ["workspace.retiring", "workspace.restored-old", "workspace.restoring"] {
    if !self.is_dir(self.join([room, left])) {
      continue
    }
    self.take_uploads(self.join([room, left]), workspace)
    self.remove_tree(self.join([room, left]))
  }
  for entry in self.readdir_strict(workspace) {
    if entry != "uploads" {
      self.remove_tree(self.join([workspace, entry]), force=true)
    }
  }
  self.readings_gone(room)
  self.unlock_worktrees(room)
  let room_paths = if raw_room == real_room { [real_room] } else { [real_room, raw_room] }
  ignore(self.remove_worktree_registrations(worktrees, room_paths))
}

///|
async fn Files::take_uploads(self : Files, from : String, workspace : String) -> Unit {
  if !self.is_dir(self.join([from, "uploads"])) {
    return
  }
  let into = self.join([workspace, "uploads"])
  self.mkdirs(into)
  for entry in self.readdir_strict(self.join([from, "uploads"])) {
    if self.lkind(self.join([into, entry])) is None {
      self.rename(self.join([from, "uploads", entry]), self.join([into, entry]))
    }
  }
}

///|
/// Whether an archived workspace holds anything `empty_workspace` would remove.
pub async fn Files::holds_more(self : Files, room : String) -> Bool {
  if self.there(self.workspace_archive(room)) {
    return true
  }
  self.entries(self.join([room, "workspace"])).iter().any(name => name != "uploads")
}

///|
/// An archived attachment read from the tar stream: `relative` its path in the workspace.
pub async fn Files::workspace_file(self : Files, room : String, relative : String, reads : Ref[Int]) -> Bytes? {
  let archive = self.workspace_archive(room)
  if !self.there(archive) {
    return None
  }
  let wanted : Array[String] = []
  for p in relative.split(self.sep) {
    if p != "" && p != "." {
      wanted.push(p.to_string())
    }
  }
  reads.val += 1
  let out = "\{archive}.reading-\{reads.val}"
  ensure(async fn() {
    let said = self.packed("workspace.file", [("path", js(archive)), ("wanted", ja(wanted.map(x => js(x)))), ("out", js(out))])
    if get(said, "found") is Some(True) {
      self.read_bytes(out)
    } else {
      None
    }
  }, async fn() { self.gone(out) })
}

///|
async fn Files::readings_gone(self : Files, room : String) -> Unit {
  for name in self.readdir_strict(room) {
    if name.has_prefix("workspace.tar.zst.reading-") {
      self.rm(self.join([room, name]), force=true)
    }
  }
}
