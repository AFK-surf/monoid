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
    "leaveThread" => s.leave_thread(a(0), a(1))
    "leftThread" => s.left_thread(a(0), a(1), a(2), a(3))
    "hasSessionActiveWatch" => s.has_session_active_watch(a(0))
    "sessionThread" => s.session_thread(a(0), a(1), a(2))
    "sessionThreadById" => s.session_thread_by_id(a(0), a(1))
    "sessionThreads" => s.session_threads(a(0), a(1))
    "latestThreadIfReady" => s.latest_thread_if_ready(a(0))
    "latestThread" => s.latest_thread(a(0))
    "sessionChat" => s.session_chat(a(0))
    "firstText" => s.first_text(a(0))
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
    "decisionsVersion" => s.decisions_version()
    "entriesBefore" => s.entries_before(a(0), a(1), a(2))
    "entriesBetween" => s.entries_between(a(0), a(1), a(2))
    "pendingCount" => s.pending_count(a(0))
    "hasPending" => s.has_pending(a(0))
    "markDelivered" => s.mark_delivered(a(0), a(1))
    "markUndelivered" => s.mark_undelivered(a(0), a(1))
    "starter" => s.starter(a(0))
    "setRead" => s.set_read(a(0), a(1), a(2))
    "setChatHidden" => s.set_chat_hidden(a(0), a(1), a(2))
    "setChatMuted" => s.set_chat_muted(a(0), a(1), a(2))
    "setPin" => s.set_pin(a(0), a(1), a(2))
    "keepChat" => s.keep_chat(a(0), a(1))
    "unkeepChat" => s.unkeep_chat(a(0), a(1))
    "pendingCardHeader" => s.pending_card_header(a(0))
    "pendingCardHeaderIfReady" => s.pending_card_header_if_ready(a(0))
    "dismiss" => s.dismiss(a(0), a(1), a(2))
    "withdrawCard" => s.withdraw_card(a(0), a(1), a(2))
    "restateCard" => s.restate_card(a(0), a(1), a(2), card_fn(arg(args, 3)))
    "closeCard" => s.close_card(a(0), a(1), a(2), a(3), a(4))
    _ => raise StoreError("no such store method: \{op}")
  }
}

///|
/// Its time now (what its writes are stamped with): the station's clock, set before each use.
pub fn Store::set_now(self : Store, now : Double) -> Unit {
  self.now = now
}
