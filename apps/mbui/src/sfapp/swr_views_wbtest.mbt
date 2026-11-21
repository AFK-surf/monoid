// A view's own topic shown at once as it is opened again, and nothing said to be empty before the core has said so
// (MBUI_SWR_VIEWS: @core.Client::show_kept, sfbase's topic_kept and topic_shown_kept): the chat's services' popover over
// a core that says its jobs late (sfdesk's chat_pops_node, jobs_pop_node), 对话目录 opened again (sfpages' outline.mbt),
// and a topic kept as a page's reader lets it go, shown again at once to the next, the core's `same` making nothing again.

///|
/// The chat's page made as nodes in `mode` on a Mac's `w` × 800 window, its services' list (`chatJobs` asked whole, not
/// the bar's summary) not said while `late` says so; `swr`: as an app since MBUI_SWR_VIEWS. Its popover, open as the
/// fixture opens it, closed.
fn swr_jobs_at(late : @signals.Signal[Bool], swr : Bool, w? : Double = 1280.0) -> @ui.Tester {
  new_run()
  @sfbase.hold_chat_page_nodes(Some(true))
  let base = fixture("chat-jobs-pop")
  let src : Source = {
    ..base,
    call: fn(_, _, done) { done(Ok(Json::object({}))) },
    topic_read: fn(name, params) {
      match (name, params.contains("summary")) {
        ("chatJobs", false) if late.get() => { value: None, error: None, version: 0 }
        // (the bar's summary as the core says it: whether it has any, none of them listed)
        ("chatJobs", true) => { value: Some({ "jobs": [], "hasJobs": true, "alarm": Json::null() }), error: None, version: 1 }
        _ => base.topic(name, params).get().snapshot()
      }
    },
    swr_views: fn() { swr },
  }
  open_fixture_over("chat-jobs-pop", src)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h=800.0, platform=0)
  t.run_for(@ui.move_most_ms)
  if @sfdesk.chat_pops_open().1 {
    t.key(@ui.key_escape)
    t.run_for(@ui.move_most_ms)
  }
  t
}

///|
/// What the popover says where a chat has no services nor jobs.
fn swr_jobs_none() -> String {
  @sf.t("web-main.jobs.none")
}

///|
test "大屏: the services' popover over a core that says its jobs late never says there are none; with MBUI_SWR_VIEWS it opens once they have come, whole, the screen as it was meanwhile" {
  for swr in [false, true] {
    let late = @signals.signal(true)
    let t = swr_jobs_at(late, swr)
    guard wide_bar_button(t, @sf.t("web-pages.chat.services")) is Some((x, y, w, h)) else {
      fail("\{swr}: no services' button")
    }
    t.tap(x + w / 2.0, y + h / 2.0)
    // each frame till the core says them: never "none"; with MBUI_SWR_VIEWS nothing put up yet
    let till = t.time() + @ui.move_most_ms
    while t.time() < till {
      t.frame_as_host() |> ignore
      assert_true(t.shown_of(swr_jobs_none()) is None, msg="\{swr}: said to be none before the core said anything")
      if swr {
        assert_true(wide_bar_dialog(t) is None, msg="opened before what it lists came")
      }
    }
    late.set(false)
    // (the first frame it is drawn in, once its jobs came)
    let mut drawn : (Double, Double, Double, Double)? = None
    for _ in 0..<4 {
      t.frame_as_host() |> ignore
      if drawn is None {
        drawn = wide_bar_dialog(t)
      }
    }
    guard drawn is Some(first) else { fail("\{swr}: the popover is not open once its jobs came") }
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("盯 CI") is Some(_), msg="\{swr}: its job there")
    assert_true(t.shown_of(swr_jobs_none()) is None, msg="\{swr}")
    guard wide_bar_dialog(t) is Some(at_rest) else { fail("\{swr}: closed") }
    // with MBUI_SWR_VIEWS whole from its first frame, coming in by its size as a panel does (its height to its width
    // as at rest); before it, opened empty and grown as they came
    let shape = fn(r : (Double, Double, Double, Double)) { r.3 / r.2 }
    if swr {
      assert_true((shape(first) - shape(at_rest)).abs() < 0.01, msg="whole from its first frame \{Repr(first)} \{Repr(at_rest)}")
    } else {
      assert_true(shape(first) < shape(at_rest) * 0.5, msg="before: grown as its jobs came \{Repr(first)} \{Repr(at_rest)}")
    }
    assert_eq(pops_faults(t), [], msg="\{swr}")
    // opened again over a core that has said them: open whole on the frame of the press, as tall as it rests
    t.key(@ui.key_escape)
    t.run_for(@ui.move_most_ms)
    t.tap(x + w / 2.0, y + h / 2.0)
    t.run_for(@ui.move_most_ms)
    guard wide_bar_dialog(t) is Some(again) else { fail("\{swr}: not opened again") }
    assert_eq(again.3, at_rest.3, msg="\{swr}: as tall as it was")
    t.key(@ui.key_escape)
    t.run_for(@ui.move_most_ms)
  }
}

