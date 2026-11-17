// Cards that stop waiting where a platform shows them (connects/card-ends.ts: Slack's and Feishu's buttons): as in
// still.fail, a card is no longer pending once a person's message after it reaches its agent (handed to a session
// there, `answered`), a newer card replaces it, its agent withdraws it or someone closes it (store.ts pendingCard); a
// system card (a login, a vault's secret...) only as it is closed (store/card-kinds.ts). A press of its own button
// changes it there already; these change it for the rest, so nothing is left to press that would answer a question
// gone by.

///|
/// The store, as far as cards that end are read of it (`Cards`).
pub struct Cards {
  get_thread : async (Double) -> J
  thread_sessions : async (Double) -> Array[J]
  /// `[message, card]` or null.
  card_ended_by_message : async (Double, Double) -> J
  card_replaced_by : async (Double, Double) -> J
  /// `[message, card, closer]` or null.
  closed_card : async (Double, Double) -> J
}

///|
/// The connect still.fail's own chats go through (sessions/internal.ts `INTERNAL_CONNECT`).
pub let internal_connect : String = @session_chats.internal_connect

///|
/// still.fail's own surface (store/rows.ts `STILLFAIL_SURFACE`).
pub let stillfail_surface : String = @session_chats.stillfail_surface

///|
/// The cards a change of the store ended (none for any change but a thread's): each `{message, card, end}`.
pub async fn cards_ended(store : Cards, change : J) -> Array[J] {
  if str_of(at(Some(change), "type")) != Some("thread") {
    return []
  }
  let id = num_of(at(Some(change), "id")).unwrap_or(0.0)
  let out : Array[J] = []
  let ended_card = (pair : J, end : J) => match pair {
    Arr(xs) if xs.length() >= 2 => out.push(jo([("message", xs[0]), ("card", xs[1]), ("end", end)]))
    _ => ()
  }
  for e in arr_of(at(Some(change), "entries")).unwrap_or([]) {
    if str_of(at(Some(e), "kind")) != Some("message") {
      continue
    }
    let n = num_of(at(Some(e), "n")).unwrap_or(0.0)
    if str_of(at(Some(e), "authorKind")) == Some("person") {
      let ended = (store.card_ended_by_message)(id, n)
      let by_ts = match at(Some(e), "ts") {
        Some(Null) | None => js("")
        Some(t) => t
      }
      ended_card(ended, jo([("why", js("message")), ("by", at(Some(e), "author").unwrap_or(undefined())), ("byTs", by_ts)]) |> drop_undefined)
    } else if !(at(Some(e), "card") is (Some(Null) | None)) || at(Some(e), "options") is Some(_) {
      let replaced = (store.card_replaced_by)(id, n)
      ended_card(replaced, jo([("why", js("replaced"))]))
    }
  }
  match at(Some(change), "answered") {
    Some(answered) => {
      let ended = (store.card_ended_by_message)(id, num_of(at(Some(answered), "n")).unwrap_or(0.0))
      ended_card(ended, jo([("why", js("message")), ("by", at(Some(answered), "author").unwrap_or(undefined())), ("byTs", at(Some(answered), "ts").unwrap_or(undefined()))]) |> drop_undefined)
    }
    None => ()
  }
  match at(Some(change), "closed") {
    Some(closed) => {
      let got = (store.closed_card)(id, num_of(Some(closed)).unwrap_or(0.0))
      match got {
        Arr(xs) if xs.length() >= 3 => {
          let closer = xs[2]
          let author = at(Some(xs[0]), "author").unwrap_or(undefined())
          let withdrawn = @session_chats.jeq(closer, author)
          out.push(jo([("message", xs[0]), ("card", xs[1]), ("end", jo([("why", js(if withdrawn { "withdrawn" } else { "closed" }))]))]))
        }
        _ => ()
      }
    }
    None => ()
  }
  out
}

///|
/// The cards a change of the store ended, changed where their thread's platform shows them (`chat`: a connect's
/// surface, where it is connected). Not waited on.
pub async fn show_ended(store : Cards, chat : (String) -> Surface?, change : J, log : Log) -> Unit {
  if str_of(at(Some(change), "type")) != Some("thread") {
    return
  }
  let entries = arr_of(at(Some(change), "entries")).unwrap_or([])
  if entries.length() == 0 && at(Some(change), "closed") is None && at(Some(change), "answered") is None {
    return
  }
  let id = num_of(at(Some(change), "id")).unwrap_or(0.0)
  let t = (store.get_thread)(id)
  if t is Null || str_of(at(Some(t), "surface")) == Some(stillfail_surface) {
    return
  }
  let connect = (store.thread_sessions)(id)
    .map(m => js_text(at(Some(m), "connect")))
    .iter()
    .find_first(c => c != internal_connect)
  let shown = match connect {
    Some(c) => chat(c)
    None => None
  }
  guard shown is Some(surface) else { return }
  if !(surface.has)("cards") || !(surface.has)("cardEnded") {
    return
  }
  let cards = cards_ended(store, change)
  let thread = jo([("channel", at(Some(t), "channel").unwrap_or(Null)), ("threadTs", at(Some(t), "threadTs").unwrap_or(Null))])
  for c in cards {
    let message = at(Some(c), "message").unwrap_or(Null)
    let ts = at(Some(message), "ts").unwrap_or(Null)
    spawn(async fn() {
      ignore((surface.call)("cardEnded", [thread, ts, at(Some(message), "text").unwrap_or(Null), at(Some(c), "card").unwrap_or(Null), at(Some(c), "end").unwrap_or(Null)])) catch {
        e => log.warn("connects", "a card that stopped waiting was not changed where it shows", jo([("thread", jn(id)), ("ts", ts), ("error", js(thrown_message(e)))]))
      }
    })
  }
}

///|
/// What a card that stopped waiting says under its words, in small grey letters: why it is closed (`name`: who wrote
/// the message that closed it, when known). A text card's answer is that message: it says they replied.
pub fn ended_words(speech : Speech, card : J, end : J, name : String?, lang : String) -> String {
  match str_of(at(Some(end), "why")).unwrap_or("") {
    "message" => {
      let key = if str_of(at(Some(card), "type")) == Some("text") { "station.card.replied" } else { "station.card.endedByMessage" }
      match name {
        Some(n) if n != "" => speech.tr(lang, key, args=[("name", n)])
        _ => speech.tr(lang, "\{key}Bare")
      }
    }
    "replaced" => speech.tr(lang, "station.card.endedReplaced")
    "withdrawn" => speech.tr(lang, "station.card.endedWithdrawn")
    "closed" => speech.tr(lang, "station.card.endedClosed")
    _ => ""
  }
}
