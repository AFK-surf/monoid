// Where a Feishu chat's words go (station/src/feishu/threads.ts, 「会话怎么分」), kept in <data>/feishu-threads.json:
// for each chat, the message its conversation began with (the thread's ts: what is said in the chat outside topics is
// one conversation, until someone starts a new one), and for each topic its first message (what the station replies
// to, to answer in it).

///|
/// What the Feishu code asks of the disk: a file's bytes (None: there is none; anything else that fails, its error), a
/// file of the station's own written whole (`writePrivateSoon`: its directory made, written beside and renamed over,
/// readable by the station alone), a directory made with those it is in, and a new file written only where none is
/// (`flag: "wx"`).
pub(all) struct Disk {
  read : async (String) -> Bytes?
  write_private : async (String, Bytes) -> Unit
  mkdir : async (String) -> Unit
  put_new : async (String, Bytes) -> Unit
}

///|
/// What the Feishu code says in the station's log (`log.info`, `log.warn`, `log.error`): its level, its area, its words
/// and its fields.
pub(all) struct Log {
  say : (String, String, String, JV) -> Unit
}

///|
pub fn Log::info(self : Log, area : String, words : String, fields : JV) -> Unit {
  (self.say)("info", area, words, fields)
}

///|
pub fn Log::warn(self : Log, area : String, words : String, fields : JV) -> Unit {
  (self.say)("warn", area, words, fields)
}

///|
pub fn Log::error(self : Log, area : String, words : String, fields : JV) -> Unit {
  (self.say)("error", area, words, fields)
}

///|
/// A file of the station's own that it keeps in memory and writes through (ops/files.ts `PrivateFile`): what is asked
/// while a write is on its way is written after it, the latest only. What `write` gives back once what was asked is
/// written (or its failure).
pub struct PrivateFile {
  path : String
  priv disk : Disk
  priv mut latest : String?
  priv mut writing : @effect.Deferred[Unit]?
}

///|
pub fn PrivateFile::new(disk : Disk, path : String) -> PrivateFile {
  { path, disk, latest: None, writing: None }
}

///|
/// Asks for `data` to be written: the flush on its way (one begun on the running runtime where there was none).
pub fn PrivateFile::write(self : PrivateFile, data : String) -> @effect.Deferred[Unit] {
  self.latest = Some(data)
  match self.writing {
    Some(d) => d
    None => {
      let d : @effect.Deferred[Unit] = @effect.Deferred::new()
      self.writing = Some(d)
      ignore(
        @effect.runtime().fork(async fn() {
          let failed = try {
            while self.latest is Some(next) {
              self.latest = None
              (self.disk.write_private)(self.path, utf8(next))
            }
            None
          } catch {
            e => Some(e)
          }
          self.writing = None
          match failed {
            None => ignore(d.succeed(()))
            Some(e) => ignore(d.fail(e))
          }
        }),
      )
      d
    }
  }
}

///|
/// Once what was asked is written (or failed).
pub async fn PrivateFile::written(self : PrivateFile) -> Unit {
  match self.writing {
    Some(d) => ignore(d.wait()) catch { _ => () }
    None => ()
  }
}

///|
/// `String(x)` of what a property read gave, as a thread's ts is used (None for undefined and null: `?? null`).
fn kept_text(v : JV?) -> String? {
  match v {
    None | Some(Null) => None
    Some(x) => Some(js_string(Some(x)))
  }
}

///|
/// `v?.[k]` of what a kept file holds: an object's field, a string's or an array's by its index or its length.
fn prop(v : JV?, k : String) -> JV? {
  match v {
    Some(Obj(_) as o) => o.get(k)
    Some(Arr(a)) =>
      if k == "length" {
        Some(jint(a.length()))
      } else {
        match index_key(k) {
          Some(i) if i < a.length().to_double() => Some(a[i.to_int()])
          _ => None
        }
      }
    Some(Str(s)) =>
      if k == "length" {
        Some(jint(s.length()))
      } else {
        match index_key(k) {
          Some(i) if i < s.length().to_double() => {
            let at = i.to_int()
            Some(Str(s.unsafe_substring(start=at, end=at + 1)))
          }
          _ => None
        }
      }
    _ => None
  }
}

///|
/// The TypeError strict code throws setting a property on a primitive.
fn cannot_create(k : String, on : JV) -> FeishuError {
  let (kind, shown) = match on {
    Num(n) => ("number", num_text(n))
    Str(s) => ("string", s)
    Bool(b) => ("boolean", if b { "true" } else { "false" })
    _ => ("object", "")
  }
  FeishuError("Cannot create property '\{k}' on \{kind} '\{shown}'")
}

///|
/// `o[k] ??= {}`: the object there (put where there was none, or null); a primitive there stays, and a field set on
/// it later is the TypeError.
fn or_new(o : JV, k : String) -> JV raise FeishuError {
  match o {
    Obj(_) =>
      match o.get(k) {
        None | Some(Null) => {
          let fresh = JV::Obj([])
          jput(o, k, fresh)
          fresh
        }
        Some(v) => v
      }
    Arr(_) =>
      // (a property of an array that is not an index is kept by nothing that is written)
      raise cannot_create(k, Str("[array]"))
    other => raise cannot_create(k, other)
  }
}

///|
/// `o[k] = v` as strict code does it: on an object, else the TypeError.
fn set_prop(o : JV, k : String, v : JV) -> Unit raise FeishuError {
  match o {
    Obj(_) => jput(o, k, v)
    Arr(_) => raise cannot_create(k, Str("[array]"))
    other => raise cannot_create(k, other)
  }
}

