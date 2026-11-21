// chat_post (station/src/sessions/conversations.ts `chatPost` and what it rests on: a post held back while messages
// came that its agent had not read, the first post of a relayed chat put into the station's first message there).

///|
/// How chat_post's answer begins when it held the post back.
pub let not_posted : String = "Not posted:"

///|
let held_kept : Int = 20

///|
let send_keys : Array[String] = ["to", "send", "kind", "need", "done", "about"]

///|
fn kind_kind(kind : J) -> String {
  str_of(at(Some(kind), "kind")).unwrap_or("")
}

///|
/// args.ts `declaredStr`.
pub fn declared_str(kind : J) -> String {
  match kind_kind(kind) {
    "all_done" => "all_done"
    "need_help" => "need_help"
    _ => "waiting"
  }
}

///|
/// args.ts `saidAs`.
pub fn said_as(kind : J) -> String {
  if kind_kind(kind) == "need_help" {
    "need_human"
  } else {
    declared_str(kind)
  }
}

///|
/// args.ts `aboutTs`.
pub fn about_ts(args : J) -> String? {
  match at(Some(args), "about") {
    None | Some(Null) => None
    Some(v) => {
      let t = trim(js_string(v))
      if t == "" {
        None
      } else {
        Some(t)
      }
    }
  }
}

///|
fn address_of_row(row : J?) -> String {
  thread_address(str_of(at(row, "channel")).unwrap_or(""), str_of(at(row, "threadTs")).unwrap_or(""))
}

///|
fn archived_by_hand(row : J?) -> Thrown {
  fail_("\{address_of_row(row)} was archived by hand: it takes no messages until someone restores it")
}

///|
/// A post as the agent gave it and, sent by send, its id.
pub(all) struct Held {
  id : String?
  args : J
}

///|
/// chat_post's arguments with a held post sent by send put back as it was written; its state is what this call gives.
pub fn unheld(w : World, key : String, args : J) -> Held raise {
  guard at(Some(args), "send") is Some(send) else { return { id: None, args } }
  if keys_of(Some(args)).iter().any(k => !send_keys.contains(k)) {
    raise fail_("send takes only to, send and the state (kind, need, done, about): the held post goes as it was written")
  }
  let id = js_string(send)
  let held = match w.require_live().state.held.get(key).bind(m => m.get(id)) {
    Some(h) if !is_undefined(h) && !(h is Null) => h
    _ => raise fail_("no held post \{id}: it was sent already, or the station restarted since; write the post again")
  }
  let to = at(Some(args), "to")
  let held_to = at(Some(held), "to")
  let same = match (to, held_to) {
    (Some(a), Some(b)) => jeq(a, b)
    (None, None) => true
    _ => false
  }
  if !same {
    raise fail_("held post \{id} goes to \{match held_to { Some(v) => js_string(v); None => "undefined" }}")
  }
  { id: Some(id), args: spread(held, without(args, ["send"])) }
}

///|
/// A new id for a post held back from session `key`.
fn hold(w : World, key : String) -> String raise {
  let st = w.require_live().state
  let m = match st.held.get(key) {
    Some(m) => m
    None => {
      let m : Map[String, J] = Map([])
      st.held[key] = m
      m
    }
  }
  while m.length() >= held_kept {
    if m.keys().next() is Some(k) { m.remove(k) } else { break }
  }
  st.held_count += 1
  "held-\{st.held_count}"
}

///|
/// The ts of the messages in the thread before entry `n` the session has not read.
async fn unseen_in(w : World, key : String, thread : J, n : Double) -> Array[String] {
  let pending = arr_of(Some(w.with_threads_j(t => t.pending_before(Json::string(key), thread.to_json(), Json::number(n))))).unwrap_or([])
  let unread = arr_of(Some(w.actor(key, "unreadIn", [thread, jn(n)]))).unwrap_or([])
  let out : Array[String] = []
  for p in pending {
    let s = js_string_of(Some(p))
    if !out.contains(s) {
      out.push(s)
    }
  }
  for m in unread {
    let s = js_string_of(at(at(Some(m), "message"), "ts"))
    if !out.contains(s) {
      out.push(s)
    }
  }
  out
}

