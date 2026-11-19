// What goes along with a workspace's chats (carry.ts), where a file of it lies on the station it goes to (restore.ts),
// and the few words of other parts these say (connects/remote.ts, jobs/jobs.ts). The gathering, the placing and the
// preview are station/replica's (carry.mbt), in this program.

///|
/// `path` as it is on this station: under `to` where it was under `from` (restore.ts `moved`).
pub fn moved(fs : Fs, path : String, from : String, to : String) -> String {
  if from == "" || from == to {
    return path
  }
  let f = if from.has_suffix(fs.sep) { from.unsafe_substring(start=0, end=from.length() - 1) } else { from }
  if path == f {
    return to
  }
  if path.has_prefix(f + fs.sep) || path.has_prefix(f + "/") {
    fs.join([to, path.unsafe_substring(start=f.length() + 1, end=path.length())])
  } else {
    path
  }
}

///|
/// read/transcript.ts `claudeProject`: each character but an ASCII letter or digit a dash; None past 200.
pub fn claude_project(cwd : String) -> String? {
  let out = StringBuilder::new()
  for i in 0..<cwd.length() {
    let c = cwd.unsafe_charcode_at(i)
    if (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') {
      out.write_char(c.unsafe_to_char())
    } else {
      out.write_char('-')
    }
  }
  let name = out.to_string()
  if name.length() <= 200 {
    Some(name)
  } else {
    None
  }
}

///|
/// Where a file of a chat carried from the station whose data directory is `from` lies here (restore.ts `carriedTo`).
pub fn carried_to(fs : Fs, path : String, from : String, to : String, room : String?) -> String {
  let at = moved(fs, path, from, to)
  let project = match room {
    Some(r) => claude_project(r)
    None => None
  }
  guard project is Some(project) else { return at }
  if from == "" || at == path {
    return at
  }
  let t = if to.has_suffix(fs.sep) { to.unsafe_substring(start=0, end=to.length() - 1) } else { to }
  let rest = at.unsafe_substring(start=t.length() + 1, end=at.length())
  let parts = []
  let mut start = 0
  for i = 0; i <= rest.length(); i = i + 1 {
    if i < rest.length() {
      let c = rest.unsafe_charcode_at(i)
      if c != '/' && c != '\\' {
        continue
      }
    }
    parts.push(rest.unsafe_substring(start~, end=i))
    start = i + 1
  }
  if parts.length() < 4 || !parts[0].has_prefix("transcripts") || parts[1] != "claude" {
    return at
  }
  parts[2] = project
  fs.join([t, ..parts])
}

///|
let cli_kept_dirs : Array[String] = ["conversations", "brain", "annotations"]

///|
let cli_home : Array[String] = ["agy", ".gemini", "antigravity-cli"]

///|
/// Whether the parts of a path under the data directory are in what an Antigravity CLI keeps of its conversations.
pub fn cli_kept(parts : Array[String]) -> Bool {
  parts.length() >= 7 &&
  parts[0] == "homes" &&
  parts[2] == cli_home[0] &&
  parts[3] == cli_home[1] &&
  parts[4] == cli_home[2] &&
  cli_kept_dirs.contains(parts[5])
}

///|
/// Whether `path` is one that goes along, or is put: under `dataDir`'s `sessions/` or a `transcripts*/` of it, or
/// what an Antigravity CLI keeps of its conversations there.
pub fn carried_place(fs : Fs, data : String, path : String) -> Bool {
  let rel = fs.relative(data, path)
  if rel == "" || rel.has_prefix("..") || fs.is_absolute(rel) {
    return false
  }
  let parts = rel.split(fs.sep).map(v => v.to_string()).collect()
  parts.length() > 1 && (parts[0] == "sessions" || parts[0].has_prefix("transcripts") || cli_kept(parts))
}

///|
/// Where a gathering keeps a session's list, in `scratch`.
pub fn list_file(fs : Fs, scratch : String, key : String) -> String {
  fs.join([scratch, "lists", "\{head_of(sha256_text(key), 32)}.jsonl"])
}

///|
/// The agent home's skills that are the station's own: none of them goes along.
pub fn own_skills() -> Array[String] {
  [..@session_storage.builtin_skills, @session_storage.feedback_skill, ..@session_storage.retired_skills]
}

///|
/// carry.ts's gathering, placing and preview, as a part of the station asks them: station/replica's in this program
/// unless the station says otherwise (a test's).
pub(all) struct Work {
  gather : async (String, String, String, Bool, String, String?, Array[String]?) -> J
  place : async (String, String, String, String?, String?, String?, Bool) -> J
  preview : async (String, String, String, Bool) -> J
  drop : (async (String) -> Unit)?
}

///|
/// The work in this program (station/replica's carry.mbt).
pub fn work_here(fs : Fs) -> Work {
  {
    gather: async fn(data, db, ws, home, scratch, agent, keys) {
      @replica.carry_gather(fs.host, fs.sep, data, db, ws, home, scratch, agent, keys, own_skills())
    },
    place: async fn(data, index, from, made, aside, placed, projects) {
      @replica.carry_place(fs.host, fs.sep, data, index, from, made, aside, placed, projects)
    },
    preview: async fn(data, db, ws, home) { @replica.carry_preview(fs.host, fs.sep, data, db, ws, home) },
    drop: None,
  }
}

///|
/// connects/remote.ts `knownOf`: the connect an id of station `here` names.
pub fn known_of(id : String, here : String) -> (String, String) {
  match id.rev_find("@") {
    Some(at) if at > 0 && at < id.length() - 1 => (id.unsafe_substring(start=0, end=at), id.unsafe_substring(start=at + 1, end=id.length()))
    _ => (id, here)
  }
}

///|
pub fn known_json(k : (String, String)) -> J {
  jo([("id", js(k.0)), ("origin", js(k.1))])
}

///|
/// connects/remote.ts `localOf`.
pub fn local_of(k : (String, String), here : String) -> String {
  if k.1 == here {
    k.0
  } else {
    "\{k.0}@\{k.1}"
  }
}

///|
/// How this station's connect ids go on `to` (retire.ts `connectsThere`).
pub fn connects_there(own : Array[String], used : Array[String], here : String, to : String) -> Array[(String, String)] {
  let out = []
  for id in uniq([..own, ..used]) {
    let there = if own.contains(id) || id.contains("@") { local_of(known_of(id, here), to) } else { id }
    if there != id {
      out.push((id, there))
    }
  }
  out
}

///|
/// jobs/jobs.ts `movedSaid`.
pub fn moved_said(why : String, name : String, port : Double?, id : String?, error : String?) -> String {
  let what = match id {
    Some(i) if i != "" =>
      match port {
        Some(p) => "Service \"\{name}\" (\{i}, port \{num_text(p)})"
        None => "Job \"\{name}\" (\{i})"
      }
    _ =>
      match port {
        Some(p) => "Service \"\{name}\" (port \{num_text(p)})"
        None => "Job \"\{name}\""
      }
  }
  match error {
    None => "\{why}; \{what} was started again."
    Some(e) => "\{why}; \{what} could not be started again: \{e}"
  }
}
