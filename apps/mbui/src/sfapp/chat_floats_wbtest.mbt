// What floats over a chat's list on its page made as nodes (sfpages' chat_jump_node.mbt): the way back to the newest
// coming and going by its fade (the old page's float_trans) once the list has been in sight, standing as it is found
// as the chat opens; gone as soon as it is pressed and the list glides back (the old list's `gliding`); and 对话目录's
// rail, its ticks there before held where they are drawn as a message comes, never a jump.

///|
/// How opaque the way back to the newest is drawn, by its liquid glass surface's alpha (its round button's `kind == 6`
/// instance, inside `rect`), 0 to 255; none where nothing of it is drawn there.
fn to_newest_alpha(t : @ui.Tester, rect : (Double, Double, Double, Double)) -> Int64? {
  let (x, y, w, h) = rect
  let mut most : Int64? = None
  for a in t.drawn_instances() {
    if a.length() > 15 && a[5] == 6.0 {
      let (cx, cy) = (a[0] + a[2] / 2.0, a[1] + a[3] / 2.0)
      if cx > x && cx < x + w && cy > y && cy < y + h {
        let alpha = (a[15] * 255.0).round().to_int64()
        if most is None || alpha > most.unwrap() {
          most = Some(alpha)
        }
      }
    }
  }
  most
}

///|
/// `ms` of the long chat's frames (long_run's), `each` told after each.
fn long_run_each(t : @ui.Tester, l : LongChat, ms : Double, each : () -> Unit) -> Unit {
  let from = t.time()
  while t.time() - from < ms - 1.0e-6 {
    long_frame(t, l)
    each()
  }
}

///|
test "a chat's page made with its inside nodes, on 小屏 and 大屏: the way back to the newest fades in as the reader leaves its end (the old page's float_trans); pressed, it fades out as the list glides back, never shown again on that way" {
  for s in long_screens {
    let (name, w, h, _) = s
    let l = long_chat()
    let t = place_long_open(l, s)
    let last = "第\{long_count}条："
    guard t.rect_of(last) is Some((_, end, _, _)) else { fail("\{name}: its last message not drawn as it opens") }
    // read up: from the frame it first shows, coming in faded
    let alphas : Array[Int64] = []
    let rect : Ref[(Double, Double, Double, Double)?] = Ref(None)
    t.move_to(w / 2.0, h / 2.0)
    t.wheel(w / 2.0, h / 2.0, -600.0)
    long_run_each(t, l, long_rest_ms, fn() {
      match to_newest_shown(t) {
        Some(b) => {
          rect.val = Some(b.rect)
          match to_newest_alpha(t, b.rect) {
            Some(a) => alphas.push(a)
            None => ()
          }
        }
        None => ()
      }
    })
    guard rect.val is Some(r) && alphas.length() > 1 else { fail("\{name}: the way back to the newest not shown read up") }
    let rest = alphas[alphas.length() - 1]
    assert_true(alphas[0] < rest, msg="\{name}: shown at once, not faded in: \{Repr(alphas)}")
    for i in 1..<alphas.length() {
      assert_true(alphas[i] >= alphas[i - 1], msg="\{name}: coming in, fainter again: \{Repr(alphas)}")
    }
    // pressed: out as the glide sets out, and nothing of it once its fade is over, the list still on its way
    t.click(Button, label="跳到最新")
    let gone : Array[(Double, Int64?)] = []
    let from = t.time()
    long_run_each(t, l, long_rest_ms, fn() { gone.push((t.time() - from, to_newest_alpha(t, r))) })
    assert_true(gone[0].1.unwrap_or(0L) < rest, msg="\{name}: pressed, still whole as the glide sets out: \{Repr(gone)}")
    let mut was : Int64 = rest
    for i, g in gone {
      match g.1 {
        Some(a) => {
          assert_true(a <= was, msg="\{name}, frame \{i}: pressed, back to \{a} from \{was}: \{Repr(gone)}")
          was = a
        }
        None => was = 0L
      }
      // (gone once its fade is over: the old page's float_ms, 160)
      if g.0 > 200.0 {
        assert_true(g.1 is None || g.1 == Some(0L), msg="\{name}, frame \{i}: pressed, still drawn at \{g.0}: \{Repr(gone)}")
      }
    }
    let now = t.rect_of(last).map(fn(r) { r.1 })
    assert_true(now is Some(y) && (y - end).abs() <= 1.0, msg="\{name}: pressed, its last message at \{Repr(now)}, its end \{end}")
    assert_true(to_newest_shown(t) is None, msg="\{name}: the way back to the newest shown at its end again")
  }
}

///|
test "a chat's page made with its inside nodes, on 小屏 and 大屏: opened again where it was left read up, the way back to the newest stands there whole from the first frame it is drawn in, coming in by nothing" {
  for s in long_screens {
    let (name, w, h, _) = s
    let l = long_chat()
    let t = place_long_open(l, s)
    // read up, the way back to the newest shown and at rest: how opaque it is then
    t.move_to(w / 2.0, h / 2.0)
    t.wheel(w / 2.0, h / 2.0, -600.0)
    long_run(t, l, long_rest_ms)
    guard to_newest_shown(t) is Some(b) && to_newest_alpha(t, b.rect) is Some(rest) else {
      fail("\{name}: the way back to the newest not shown read up")
    }
    // left, and opened again: each frame it is drawn in, as opaque as at rest
    home()
    @ui.came_from_outside()
    long_run(t, l, long_opened_ms)
    assert_true(to_newest_shown(t) is None, msg="\{name}: the way back to the newest left over the chats")
    let seen : Array[Int64] = []
    open_chat(long_ref)
    @ui.came_from_outside()
    long_run_each(t, l, long_opened_ms, fn() {
      match to_newest_shown(t) {
        Some(b) =>
          match to_newest_alpha(t, b.rect) {
            Some(a) => seen.push(a)
            None => ()
          }
        None => ()
      }
    })
    assert_true(seen.length() > 0, msg="\{name}: opened again read up, the way back to the newest not shown")
    assert_true(seen.iter().all(fn(a) { a == rest }), msg="\{name}: opened again, it came in: \{Repr(seen)}, at rest \{rest}")
  }
}

