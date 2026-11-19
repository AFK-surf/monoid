// feishu_api (station/src/feishu/tool.ts, 「agent 看到的」): any Feishu OpenAPI call as the bot of one of the
// session's Feishu chats. Messages are not sent through it (chat_post answers a chat, and keeps what was said), nor is
// the app itself managed.

///|
/// The tool as the agents are told it.
pub fn feishu_api_tool() -> JV {
  jobj([
    ("name", Some(js("feishu_api"))),
    (
      "description",
      Some(
        js(
          "Call a Feishu (Lark) OpenAPI method as your Feishu bot, e.g. GET /open-apis/im/v1/chats/:chat_id, GET /open-apis/docx/v1/documents/:id/raw_content, POST /open-apis/im/v1/messages/:message_id/reactions. Getting a message's image or file with GET /open-apis/im/v1/messages/:message_id/resources/:file_key (params type: image or file) saves it in your workspace and returns its local path, content type and size; other non-JSON answers are saved the same way. What it may read and change is what the app's permissions allow. Send and answer messages with chat_post, not this.",
        ),
      ),
    ),
    (
      "inputSchema",
      Some(
        jobj([
          ("type", Some(js("object"))),
          (
            "properties",
            Some(
              jobj([
                (
                  "method",
                  Some(
                    jobj([
                      ("type", Some(js("string"))),
                      (
                        "description",
                        Some(
                          js(
                            "An HTTP method and the path, e.g. \"GET /open-apis/contact/v3/users/ou_xxx\".",
                          ),
                        ),
                      ),
                    ]),
                  ),
                ),
                (
                  "params",
                  Some(
                    jobj([
                      ("type", Some(js("object"))),
                      (
                        "description",
                        Some(
                          js(
                            "A GET's query parameters; for other methods the JSON body (its query parameters under \"query\").",
                          ),
                        ),
                      ),
                      ("additionalProperties", Some(Bool(true))),
                    ]),
                  ),
                ),
                (
                  "to",
                  Some(
                    jobj([
                      ("type", Some(js("string"))),
                      (
                        "description",
                        Some(
                          js(
                            "CHANNEL/THREAD_TS of one of your Feishu conversations: whose bot to call as. Default: this session's own connect.",
                          ),
                        ),
                      ),
                    ]),
                  ),
                ),
              ]),
            ),
          ),
          ("required", Some(Arr([js("method")]))),
          ("additionalProperties", Some(Bool(false))),
        ]),
      ),
    ),
  ])
}

///|
/// Paths that are not for agents: the app's credentials and settings.
let managing : Array[String] = [
  "/open-apis/auth/", "/open-apis/application/", "/open-apis/app_engine/",
]

// ── a file's name (`fileName`) ──

///|
/// What follows `(?:^|;)` in `disposition` for each place such a match may begin, in the order a regular expression
/// tries them: where the text after begins.
fn match_starts(s : String) -> Array[Int] {
  let out = [0]
  for i in 0..<s.length() {
    if s.unsafe_charcode_at(i) == ';' {
      out.push(i + 1)
    }
  }
  out
}

///|
/// `\s*`: past the white space from `i`.
fn skip_space(s : String, i : Int) -> Int {
  let mut j = i
  while j < s.length() && is_js_space(s.unsafe_charcode_at(j)) {
    j += 1
  }
  j
}

///|
/// `word` at `i`, ASCII letters in either case: where it ends.
fn word_at(s : String, i : Int, word : String) -> Int? {
  if i + word.length() > s.length() {
    return None
  }
  if ascii_lower(s.unsafe_substring(start=i, end=i + word.length())) ==
    ascii_lower(word) {
    Some(i + word.length())
  } else {
    None
  }
}

///|
/// `[^;]*` from `i`: where it ends.
fn not_semicolon(s : String, i : Int) -> Int {
  let mut j = i
  while j < s.length() && s.unsafe_charcode_at(j) != ';' {
    j += 1
  }
  j
}

///|
/// `/(?:^|;)\s*filename\*\s*=\s*UTF-8''([^;]*)/i`'s capture.
fn disposition_encoded(s : String) -> String? {
  for start in match_starts(s) {
    let mut i = skip_space(s, start)
    guard word_at(s, i, "filename*") is Some(j) else { continue }
    i = skip_space(s, j)
    if i >= s.length() || s.unsafe_charcode_at(i) != '=' {
      continue
    }
    i = skip_space(s, i + 1)
    guard word_at(s, i, "UTF-8''") is Some(j) else { continue }
    return Some(s.unsafe_substring(start=j, end=not_semicolon(s, j)))
  }
  None
}

