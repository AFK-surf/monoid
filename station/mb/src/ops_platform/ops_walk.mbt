// station/src/ops/walk.ts `walkBounded` and follow.ts `FollowedTree`'s scan: a walk of a tree the station does not
// own, breadth first, on its root's file system, no link followed (unless asked), bounded in entries, depth and time;
// and the directories of a tree its owner lets in, each watched.

///|
pub let walk_max_entries : Int = 50000

///|
pub let walk_max_depth : Int = 32

///|
pub let walk_max_duration_ms : Double = 15000.0

///|
/// walk.ts `WalkEntry`.
pub(all) struct WalkEntry {
  path : String
  rel : String
  name : String
  depth : Int
  directory : Bool
  symlink : Bool
  file : Bool
  /// Its lstat, where every entry is stated (`stat`).
  stats : Lstat?
  root : String
}

///|
pub fn WalkEntry::to_json(self : WalkEntry) -> Json {
  {
    "path": js(self.path),
    "rel": js(self.rel),
    "name": js(self.name),
    "depth": ji(self.depth),
    "directory": jb(self.directory),
    "symlink": jb(self.symlink),
    "file": jb(self.file),
    "size": match self.stats {
      Some(s) => jn(s.size)
      None => Json::null()
    },
    "root": js(self.root),
  }
}

///|
/// walk.ts `Visit`.
pub(all) enum Visit {
  Go
  Skip
  Stop
}

///|
/// walk.ts `WalkOptions`.
pub(all) struct WalkOptions {
  same_device : Bool
  max_entries : Int
  max_depth : Int
  max_duration_ms : Double
  now : () -> Double
  stat : Bool
  follow_root : Bool
  follow_links : Bool
  /// An error of the file system: its path and what failed (`lstat`, `readdir`, `stat`).
  on_error : (String, String) -> Unit
  on_crossed : (WalkEntry) -> Unit
  aborted : () -> Bool
}

///|
pub fn WalkOptions::default(now : () -> Double) -> WalkOptions {
  {
    same_device: true,
    max_entries: walk_max_entries,
    max_depth: walk_max_depth,
    max_duration_ms: walk_max_duration_ms,
    now,
    stat: false,
    follow_root: false,
    follow_links: false,
    on_error: (_, _) => (),
    on_crossed: _ => (),
    aborted: () => false,
  }
}

///|
/// walk.ts `WalkResult`.
pub(all) struct WalkResult {
  truncated : Bool
  reason : String?
  visited : Int
  crossed : Int
}

///|
pub fn WalkResult::to_json(self : WalkResult) -> Json {
  let m : Map[String, Json] = { "truncated": jb(self.truncated) }
  match self.reason {
    Some(r) => m["reason"] = js(r)
    None => ()
  }
  m["visited"] = ji(self.visited)
  m["crossed"] = ji(self.crossed)
  Json::object(m)
}

///|
priv struct Pending {
  path : String
  rel : String
  depth : Int
  root : String
  dev : Double
}

///|
/// What a path is, as lstat (or stat, links followed) says: its kind, device and identity (its real path, which a
/// directory has one of, where the walk would compare its device and inode).
priv struct Stated {
  kind : String
  dev : Double
  id : String
  lstat : Lstat?
}

///|
fn stated(fs : Fs, path : String, follow : Bool, want_lstat : Bool) -> Stated? raise {
  if follow {
    guard fs.kind(path) is Some(k) else { return None }
    let dev = fs.dev(path, follow=true).unwrap_or(0.0)
    let id = if k == "dir" { fs.realpath(path).unwrap_or(path) } else { path }
    Some({ kind: k, dev, id, lstat: if want_lstat { fs.lstat(path) } else { None } })
  } else {
    guard fs.lstat(path) is Some(l) else { return None }
    let dev = fs.dev(path).unwrap_or(0.0)
    let id = if l.kind == "dir" { fs.realpath(path).unwrap_or(path) } else { path }
    Some({ kind: l.kind, dev, id, lstat: Some(l) })
  }
}

