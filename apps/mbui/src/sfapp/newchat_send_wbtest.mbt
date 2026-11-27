// A new chat's first words (new_chat.mbt new_send, flight.mbt carried): the page the chat from the frame they are sent,
// they on screen where they were typed, then into their bubble over the composer with the chat's list coming up out of
// it (480 ms after 90, Ease.Arrive), the scene leaving from the same moment: however late the core answers (a phone's,
// a round trip later each, its first view of the chat later still), never gone for a frame nor drawn twice apart.

///|
/// Where words `s` are seen now under the bar (each copy of exactly them, not see-through): (x, y).
fn seen_words(t : @ui.Tester, s : String) -> Array[(Double, Double)] {
  t.words().filter(fn(w) { w.0 == s && w.5 > 0.5 && w.2 > 60.0 }).map(fn(w) { (w.1, w.2) })
}

///|
/// Where words `s` are seen now: once (copies drawn over each other count as one), else the test fails.
fn seen_once(t : @ui.Tester, s : String) -> (Double, Double) raise {
  let at = seen_words(t, s)
  guard at.length() > 0 else { fail("「\{s}」 not seen at \{t.time()}") }
  for p in at {
    if (p.0 - at[0].0).abs() > 0.5 || (p.1 - at[0].1).abs() > 0.5 {
      fail("「\{s}」 seen twice apart at \{t.time()}: \{Repr(at)}")
    }
  }
  at[0]
}

///|
#callsite(autofill(loc))
fn assert_at(was : (Double, Double), now : (Double, Double), loc~ : SourceLoc) -> Unit raise {
  if (was.0 - now.0).abs() > 0.5 || (was.1 - now.1).abs() > 0.5 {
    fail("moved from \{Repr(was)} to \{Repr(now)} (\{loc})")
  }
}

///|
/// Home over the made-up chats with the core's answers to `newChat.create` and `chat.send` kept (`held`, by name: what
/// gives each), and the chat made unread while `unread` says (told as the test sets it): as a phone's core gives them,
/// a round trip later. In a phone's window, or `w` by `h` on `platform`.
fn held_core(
  held : Map[String, () -> Unit],
  unread : @signals.Signal[Bool],
  w? : Double = 390.0,
  h? : Double = 844.0,
  platform? : Int = 2,
  finger? : Bool = false,
) -> @ui.Tester {
  new_run()
  let base = fixture("home")
  let src : Source = {
    ..base,
    call: fn(name, params, done) {
      match name {
        "newChat.create" | "chat.send" =>
          (base.call)(name, params, fn(r) { held[name] = fn() { done(r) } })
        _ => (base.call)(name, params, done)
      }
    },
    topic_read: fn(name, params) {
      let t = base.topic(name, params).get().snapshot()
      let made = match params.get("session") {
        Some(String(s)) => s.has_prefix("new:")
        _ => false
      }
      if name == "chat" && made && unread.get() {
        { value: None, error: None, version: 0 }
      } else {
        t
      }
    },
  }
  if finger {
    @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform~, pointing=Finger, native=Finger)
  } else {
    @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform~)
  }
}

///|
/// 令 tapped, `words` typed in the new chat and sent: where they are seen the frame after (over the field, the field
/// emptied under them).
fn new_chat_sent(t : @ui.Tester, words : String) -> (Double, Double) raise {
  let (_, y) = bar_places_at()
  t.tap(bar_action_x, y)
  t.run_for(@ui.move_most_ms)
  t.tap_text("做任何事")
  t.type_text(words)
  t.draw()
  tap_send(t)
  t.draw()
  let (_, field, _, _) = t.ime()
  assert_eq(field, "")
  let at = seen_once(t, words)
  // (in the composer, at the screen's foot)
  assert_true(at.1 > 700.0)
  at
}

///|
/// The frames from now till `until` (ms on the test's clock): each where words `s` are seen, and going one way only,
/// up or down as the first step goes (a frame's step at most `most`): from where they were typed into their bubble over
/// the composer at the chat's foot, the chat's rows standing at its end (Ctx::list's `from_end`).
fn one_way_till(t : @ui.Tester, s : String, until : Double, most : Double) -> (Double, Double) raise {
  let mut at = seen_once(t, s)
  let mut way = 0.0
  while t.time() < until {
    t.frame()
    let now = seen_once(t, s)
    let d = now.1 - at.1
    if d.abs() > most || (way != 0.0 && d * way < 0.0 && d.abs() > 0.5) {
      fail("「\{s}」 from \{Repr(at)} to \{Repr(now)} in a frame at \{t.time()}")
    }
    if d.abs() > 0.5 {
      way = d
    }
    at = now
  }
  at
}


