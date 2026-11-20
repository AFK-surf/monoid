// What a grant's card is posted and found by (station/src/sessions/card-place.ts): delegates to @session_chats
// through a thin World adapter.

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
fn as_chats(w : World) -> @session_chats.World {
  {
    call: async fn(name, args) {
      match name {
        "hub.storeHas" => w.ask("store.has", args)
        "actor.messageIdentity" => w.ask("hub.identity", args)
        "wall.sleep" => {
          w.sleep(num_of(args.get(0)).unwrap_or(0.0))
          Null
        }
        "store.insertMessage" if args.length() == 2 && undefined(args[1]) =>
          w.ask(name, [args[0]])
        "hub.prepareCardPosts" if args.length() == 2 && undefined(args[1]) =>
          w.ask(name, [args[0]])
        _ => w.ask(name, args)
      }
    },
    callback: w.callback,
    words: w.words,
    lang: Ref(w.lang),
    thrown: Ref(Null),
  }
}

///|
/// card-place.ts `cardHeaderIfReady`: a bounded card header, Some(Null) for none, None where an old thread must be
/// prepared first.
pub async fn card_header_if_ready(w : World, thread : J) -> J? {
  @session_chats.card_header_if_ready(as_chats(w), thread)
}

///|
/// card-place.ts `cardPlace`: Some(Null) where none was asked, None where not ready, else the conversation and whether
/// this card, another or none waits there.
pub async fn card_place(w : World, session : String, thread : J, ts : J) -> J? {
  @session_chats.card_place(as_chats(w), session, thread, ts)
}

///|
pub let card_occupied : String = @session_chats.card_occupied

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
  @session_chats.record_posted_card(
    as_chats(w), session, thread, text, card, posted, occupied, needed, identity,
  )
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
  @session_chats.post_card(
    as_chats(w), session, thread, text, card, occupied, needed,
  )
}
