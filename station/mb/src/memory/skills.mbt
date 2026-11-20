// A shared skill's files (station/src/share/index.ts, a skill shared with the other stations of the home workspace):
// read and hashed, written whole in place of what was there, and an edit made on an older copy kept beside it, by the
// shell (`fs.*`), none of their bytes on the station's thread but those it sends another station (`bytes`, as base64,
// the transport's own encoding). What it replaced is station/test/reference/share-skills.ts, which
// station/test/mb-share-skills.test.ts holds it to.

///|
/// A file of a skill found: its path in the skill (`/` between its components) and where it is.
priv struct SkillFile {
  path : String
  full : String
}

///|
/// A skill's files under `dir` (index.ts `readSkill` as it was): depth first, each directory's entries in their order,
/// links and the conflicts kept beside it (`SKILL.conflict-*`) left out. None past `max_bytes` (counted as they are
/// found) or `max_files`. A directory that does not read, or a file gone as it is looked at, fails it.
async fn skill_files(
  host : @host.Host,
  sep : String,
  dir : String,
  max_bytes : Double,
  max_files : Int,
) -> Array[SkillFile]? {
  let out : Array[SkillFile] = []
  let mut bytes = 0.0
  guard readdir(host, dir) is Some(top) else {
    raise Failed("ENOENT: no such file or directory, scandir '\{dir}'")
  }
  let stack : Array[(String, Array[(String, String)], Int)] = [("", top, 0)]
  while stack.pop() is Some((rel, es, at)) {
    if at >= es.length() {
      continue
    }
    stack.push((rel, es, at + 1))
    let (name, kind) = es[at]
    let sub = if rel == "" { name } else { rel + "/" + name }
    let full = dir + sep + sub.replace_all(old="/", new=sep)
    if kind == "dir" {
      guard readdir(host, full) is Some(inner) else {
        raise Failed("ENOENT: no such file or directory, scandir '\{full}'")
      }
      stack.push((sub, inner, 0))
    } else if kind == "file" {
      // A conflict kept beside the skill is the host's to show, not part of what is shared.
      if name.has_prefix("SKILL.conflict-") {
        continue
      }
      guard lstat(host, full) is Some(st) else {
        raise Failed("ENOENT: no such file or directory, lstat '\{full}'")
      }
      bytes += st.size
      if bytes > max_bytes || out.length() >= max_files {
        return None
      }
      out.push({ path: sub, full })
    }
  }
  Some(out)
}

///|
/// The hash of a skill whose files hash so (path → SHA-256): of each `<path>\0<hash>`, in the order JavaScript sorts
/// the paths, put together with `\n` (index.ts `skillHash` as it was).
pub fn skill_hash(hashes : Map[String, String]) -> String {
  let paths = hashes.keys().collect()
  paths.sort_by(fn(a, b) {
    if a == b {
      0
    } else if js_after(a, b) {
      1
    } else {
      -1
    }
  })
  let lines = paths.map(fn(p) { p + "\u{0}" + hashes.get(p).unwrap_or("") })
  sha256_hex(@utf8.encode(lines.join("\n")))
}

///|
/// `skillRead`: a skill's hash and whether it has its SKILL.md, with `bytes` its files too (path → base64); past what
/// may be shared, `tooLarge`.
async fn skill_read(
  host : @host.Host,
  sep : String,
  dir : String,
  max_bytes : Double,
  max_files : Int,
  with_bytes : Bool,
) -> Json {
  guard skill_files(host, sep, dir, max_bytes, max_files) is Some(found) else {
    return { "tooLarge": true }
  }
  let hashes : Map[String, String] = Map([])
  let files : Map[String, Json] = Map([])
  for f in found {
    if with_bytes {
      // Read once, hashed as read: what is sent is what its hash says.
      guard bytes_of(host, f.full) is Some(b) else {
        raise Failed("ENOENT: no such file or directory, open '\{f.full}'")
      }
      hashes[f.path] = sha256_hex(b)
      files[f.path] = Json::string(@base64.encode(b))
    } else {
      guard hash_of(host, f.full) is Some(h) else {
        raise Failed("ENOENT: no such file or directory, open '\{f.full}'")
      }
      hashes[f.path] = h
    }
  }
  let out : Map[String, Json] = {
    "hash": Json::string(skill_hash(hashes)),
    "hasSkillMd": Json::boolean(hashes.contains("SKILL.md")),
  }
  if with_bytes {
    out["files"] = Json::object(files)
  }
  Json::object(out)
}