///|
test "wide: a new chat's first words sent: its field's hint not drawn over them in the frame they go" {
  both_pages(fn() raise {
    // (frame by frame as a host draws them, one build each: the core a round trip late, as a phone's)
    let src = @sffixture.round_trip(fixture_app("chat"), 60.0)
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
    let carried = Ref(0)
    let hinted : Array[Double] = []
    let look = fn(t : @ui.Tester) {
      if seen_words(t, "把发布说明写一下").length() > 0 {
        carried.val += 1
        if hint_seen(t, hint="做任何事") {
          hinted.push(t.time())
        }
      }
    }
    t.drive(
      "timeout 20000\nuntil 新建对话\ntap 新建对话\nuntil 做任何事\ntap 做任何事\ntype 把发布说明写一下\ntap icon:arrow-up\n",
      each=look,
    )
    |> ignore
    // each frame of the words' way out of the field, till the page has become the chat and past it
    let till = t.time() + @sfbase.flight_desk_ms
    while t.time() < till {
      t.frame()
      look(t)
    }
    assert_true(carried.val > 10)
    assert_true(app.nav.top() is Chat(_))
    assert_eq(hinted, [])
  })
}

///|
/// The soft keyboard up over a phone's window (as a host says it, the app laid out above it): `h` of its 844.
fn keyboard_up(t : @ui.Tester, h : Double) -> Unit {
  t.set_ime_inset(h)
  t.resize_next(390.0, 844.0 - h)
  t.run_for(@ui.move_most_ms)
}

///|
test "a new chat's first words sent with the keyboard up: no words over others on any frame, the core however late" {
  both_pages(fn() raise {
    // (words over words on any frame where something moves fail the test: words_over.mbt)
    let held : Map[String, () -> Unit] = Map([])
    let unread = @signals.signal(true)
    let t = held_core(held, unread)
    let (_, y) = bar_places_at()
    t.tap(bar_action_x, y)
    t.run_for(@ui.move_most_ms)
    t.tap_text("做任何事")
    keyboard_up(t, 336.0)
    let words = "把发布说明写一下"
    t.type_text(words)
    t.draw()
    tap_send(t)
    t.draw()
    assert_true(app.nav.top() is Chat(_))
    let typed = seen_once(t, words)
    let landed = one_way_till(t, words, t.time() + flight_carry_after_ms + flight_carry_ms + 34.0, 120.0)
    assert_true(landed.1 < typed.1, msg="landed at \{Repr(landed)} from \{Repr(typed)}")
    for name in ["newChat.create", "chat.send"] {
      match held.get(name) {
        Some(give) => give()
        None => fail("\{name} not asked")
      }
      t.draw()
    }
    unread.set(false)
    t.run_for(new_leave_ms)
    assert_at(landed, seen_once(t, words))
  })
}

///|
test "a new chat's first words and picture sent with the keyboard up: no words over others on any frame" {
  both_pages(fn() raise {
    let src = fixture_app("newchat-attach")
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
    t.drive("timeout 20000\nuntil 想让 agent 做什么？\n") |> ignore
    keyboard_up(t, 336.0)
    tap_send(t)
    t.draw()
    assert_true(app.nav.top() is Chat(_))
    t.run_for(flight_carry_after_ms + flight_carry_ms + new_leave_ms)
  })
}

