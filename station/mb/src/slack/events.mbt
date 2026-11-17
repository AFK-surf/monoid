// What Slack says, as the station takes it (station/src/slack/surface.ts, its functions of no connection): who the bot
// is, a message's words (its tables too) and files, an event of Socket Mode as a chat's event, a person.

///|
/// Who a bot token belongs to, as Slack reports it (connects/connections.ts `BotIdentity`): its workspace and its
/// address, its bot user, name and picture, and its app's bot id (B…).
pub(all) struct BotIdentity {
  team : String
  team_id : String
  url : String
  bot_user_id : String
  bot_name : String
  bot_image : String?
  bot_id : String
}

///|
pub fn BotIdentity::to_j(self : BotIdentity) -> J {
  jo([
    ("team", js(self.team)),
    ("teamId", js(self.team_id)),
    ("url", js(self.url)),
    ("botUserId", js(self.bot_user_id)),
    ("botName", js(self.bot_name)),
    ("botImage", jopt(self.bot_image)),
    ("botId", js(self.bot_id)),
  ])
}

///|
fn first_string(values : Array[J?], ok : (String) -> Bool) -> String? {
  for v in values {
    match str_of(v) {
      Some(s) if ok(s) => return Some(s)
      _ => ()
    }
  }
  None
}

///|
/// Who the bot is, and where: its name as people see it in that workspace (not its handle), when Slack says.
pub async fn identity_of(client : SlackClient, token : String) -> BotIdentity {
  let auth = client.api("auth.test", [], token)
  let bot_user_id = text(at(Some(auth), "user_id"))
  let user = {
    let d = client.api("users.info", [("user", bot_user_id)], token)
    match at(Some(d), "user") {
      None | Some(Null) => None
      u => u
    }
  } catch {
    _ => None
  }
  let profile = match at(user, "profile") {
    None | Some(Null) => None
    p => p
  }
  let shown = first_string([at(profile, "display_name"), at(user, "real_name"), at(profile, "real_name")], n => trim(n) !=
    "")
  let image = first_string([at(profile, "image_72"), at(profile, "image_48"), at(profile, "image_original")], u => u.has_prefix(
    "https://",
  ))
  {
    team: text(at(Some(auth), "team")),
    team_id: text(at(Some(auth), "team_id")),
    url: text(at(Some(auth), "url")),
    bot_user_id,
    bot_name: shown.unwrap_or(text(at(Some(auth), "user"))),
    bot_image: image,
    bot_id: text(at(Some(auth), "bot_id")),
  }
}

///|
/// Checks a token pair without connecting: the bot token must authenticate, and the app-level token must be allowed
/// to open a Socket Mode connection. Its problems are said in `lang`.
pub async fn verify_slack_tokens(
  words : Words,
  client : SlackClient,
  app_token : String,
  bot_token : String,
  lang : String,
) -> (J?, Array[String]) {
  let errors = []
  let mut identity : J? = None
  if !bot_token.has_prefix("xoxb-") {
    errors.push(words.tr(lang, "station.slackTokens.botPrefix"))
  } else {
    match (try Ok(identity_of(client, bot_token)) catch { e => Err(e) }) {
      Ok(i) => identity = Some(i.to_j())
      Err(e) => errors.push(words.tr(lang, "station.slackTokens.botInvalid", args=[("error", message_of(e))]))
    }
  }
  if !app_token.has_prefix("xapp-") {
    errors.push(words.tr(lang, "station.slackTokens.appPrefix"))
  } else {
    match (try Ok(client.api("apps.connections.open", [], app_token)) catch { e => Err(e) }) {
      Ok(_) => ()
      Err(e) => errors.push(words.tr(lang, "station.slackTokens.appNoSocket", args=[("error", message_of(e))]))
    }
  }
  (identity, errors)
}

