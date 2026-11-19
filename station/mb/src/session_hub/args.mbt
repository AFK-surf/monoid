// The agents' tool arguments as the station reads them (station/src/sessions/args.ts): how a turn ends (`kind`, in
// today's words and those from before), what goes with it (`need`, `done`, `about`), the card a post carries (`card`,
// or `options` from before cards; JSON text from a runtime whose tool list is older), and how posts with files are
// kept. Every rule and every word of what an agent is told when it is refused is the TypeScript's (the Rust station's).

///|
/// What refused a call, in the words the agent (or the person) is told.
pub(all) suberror Refused {
  Refused(String)
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for Refused with output(self, logger) {
  match self {
    Refused(m) => logger.write_string(m)
  }
}

///|
pub fn Refused::message(self : Refused) -> String {
  match self {
    Refused(m) => m
  }
}

///|
fn refuse(message : String) -> Refused {
  Refused(message)
}

///|
/// How long an agent may say it waits (chat_state "waiting").
pub let min_wait_seconds : Int = 10

///|
pub let max_wait_seconds : Int = 3600

///|
/// How many answers a decision may offer.
pub let max_options : Int = 6

///|
let cards : Array[String] = ["options", "text", "login"]

///|
let max_placeholder : Int = 80

///|
let min_reason : Int = 6

///|
/// actor.ts `parseDeclared`: a kind as kept or given, the words from before these included: `{kind}` (with `seconds`
/// for waiting) as JSON.
pub fn parse_declared(kind : String, wait : Double) -> Json? {
  match kind {
    "all_done" | "final" => Some({ "kind": "all_done" })
    "need_human" | "need_help" | "block" | "need_decision" => Some({ "kind": "need_help" })
    "waiting" => Some({ "kind": "waiting", "seconds": num(wait) })
    _ => None
  }
}

///|
/// `jsNumber`: a number, or a string holding one.
pub fn js_number(value : Json) -> Double? {
  match value {
    Number(n, ..) => Some(n)
    String(s) => {
      let t = trim(s)
      let l = @jscase.lower(t)
      let unsigned = if l.has_prefix("+") || l.has_prefix("-") { slice(l, 1) } else { l }
      if unsigned == "inf" || unsigned == "infinity" {
        return Some(if t.has_prefix("-") { @double.neg_infinity } else { @double.infinity })
      }
      if unsigned == "nan" {
        return Some(@double.not_a_number)
      }
      if decimal_text(t) {
        Some(@string.parse_double(t) catch { _ => return None })
      } else {
        None
      }
    }
    _ => None
  }
}

///|
/// /^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/
fn decimal_text(t : String) -> Bool {
  let n = t.length()
  let mut i = 0
  let at = (k : Int) => if k < n { u(t, k) } else { -1 }
  if at(i) == '+'.to_int() || at(i) == '-'.to_int() {
    i += 1
  }
  let mut whole = 0
  while is_digit_unit(at(i)) {
    i += 1
    whole += 1
  }
  if whole > 0 {
    if at(i) == '.'.to_int() {
      i += 1
      while is_digit_unit(at(i)) {
        i += 1
      }
    }
  } else {
    if at(i) != '.'.to_int() {
      return false
    }
    i += 1
    let mut frac = 0
    while is_digit_unit(at(i)) {
      i += 1
      frac += 1
    }
    if frac == 0 {
      return false
    }
  }
  if at(i) == 'e'.to_int() || at(i) == 'E'.to_int() {
    i += 1
    if at(i) == '+'.to_int() || at(i) == '-'.to_int() {
      i += 1
    }
    let mut exp = 0
    while is_digit_unit(at(i)) {
      i += 1
      exp += 1
    }
    if exp == 0 {
      return false
    }
  }
  i == n
}

///|
/// `declaredStr`.
pub fn declared_str(kind : Json) -> String {
  match str_of(kind, "kind") {
    Some("all_done") => "all_done"
    Some("need_help") => "need_help"
    _ => "waiting"
  }
}

///|
/// `saidAs`: a state in the words agents are told (need_human is kept as need_help, the word clients read).
pub fn said_as(kind : Json) -> String {
  if str_of(kind, "kind") == Some("need_help") {
    "need_human"
  } else {
    declared_str(kind)
  }
}

///|
/// `stateArg`: how a post or chat_state ends the turn (`kind`), and in which words ("now", "before", "decision").
/// Waiting is chat_state's own.
pub fn state_arg(value : Json?) -> (Json, String)? raise Refused {
  match value {
    None | Some(Null) | Some(String("")) => return None
    Some(String(v)) if v != "waiting" =>
      match parse_declared(v, 0.0) {
        Some(kind) => {
          let said = if v == "final" || v == "block" {
            "before"
          } else if v == "need_decision" {
            "decision"
          } else {
            "now"
          }
          return Some((kind, said))
        }
        None => ()
      }
    _ => ()
  }
  raise refuse(
    "kind must be \"all_done\" or \"need_human\" (or \"waiting\", with chat_state), got \{js_json(value.unwrap())}",
  )
}

///|
let empty_reasons : Array[String] = [
  "做完了", "已完成", "全部完成", "都完成了", "done", "ok", "alldone", "finished", "allfinished",
]

///|
fn alnum_point(c : Int) -> Bool {
  let mut lo = 0
  let mut hi = alnum_ranges.length()
  while lo < hi {
    let mid = (lo + hi) / 2
    let (a, b) = alnum_ranges[mid]
    if c < a {
      hi = mid
    } else if c > b {
      lo = mid + 1
    } else {
      return true
    }
  }
  false
}

///|
/// `isReason`: whether all_done's `done` gives a reason, not only the word: at least a few characters, and not one of
/// the words that say only that it is done.
pub fn is_reason(done : String) -> Bool {
  let b = StringBuilder()
  for c in done {
    if alnum_point(c.to_int()) {
      b.write_char(c)
    }
  }
  let bare = @jscase.lower(b.to_string())
  chars(bare) >= min_reason && !empty_reasons.contains(bare)
}

///|
/// `needArg`: the turn's words kept with it (turns.need): what a need_help turn needs of a person (`need`), or what an
/// all_done one leaves the chat with (`done`).
pub fn need_arg(args : Map[String, Json], kind : Json, said : String) -> String? raise Refused {
  let text = (k : String) => match args.get(k) {
    None => None
    Some(v) => {
      let t = trim(js_string(v))
      if t == "" {
        None
      } else {
        Some(t)
      }
    }
  }
  let need = text("need")
  let done = text("done")
  let k = str_of(kind, "kind").unwrap_or("")
  if need is Some(_) && k != "need_help" {
    raise refuse("need goes only with kind \"need_human\"")
  }
  if done is Some(_) && k != "all_done" {
    raise refuse("done goes only with kind \"all_done\"")
  }
  match done {
    Some(d) if !is_reason(d) =>
      raise refuse(
        "done must say why nothing in the chat is left, so people can trust it: what was finished and where it landed or how it was confirmed (a commit, a release, a person's confirmation, the answer given), e.g. 已合进 main 82f108a5，测试版 1389 已发，你确认过滑动可以; not just that it is done",
      )
    _ => ()
  }
  if k == "need_help" && need is None && said == "now" {
    raise refuse(
      "need is required for need_human: what the person has to give, do or decide, in one sentence",
    )
  }
  if k == "all_done" && done is None && said == "now" {
    raise refuse(
      "done is required for all_done: why nothing in the chat is left, with the evidence (e.g. 已合进 main 82f108a5，测试版 1389 已发，你确认过滑动可以)",
    )
  }
  if k == "need_help" {
    need
  } else if k == "all_done" {
    done
  } else {
    None
  }
}

///|
/// `aboutTs`: the ts `about` names, if it is given.
pub fn about_ts(args : Map[String, Json]) -> String? {
  match args.get("about") {
    None | Some(Null) => None
    Some(v) => {
      let ts = trim(js_string(v))
      if ts == "" {
        None
      } else {
        Some(ts)
      }
    }
  }
}

///|
/// `firstLine`: a post's first line, without markup, cut to about 40 characters.
pub fn first_line(text : String) -> String {
  let first = split(text, "\n").map(trim).iter().find_first(l => l != "").unwrap_or("")
  let unmarked = replace_all(replace_all(replace_all(first, "**", ""), "__", ""), "`", "")
  // .replace(/^[#>\-* ]+/, "")
  let mut i = 0
  while i < unmarked.length() &&
        [
          '#'.to_int(),
          '>'.to_int(),
          '-'.to_int(),
          '*'.to_int(),
          ' '.to_int(),
        ].contains(u(unmarked, i)) {
    i += 1
  }
  let clean = trim(slice(unmarked, i))
  let cut = take(clean, 40)
  if chars(clean) > 40 {
    trim_end(cut) + "…"
  } else {
    cut
  }
}

///|
/// JavaScript's `trimEnd`.
fn trim_end(s : String) -> String {
  let mut end = s.length()
  while end > 0 && @jscase.is_white_space(u(s, end - 1)) {
    end -= 1
  }
  slice(s, 0, to=end)
}

///|
/// `optionsArg`: the answers an options card offers, as kept with its post: `[{label, detail?, recommended?, action?}]`,
/// each label trimmed. 1 to 6, labels not empty and not repeated, at most one recommended. JSON text read too.
pub fn options_arg(value : Json?) -> Array[Json]? raise Refused {
  let shape = "options must be an array of {label, detail?, recommended?}"
  let parsed : Json? = match value {
    Some(String(s)) if trim(s) != "" =>
      Some(@json.parse(s) catch { _ => raise refuse(shape) })
    _ => None
  }
  let list = match parsed {
    Some(p) => Some(p)
    None => value
  }
  let given = match list {
    None | Some(Null) | Some(String(_)) => return None
    Some(Array(a)) => a
    Some(_) => raise refuse(shape)
  }
  if given.length() == 0 || given.length() > max_options {
    raise refuse("options must have 1 to \{max_options} answers, got \{given.length()}")
  }
  let out : Array[Json] = []
  let labels : Array[String] = []
  for i, g in given {
    let o : Json = match g {
      String(s) => { "label": Json::string(s) }
      Object(_) => g
      _ => raise refuse("options[\{i}] must be an object {label, detail?, recommended?}")
    }
    let label = match field(o, "label") {
      None => ""
      Some(v) => trim(js_string(v))
    }
    if label == "" {
      raise refuse("options[\{i}].label is empty: a short phrase that reads on its own")
    }
    if labels.contains(label) {
      raise refuse(
        "options[\{i}].label repeats \{Json::string(label).stringify()}: each answer says something else",
      )
    }
    labels.push(label)
    let kept : Map[String, Json] = { "label": Json::string(label) }
    let detail = match field(o, "detail") {
      None => ""
      Some(v) => trim(js_string(v))
    }
    if detail != "" {
      kept["detail"] = Json::string(detail)
    }
    match field(o, "recommended") {
      Some(True) | Some(String("true")) => kept["recommended"] = Json::boolean(true)
      _ => ()
    }
    match field(o, "action") {
      None => ()
      Some(String("reply" | "close") as a) => kept["action"] = a
      Some(_) => raise refuse("options[\{i}].action must be reply or close")
    }
    out.push(Json::object(kept))
  }
  if out.filter(o => field(o, "recommended") is Some(_)).length() > 1 {
    raise refuse("only one option may be recommended")
  }
  Some(out)
}

///|
/// `optionsCard`.
pub fn options_card(options : Array[Json]) -> Json {
  { "type": "options", "options": Json::array(options) }
}

///|
/// /^[0-9a-z]{1,40}$/
fn login_id(s : String) -> Bool {
  s.length() >= 1 &&
  s.length() <= 40 &&
  s.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z'))
}

///|
/// /^[0-9a-f]{64}$/
fn station_key(s : String) -> Bool {
  s.length() == 64 && s.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
}

///|
/// The bytes of a string in UTF-8 (`Buffer.byteLength`).
fn utf8_length(s : String) -> Int {
  let mut n = 0
  for c in s {
    let p = c.to_int()
    n += if p < 0x80 {
      1
    } else if p < 0x800 {
      2
    } else if p < 0x10000 {
      3
    } else {
      4
    }
  }
  n
}

///|
/// `cardArg`: the card a post carries (chat_post `card`, or its `options` as said before cards), as kept with it.
pub fn card_arg(card : Json?, options : Json?) -> Json? raise Refused {
  let shape = "card must be an object: {\"type\": \"options\", \"options\": [{label, detail?, recommended?}]}, {\"type\": \"text\", \"placeholder\"?} or {\"type\": \"login\", \"login\": \"<id>\"}"
  let given : Json? = match card {
    None | Some(Null) => None
    Some(String(s)) =>
      if trim(s) == "" {
        None
      } else {
        Some(@json.parse(s) catch { _ => raise refuse(shape) })
      }
    Some(c) => Some(c)
  }
  let legacy = options_arg(options)
  let given = match given {
    // (JSON.parse("null") is null too)
    None | Some(Null) =>
      return match legacy {
        None => None
        Some(l) => Some(options_card(l))
      }
    Some(g) => g
  }
  if legacy is Some(_) {
    raise refuse(
      "give the options in card ({\"type\": \"options\", \"options\": [...]}), not also as options",
    )
  }
  if !is_object(given) {
    raise refuse(shape)
  }
  let kind = match field(given, "type") {
    None => ""
    Some(v) => trim(js_string(v))
  }
  let kept : Map[String, Json] = Map([])
  if kind == "options" {
    match options_arg(field(given, "options")) {
      None =>
        raise refuse(
          "an options card has options: 1 to \{max_options} answers {label, detail?, recommended?}",
        )
      Some(o) => {
        kept["type"] = "options"
        kept["options"] = Json::array(o)
      }
    }
  } else if kind == "text" {
    let placeholder = match field(given, "placeholder") {
      None => ""
      Some(v) => trim(js_string(v))
    }
    if chars(placeholder) > max_placeholder {
      raise refuse(
        "a text card's placeholder is at most \{max_placeholder} characters: a hint of what to write",
      )
    }
    kept["type"] = "text"
    if placeholder != "" {
      kept["placeholder"] = Json::string(placeholder)
    }
  } else if kind == "login" {
    let login = match field(given, "login") {
      Some(String(s)) => trim(s)
      _ => ""
    }
    if !login_id(login) {
      raise refuse(
        "a login card names the login: {\"type\": \"login\", \"login\": \"<the id login start answered>\"}",
      )
    }
    kept["type"] = "login"
    kept["login"] = Json::string(login)
    match field(given, "station") {
      None | Some(Null) | Some(String("")) => ()
      Some(String(s)) if station_key(s) => kept["station"] = Json::string(s)
      Some(_) =>
        raise refuse(
          "card.station: the key of the station the login runs on, when it is another station",
        )
    }
  } else if kind == "" {
    raise refuse("a card says its type: one of \{cards.join(", ")}")
  } else {
    raise refuse(
      "unknown card type \{Json::string(kind).stringify()}: the types known are \{cards.join(", ")}",
    )
  }
  match field(given, "assignee") {
    None => ()
    Some(a) => {
      let v = match a {
        String(s) => Some(trim(s))
        _ => None
      }
      let ok = match v {
        None => false
        Some(v) => {
          let parts = split(v, "@")
          parts.length() == 2 &&
          parts[0] != "" &&
          parts[1] != "" &&
          !v.iter().any(c => @jscase.is_space(c.to_int())) &&
          utf8_length(v) <= 254
        }
      }
      if !ok {
        raise refuse("card.assignee must be the decision maker's email, not a display name")
      }
      kept["assignee"] = Json::string(@jscase.lower(v.unwrap()))
    }
  }
  Some(Json::object(kept))
}

///|
/// `optionsSaid`: what chat_post says of the answers it offered, in the order and with the numbers the card shows them.
pub fn options_said(options : Json) -> String {
  let all = match options {
    Array(a) => a
    _ => []
  }
  let recommended = (o : Json) => field(o, "recommended") is Some(_)
  let shown = all.filter(o => !recommended(o)) + all.filter(recommended)
  let labels = []
  for i, o in shown {
    let label = "\{i + 1}. \{str_of(o, "label").unwrap_or("")}"
    labels.push(if recommended(o) { "\{label} (recommended)" } else { label })
  }
  " People can pick, numbered as the card shows them: \{labels.join("; ")}; a reply option reaches you as their message quoting this one with the option's label (action=close ends the wait silently: you are told the choice with what you are next handed). A message in the chat also closes the card, but may be a clarification rather than an answer."
}

///|
/// `cardSaid`: what chat_post says of the card it posted.
pub fn card_said(card : Json) -> String {
  match str_of(card, "type") {
    Some("options") => options_said(field(card, "options").unwrap_or(Json::null()))
    Some("login") => " People finish the login from the card (or its link) in their own browser; when it ends you get a station notice and the card closes."
    _ => " People can write their answer in the card's field; it reaches you as their message quoting this one. A message in the chat also closes the card, but may be a clarification rather than an answer."
  }
}

///|
fn is_html(f : Json) -> Bool {
  let name = @jscase.lower(str_of(f, "name").unwrap_or(""))
  name.has_suffix(".html") || name.has_suffix(".htm")
}

///|
/// `placeFigures`: the text with each HTML file not yet placed in it placed on a line of its own.
pub fn place_figures(text : String, files : Array[Json]) -> String {
  let mut kept = text
  for f in files.filter(is_html) {
    let name = str_of(f, "name").unwrap_or("")
    if !kept.contains("](\{name})") {
      kept = if kept == "" {
        "[\{name}](\{name})"
      } else {
        "\{kept}\n\n[\{name}](\{name})"
      }
    }
  }
  kept
}

///|
/// encodeURIComponent.
pub fn encode_uri_component(s : String) -> String {
  @url.encode_uri_component(s)
}

///|
/// `slackWithFiles`: what Slack is sent of a post with files it cannot take, and what still.fail keeps.
pub fn slack_with_files(words : Words, text : String, files : Array[Json], link : String) -> (String, String) {
  let figure = files.iter().find_first(is_html)
  let what = match figure {
    Some(_) =>
      if files.length() == 1 {
        words.tr("station.slack.viewFigure")
      } else {
        words.tr("station.slack.viewFigureAndFiles")
      }
    None => words.tr("station.slack.viewFiles")
  }
  let opened = match figure {
    Some(f) => Some(f)
    None => files.get(0)
  }
  let target = match opened {
    Some(f) => "\{link}?file=\{encode_uri_component(str_of(f, "name").unwrap_or(""))}"
    None => link
  }
  let posted = if text == "" {
    "<\{target}|\{what}>"
  } else {
    "\{text}\n\n<\{target}|\{what}>"
  }
  (posted, place_figures(text, files))
}

///|
/// /^[A-Za-z0-9]+$/
fn alnum_ascii(s : String) -> Bool {
  s.length() > 0 &&
  s.iter().all(c => (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'))
}

///|
/// `threadCommand`: what a message alone asks of the sessions of its thread, after mentions: `-stop`, `-compact`,
/// `-clear`; None for a message for its agent.
pub fn thread_command(text : String) -> String? {
  let mut rest = trim(text)
  while rest.has_prefix("<@") {
    let after = slice(rest, 2)
    let end = index_of(after, ">")
    if end < 0 {
      return None
    }
    let id = slice(after, 0, to=end)
    if id == "" || !alnum_ascii(id) {
      return None
    }
    rest = trim_start(slice(after, end + 1))
  }
  match @jscase.lower(rest) {
    "-stop" => Some("stop")
    "-compact" => Some("compact")
    "-clear" => Some("clear")
    _ => None
  }
}

///|
/// JavaScript's `trimStart`.
fn trim_start(s : String) -> String {
  let mut i = 0
  while i < s.length() && @jscase.is_white_space(u(s, i)) {
    i += 1
  }
  slice(s, i)
}

///|
/// `isSlackMethod`: a Slack Web API method's shape: family.method, lower camel case.
pub fn is_slack_method(name : String) -> Bool {
  let parts = split(name, ".")
  let first = parts[0]
  let rest = parts[1:].to_owned()
  let first_ok = first.length() > 0 &&
    u(first, 0) >= 'a'.to_int() &&
    u(first, 0) <= 'z'.to_int() &&
    first.iter().all(c => (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'))
  let letters = (p : String) => p.length() > 0 &&
    p.iter().all(c => (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'))
  first_ok && rest.length() > 0 && rest.iter().all(letters)
}
