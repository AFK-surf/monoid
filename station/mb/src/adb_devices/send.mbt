// adb/send.ts: phone_send, a file sent to a granted phone the way a chat's file is downloaded (GET /sessions/:key/parts,
// the phone fetching it a part at a time), not over adb, whose every packet waits for the phone's OKAY across the link
// and whose push begins again from nothing when a tunnel breaks. The file is put in the session's uploads under a name
// of its content, so a fetch cut short goes on from what the phone has of it when asked again.

///|
/// How long the phone has to take the fetch's stream.
let fetch_open : Double = 10000.0

///|
let b64_chars : String = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

///|
/// Bytes in base64, as they go between the program and its world.
pub fn b64(b : BytesView) -> String {
  let out = StringBuilder::new()
  let n = b.length()
  let mut i = 0
  while i < n {
    let a = b[i].to_int()
    let c1 = if i + 1 < n { b[i + 1].to_int() } else { 0 }
    let c2 = if i + 2 < n { b[i + 2].to_int() } else { 0 }
    out.write_char(b64_chars[a >> 2].unsafe_to_char())
    out.write_char(b64_chars[((a & 3) << 4) | (c1 >> 4)].unsafe_to_char())
    out.write_char(
      if i + 1 < n {
        b64_chars[((c1 & 15) << 2) | (c2 >> 6)].unsafe_to_char()
      } else {
        '='
      },
    )
    out.write_char(
      if i + 2 < n {
        b64_chars[c2 & 63].unsafe_to_char()
      } else {
        '='
      },
    )
    i += 3
  }
  out.to_string()
}

///|
/// Base64's bytes (what is no letter of it left out).
pub fn unb64(s : String) -> Bytes {
  let buf = @buffer.new()
  let mut acc = 0
  let mut bits = 0
  for c in s {
    let v = if c >= 'A' && c <= 'Z' {
      c.to_int() - 'A'.to_int()
    } else if c >= 'a' && c <= 'z' {
      c.to_int() - 'a'.to_int() + 26
    } else if c >= '0' && c <= '9' {
      c.to_int() - '0'.to_int() + 52
    } else if c == '+' || c == '-' {
      62
    } else if c == '/' || c == '_' {
      63
    } else {
      continue
    }
    acc = (acc << 6) | v
    bits += 6
    if bits >= 8 {
      bits -= 8
      buf.write_byte(((acc >> bits) & 0xff).to_byte())
    }
  }
  buf.to_bytes()
}

///|
/// The machine's separator of paths.
async fn sep(w : World) -> String {
  match w.ask("platform.sep", []) {
    Str(_) as s => js_text(s)
    _ => "/"
  }
}

///|
/// `given` (absolute, or in the session's `workspace`) in its uploads as `<sha256 prefix>-<name>`: its name there and
/// its size.
pub async fn staged(
  w : World,
  workspace : String,
  given : String,
) -> (String, Double) {
  let sep = sep(w)
  let path = if @nodepath.is_absolute(sep, given) {
    given
  } else {
    @nodepath.join(sep, [workspace, given])
  }
  let meta = w.ask("fs.stat", [js(path)]) catch { _ => Null }
  if meta is Null {
    raise fail_("no such file: \{given}")
  }
  if !(at(Some(meta), "isFile") is Some(Bool(true))) {
    raise fail_("not a file: \{given}")
  }
  let size = num_of(at(Some(meta), "size")).unwrap_or(0.0)
  let hash = js_text(w.ask("fs.sha256", [js(path)]))
  let safe = StringBuilder::new()
  for c in @nodepath.basename(sep, path) {
    safe.write_string(
      if c == '\\' || c == '/' || c.to_int() < 0x20 {
        "_"
      } else {
        c.to_string()
      },
    )
  }
  let name = "\{js_slice(hash, 0, b=16)}-\{safe.to_string()}"
  let dir = @nodepath.join(sep, [workspace, "uploads"])
  let at_ = @nodepath.join(sep, [dir, name])
  let there = w.ask("fs.stat", [js(at_)]) catch { _ => Null }
  if !(num_of(at(Some(there), "size")) == Some(size)) {
    ignore(w.ask("fs.mkdir", [js(dir)]))
    ignore(w.ask("fs.copy", [js(path), js("\{at_}.part")]))
    ignore(w.ask("fs.rename", [js("\{at_}.part"), js(at_)]))
  }
  (name, size)
}

///|
/// What the phone said of a fetch: where it put the file (`{path}`), or why it stopped and how much it has
/// (`{error, at, old}`).
pub async fn fetch_on_phone(
  w : World,
  conn : J,
  key : String,
  name : String,
  size : Double,
  heard? : async (Double) -> Unit,
) -> J {
  let mut got = 0.0
  try {
    let stream = w.ask("conn.openBi", [
      conn,
      jn(fetch_open),
      js("the phone did not take the file"),
    ])
    write_line(
      w,
      stream,
      jo([
        (
          "fetch",
          jo([("key", js(key)), ("name", js(name)), ("size", jn(size))]),
        ),
      ]),
    )
    ignore(w.ask("stream.finish", [stream]))
    let reader = Reader::new(w, stream)
    while true {
      guard reader.line() is Some(said) else {
        return jo([
          ("error", js("the phone ended the fetch")),
          ("at", jn(got)),
          ("old", jb(false)),
        ])
      }
      if at(Some(said), "path") is Some(Str(_) as p) {
        return jo([("path", p)])
      }
      if at(Some(said), "error") is Some(Str(_) as e) {
        // An app from before fetches takes the stream for a tunnel of a kind it does not know.
        let at_ = match at(Some(said), "at") {
          Some(Num(n)) => n
          _ => got
        }
        let old = at(Some(said), "at") is None &&
          js_text(e) == "无法识别的通道"
        return jo([("error", e), ("at", jn(at_)), ("old", jb(old))])
      }
      if at(Some(said), "at") is Some(Num(n)) {
        got = n
        match heard {
          Some(f) => f(got)
          None => ()
        }
      }
    }
    Null
  } catch {
    e => jo([("error", js(message_of(e))), ("at", jn(got)), ("old", jb(false))])
  }
}
