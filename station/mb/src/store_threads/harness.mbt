// The store on a line protocol (reader `--builder harness-store-threads --db <file>`), what
// station/test/mb-store-threads.test.ts plays against the TypeScript store on a twin database: each line
// `{id, op, args, now}` names a store method as store.ts names it, its arguments as the TypeScript's in JSON, and the
// store's time then; it is answered `{id, result}` or `{id, error: {name, message}}`, with what the store told meanwhile
// (`changes`) and asked to be prepared (`requested`). What a method takes as a function is said as data: a statement
// to run (`{sql, args}`, "$n" for the new entry's number) or an error to raise (`{throw}`); a card restated by merging
// (`{merge}`) or set (`{set}`). The queued outcomes' consumer runs as `worker.*` on a clock of its own the test moves.

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
fn prepared_of(v : @jsjson.JValue?) -> Prepared? {
  match v {
    Some(Obj(_) as p) =>
      Some({
        scan: CardEditScan::from_json(jget(p, "scan").unwrap_or(Null)),
        card: jtext(jget(p, "card")),
        edit: match jget(p, "edit") {
          None => None
          Some(Str(s)) => Some(Some(@jsjson.sanitize_str(s)))
          Some(_) => Some(None)
        },
      })
    _ => None
  }
}

///|
fn error_json(e : Error) -> Json {
  let (name, message) = match e {
    MessageWriteBusy => ("MessageWriteBusy", "")
    DecisionSessionsUnavailable => ("DecisionSessionsUnavailable", "decision session lookup is not ready")
    SessionChatUnavailable => ("SessionChatUnavailable", "session chat is still being prepared")
    CcSessionsUnavailable(_) => ("CcSessionsUnavailable", "copy destinations are still being prepared")
    StoreError(m) => ("Error", m)
    @wire.ShellError(m) => ("Error", m)
    Failure(m) => ("Error", m)
    e => ("Error", e.to_string())
  }
  let out : Map[String, Json] = { "name": jstr(name), "message": jstr(message) }
  if e is CcSessionsUnavailable(sessions) {
    out["sessions"] = Json::array(sessions.map(jstr))
  }
  Json::object(out)
}

///|
/// What the harness keeps across lines: the store, and the worker with the gates its page reads wait at.
priv struct Harness {
  store : Store
  mut worker : Worker?
  rt : @effect.Runtime
  gates : Map[String, @effect.Deferred[Unit]]
  mut held : Int
}

///|
async fn Harness::wait_gate(self : Harness, thread : Json) -> Unit {
  match self.gates.get(thread.stringify()) {
    Some(gate) => {
      self.held += 1
      gate.wait() catch {
        _ => ()
      }
      self.held -= 1
    }
    None => ()
  }
  @effect.pause()
}

