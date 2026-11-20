// Named dispatch and clock setter for `Store` (store.ts method names), used by station_main's live store bridge.

///|
fn arg(args : Array[@jsjson.JValue], i : Int) -> @jsjson.JValue? {
  args.get(i)
}

///|
fn jarg(args : Array[@jsjson.JValue], i : Int) -> Json {
  match args.get(i) {
    Some(v) => to_json(v)
    None => Json::null()
  }
}

///|
/// A hook said as data: a statement run on the store's connection, or an error raised.
fn hook(store : Store, spec : @jsjson.JValue?, n : Double?) -> (() -> Unit raise)? {
  match spec {
    None | Some(Null) => None
    Some(s) =>
      Some(() => {
        match jtext(jget(s, "throw")) {
          Some(m) => raise StoreError(m)
          None => ()
        }
        let sql = jtext(jget(s, "sql")).unwrap_or("")
        let params = match jget(s, "args") {
          Some(Arr(xs)) =>
            xs.map(x => match (x, n) {
              (Str(u), Some(v)) if @jsjson.sanitize_str(u) == "$n" => jnum(v)
              _ => to_json(x)
            })
          _ => []
        }
        ignore(store.run(sql, params))
      })
  }
}

///|
fn card_fn(spec : @jsjson.JValue?) -> (@jsjson.JValue?) -> @jsjson.JValue raise {
  was => match spec {
    Some(s) =>
      match (jget(s, "set"), jget(s, "merge")) {
        (Some(v), _) => v
        (_, Some(Obj(fields))) => {
          let mut out = match was {
            Some(Obj(_) as w) => w
            _ => Obj([])
          }
          for f in fields {
            out = jset(out, @jsjson.sanitize_str(f.0), f.1)
          }
          out
        }
        _ => was.unwrap_or(Null)
      }
    None => was.unwrap_or(Null)
  }
}

