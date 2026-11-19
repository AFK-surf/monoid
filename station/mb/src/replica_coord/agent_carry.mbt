// A retired station's agent home put into this station's, as its chats are taken here (agent-carry.ts): its
// MEMORY.md put or appended under a heading, its presets.json merged by the devices' rule, a skill put whole where this
// one has none of that name. Nothing this station has is overwritten.

///|
/// What an agent home is made with: as good as none.
let made_empty = "# still.fail memory"

///|
fn js_space(c : Int) -> Bool {
  @jsjson.is_js_space(c)
}

///|
/// `s.trim()`.
pub fn js_trim(s : String) -> String {
  @jsjson.trim_js(s)
}

///|
/// `s.trimEnd()`.
pub fn js_trim_end(s : String) -> String {
  let mut b = s.length()
  while b > 0 && js_space(s.unsafe_charcode_at(b - 1)) {
    b -= 1
  }
  s.unsafe_substring(start=0, end=b)
}

///|
/// The line under a retired station's memory appended here, by which it is found again.
pub fn memory_mark(origin : String) -> String {
  "<!-- the memory of station \{origin}, retired into this one -->"
}

///|
async fn write_whole(fs : Fs, path : String, text : String) -> Unit {
  fs.mkdirs(fs.dirname(path))
  let tmp = "\{path}.\{fs.random_hex(4)}.carrying"
  fs.write_text(tmp, text)
  fs.rename(tmp, path)
}

///|
fn parsed_presets(text : String) -> J? {
  let v = parse(text) catch { _ => return None }
  match at(v, "presets") {
    Some(Arr(_)) => Some(v)
    _ => None
  }
}

///|
/// A preset or a deleted one as presets.json says it, for `newer_record` to weigh.
fn weighed(x : J) -> J {
  let rev = match at(x, "rev") {
    Some(Num(n)) if n == n.floor() && n.abs() <= 9007199254740991.0 && n >= 1.0 => n
    _ => 1.0
  }
  let updated = match at(x, "updatedAt") {
    Some(Num(n)) => n
    _ => 0.0
  }
  let base = match x {
    Obj(_) => x
    _ => Obj([])
  }
  set(set(base, "rev", jn(rev)), "updatedAt", jn(updated))
}

///|
/// `theirs` merged into `ours`, two presets.json: of each id the newer, kept as written; what this one has first, in
/// its order, what it has not after. How many of theirs were taken.
pub fn merge_presets(ours : J, theirs : J) -> (J, Int) {
  let all : Map[String, J] = {}
  let order = []
  let put = (x : J) => {
    guard str_at(x, "id") is Some(id) else { return false }
    match all.get(id) {
      None => order.push(id)
      Some(was) => {
        let a = weighed(was)
        let b = weighed(x)
        if @session_chats.canonical(a) == @session_chats.canonical(b) ||
          physical_equal(@session_chats.newer_record(a, b), a) {
          return false
        }
      }
    }
    all[id] = x
    true
  }
  for x in [..items(at(ours, "presets")), ..items(at(ours, "gone"))] {
    ignore(put(x))
  }
  let mut taken = 0
  for x in [..items(at(theirs, "presets")), ..items(at(theirs, "gone"))] {
    if put(x) {
      taken += 1
    }
  }
  let kept = order.map(id => all.get(id).unwrap_or(Null))
  let gone = (x : J) => at(x, "gone") is Some(Bool(true))
  let file = set(set(ours, "presets", ja(kept.filter(x => !gone(x)))), "gone", ja(kept.filter(gone)))
  (file, taken)
}

///|
/// What merging a home did.
pub struct HomeMerged {
  memory : String
  presets : Int
  skills : Array[String]
  skills_kept : Array[String]
}

///|
pub fn HomeMerged::to_json(self : HomeMerged) -> J {
  jo([("memory", js(self.memory)), ("presets", ji(self.presets)), ("skills", jstrs(self.skills)), ("skillsKept", jstrs(self.skills_kept))])
}