///|
/// A rich_text element as Slack's own text writes it (links <url|label>, mentions <@U…>), so it reads like the rest.
fn rich_text(el : J?) -> String {
  let kind = text(at(el, "type"))
  match at(el, "elements") {
    Some(Arr(xs)) => {
      let inner = xs.map(x => rich_text(Some(x)))
      if kind == "rich_text_list" {
        return inner.map(s => "• \{s}").join("\n")
      }
      return inner.join(if kind == "rich_text" { "\n" } else { "" })
    }
    _ => ()
  }
  match kind {
    "text" => text(at(el, "text"))
    "link" =>
      if truthy(at(el, "text")) {
        "<\{text(at(el, "url"))}|\{text(at(el, "text"))}>"
      } else {
        "<\{text(at(el, "url"))}>"
      }
    "user" => "<@\{text(at(el, "user_id"))}>"
    "usergroup" => "<!subteam^\{text(at(el, "usergroup_id"))}>"
    "channel" => "<#\{text(at(el, "channel_id"))}>"
    "broadcast" => "<!\{text(at(el, "range"))}>"
    "emoji" => ":\{text(at(el, "name"))}:"
    "date" => text(at(el, "fallback"))
    _ => text(at(el, "text"))
  }
}

///|
/// A table cell's content on one line, its pipes kept from closing the cell (those inside <url|label> stay as Slack's).
fn cell_text(cell : J?) -> String {
  let kind = text(at(cell, "type"))
  let raw = if kind == "rich_text" {
    rich_text(cell)
  } else if kind == "raw_number" {
    match at(cell, "number") {
      None | Some(Null) =>
        match at(cell, "text") {
          None | Some(Null) => ""
          t => js_str(t)
        }
      n => js_str(n)
    }
  } else {
    text(at(cell, "text"))
  }
  trim(escape_pipes(join_lines(raw)))
}

///|
/// `s.replace(/\s*\n\s*/g, " ")`.
fn join_lines(s : String) -> String {
  let n = s.length()
  let out = StringBuilder::new()
  let mut i = 0
  while i < n {
    // a run of white space holding a line break: one space
    if @jscase.is_space(s.unsafe_charcode_at(i)) {
      let mut j = i
      let mut nl = false
      while j < n && @jscase.is_space(s.unsafe_charcode_at(j)) {
        if s.unsafe_charcode_at(j) == '\n'.to_int() {
          nl = true
        }
        j += 1
      }
      if nl {
        // (the run's spaces before its first break and after its last go with it; any between breaks too)
        out.write_char(' ')
      } else {
        out.write_string(s.unsafe_substring(start=i, end=j))
      }
      i = j
      continue
    }
    out.write_char(s.unsafe_charcode_at(i).unsafe_to_char())
    i += 1
  }
  out.to_string()
}

///|
/// `s.replace(/(<[^<>]*>)|\|/g, (m, slack) => slack ?? "\\|")`.
fn escape_pipes(s : String) -> String {
  let n = s.length()
  let out = StringBuilder::new()
  let mut i = 0
  while i < n {
    let c = s.unsafe_charcode_at(i)
    if c == '<'.to_int() {
      let mut j = i + 1
      while j < n && s.unsafe_charcode_at(j) != '<'.to_int() && s.unsafe_charcode_at(j) != '>'.to_int() {
        j += 1
      }
      if j < n && s.unsafe_charcode_at(j) == '>'.to_int() {
        out.write_string(s.unsafe_substring(start=i, end=j + 1))
        i = j + 1
        continue
      }
    }
    if c == '|'.to_int() {
      out.write_string("\\|")
    } else {
      out.write_char(c.unsafe_to_char())
    }
    i += 1
  }
  out.to_string()
}

///|
/// A table block as a Markdown table, its first row the header (as Slack shows it).
fn table_text(block : J?) -> String {
  let rows = arr(at(block, "rows")).map(row => match row {
    Arr(cells) => cells.map(c => cell_text(Some(c)))
    _ => []
  })
  if rows.length() == 0 {
    return ""
  }
  let mut width = rows[0].length()
  for r in rows {
    if r.length() > width {
      width = r.length()
    }
  }
  let line = (r : Array[String]) => {
    let cells = []
    for i in 0..<width {
      cells.push(if i < r.length() { r[i] } else { "" })
    }
    "| \{cells.join(" | ")} |"
  }
  let dashes = []
  for _ in 0..<width {
    dashes.push("---")
  }
  ([line(rows[0]), line(dashes)] + rows[1:].to_array().map(line)).join("\n")
}