///|
/// A path in a skill that stays inside it (station/src/ops/paths.ts `relativeParts`: not rooted, no `..`), none of its
/// components `.` or empty: its components.
pub fn skill_path(sep : String, path : String) -> Array[String]? {
  guard @nodepath.relative_parts(sep, path) is Some(parts) else { return None }
  if parts.iter().any(fn(p) { p == "." || p == "" }) {
    return None
  }
  Some(parts)
}

///|
/// `text`'s bytes as Node's `Buffer.from(text, "base64")` gives them: what is no base64 passed over, ended at the
/// first `=`, a last character alone dropped.
pub fn base64_bytes(text : String) -> Bytes {
  @codec.base64_decode_loose(text)
}

///|
/// What a shared skill's files are (path → base64), each checked before anything is written: a path that leaves the
/// skill (`skill_path`), a file not given as text, or past `most` bytes in all (where it is said) writes nothing.
fn skill_given(
  sep : String,
  files : Map[String, Json],
  most : Double?,
) -> Array[(Array[String], Bytes)] raise Failed {
  let out = []
  let mut size = 0.0
  for path, data in files {
    guard skill_path(sep, path) is Some(parts) else {
      raise Failed("bad path in a shared skill: \{path}")
    }
    guard data is String(b64) else {
      raise Failed("bad file in a shared skill: \{path}")
    }
    let bytes = base64_bytes(b64)
    size += bytes.length().to_double()
    out.push((parts, bytes))
  }
  if most is Some(m) && size > m {
    raise Failed("the skill is too large to share")
  }
  out
}

///|
/// The temporary directories' count, so that two writes of one process never share one.
let skill_temps : Ref[Int] = { val: 0 }

///|
/// `skillWrite`: the skill at `dir` replaced by `files` whole (index.ts `writeSkill` as it was): written into a
/// directory beside it, `<dir>.tmp-<pid>-<n>`, which then takes its place. With `check`, only checked.
async fn skill_write(
  host : @host.Host,
  sep : String,
  dir : String,
  files : Map[String, Json],
  most : Double?,
  check : Bool,
) -> Unit {
  let given = skill_given(sep, files, most)
  if check {
    return
  }
  skill_temps.val += 1
  let temp = "\{dir}.tmp-\{@host.pid()}-\{skill_temps.val}"
  ignore(fs(host, "fs.remove", { "path": Json::string(temp), "recursive": Json::boolean(true) }))
  for file in given {
    let (parts, bytes) = file
    let full = temp + sep + parts.join(sep)
    let parent = if parts.length() == 1 {
      temp
    } else {
      temp + sep + parts[0:parts.length() - 1].join(sep)
    }
    ignore(fs(host, "fs.mkdir", { "path": Json::string(parent) }))
    ignore(
      fs(
        host,
        "fs.put",
        {
          "path": Json::string(full),
          "offset": Json::number(0),
          "truncate": Json::boolean(true),
        },
        bytes~,
      ),
    )
  }
  ignore(fs(host, "fs.mkdir", { "path": Json::string(temp) }))
  ignore(fs(host, "fs.remove", { "path": Json::string(dir), "recursive": Json::boolean(true) }))
  ignore(fs(host, "fs.rename", { "from": Json::string(temp), "to": Json::string(dir) }))
}

///|
/// Where an edit of `peer`'s made on an older copy is kept beside the skill at `dir` (its station's first 12 characters).
pub fn skill_conflict_path(sep : String, dir : String, peer : String) -> String {
  let short = if peer.length() > 12 {
    peer.unsafe_substring(start=0, end=12)
  } else {
    peer
  }
  dir + sep + "SKILL.conflict-\{short}.md"
}

///|
/// `skillConflict`: `content` (base64) kept beside the skill at `dir` as the edit `peer` made on an older copy.
async fn skill_conflict(host : @host.Host, sep : String, dir : String, peer : String, content : String) -> Unit {
  ignore(
    fs(
      host,
      "fs.put",
      {
        "path": Json::string(skill_conflict_path(sep, dir, peer)),
        "offset": Json::number(0),
        "truncate": Json::boolean(true),
      },
      bytes=base64_bytes(content),
    ),
  )
}

///|
/// The SHA-256 digest of `data`, in lower-case hex (as Node's `digest("hex")`): `@hash.sha256_hex`'s, kept here for
/// what calls it by this package.
pub fn sha256_hex(data : BytesView) -> String {
  @hash.sha256_hex(data)
}