///|
/// `Number(v)` of what a kept file holds (a chat's `seen`).
fn js_to_number(v : JV) -> Double {
  match v {
    Null => 0.0
    Bool(b) => if b { 1.0 } else { 0.0 }
    Num(n) => n
    Str(s) => js_number(s)
    Arr([]) => 0.0
    Arr([x]) => js_to_number(Str(js_string(Some(x))))
    _ => @double.not_a_number
  }
}

///|
/// JavaScript's `a > b` of a number and what a kept file holds.
fn greater(a : Double, b : JV) -> Bool {
  match b {
    Str(s) => a > js_number(s)
    _ => a > js_to_number(b)
  }
}

///|
pub struct FeishuThreads {
  path : String
  priv file : PrivateFile
  priv log : Log
  priv kept : JV
}

///|
/// The file read once, as the station starts: an object, else nothing kept (what could not be read said in the log).
pub async fn FeishuThreads::open(
  disk : Disk,
  log : Log,
  path : String,
) -> FeishuThreads {
  let mut kept : JV = Obj([])
  let read = try {
    match (disk.read)(path) {
      Some(b) => Ok(Some(b))
      None => Ok(None)
    }
  } catch {
    e => Err(e)
  }
  match read {
    Ok(Some(b)) =>
      match try_parse(utf8_text(b)) {
        Some(Obj(_) as v) => kept = v
        Some(_) => ()
        None =>
          log.warn(
            "feishu",
            "feishu threads file unreadable; starting empty",
            jobj([("error", Some(js(json_parse_words(utf8_text(b)))))]),
          )
      }
    Ok(None) => ()
    Err(e) =>
      log.warn(
        "feishu",
        "feishu threads file unreadable; starting empty",
        jobj([("error", Some(js(error_words(e))))]),
      )
  }
  { path, file: PrivateFile::new(disk, path), log, kept }
}

///|
/// What JSON.parse's SyntaxError says of text it refused (V8's words, as far as the log is concerned).
fn json_parse_words(t : String) -> String {
  if trim_js(t) == "" {
    "Unexpected end of JSON input"
  } else {
    "Unexpected token in JSON"
  }
}

///|
/// Everything kept, as the file has it.
pub fn FeishuThreads::kept_jv(self : FeishuThreads) -> JV {
  self.kept
}

///|
fn FeishuThreads::of(self : FeishuThreads, connect : String) -> JV raise FeishuError {
  let at = or_new(self.kept, connect)
  ignore(or_new(at, "chats"))
  ignore(or_new(at, "topics"))
  ignore(or_new(at, "seen"))
  at
}

///|
/// Kept in memory at once, written off the station's thread (those asked while a write is on its way: the latest
/// after it).
fn FeishuThreads::save(self : FeishuThreads) -> Unit {
  let d = self.file.write(stringify(self.kept))
  let log = self.log
  ignore(
    @effect.runtime().fork(async fn() {
      d.wait() catch {
        e =>
          log.warn(
            "feishu",
            "feishu threads not kept",
            jobj([("error", Some(js(error_words(e))))]),
          )
      }
    }),
  )
}

///|
/// Once what was changed is written.
pub async fn FeishuThreads::written(self : FeishuThreads) -> Unit {
  self.file.written()
}

///|
/// The conversation a chat is in now, if it has begun one: as the file keeps it (one written by hand may keep a
/// number, which the station is then given as it is).
pub fn FeishuThreads::current(
  self : FeishuThreads,
  connect : String,
  chat : String,
) -> JV? {
  match prop(prop(prop(Some(self.kept), connect), "chats"), chat) {
    None | Some(Null) => None
    v => v
  }
}

///|
/// A conversation of the chat begins with `message`.
pub fn FeishuThreads::begin(
  self : FeishuThreads,
  connect : String,
  chat : String,
  message : String,
) -> Unit raise FeishuError {
  let at = self.of(connect)
  set_prop(at.get("chats").unwrap(), chat, js(message))
  self.save()
}

///|
/// The chats with a conversation, and when the last message heard in each was said (ms): what is read again after the
/// station was away (Feishu does not send what was said meanwhile).
pub fn FeishuThreads::conversations(
  self : FeishuThreads,
  connect : String,
) -> Array[(String, JV)] {
  let at = prop(Some(self.kept), connect)
  let chats = nullish(prop(at, "chats"), Obj([]))
  let keys = match chats {
    Obj(_) => jkeys(chats)
    Str(s) => Array::makei(s.length(), i => i.to_string())
    Arr(a) => Array::makei(a.length(), i => i.to_string())
    _ => []
  }
  keys.map(chat => (chat, nullish(prop(prop(at, "seen"), chat), Num(0.0))))
}

///|
/// A message said at `when` was heard in `chat` (kept when it is the latest).
pub fn FeishuThreads::heard(
  self : FeishuThreads,
  connect : String,
  chat : String,
  when : Double,
) -> Unit raise FeishuError {
  let seen = self.of(connect).get("seen").unwrap()
  let before = nullish(prop(Some(seen), chat), Num(0.0))
  if !greater(when, before) {
    return
  }
  set_prop(seen, chat, Num(when))
  self.save()
}

///|
/// A topic's first message, once heard.
pub fn FeishuThreads::topic_root(
  self : FeishuThreads,
  connect : String,
  topic : String,
) -> String? {
  kept_text(prop(prop(prop(Some(self.kept), connect), "topics"), topic))
}

///|
pub fn FeishuThreads::heard_topic(
  self : FeishuThreads,
  connect : String,
  topic : String,
  root : String,
) -> Unit raise FeishuError {
  let topics = self.of(connect).get("topics").unwrap()
  if prop(Some(topics), topic) == Some(Str(root)) {
    return
  }
  set_prop(topics, topic, js(root))
  self.save()
}