///|
/// What a message says: its text, and the tables in its blocks and attachments, which Slack leaves out of the text.
pub fn message_text(m : J?) -> String {
  let blocks = arr(at(m, "blocks")) + arr(at(m, "attachments")).map(a => arr(at(Some(a), "blocks"))).flatten()
  let tables = blocks
    .filter(b => str_of(at(Some(b), "type")) == Some("table"))
    .map(b => table_text(Some(b)))
    .filter(t => t != "")
  ([text(at(m, "text"))] + tables).filter(t => t != "").join("\n\n")
}

///|
/// The files shared with a message (`{id, name, size, url}`). Ones Slack keeps back or that live elsewhere have no url.
pub fn message_files(m : J?) -> Array[J] {
  arr(at(m, "files"))
  .filter(f => text(at(Some(f), "id")) != "")
  .map(f => {
    let ff = Some(f)
    let held = !["tombstone", "hidden_by_limit", "external"].contains(text(at(ff, "mode")))
    let url = match text(at(ff, "url_private_download")) {
      "" => text(at(ff, "url_private"))
      u => u
    }
    let name = match text(at(ff, "name")) {
      "" =>
        match text(at(ff, "title")) {
          "" => text(at(ff, "id"))
          t => t
        }
      n => n
    }
    jo([
      ("id", js(text(at(ff, "id")))),
      ("name", js(name)),
      (
        "size",
        match at(ff, "size") {
          Some(Num(_) as n) => n
          _ => ji(0)
        },
      ),
      ("url", if held && url != "" { js(url) } else { Null }),
    ])
  })
}

///|
/// The files of a Web API answer: its messages' (conversations.replies, conversations.history), or a message's or a
/// file's.
pub fn answer_files(answer : J?) -> Array[J] {
  let messages : Array[J?] = arr(at(answer, "messages")).map(m => Some(m))
  messages.push(at(answer, "message"))
  messages.push(Some(jo([("files", ja([at(answer, "file").unwrap_or(Null)]))])))
  messages.map(message_files).flatten()
}

///|
/// Whether `s` is a number as /^\d+(?:\.\d+)?$/ has one.
fn plain_number(s : String) -> Bool {
  let parts = s.split(".").map(p => p.to_string()).to_array()
  let digits = (p : String) => p != "" && p.iter().all(c => c >= '0' && c <= '9')
  match parts {
    [a] => digits(a)
    [a, b] => digits(a) && digits(b)
    _ => false
  }
}

///|
/// A Slack event as the station takes it (surface.ts `toEvent`): someone's message (a person, or another app's bot),
/// an edit, a stop of its agent's session, or nothing it keeps (its own messages, deletes). `bot_id`: this app's bot
/// id (B…).
pub fn to_event(event : J?, bot_user_id : String, bot_id : String) -> J? {
  // A message this bot posted itself: the station records those as it posts them.
  let own = (e : J?) => {
    let mine_by = (key : String, mine : String) => mine != "" && str_of(at(e, key)) == Some(mine)
    mine_by("user", bot_user_id) || mine_by("bot_id", bot_id)
  }
  let kind = text(at(event, "type"))
  let subtype = str_of(at(event, "subtype"))
  if kind == "agent_session_stopped" {
    let channel = text(at(event, "channel"))
    let thread_ts = text(at(event, "thread_ts"))
    let ts = text(at(event, "event_ts"))
    if channel == "" || thread_ts == "" || !plain_number(ts) || js_num(Some(js(ts))).is_inf() {
      return None
    }
    return Some(jo([("type", js("stop")), ("channel", js(channel)), ("threadTs", js(thread_ts)), ("ts", js(ts))]))
  }
  if kind == "message" && subtype == Some("message_changed") {
    let changed = match at(event, "message") {
      None | Some(Null) => None
      c => c
    }
    let ts = text(at(changed, "ts"))
    if ts == "" || own(changed) {
      return None
    }
    // A message outside any thread is the root of its own.
    let thread_ts = match str_of(at(changed, "thread_ts")) {
      Some(t) => t
      None => ts
    }
    return Some(
      jo([
        ("type", js("changed")),
        ("channel", js(text(at(event, "channel")))),
        ("threadTs", js(thread_ts)),
        ("ts", js(ts)),
        ("text", js(message_text(changed))),
      ]),
    )
  }
  // The station has no retraction: a deleted message stays as it was said.
  if kind == "message" && subtype == Some("message_deleted") {
    return None
  }
  if kind != "app_mention" && kind != "message" {
    return None
  }
  // Message subtypes that are someone talking: a person, or another app's bot.
  let talking = match subtype {
    None => true
    Some(s) => s == "file_share" || s == "thread_broadcast" || s == "bot_message"
  }
  if !talking || own(event) {
    return None
  }
  // Its bot user when Slack gives one, else its bot id.
  let by = match at(event, "user") {
    None | Some(Null) => at(event, "bot_id")
    u => u
  }
  let user = text(by)
  if user == "" {
    return None
  }
  let body = message_text(event)
  let ts = text(at(event, "ts"))
  let files = message_files(event)
  let message = [
    ("channel", js(text(at(event, "channel")))),
    (
      "threadTs",
      js(
        match str_of(at(event, "thread_ts")) {
          Some(t) => t
          None => ts
        },
      ),
    ),
    ("ts", js(ts)),
    ("user", js(user)),
    ("text", js(body)),
    (
      "addressed",
      jb(kind == "app_mention" || str_of(at(event, "channel_type")) == Some("im") || body.contains("<@\{bot_user_id}>")),
    ),
  ]
  if files.length() > 0 {
    message.push(("files", ja(files)))
  }
  Some(jo([("type", js("message")), ("message", jo(message))]))
}

