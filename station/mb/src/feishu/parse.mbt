// What Feishu's events say, as the station takes them (station/src/feishu/parse.ts, 「收到的内容」): someone's
// message in a chat or a topic, with its text and files, or an answer from a card's button or form.

///|
/// A file in a message, as the station's chats keep it (sessions/chat.ts `InboundFile`).
#derive(Eq, Debug)
pub(all) struct InboundFile {
  id : String
  name : String
  size : Int
  url : String?
}

///|
pub fn InboundFile::to_jv(self : InboundFile) -> JV {
  jobj([
    ("id", Some(js(self.id))),
    ("name", Some(js(self.name))),
    ("size", Some(jint(self.size))),
    ("url", Some(jopt(self.url))),
  ])
}

///|
/// A message as Feishu gave it, before the station puts it in a thread.
pub(all) struct FeishuMessage {
  chat : String
  /// The topic it is in (omt_…), or None: said in the chat itself.
  topic : String?
  /// The topic's first message, for replying in it.
  root : String?
  /// The message it replies to (quotes), or None.
  parent : String?
  id : String
  user : String
  text : String
  /// A direct message, or one that @s the bot.
  addressed : Bool
  /// The person asked for a new session (「新会话」, /new) with it.
  fresh : Bool
  p2p : Bool
  files : Array[InboundFile]
  /// When it was said (ms), as Feishu says.
  at : Double
}

///|
pub fn FeishuMessage::to_jv(self : FeishuMessage) -> JV {
  jobj([
    ("chat", Some(js(self.chat))),
    ("topic", Some(jopt(self.topic))),
    ("root", Some(jopt(self.root))),
    ("parent", Some(jopt(self.parent))),
    ("id", Some(js(self.id))),
    ("user", Some(js(self.user))),
    ("text", Some(js(self.text))),
    ("addressed", Some(Bool(self.addressed))),
    ("fresh", Some(Bool(self.fresh))),
    ("p2p", Some(Bool(self.p2p))),
    ("files", Some(Arr(self.files.map(f => f.to_jv())))),
    ("at", Some(Num(self.at))),
  ])
}

///|
/// A card's button pressed, or its form sent.
pub(all) struct CardAnswer {
  chat : String
  message : String
  user : String
  event : String
  value : JV
  form : JV
}

///|
pub fn CardAnswer::to_jv(self : CardAnswer) -> JV {
  jobj([
    ("chat", Some(js(self.chat))),
    ("message", Some(js(self.message))),
    ("user", Some(js(self.user))),
    ("event", Some(js(self.event))),
    ("value", Some(self.value)),
    ("form", Some(self.form)),
  ])
}

///|
/// A file the station fetches later: its message, its key and Feishu's kind of resource, in `url`.
pub fn resource_url(message : String, key : String, kind : String) -> String {
  "feishu:\{kind}:\{message}:\{key}"
}

///|
/// `/^feishu:(image|file):([^:]+):(.+)$/` on `url`: its kind, message and key.
pub fn resource_of(url : String) -> (String, String, String)? {
  let kind = if starts(url, "feishu:image:") {
    "image"
  } else if starts(url, "feishu:file:") {
    "file"
  } else {
    return None
  }
  let rest = url.unsafe_substring(start=7 + kind.length() + 1, end=url.length())
  // ([^:]+): the message, up to the first colon (at least one character); (.+): the rest, no line terminator in it
  let mut colon = -1
  for i in 0..<rest.length() {
    if rest.unsafe_charcode_at(i) == ':' {
      colon = i
      break
    }
  }
  if colon <= 0 {
    return None
  }
  let message = rest.unsafe_substring(start=0, end=colon)
  let key = rest.unsafe_substring(start=colon + 1, end=rest.length())
  if key == "" {
    return None
  }
  // `.` takes no line terminator, `$` ends the input: none of them may be in the key, nor in the message (`[^:]`
  // takes them, but the whole must match, and the key's part is after the message's)
  for i in 0..<key.length() {
    if key.unsafe_charcode_at(i) is (0x0a | 0x0d | 0x2028 | 0x2029) {
      return None
    }
  }
  Some((kind, message, key))
}

