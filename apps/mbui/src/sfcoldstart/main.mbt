// Thin JS-exported harness for `apps/mbui/scripts/cold-start-smoke.mjs`:
// mounts the real `stillfail` app tree (`@sfapp.app_tree` + `@sfapp.view`) with
// the shared production Core wiring (`@sfapp.wire_core_client`) against a real
// Node `client/core-ts` Core in an empty data directory.

///|
priv struct ColdStartSession {
  client : @core.Client
  src : @sfapp.Source
  tester : @ui.Tester
  outbox : Array[String]
}

///|
let session : Ref[ColdStartSession?] = Ref(None)

///|
fn client_source(client : @core.Client) -> @sfapp.Source {
  let base = @sfbase.made_source()
  {
    ..base,
    topic_key: fn(name, params) {
      @sfbase.wire_topic_key(name, @sfbase.core_topic_params(name, params))
    },
    topic_keyed: fn(_, _, _, _) { None },
    topic_read: fn(name, params) {
      let sub = client.follow_topic(name, params=@sfbase.core_topic_params(name, params))
      { value: sub.value, error: sub.error, version: sub.version }
    },
    waits: fn(name, params) {
      client.follow_topic(name, params=@sfbase.core_topic_params(name, params)).waiting
    },
    generation: fn(name, params) {
      client.topic_generation(name, params=@sfbase.core_topic_params(name, params))
    },
    call: fn(name, params, done) {
      if @sfbase.unread_answer(done) {
        client.call(name, params~) |> ignore
      } else {
        client.call(name, params~, on_done=done) |> ignore
      }
    },
    fatal: fn() { client.fatal },
    leave: fn(name, params, reason) {
      if reason is @sfbase.TopicLeave::Owned(stop) {
        stop()
        return
      }
      client.leave_topic(name, params=@sfbase.core_topic_params(name, params))
    },
    release: fn(name, params) {
      client.release_topic(name, params=@sfbase.core_topic_params(name, params))
    },
    refresh: fn(name, params) {
      client.refresh_topic(name, params=@sfbase.core_topic_params(name, params))
    },
  }
}

///|
pub fn cold_start_init() -> Unit {
  @sfapp.new_run()
  let outbox : Array[String] = []
  let client = @core.Client::new(fn(msg) { outbox.push(msg) })
  let src = client_source(client)
  @sfapp.wire_core_client(client, src) |> ignore
  let tester = @ui.Tester::new(
    fn(c) { @sfapp.view(c, src) },
    tree=@sfapp.app_tree(src),
    w=1280.0,
    h=800.0,
    platform=0,
  )
  session.val = Some({ client, src, tester, outbox })
}

///|
pub fn cold_start_take_outbox() -> String {
  match session.val {
    Some(s) => {
      let items = s.outbox.map(Json::string)
      s.outbox.clear()
      s.outbox.shrink_to_fit()
      Json::array(items).stringify()
    }
    None => "[]"
  }
}

///|
pub fn cold_start_receive(json : String) -> Unit {
  match session.val {
    Some(s) => s.client.receive(json) |> ignore
    None => ()
  }
}

///|
pub fn cold_start_frame() -> Unit {
  match session.val {
    Some(s) => s.tester.frame()
    None => ()
  }
}

///|
pub fn cold_start_state() -> String {
  match session.val {
    Some(s) => @sfapp.app_state_name(s.src)
    None => "Uninitialized"
  }
}

///|
pub fn cold_start_journal() -> String {
  @ui.journal_shown()
}

///|
pub fn cold_start_fatal() -> String {
  match session.val {
    Some(s) => s.client.fatal.unwrap_or("")
    None => "Uninitialized"
  }
}
