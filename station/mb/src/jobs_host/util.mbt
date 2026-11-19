// What every part of jobs_host takes JSON, text and numbers by, as the TypeScript it replaces had them: a value's
// field, a JavaScript number as `String(n)` says it, `Math.round`, a slice of a string, and the shell's calls.

///|
pub(all) suberror HostError {
  HostError(String)
}

///|
pub impl Show for HostError with output(self, logger) {
  let HostError(s) = self
  logger.write_string(s)
}

///|
/// The words an error says, as a TypeScript `(error as Error).message` would.
pub fn words_of(e : Error) -> String {
  match e {
    HostError(s) => s
    _ => {
      let s = e.to_string()
      // (the shell's refusals come as ShellError("…"))
      match s.find("(\"") {
        Some(i) if s.has_suffix("\")") => {
          let inner = s.view(start_offset=i + 2, end_offset=s.length() - 2).to_owned()
          unescape(inner)
        }
        _ => s
      }
    }
  }
}

///|
fn unescape(s : String) -> String {
  let out = StringBuilder::new()
  let mut i = 0
  while i < s.length() {
    let c = s.unsafe_charcode_at(i)
    if c == '\\' && i + 1 < s.length() {
      let d = s.unsafe_charcode_at(i + 1)
      match d {
        'n' => out.write_char('\n')
        't' => out.write_char('\t')
        _ => out.write_char(Int::unsafe_to_char(d))
      }
      i += 2
    } else {
      out.write_char(Int::unsafe_to_char(c))
      i += 1
    }
  }
  out.to_string()
}

///|
fn jstr(s : String) -> Json {
  Json::string(s)
}

///|
fn jnum(d : Double) -> Json {
  Json::number(d)
}

///|
fn jint(n : Int) -> Json {
  Json::number(n.to_double())
}

///|
fn jbool(b : Bool) -> Json {
  if b {
    Json::boolean(true)
  } else {
    Json::boolean(false)
  }
}

///|
/// An object of these pairs, in their order (later keys replacing earlier as a spread does).
fn obj(pairs : Array[(String, Json)]) -> Json {
  let m : Map[String, Json] = Map([])
  for p in pairs {
    m[p.0] = p.1
  }
  Json::object(m)
}

///|
/// `v[key]` where `v` is an object (not an array) that has it.
fn field(v : Json, key : String) -> Json? {
  match v {
    Object(m) => m.get(key)
    _ => None
  }
}

///|
/// `v[key]`, null where there is none.
fn field_or_null(v : Json, key : String) -> Json {
  field(v, key).unwrap_or(Json::null())
}

///|
/// `v[key]` where it is a string, else "".
fn text(v : Json, key : String) -> String {
  match field(v, key) {
    Some(String(s)) => s
    _ => ""
  }
}

///|
/// A finite number (load.ts `num`).
fn num(v : Json?) -> Double? {
  match v {
    Some(Number(d, ..)) => Some(d)
    _ => None
  }
}

///|
/// A JavaScript number as `String(n)` writes it.
pub fn js_number(d : Double) -> String {
  if d == 0.0 {
    return "0"
  }
  @jsjson.stringify(@jsjson.JValue::Num(d))
}

///|
/// `JSON.stringify(s)` of a string.
fn js_quoted(s : String) -> String {
  @jsjson.stringify(@jsjson.JValue::of_string(s))
}

///|
/// `Math.round`.
pub fn js_round(x : Double) -> Double {
  @jsjson.js_round(x)
}

///|
/// `Number.isSafeInteger`.
fn safe_integer(d : Double) -> Bool {
  @jsjson.is_safe_integer(d)
}

///|
fn slice(s : String, from : Int, to : Int) -> String {
  let n = s.length()
  let a = if from < 0 { 0 } else if from > n { n } else { from }
  let b = if to < a { a } else if to > n { n } else { to }
  s.view(start_offset=a, end_offset=b).to_owned()
}

///|
fn from(s : String, i : Int) -> String {
  slice(s, i, s.length())
}