///|
/// The name a users.info answer gives a person, their email and their profile picture (`{name, email, picture}`).
pub fn person_of(answer : J?) -> J {
  let u = match at(answer, "user") {
    None | Some(Null) => None
    x => x
  }
  let p = match at(u, "profile") {
    None | Some(Null) => None
    x => x
  }
  let name = first_string([at(p, "display_name"), at(u, "real_name"), at(u, "name")], n => n != "").unwrap_or("")
  jo([("name", js(name)), ("email", js(lower(text(at(p, "email"))))), ("picture", js(text(at(p, "image_72"))))])
}

///|
/// What a card that stopped waiting says under its words (connects/card-ends.ts `endedWords`): why it is closed
/// (`end`: `{why, by?, byTs?}`; `name`: who wrote the message that closed it, when known).
pub fn ended_words(words : Words, card : J?, end : J?, name : String?, lang : String) -> String {
  match text(at(end, "why")) {
    "message" => {
      let key = if str_of(at(card, "type")) == Some("text") { "station.card.replied" } else { "station.card.endedByMessage" }
      match name {
        Some(n) if n != "" => words.tr(lang, key, args=[("name", n)])
        _ => words.tr(lang, "\{key}Bare")
      }
    }
    "replaced" => words.tr(lang, "station.card.endedReplaced")
    "withdrawn" => words.tr(lang, "station.card.endedWithdrawn")
    _ => words.tr(lang, "station.card.endedClosed")
  }
}

///|
/// A number as Rust's `str::parse::<f64>` reads one (a Slack ts); None where it does not.
fn ts_number(s : String) -> Double? {
  // /^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/
  let n = s.length()
  let mut i = 0
  let at_ = (k : Int) => if k < n { s.unsafe_charcode_at(k) } else { -1 }
  let digit = (c : Int) => c >= '0'.to_int() && c <= '9'.to_int()
  if at_(i) == '+'.to_int() || at_(i) == '-'.to_int() {
    i += 1
  }
  let start = i
  while digit(at_(i)) {
    i += 1
  }
  let whole = i > start
  if whole {
    if at_(i) == '.'.to_int() {
      i += 1
      while digit(at_(i)) {
        i += 1
      }
    }
  } else {
    if at_(i) != '.'.to_int() {
      return None
    }
    i += 1
    let f = i
    while digit(at_(i)) {
      i += 1
    }
    if i == f {
      return None
    }
  }
  if at_(i) == 'e'.to_int() || at_(i) == 'E'.to_int() {
    i += 1
    if at_(i) == '+'.to_int() || at_(i) == '-'.to_int() {
      i += 1
    }
    let e = i
    while digit(at_(i)) {
      i += 1
    }
    if i == e {
      return None
    }
  }
  if i != n {
    return None
  }
  Some(js_num(Some(js(s))))
}
