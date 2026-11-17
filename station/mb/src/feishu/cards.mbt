// What the station posts in Feishu (station/src/feishu/cards.ts, 「发出去的样子」): an agent's words as rich-text
// messages (`post`, an `md` element), and as message cards (JSON 2.0) a question's buttons or field, the answer it
// got, and the line saying what the agent is doing.

///|
/// The words people read (station/src/ops/i18n.ts): `tr(lang, key, args)`, and the station's own language
/// (`stationLang()`).
pub(all) struct Words {
  tr : (String, String, Map[String, Json]) -> String
  station_lang : () -> String
}

///|
/// The most of an agent's text one message or card carries (a card is at most 30 KB of JSON; Chinese is three bytes a
/// character).
pub let card_chars : Int = 6000

///|
fn card(elements : Array[JV], summary? : String = "", header? : JV) -> JV {
  let config = jobj([
    ("update_multi", Some(Bool(true))),
    ("enable_forward", Some(Bool(true))),
  ])
  if summary != "" {
    jput(config, "summary", jobj([("content", Some(js(summary)))]))
  }
  jobj([
    ("schema", Some(js("2.0"))),
    ("config", Some(config)),
    ("header", header),
    ("body", Some(jobj([("elements", Some(Arr(elements)))]))),
  ])
}

///|
fn markdown(content : String) -> JV {
  jobj([("tag", Some(js("markdown"))), ("content", Some(js(content)))])
}

///|
/// A line in grey, under what it is about.
fn note(content : String) -> JV {
  markdown("<font color='grey'>\{content}</font>")
}

///|
/// `/<at id=["']?([^"'\s>]+)["']?>/g` as `<at user_id="$1">`: a mention written as in a card, as `md` writes one.
fn at_mentions(t : String) -> String {
  let out = StringBuilder::new()
  let n = t.length()
  let open = "<at id="
  let mut i = 0
  while i < n {
    if i + open.length() <= n &&
      t.unsafe_substring(start=i, end=i + open.length()) == open {
      let mut j = i + open.length()
      if j < n && t.unsafe_charcode_at(j) is ('"' | '\'') {
        j += 1
      }
      let from = j
      while j < n {
        let c = t.unsafe_charcode_at(j)
        if c is ('"' | '\'' | '>') || is_js_space(c) {
          break
        }
        j += 1
      }
      if j > from {
        let id = t.unsafe_substring(start=from, end=j)
        let mut k = j
        if k < n && t.unsafe_charcode_at(k) is ('"' | '\'') {
          k += 1
        }
        if k < n && t.unsafe_charcode_at(k) == '>' {
          out.write_string("<at user_id=\"\{id}\">")
          i = k + 1
          continue
        }
      }
    }
    out.write_char(t.unsafe_charcode_at(i).unsafe_to_char())
    i += 1
  }
  out.to_string()
}

///|
/// An agent's message as rich-text messages' content: one, or several in order when it is long. A mention is written
/// as in a card (`<at id=ou_xxx></at>`), which `md` writes `<at user_id="ou_xxx"></at>`.
pub fn text_posts(t : String) -> Array[String] {
  @session_chats.split_for_slack(t, card_chars)
  .filter(p => trim_js(p) != "")
  .map(p => {
    let md = at_mentions(p)
    stringify(
      jobj([
        (
          "zh_cn",
          Some(
            jobj([
              (
                "content",
                Some(
                  Arr([
                    Arr([
                      jobj([("tag", Some(js("md"))), ("text", Some(js(md)))]),
                    ]),
                  ]),
                ),
              ),
            ]),
          ),
        ),
      ]),
    )
  })
}

///|
/// Words as plain text (a button's label, a field's hint).
fn plain(content : String) -> JV {
  jobj([("tag", Some(js("plain_text"))), ("content", Some(js(content)))])
}

///|
fn tr0(words : Words, lang : String, key : String) -> String {
  (words.tr)(lang, key, Map([]))
}