///|
/// walk.ts `walkBounded`: `roots` walked in order, `visit` told each entry.
pub fn walk_bounded(
  fs : Fs,
  roots : Array[String],
  visit : (WalkEntry) -> Visit,
  o : WalkOptions,
) -> WalkResult raise {
  let until = (o.now)() + o.max_duration_ms
  let into : Array[String] = []
  let first = (s : Stated?) => match s {
    Some(st) if o.follow_links =>
      if into.contains(st.id) {
        false
      } else {
        into.push(st.id)
        true
      }
    _ => true
  }
  let mut visited = 0
  let mut crossed = 0
  let mut deeper = false
  let limit = () => if (o.aborted)() {
    Some("aborted")
  } else if visited >= o.max_entries {
    Some("entries")
  } else if (o.now)() > until {
    Some("duration")
  } else {
    None
  }
  let queue : Array[Pending] = []
  for root in roots {
    match limit() {
      Some(why) => return { truncated: true, reason: Some(why), visited, crossed }
      None => ()
    }
    let mut meta = match stated(fs, root, false, true) {
      Some(m) => m
      None => {
        (o.on_error)(root, "lstat")
        continue
      }
    }
    let link = meta.kind == "link"
    if link && o.follow_root {
      match stated(fs, root, true, false) {
        Some(m) => meta = { ..m, lstat: meta.lstat }
        None => {
          (o.on_error)(root, "lstat")
          continue
        }
      }
    }
    let entry : WalkEntry = {
      path: root,
      rel: "",
      name: posix_basename(root),
      depth: 0,
      directory: meta.kind == "dir",
      symlink: link && !o.follow_root,
      file: meta.kind == "file",
      stats: if o.stat { meta.lstat } else { None },
      root,
    }
    visited += 1
    let said = visit(entry)
    if said is Stop {
      return { truncated: true, reason: Some("stopped"), visited, crossed }
    }
    if !(said is Skip) && entry.directory && first(Some(meta)) {
      queue.push({ path: root, rel: "", depth: 0, root, dev: meta.dev })
    }
  }
  let mut head = 0
  while head < queue.length() {
    let dir = queue[head]
    head += 1
    match limit() {
      Some(why) => return { truncated: true, reason: Some(why), visited, crossed }
      None => ()
    }
    let listed = match fs.readdir(dir.path) {
      Some(l) => l
      None => {
        (o.on_error)(dir.path, "readdir")
        continue
      }
    }
    for d in listed {
      match limit() {
        Some(why) => return { truncated: true, reason: Some(why), visited, crossed }
        None => ()
      }
      let (name, listed_kind) = d
      let path = posix_join([dir.path, name])
      let depth = dir.depth + 1
      let mut stats : Stated? = None
      if o.stat || ((o.same_device || o.follow_links) && listed_kind == "dir") {
        match stated(fs, path, false, true) {
          Some(s) => stats = Some(s)
          None => {
            (o.on_error)(path, "lstat")
            continue
          }
        }
      }
      let symlink = match stats {
        Some(s) => s.kind == "link"
        None => listed_kind == "link"
      }
      let mut target = stats
      if o.follow_links && symlink {
        target = match stated(fs, path, true, false) {
          Some(t) => Some(t)
          None => {
            (o.on_error)(path, "stat")
            None
          }
        }
      }
      let followed = o.follow_links && symlink
      let directory = if followed {
        target is Some({ kind: "dir", .. })
      } else {
        match stats {
          Some(s) => s.kind == "dir"
          None => listed_kind == "dir"
        }
      }
      let file = if followed {
        target is Some({ kind: "file", .. })
      } else {
        match stats {
          Some(s) => s.kind == "file"
          None => listed_kind == "file"
        }
      }
      let entry : WalkEntry = {
        path,
        rel: if dir.rel == "" { name } else { dir.rel + "/" + name },
        name,
        depth,
        directory,
        symlink,
        file,
        stats: if o.stat {
          match stats {
            Some(s) => s.lstat
            None => None
          }
        } else {
          None
        },
        root: dir.root,
      }
      visited += 1
      let said = visit(entry)
      if said is Stop {
        return { truncated: true, reason: Some("stopped"), visited, crossed }
      }
      if said is Skip || !directory {
        continue
      }
      match target {
        Some(t) if o.same_device && t.dev != dir.dev => {
          crossed += 1
          (o.on_crossed)(entry)
          continue
        }
        _ => ()
      }
      if depth >= o.max_depth {
        deeper = true
        continue
      }
      if !first(target) {
        continue
      }
      queue.push({ path, rel: entry.rel, depth, root: dir.root, dev: dir.dev })
    }
  }
  if deeper {
    { truncated: true, reason: Some("depth"), visited, crossed }
  } else {
    { truncated: false, reason: None, visited, crossed }
  }
}

// ── follow.ts ────────────────────────────────────────────────────────────────────────────────────────────────────

///|
/// follow.ts `Scanned`.
pub(all) struct Scanned {
  failed : String?
  over : Bool
}

///|
/// follow.ts `FollowedTree`: the directories let in, each watched (`watch`: made, or the error code it failed with).
pub struct FollowedTree {
  root : String
  into : (String) -> Bool
  most : Int
  watch : (String) -> String?
  watches : Array[String]
  mut closed : Bool
}

///|
pub fn FollowedTree::new(
  root : String,
  into : (String) -> Bool,
  most : Int,
  watch : (String) -> String?,
) -> FollowedTree {
  { root, into, most, watch, watches: [], closed: false }
}

///|
/// follow.ts `scan`: the directories let in found again, those new watched, those gone let go.
pub fn FollowedTree::scan(self : FollowedTree, fs : Fs) -> Scanned raise {
  let found : Array[String] = []
  let mut failed : String? = None
  let mut over = false
  fn walk(rel : String) -> Unit raise {
    if self.closed || failed is Some(_) {
      return
    }
    if found.length() >= self.most {
      over = true
      return
    }
    found.push(rel)
    if !self.watches.contains(rel) {
      let at = if rel == "" { self.root } else { posix_join([self.root, rel]) }
      match (self.watch)(at) {
        None => self.watches.push(rel)
        Some(code) => {
          if code != "ENOENT" && code != "ENOTDIR" {
            failed = Some(code)
          }
          return
        }
      }
    }
    let entries = match fs.readdir(if rel == "" { self.root } else { posix_join([self.root, rel]) }) {
      Some(e) => e
      None => return
    }
    for e in entries {
      let sub_rel = if rel == "" { e.0 } else { rel + "/" + e.0 }
      if e.1 == "dir" && (self.into)(sub_rel) {
        walk(sub_rel)
      }
    }
  }

  walk("")
  if failed is None && !self.closed {
    let kept = self.watches.filter(w => found.contains(w))
    self.watches.clear()
    self.watches.push_iter(kept.iter())
  }
  { failed, over }
}

///|
/// follow.ts `close`: every watch let go.
pub fn FollowedTree::close(self : FollowedTree) -> Unit {
  self.closed = true
  self.watches.clear()
}

///|
/// follow.ts's watch callback: what changed, relative to the root, `name` told by the watch of `rel`.
pub fn followed_change(rel : String, name : String?) -> String {
  match name {
    None => rel
    Some(n) => if rel == "" { n } else { rel + "/" + n }
  }
}