///|
test "a new chat's first words sent on a short page: nothing of its scene the foot hid is seen as the foot fades" {
  both_pages(fn() raise {
    // (the scene longer than the page: its combinations under the band, frosted, and under the composer, hidden)
    let src = fixture_app("newchat-crowded")
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=470.0, platform=2)
    t.drive("timeout 20000\nuntil 想让 agent 做什么？\n") |> ignore
    t.tap_text("做任何事")
    t.type_text("把发布说明写一下")
    t.run_for(@ui.move_most_ms)
    // the foot's top: what is seen under it is the choices' and the composer's alone (the old page's as it measured it;
    // the page made as nodes, its band of glass across the window's foot)
    let top = match @motion.measured(t.ctx(), "new/foot") {
      Some(h) => 470.0 - h
      None => t.drawn_glass().fold(init=470.0, fn(a, g) { if g.2 >= 389.0 && g.1 > 100.0 && g.1 < a { g.1 } else { a } })
    }
    let under = fn() { t.glyphs_seen().filter(fn(g) { g.3 > top + 1.0 }).length() }
    let before = under()
    tap_send(t)
    t.draw()
    assert_true(app.nav.top() is Chat(_))
    // as it is sent, halfway through the choices' fading (the band's), as they have gone, as the scene is half gone
    for i, ms in [0.0, new_fade_ms / 2.0, new_fade_ms / 2.0, new_leave_ms / 2.0 - new_fade_ms] {
      if i > 0 {
        t.run_for(ms)
      }
      let now = under()
      if now > before {
        fail("\{now - before} glyphs more seen under the foot's top at \{t.time()} than before the words were sent")
      }
    }
  })
}

///|
test "a new chat's first words sent: its scene fades where it is from then, as they go, not once the chat is made" {
  both_pages(fn() raise {
    let held : Map[String, () -> Unit] = Map([])
    let t = held_core(held, @signals.signal(true))
    let title = "想让 agent 做什么？"
    new_chat_sent(t, "把发布说明写一下") |> ignore
    let at = seen_once(t, title)
    // halfway, the chat not made yet (the core's answers kept), the page it already: where it was (or drifting gently
    // upward on the node choreography), half faded
    t.run_for(new_leave_ms / 2.0)
    assert_true(app.nav.top() is Chat(_))
    match t.words().filter(fn(w) { w.0 == title }) {
      [w] => {
        assert_true((w.1 - at.0).abs() <= 0.5, msg="x drifted from \{at.0} to \{w.1}")
        assert_true(w.2 <= at.1 + 0.5 && w.2 >= at.1 - 10.5, msg="y drift out of range: \{at.1} -> \{w.2}")
        assert_true(w.5 > 0.05 && w.5 < 0.95, msg="fading: \{w.5}")
      }
      ws => fail("「\{title}」 seen \{ws.length()} times")
    }
    t.run_for(new_leave_ms / 2.0)
    t.frame()
    assert_true(t.words().filter(fn(w) { w.0 == title && w.5 > 0.0 }).is_empty())
    // made and sent to: the page the chat, the scene not back over it
    match held.get("newChat.create") {
      Some(give) => give()
      None => fail("no chat asked for")
    }
    t.draw()
    match held.get("chat.send") {
      Some(give) => give()
      None => fail("the message not sent")
    }
    t.draw()
    assert_true(app.nav.top() is Chat(_))
    t.run_for(new_leave_ms)
    assert_true(t.words().filter(fn(w) { w.0 == title && w.5 > 0.0 }).is_empty())
  })
}

///|
test "a new chat's first words with the core at once: never gone, into their bubble over the composer with the list" {
  both_pages(fn() raise {
    let t = tester("home")
    let words = "把发布说明写一下"
    let typed = new_chat_sent(t, words)
    let sent = t.time()
    let landed = one_way_till(t, words, sent + flight_carry_after_ms + flight_carry_ms + 100.0, 120.0)
    // over the composer at the chat's foot
    assert_true(landed.1 < typed.1 && landed.1 > typed.1 - 200.0, msg="landed at \{Repr(landed)} from \{Repr(typed)}")
  })
}