///|
/// 「新会话」, /new: `/^(新会话|新对话|new session|\/new)$/i`.
fn new_session(s : String) -> Bool {
  if s == "新会话" || s == "新对话" {
    return true
  }
  let l = ascii_lower(s)
  l == "new session" || l == "/new"
}

///|
/// ASCII letters lowered (what `/i` takes as the same, for these words).
fn ascii_lower(s : String) -> String {
  let out = StringBuilder::new()
  for i in 0..<s.length() {
    let c = s.unsafe_charcode_at(i)
    out.write_char(
      (if c >= 'A' && c <= 'Z' { c + 32 } else { c }).unsafe_to_char(),
    )
  }
  out.to_string()
}

///|
/// `@_user_1` and the like as `@name`; whether the bot was among them.
fn with_mentions(said : String, mentions : Array[JV], bot : String) -> (String, Bool) {
  let mut addressed = false
  let mut out = said
  for m in mentions {
    let key = text(jget(Some(m), "key"))
    if key == "" {
      continue
    }
    let open = text(jget(jget(Some(m), "id"), "open_id"))
    if open != "" && open == bot {
      addressed = true
    }
    let name = text(jget(Some(m), "name"))
    out = replace_every(out, key, "@" + (if name != "" { name } else { open }))
  }
  (out, addressed)
}

///|
/// `/\n$/`'s one newline off the end.
fn without_last_newline(s : String) -> String {
  if s.length() > 0 && s.unsafe_charcode_at(s.length() - 1) == '\n' {
    s.unsafe_substring(start=0, end=s.length() - 1)
  } else {
    s
  }
}

///|
/// `styles.includes(word)`.
fn styled(styles : Array[JV], word : String) -> Bool {
  styles.iter().any(s => s == Str(word))
}

///|
/// A rich text (`post`) as Markdown, its images and videos as files.
fn post_text(
  content : JV,
  message : String,
  bot : String,
) -> (String, Array[InboundFile], Bool) {
  // Received posts are `{title, content}`; ones of other shapes keep a language level (`{zh_cn: {title, content}}`).
  let body : JV = if jget(Some(content), "content") is Some(Arr(_)) {
    content
  } else {
    let mut found : JV? = None
    for v in jvalues(nullish(Some(content), Obj([]))) {
      if jget(Some(v), "content") is Some(Arr(_)) {
        found = Some(v)
        break
      }
    }
    found.unwrap_or(Obj([]))
  }
  let files = []
  let mut addressed = false
  let lines = []
  let title = trim_js(text(jget(Some(body), "title")))
  if title != "" {
    lines.push("**\{title}**")
  }
  for paragraph in jitems(jget(Some(body), "content")) {
    let line = StringBuilder::new()
    for el in jitems(Some(paragraph)) {
      let e = Some(el)
      let tag = text(jget(e, "tag"))
      let styles = jitems(jget(e, "style"))
      if tag == "text" {
        let mut t = text(jget(e, "text"))
        if styled(styles, "bold") {
          t = "**\{t}**"
        }
        if styled(styles, "italic") {
          t = "*\{t}*"
        }
        if styled(styles, "lineThrough") {
          t = "~~\{t}~~"
        }
        line.write_string(t)
      } else if tag == "a" {
        let t = text(jget(e, "text"))
        let href = text(jget(e, "href"))
        line.write_string("[\{if t != "" { t } else { href }}](\{href})")
      } else if tag == "at" {
        let user_id = text(jget(e, "user_id"))
        let id = if user_id != "" { user_id } else { text(jget(e, "open_id")) }
        if id != "" && id == bot {
          addressed = true
        }
        let name = text(jget(e, "user_name"))
        line.write_string("@" + (if name != "" { name } else { id }))
      } else if tag == "img" {
        let key = text(jget(e, "image_key"))
        if key != "" {
          files.push({
            id: key,
            name: "\{key}.png",
            size: 0,
            url: Some(resource_url(message, key, "image")),
          })
        }
      } else if tag == "media" {
        let key = text(jget(e, "file_key"))
        if key != "" {
          let name = text(jget(e, "file_name"))
          files.push({
            id: key,
            name: if name != "" { name } else { "\{key}.mp4" },
            size: 0,
            url: Some(resource_url(message, key, "file")),
          })
        }
      } else if tag == "code_block" {
        let language = @jscase.lower(text(jget(e, "language")))
        let code = without_last_newline(text(jget(e, "text")))
        line.write_string("\n```\{language}\n\{code}\n```\n")
      } else if tag == "md" {
        line.write_string(text(jget(e, "text")))
      } else if tag == "emotion" {
        line.write_string("[\{text(jget(e, "emoji_type"))}]")
      } else if tag == "hr" {
        line.write_string("\n---\n")
      }
    }
    lines.push(line.to_string())
  }
  (trim_js(lines.join("\n")), files, addressed)
}