///|
/// One of the store's calls by its TypeScript name (store.ts), its arguments and answer as JSON: what the station's
/// own parts ask of it by name (station_main's agents' side).
pub fn Store::call(self : Store, op : String, args : Array[@jsjson.JValue]) -> Json raise {
  let s = self
  let a = (i : Int) => jarg(args, i)
  match op {
    "getThread" => s.get_thread(a(0))
    "threadAt" => s.thread_at(a(0), a(1), a(2))
    "threadsAt" => s.threads_at(a(0), a(1))
    "openThread" => s.open_thread(a(0), a(1), a(2), a(3), a(4))
    "threadOfMessage" => s.thread_of_message(a(0), a(1), a(2))
    "joinThread" => s.join_thread(a(0), a(1), a(2))
    "leaveThread" => s.leave_thread(a(0), a(1))
    "leftThread" => s.left_thread(a(0), a(1), a(2), a(3))
    "threadSessions" => s.thread_sessions(a(0))
    "hasActiveWatch" => s.has_active_watch(a(0))
    "hasSessionActiveWatch" => s.has_session_active_watch(a(0))
    "sessionThread" => s.session_thread(a(0), a(1), a(2))
    "sessionThreadById" => s.session_thread_by_id(a(0), a(1))
    "sessionHomeThread" => s.session_home_thread(a(0))
    "ccThreads" => s.cc_threads(a(0))
    "sessionThreads" => s.session_threads(a(0), a(1))
    "recentSessionThreads" => s.recent_session_threads(a(0), a(1))
    "latestThreadIfReady" => s.latest_thread_if_ready(a(0))
    "latestThread" => s.latest_thread(a(0))
    "sessionChat" => s.session_chat(a(0))
    "listThreads" => s.list_threads(a(0), a(1), a(2), a(3))
    "recentConnectPeople" => s.recent_connect_people(a(0), a(1))
    "recentChatList" => s.recent_chat_list(a(0), a(1), a(2))
    "searchChatList" => s.search_chat_list(a(0), a(1), a(2), a(3), filter=a(4))
    "firstText" => s.first_text(a(0))
    "lastMessage" => s.last_message(a(0))
    "insertMessage" => {
      let before = hook(s, arg(args, 1), None)
      let inserted = match arg(args, 2) {
        None | Some(Null) => None
        Some(spec) =>
          Some((n : Double) => match hook(s, Some(spec), Some(n)) {
            Some(f) => f()
            None => ()
          })
      }
      s.insert_message(arg(args, 0).unwrap_or(Obj([])), before~, inserted~)
    }
    "editMessage" => s.edit_message(a(0), a(1), a(2), a(3), a(4))
    "editMessageIfReady" => s.edit_message_if_ready(a(0), a(1), a(2), a(3), a(4))
    "decisionsVersion" => s.decisions_version()
    "recentDecisions" => s.recent_decisions()
    "recordDecision" => s.record_decision(a(0), arg(args, 1).unwrap_or(Null))
    "lastDecision" => s.last_decision(a(0))
    "latestDecisionsSince" => s.latest_decisions_since(a(0), a(1))
    "archivePolicy" => s.archive_policy(a(0))
    "setArchivePolicy" => s.set_archive_policy(arg(args, 0).unwrap_or(Null), arg(args, 1).unwrap_or(Null), a(2), a(3))
    "setArchiveVerdict" => s.set_archive_verdict(a(0), a(1), a(2), arg(args, 3).unwrap_or(Null))
    "suggestArchive" => s.suggest_archive(a(0), a(1), a(2))
    "clearArchiveSuggestion" => s.clear_archive_suggestion(a(0), a(1))
    "archiveSuggested" => s.archive_suggested(a(0))
    "lastEntry" => s.last_entry(a(0))
    "entriesBefore" => s.entries_before(a(0), a(1), a(2))
    "entriesBetween" => s.entries_between(a(0), a(1), a(2))
    "messagePageEntries" => s.message_page_entries(a(0), a(1))
    "messageAt" => s.message_at(a(0), a(1))
    "messageAtIfReady" => s.message_at_if_ready(a(0), a(1))
    "messageNumberAt" => s.message_number_at(a(0), a(1))
    "cardAt" => s.card_at(a(0), a(1))
    "messagesBefore" => s.messages_before(a(0), a(1), a(2))
    "insertLetter" => s.insert_letter(arg(args, 0).unwrap_or(Obj([])))
    "deliverLetter" => s.deliver_letter(a(0), a(1), a(2))
    "deliver" => s.deliver(a(0), a(1), a(2), a(3))
    "pendingBefore" => s.pending_before(a(0), a(1), a(2))
    "pendingCount" => s.pending_count(a(0))
    "hasPending" => s.has_pending(a(0))
    "hasUndelivered" => s.has_undelivered(a(0))
    "markDelivered" => s.mark_delivered(a(0), a(1))
    "markUndelivered" => s.mark_undelivered(a(0), a(1))
    "heardThreads" => s.heard_threads(a(0), a(1))
    "starter" => s.starter(a(0))
    "participants" => s.participants(a(0))
    "setRead" => s.set_read(a(0), a(1), a(2))
    "setChatHidden" => s.set_chat_hidden(a(0), a(1), a(2))
    "setChatMuted" => s.set_chat_muted(a(0), a(1), a(2))
    "pins" => s.pins(a(0))
    "setPin" => s.set_pin(a(0), a(1), a(2))
    "relayedTo" => s.relayed_to(a(0))
    "noteRelayed" => s.note_relayed(a(0), a(1))
    "keepChat" => s.keep_chat(a(0), a(1))
    "unkeepChat" => s.unkeep_chat(a(0), a(1))
    "pendingCard" => s.pending_card(a(0))
    "pendingCardHeader" => s.pending_card_header(a(0))
    "pendingCardHeaderIfReady" => s.pending_card_header_if_ready(a(0))
    "closedCard" => s.closed_card(a(0), a(1))
    "askingMessage" => s.asking_message(a(0), a(1), a(2))
    "cardClosedSince" => s.card_closed_since(a(0), a(1))
    "dismissed" => s.dismissed(a(0))
    "dismiss" => s.dismiss(a(0), a(1), a(2))
    "withdrawCard" => s.withdraw_card(a(0), a(1), a(2))
    "restateCard" => s.restate_card(a(0), a(1), a(2), card_fn(arg(args, 3)))
    "closeCard" => s.close_card(a(0), a(1), a(2), a(3), a(4))
    "untoldCardChoices" => s.untold_card_choices(a(0), a(1))
    "setMovedNotes" => s.set_moved_notes(a(0))
    "untoldMovedNote" => s.untold_moved_note(a(0))
    "markMovedNoteTold" => s.mark_moved_note_told(a(0))
    "markCardChoicesTold" => s.mark_card_choices_told(a(0), a(1))
    "cardChoices" => s.card_choices(a(0), a(1))
    "archiveLook" => @readops.archive_look(s.db, a(0))
    _ => raise StoreError("no such store method: \{op}")
  }
}

///|
/// Its time now (what its writes are stamped with): the station's clock, set before each use.
pub fn Store::set_now(self : Store, now : Double) -> Unit {
  self.now = now
}