///|
test "a new chat's first words not sent (the chat not made): the page the new chat again, they back in its field" {
  both_pages(fn() raise {
    let held : Map[String, () -> Unit] = Map([])
    let unread = @signals.signal(true)
    new_run()
    let base = fixture("home")
    let src : Source = {
      ..base,
      call: fn(name, params, done) {
        match name {
          "newChat.create" =>
            held[name] = fn() {
              done(Err({ "code": Json::string("unavailable"), "message": Json::string("Willow 离线") }))
            }
          _ => (base.call)(name, params, done)
        }
      },
    }
    ignore(unread)
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
    let words = "把发布说明写一下"
    new_chat_sent(t, words) |> ignore
    // (the page the chat meanwhile, its scene gone)
    assert_true(app.nav.top() is Chat(_))
    t.run_for(new_leave_ms)
    match held.get("newChat.create") {
      Some(give) => give()
      None => fail("no chat asked for")
    }
    t.draw()
    assert_true(app.nav.top() is NewChat)
    let (_, back, _, _) = t.ime()
    assert_eq(back, words)
    // its scene, gone as they were sent, back as it was
    t.run_for(new_leave_ms)
    t.frame()
    seen_once(t, "想让 agent 做什么？") |> ignore
    assert_true(t.words().filter(fn(w) { w.0 == "想让 agent 做什么？" && w.5 < 0.99 }).is_empty())
  })
}

///|
/// Home over the made-up chats whose core keeps its answers to `newChat.create` and `chat.send` (`held`, by name: what
/// gives each), giving each the error `fails` names for it, else what it would; in a phone's window.
fn failing_core(held : Map[String, () -> Unit], fails : Map[String, Json]) -> (@ui.Tester, Source) {
  new_run()
  let base = fixture("home")
  let src : Source = {
    ..base,
    call: fn(name, params, done) {
      match name {
        "newChat.create" | "chat.send" =>
          match fails.get(name) {
            Some(e) => held[name] = fn() { done(Err(e)) }
            None => (base.call)(name, params, fn(r) { held[name] = fn() { done(r) } })
          }
        "composer.take" | "composer.restore" | "composer.carry" =>
          match fails.get(name) {
            Some(e) => held[name] = fn() { done(Err(e)) }
            None => (base.call)(name, params, done)
          }
        _ => (base.call)(name, params, done)
      }
    },
  }
  (@ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2), src)
}

///|
/// What the core kept for `name` given (its answer, as it comes a round trip late).
fn give_held(held : Map[String, () -> Unit], name : String) -> Unit raise {
  match held.get(name) {
    Some(give) => give()
    None => fail("\{name} not asked")
  }
}

///|
test "a new chat's chat not made once it was left for another page: that page stays, its first words back in the new chat's draft" {
  both_pages(fn() raise {
    let held : Map[String, () -> Unit] = Map([])
    let (t, src) = failing_core(held, {
      "newChat.create": { "code": "unavailable", "message": "Willow 离线" },
    })
    let words = "把发布说明写一下"
    new_chat_sent(t, words) |> ignore
    guard app.nav.top() is Chat(_) else { fail("not become the chat") }
    t.run_for(new_leave_ms)
    // left for Home before the core says the chat could not be made
    t.back()
    t.run_for(@ui.move_most_ms)
    let left = app.nav.top()
    assert_false(left is Chat(_) || left is NewChat, msg="not left")
    give_held(held, "newChat.create")
    t.run_for(@ui.move_most_ms)
    // (the page left for, not the new chat put in its place: Nav::become changes whatever is on top)
    assert_true(app.nav.top() == left, msg="the page left for replaced")
    // its first words, where the new chat will have them as it is opened again
    assert_eq(@sfbase.writing(src, "new:ws1").text.get(), words)
  })
}

///|
test "a new chat's chat not made, something written meanwhile in its composer: that stays, why the words did not go said" {
  both_pages(fn() raise {
    let held : Map[String, () -> Unit] = Map([])
    let (t, src) = failing_core(held, {
      "newChat.create": { "code": "unavailable", "message": "Willow 离线" },
    })
    new_chat_sent(t, "把发布说明写一下") |> ignore
    guard app.nav.top() is Chat(r) else { fail("not become the chat") }
    t.run_for(new_leave_ms)
    // written on in the chat's composer, as a hand does (by its hint)
    t.tap_text("发消息")
    t.run_for(@ui.move_most_ms)
    t.type_text("接着写")
    t.run_for(@ui.move_most_ms)
    assert_eq(@sfbase.writing(@sfbase.page_source_for_chat(src, r), r.station + ":" + r.session).text.get(), "接着写")
    give_held(held, "newChat.create")
    t.run_for(@ui.move_most_ms)
    assert_true(app.nav.top() is NewChat)
    // what was written meanwhile, not the first words over it
    assert_eq(@sfbase.writing(src, "new:ws1").text.get(), "接着写")
    // why they did not go, said
    seen_once(t, "发送失败：Willow 离线") |> ignore
  })
}

