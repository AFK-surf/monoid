// The app asks the core for only the chat data its page uses, while other topics keep their own parameters.

///|
test "a chat asks the core for a compact view" {
  let params : Map[String, Json] = { "station": "w/s", "session": "k" }
  let chat = core_topic_params("chat", params)
  assert_eq(chat.get("compact"), Some(Json::boolean(true)))
  assert_eq(chat.get("session"), Some(Json::string("k")))
  assert_true(params.get("compact") is None)
  assert_eq(core_topic_params("chatJobs", params).get("compact"), Some(Json::boolean(true)))
  assert_eq(core_topic_params("history", params).get("compact"), None)
}

///|
test "Source::owned_by auto-parks on deep park, faults on parked Raw read, and non-Chat leave/wake has 0 faults" {
  let prev_stop = @view.faults_stop.val
  let prev_told = @view.fault_told.val
  let faults : Array[String] = []
  @view.faults_stop.val = false
  @view.fault_told.val = Some(fn(said) { faults.push(said) })
  let val = @signals.signal(Json::string("v1"))
  let base : Source = {
    ..made_source(),
    topic_read: fn(_name, _params) { { value: Some(val.get()), error: None, version: 1 } },
  }
  let active_tab = @signals.signal(0)
  let owned_ref : Ref[Source?] = Ref(None)
  let seen : Ref[String] = Ref("")
  let t = @ui.Tester::tree(
    fn(root) {
      root.pick_kept(at_once=true, fn() { active_tab.get() }, fn(page, k) {
        if k == 0 {
          let owned = base.owned_by(page)
          owned_ref.val = Some(owned)
          page.reacts(fn() { owned.topic("status", {}).get().value }, fn(v) {
            seen.val = match v {
              Some(String(s)) => s
              _ => ""
            }
          })
        }
      })
    },
    keeps_sources=true,
  )
  t.draw()
  let owned = owned_ref.val.unwrap()
  assert_eq(seen.val, "v1")
  assert_eq(owned.prefetch("status", {}).value, Some(Json::string("v1")))
  assert_eq(faults, [], msg="active read should produce 0 faults")
  // Deep-parking a non-Chat page via pick_kept produces 0 faults on the leave frame.
  active_tab.set(1)
  t.draw()
  assert_eq(faults, [], msg="non-Chat page leaving/parking frame must produce 0 faults")
  // Raw read while parked triggers @view.fault_told instead of silently returning None.
  let parked_res = owned.prefetch("status", {})
  assert_true(parked_res.value is None)
  assert_true(
    faults.any(fn(s) { s.contains("parked-source-raw-read: status") }),
    msg="expected parked-source-raw-read fault, got: \{Repr(faults)}",
  )
  faults.clear()
  // Even when another active Graph watcher holds the same topic, a parked Raw read via `topic().get()`
  // must NOT bypass the parked guard via the watched-topic cache shortcut.
  let watch = @signals.watch(fn() {  })
  let active_watcher = owned.topic("status2", {})
  watch.read(fn() { active_watcher.get() }) |> ignore
  let parked_topic_res = owned.topic("status2", {}).get()
  assert_true(parked_topic_res.value is None)
  assert_true(
    faults.any(fn(s) { s.contains("parked-source-raw-read: status2") }),
    msg="parked Raw topic().get() must fault even with active watched holder, got: \{Repr(faults)}",
  )
  watch.stop()
  faults.clear()
  // Waking restores owner in pre-order before descendants re-read: 0 faults, fresh value seen.
  val.set(Json::string("v2"))
  active_tab.set(0)
  t.draw()
  assert_eq(faults, [], msg="waking parked page must produce 0 faults")
  assert_eq(seen.val, "v2")
  assert_eq(owned.prefetch("status", {}).value, Some(Json::string("v2")))
  // Chat path: owned_by_parkable(auto_park=false) does not auto-park on pick_kept rest,
  // and manual park returns None without faulting (so Chat failure callbacks like composer stay safe).
  let chat_tab = @signals.signal(0)
  let chat_owned_ref : Ref[Source?] = Ref(None)
  let chat_park_ref : Ref[((Bool) -> Unit)?] = Ref(None)
  let t2 = @ui.Tester::tree(
    fn(root) {
      root.pick_kept(at_once=true, fn() { chat_tab.get() }, fn(page, k) {
        if k == 0 {
          let (co, park) = base.owned_by_parkable(page, auto_park=false)
          chat_owned_ref.val = Some(co)
          chat_park_ref.val = Some(park)
        }
      })
    },
    keeps_sources=true,
  )
  t2.draw()
  chat_tab.set(1)
  t2.draw()
  assert_eq(chat_owned_ref.val.unwrap().prefetch("chat", {}).value, Some(Json::string("v2")))
  assert_eq(faults, [], msg="auto_park=false must not auto-park on pick_kept rest")
  (chat_park_ref.val.unwrap())(true)
  assert_true(chat_owned_ref.val.unwrap().prefetch("chat", {}).value is None)
  assert_eq(faults, [], msg="manual auto_park=false park must return None without faulting")
  @view.faults_stop.val = prev_stop
  @view.fault_told.val = prev_told
  @ui.run_let_go()
}
