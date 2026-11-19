// A question in Slack, as Block Kit (station/src/slack/cards.ts): the agent's words, then the options as radio buttons
// with the recommended one last and chosen already, and a button that sends the answer; or, for one to write, the words
// marked as a question, answered by a reply in the thread; or, for a login whose page gives a code, a field for that
// code and a button that hands it to the login, never said in the thread. Pressed, a button comes over Socket Mode (an
// `interactive` envelope) and the message is changed to say who answered what.

///|
/// The station's words (client/i18n/catalog's station part) and its language ("zh", "en").
pub type Words = @session_chats.Words

///|
/// The most a message's Markdown, and an option's label or description, may hold (Slack refuses more).
pub let markdown_chars : Int = 12000

///|
let option_chars : Int = 75

///|
/// The most a button's value may hold.
let value_chars : Int = 2000

///|
/// The button that sends a card's answer.
pub let send_action : String = "sf_answer"

///|
let pick_action : String = "sf_pick"

///|
let field_action : String = "sf_text"

///|
/// A login card's field and its button.
let code_action : String = "sf_code"

///|
pub let login_action : String = "sf_login"

///|
/// A login card's button that opens its page (a link: pressed, it hands Slack nothing to do).
let open_action : String = "sf_login_page"

///|
/// The longest address a button may open.
let url_chars : Int = 3000

///|
fn plain(t : String) -> J {
  jo([("type", js("plain_text")), ("text", js(t)), ("emoji", jb(true))])
}

///|
/// At most `most` code points, the last of them … where cut.
fn cut(s : String, most : Int) -> String {
  if point_count(s) <= most {
    s
  } else {
    "\{first_points(s, most - 1)}…"
  }
}

///|
/// Words as a markdown block: Slack draws it as still.fail does (bold, links, lists, headings, tables, code).
pub fn markdown(t : String) -> J {
  jo([("type", js("markdown")), ("text", js(t))])
}

///|
/// What a card says above its buttons, in one markdown block (none when it says nothing); the most Slack takes.
fn markdown_of(parts : Array[String]) -> J? {
  if parts.length() == 0 {
    None
  } else {
    Some(markdown(cut(parts.join("\n\n"), markdown_chars)))
  }
}

///|
fn said_parts(t : String) -> Array[String] {
  if trim(t) == "" {
    []
  } else {
    [t]
  }
}

///|
fn blocks_of(bs : Array[J?]) -> Array[J] {
  bs.filter_map(b => b)
}

///|
/// A question's blocks (cards.ts `questionBlocks`).
pub fn question_blocks(words : Words, t : String, question : J?, lang : String) -> Array[J] {
  let blocks : Array[J?] = []
  let said = said_parts(t)
  match str_of(at(question, "type")) {
    Some("options") => {
      let given = arr(at(question, "options"))
      let ordered = given.filter(o => !is_true(at(Some(o), "recommended"))) +
        given.filter(o => is_true(at(Some(o), "recommended")))
      let labels = ordered.map(o => match at(Some(o), "label") {
        None | Some(Null) => ""
        l => js_str(l)
      })
      let details = ordered.map(o => match str_of(at(Some(o), "detail")) {
        Some(d) => trim(d)
        None => ""
      })
      let long = labels.iter().any(l => point_count(l) > option_chars) ||
        details.iter().any(d => point_count(d) > option_chars)
      if long {
        said.push(
          labels
          .mapi((i, l) => if details[i] != "" { "**\{l}**\n\{details[i]}" } else { "**\{l}**" })
          .join("\n\n"),
        )
      }
      let options = labels.mapi((i, l) => {
        let fs = [("text", plain(cut(l, option_chars))), ("value", js(i.to_string()))]
        if !long && details[i] != "" {
          fs.push(("description", plain(details[i])))
        }
        jo(fs)
      })
      let chosen = ordered.search_by(o => is_true(at(Some(o), "recommended")))
      let pick = [("type", js("radio_buttons")), ("action_id", js(pick_action)), ("options", ja(options))]
      match chosen {
        Some(c) => pick.push(("initial_option", options[c]))
        None => ()
      }
      let mut sent = jo([("l", jsa(labels))])
      // Labels too long to carry are read from the option chosen instead (its start, as shown).
      if stringify(sent).length() > value_chars {
        sent = jo([])
      }
      blocks.push(markdown_of(said))
      blocks.push(
        Some(
          jo([
            ("type", js("actions")),
            (
              "elements",
              ja([
                jo(pick),
                jo([
                  ("type", js("button")),
                  ("action_id", js(send_action)),
                  ("text", plain(words.tr(lang, "station.slack.confirm"))),
                  ("style", js("primary")),
                  ("value", js(stringify(sent))),
                ]),
              ]),
            ),
          ]),
        ),
      )
    }
    Some("text") => {
      blocks.push(Some(jo([("type", js("header")), ("text", plain(words.tr(lang, "station.card.asking")))])))
      blocks.push(markdown_of(said))
      let hint = match str_of(at(question, "placeholder")) {
        Some(p) if trim(p) != "" => " · \{trim(p)}"
        _ => ""
      }
      blocks.push(
        Some(
          jo([
            ("type", js("context")),
            (
              "elements",
              ja([
                jo([
                  ("type", js("mrkdwn")),
                  ("text", js(escape("\{words.tr(lang, "station.slack.replyHint")}\{hint}"))),
                ]),
              ]),
            ),
          ]),
        ),
      )
    }
    _ => ()
  }
  blocks_of(blocks)
}