///|
test "a new chat's first message refused by the core: its words back in the chat's composer, the page the chat" {
  both_pages(fn() raise {
    let held : Map[String, () -> Unit] = Map([])
    let (t, src) = failing_core(held, {
      "chat.send": { "code": "invalid_params", "message": "太长了" },
    })
    let words = "把发布说明写一下"
    new_chat_sent(t, words) |> ignore
    guard app.nav.top() is Chat(r) else { fail("not become the chat") }
    give_held(held, "newChat.create")
    t.draw()
    give_held(held, "chat.send")
    t.run_for(@ui.move_most_ms)
    assert_true(app.nav.top() is Chat(_))
    // back in the chat's composer, as the core has it (not only as the page last drew it)
    assert_eq(@sfbase.writing(src, r.station + ":" + r.session).text.get(), words)
    assert_eq(@sfbase.writing(src, "new:ws1").text.get(), "")
  })
}

///|
test "a new chat's first message rejected with auth_stale restores words in composer instead of swallowing them" {
  both_pages(fn() raise {
    let held : Map[String, () -> Unit] = Map([])
    let (t, src) = failing_core(held, {
      "chat.send": { "code": "auth_stale", "message": "授权或锁定状态已变化，请重试" },
    })
    let words = "把发布说明写一下"
    new_chat_sent(t, words) |> ignore
    guard app.nav.top() is Chat(r) else { fail("not become the chat") }
    give_held(held, "newChat.create")
    t.draw()
    give_held(held, "chat.send")
    t.run_for(@ui.move_most_ms)
    assert_true(app.nav.top() is Chat(_))
    assert_eq(@sfbase.writing(src, r.station + ":" + r.session).text.get(), words)
  })
}

///|
test "newChat.create and composer.restore both failing with auth_stale still restore words in new chat composer" {
  both_pages(fn() raise {
    let held : Map[String, () -> Unit] = Map([])
    let (t, _) = failing_core(held, {
      "newChat.create": { "code": "auth_stale", "message": "授权或锁定状态已变化，请重试" },
      "composer.restore": { "code": "auth_stale", "message": "授权或锁定状态已变化，请重试" },
    })
    let words = "把发布说明写一下"
    new_chat_sent(t, words) |> ignore
    guard app.nav.top() is Chat(_) else { fail("not become the chat") }
    give_held(held, "newChat.create")
    t.run_for(@ui.move_most_ms)
    give_held(held, "composer.restore")
    t.run_for(@ui.move_most_ms)
    assert_true(app.nav.top() is NewChat)
    let (_, back, _, _) = t.ime()
    assert_eq(back, words)
    seen_once(t, "发送失败：授权或锁定状态已变化，请重试") |> ignore
  })
}

///|
test "composer.take failing with auth_stale on new chat returns to NewChat with words intact (even if newChat.create succeeds)" {
  both_pages(fn() raise {
    let held : Map[String, () -> Unit] = Map([])
    let (t, _) = failing_core(held, {
      "composer.take": { "code": "auth_stale", "message": "授权或锁定状态已变化，请重试" },
      "composer.carry": { "code": "auth_stale", "message": "授权或锁定状态已变化，请重试" },
    })
    let words = "把发布说明写一下"
    new_chat_sent(t, words) |> ignore
    guard app.nav.top() is Chat(r) else { fail("not become the chat") }
    give_held(held, "composer.take")
    t.run_for(@ui.move_most_ms)
    give_held(held, "newChat.create")
    t.run_for(@ui.move_most_ms)
    assert_true(app.nav.top() is NewChat, msg="must return to NewChat so restored draft is visible")
    let (_, back, _, _) = t.ime()
    assert_eq(back, words)
    // `fresh.made` is preserved so retrying Send reuses the created chat rather than leaking an empty one.
    assert_eq(@sfbase.fresh.made.get(), r.session)
    seen_once(t, "发送失败：授权或锁定状态已变化，请重试") |> ignore
  })
}

