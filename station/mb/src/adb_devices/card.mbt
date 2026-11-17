// What a grant's card is posted and found by (station/src/sessions/card-place.ts): its request can outlive a question
// card closed by a chat message.

///|
/// Whether an answer is `undefined`.
pub fn undefined(v : J) -> Bool {
  @session_chats.is_undefined(v)
}

///|
/// Whether the store has `name` (a method a store from before lacks).
pub async fn World::store_has(self : World, name : String) -> Bool {
  self.ask("store.has", [js(name)]) is Bool(true)
}

///|
/// Whether the hub has `name` (`hub.<name> != null`).
pub async fn World::hub_has(self : World, name : String) -> Bool {
  self.ask("hub.has", [js(name)]) is Bool(true)
}

///|
/// card-place.ts `cardHeaderIfReady`: a bounded card header, Some(Null) for none, None where an old thread must be
/// prepared first.
pub async fn card_header_if_ready(w : World, thread : J) -> J? {
  if w.store_has("pendingCardHeaderIfReady") {
    let v = w.store("pendingCardHeaderIfReady", [thread])
    if undefined(v) {
      None
    } else {
      Some(v)
    }
  } else {
    Some(w.store("pendingCardHeader", [thread]))
  }
}

///|
/// card-place.ts `cardPlace`: Some(Null) where none was asked, None where not ready, else the conversation and whether
/// this card, another or none waits there.
pub async fn card_place(w : World, session : String, thread : J, ts : J) -> J? {
  if thread is Null || ts is Null {
    return Some(Null)
  }
  let where_ = w.store("sessionThreadById", [js(session), thread])
  if where_ is Null {
    raise fail_(
      "the original conversation is no longer available to this session",
    )
  }
  guard card_header_if_ready(w, thread) is Some(current) else { return None }
  let state = if current is Null {
    "none"
  } else if jeq(get(at_i(Some(current), 0).unwrap_or(Null), "ts"), ts) {
    "same"
  } else {
    "other"
  }
  Some(jo([("thread", where_), ("state", js(state))]))
}

///|
pub let card_occupied : String = "Another card is pending in that conversation. Resolve or withdraw it before asking this again."

///|
/// card-place.ts `recordPostedCard`: once the surface has given the post its timestamp, recorded only while the request
/// and card are still valid, the second check run inside the insert's write; a busy writer or an old index waited for
/// outside it.
pub async fn record_posted_card(
  w : World,
  session : String,
  thread : J,
  text : String,
  card : J,
  posted : J,
  occupied : ((String) -> Error)?,
  needed : (async () -> Bool)?,
  identity : J?,
) -> J {
  let id = get(get(thread, "thread"), "id")
  let fields = [
    ("thread", id),
    ("ts", posted),
    ("authorKind", js("agent")),
    ("author", js(session)),
    ("text", js(text)),
    ("attachments", ja([])),
    ("declared", J::Null),
    ("card", card),
  ]
  if identity is Some(i) {
    fields.push(("agentIdentity", i))
  }
  let message = jo(fields)
  let check = async fn() -> Unit {
    if needed is Some(f) && !f() {
      raise refused("CardNoLongerNeeded", "")
    }
    let occupied = occupied.unwrap()
    if w.store("sessionThreadById", [js(session), id]) is Null {
      raise occupied(
        "the original conversation is no longer available to this session",
      )
    }
    match card_header_if_ready(w, id) {
      None => raise refused("CardPreparationNeeded", "")
      Some(Null) => ()
      Some(_) => raise occupied(card_occupied)
    }
  }
  let mut delay = 10.0
  while true {
    let inserted = try {
      if occupied is Some(_) {
        check()
      }
      let args = [message]
      if occupied is Some(_) {
        args.push(
          (w.callback)(async fn(_) {
            check()
            J::Null
          }),
        )
      }
      Ok(w.store("insertMessage", args))
    } catch {
      e => Err(e)
    }
    match inserted {
      Ok(ns) => {
        let n = at_i(Some(ns), 0).unwrap_or(Null)
        ignore(w.ask("hub.shared", [id, n, js(session), js(text)]))
        return if card is Null { Null } else { posted }
      }
      Err(e) =>
        match kind_of(e) {
          "CardNoLongerNeeded" => return Null
          "CardPreparationNeeded" => {
            if !w.hub_has("prepareCardPosts") {
              raise occupied.unwrap()("card lookup is not ready")
            }
            ignore(w.ask("hub.prepareCardPosts", [ja([id])]))
          }
          "MessageWriteBusy" => {
            w.sleep(delay)
            delay = @cmp.minimum(delay * 2.0, 250.0)
          }
          _ => raise e
        }
    }
  }
  Null
}

///|
/// card-place.ts `postCard`: `text` said in `thread` as `session`'s agent, with `card` (Null on a surface without
/// cards), posted and then kept as the agent's message; the card's ts, or Null with none.
pub async fn post_card(
  w : World,
  session : String,
  thread : J,
  text : String,
  card : J,
  occupied : ((String) -> Error)?,
  needed : (async () -> Bool)?,
) -> J {
  let identity = match w.ask("hub.identity", [js(session)]) {
    Null => None
    v if undefined(v) => None
    v => Some(v)
  }
  let row = get(thread, "thread")
  let here = jo([
    ("channel", get(row, "channel")),
    ("threadTs", get(row, "threadTs")),
  ])
  let posted = w.ask("chat.post", [
    get(thread, "connect"),
    here,
    js(text),
    ja([]),
  ])
  record_posted_card(
    w, session, thread, text, card, posted, occupied, needed, identity,
  )
}