///|
fn Harness::call(self : Harness, op : String, args : Array[@jsjson.JValue]) -> Json raise {
  let s = self.store
  let a = (i : Int) => jarg(args, i)
  match op {
    "getThread" => s.get_thread(a(0))
    "threadAt" => s.thread_at(a(0), a(1), a(2))
    "threadsAt" => s.threads_at(a(0), a(1))
    "openThread" => s.open_thread(a(0), a(1), a(2), a(3), a(4))
    "openThreadOf" => s.open_thread_of(a(0), a(1), a(2), a(3), a(4), a(5))
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
    "lastMessageAtForArchive" => s.last_message_at_for_archive(a(0))
    "unreadCount" => s.unread_count(a(0), a(1))
    "messageCount" => s.message_count(a(0))
    "unreadForArchive" => s.unread_for_archive(a(0), a(1))
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
    "decisionSessionsReady" => s.decision_sessions_ready()
    "lastDecision" => s.last_decision(a(0))
    "latestDecisionsSince" => s.latest_decisions_since(a(0), a(1))
    "archivePolicy" => s.archive_policy(a(0))
    "setArchivePolicy" => s.set_archive_policy(arg(args, 0).unwrap_or(Null), arg(args, 1).unwrap_or(Null), a(2), a(3))
    "setArchiveVerdict" => s.set_archive_verdict(a(0), a(1), a(2), arg(args, 3).unwrap_or(Null))
    "suggestArchive" => s.suggest_archive(a(0), a(1), a(2))
    "clearArchiveSuggestion" => s.clear_archive_suggestion(a(0), a(1))
    "archiveSuggested" => s.archive_suggested(a(0))
    "lastEntry" => s.last_entry(a(0))
    "entriesAfter" => s.entries_after(a(0), a(1))
    "entriesBefore" => s.entries_before(a(0), a(1), a(2))
    "entriesBetween" => s.entries_between(a(0), a(1), a(2))
    "messagePageEntries" => s.message_page_entries(a(0), a(1))
    "messageAt" => s.message_at(a(0), a(1))
    "messageAtIfReady" => s.message_at_if_ready(a(0), a(1))
    "messageNumberAt" => s.message_number_at(a(0), a(1))
    "cardAt" => s.card_at(a(0), a(1))
    "messagesBefore" => s.messages_before(a(0), a(1), a(2))
    "insertLetter" => s.insert_letter(arg(args, 0).unwrap_or(Obj([])))
    "lastLetter" => s.last_letter(a(0))
    "deliverLetter" => s.deliver_letter(a(0), a(1), a(2))
    "deliver" => s.deliver(a(0), a(1), a(2), a(3))
    "deliveryPending" => s.delivery_pending(a(0), a(1), a(2))
    "completeRouterWrite" => s.complete_router_write(a(0))
    "pendingMessages" => s.pending_messages(a(0))
    "pendingBefore" => s.pending_before(a(0), a(1), a(2))
    "pendingCount" => s.pending_count(a(0))
    "hasPending" => s.has_pending(a(0))
    "hasUndelivered" => s.has_undelivered(a(0))
    "markDelivered" => s.mark_delivered(a(0), a(1))
    "markUndelivered" => s.mark_undelivered(a(0), a(1))
    "heardThreads" => s.heard_threads(a(0), a(1))
    "sessionsWithPending" => s.sessions_with_pending()
    "returningSessionsIn" => s.returning_sessions_in(a(0))
    "starter" => s.starter(a(0))
    "participants" => s.participants(a(0))
    "readPosition" => s.read_position(a(0), a(1))
    "setRead" => s.set_read(a(0), a(1), a(2))
    "setChatHidden" => s.set_chat_hidden(a(0), a(1), a(2))
    "setChatMuted" => s.set_chat_muted(a(0), a(1), a(2))
    "pins" => s.pins(a(0))
    "pinnedSessions" => s.pinned_sessions()
    "archiveMarks" => s.archive_marks(a(0), a(1))
    "setPin" => s.set_pin(a(0), a(1), a(2))
    "relayedTo" => s.relayed_to(a(0))
    "noteRelayed" => s.note_relayed(a(0), a(1))
    "connectThreadStation" => s.connect_thread_station(a(0), a(1), a(2))
    "setConnectThreadStation" => s.set_connect_thread_station(a(0), a(1), a(2), a(3))
    "connectThreads" => s.connect_threads(a(0))
    "dropConnectThreads" => s.drop_connect_threads(a(0))
    "connectLocalThreads" => s.connect_local_threads(a(0))
    "keptChats" => s.kept_chats(a(0))
    "keepChat" => s.keep_chat(a(0), a(1))
    "unkeepChat" => s.unkeep_chat(a(0), a(1))
    "pendingCard" => s.pending_card(a(0))
    "pendingCardHeader" => s.pending_card_header(a(0))
    "pendingCardHeaderIfReady" => s.pending_card_header_if_ready(a(0))
    "cardEndedByMessage" => s.card_ended_by_message(a(0), a(1))
    "cardReplacedBy" => s.card_replaced_by(a(0), a(1))
    "closedCard" => s.closed_card(a(0), a(1))
    "askingMessage" => s.asking_message(a(0), a(1), a(2))
    "cardClosedSince" => s.card_closed_since(a(0), a(1))
    "dismissed" => s.dismissed(a(0))
    "dismiss" => s.dismiss(a(0), a(1), a(2))
    "withdrawCard" => s.withdraw_card(a(0), a(1), a(2))
    "restateCard" => s.restate_card(a(0), a(1), a(2), card_fn(arg(args, 3)))
    "saveCardOutcome" => {
      let save = hook(s, arg(args, 1), None)
      jstr(
        s.save_card_outcome(CardOutcome::from_json(arg(args, 0).unwrap_or(Null)), () => match save {
          Some(f) => f()
          None => ()
        }),
      )
    }
    "restateQueuedCard" =>
      match s.restate_queued_card(CardOutcome::from_json(arg(args, 0).unwrap_or(Null)), prepared_of(arg(args, 1))) {
        Some(b) => jbool(b)
        None => undefined
      }
    "beginCardEditScan" =>
      match s.begin_card_edit_scan(CardOutcome::from_json(arg(args, 0).unwrap_or(Null))) {
        Some(scan) => scan.to_json()
        None => Json::null()
      }
    "endCardEditScan" => {
      s.end_card_edit_scan(CardEditScan::from_json(arg(args, 0).unwrap_or(Null)))
      undefined
    }
    "cardOutcomeHeads" =>
      Json::array(
        s
        .card_outcome_heads(text_of(a(0)).unwrap_or("0"), if a(1) is Null { 64 } else { num(a(1)).to_int() })
        .map(c => c.to_json()),
      )
    "cardEditPage" =>
      card_edit_page(s.db, a(0), text_of(a(1)).unwrap_or(""), text_of(a(2)))
    "cardMessagePage" =>
      card_message_page(s.db, a(0), text_of(a(1)).unwrap_or(""), text_of(a(2)))
    "closeLoginCards" => s.close_login_cards(a(0))
    "closeCard" => s.close_card(a(0), a(1), a(2), a(3), a(4))
    "untoldCardChoices" => s.untold_card_choices(a(0), a(1))
    "setMovedNotes" => s.set_moved_notes(a(0))
    "untoldMovedNote" => s.untold_moved_note(a(0))
    "markMovedNoteTold" => s.mark_moved_note_told(a(0))
    "markCardChoicesTold" => s.mark_card_choices_told(a(0), a(1))
    "cardChoices" => s.card_choices(a(0), a(1))
    "archiveLook" => @readops.archive_look(s.db, a(0))
    "worker.start" => {
      let page = async fn(thread : Json, target : String, before : String?) -> Json {
        self.wait_gate(thread)
        card_edit_page(s.db, thread, target, before)
      }
      let message_page = async fn(thread : Json, target : String, before : String?) -> Json {
        self.wait_gate(thread)
        card_message_page(s.db, thread, target, before)
      }
      let w = Worker::new(s, self.rt, page, message_page)
      self.worker = Some(w)
      if a(0) is True {
        w.previous_exited()
      }
      undefined
    }
    "worker.exited" => {
      self.worker.unwrap().previous_exited()
      undefined
    }
    "worker.run" => undefined
    "worker.wake" => {
      self.worker.unwrap().wake()
      undefined
    }
    "worker.save" => {
      let save = hook(s, arg(args, 1), None)
      jstr(
        self.worker
        .unwrap()
        .save(CardOutcome::from_json(arg(args, 0).unwrap_or(Null)), () => match save {
          Some(f) => f()
          None => ()
        }),
      )
    }
    "worker.hold" => {
      self.gates[a(0).stringify()] = @effect.Deferred::new()
      undefined
    }
    "worker.release" => {
      match self.gates.get(a(0).stringify()) {
        Some(g) => {
          self.gates.remove(a(0).stringify())
          ignore(g.succeed(()))
        }
        None => ()
      }
      undefined
    }
    "worker.state" =>
      match self.worker {
        Some(w) =>
          match w.state() {
            Object(m) => {
              m["held"] = jint(self.held)
              m["warnings"] = Json::array(w.warnings.map(jstr))
              Json::object(m)
            }
            other => other
          }
        None => { "held": jint(self.held) }
      }
    "worker.close" => {
      match self.worker {
        Some(w) => w.close()
        None => ()
      }
      undefined
    }
    _ => raise StoreError("no such store method: \{op}")
  }
}