///|
test "对话目录 opened again with MBUI_SWR_VIEWS: the rows it had at once, no bones, nothing asked again; before it, bones again till the core answers" {
  for swr in [false, true] {
    let calls : Array[Made] = []
    let held : OutlineHeld = { on: true, answers: [] }
    let t = outline_tester(calls, held~, swr~)
    t.key(@ui.key_of_char('g'), mods=@ui.mod_cmd)
    t.run_for(@ui.move_most_ms)
    assert_true(outline_panel(t) is Some(_), msg="\{swr}: open")
    assert_true(t.bones_drawn() > 0, msg="\{swr}: bones till its rows come, the first time")
    held.on = false
    outline_let_go(held)
    t.run_for(@ui.move_most_ms)
    assert_eq(t.bones_drawn(), 0, msg="\{swr}")
    let rows = t.words().filter(fn(w) { w.0 == "截图初稿我看了，iPad 那几张字还是小，第三张的状态栏也没隐藏，我标出来发你" }).length()
    assert_true(rows > 0, msg="\{swr}: its rows")
    t.key(@ui.key_escape)
    t.run_for(@ui.move_most_ms)
    assert_true(outline_panel(t) is None, msg="\{swr}: closed")
    // opened again, the core's rows held back: the frame it opens in
    held.on = true
    let asked = outline_rows_asked(calls).length()
    t.key(@ui.key_of_char('g'), mods=@ui.mod_cmd)
    t.run_for(@ui.frame_period_default)
    if swr {
      assert_eq(t.bones_drawn(), 0, msg="opened again: no bones, the rows it had")
      t.run_for(@ui.move_most_ms)
      assert_eq(t.bones_drawn(), 0, msg="opened again, at rest: no bones")
      assert_eq(outline_rows_asked(calls).length(), asked, msg="nothing asked again of what it had")
      assert_eq(outline_faults(t), [])
    } else {
      t.run_for(@ui.move_most_ms)
      assert_true(t.bones_drawn() > 0, msg="before MBUI_SWR_VIEWS: bones again till the core answers")
    }
    held.on = false
    outline_let_go(held)
    t.run_for(@ui.move_most_ms)
  }
}

///|
test "a view's own topic let go of and read again by a page (MBUI_SWR_VIEWS): its kept value shown on the first read, the core's `same` making nothing again; what changed from it taken as an answer" {
  fresh_app()
  let sent : Array[String] = []
  let client = @core.Client::new(fn(s) { sent.push(s) })
  client.keep(@sfbase.topic_kept, most=fn() { @sfbase.kept_most_by(true) })
  client.show_kept(@sfbase.topic_shown_kept)
  let src = signal_client_source(client)
  let params : Map[String, Json] = { "station": "ws/a", "key": "k1" }
  let made = Ref(0)
  let follow = fn(seen : Array[@sfbase.TopicState]) {
    let live = src.topic("agentCard", params)
    // (what a card works out of it: done again only for another value, not for the same one said again)
    let value = @signals.computed(fn(_) { live.get().value }, same=fn(a, b) { physical_equal(a, b) })
    let stop = @signals.effect(fn() {
      value.get() |> ignore
      made.val += 1
      seen.push(@signals.untracked(fn() { live.get() }))
    })
    fn() {
      stop()
      value.dispose()
      live.dispose()
    }
  }
  let last_id = fn() {
    let last = sent.rev_iter().find_first(fn(s) { s.contains("\"subscribe\"") }).unwrap()
    let j = @json.parse(last) catch { _ => Json::null() }
    match j {
      Object(m) =>
        match m.get("id") {
          Some(Number(d, ..)) => (d.to_int(), last)
          _ => @halt.saying("no id")
        }
      _ => @halt.saying("not JSON")
    }
  }
  let first : Array[@sfbase.TopicState] = []
  let stop = follow(first)
  let (id, _) = last_id()
  client.receive_json({ "id": id, "value": { "latest": [{ "key": "l1", "text": "读文件" }] } })
  let had = first[first.length() - 1].value
  stop()
  assert_true(sent.iter().any(fn(s) { s.contains("\"id\":\{id},\"unsubscribe\":true,\"keep\":true") }), msg=sent.join("\n"))
  client.receive_json({ "id": id, "v": "a:1" })
  // Read again: its first read the value kept, the same object, said kept (TopicState's `kept`), asked with its version.
  let second : Array[@sfbase.TopicState] = []
  let made_before = made.val
  let stop = follow(second)
  let (again, said) = last_id()
  assert_true(said.contains("\"have\":\"a:1\""), msg=said)
  assert_eq(second.length(), 1)
  assert_true(physical_equal(second[0].value, had), msg="shown on the first read as it was")
  assert_true(second[0].kept(), msg="said to be what was kept till the core answers")
  // The core's `same`: nothing worked out of it made again.
  client.receive_json({ "id": again, "same": true })
  assert_eq(made.val, made_before + 1, msg="the same value said again makes nothing again")
  stop()
  client.receive_json({ "id": again, "v": "a:1" })
  // Read a third time: what changed from what it kept, taken as the core's first answer, applied to it.
  let third : Array[@sfbase.TopicState] = []
  let stop = follow(third)
  let (third_id, _) = last_id()
  assert_true(physical_equal(third[0].value, had), msg="shown at once again")
  client.receive_json({ "id": third_id, "kept": true, "delta": [{ "path": ["latest", 0, "text"], "set": "改文件" }] })
  let now = third[third.length() - 1]
  assert_eq(now.value.unwrap().stringify(), "{\"latest\":[{\"key\":\"l1\",\"text\":\"改文件\"}]}")
  assert_false(now.kept(), msg="the core's now")
  stop()
}