///|
test "composer.take and newChat.create both failing with auth_stale return to NewChat with words intact and a single toast" {
  both_pages(fn() raise {
    let held : Map[String, () -> Unit] = Map([])
    let (t, _) = failing_core(held, {
      "composer.take": { "code": "auth_stale", "message": "授权或锁定状态已变化，请重试" },
      "composer.carry": { "code": "auth_stale", "message": "授权或锁定状态已变化，请重试" },
      "newChat.create": { "code": "auth_stale", "message": "授权或锁定状态已变化，请重试" },
    })
    let words = "把发布说明写一下"
    new_chat_sent(t, words) |> ignore
    guard app.nav.top() is Chat(_) else { fail("not become the chat") }
    give_held(held, "composer.take")
    t.run_for(@ui.move_most_ms)
    let toast_n_after_take = app.toast.get().n
    give_held(held, "newChat.create")
    t.run_for(@ui.move_most_ms)
    assert_true(app.nav.top() is NewChat)
    let (_, back, _, _) = t.ime()
    assert_eq(back, words)
    assert_eq(@sfbase.fresh.made.get(), "", msg="failed newChat.create must clear fresh.made")
    assert_eq(app.toast.get().n, toast_n_after_take, msg="must not show duplicate toast when both fail")
  })
}

///|
/// Home over the made-up chats with the new chat's stations not read while `reading` says (the core's `newChat` with
/// no `stations`: only the station it last started on, `kept`), the new chats asked for counted in `made`.
fn reading_core(reading : @signals.Signal[Bool], made : Ref[Int]) -> @ui.Tester {
  new_run()
  let base = fixture("home")
  let src : Source = {
    ..base,
    call: fn(name, params, done) {
      if name == "newChat.create" {
        made.val += 1
      }
      (base.call)(name, params, done)
    },
    topic_read: fn(name, params) {
      if name == "newChat" && reading.get() {
        // (the key its chat is to be made under, as the core gives it whatever it has read)
        let next = text(base.topic(name, params).get().snapshot().value, "next")
        {
          value: Some({
            "kept": "st1",
            "next": Json::string(next),
            "any": false,
            "waiting": false,
          }),
          error: None,
          version: 0,
        }
      } else {
        base.topic(name, params).get().snapshot()
      }
    },
  }
  @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
}

///|
test "a new chat while its stations are read: its page as it will be, its first words sent at once to the station it last started on" {
  both_pages(fn() raise {
    let reading = @signals.signal(true)
    let made = Ref(0)
    let t = reading_core(reading, made)
    let (_, y) = bar_places_at()
    t.tap(bar_action_x, y)
    t.run_for(@ui.move_most_ms)
    // the page's own words and its composer, nothing said of a station not known yet
    assert_true(t.find("想让 agent 做什么？") is Some(_))
    assert_true(t.find("它会在") is None)
    assert_true(t.find("没有可用模型") is None)
    // sent while they are read: made at once on the station it last started on (the owner, 2026-11-14: 「new chat 发消息
    // 任何时候都应该立即发出去」), the field emptied, never a press taken for nothing
    t.tap_text("做任何事")
    t.type_text("先写一半")
    t.draw()
    tap_send(t)
    t.draw()
    assert_eq(made.val, 1)
    let (_, field, _, _) = t.ime()
    assert_eq(field, "")
    assert_true(app.nav.top() is Chat(_))
    // read meanwhile: nothing more made
    reading.set(false)
    t.draw()
    assert_eq(made.val, 1)
  })
}

///|
test "a new chat's first words: the room under its rows goes down to where the composer comes to stand, never at once" {
  both_pages(fn() raise {
    let t = tester("home")
    // (three lines: the composer held as tall for them till they set out, lines more than it comes to stand at)
    let words = "第一行\n第二行\n第三行"
    ignore(new_chat_sent(t, words))
    // (every frame drawn from the press on, as a display draws them: the composer let go of as the words set out, its
    // room under the rows on the list's way with it, not a step)
    // (the chat's list's, the last list drawn, once it is the only one: the new chat's page has a list of its own
    // before, leaving as the chat comes; the old view's foot its last row, the page made as nodes' its list's own, held
    // apart from its rows (View::scrolls_window's `foot`): the room from where they end to the window's foot, a row
    // that comes making its way into it)
    let foot = fn() {
      let lists = t.list_row_boxes()
      if !(app.nav.top() is Chat(_)) || lists.length() != 1 || lists[0].length() == 0 {
        -1.0
      } else {
        let (_, y, _, h) = lists[0][lists[0].length() - 1]
        844.0 - (y + h)
      }
    }
    let mut was = foot()
    let end = t.time() + flight_carry_after_ms + flight_carry_ms + @ui.move_most_ms
    while t.time() < end {
      t.frame()
      let now = foot()
      if was >= 0.0 && now >= 0.0 {
        assert_true((now - was).abs() < newchat_foot_step, msg="at \{t.time()}: the room under the rows \{was} → \{now}")
      }
      was = now
    }
  })
}

