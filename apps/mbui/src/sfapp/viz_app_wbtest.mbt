// A station's app (sfbase's viz_app.mbt): a widget bound to one asks its documents and its LLM through the core, its
// program's imports answering at once with a request id and their answers coming to its `mbui_event` as the core gives
// them; a document changed is told by `app.watch`; `sf-app:` links name an app; a declarative button asks the LLM.

///|
/// A call the widget made of the made-up core: its name, what it gave, and how it is answered.
priv struct AppCall {
  name : String
  params : Json
  done : (Result[Json, Json]) -> Unit
}

///|
/// A made-up core for an app widget in chat `s-c1` on `ws1/st1`: each call kept in `calls` to be answered by the test,
/// each watch in `watched` to be told by it.
fn app_core(calls : Array[AppCall], watched : Array[(String, Json, (Json) -> Unit)]) -> @sfbase.VizAppHost {
  {
    station: "ws1/st1",
    key: "s-c1",
    call: fn(name, params, done) { calls.push({ name, params, done }) },
    watch: fn(name, params, on_value) {
      watched.push((name, params, on_value))
      fn() { () }
    },
  }
}

///|
/// `widget` drawn as `place` in a Tester, what it keeps in `kept`, asking its app through `app`.
fn app_tester(place : String, widget : @sfbase.VizMbuiWidget, kept : Ref[Json], app : @sfbase.VizAppHost?) -> @ui.Tester {
  new_run()
  @ui.Tester::new(
    fn(c) { @sf.begin(c) |> ignore },
    tree=fn(root) {
      @sfbase.viz_mbui_node(root, place, widget, fn() { kept.val }, {
        keep: Some(fn(s) { kept.val = s }),
        failed: None,
        follow_up: None,
        app,
      })
    },
    w=420.0,
    h=600.0,
  )
}

///|
fn kept_field(kept : Ref[Json], k : String) -> Json? {
  match kept.val {
    Object(m) => m.get(k)
    _ => None
  }
}

///|
fn param(c : AppCall, k : String) -> Json? {
  match c.params {
    Object(m) => m.get(k)
    _ => None
  }
}

///|
/// A program asking its app as it starts (`mbui_init`): `db_list("todos")`, `db_put("todos", "a", {"t":1})`,
/// `llm({"prompt":"hi"})`, `db_put("todos", "a", "{bad")`, each id kept as `r1`…`r4` (`state_set_i32`); each event its
/// `mbui_event` is given merged whole into its state (`input_copy`, `set_state`).
let app_program_b64 : String = "AGFzbQEAAAABIwZgAn9/AX9gBn9/f39/fwF/YAN/f38AYAABf2ACf38AYAAAAmEGBG1idWkHZGJfbGlzdAAABG1idWkGZGJfcHV0AAEEbWJ1aQNsbG0AAARtYnVpDXN0YXRlX3NldF9pMzIAAgRtYnVpCmlucHV0X2NvcHkAAARtYnVpCXNldF9zdGF0ZQAEAwMCBQQFAwEAAQcaAgltYnVpX2luaXQABgptYnVpX2V2ZW50AAcKWwJIAEGAAUECQQBBBRAAEANBiAFBAkEAQQVBEEEBQSBBBxABEANBkAFBAkHAAEEPEAIQA0GYAUECQQBBBUEQQQFB4ABBBBABEAMLEABBgAhBgAhBgMAAEAQQBQsLXAkAQQALBXRvZG9zAEEQCwFhAEEgCwd7InQiOjF9AEHAAAsPeyJwcm9tcHQiOiJoaSJ9AEHgAAsEe2JhZABBgAELAnIxAEGIAQsCcjIAQZABCwJyMwBBmAELAnI0"

///|
fn app_program() -> @sfbase.VizMbuiWidget {
  @sfbase.viz_mbui_parse("todo.wasm", "wasm:base64:" + app_program_b64).unwrap()
}

