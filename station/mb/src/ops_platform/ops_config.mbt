// station/src/ops/config.ts `ConfigFile`: config.json as a live, editable document, the file the source of truth.
// Edits are checked, written whole (beside and renamed, as the shell's `fs.write` does) and told to whoever listens;
// fields this station does not know are kept. Edited by something else, it is read again when the file changed (its
// size, time and inode), and told then. A file not there is `{}`. Unreadable, the last good value stays for readers
// and edits are refused until it reads again; read first, it is refused, never taken for the defaults.

///|
pub struct ConfigFile {
  path : String
  data : String
  fs : Fs
  /// What an edit must pass (accounts' parse_config): what is wrong, None where nothing is.
  mut check : (Json, String) -> String?
  /// The words an unreadable file is refused with (json-file.ts `InvalidJsonFile`).
  invalid_words : String
  mut seen : String
  mut value : Json
  mut invalid : String?
  mut last_written : String?
  listeners : Array[(Json) -> Unit]
}

///|
/// config.ts's constructor: the file at STILLFAIL_CONFIG (`env_config`), else `<data>/config.json`, read at once.
pub fn ConfigFile::new(
  fs : Fs,
  data : String,
  env_config : String?,
  invalid_words : String,
) -> ConfigFile raise {
  let path = match env_config {
    Some(p) if p != "" => p
    _ => posix_join([data, "config.json"])
  }
  let c : ConfigFile = {
    path,
    data,
    fs,
    check: (_, _) => None,
    invalid_words,
    seen: "",
    value: Json::object(Map([])),
    invalid: None,
    last_written: None,
    listeners: [],
  }
  ignore(c.raw())
  c
}

///|
/// The file's size, time and inode, or "none" where it is not.
fn ConfigFile::stamp(self : ConfigFile) -> String raise {
  match self.fs.meta(self.path) {
    None => "none"
    Some((size, mtime, _)) => {
      let ino = match self.fs.lstat(self.path) {
        Some(l) => l.ino
        None => 0.0
      }
      "\{num_text(size)}:\{num_text(mtime)}:\{num_text(ino)}"
    }
  }
}

///|
/// config.ts `raw`: the config as stored now (the file looked at again, as an unwatched one's is at every read).
pub fn ConfigFile::raw(self : ConfigFile) -> Json raise {
  let now = self.stamp()
  if now != self.seen {
    self.take(now, if now == "none" { None } else { self.fs.read(self.path) })
  }
  self.value
}

///|
/// config.ts `take`: what the file holds as stamped `now`.
fn ConfigFile::take(self : ConfigFile, now : String, text : String?) -> Unit raise {
  let first = self.seen == ""
  match (text, self.last_written) {
    (Some(t), Some(w)) if t == w => {
      self.seen = now
      self.invalid = None
      return
    }
    _ => ()
  }
  self.last_written = None
  let parsed = match text {
    None => Some(Json::object(Map([])))
    Some(t) => js_parse(t)
  }
  match parsed {
    Some(v) => {
      self.value = v
      self.seen = now
      self.invalid = None
    }
    None => {
      self.seen = now
      self.invalid = Some(self.invalid_words)
      if first {
        raise Failure(self.invalid_words)
      }
      return
    }
  }
  if !first {
    self.tell()
  }
}

///|
/// config.ts `listen`.
pub fn ConfigFile::listen(self : ConfigFile, listener : (Json) -> Unit) -> Unit {
  self.listeners.push(listener)
}

///|
fn ConfigFile::tell(self : ConfigFile) -> Unit {
  for l in self.listeners {
    l(self.value)
  }
}

///|
/// config.ts `update`: an edit applied to a copy, written and told only where the result checks out (else refused,
/// nothing changed).
pub fn ConfigFile::update(self : ConfigFile, edit : (Json) -> Json) -> Json raise {
  let current = self.raw()
  match self.invalid {
    Some(e) => raise Failure(e)
    None => ()
  }
  let next = edit(current)
  match (self.check)(next, self.data) {
    Some(e) => raise Failure(e)
    None => ()
  }
  let text = @jsjson.stringify_indent(to_jvalue(next), 2) + "\n"
  self.fs.write(self.path, text)
  self.fs.chmod(self.path, 0o600)
  self.value = next
  self.last_written = Some(text)
  self.seen = self.stamp()
  self.tell()
  next
}

///|
/// A case's edit: `set` merged over the config's top level (a key given null removed), as a JSON edit would do it.
pub fn config_edit(set : Json) -> (Json) -> Json {
  current => {
    let out : Map[String, Json] = Map([])
    match current {
      Object(m) =>
        for k, v in m {
          out[k] = v
        }
      _ => ()
    }
    match set {
      Object(s) =>
        for k, v in s {
          if v is Null {
            out.remove(k)
          } else {
            out[k] = v
          }
        }
      _ => ()
    }
    Json::object(out)
  }
}