///|
async fn unread_before(w : World, key : String, thread : J, n : J) -> String {
  let ts = unseen_in(w, key, thread, num_of(Some(n)).unwrap_or(0.0))
  if ts.length() == 0 {
    return ""
  }
  let one = ts.length() == 1
  " Before this post went up, \{if one { "a message" } else { "messages" }} you had not read yet came in this thread (ts \{ts.join(", ")}): written without seeing your post, \{if one { "it comes" } else { "they come" }} to you next."
}

///|
/// The agent's first post in a conversation its chat was relayed to: added under the station's first message there.
/// That message's ts and number, or None where it is posted as a reply.
async fn into_opening(
  w : World,
  key : String,
  connect : String,
  thread : J,
  text : String,
  check_turn : async () -> Unit,
) -> (J, J)? {
  let tid = at(Some(thread), "id").unwrap_or(Null)
  let openings = w.require_live().state.openings
  let okey = tid.to_json().stringify()
  let pending = openings.get(okey).unwrap_or(Null)
  if pending is Null || str_of(at(Some(pending), "session")) != Some(key) {
    return None
  }
  if at(Some(pending), "claimed") is Some(Bool(true)) {
    openings.remove(okey)
    return None
  }
  let set_claimed = (claimed : Bool) => match openings.get(okey) {
    Some(Obj(fs)) => openings[okey] = Obj([..fs.filter(f => @jsjson.sanitize_str(f.0) != "claimed"), ("claimed", jb(claimed))])
    _ => ()
  }
  set_claimed(true)
  let mut retry = false
  let mut edited = false
  let pts = at(Some(pending), "ts").unwrap_or(Null)
  let finish = fn() {
    if openings.contains(okey) {
      if retry { set_claimed(false) } else { openings.remove(okey) }
    }
  }
  let result = try {
    if !(w.ask("hub.chatHas", [js(connect), js("edit")]) is Bool(true)) {
      finish()
      return None
    }
    let prepare = w.has("prepareLegacyEdits")
    let mut opening = if prepare {
      w.with_threads_opt(t => t.message_at_if_ready(tid.to_json(), pts.to_json()))
    } else {
      Some(w.with_threads_j(t => t.message_at(tid.to_json(), pts.to_json())))
    }
    let mut waited = false
    while opening is None {
      waited = true
      w.hub("prepareLegacyEdits", [js("<effect>")]) |> ignore
      opening = w.with_threads_opt(t => t.message_at_if_ready(tid.to_json(), pts.to_json()))
    }
    if waited {
      let current = w.with_threads_j(t => t.session_thread(Json::string(key), at(Some(thread), "channel").unwrap_or(Null).to_json(), at(Some(thread), "threadTs").unwrap_or(Null).to_json()))
      if nullish(Some(current)) ||
        !jeq(at(at(Some(current), "thread"), "id").unwrap_or(Null), tid) ||
        str_of(at(Some(current), "connect")).unwrap_or("") != connect {
        raise fail_("the conversation changed while preparing its first message; try again")
      }
      if w.store_manually_archived(tid) {
        raise fail_("the conversation was archived while preparing its first message; restore it first")
      }
    }
    let opening = opening.unwrap()
    if opening is Null {
      finish()
      return None
    }
    let whole = "\{str_of(at(Some(opening), "text")).unwrap_or("")}\n\n\{text}"
    check_turn()
    let ok = try {
      w.chat(connect, "edit", [thread_ref(Some(thread)), pts, js(whole)]) is Bool(true)
    } catch {
      e => {
        w.log(
          "warn",
          "hub",
          "a relayed chat's first post did not go into the station's first message",
          jo([("thread", tid), ("error", js(thrown_message(e)))]),
        )
        false
      }
    }
    if !ok {
      finish()
      return None
    }
    edited = true
    let surface = at(Some(thread), "surface").unwrap_or(Null)
    let channel = at(Some(thread), "channel").unwrap_or(Null)
    let thread_ts = at(Some(thread), "threadTs").unwrap_or(Null)
    while w.with_threads_opt(t => t.edit_message_if_ready(surface.to_json(), channel.to_json(), thread_ts.to_json(), pts.to_json(), Json::string(whole))) is None {
      w.hub("prepareLegacyEdits", []) |> ignore
    }
    (pts, at(Some(opening), "n").unwrap_or(Null))
  } catch {
    e => {
      if edited {
        finish()
        raise fail_("The first message was updated on the platform, but could not be recorded here: \{thrown_message(e)}")
      }
      retry = true
      finish()
      raise e
    }
  }
  finish()
  Some(result)
}