///|
/// A login card (cards.ts `loginBlocks`): `page` the login's page as its card gives it (`{url, domain, code?,
/// paste}`), `shown` whether it may be shown in this channel.
pub fn login_blocks(words : Words, t : String, lang : String, page? : J? = None, shown? : Bool = true) -> Array[J] {
  let page = match page {
    Some(Null) | None => None
    p => p
  }
  let open = match page {
    Some(p) if shown =>
      match at(Some(p), "url") {
        Some(Str(u)) if u.length() <= url_chars => Some(p)
        _ => None
      }
    _ => None
  }
  let button = match open {
    Some(o) => {
      let b = [
        ("type", js("button")),
        ("action_id", js(open_action)),
        ("text", plain(words.tr(lang, "station.slack.loginOpen", args=[("domain", js_str(at(Some(o), "domain")))]))),
        ("url", at(Some(o), "url").unwrap_or(Null)),
      ]
      if !truthy(at(Some(o), "paste")) {
        b.push(("style", js("primary")))
      }
      Some(jo([("type", js("actions")), ("elements", ja([jo(b)]))]))
    }
    None => None
  }
  match page {
    Some(p) if !truthy(at(Some(p), "paste")) => {
      if open is None {
        return blocks_of([markdown_of(said_parts(t))])
      }
      let code = match at(Some(p), "code") {
        None | Some(Null) => ""
        c => js_str(c)
      }
      let code_block = jo([
        ("type", js("section")),
        (
          "text",
          jo([
            ("type", js("mrkdwn")),
            ("text", js("\{escape(words.tr(lang, "station.slack.loginDeviceCode"))}  `\{escape(code)}`")),
          ]),
        ),
      ])
      return blocks_of([markdown_of(said_parts(t)), Some(code_block), button])
    }
    _ => ()
  }
  blocks_of([
    markdown_of(said_parts(t)),
    button,
    Some(
      jo([
        ("type", js("input")),
        ("block_id", js(code_action)),
        ("dispatch_action", jb(false)),
        ("label", plain(words.tr(lang, "station.slack.loginCode"))),
        (
          "element",
          jo([
            ("type", js("plain_text_input")),
            ("action_id", js(code_action)),
            ("placeholder", plain(words.tr(lang, "station.slack.loginCodeHint"))),
          ]),
        ),
      ]),
    ),
    Some(
      jo([
        ("type", js("actions")),
        (
          "elements",
          ja([
            jo([
              ("type", js("button")),
              ("action_id", js(login_action)),
              ("text", plain(words.tr(lang, "station.slack.loginSubmit"))),
              ("style", js("primary")),
            ]),
          ]),
        ),
      ]),
    ),
  ])
}

///|
/// A card's words, to be shown again once it is answered: the Markdown the station posted, or, when that is not known
/// any more (a restart since), the blocks Slack holds of the message.
pub(all) enum CardWords {
  Markdown(String)
  Blocks(Array[J])
}

///|
/// The blocks that show a card's words: its Markdown in a markdown block, or Slack's own blocks of it without what
/// could be pressed or filled in (its buttons and fields).
fn words_blocks(w : CardWords) -> Array[J] {
  match w {
    Markdown(m) => blocks_of([markdown_of(said_parts(m))])
    Blocks(bs) =>
      bs.filter(b => {
        let k = str_of(at(Some(b), "type"))
        k != Some("actions") && k != Some("input")
      })
  }
}

///|
fn context_block(t : String) -> J {
  jo([("type", js("context")), ("elements", ja([jo([("type", js("mrkdwn")), ("text", js(t))])]))])
}

///|
/// A login card once its code was handed over: its words, and who entered it; no field any more.
pub fn login_entered_blocks(words : Words, w : CardWords, who : String, lang : String) -> Array[J] {
  words_blocks(w) + [context_block("✓ \{escape(words.tr(lang, "station.slack.loginEntered", args=[("name", who)]))}")]
}