///|
/// `s.indexOf(sep, at)`.
fn index_of(s : String, sep : String, at? : Int = 0) -> Int {
  @jsjson.js_index_of(s, sep, from=at)
}

///|
/// `s.split(sep)` of a non-empty separator.
fn split(s : String, sep : String) -> Array[String] {
  @jsjson.js_split(s, sep)
}

///|
fn join(parts : Array[String], sep : String) -> String {
  parts.join(sep)
}

///|
fn starts(s : String, p : String) -> Bool {
  s.has_prefix(p)
}

///|
fn ends(s : String, p : String) -> Bool {
  s.has_suffix(p)
}

///|
fn is_digit(c : Int) -> Bool {
  c >= '0' && c <= '9'
}

///|
fn all_digits(s : String) -> Bool {
  if s.length() == 0 {
    return false
  }
  for i in 0..<s.length() {
    if !is_digit(s.unsafe_charcode_at(i)) {
      return false
    }
  }
  true
}

///|
/// `Number(s)` of digits (and one `.`), as a double.
fn digits_number(s : String) -> Double {
  @string.parse_double(s) catch {
    _ => 0.0
  }
}

///|
/// `/^\d+(\.\d+)?$/`.
fn decimal(s : String) -> Bool {
  match s.find(".") {
    None => all_digits(s)
    Some(i) => all_digits(slice(s, 0, i)) && all_digits(from(s, i + 1))
  }
}

///|
fn lower_ascii(s : String) -> String {
  let out = StringBuilder::new()
  for i in 0..<s.length() {
    let c = s.unsafe_charcode_at(i)
    out.write_char(Int::unsafe_to_char(if c >= 'A' && c <= 'Z' { c + 32 } else { c }))
  }
  out.to_string()
}

///|
fn trim(s : String) -> String {
  @jscase.trim(s)
}

///|
/// An array's values joined as `Array.prototype.join` writes them.
fn js_join(values : Array[Json], sep : String) -> String {
  join(values.map(js_text), sep)
}

///|
/// A value as `String(v)` writes it, inside a join (null and undefined as "").
fn js_text(v : Json) -> String {
  match v {
    Null => ""
    True => "true"
    False => "false"
    Number(d, ..) => js_number(d)
    String(s) => s
    Array(a) => js_join(a, ",")
    Object(_) => "[object Object]"
  }
}

///|
/// The shell's answer to `op`, its failure raised with its words.
async fn ask(host : @host.Host, op : String, args : Json) -> Json raise {
  let (answer, _) = host.shell(op, args)
  answer
}

///|
/// A program run to its end (`proc.run`): what it printed; None where it did not end well (`code`: its code too).
async fn run_program(
  host : @host.Host,
  command : String,
  args : Array[String],
  timeout_ms? : Int = 5000,
  max_bytes? : Int = 1 << 20,
  env? : Map[String, String] = {},
) -> String? {
  let e : Map[String, Json] = Map([])
  for k, v in env {
    e[k] = jstr(v)
  }
  let answer = ask(host, "proc.run", {
    "command": jstr(command),
    "args": Json::array(args.map(jstr)),
    "timeoutMs": jint(timeout_ms),
    "maxBytes": jint(max_bytes),
    "env": Json::object(e),
  }) catch {
    _ => return None
  }
  match answer {
    String(s) => Some(s)
    _ => None
  }
}

///|
/// A program's code and what it printed, for any end it came to (`proc.run`'s `code`).
async fn run_code(
  host : @host.Host,
  command : String,
  args : Array[String],
  timeout_ms? : Int = 5000,
  max_bytes? : Int = 1 << 20,
) -> (Int, String)? {
  let answer = ask(host, "proc.run", {
    "command": jstr(command),
    "args": Json::array(args.map(jstr)),
    "timeoutMs": jint(timeout_ms),
    "maxBytes": jint(max_bytes),
    "code": jbool(true),
  }) catch {
    _ => return None
  }
  match answer {
    { "code": Number(c, ..), "out": String(o), .. } => Some((c.to_int(), o))
    _ => None
  }
}

