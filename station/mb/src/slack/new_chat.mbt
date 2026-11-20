// `/sf` (apps.mbt `new_chat_command`; station/src/slack/new-chat.ts): a new chat with a model picked. Slack completes
// nothing typed after a command, so the command opens a form whose model field completes as one types (an external
// select: Slack asks the station for the options matching what is typed, `block_suggestion`; nothing typed, the few
// the person is offered first, the hub's `modelsFirst`); sent, the bot posts the words in the channel as a new thread
// and a session on that model takes it (surface.mbt `new_chat`, `start_chat`). All of it over Socket Mode.

///|
/// The form's callback id: what tells its submission from other forms'.
pub let new_chat_view_id : String = "stillfail-new-chat"

///|
let max_options : Int = 100

///|
let max_words : Int = 3000

///|
/// A model a chat may be started on: its runtime and its model (the runtime's default: None).
#derive(Eq)
pub(all) struct ModelChoice {
  runtime : String
  model : String?
}

///|
pub fn ModelChoice::to_j(self : ModelChoice) -> J {
  jo([("runtime", js(self.runtime)), ("model", jopt(self.model))])
}

///|
/// A model as the hub gives one (`{runtime, model}`), None where it is not one.
pub fn ModelChoice::of_j(v : J?) -> ModelChoice? {
  match str_of(at(v, "runtime")) {
    Some(r) =>
      Some({
        runtime: r,
        model: match at(v, "model") {
          Some(Str(u)) => Some(@jsjson.sanitize_str(u))
          _ => None
        },
      })
    None => None
  }
}

///|
/// How a model shows in the form: its runtime as people call it, and the model (the runtime's default when none).
pub fn model_label(words : Words, choice : ModelChoice, lang : String) -> String {
  let name = match @session_chats.runtime_named(choice.runtime) {
    Some(r) => @session_chats.runtime_title(r)
    None => choice.runtime
  }
  let model = match choice.model {
    Some(m) => m
    None => words.tr(lang, "station.slack.newChatDefaultModel")
  }
  "\{name} · \{model}"
}

///|
/// A model as an option's value.
pub fn model_value(choice : ModelChoice) -> String {
  stringify(ja([js(choice.runtime), jopt(choice.model)]))
}

///|
/// An option's value as a model (None: not one): `String(value)` read as JSON.
pub fn model_of(value : J?) -> ModelChoice? {
  match (try Ok(parse(js_str(value))) catch { e => Err(e) }) {
    Ok(Arr([Str(r), Null])) if r.length() > 0 => Some({ runtime: @jsjson.sanitize_str(r), model: None })
    Ok(Arr([Str(r), Str(m)])) if r.length() > 0 => Some({ runtime: @jsjson.sanitize_str(r), model: Some(@jsjson.sanitize_str(m)) })
    _ => None
  }
}

///|
fn model_option(words : Words, choice : ModelChoice, lang : String) -> J {
  jo([("text", plain(cut(model_label(words, choice, lang), 75))), ("value", js(model_value(choice)))])
}

///|
/// The options for what is typed in the model field: those whose label has every word typed, in order given.
pub fn model_options(words : Words, models : Array[ModelChoice], query : String, lang : String) -> Array[J] {
  let typed = @jscase.split_by(lower(query), @jscase.is_space).filter(w => w != "")
  models
  .filter(m => {
    let label = lower("\{model_label(words, m, lang)} \{m.model.unwrap_or("")}")
    typed.iter().all(w => label.contains(w))
  })
  .iter()
  .take(max_options)
  .map(m => model_option(words, m, lang))
  .collect()
}

///|
/// The form `/sf` opens in `channel`: the model (the first of `models` picked), and the words (what followed the
/// command).
pub fn new_chat_view(words : Words, models : Array[ModelChoice], channel : String, said : String, lang : String) -> J {
  let model = [
    ("type", js("external_select")),
    ("action_id", js("model")),
    ("min_query_length", ji(0)),
    ("placeholder", plain(words.tr(lang, "station.slack.newChatModelHint"))),
  ]
  if models.length() > 0 {
    model.push(("initial_option", model_option(words, models[0], lang)))
  }
  let input = [
    ("type", js("plain_text_input")),
    ("action_id", js("words")),
    ("multiline", jb(true)),
    ("max_length", ji(max_words)),
    ("placeholder", plain(words.tr(lang, "station.slack.newChatWordsHint"))),
  ]
  let given = trim(said)
  if given != "" {
    input.push(("initial_value", js(first_points(given, max_words))))
  }
  jo([
    ("type", js("modal")),
    ("callback_id", js(new_chat_view_id)),
    ("private_metadata", js(stringify(jo([("channel", js(channel))])))),
    ("title", plain(words.tr(lang, "station.slack.newChatTitle"))),
    ("submit", plain(words.tr(lang, "station.slack.newChatSubmit"))),
    ("close", plain(words.tr(lang, "station.slack.newChatCancel"))),
    (
      "blocks",
      ja([
        jo([
          ("type", js("input")),
          ("block_id", js("model")),
          ("label", plain(words.tr(lang, "station.slack.newChatModel"))),
          ("element", jo(model)),
        ]),
        jo([
          ("type", js("input")),
          ("block_id", js("words")),
          ("label", plain(words.tr(lang, "station.slack.newChatWords"))),
          ("element", jo(input)),
        ]),
      ]),
    ),
  ])
}

///|
/// What a sent form asks for: where, by whom, on which model, saying what.
pub struct Submitted {
  channel : String
  user : String
  model : ModelChoice?
  words : String
}

///|
pub fn Submitted::to_j(self : Submitted) -> J {
  jo([
    ("channel", js(self.channel)),
    ("user", js(self.user)),
    (
      "model",
      match self.model {
        Some(m) => m.to_j()
        None => Null
      },
    ),
    ("words", js(self.words)),
  ])
}

///|
/// What a sent form asks for. None: not this form, or not whole.
pub fn submitted_chat(payload : J?) -> Submitted? {
  let view = at(payload, "view")
  if str_of(at(view, "callback_id")) != Some(new_chat_view_id) {
    return None
  }
  let meta = match at(view, "private_metadata") {
    None | Some(Null) => ""
    m => js_str(m)
  }
  let channel = match (try Ok(parse(meta)) catch { e => Err(e) }) {
    Ok(Null) | Err(_) => ""
    Ok(v) =>
      match at(Some(v), "channel") {
        None | Some(Null) => ""
        c => js_str(c)
      }
  }
  let user = text(at_path(payload, ["user", "id"]))
  let values = at_path(view, ["state", "values"])
  let model = model_of(at_path(values, ["model", "model", "selected_option", "value"]))
  let said = match str_of(at_path(values, ["words", "words", "value"])) {
    Some(w) => trim(w)
    None => ""
  }
  if channel == "" || user == "" {
    return None
  }
  Some({ channel, user, model, words: said })
}

///|
/// The thread's first message, as the bot posts it for the person: who asked which model, then what they said.
pub fn new_chat_blocks(words : Words, user : String, choice : ModelChoice, said : String, lang : String) -> (String, Array[J]) {
  let head = words.tr(lang, "station.slack.newChatBy", args=[("who", "<@\{user}>"), ("model", model_label(words, choice, lang))])
  (
    "\{head}\n\{said}",
    [
      jo([("type", js("context")), ("elements", ja([jo([("type", js("mrkdwn")), ("text", js(head))])]))]),
      jo([("type", js("markdown")), ("text", js(said))]),
    ],
  )
}