///|
/// chat_post: a message to one of the session's conversations, maybe with files and a card, maybe ending its turn.
pub async fn chat_post(w : World, key : String, args : J, held : Held) -> String {
  let identity = message_identity(w, key)
  if at(Some(args), "withdraw") is Some(withdraw) {
    if keys_of(Some(args)).iter().any(k => k != "to" && k != "withdraw") {
      raise fail_("withdraw uses only to and withdraw; post updates and record your ending separately")
    }
    let ts = match withdraw {
      Str(u) if trim(@jsjson.sanitize_str(u)) != "" => @jsjson.sanitize_str(u)
      _ => raise fail_("withdraw must be your question's message ts")
    }
    let thread = target(w, key, at(Some(args), "to"))
    let tid = at(at(Some(thread), "thread"), "id").unwrap_or(Null)
    let vault = at(Some(w.with_threads_j(t => t.card_at(tid.to_json(), Json::string(ts)))), "vault")
    match str_of(at(vault, "request")) {
      Some(r) =>
        raise fail_(
          "That card is the vault request \{r}: withdraw it with secret_cancel {request: \"\{r}\"}, which closes its card too.",
        )
      None => ()
    }
    if !(w.with_threads_j(t => t.withdraw_card(Json::string(key), tid.to_json(), Json::string(ts))) is Bool(true)) {
      raise fail_("withdraw must name your own message with a card in this conversation")
    }
    return "Withdrew the answer card; its message is kept. Continue your work and record the appropriate ending state."
  }
  if at(Some(args), "title") is Some(title) && at(Some(args), "text") is None && at(Some(args), "files") is None {
    if keys_of(Some(args)).iter().any(k => k != "to" && k != "title") {
      raise fail_("titling alone uses only to and title; post updates and record your ending separately")
    }
    let t = match title {
      Str(u) if clean_title(@jsjson.sanitize_str(u)) != "" => @jsjson.sanitize_str(u)
      _ => raise fail_("title is empty")
    }
    let thread = target(w, key, at(Some(args), "to"))
    let row = at(Some(thread), "thread")
    if w.store_manually_archived(at(row, "id").unwrap_or(Null)) {
      raise archived_by_hand(row)
    }
    let said = trim(name_chat(w, row.unwrap_or(Null), t))
    return if said == "" { "The chat already has that title." } else { said }
  }
  let mut text = match at(Some(args), "text") {
    None => ""
    Some(v) => trim(js_string(v))
  }
  let paths = match at(Some(args), "files") {
    Some(Arr(xs)) => xs.map(js_string)
    _ => []
  }
  let given = hub_ok(() => @session_hub.state_arg(opt_json(at(Some(args), "kind"))))
  let card = match hub_ok(() => @session_hub.card_arg(opt_json(at(Some(args), "card")), opt_json(at(Some(args), "options")))) {
    Some(c) => @jsjson.JValue::of_json(c)
    None => Null
  }
  let (kind, given_said) = match given {
    Some((k_json, said)) => (@jsjson.JValue::of_json(k_json), Some(said))
    None => (Null, None)
  }
  if given_said == Some("decision") && card is Null {
    raise fail_(
      "need_decision carries options: a card {\"type\": \"options\", \"options\": [...]} people pick from (or end with kind \"need_human\" and say in need what they have to decide)",
    )
  }
  let mut need = match given {
    None => need_arg_of(args, { "kind": Json::string("waiting"), "seconds": Json::number(0.0) }, "now")
    Some((k_json, said)) => need_arg_of(args, k_json, said)
  }
  if need is Null && !(given is None) && kind_kind(kind) == "need_help" && given_said != Some("now") && !(card is Null) {
    let line = @session_hub.first_line(text)
    if line != "" {
      need = js(line)
    }
  }
  if kind is Null && !nullish(at(Some(args), "about")) {
    raise fail_("about goes with kind: the message the state this post records is about")
  }
  if text == "" && paths.length() == 0 {
    raise fail_("text is empty")
  }
  let thread = target(w, key, at(Some(args), "to"))
  let row = at(Some(thread), "thread")
  let tid = at(row, "id").unwrap_or(Null)
  let connect = str_of(at(Some(thread), "connect")).unwrap_or("")
  let surface = str_of(at(row, "surface")).unwrap_or("")
  if w.store_manually_archived(tid) {
    raise archived_by_hand(row)
  }
  match str_of(at(Some(card), "assignee")) {
    Some(a) =>
      match runner_assignee(w, tid, a) {
        Some(refused) => raise fail_(refused)
        None => ()
      }
    None => ()
  }
  let card_type = str_of(at(Some(card), "type"))
  let login_cards = w.ask("hub.chatProp", [js(connect), js("loginCards")]) is Bool(true)
  let page = if card_type == Some("login") && login_cards && at(Some(card), "station") is None {
    if w.has("logins") {
      w.ask("logins.page", [js(js_string_of(at(Some(card), "login")))])
    } else {
      J::Null
    }
  } else {
    J::Null
  }
  let page = if is_undefined(page) { J::Null } else { page }
  let login_here = !(page is Null)
  let shown = if login_here {
    set_field(card, "page", page)
  } else if card_type == Some("login") && surface != stillfail_surface {
    J::Null
  } else {
    card
  }
  let cards_shown = w.ask("hub.chatProp", [js(connect), js("cards")]) is Bool(true)
  if !(card is Null) &&
    surface != stillfail_surface &&
    !(cards_shown && (card_type == Some("options") || card_type == Some("text"))) &&
    card_type != Some("login") {
    raise fail_(
      "cards (options, a text field) are not shown here; write the choices or the question in the text and end with kind \"need_human\"",
    )
  }
  if !(card is Null) && text == "" {
    raise fail_("text is required with a card: what it asks and the facts it turns on, so it can be answered from this message alone")
  }
  let mut about = J::Null
  let ts = about_ts(args)
  let need_help = kind_kind(kind) == "need_help"
  let checking_question = need_help && ts is Some(_)
  let checking_default = need_help && ts is None
  let guarded = checking_question || checking_default
  let question_actor = if guarded { actor_id(w, key) } else { J::Null }
  let question_turn = if guarded && !(question_actor is Null) { w.actor(key, "currentTurnId", []) } else { J::Null }
  let check_question_turn = async fn() {
    if guarded && !(question_actor is Null) && !(question_turn is Null) {
      if !jeq(actor_id(w, key), question_actor) || !jeq(w.actor(key, "currentTurnId", []), question_turn) {
        raise fail_("the turn ended while checking its question; no message was posted")
      }
    }
  }
  let question_threads : Ref[(async () -> Array[J])?] = Ref::new(None)
  if ts is Some(t) {
    if checking_question {
      let threads_of = async fn() {
        let current = target(w, key, at(Some(args), "to"))
        if !jeq(at(at(Some(current), "thread"), "id").unwrap_or(Null), tid) ||
          str_of(at(Some(current), "connect")) != Some(connect) {
          raise fail_("the conversation changed while checking the question; try again")
        }
        if w.store_manually_archived(at(at(Some(current), "thread"), "id").unwrap_or(Null)) {
          raise archived_by_hand(at(Some(current), "thread"))
        }
        [at(at(Some(current), "thread"), "id").unwrap_or(Null)]
      }
      question_threads.val = Some(threads_of)
      about = question_for_about(w, key, threads_of, t)
      check_question_turn()
    } else {
      about = message_for_about(w, key, tid, t, need_help)
    }
    if about is Null {
      raise fail_(
        "about must be the ts of a message in \{address_of_row(row)} (or leave it out), got \{t}",
      )
    }
    if need_help && !(card is Null) {
      raise fail_("a new card is this post's question: omit about so the wait points to it")
    }
  }
  let unseen = unseen_in(w, key, tid, 9007199254740991.0)
  if unseen.length() > 0 {
    let id = match held.id {
      Some(i) => i
      None => hold(w, key)
    }
    let post = without(held.args, ["kind", "need", "done", "about"])
    if w.require_live().state.held.get(key) is Some(m) { m[id] = post }
    let one = unseen.length() == 1
    return "\{not_posted} \{if one { "a message" } else { "messages" }} you had not read came in \{address_of_row(row)} (ts \{unseen.join(", ")}), and \{if one { "it comes" } else { "they come" }} to you next; no state was recorded. Held as \{id}. After reading \{if one { "it" } else { "them" }}, if this post still stands as written, call chat_post with to, send=\"\{id}\" and the state the turn now ends with (kind, need, done, about), without writing it again; otherwise post what fits now."
  }
  if held.id is Some(i) {
    if w.require_live().state.held.get(key) is Some(m) { m.remove(i) }
  }
  if surface == stillfail_surface {
    let srow = w.store_get_session(key)
    if srow is Null {
      raise fail_("unknown session")
    }
    text = prepare(w, text, paths, str_of(at(Some(srow), "workspace")).unwrap_or(""))
  }
  let slack = surface != stillfail_surface && paths.length() > 0
  let link = fn() raise {
    match w.hub_link(key) {
      Some(l) => l
      None =>
        raise fail_(
          "files cannot be shown from Slack until this station is in a still.fail workspace; mention their paths in the text instead",
        )
    }
  }
  let attached = if paths.length() == 0 { J::Arr([]) } else { attach(w, key, paths, key) }
  let data_dir = str_of(at(Some(w.config()), "dataDir")).unwrap_or("")
  let files = w.dep("keep", [attached, js(join_path([data_dir, "thumbs"]))])
  let no_files = arr_of(Some(files)).unwrap_or([]).length() == 0
  check_question_turn()
  let here = thread_ref(row)
  let opening = if card is Null && no_files {
    into_opening(w, key, connect, row.unwrap_or(Null), text, check_question_turn)
  } else {
    None
  }
  let mut posted = J::Null
  let mut n = J::Null
  match opening {
    Some((p, m)) => {
      posted = p
      n = m
    }
    None => {
      check_question_turn()
      if slack {
        try {
          posted = w.chat(connect, "post", [here, js(text), files, shown])
          text = @session_hub.place_figures(text, json_items(files))
        } catch {
          e => {
            if !thrown_message(e).contains("missing_scope") {
              raise e
            }
            let (posted_text, rest) = @session_hub.slack_with_files(w.words.to_hub(w.lang.val), text, json_items(files), link())
            posted = w.chat(connect, "post", [here, js(posted_text), ja([])])
            text = rest
          }
        }
      } else {
        posted = w.chat(connect, "post", [here, js(text), files, shown])
      }
      let fields = [
        ("thread", tid),
        ("ts", posted),
        ("authorKind", js("agent")),
        ("author", js(key)),
        ("text", js(text)),
        ("attachments", files),
        ("declared", if kind is Null { J::Null } else { js(declared_str(kind)) }),
        ("card", card),
      ]
      if identity is Some(i) {
        fields.push(("agentIdentity", i))
      }
      n = at_i(Some(w.store_insert_message(jo(fields))), 0).unwrap_or(Null)
    }
  }
  let offered = if card is Null {
    ""
  } else {
    "\{@session_hub.card_said(card.to_json())} Card message ts: \{js_string_of(Some(posted))}."
  }
  w.hub_shared(tid, n, key, text)
  let actor = if guarded { question_actor } else { actor_id(w, key) }
  let has_actor = !(actor is Null)
  if guarded {
    if has_actor && !(question_turn is Null) && jeq(actor_id(w, key), actor) {
      w.actor(key, "postedForTurn", [question_turn]) |> ignore
    }
  } else if has_actor {
    w.actor(key, "postedNow", []) |> ignore
  }
  if kind is Null && has_actor {
    w.actor(key, "goesOn", []) |> ignore
  }
  if !guarded && !(need is Null) && has_actor {
    w.actor(key, "need", [need]) |> ignore
  }
  let mut recorded = true
  let mut state_error : String? = None
  if !(kind is Null) {
    let threads_here = async fn() {
      let current = w.store_session_thread_by_id(key, tid)
      if !(current is Null) && str_of(at(Some(current), "connect")) == Some(connect) {
        [tid]
      } else {
        []
      }
    }
    if about is Null && need_help {
      try {
        about = pending_for_state(w, key, threads_here)
      } catch {
        e => {
          recorded = false
          state_error = Some(thrown_message(e))
        }
      }
    }
    if guarded {
      if recorded && has_actor && !(question_turn is Null) {
        try {
          if checking_question && ts is Some(t) && question_threads.val is Some(threads_of) && !(about is Null) {
            recorded = jeq(actor_id(w, key), actor) &&
              record_question_for_turn(
                w,
                key,
                question_turn,
                kind,
                need,
                about,
                false,
                threads_of,
                t,
                "about must be the ts of a message in \{address_of_row(row)} (or leave it out), got \{t}",
              )
          } else if checking_default {
            recorded = record_pending_for_turn(
              w,
              key,
              actor,
              question_turn,
              kind,
              need,
              about,
              false,
              threads_here,
              !(card is Null) || !(about is Null),
            )
          }
        } catch {
          e => {
            recorded = false
            state_error = Some(thrown_message(e))
          }
        }
      }
    } else if has_actor {
      w.actor(key, "about", [about]) |> ignore
      recorded = w.actor(key, "declare", [kind]) is Bool(true)
    }
  }
  let titled = match at(Some(args), "title") {
    Some(Str(u)) => name_chat(w, row.unwrap_or(Null), @jsjson.sanitize_str(u))
    _ => ""
  }
  let place = address_of_row(row) +
    (match opening {
      Some(_) => " (added to the station's first message there, ts \{js_string_of(Some(posted))})"
      None => ""
    })
  let crossed = unread_before(w, key, tid, n)
  if !(kind is Null) {
    if recorded {
      "Posted to \{place}, and recorded state \{said_as(kind)}.\{crossed}\{titled}\{offered}"
    } else {
      match state_error {
        Some(err) => "Posted to \{place}, but its state was not recorded: \{err}.\{crossed}\{titled}\{offered}"
        None => "Posted to \{place}, but its turn ended before its state was recorded.\{crossed}\{titled}\{offered}"
      }
    }
  } else {
    "Posted to \{place}.\{crossed}\{titled}\{offered}"
  }
}