///|
test "a bound program's db_list, db_put and llm give request ids at once, and each answer comes to its mbui_event as the core gives it" {
  let calls : Array[AppCall] = []
  let watched : Array[(String, Json, (Json) -> Unit)] = []
  let kept : Ref[Json] = Ref(Json::null())
  let widget = @sfbase.viz_mbui_bound_to(app_program(), "todo")
  let t = app_tester("test:app:bound", widget, kept, Some(app_core(calls, watched)))
  t.frame()
  // the ids, given as it asked, before any answer
  assert_eq(kept_field(kept, "r1"), Some(Json::number(1.0)))
  assert_eq(kept_field(kept, "r2"), Some(Json::number(2.0)))
  assert_eq(kept_field(kept, "r3"), Some(Json::number(3.0)))
  assert_eq(kept_field(kept, "r4"), Some(Json::number(4.0)))
  // what it asked sent once its call returned; the write of what is not JSON refused here, never sent
  assert_eq(calls.map(fn(c) { c.name }), ["app.docs", "app.putDoc", "app.llm"])
  assert_eq(param(calls[0], "station"), Some(Json::string("ws1/st1")))
  assert_eq(param(calls[0], "id"), Some(Json::string("todo")))
  assert_eq(param(calls[0], "collection"), Some(Json::string("todos")))
  assert_eq(param(calls[1], "doc"), Some(Json::string("a")))
  assert_eq(param(calls[1], "data"), Some(Json::object({ "t": Json::number(1.0) })))
  assert_eq(param(calls[2], "key"), Some(Json::string("s-c1")))
  assert_eq(param(calls[2], "prompt"), Some(Json::string("hi")))
  assert_eq(kept_field(kept, "req"), Some(Json::number(4.0)))
  assert_eq(kept_field(kept, "ok"), Some(Json::boolean(false)))
  assert_eq(kept_field(kept, "error"), Some(Json::string("invalid JSON")))
  // answered out of order: each comes as it is given
  (calls[0].done)(
    Ok(
      Json::object({
        "docs": Json::array([
          Json::object({ "id": Json::string("a"), "data": Json::object({ "t": Json::number(1.0) }), "rev": Json::number(1.0) }),
        ]),
      }),
    ),
  )
  t.frame()
  assert_eq(kept_field(kept, "type"), Some(Json::string("app")))
  assert_eq(kept_field(kept, "req"), Some(Json::number(1.0)))
  assert_eq(kept_field(kept, "ok"), Some(Json::boolean(true)))
  assert_eq(kept_field(kept, "op"), Some(Json::string("docs")))
  match kept_field(kept, "docs") {
    Some(Array(a)) => assert_eq(a.length(), 1)
    other => fail("expected the documents, got \{Repr(other)}")
  }
  (calls[2].done)(
    Err(
      Json::object({
        "err": Json::object({ "code": Json::number(422.0), "message": Json::string("pick a profile that can complete text") }),
      }),
    ),
  )
  t.frame()
  assert_eq(kept_field(kept, "req"), Some(Json::number(3.0)))
  assert_eq(kept_field(kept, "ok"), Some(Json::boolean(false)))
  assert_eq(kept_field(kept, "error"), Some(Json::string("pick a profile that can complete text")))
  (calls[1].done)(Ok(Json::object({ "rev": Json::number(1.0) })))
  t.frame()
  assert_eq(kept_field(kept, "req"), Some(Json::number(2.0)))
  assert_eq(kept_field(kept, "op"), Some(Json::string("put")))
  assert_eq(kept_field(kept, "rev"), Some(Json::number(1.0)))
  assert_eq(t.find("Wasm 沙箱拦截") is None, true, msg="no trap")
}

///|
test "a program bound to no app gets 0 from each app import and asks the core nothing" {
  let calls : Array[AppCall] = []
  let watched : Array[(String, Json, (Json) -> Unit)] = []
  let kept : Ref[Json] = Ref(Json::null())
  // (in a chat, where the core could be asked, but bound to no app: neither its .mbui nor a link names one)
  let t = app_tester("test:app:unbound", app_program(), kept, Some(app_core(calls, watched)))
  t.frame()
  let held = Ref(@sfbase.viz_mbui_state_at("test:app:unbound").unwrap())
  for k in ["r1", "r2", "r3", "r4"] {
    assert_eq(kept_field(held, k), Some(Json::number(0.0)), msg=k)
  }
  assert_eq(calls.length(), 0)
  assert_eq(watched.length(), 0, msg="no app watched")
  // named an app but shown where no station can be asked (no host): unbound as well
  let kept2 : Ref[Json] = Ref(Json::null())
  let t2 = app_tester("test:app:nohost", @sfbase.viz_mbui_bound_to(app_program(), "todo"), kept2, None)
  t2.frame()
  assert_eq(kept_field(Ref(@sfbase.viz_mbui_state_at("test:app:nohost").unwrap()), "r1"), Some(Json::number(0.0)))
}