///|
/// The field of an interaction's state (`Object.values(payload?.state?.values ?? {}).map(v => v?.[id]).find(…)`).
fn state_field(payload : J?, id : String) -> J? {
  for v in values_of(at_path(payload, ["state", "values"])) {
    match at(Some(v), id) {
      Some(f) => return Some(f)
      None => ()
    }
  }
  None
}

///|
/// What a press of a login card's button hands over: the field's words ("" when empty). None for any other action.
pub fn login_code_of(payload : J?) -> String? {
  let pressed = arr(at(payload, "actions")).iter().any(a => str_of(at(Some(a), "action_id")) == Some(login_action))
  if !pressed {
    return None
  }
  match str_of(at(state_field(payload, code_action), "value")) {
    Some(v) => Some(trim(v))
    None => Some("")
  }
}

///|
/// A question once answered: its words, and who answered what; nothing to press any more.
pub fn answered_blocks(words : Words, w : CardWords, who : String, said : String, lang : String) -> Array[J] {
  words_blocks(w) +
  [context_block("✓ \{escape(words.tr(lang, "station.feishu.answered", args=[("name", who), ("answer", said)]))}")]
}

///|
/// A question that stopped waiting other than by its button: its words, and why it is closed.
pub fn ended_blocks(t : String, why : String) -> Array[J] {
  blocks_of([markdown_of(said_parts(t)), Some(context_block(escape(why)))])
}

///|
/// Where a thread stands once its agent's turn ended: done, what it needs of a person, or that the agent left it
/// (`kind`: "done", "need", "left"; `words` what it said).
pub struct Stands {
  kind : String
  words : String?
}

///|
pub fn Stands::of_j(v : J?) -> Stands? {
  match v {
    Some(Obj(_)) =>
      Some({
        kind: text(at(v, "kind")),
        words: match at(v, "words") {
          Some(Str(u)) => Some(@jsjson.sanitize_str(u))
          _ => None
        },
      })
    _ => None
  }
}

///|
/// The most of its words the line carries.
let stands_chars : Int = 500

///|
pub fn stands_block(words : Words, s : Stands, lang : String) -> J {
  context_block(escape(stands_text(words, s, lang)))
}

///|
pub fn stands_text(words : Words, s : Stands, lang : String) -> String {
  if s.kind == "left" {
    return "🔕 \{words.tr(lang, "station.slack.standsLeft")}"
  }
  let w = trim(s.words.unwrap_or(""))
  let (mark, key, name) = if s.kind == "done" {
    ("✓", "station.slack.standsDone", "done")
  } else {
    ("🔔", "station.slack.standsNeed", "need")
  }
  let said = if w == "" { words.tr(lang, "\{key}Bare") } else { words.tr(lang, key, args=[(name, cut(w, stands_chars))]) }
  "\{mark} \{said}"
}

///|
/// What a press of a card's send button answers: the option chosen (its label) or the words in the field, "" when
/// nothing was chosen or written, and whether it was a field. None for any other action.
pub fn answer_of(payload : J?) -> (String, Bool)? {
  let action = match arr(at(payload, "actions")).search_by(a => str_of(at(Some(a), "action_id")) == Some(send_action)) {
    Some(i) => arr(at(payload, "actions"))[i]
    None => return None
  }
  let sent = {
    let raw = match at(Some(action), "value") {
      Some(Str(u)) => @jsjson.sanitize_str(u)
      _ => "{}"
    }
    match (try Ok(parse(raw)) catch { e => Err(e) }) {
      Ok(Null) | Err(_) => jo([])
      Ok(v) => v
    }
  }
  match state_field(payload, field_action) {
    Some(f) =>
      return Some(
        (
          match str_of(at(Some(f), "value")) {
            Some(v) => trim(v)
            None => ""
          },
          true,
        ),
      )
    None => ()
  }
  let mut option : J? = None
  for v in values_of(at_path(payload, ["state", "values"])) {
    match at(at(Some(v), pick_action), "selected_option") {
      None | Some(Null) => ()
      o => {
        option = o
        break
      }
    }
  }
  let label = match (truthy(option), at(Some(sent), "l")) {
    (true, Some(Arr(ls))) => {
      let n = js_num(at(option, "value"))
      if n.is_nan() || n != n.floor() || n < 0.0 || n >= ls.length().to_double() {
        None
      } else {
        str_of(Some(ls[n.to_int()]))
      }
    }
    _ => None
  }
  let said = match label {
    Some(l) => l
    None => text(at_path(option, ["text", "text"]))
  }
  Some((said, false))
}