///|
fn is_line_terminator(c : Int) -> Bool {
  c is (0x0a | 0x0d | 0x2028 | 0x2029)
}

///|
/// `"((?:\\.|[^"])*)"` from `i` (at its opening quote), as a backtracking matcher tries it: where the closing quote is.
fn quoted_end(s : String, i : Int) -> Int? {
  // the choices made: where each `\\.` was taken, to be tried again as `[^"]` (the backslash alone)
  let n = s.length()
  let escapes : Array[Int] = []
  let mut at = i + 1
  while true {
    // greedy: as far as it goes, `\\.` first
    while at < n {
      let c = s.unsafe_charcode_at(at)
      if c == '\\' && at + 1 < n && !is_line_terminator(s.unsafe_charcode_at(at + 1)) {
        escapes.push(at)
        at += 2
      } else if c != '"' {
        at += 1
      } else {
        break
      }
    }
    if at < n && s.unsafe_charcode_at(at) == '"' {
      return Some(at)
    }
    // stuck at the end: the latest `\\.` taken as the backslash alone, and on from the character it escaped
    guard escapes.pop() is Some(e) else { return None }
    at = e + 1
    // (that character, if a quote, ends it now; if not, the greedy run goes on from it, its own choices new)
    if s.unsafe_charcode_at(at) == '"' {
      return Some(at)
    }
  }
  None
}

///|
/// `/(?:^|;)\s*filename\s*=\s*(?:"((?:\\.|[^"])*)"|([^;]*))/i`: its first capture (quoted) or its second.
fn disposition_plain(s : String) -> (String?, String?)? {
  for start in match_starts(s) {
    let mut i = skip_space(s, start)
    guard word_at(s, i, "filename") is Some(j) else { continue }
    i = skip_space(s, j)
    if i >= s.length() || s.unsafe_charcode_at(i) != '=' {
      continue
    }
    i = skip_space(s, i + 1)
    if i < s.length() && s.unsafe_charcode_at(i) == '"' {
      match quoted_end(s, i) {
        Some(e) => return Some((Some(s.unsafe_substring(start=i + 1, end=e)), None))
        None => ()
      }
    }
    return Some((None, Some(s.unsafe_substring(start=i, end=not_semicolon(s, i)))))
  }
  None
}

///|
/// `.replace(/\\(.)/g, "$1")`.
fn unescaped(s : String) -> String {
  let out = StringBuilder::new()
  let n = s.length()
  let mut i = 0
  while i < n {
    let c = s.unsafe_charcode_at(i)
    if c == '\\' && i + 1 < n && !is_line_terminator(s.unsafe_charcode_at(i + 1)) {
      out.write_char(s.unsafe_charcode_at(i + 1).unsafe_to_char())
      i += 2
    } else {
      out.write_char(c.unsafe_to_char())
      i += 1
    }
  }
  out.to_string()
}

///|
/// decodeURIComponent: each %XX run as UTF-8, well formed or the URIError.
pub fn decode_uri_component(s : String) -> String raise FeishuError {
  let out = StringBuilder::new()
  let n = s.length()
  let mut i = 0
  let byte_at = (k : Int) => {
    if k + 2 >= n || s.unsafe_charcode_at(k) != '%' {
      None
    } else {
      match (@codec.hex_digit(s.unsafe_charcode_at(k + 1)), @codec.hex_digit(s.unsafe_charcode_at(k + 2))) {
        (Some(h), Some(l)) => Some(h * 16 + l)
        _ => None
      }
    }
  }
  while i < n {
    let c = s.unsafe_charcode_at(i)
    if c != '%' {
      out.write_char(c.unsafe_to_char())
      i += 1
      continue
    }
    guard byte_at(i) is Some(b) else { raise FeishuError("URI malformed") }
    i += 3
    if b < 0x80 {
      out.write_char(b.unsafe_to_char())
      continue
    }
    let (need, init, min) = if (b & 0xe0) == 0xc0 {
      (1, b & 0x1f, 0x80)
    } else if (b & 0xf0) == 0xe0 {
      (2, b & 0x0f, 0x800)
    } else if (b & 0xf8) == 0xf0 {
      (3, b & 0x07, 0x10000)
    } else {
      raise FeishuError("URI malformed")
    }
    let mut cp = init
    for _ in 0..<need {
      guard byte_at(i) is Some(x) && (x & 0xc0) == 0x80 else {
        raise FeishuError("URI malformed")
      }
      cp = (cp << 6) | (x & 0x3f)
      i += 3
    }
    if cp < min || cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff) {
      raise FeishuError("URI malformed")
    }
    out.write_char(cp.unsafe_to_char())
  }
  out.to_string()
}