///|
test "a document changed on the station comes to the bound program's mbui_event as app-doc, told by app.watch" {
  let calls : Array[AppCall] = []
  let watched : Array[(String, Json, (Json) -> Unit)] = []
  let kept : Ref[Json] = Ref(Json::null())
  let widget = @sfbase.viz_mbui_bound_to(app_program(), "todo")
  let t = app_tester("test:app:watch", widget, kept, Some(app_core(calls, watched)))
  t.frame()
  assert_eq(watched.length(), 1)
  let (name, params, tell) = watched[0]
  assert_eq(name, "app.watch")
  assert_eq(params, Json::object({ "station": Json::string("ws1/st1"), "id": Json::string("todo") }))
  // (the first `opened`, as the watch starts, is no change)
  tell(Json::object({ "type": Json::string("opened") }))
  t.frame()
  assert_eq(kept_field(kept, "type"), Some(Json::string("app")), msg="still the last answer's")
  tell(
    Json::object({
      "type": Json::string("app-doc"),
      "app": Json::string("todo"),
      "collection": Json::string("todos"),
      "id": Json::string("a"),
      "rev": Json::number(2.0),
      "deleted": Json::boolean(true),
    }),
  )
  t.frame()
  assert_eq(kept_field(kept, "type"), Some(Json::string("app-doc")))
  assert_eq(kept_field(kept, "collection"), Some(Json::string("todos")))
  assert_eq(kept_field(kept, "id"), Some(Json::string("a")))
  assert_eq(kept_field(kept, "deleted"), Some(Json::boolean(true)))
  // the link to the station open again after an absence: anything may have changed (empty collection and id)
  tell(Json::object({ "type": Json::string("opened") }))
  t.frame()
  assert_eq(kept_field(kept, "collection"), Some(Json::string("")))
  assert_eq(kept_field(kept, "deleted"), Some(Json::boolean(false)))
}

///|
test "sf-app links name an app, its current version or one pinned" {
  assert_eq(@sfbase.viz_app_link("sf-app:todo"), Some(("todo", None)))
  assert_eq(@sfbase.viz_app_link("sf-app:my-app-2@3"), Some(("my-app-2", Some(3))))
  assert_eq(@sfbase.viz_app_link(" sf-app:todo@12 "), Some(("todo", Some(12))))
  assert_eq(@sfbase.viz_app_link("sf-app:Todo"), None, msg="ids are lower case")
  assert_eq(@sfbase.viz_app_link("sf-app:-todo"), None)
  assert_eq(@sfbase.viz_app_link("sf-app:todo@"), None)
  assert_eq(@sfbase.viz_app_link("sf-app:todo@0"), None)
  assert_eq(@sfbase.viz_app_link("sf-app:todo@x1"), None)
  assert_eq(@sfbase.viz_app_link("sf-app:" + "a".repeat(41)), None)
  assert_eq(@sfbase.viz_app_link("https://example.com/sf-app:todo"), None)
  assert_eq(@sfbase.viz_app_link("todo.mbui"), None)
  // as a message's Markdown hands a link alone on its line to its files (sf's file_name_of): the same
  assert_eq(@sfbase.viz_app_link(@sf.file_name_of("sf-app:todo@2")), Some(("todo", Some(2))))
  // what app.get gives: a .mbui's JSON as it is, a .wasm's bytes as base64, either a widget bound to its app by its link
  let got = @sfbase.viz_app_got_of(
    "todo",
    Json::object({ "kind": Json::string("wasm"), "rev": Json::number(4.0), "source": Json::string(app_program_b64) }),
  ).unwrap()
  assert_eq(got.rev, 4)
  let w = @sfbase.viz_mbui_bound_to(@sfbase.viz_mbui_parse(got.name, got.raw).unwrap(), "todo")
  assert_eq(@sfbase.viz_mbui_app(w), "todo")
  let m = @sfbase.viz_app_got_of(
    "notes",
    Json::object({ "kind": Json::string("mbui"), "rev": Json::number(1.0), "source": Json::string("{\"app\":\"notes\",\"root\":{\"type\":\"text\",\"text\":\"hi\"}}") }),
  ).unwrap()
  assert_eq(@sfbase.viz_mbui_app(@sfbase.viz_mbui_parse(m.name, m.raw).unwrap()), "notes", msg="its .mbui's own field")
  assert_true(@sfbase.viz_app_got_of("x", Json::object({ "rev": Json::number(1.0) })) is Err(_))
}