///|
/// `.replace(/@\S+/g, "")`: each `@` and the run of what is not white space after it (at least one) taken out.
fn without_at_words(s : String) -> String {
  let out = StringBuilder::new()
  let n = s.length()
  let mut i = 0
  while i < n {
    let c = s.unsafe_charcode_at(i)
    if c == '@' && i + 1 < n && !is_js_space(s.unsafe_charcode_at(i + 1)) {
      i += 1
      while i < n && !is_js_space(s.unsafe_charcode_at(i)) {
        i += 1
      }
      continue
    }
    out.write_char(c.unsafe_to_char())
    i += 1
  }
  out.to_string()
}

///|
/// An `im.message.receive_v1` event as a message, or None where it is none of the station's (the bot's own, another
/// app's). `bot`: the bot's open_id.
pub fn message_of(event : JV?, bot : String) -> FeishuMessage? {
  let sender = jget(event, "sender")
  let m = jget(event, "message")
  // An app's messages (this bot's own among them) are not someone talking to it.
  if text(jget(sender, "sender_type")) != "user" {
    return None
  }
  let user = text(jget(jget(sender, "sender_id"), "open_id"))
  let id = text(jget(m, "message_id"))
  let chat = text(jget(m, "chat_id"))
  if user == "" || id == "" || chat == "" {
    return None
  }
  let raw_content = text(jget(m, "content"))
  let content = try_parse(if raw_content != "" { raw_content } else { "{}" }).unwrap_or(
    Obj([]),
  )
  let kind = text(jget(m, "message_type"))
  let mentions = jitems(jget(m, "mentions"))
  let mentions_bot = () => mentions.iter().any(x => text(jget(jget(Some(x), "id"), "open_id")) == bot)
  let files = []
  let mut said = ""
  let mut addressed = false
  if kind == "text" {
    let (t, a) = with_mentions(text(jget(Some(content), "text")), mentions, bot)
    said = t
    addressed = a
  } else if kind == "post" {
    let (t, f, a) = post_text(content, id, bot)
    said = t
    files.append(f)
    addressed = a || mentions_bot()
  } else if kind == "image" {
    let key = text(jget(Some(content), "image_key"))
    if key != "" {
      files.push({
        id: key,
        name: "\{key}.png",
        size: 0,
        url: Some(resource_url(id, key, "image")),
      })
    }
  } else if kind == "file" || kind == "audio" || kind == "media" {
    let key = text(jget(Some(content), "file_key"))
    let fallback = if kind == "audio" {
      "\{key}.opus"
    } else if kind == "media" {
      "\{key}.mp4"
    } else {
      key
    }
    if key != "" {
      let name = text(jget(Some(content), "file_name"))
      files.push({
        id: key,
        name: if name != "" { name } else { fallback },
        size: 0,
        url: Some(resource_url(id, key, "file")),
      })
    }
  } else {
    said = "[\{if kind != "" { kind } else { "message" }}]"
  }
  if kind != "text" && kind != "post" {
    addressed = mentions_bot()
  }
  let p2p = text(jget(m, "chat_type")) == "p2p"
  // What it says besides its mentions (a bot's name may have spaces: its placeholder is what is taken out).
  let raw = if kind == "text" { text(jget(Some(content), "text")) } else { said }
  let mut stripped = raw
  for x in mentions {
    let key = text(jget(Some(x), "key"))
    stripped = replace_every(stripped, if key != "" { key } else { "\u{0}" }, "")
  }
  let bare = trim_js(without_at_words(stripped))
  let fresh = (addressed || p2p) && new_session(bare)
  let topic = text(jget(m, "thread_id"))
  let root = text(jget(m, "root_id"))
  let parent = text(jget(m, "parent_id"))
  let at = js_number(text(jget(m, "create_time")))
  Some({
    chat,
    topic: if topic == "" { None } else { Some(topic) },
    root: if root != "" { Some(root) } else { None },
    parent: if parent != "" { Some(parent) } else { None },
    id,
    user,
    text: said,
    addressed: addressed || p2p,
    fresh,
    p2p,
    files,
    at: if at.is_nan() || at == 0.0 { 0.0 } else { at },
  })
}