///|
/// `[\\/\x00-\x1f\x7f<>:"|?*]` each as `_`, then `[. ]+$` off, then trimmed.
fn safe_name(s : String) -> String {
  let out = StringBuilder::new()
  for i in 0..<s.length() {
    let c = s.unsafe_charcode_at(i)
    if c < 0x20 || c == 0x7f || c is ('\\' | '/' | '<' | '>' | ':' | '"' | '|' | '?' | '*') {
      out.write_char('_')
    } else {
      out.write_char(c.unsafe_to_char())
    }
  }
  let t = out.to_string()
  let mut end = t.length()
  while end > 0 && t.unsafe_charcode_at(end - 1) is ('.' | ' ') {
    end -= 1
  }
  trim_js(t.unsafe_substring(start=0, end~))
}

///|
let extensions : Array[(String, String)] = [
  ("image/jpeg", ".jpg"),
  ("image/png", ".png"),
  ("image/gif", ".gif"),
  ("image/webp", ".webp"),
  ("image/svg+xml", ".svg"),
  ("application/pdf", ".pdf"),
  ("text/html", ".html"),
  ("text/plain", ".txt"),
  ("text/csv", ".csv"),
  ("application/zip", ".zip"),
]

///|
/// The first `most` code points.
fn first_points(s : String, most : Int) -> String {
  let p = points(s)
  if p.length() <= most {
    s
  } else {
    p[0:most].to_array().join("")
  }
}

///|
/// A suggested name is untrusted: keep it within uploads, short enough for a filesystem, and preserve its extension.
pub fn file_name(content_type : String, disposition : String) -> String {
  let encoded = disposition_encoded(disposition)
  let mut name = match disposition_plain(disposition) {
    Some((Some(q), _)) => trim_js(unescaped(q))
    Some((None, Some(p))) => trim_js(p)
    _ => ""
  }
  match encoded {
    Some(e) => name = decode_uri_component(trim_js(e)) catch { _ => name }
    None => ()
  }
  name = safe_name(name)
  let ext_full = extname(name)
  let ext = first_points(ext_full, 16)
  let ext = if ext != "" {
    ext
  } else {
    let kind = @jscase.lower(trim_js(content_type.split(";").next().map(v => v.to_string()).unwrap_or("")))
    let mut found = ""
    for e in extensions {
      if e.0 == kind {
        found = e.1
        break
      }
    }
    found
  }
  let stem = if ext_full != "" {
    name.unsafe_substring(start=0, end=name.length() - ext_full.length())
  } else {
    name
  }
  first_points(if stem == "" { "file" } else { stem }, 32) + ext
}

// ── the tool ──

///|
/// What the tool asks of the station's hub (sessions/hub.ts and what it reaches).
pub(all) struct ToolWorld {
  /// A session's row: its own connect (None: none) and its workspace; None where there is no such session.
  session : (String) -> (String?, String)?
  /// The connects of the session's recent threads, newest first (store `recentSessionThreads`).
  recent_connects : (String) -> Array[String]
  /// The connect of the session's thread `to` names (sessions/conversations.ts `target`), or its refusal.
  target : (String, JV) -> String raise
  /// A connect's surface's OpenAPI call (`chat.api`), where it has one.
  chat_api : (String) -> (async (String, JV) -> Answered)?
  now : () -> Int64
  uuid : () -> String
  disk : Disk
  /// The file system's separator ("/", "\\" on Windows).
  sep : String
}

///|
/// `jsString`: a string as it is, null as "null", anything else as JSON.
fn js_string_arg(v : JV) -> String {
  match v {
    Str(s) => s
    Null => "null"
    v => stringify(v)
  }
}

