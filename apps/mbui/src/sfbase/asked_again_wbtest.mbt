// Unit tests for `topic_value_held` and `chat_head_json_held` reference-equality semantics
// and `(None, None)` retention while topics are re-asked.

///|
fn held_test_source(val : Ref[Json?], err : Ref[Json?], rev : @signals.Signal[Int]) -> Source {
  {
    ..made_source(),
    topic_read: fn(_, _) {
      let v = rev.get()
      { value: val.val, error: err.val, version: v }
    },
  }
}

///|
test "topic_value_held retains previous value on (None, None) and compares Some by reference" {
  kept_reset()
  let _tester = @ui.Tester::new(fn(_) {  })
  let v1 : Json = { "id": "c1", "title": "hello" }
  let val : Ref[Json?] = Ref(Some(v1))
  let err : Ref[Json?] = Ref(None)
  let rev = @signals.signal(0)
  let src = held_test_source(val, err, rev)
  let params : Map[String, Json] = { "id": "c1" }
  let held = topic_value_held(src, "demo", params)
  let runs = Ref(0)
  let stop = @signals.effect(fn() {
    held.get() |> ignore
    runs.val += 1
  })
  assert_eq(runs.val, 1)
  assert_true(
    match held.get() {
      Some(x) => physical_equal(x, v1)
      None => false
    },
  )

  // Re-asked (`value=None, error=None`): keeps previous `v1` by exact same ref, no downstream re-run.
  val.val = None
  rev.set(1)
  assert_eq(runs.val, 1)
  assert_true(
    match held.get() {
      Some(x) => physical_equal(x, v1)
      None => false
    },
  )

  // Same reference returned again: physical_equal is true -> no downstream re-run.
  val.val = Some(v1)
  rev.set(2)
  assert_eq(runs.val, 1)

  // Structurally equal Json instance suppresses spurious downstream re-runs.
  let v2 : Json = { "id": "c1", "title": "hello" }
  val.val = Some(v2)
  rev.set(3)
  assert_eq(runs.val, 1)

  // Distinct content notifies downstream.
  let v3 : Json = { "id": "c1", "title": "world" }
  val.val = Some(v3)
  rev.set(4)
  assert_eq(runs.val, 2)
  assert_true(
    match held.get() {
      Some(x) => physical_equal(x, v3)
      None => false
    },
  )

  // Error clears the held value.
  val.val = None
  err.val = Some(Json::string("offline"))
  rev.set(5)
  assert_eq(runs.val, 3)
  assert_eq(held.get(), None)
  stop()
}

///|
test "chat_head_json_held ignores messages-only updates and retains head on (None, None)" {
  kept_reset()
  let _tester = @ui.Tester::new(fn(_) {  })
  let title : Json = "demo"
  let agents : Json = [{ "key": "a1", "working": false }]
  let val : Ref[Json?] = Ref(Some({ "title": title, "agents": agents, "messages": [1, 2] }))
  let err : Ref[Json?] = Ref(None)
  let rev = @signals.signal(0)
  let src = held_test_source(val, err, rev)
  let r : ChatRef = { station: "st1", session: "c1", title: "demo", station_name: "St1" }
  let held = chat_head_json_held(src, r)
  let runs = Ref(0)
  let stop = @signals.effect(fn() {
    held.get() |> ignore
    runs.val += 1
  })
  assert_eq(runs.val, 1)
  let first = held.get().unwrap()

  // Updating only `messages` keeps `chat_head_json` identical by reference -> zero downstream runs.
  val.val = Some({ "title": title, "agents": agents, "messages": [1, 2, 3] })
  rev.set(1)
  assert_eq(runs.val, 1)
  assert_true(physical_equal(held.get().unwrap(), first))

  // Re-asked (`None, None`) retains previous head.
  val.val = None
  rev.set(2)
  assert_eq(runs.val, 1)
  assert_true(physical_equal(held.get().unwrap(), first))

  // Head field change notifies downstream.
  let agents2 : Json = [{ "key": "a1", "working": true }]
  val.val = Some({ "title": title, "agents": agents2, "messages": [1, 2, 3] })
  rev.set(3)
  assert_eq(runs.val, 2)
  stop()
}