///|
/// `home`'s files (as sent: `list` the list's file, each file's bytes `files/<hash>`) merged into `to`, this station's
/// agent home of the workspace. `origin`, `name`, `at`: the retired station, and when.
pub async fn merge_agent_home(fs : Fs, to : String, home : J, list : String, files : String, origin : String, name : String, at_ms : Double) -> HomeMerged {
  let mut memory_out = "none"
  let mut presets_out = 0
  let skills_out = []
  let kept_out = []
  let mut memory : J? = None
  let mut presets : J? = None
  let groups : Array[(String, Array[(String, J)])] = []
  let dir = text_at(home, "dir")
  for line in fs.lines(list) {
    if line == "" {
      continue
    }
    let f = parse(line) catch { _ => continue }
    guard at(f, "hash") is Some(_) else { continue }
    let rel = fs.relative(dir, text_at(f, "path"))
    if rel == "" || rel.has_prefix("..") || fs.is_absolute(rel) {
      continue
    }
    let parts = rel.split(fs.sep).map(v => v.to_string()).collect()
    if rel == "MEMORY.md" {
      memory = Some(f)
    } else if rel == "presets.json" {
      presets = Some(f)
    } else if parts[0] == "skills" && parts.length() > 2 && !parts[1].has_prefix(".") {
      let rest = parts[2:].to_array().join(fs.sep)
      match groups.search_by(g => g.0 == parts[1]) {
        Some(i) => groups[i].1.push((rest, f))
        None => groups.push((parts[1], [(rest, f)]))
      }
    }
  }
  let blob = (f : J) => fs.join([files, text_at(f, "hash")])
  match memory {
    Some(m) if fs.there(blob(m)) => {
      let theirs = js_trim(fs.read_text(blob(m)).unwrap_or(""))
      let path = fs.join([to, "MEMORY.md"])
      let ours = fs.read_text(path).unwrap_or("")
      let mark = memory_mark(origin)
      if theirs == "" || theirs == made_empty || ours.contains(mark) {
        memory_out = "kept"
      } else if js_trim(ours) == "" || js_trim(ours) == made_empty {
        write_whole(fs, path, "\{theirs}\n\n\{mark}\n")
        memory_out = "put"
      } else {
        let day = head_of(@session_storage.iso(at_ms), 10)
        let who = if name != "" { name } else { head_of(origin, 12) }
        write_whole(fs, path, "\{js_trim_end(ours)}\n\n## From station \{who} (retired into this one on \{day})\n\n\{mark}\n\n\{theirs}\n")
        memory_out = "appended"
      }
    }
    _ => ()
  }
  match presets {
    Some(p) if fs.there(blob(p)) => {
      let theirs = parsed_presets(fs.read_text(blob(p)).unwrap_or(""))
      let path = fs.join([to, "presets.json"])
      let ours = match fs.read_text(path) {
        None => Some(jo([("presets", ja([]))]))
        Some(t) => parsed_presets(t)
      }
      match (theirs, ours) {
        (Some(t), Some(o)) => {
          let (file, taken) = merge_presets(o, t)
          if taken > 0 {
            write_whole(fs, path, "\{@jsjson.stringify_indent(file, 2)}\n")
            presets_out = taken
          }
        }
        _ => ()
      }
    }
    _ => ()
  }
  groups.sort_by((a, b) => if js_less(a.0, b.0) { -1 } else { 1 })
  for g in groups {
    let target = fs.join([to, "skills", g.0])
    if fs.there(target) {
      kept_out.push(g.0)
      continue
    }
    let beside = fs.join([to, "skills", ".carrying-\{g.0}"])
    fs.rm_rf(beside)
    for item in g.1 {
      let f = item.1
      if !fs.there(blob(f)) {
        continue
      }
      let path = fs.join([beside, item.0])
      fs.mkdirs(fs.dirname(path))
      fs.copy(blob(f), path)
      match num_at(f, "mode") {
        Some(mode) =>
          fs.chmod(path, mode.to_int()) catch {
            _ => ()
          }
        None => ()
      }
    }
    if !fs.there(beside) {
      continue
    }
    fs.rename(beside, target)
    skills_out.push(g.0)
  }
  { memory: memory_out, presets: presets_out, skills: skills_out, skills_kept: kept_out }
}