///|
/// The most the room under a new chat's rows may change in a frame on its way (points): a line's at once is a step.
let newchat_foot_step : Double = 8.0

///|
test "unfolded: a new chat's long first words sent: the room under the chat's rows never below 0" {
  both_pages(fn() raise {
    // (a foldable opened, laid out Medium with touch: the chat's list keeps the composer's room as it comes to stand,
    // composer_room's `settled`, from the frame the new chat becomes the chat; that room measured the new chat's tall
    // composer against a foot never measured on a chat's page, -200 under 0: 0.1.8569's crash, chat_list's Foot row
    // `Exact(<0>)`)
    let src = @sffixture.round_trip(fixture_app("chat"), 60.0)
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=864.0, h=954.0, platform=2)
    // (what is held here is that it is drawn at all; how the composer opens at this width is not this test's)
    t.motion_unjudged(true)
    let words = "把发布说明写一下，" + "先列出这次改了什么、为什么改、谁会注意到，再按页面分组，每组写清楚旧的和新的样子。".repeat(6)
    t.drive("timeout 20000\nuntil 新建对话\ntap 新建对话\nuntil 做任何事\ntap 做任何事\n") |> ignore
    t.type_text(words)
    t.draw()
    tap_send(t)
    t.draw()
    let till = t.time() + @sfbase.flight_desk_ms + new_leave_ms + @sfbase.sent_down_ms
    while t.time() < till {
      t.frame()
    }
    assert_true(app.nav.top() is Chat(_))
  })
}

///|
test "a new chat's first words the station has not taken yet: in its outbox, not back in its composer as well" {
  let held : Map[String, () -> Unit] = Map([])
  let session = Ref("")
  let restored : Array[String] = []
  new_run()
  let base = fixture("home")
  let src : Source = {
    ..base,
    call: fn(name, params, done) {
      match name {
        "chat.send" => {
          session.val = text(Some(params), "session")
          // (the core took it into the chat's outbox, which sends it once the station answers)
          held[name] = fn() {
            done(Err({ "code": Json::string("timeout"), "message": Json::string("Willow 没有回应") }))
          }
        }
        "composer.restore" => {
          restored.push(text(Some(params), "key"))
          (base.call)(name, params, done)
        }
        _ => (base.call)(name, params, done)
      }
    },
  }
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  let words = "把发布说明写一下"
  new_chat_sent(t, words) |> ignore
  t.run_for(new_leave_ms)
  match held.get("chat.send") {
    Some(give) => give()
    None => fail("the message not sent")
  }
  t.draw()
  t.run_for(new_leave_ms)
  assert_true(app.nav.top() is Chat(_))
  assert_true(session.val != "")
  let w = @sfbase.writing(src, "ws1/st1:" + session.val)
  assert_eq(w.text.get(), "")
  assert_eq(w.field.text(), "")
  let (_, field, _, _) = t.ime()
  assert_eq(field, "")
  assert_eq(restored, [], msg="its words put back in the composer")
  assert_true(@sfbase.toast_words().contains("Willow 没有回应"))
}