///|
/// A path joined as Node's posix `join` joins it.
fn pjoin(parts : Array[String]) -> String {
  @nodepath.join("/", parts)
}

///|
/// The shell's answer, None where it failed.
async fn try_ask(host : @host.Host, op : String, args : Json) -> Json? {
  try ask(host, op, args) catch {
    _ => None
  } noraise {
    v => Some(v)
  }
}

///|
/// A file's text, None when it does not read.
async fn read_text(host : @host.Host, path : String) -> String? {
  match try_ask(host, "fs.read", { "path": jstr(path) }) {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
/// A file's bytes, None when it does not open.
async fn read_bytes(host : @host.Host, path : String) -> Bytes? {
  match try_ask(host, "fs.bytes", { "path": jstr(path) }) {
    Some(String(h)) => Some(@hex.decode(h) catch { _ => return None })
    _ => None
  }
}

///|
/// What lstat says of a path: {kind, size, mode, ino, mtimeMs, ctimeMs}; None where nothing is there.
async fn lstat(host : @host.Host, path : String) -> Json? {
  match try_ask(host, "fs.lstat", { "path": jstr(path) }) {
    Some(Null) | None => None
    Some(v) => Some(v)
  }
}

///|
/// A directory's names in Node's readdir order; None where it cannot be read.
async fn readdir(host : @host.Host, path : String) -> Array[String]? {
  match try_ask(host, "fs.readdir", { "path": jstr(path) }) {
    Some(Array(a)) =>
      Some(
        a.filter_map(v => match v {
          String(s) => Some(s)
          _ => None
        }),
      )
    _ => None
  }
}

///|
/// rm -f (`recursive`: a folder with all it holds), its failure let go.
async fn remove(host : @host.Host, path : String, recursive? : Bool = false) -> Unit {
  ignore(try_ask(host, "fs.remove", { "path": jstr(path), "recursive": jbool(recursive) }))
}

///|
async fn mkdirs(host : @host.Host, path : String) -> Unit raise {
  ignore(ask(host, "fs.mkdir", { "path": jstr(path) }))
}

///|
/// Bytes put into a file (`fs.put`): at `offset` (appended where none), its size after.
async fn put(
  host : @host.Host,
  path : String,
  bytes : Bytes,
  offset? : Double,
  truncate? : Bool = false,
  sync? : Bool = false,
  nofollow? : Bool = false,
  exclusive? : Bool = false,
  mode? : Int = 0o666,
) -> Double raise {
  let args : Map[String, Json] = {
    "path": jstr(path),
    "truncate": jbool(truncate),
    "sync": jbool(sync),
    "nofollow": jbool(nofollow),
    "exclusive": jbool(exclusive),
    "mode": jint(mode),
  }
  match offset {
    Some(o) => args["offset"] = jnum(o)
    None => ()
  }
  let (answer, _) = host.shell("fs.put", Json::object(args), bytes~)
  num(field(answer, "size")).unwrap_or(0.0)
}

///|
/// Text written whole (made beside it and moved into place).
async fn write_text(host : @host.Host, path : String, text : String) -> Unit raise {
  ignore(ask(host, "fs.write", { "path": jstr(path), "text": jstr(text) }))
}

///|
async fn rename(host : @host.Host, from : String, to : String) -> Unit raise {
  ignore(ask(host, "fs.rename", { "from": jstr(from), "to": jstr(to) }))
}

///|
/// Random bytes as hex, `n` of them.
async fn random_hex(host : @host.Host, n : Int) -> String {
  match try_ask(host, "crypto.random", { "bytes": jint(n) }) {
    Some(String(s)) => s
    _ => {
      // (no source answered: the clock's)
      let t = @host.now()
      let out = StringBuilder::new()
      for i in 0..<n {
        let b = ((t >> (i % 8 * 8)) & 0xffL).to_int() ^ (i * 37 % 256)
        out.write_string(@hex.encode(Bytes::from_array([b.to_byte()])))
      }
      out.to_string()
    }
  }
}
