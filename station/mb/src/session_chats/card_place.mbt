// Where a long-lived operation's card stands (station/src/sessions/card-place.ts): its request can outlive a question
// card closed by a chat message.

///|
/// A bounded card header (`[{ts}, ...]`), Some(Null) for none, None where an old thread must be prepared first.
pub async fn card_header_if_ready(w : World, thread : J) -> J? {
  if w.store_has("pendingCardHeaderIfReady") {
    w.store_pending_card_header_if_ready(thread)
  } else {
    Some(w.store_pending_card_header(thread))
  }
}

///|
/// What `cardPlace` finds: none asked (Null), not ready (None), or the conversation and whether this card, another or
/// none waits there.
pub async fn card_place(w : World, session : String, thread : J, ts : J) -> J? {
  if nullish(Some(thread)) || nullish(Some(ts)) {
    return Some(Null)
  }
  let where_ = w.store_session_thread_by_id(session, thread)
  if where_ is Null {
    raise fail_("the original conversation is no longer available to this session")
  }
  guard card_header_if_ready(w, thread) is Some(current) else { return None }
  let state = if current is Null {
    "none"
  } else if jeq(at(at_i(Some(current), 0), "ts").unwrap_or(Null), ts) {
    "same"
  } else {
    "other"
  }
  Some(jo([("thread", where_), ("state", js(state))]))
}

///|
pub let card_occupied : String = "Another card is pending in that conversation. Resolve or withdraw it before asking this again."

///|
priv suberror CardFlow {
  PreparationNeeded
  NoLongerNeeded
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
impl Show for CardFlow with output(self, logger) {
  match self {
    PreparationNeeded => logger.write_string("the card is to be prepared again")
    NoLongerNeeded => logger.write_string("the card is no longer needed")
  }
}

///|
/// Once the surface has given the post its timestamp, records it only while the request and card are still valid: the
/// second check inside the insert's write. `occupied`: what refuses it when another card came (None: no card to keep
/// apart); `needed`: whether the request still wants it.
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
  let tid = at(at(Some(thread), "thread"), "id").unwrap_or(Null)
  let fields = [
    ("thread", tid),
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
  let check = async fn() raise {
    if needed is Some(f) && !f() {
      raise NoLongerNeeded
    }
    if w.store_session_thread_by_id(session, tid) is Null {
      raise (occupied.unwrap())("the original conversation is no longer available to this session")
    }
    match card_header_if_ready(w, tid) {
      None => raise PreparationNeeded
      Some(Null) => ()
      Some(_) => raise (occupied.unwrap())(card_occupied)
    }
  }
  let mut delay = 10.0
  while true {
    let n = try {
      if occupied is Some(_) {
        check()
      }
      let extra = []
      if occupied is None {
        extra.push(undefined_j())
      }
      if occupied is Some(_) {
        extra.push(
          (w.callback)(async fn(_) {
            check() catch {
              NoLongerNeeded => raise Thrown("CardNoLongerNeeded", "")
              PreparationNeeded => raise Thrown("CardPreparationNeeded", "")
              e => raise e
            }
            Null
          }),
        )
      }
      at_i(Some(w.store_insert_message(message, extra~)), 0).unwrap_or(Null)
    } catch {
      NoLongerNeeded | Thrown("CardNoLongerNeeded", _) => return Null
      PreparationNeeded | Thrown("CardPreparationNeeded", _) => {
        if !w.has("prepareCardPosts") {
          raise (occupied.unwrap())("card lookup is not ready")
        }
        w.hub("prepareCardPosts", [ja([tid]), undefined_j()]) |> ignore
        continue
      }
      Thrown("MessageWriteBusy", _) => {
        w.sleep(delay)
        delay = @cmp.minimum(delay * 2.0, 250.0)
        continue
      }
      e => raise e
    }
    w.hub_shared(tid, n, session, text)
    return if card is Null { Null } else { posted }
  }
  Null
}

///|
/// Says `text` in `thread` as `session`'s agent, with `card` (Null on a surface without cards): posted, then kept.
pub async fn post_card(
  w : World,
  session : String,
  thread : J,
  text : String,
  card : J,
  occupied : ((String) -> Error)?,
  needed : (async () -> Bool)?,
) -> J {
  let identity = message_identity(w, session)
  let row = at(Some(thread), "thread")
  let posted = w.chat(str_of(at(Some(thread), "connect")).unwrap_or(""), "post", [thread_ref(row), js(text), ja([])])
  record_posted_card(w, session, thread, text, card, posted, occupied, needed, identity)
}

///|
/// `hub.actors.get(key)?.messageIdentity() ?? undefined`.
pub async fn message_identity(w : World, key : String) -> J? {
  match w.actor(key, "messageIdentity", []) {
    Null => None
    i => Some(i)
  }
}
