// A chat's page made with its inside nodes (sfbase's chat_page_nodes on): a picture quoted in words sent from here,
// pressed in their message once the core has taken the row over, opens in the viewer asked of the core by the name
// the core gives that row (`o:<outbox id>/q:<i>`, the core's placed.ts `near`: by any other it finds the picture
// nowhere, and the viewer has no way to the chat's other pictures nor says which of them it is), and goes back to the
// row it was pressed in as it closes; pressed before the core has it, it is asked by that name as the core takes it
// over (the row keeping the key it was sent as: chat_body_rows' `sent_as`, given the viewer by sfbase's rows_sent_as).
// On 小屏 over the whole window, and on 大屏 as its tab beside the chat over the whole window.

///|
/// The core's outbox row `out-1` taking over words "." sent from here quoting picture `file` (named `name`), once
/// `has` is on.
fn cnsq_core(has : @signals.Signal[Bool], name : String, file : Json, w : Double, platform : Int) -> (@ui.Tester, Source) {
  let made : Ref[Source?] = Ref(None)
  let calls : Array[Made] = []
  let t = fake_core(calls, made~, platform~, over=fn(topic, tp) {
    match (topic, tp.value) {
      ("chat", Some(Object(m))) if has.get() => {
        let v = m.copy()
        v["outbox"] = [{
          "id": "out-1", "text": ".", "createdAt": 0, "state": "sending",
          "attachments": [file],
          "quotes": [{ "author": "Ana", "text": Json::string(name), "ts": "ts8", "comment": "", "file": Json::string(name) }],
        }]
        { ..tp, value: Some(Json::object(v)), version: tp.version + 1 }
      }
      _ => tp
    }
  })
  if w != 390.0 {
    t.resize(w, 844.0)
    t.run_for(@ui.move_most_ms)
  }
  (t, made.val.unwrap())
}

///|
/// Where the viewer asked the core for the pictures beside the one it shows (imageNear's `at`), since it was last
/// cleared.
fn cnsq_asked() -> Array[String] {
  let asked : Array[String] = []
  @sfbase.near_asked.each(fn(_, p) { asked.push(text(Some(Json::object(p)), "at")) })
  asked
}

///|
/// On a screen `w` wide (`platform`'s): a picture quoted and sent, the core taking the row over before it is pressed
/// (`early` false) or as it shows in the viewer (`early`); asked by the core's name for the row, back to its row.
fn cnsq_check(w : Double, platform : Int, early : Bool) -> Unit raise {
  let has = @signals.signal(false)
  let name = "sent-quote.png"
  let file : Json = { "name": Json::string(name), "path": Json::string("/w/uploads/" + name), "size": 120, "width": 1600, "height": 900, "owner": "s-c1" }
  let (t, src) = cnsq_core(has, name, file, w, platform)
  let wr = @sfbase.writing(src, "ws1/st1:s-c1")
  @sfbase.writing_quote(src, wr, { "author": "Ana", "text": Json::string(name), "ts": "ts8" }, file~)
  t.run_for(@ui.move_most_ms + @ui.image_fade_ms)
  t.tap_text("发消息")
  t.type_text(".")
  tap_send(t)
  t.run_for(@sfbase.flight_len(true) * 2.0 + @sf.hint_back_ms + @ui.move_most_ms)
  if !early {
    has.set(true)
    t.run_for(@ui.move_most_ms)
  }
  let pictures = t.locate("img:" + name)
  assert_eq(pictures.length(), 1, msg="the quoted picture in its message: \{Repr(pictures)}")
  @sfbase.near_asked.clear()
  t.tap(pictures[0].0, pictures[0].1)
  t.frame()
  if early {
    has.set(true)
    t.frame()
  }
  let asked = cnsq_asked()
  assert_true(
    asked.last() == Some("o:out-1/q:0"),
    msg="\{w}, taken over \{if early { "as it shows" } else { "before" }}: the viewer asked the core by \{Repr(asked)}, not by its row's name there",
  )
  t.run_for(@ui.move_most_ms)
  // (over the whole window, a phone's and a desktop's 大屏's as its tab: back closing it)
  t.back()
  t.run_for(@ui.move_most_ms * 2.0)
  let back = t.locate("img:" + name)
  // (on 大屏 its row laid out at the narrower width under its tab and back again, to a tenth of a point where it was;
  // on 小屏, flown back to its very place)
  let near = fn(a : (Double, Double), b : (Double, Double)) {
    if w == 390.0 {
      a == b
    } else {
      (a.0 - b.0).abs() < 0.5 && (a.1 - b.1).abs() < 0.5
    }
  }
  assert_true(back.length() == 1 && near(back[0], pictures[0]), msg="\{w}: closed, not back in its row: \{Repr(back)} (was \{Repr(pictures[0])})")
}

///|
test "a picture quoted in words sent from here opens asked of the core by its row's name there, and goes back to that row" {
  for screen in [(390.0, 2), (1280.0, 0)] {
    cnsq_check(screen.0, screen.1, false)
    cnsq_check(screen.0, screen.1, true)
  }
}

///|
/// The first of the words over words drawn now (Tester::words_over_now) that names words `over` says and words `under`
/// says, with when.
fn cnsq_crossed(t : @ui.Tester, over : (String) -> Bool, under : (String) -> Bool) -> String? {
  for f in t.words_over_now() {
    let (a, b) = match f.split("」 under 「").to_array() {
      [a, b] => (a.to_owned(), b.to_owned())
      _ => continue
    }
    let a = a.trim_start(chars="「").to_owned()
    let b = match b.split("」").to_array() {
      [b, ..] => b.to_owned()
      _ => continue
    }
    if (under(a) && over(b)) || (under(b) && over(a)) {
      return Some(f + " at \{t.time()}")
    }
  }
  None
}