///|
/// Answers the line protocol on the database at `db_path` until stdin ends.
pub async fn harness(host : @host.Host, db_path : String) -> Unit {
  let db = @sql.Db::attach(host, db_path, wait=5000) catch {
    e => {
      host.say(({ "error": error_json(e) } : Json).stringify())
      return
    }
  }
  let store = Store::new(db, 0.0) catch {
    e => {
      host.say(({ "error": error_json(e) } : Json).stringify())
      return
    }
  }
  let h = { store, worker: None, rt: @effect.Runtime::new(start=0L), gates: Map([]), held: 0 }
  while host.line() is Some(line) {
    if line == "" {
      continue
    }
    let ask = @jsjson.parse(line) catch { _ => Null }
    let id = jnullish(jget(ask, "id"))
    let op = jtext(jget(ask, "op")).unwrap_or("")
    let args = match jget(ask, "args") {
      Some(Arr(xs)) => xs
      _ => []
    }
    store.sent.clear()
    store.requested.clear()
    match jget(ask, "now") {
      Some(Num(n)) => {
        store.now = n
        if op.has_prefix("worker.") {
          match h.worker {
            Some(w) => {
              w.run_until(n.to_int64())
              store.now = n
            }
            None =>
              if n.to_int64() > h.rt.now() {
                h.rt.advance((n.to_int64() - h.rt.now()).to_int())
              }
          }
        }
      }
      _ => ()
    }
    let out : Map[String, Json] = { "id": id }
    (try h.call(op, args) catch {
      e => out["error"] = error_json(e)
    } noraise {
      r => out["result"] = r
    })
    if op.has_prefix("worker.") {
      match h.worker {
        Some(w) => w.run_until(h.rt.now())
        None => ()
      }
    }
    out["changes"] = Json::array(store.sent.copy())
    out["requested"] = Json::array(store.requested.copy())
    store.sent.clear()
    store.requested.clear()
    host.say(Json::object(out).stringify())
  }
  db.close()
}

///|
/// One of the store's calls by its TypeScript name (store.ts), its arguments and answer as JSON: what the station's
/// own parts ask of it by name (station_main's agents' side), as this harness answers the test.
pub fn Store::call(self : Store, op : String, args : Array[@jsjson.JValue]) -> Json raise {
  let h : Harness = { store: self, worker: None, rt: @effect.runtime(), gates: Map([]), held: 0 }
  h.call(op, args)
}

///|
/// Its time now (what its writes are stamped with): the station's clock, set before each use.
pub fn Store::set_now(self : Store, now : Double) -> Unit {
  self.now = now
}
