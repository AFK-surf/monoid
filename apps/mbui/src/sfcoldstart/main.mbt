// Thin JS-exported harness for `apps/mbui/scripts/cold-start-smoke.mjs`:
// mounts the real `stillfail` app tree (`@sfapp.app_tree` + `@sfapp.view`) over
// the production `@core` singleton (`@core.serve` + `@core.receive` + `@sfapp.core_base_source`
// + `@sfapp.wire_core_client`) against a real Node `client/core-ts` Core in an
// empty data directory.

///|
priv struct ColdStartSession {
  tester : @ui.Tester
  outbox : Array[String]
}

///|
let session : Ref[ColdStartSession?] = Ref(None)

///|
pub fn cold_start_init() -> Unit {
  @sfapp.new_run()
  let outbox : Array[String] = []
  let src = @sfapp.core_base_source()
  let inner_tree = @sfapp.app_tree(src)
  let mut served = false
  // `@ui.Tester::new` runs `@ui.reset()` before mounting `tree`, and `sffixture`
  // registers `@ui.on_reset(fn() { @core.serve_end() })`. Start `@core.serve` and
  // wire `@core.client` right before `app_tree` mounts frame 0.
  let tester = @ui.Tester::new(
    fn(c) { @sfapp.view(c, src) },
    tree=fn(root) {
      if !served {
        served = true
        @core.serve(fn(msg) { outbox.push(msg) }) |> ignore
        @sfapp.wire_core_client(@core.client, src) |> ignore
      }
      inner_tree(root)
    },
    w=1280.0,
    h=800.0,
    platform=0,
  )
  session.val = Some({ tester, outbox })
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
  if session.val is Some(_) {
    @core.receive(json, None)
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
pub fn cold_start_journal() -> String {
  @ui.journal_shown()
}

///|
pub fn cold_start_fatal() -> String {
  match session.val {
    Some(_) => @core.fatal().unwrap_or("")
    None => "Uninitialized"
  }
}
