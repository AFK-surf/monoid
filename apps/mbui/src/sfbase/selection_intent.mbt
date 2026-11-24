// Experimental selection intent inference state: holds the selected passage, the in-flight `chat.selectionIntent` call,
// and the lightweight model's inferred intent and direct reply.

///|
pub(all) struct SelectionIntentState {
  station : @signals.Signal[String]
  thread : @signals.Signal[Double]
  draft : @signals.Signal[String]
  selection : @signals.Signal[String]
  message_ts : @signals.Signal[String]
  author : @signals.Signal[String]
  role : @signals.Signal[String]
  loading : @signals.Signal[Bool]
  intent : @signals.Signal[String]
  reply : @signals.Signal[String]
  model : @signals.Signal[String]
  error : @signals.Signal[String]
}

///|
// kept across runs: reset by selection_intent_reset()
pub let selection_intent : SelectionIntentState = {
  station: @signals.signal("", same=fn(a, b) { a == b }),
  thread: @signals.signal(-1.0, same=fn(a, b) { a == b }),
  draft: @signals.signal("", same=fn(a, b) { a == b }),
  selection: @signals.signal("", same=fn(a, b) { a == b }),
  message_ts: @signals.signal("", same=fn(a, b) { a == b }),
  author: @signals.signal("", same=fn(a, b) { a == b }),
  role: @signals.signal("", same=fn(a, b) { a == b }),
  loading: @signals.signal(false, same=fn(a, b) { a == b }),
  intent: @signals.signal("", same=fn(a, b) { a == b }),
  reply: @signals.signal("", same=fn(a, b) { a == b }),
  model: @signals.signal("", same=fn(a, b) { a == b }),
  error: @signals.signal("", same=fn(a, b) { a == b }),
}

///|
/// Serial of the latest inference request so a stale reply cannot overwrite a newer one or a closed panel.
// kept across runs: only counts on
let selection_intent_serial : Ref[Int] = Ref(0)

///|
pub fn selection_intent_reset() -> Unit {
  selection_intent_serial.val = selection_intent_serial.val + 1
  selection_intent.station.set("")
  selection_intent.thread.set(-1.0)
  selection_intent.draft.set("")
  selection_intent.selection.set("")
  selection_intent.message_ts.set("")
  selection_intent.author.set("")
  selection_intent.role.set("")
  selection_intent.loading.set(false)
  selection_intent.intent.set("")
  selection_intent.reply.set("")
  selection_intent.model.set("")
  selection_intent.error.set("")
}

///|
fn selection_intent_run(src : Source) -> Unit {
  let station = @signals.untracked(fn() { selection_intent.station.get() })
  let thread = @signals.untracked(fn() { selection_intent.thread.get() })
  let selection = @signals.untracked(fn() { selection_intent.selection.get() })
  let message_ts = @signals.untracked(fn() { selection_intent.message_ts.get() })
  let author = @signals.untracked(fn() { selection_intent.author.get() })
  guard station != "" && thread >= 0.0 && selection != "" else { return }
  selection_intent_serial.val = selection_intent_serial.val + 1
  let seq = selection_intent_serial.val
  selection_intent.loading.set(true)
  selection_intent.intent.set("")
  selection_intent.reply.set("")
  selection_intent.model.set("")
  selection_intent.error.set("")
  let params : Map[String, Json] = {
    "station": Json::string(station),
    "thread": Json::number(thread),
    "selection": Json::string(selection),
  }
  if message_ts != "" {
    params["messageTs"] = Json::string(message_ts)
  }
  if author != "" {
    params["author"] = Json::string(author)
  }
  (src.call)("chat.selectionIntent", Json::object(params), fn(res) {
    if selection_intent_serial.val != seq {
      return
    }
    selection_intent.loading.set(false)
    match res {
      Ok(v) => {
        selection_intent.intent.set(text(Some(v), "intent"))
        selection_intent.reply.set(text(Some(v), "reply"))
        selection_intent.model.set(text(Some(v), "model"))
      }
      Err(e) => selection_intent.error.set(error_words(e))
    }
  })
}

///|
/// Starts an intent-inference request for a selected passage in chat `thread` of `station`.
pub fn selection_intent_ask(
  src : Source,
  station : String,
  thread : Double,
  draft : String,
  selection : String,
  message_ts : String,
  author : String,
  role : String,
) -> Unit {
  selection_intent.station.set(station)
  selection_intent.thread.set(thread)
  selection_intent.draft.set(draft)
  selection_intent.selection.set(selection)
  selection_intent.message_ts.set(message_ts)
  selection_intent.author.set(author)
  selection_intent.role.set(role)
  selection_intent_run(src)
}

///|
/// Retries the current selection intent request after a failure.
pub fn selection_intent_retry(src : Source) -> Unit {
  selection_intent_run(src)
}

///|
/// A pinned selection-intent reply kept floating in its chat until unpinned.
#derive(Eq)
pub(all) struct PinnedIntent {
  id : Int
  draft : String
  selection : String
  intent : String
  reply : String
  model : String
  collapsed : Bool
}

///|
// kept across runs: reset by selection_intent_pins_reset()
pub let pinned_intents : @signals.Signal[Array[PinnedIntent]] = @signals.signal([], same=fn(a, b) { a == b })

///|
// kept across runs: only counts on
let pinned_intent_serial : Ref[Int] = Ref(0)

///|
pub fn selection_intent_pins_reset() -> Unit {
  pinned_intents.set([])
}

///|
/// Pins the current inferred reply into its chat (deduplicating identical selection+reply in the same chat).
pub fn selection_intent_pin() -> Bool {
  let draft = @signals.untracked(fn() { selection_intent.draft.get() })
  let selection = @signals.untracked(fn() { selection_intent.selection.get() })
  let intent = @signals.untracked(fn() { selection_intent.intent.get() })
  let reply = @signals.untracked(fn() { selection_intent.reply.get() })
  let model = @signals.untracked(fn() { selection_intent.model.get() })
  guard draft != "" && reply != "" else { return false }
  let cur = @signals.untracked(fn() { pinned_intents.get() })
  if cur.iter().any(fn(p) { p.draft == draft && p.selection == selection && p.reply == reply }) {
    return true
  }
  pinned_intent_serial.val = pinned_intent_serial.val + 1
  let next = cur.copy()
  next.push({ id: pinned_intent_serial.val, draft, selection, intent, reply, model, collapsed: false })
  pinned_intents.set(next)
  true
}

///|
/// Removes a pinned reply by its id.
pub fn selection_intent_unpin(id : Int) -> Unit {
  let cur = @signals.untracked(fn() { pinned_intents.get() })
  pinned_intents.set(cur.filter(fn(p) { p.id != id }))
}

///|
/// Toggles collapsed/expanded state of a pinned reply card.
pub fn selection_intent_toggle_collapse(id : Int) -> Unit {
  let cur = @signals.untracked(fn() { pinned_intents.get() })
  pinned_intents.set(
    cur.map(fn(p) { if p.id == id { { ..p, collapsed: !p.collapsed } } else { p } }),
  )
}

///|
/// All pinned intent replies belonging to chat `draft`.
pub fn pinned_intents_for(draft : String) -> Array[PinnedIntent] {
  pinned_intents.get().filter(fn(p) { p.draft == draft })
}