///|
/// `s.split(/\s+/)`.
fn split_space(s : String) -> Array[String] {
  let out = []
  let n = s.length()
  let mut from = 0
  let mut i = 0
  while i < n {
    if is_js_space(s.unsafe_charcode_at(i)) {
      out.push(s.unsafe_substring(start=from, end=i))
      while i < n && is_js_space(s.unsafe_charcode_at(i)) {
        i += 1
      }
      from = i
    } else {
      i += 1
    }
  }
  out.push(s.unsafe_substring(start=from, end=n))
  out
}

///|
/// `/\/reactions(\/|$)/`.
fn reactions_path(path : String) -> Bool {
  let word = "/reactions"
  let n = path.length()
  let mut i = 0
  while i + word.length() <= n {
    if path.unsafe_substring(start=i, end=i + word.length()) == word {
      let after = i + word.length()
      if after == n || path.unsafe_charcode_at(after) == '/' {
        return true
      }
    }
    i += 1
  }
  false
}

///|
/// read/transcript.ts `iso`: an ISO timestamp of milliseconds since the epoch, as toISOString writes it.
pub fn iso(ms : Int64) -> String {
  @time.format_iso_ms(ms)
}

///|
/// The tool's call for session `key` (`world`: None while the station starts): what it answers the agent.
pub async fn feishu_api_run(
  world : ToolWorld?,
  is_feishu : (String) -> Bool,
  key : String,
  args : JV,
) -> String {
  guard world is Some(h) else {
    raise FeishuError("the station is starting; try again in a moment")
  }
  let meth = trim_js(
    match args.get("method") {
      None => ""
      Some(v) => js_string_arg(v)
    },
  )
  let params = match args.get("params") {
    Some(Obj(_) as p) => p
    _ => Obj([])
  }
  let split = split_space(meth)
  let path = if split.length() > 1 { split[1] } else { "" }
  let verb = ascii_upper(split[0])
  for p in managing {
    if starts(path, p) {
      raise FeishuError(
        "\{path} is not for agents: it manages the Feishu app itself",
      )
    }
  }
  if verb != "GET" &&
    starts(path, "/open-apis/im/v1/messages") &&
    !reactions_path(path) {
    raise FeishuError(
      "send, answer and change messages with chat_post (it keeps what is said in the conversation); feishu_api reads messages and adds reactions",
    )
  }
  let connect = match args.get("to") {
    Some(Str(to)) if to != "" => Some((h.target)(key, Str(to)))
    _ => {
      let own = match (h.session)(key) {
        Some((c, _)) => c
        None => None
      }
      match own {
        Some(c) if is_feishu(c) => Some(c)
        _ => {
          let mut found = None
          for c in (h.recent_connects)(key) {
            if is_feishu(c) {
              found = Some(c)
              break
            }
          }
          found
        }
      }
    }
  }
  guard connect is Some(connect) && is_feishu(connect) else {
    raise FeishuError(
      "this session has no Feishu conversation: give to= one of your Feishu chats",
    )
  }
  guard (h.chat_api)(connect) is Some(api) else {
    raise FeishuError("this Feishu connect is not connected")
  }
  match api(meth, params) {
    File(bytes, content_type, disposition) => {
      guard (h.session)(key) is Some((_, workspace)) else {
        raise FeishuError("this session no longer exists")
      }
      let dir = @nodepath.join(h.sep, [workspace, "uploads"])
      (h.disk.mkdir)(dir)
      let stamp = replace_every(
        replace_every(slice_js(iso((h.now)()), 0, b=19), ":", "-"),
        ".",
        "-",
      )
      let path = @nodepath.join(h.sep, [
        dir,
        "\{stamp}-\{(h.uuid)()}-\{file_name(content_type, disposition)}",
      ])
      (h.disk.put_new)(path, bytes)
      stringify(
        jobj([
          ("path", Some(js(path))),
          ("content_type", Some(js(content_type))),
          ("size", Some(jint(bytes.length()))),
        ]),
      )
    }
    Data(result) => {
      let t = stringify(result)
      let chars = points(t)
      if chars.length() > 60_000 {
        chars[0:60_000].to_array().join("") +
        "… (cut at 60000 characters; ask for less, e.g. a smaller page_size)"
      } else {
        t
      }
    }
  }
}