///|
/// The long chat of two people away from its end (chat-outline-away) on its page made as nodes, 1280 by 800 on a Mac,
/// its outline (chatOutline) what `outline` says once it says any (told anew each time it changes); made, nothing run
/// yet.
fn rail_told_tester(outline : @signals.Signal[Json?]) -> @ui.Tester {
  new_run()
  @sf.presenters_reset()
  let base = fixture("chat-outline-away")
  let told = Ref(0)
  let src : Source = {
    ..base,
    asks_outline: fn() { true },
    topic_read: fn(name, params) {
      match (name, outline.get()) {
        ("chatOutline", Some(o)) => {
          told.val += 1
          { value: Some(o), error: None, version: 1000 + told.val }
        }
        _ => (base.topic_read)(name, params)
      }
    },
  }
  open_fixture_over("chat-outline-away", src)
  @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
}

///|
/// The tops of the rail's ticks (`rail` its press) drawn now, from the top.
fn rail_tick_tops(t : @ui.Tester, rail : (Double, Double, Double, Double)) -> Array[Double] {
  let (rx, ry, rw, rh) = rail
  let tops = outline_drawn(t, "rect")
    .filter(fn(r) { r.0 >= rx && r.0 + r.2 <= rx + rw + 0.5 && r.1 >= ry - 40.0 && r.1 + r.3 <= ry + rh + 40.5 && r.3 <= 2.5 })
    .map(fn(r) { r.1 })
  tops.sort()
  tops
}

///|
test "对话目录's rail on a chat's page made as nodes: a message said, on its day and on a day after, its tick comes in as the rail makes room for it; the ticks there before move to their places a little each frame, never a jump" {
  let outline : @signals.Signal[Json?] = @signals.signal(None)
  let t = rail_told_tester(outline)
  t.run_for(@ui.move_most_ms)
  t.run_for(@ui.move_most_ms)
  // (the fixture's outline as the core tells it, told again by the test from now on)
  let said = (fixture("chat-outline-away").topic_read)("chatOutline", { "station": "ws1/st1", "thread": 7 }).value
  guard said is Some(Object(o)) && o.get("days") is Some(Array(days)) && days.length() > 0 else {
    fail("the fixture's outline: \{Repr(said)}")
  }
  let days = days.copy()
  outline.set(Some(Json::object(o)))
  t.run_for(@ui.move_most_ms)
  guard rail_nodes_rails(t, 1280.0) is [rail] else { fail("no rail: \{Repr(outline_buttons(t))}") }
  let before = rail_tick_tops(t, rail)
  assert_eq(before.length(), 31, msg="\{Repr(before)}")
  let last_seq = outline_seqs_of(days)
  // a message said on its last day, then one on a day after it
  let said_on = fn(day : Json, seq : Double) -> Json {
    guard day is Object(d) && d.get("seqs") is Some(Array(seqs)) else { return day }
    let d = d.copy()
    d["seqs"] = Json::array([..seqs, Json::number(seq)])
    Json::object(d)
  }
  for step in 0..<2 {
    let was = rail_tick_tops(t, rail)
    if step == 0 {
      days[days.length() - 1] = said_on(days[days.length() - 1], last_seq + 1.0)
    } else {
      days.push({ "date": "2026-11-18", "day": "今天", "seqs": [Json::number(last_seq + 2.0)] })
    }
    let o = o.copy()
    o["days"] = Json::array(days.copy())
    outline.set(Some(Json::object(o)))
    @ui.came_from_outside()
    // (each frame on: those there before, each no further than a little from where it was the frame before)
    let mut prev = was
    let mut prev_at = t.time()
    let from = t.time()
    while t.time() - from < @ui.move_most_ms * 2.0 - 1.0e-6 {
      t.run_for(@ui.frame_period_default)
      let now = rail_tick_tops(t, rail)
      let dt = t.time() - prev_at
      let most = 3.0 * @sf.dmax(1.0, dt / @ui.frame_period_default)
      // (the first of them where they were: those over the new one, matched in order from the top)
      for i in 0..<prev.length() {
        if i < now.length() {
          assert_true(
            (now[i] - prev[i]).abs() <= most,
            msg="step \{step}: tick \{i} from \{prev[i]} to \{now[i]} in \{dt} ms: \{Repr(prev)} → \{Repr(now)}",
          )
        }
      }
      prev = now
      prev_at = t.time()
    }
    assert_eq(rail_tick_tops(t, rail).length(), was.length() + 1, msg="step \{step}: \{Repr(rail_tick_tops(t, rail))}")
  }
}

///|
/// The last of the seqs `days` hold (a chatOutline's days), -1 none.
fn outline_seqs_of(days : Array[Json]) -> Double {
  let mut last = -1.0
  for d in days {
    for q in items(Some(d), "seqs") {
      match q {
        Number(seq, ..) => if seq > last { last = seq }
        _ => ()
      }
    }
  }
  last
}