///|
/// The chat's page made as nodes on 小屏, the fixture's station answering on the test's clock (`clock`).
fn cnsq_fixture(clock : Ref[Double]) -> @ui.Tester {
  new_run()
  fix_clock.val = Some(fn() { clock.val })
  let src = fixture("chat")
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2, words_over_held=false)
  t.run_for(@ui.move_most_ms)
  t
}

///|
test "words sent from here that fail at once: 未发送 and 重试 under them seen as they land, never under them on their way" {
  let clock : Ref[Double] = { val: 0.0 }
  let t = cnsq_fixture(clock)
  // (one sent and answered first, as composer_wbtest's: its agent's answer over, the next sent in their turn after it)
  t.tap_text("发消息")
  t.type_text("测试一下")
  tap_send(t)
  fix_clock_set(clock, clock.val + fix_deliver_ms)
  t.draw()
  t.run_for(fix_answer_ms)
  fix_clock_set(clock, clock.val + fix_answer_ms)
  t.draw()
  t.run_for(Pose::Fold.ms() + Pose::Float.ms() + Pose::Spit.ms() + Pose::Return.ms() + 2.0 * @ui.frame_period_default)
  t.tap_text("发消息")
  t.type_text("这条会失败")
  tap_send(t)
  // (the station refuses it in the press's moment: what did not go said while the words still fly from the field)
  fix_clock_set(clock, clock.val + fix_deliver_ms)
  let crossed : Ref[String?] = Ref(None)
  let check = fn() {
    if crossed.val is None {
      crossed.val = cnsq_crossed(t, fn(w) { w == "这条会失败" }, fn(w) { w == "未发送" || w == "重试" || w == "删除" })
    }
  }
  t.each_frame(Some(check))
  t.draw()
  t.run_for(@sfbase.flight_desk_ms + @ui.move_most_ms)
  t.each_frame(None)
  assert_true(crossed.val is None, msg="\{Repr(crossed.val)}")
  // landed: what did not go said under them, whole
  assert_true(t.words().iter().any(fn(w) { w.0 == "未发送" && w.5 >= 1.0 }), msg="未发送 not seen whole once they landed")
  fix_clock.val = None
}

///|
test "words sent from here quoting a message with a comment: the quote's card flies from the composer's with them, seen in every frame, never under them" {
  let clock : Ref[Double] = { val: 0.0 }
  let t = cnsq_fixture(clock)
  let card = fn(w : String) { w.has_prefix("Claude：做完了") }
  let quote_of = fn() {
    let (x, y) = t.find("做完了：列表、跳到最新的按钮").unwrap()
    t.press_at(x, y)
    t.run_for(long_press_ms)
    t.release(x, y)
    t.tap_text("全选")
    t.tap_text("引用")
  }
  quote_of()
  t.type_text("这里再确认一下")
  t.tap_text("发消息")
  t.type_text("看看这个")
  // (sent at once, the composer still opening to the quote, as a quick hand has it: the composer_wbtest's case)
  let crossed : Ref[String?] = Ref(None)
  // (where the card's words are seen in each frame: one copy, not see-through, a step on from the frame before)
  let tops : Array[Double?] = []
  t.each_frame(Some(fn() {
    if crossed.val is None {
      crossed.val = cnsq_crossed(t, fn(w) { w == "看看这个" }, card)
    }
    let seen = t.words().filter(fn(w) { card(w.0) && w.5 > 0.5 && w.2 > 60.0 && w.2 < 844.0 })
    tops.push(if seen.length() == 1 { Some(seen[0].2) } else { None })
  }))
  tap_send(t)
  t.run_shown(@sfbase.flight_desk_ms + @ui.move_most_ms)
  t.each_frame(None)
  assert_true(crossed.val is None, msg="\{Repr(crossed.val)}")
  assert_true(tops.iter().all(fn(y) { y is Some(_) }), msg="the card not seen once in some frame of its way: \{Repr(tops)}")
  for i in 1..<tops.length() {
    match (tops[i - 1], tops[i]) {
      (Some(a), Some(b)) => assert_true((b - a).abs() < 80.0, msg="the card jumped from \{a} to \{b} in a frame: \{Repr(tops)}")
      _ => ()
    }
  }
  assert_true(t.words().iter().any(fn(w) { card(w.0) && w.5 >= 1.0 && w.2 > 0.0 && w.2 < 844.0 }), msg="the card not seen whole once they landed")
  // again, the composer at rest with its quote over the field: the card sets out from where it stood there
  quote_of()
  t.type_text("再看一眼")
  t.tap_text("发消息")
  t.type_text("还有这个")
  t.run_for(@ui.move_most_ms)
  // (the composer's card: the lowest of the card's copies, the one sent before it in its row over it)
  let mut from = -1.0
  for w in t.words() {
    if card(w.0) && w.5 > 0.5 && w.2 > from {
      from = w.2
    }
  }
  let first : Ref[Double?] = Ref(None)
  t.each_frame(Some(fn() {
    if first.val is None {
      let mut near : Double? = None
      for w in t.words() {
        if card(w.0) && w.5 > 0.5 {
          match near {
            Some(n) if (n - from).abs() <= (w.2 - from).abs() => ()
            _ => near = Some(w.2)
          }
        }
      }
      first.val = near
    }
  }))
  tap_send(t)
  t.run_shown(@sfbase.flight_desk_ms + @ui.move_most_ms)
  t.each_frame(None)
  match first.val {
    Some(y) => assert_true((y - from).abs() < 12.0, msg="set out at \{y}, not from the composer's card at \{from}")
    None => fail("the card not seen in the frame after the press")
  }
  fix_clock.val = None
}