///|
/// A question's card: its text, then a button for each option (the recommended one last, as still.fail shows them, and
/// filled); or, for one to write, the text under an orange header marking it as a question and a line saying to reply
/// (with its hint), with no field, as a reply in the chat answers it. `thread`: where the answer goes.
pub fn question_card(
  words : Words,
  t : String,
  question : JV?,
  thread : String,
  lang : String,
) -> JV {
  let elements = []
  if trim_js(t) != "" {
    elements.push(markdown(t))
  }
  let kind = jget(question, "type")
  if kind == Some(Str("options")) {
    let options = jitems(jget(question, "options"))
    let recommended = (o : JV) => jget(Some(o), "recommended") == Some(Bool(true))
    let ordered = options.filter(o => !recommended(o)) +
      options.filter(o => recommended(o))
    for o in ordered {
      let label = js_string(Some(nullish(jget(Some(o), "label"), Str(""))))
      let value = jobj([
        ("sf", Some(js("answer"))),
        ("t", Some(js(thread))),
        ("l", Some(js(label))),
      ])
      elements.push(
        jobj([
          ("tag", Some(js("button"))),
          ("text", Some(plain(label))),
          (
            "type",
            Some(js(if recommended(o) { "primary_filled" } else { "default" })),
          ),
          ("width", Some(js("fill"))),
          (
            "behaviors",
            Some(
              Arr([
                jobj([("type", Some(js("callback"))), ("value", Some(value))]),
              ]),
            ),
          ),
        ]),
      )
      match jget(Some(o), "detail") {
        Some(Str(d)) if trim_js(d) != "" => elements.push(note(d))
        _ => ()
      }
    }
  } else if kind == Some(Str("text")) {
    let hint = match jget(question, "placeholder") {
      Some(Str(p)) if trim_js(p) != "" => " · \{trim_js(p)}"
      _ => ""
    }
    elements.push(note(tr0(words, lang, "station.feishu.replyHint") + hint))
    return card(
      elements,
      header=jobj([
        ("title", Some(plain(tr0(words, lang, "station.card.asking")))),
        ("template", Some(js("orange"))),
      ]),
    )
  }
  card(elements)
}

///|
/// A question's card once answered: its text, and who answered what; nothing to press any more.
pub fn answered_card(
  words : Words,
  t : String,
  who : String,
  said : String,
  lang : String,
) -> JV {
  let elements = []
  if trim_js(t) != "" {
    elements.push(markdown(t))
  }
  elements.push(
    note(
      (words.tr)(lang, "station.feishu.answered", {
        "name": Json::string(who),
        "answer": Json::string(said),
      }),
    ),
  )
  card(elements)
}

///|
/// A question's card that stopped waiting other than by its buttons (connects/card-ends.ts): its text, and why it is
/// closed; nothing to press any more.
pub fn ended_card(t : String, words_said : String) -> JV {
  let elements = []
  if trim_js(t) != "" {
    elements.push(markdown(t))
  }
  elements.push(note(words_said))
  card(elements)
}

///|
/// How long a turn took, in words.
pub fn took(words : Words, ms : Double, lang : String) -> String {
  let s = @cmp.maximum(1.0, js_round(ms / 1000.0))
  if s < 60.0 {
    return (words.tr)(lang, "station.feishu.seconds", {
      "s": Json::number(s),
    })
  }
  let m = (s / 60.0).floor()
  let rest = s - m * 60.0
  (words.tr)(lang, "station.feishu.minutes", {
    "m": Json::number(m),
    "s": Json::number(rest),
  })
}

///|
/// What the agent is doing, while it works.
pub fn working_card(status : String) -> JV {
  card([note(status)], summary=status)
}

///|
/// The turn over: how long it took, and where its steps can be read.
pub fn done_card(
  words : Words,
  ms : Double,
  page : String?,
  lang : String,
) -> JV {
  let line = (words.tr)(lang, "station.feishu.done", {
    "time": Json::string(took(words, ms, lang)),
  })
  let history = match page {
    Some(p) => " · [\{tr0(words, lang, "station.feishu.history")}](\{p})"
    None => ""
  }
  card([note(line + history)], summary=line)
}

///|
/// A card's JSON as a message's content: inline, or the CardKit entity it shows.
pub fn inline(c : JV) -> String {
  stringify(c)
}

///|
pub fn entity(card_id : String) -> String {
  stringify(
    jobj([
      ("type", Some(js("card"))),
      ("data", Some(jobj([("card_id", Some(js(card_id)))]))),
    ]),
  )
}

///|
/// Why a card stopped waiting (connects/card-ends.ts `CardEnd`): a person's message after it (`by` its author, `by_ts`
/// that message's ts), a newer card, its agent withdrawing it, or a person closing it.
pub(all) enum CardEnd {
  ByMessage(String, String)
  Replaced
  Withdrawn
  Closed
}

///|
/// What a card that stopped waiting says under its words (connects/card-ends.ts `endedWords`): why it is closed
/// (`name`: who wrote the message that closed it, when known). A text card's answer is that message: it says they
/// replied.
pub fn ended_words(
  words : Words,
  c : JV?,
  end : CardEnd,
  name : String?,
  lang : String,
) -> String {
  match end {
    ByMessage(_, _) => {
      let key = if jget(c, "type") == Some(Str("text")) {
        "station.card.replied"
      } else {
        "station.card.endedByMessage"
      }
      match name {
        Some(n) if n != "" => (words.tr)(lang, key, { "name": Json::string(n) })
        _ => tr0(words, lang, key + "Bare")
      }
    }
    Replaced => tr0(words, lang, "station.card.endedReplaced")
    Withdrawn => tr0(words, lang, "station.card.endedWithdrawn")
    Closed => tr0(words, lang, "station.card.endedClosed")
  }
}