///|
/// Sent from a new chat with the screen's keyboard up, it stays up as the page becomes the chat, the next words typed
/// into the chat's composer: though its field is another draft's, and a chat come to takes the cursor only where the
/// keyboard is at hand, the cursor is held where the composer's field is built (held so 2026-11-17, asked of a report).
test "a new chat's first words sent with the keyboard up: the chat it becomes written in at once, its keyboard kept up" {
  both_pages(fn() raise {
    let held : Map[String, () -> Unit] = Map([])
    let unread = @signals.signal(false)
    // (the screen's keyboard: a finger the native input)
    let t = held_core(held, unread, finger=true)
    let (_, y) = bar_places_at()
    t.tap(bar_action_x, y)
    t.run_for(@ui.move_most_ms)
    t.tap_text("做任何事")
    keyboard_up(t, 336.0)
    t.type_text("第一条")
    t.draw()
    tap_send(t)
    t.run_for(@ui.move_most_ms)
    assert_true(app.nav.top() is Chat(_))
    let (active, _, _, _) = t.ime()
    assert_true(active, msg="the keyboard went down as the new chat became the chat")
    t.type_text("第二条")
    t.draw()
    let (_, words, _, _) = t.ime()
    assert_eq(words, "第二条")
    for name in ["newChat.create", "chat.send"] {
      match held.get(name) {
        Some(give) => give()
        None => fail("\{name} not asked")
      }
      t.draw()
    }
    t.run_for(new_leave_ms)
    let (active, _, _, _) = t.ime()
    assert_true(active)
  })
}

///|
/// The frames a host draws (60 a second, as it draws them: check_looks(false), its rows on the device's pixels) of a new
/// chat's first words sent on the page made as nodes, opened as fixture mode `mode` on a `w` by `h` window of
/// `platform` and driven by `script`: at each, its moment and whether the new chat's scene (its title) is seen.
fn new_scene_frames(
  mode : String,
  w : Double,
  h : Double,
  platform : Int,
  script : String,
) -> Array[(Double, Bool)] raise {
  new_run()
  let src = fixture_app(mode)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform~, words_over_held=false)
  t.check_looks(false)
  t.set_rows_on_pixels(true)
  t.set_frame_period(1000.0 / 60.0)
  let title = @sf.t("android-chat.new.heading")
  let frames : Array[(Double, Bool)] = []
  t.drive(script, each=fn(t) {
    frames.push((t.time(), t.words().iter().any(fn(wd) { wd.0 == title && wd.5 > 0.02 })))
  })
  |> ignore
  assert_true(app.nav.top() is Chat(_), msg="the new chat did not become its chat")
  frames
}

///|
/// Where the frames `frames` (new_scene_frames') draw the new chat's scene, then none of it, then it again: each such
/// frame's moment.
fn new_scene_gaps(frames : Array[(Double, Bool)]) -> Array[Double] {
  let gaps = []
  for i in 1..<(frames.length() - 1) {
    if !frames[i].1 && frames[i - 1].1 {
      let mut back = false
      for j in (i + 1)..<frames.length() {
        if frames[j].1 {
          back = true
        }
      }
      if back {
        gaps.push(frames[i].0)
      }
    }
  }
  gaps
}

///|
/// The page becomes the chat in the change its first words are sent in, its scene leaving over the chat from then
/// (new_leave_ms): the scene's old view is the one the page showed, the same node going on to draw it leaving, never let
/// go there and made again for its way out (an old view hosted in a node draws nothing in the frame it is made: the frame
/// the words went in was drawn with neither the scene nor a composer, and the scene back the next; 2026-11-17).
test "a new chat's first words sent on the page made as nodes: its scene drawn in every frame till it has left, 大屏 and 小屏" {
  if @ui.test_at_a_rate() {
    return
  }
  let wide = new_scene_frames(
    "chat",
    1280.0,
    800.0,
    0,
    "timeout 20000\nuntil 新建对话\nwait 600\ntap 新建对话\nwait 900\nuntil 做任何事\nwait 500\ntype 把发布说明写一下\nwait 700\ntap icon:arrow-up\nwait 600\nexit\n",
  )
  assert_eq(new_scene_gaps(wide), [])
  let narrow = new_scene_frames(
    "newchat",
    390.0,
    844.0,
    2,
    "timeout 20000\nwait 1200\ntap 做任何事\nwait 500\ntype 把发布说明写一下\nwait 700\ntap icon:arrow-up\nwait 600\nexit\n",
  )
  assert_eq(new_scene_gaps(narrow), [])
  let picture = new_scene_frames("newchat-attach", 390.0, 844.0, 2, "timeout 20000\nwait 1500\ntap icon:arrow-up\nwait 600\nexit\n")
  assert_eq(new_scene_gaps(picture), [])
}
