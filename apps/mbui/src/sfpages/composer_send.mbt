// What is written going into a chat once the core has taken it off the draft (composer.take's answer): one way for a
// chat's composer (send_in_chat) and a new chat's first message (new_chat.mbt's new_send), whichever view drew it.
// Only what the core answers differs for them: taken into the chat, refused before the chat's outbox had it (back in
// the composer unless something new is written there), or kept in its outbox to go once its station is reached.

///|
/// Where a message goes in its chat: the thread the chat's view names, or, before it names one (a new chat's, an agent's
/// session not threaded yet), its session.
priv enum SendTo {
  ToThread(Double)
  ToSession(String)
}

///|
/// What the core said of a message sent (`chat.send`): taken; refused before its chat's outbox had it (`why`: the core's
/// words; invalid_params, core_restarted, closed); kept in the outbox, which says it did not go yet and sends it once its
/// station is reached (`why`).
priv enum SendAnswer {
  SentTaken
  SentRefused(String)
  SentKept(String)
}

///|
/// What the core took (`taken`: composer.take's answer, its words with the links and paths named after them, the files
/// that are up, the quotes, those still going up) sent to `to` on `station` (`chat.send`), `done` told what it said.
fn send_taken(src : Source, station : String, to : SendTo, taken : Json, done : (SendAnswer) -> Unit) -> Unit {
  let t = Some(taken)
  let params : Map[String, Json] = {
    "station": Json::string(station),
    "text": Json::string(text(t, "text")),
    "attachments": Json::array(items(t, "attachments")),
    "quotes": Json::array(items(t, "quotes")),
  }
  let going = items(t, "uploads")
  if going.length() > 0 {
    params["uploads"] = Json::array(going)
  }
  match to {
    ToThread(th) => params["thread"] = Json::number(th)
    ToSession(s) => params["session"] = Json::string(s)
  }
  (src.call)("chat.send", Json::object(params), fn(res) {
    match res {
      Ok(_) => done(SentTaken)
      Err(e) => {
        let why = text(Some(e), "message")
        match text(Some(e), "code") {
          "invalid_params" | "core_restarted" | "closed" => done(SentRefused(why))
          _ => done(SentKept(why))
        }
      }
    }
  })
}

///|
/// What was sent from here that did not go (sent_refuse), by its key (sent_local's): a chat's list looks for no row of
/// it (chat_body_node's sent_watched).
// kept across runs: cleared by sent_unseen_reset
let sent_refused : Set[String] = Set([])

///|
/// The outbox entries the viewer let go of (`chat.discard`: 删除, or 编辑 taking its words back), by chat (its station and
/// session, `\u{1}` between), each by its row's key ("o:" and its id): what was sent as one of them is looked for no
/// more.
// kept across runs: cleared by sent_unseen_reset
let sent_discarded : Map[String, Set[String]] = Map([])

///|
fn sent_unseen_reset() -> Unit {
  sent_refused.clear()
  sent_discarded.clear()
}

///|
/// What was sent from chat `rk` as `key` did not go (refused, or let go of before the core took it): it leaves the
/// list (sent_local_gone), and the list looks for it no more.
fn sent_refuse(rk : String, key : String) -> Unit {
  sent_refused.insert(key)
  sent_local_gone(rk, key)
}

///|
fn sent_was_refused(key : String) -> Bool {
  sent_refused.contains(key)
}

///|
/// Outbox entry `id` of chat `rk` let go of by the viewer (`chat.discard`).
fn sent_outbox_discarded(rk : String, id : String) -> Unit {
  guard id != "" && !id.has_prefix("local:") else { return }
  match sent_discarded.get(rk) {
    Some(s) => s.insert("o:" + id)
    None => sent_discarded[rk] = Set(["o:" + id])
  }
}

///|
/// Whether the viewer let go of an outbox entry of chat `rk` not among its rows `before` (what was there as words were
/// sent): one they sent since, which they took away themselves.
fn sent_was_discarded_after(rk : String, before : Map[String, Bool]) -> Bool {
  match sent_discarded.get(rk) {
    Some(s) => s.iter().any(fn(k) { !before.contains(k) })
    None => false
  }
}