///|
let llm_widget : String =
  #|{"app":"notes","title":"Notes","state":{"topic":"cats"},
  #| "root":{"type":"card","children":[
  #|   {"type":"text","text":"Summary: ${summary}"},
  #|   {"type":"button","label":"Summarize","llm":{"prompt":"Summarize {topic} in a line","into":"summary"}}]}}

///|
test "a declarative button's llm asks the app with its state filled in and puts the answer's text in state[into]" {
  let calls : Array[AppCall] = []
  let watched : Array[(String, Json, (Json) -> Unit)] = []
  let kept : Ref[Json] = Ref(Json::null())
  let widget = @sfbase.viz_mbui_parse("notes.mbui", llm_widget).unwrap()
  assert_eq(@sfbase.viz_mbui_app(widget), "notes")
  let t = app_tester("test:app:llm", widget, kept, Some(app_core(calls, watched)))
  t.frame()
  t.tap_text("Summarize")
  t.frame()
  assert_eq(calls.length(), 1)
  assert_eq(calls[0].name, "app.llm")
  assert_eq(param(calls[0], "id"), Some(Json::string("notes")))
  assert_eq(param(calls[0], "key"), Some(Json::string("s-c1")))
  assert_eq(param(calls[0], "prompt"), Some(Json::string("Summarize cats in a line")))
  (calls[0].done)(Ok(Json::object({ "text": Json::string("Cats nap a lot.") })))
  t.frame()
  assert_eq(kept_field(kept, "summary"), Some(Json::string("Cats nap a lot.")))
  assert_eq(kept_field(kept, "summary_pending"), Some(Json::boolean(false)))
  assert_true(t.find("Summary: Cats nap a lot.") is Some(_), msg="the answer shown where the widget says")
  // refused: the station's words in state[into + "_error"], the answer before kept
  t.tap_text("Summarize")
  t.frame()
  (calls[1].done)(Err(Json::object({ "err": Json::object({ "message": Json::string("pick a DeepSeek Harness profile") }) })))
  t.frame()
  assert_eq(kept_field(kept, "summary_error"), Some(Json::string("pick a DeepSeek Harness profile")))
  assert_eq(kept_field(kept, "summary"), Some(Json::string("Cats nap a lot.")))
}

///|
test "a declarative llm button bound to no app asks nothing and says so in state[into + \"_error\"]" {
  let calls : Array[AppCall] = []
  let watched : Array[(String, Json, (Json) -> Unit)] = []
  let kept : Ref[Json] = Ref(Json::null())
  let unbound = llm_widget.replace(old="\"app\":\"notes\",", new="")
  let widget = @sfbase.viz_mbui_parse("notes.mbui", unbound).unwrap()
  assert_eq(@sfbase.viz_mbui_app(widget), "")
  let t = app_tester("test:app:llm-unbound", widget, kept, Some(app_core(calls, watched)))
  t.frame()
  t.tap_text("Summarize")
  t.frame()
  assert_eq(calls.length(), 0)
  match kept_field(kept, "summary_error") {
    Some(String(s)) => assert_true(s.contains("not bound to an app"))
    other => fail("expected the words saying it is bound to no app, got \{Repr(other)}")
  }
}