///|
/// `{...v}` of any value: an object's own fields, an array's or a string's by index, nothing of anything else.
fn spread_of(v : JV?) -> JV {
  let o = JV::Obj([])
  match v {
    Some(Obj(fields)) => for f in fields { jput(o, f.0, f.1) }
    Some(Arr(a)) => for i, x in a { jput(o, i.to_string(), x) }
    Some(Str(s)) =>
      for i in 0..<s.length() {
        jput(o, i.to_string(), Str(s.unsafe_substring(start=i, end=i + 1)))
      }
    _ => ()
  }
  o
}

///|
/// `{key: undefined}` as JavaScript keeps it and JSON.stringify leaves it out: a field set to `v`, or taken out of
/// the object's keys while keeping its place where it was there (undefined), as one never there where it was not.
fn put_maybe(o : JV, k : String, v : JV?) -> Unit {
  match v {
    Some(x) => jput(o, k, x)
    None => jdelete(o, k)
  }
}

///|
/// A message as the OpenAPI lists it (`GET /im/v1/messages`) in the shape its event has: what `message_of` reads.
/// An object of `undefined` fields where the TypeScript put them (which JSON leaves out) has them left out.
pub fn listed_as_event(item : JV?) -> JV {
  let sender = nullish(jget(item, "sender"), Obj([]))
  let sender_type = if text(jget(Some(sender), "sender_type")) == "app" {
    "app"
  } else {
    "user"
  }
  let message = spread_of(item)
  put_maybe(message, "content", jget(jget(item, "body"), "content"))
  put_maybe(message, "message_type", jget(item, "msg_type"))
  let mentions = jitems(jget(item, "mentions")).map(x => {
    let id = match jget(Some(x), "id") {
      Some(Str(s)) => Some(jobj([("open_id", Some(Str(s)))]))
      other => other
    }
    jobj([
      ("key", jget(Some(x), "key")),
      ("name", jget(Some(x), "name")),
      ("id", id),
    ])
  })
  jput(message, "mentions", Arr(mentions))
  jobj([
    (
      "sender",
      Some(
        jobj([
          ("sender_type", Some(js(sender_type))),
          (
            "sender_id",
            Some(jobj([("open_id", Some(js(text(jget(Some(sender), "id")))))])),
          ),
        ]),
      ),
    ),
    ("message", Some(message)),
  ])
}

///|
/// A `card.action.trigger` event: who answered which card.
pub fn card_answer_of(event : JV?, event_id : String) -> CardAnswer? {
  let user = text(jget(jget(event, "operator"), "open_id"))
  let chat = text(jget(jget(event, "context"), "open_chat_id"))
  let message = text(jget(jget(event, "context"), "open_message_id"))
  if user == "" || chat == "" {
    return None
  }
  let value = nullish(jget(jget(event, "action"), "value"), Null)
  let form = nullish(jget(jget(event, "action"), "form_value"), Null)
  Some({ chat, message, user, event: event_id, value, form })
}
