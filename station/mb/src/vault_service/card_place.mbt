// Where a long-lived operation's card stands (station/src/sessions/card-place.ts): its request can outlive a question
// card closed by a chat message. The vault's requests and sign-ins post their cards through it.

///|
/// A call given up by its caller (an `AbortSignal`'s): what waits on it stops, saying so.
pub struct Signal {
  mut aborted : Bool
}

///|
pub fn Signal::new() -> Signal {
  { aborted: false }
}

///|
pub fn Signal::abort(self : Signal) -> Unit {
  self.aborted = true
}

///|
/// What a given-up call raises (`signal.throwIfAborted()`).
pub suberror Aborted

///|
pub impl Show for Aborted with output(_, logger) {
  logger.write_string("This operation was aborted")
}

///|
fn throw_if_aborted(signal : Signal?) -> Unit raise Aborted {
  if signal is Some(s) && s.aborted {
    raise Aborted
  }
}

///|
/// What is left when another card waits in the conversation.
pub let card_occupied : String = "Another card is pending in that conversation. Resolve or withdraw it before asking this again."

///|
/// A bounded card header (its ts), or None where an old thread must be prepared first (Some(None): none waits).
fn card_header_if_ready(store : Store, thread : Int) -> String?? {
  match store.pending_card_header_if_ready {
    Some(f) => f(thread)
    None => Some((store.pending_card_header)(thread))
  }
}

///|
/// Whether this exact card, another card, or no card is waiting in the original conversation.
pub(all) enum CardState {
  Same
  Other
  NoCard
} derive(Eq)

///|
/// The original conversation and its card's state; None where the operation was asked on a surface without its own
/// card (Some(None) of `ready`: an old thread to prepare first).
fn card_place(store : Store, session : String, thread : Int?, ts : String?) -> (Thread, CardState)?? raise {
  guard thread is Some(t) && ts is Some(ts) else { return Some(None) }
  let where_ = match (store.session_thread_by_id)(session, t) {
    Some(w) => w
    None => raise Failure("the original conversation is no longer available to this session")
  }
  match card_header_if_ready(store, t) {
    None => None
    Some(None) => Some(Some((where_, NoCard)))
    Some(Some(current)) => Some(Some((where_, if current == ts { Same } else { Other })))
  }
}

///|
priv suberror CardPreparationNeeded

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
impl Show for CardPreparationNeeded with output(self, logger) {
  match self {
    CardPreparationNeeded => logger.write_string("the card is to be prepared again")
  }
}

///|
priv suberror CardNoLongerNeeded

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
impl Show for CardNoLongerNeeded with output(self, logger) {
  match self {
    CardNoLongerNeeded => logger.write_string("the card is no longer needed")
  }
}

///|
/// Once the surface has given the post its ts, it is recorded only while the request and card are still valid; the
/// second check runs inside the insert's write. A busy writer or an old index is waited for outside it. The card's ts,
/// None where there is no card (or it is no longer needed).
async fn record_posted_card(
  w : World,
  session : String,
  thread : Thread,
  text : String,
  card : Json?,
  posted : String,
  occupied : ((String) -> Error)?,
  needed? : () -> Bool raise,
  identity? : Json,
  signal? : Signal,
) -> String? {
  let hub = w.hub
  let fields = [
    ("thread", ji(thread.id)),
    ("ts", js(posted)),
    ("authorKind", js("agent")),
    ("author", js(session)),
    ("text", js(text)),
    ("attachments", jarr([])),
    ("declared", Json::null()),
    ("card", card.unwrap_or(Json::null())),
  ]
  if identity is Some(i) {
    fields.push(("agentIdentity", i))
  }
  let message = obj(fields)
  let check = fn() raise {
    throw_if_aborted(signal)
    if needed is Some(n) && !n() {
      raise CardNoLongerNeeded
    }
    let refuse = (why : String) => match occupied {
      Some(o) => o(why)
      None => Failure(why)
    }
    if (hub.store.session_thread_by_id)(session, thread.id) is None {
      raise refuse("the original conversation is no longer available to this session")
    }
    match card_header_if_ready(hub.store, thread.id) {
      None => raise CardPreparationNeeded
      Some(Some(_)) => raise refuse(card_occupied)
      Some(None) => ()
    }
  }
  let mut delay = 10.0
  while true {
    throw_if_aborted(signal)
    let n = (fn() -> Int raise {
      if occupied is Some(_) {
        check()
      }
      (hub.store.insert_message)(message, if occupied is Some(_) { Some(check) } else { None })
    })() catch {
      CardNoLongerNeeded => return None
      CardPreparationNeeded => {
        match hub.prepare_card_posts {
          None =>
            match occupied {
              Some(o) => raise o("card lookup is not ready")
              None => raise Failure("card lookup is not ready")
            }
          Some(prepare) => prepare([thread.id])
        }
        continue
      }
      WriteBusy => {
        (w.sleep)(delay)
        throw_if_aborted(signal)
        delay = (delay * 2.0).min(250.0)
        continue
      }
      e => raise e
    }
    (hub.shared)(thread.id, n, session, text)
    return if card is Some(_) { Some(posted) } else { None }
  }
  None
}

///|
/// Says `text` in `thread` as `session`'s agent, with `card` (None on a surface without cards): posted, then kept as
/// the agent's message. The card's ts, or None with none.
async fn post_card(
  w : World,
  session : String,
  thread : Thread,
  text : String,
  card : Json?,
  occupied : ((String) -> Error)?,
  needed? : () -> Bool raise,
  signal? : Signal,
) -> String? {
  let identity = (w.hub.identity)(session)
  throw_if_aborted(signal)
  let posted = (w.hub.post)(thread.connect, thread.channel, thread.thread_ts, text)
  // A non-card surface has already delivered the message; finish recording it even if the caller leaves.
  record_posted_card(
    w,
    session,
    thread,
    text,
    card,
    posted,
    occupied,
    needed?,
    identity?,
    signal?=if card is Some(_) { signal } else { None },
  )
}
