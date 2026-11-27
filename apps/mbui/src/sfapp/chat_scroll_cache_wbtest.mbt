///|
fn chat_scrolled_reference(keep : Bool) -> (Double, Double, String) raise {
  let t = chat_tester("chat")
  t.check_looks(false)
  t.set_rows_on_pixels(true)
  t.drawn_again(keep)
  t.draw()
  let title = "首页的列表改成按天分组"
  scroll_run_clear(t, title) |> ignore
  let before = t.run_rects(title)[0]
  let visible = t.visible()
  let at = t.time()
  t.wheel_told(195.0, 400.0, 0.0, 5.0, 0, at + 1.0)
  t.frame_at(at + 16.0)
  let after = t.run_rects(title)[0]
  assert_eq(t.visible(), visible, msg="the short scroll must keep the same chat rows")
  assert_true(after.1 < before.1, msg="the reference must move with its message: \{Repr(before)} -> \{Repr(after)}")
  t.tap_run(title)
  let opened = match app.nav.top() {
    Chat(r) => r.session
    _ => ""
  }
  t.drawn_again(true)
  (before.1, after.1, opened)
}

///|
test "a scrolled chat reference opens the same chat with or without kept rows" {
  let ordinary = chat_scrolled_reference(false)
  let kept = chat_scrolled_reference(true)
  println("CHAT_SCROLL_REFERENCE ordinary=\{Repr(ordinary)} retained=\{Repr(kept)}")
  assert_eq(ordinary.2, "s-c2", msg="the reference must open its chat after the scroll")
  assert_eq(kept, ordinary, msg="retained rows must move and respond as the ordinary path")
}

///|
/// What a page's list draws, for reused_wheeled: its words that `of` says are its rows' (where they are and how big)
/// and the rectangles drawn across `lane` (from, to) within the window's height `h`; every fault the audit says.
#derive(Eq, Debug)
priv struct ReusedDrawn {
  words : Array[(String, Double, Double, Double, Double)]
  rects : Array[(Double, Double, Double, Double, Int64)]
  faults : Array[String]
}

///|
/// A page's list's rows of one kind wheeled away and back (View::scrolls_window's `reused`: a row put by as it no more
/// shows, taken by the next of its kind to come to show): `t`'s list under (x, y) wheeled by each of `steps`, then back
/// by each again the other way, then by each once more. What is drawn (ReusedDrawn: `of` its rows' words, across
/// `lane`) at each step of the first way and of the last must be the same, and back where it began what it was before
/// any wheel (its rows made then, never taken for another). What the window's tree made on each of the three ways.
fn reused_wheeled(
  t : @ui.Tester,
  at : (Double, Double),
  lane : (Double, Double),
  h : Double,
  of : (String) -> Bool,
  steps : Array[Double],
) -> (Int, Int, Int) raise {
  let drawn = fn() -> ReusedDrawn {
    {
      words: t.words().filter(fn(w) { of(w.0) && w.2 + w.4 > 0.0 && w.2 < h && w.5 > 0.0 }).map(fn(w) { (w.0, w.1, w.2, w.3, w.4) }),
      rects: t.drawn_rects().filter(fn(r) { r.0 >= lane.0 && r.0 < lane.1 && r.1 + r.3 > 0.0 && r.1 < h }),
      faults: t.audit(),
    }
  }
  let first = drawn()
  let way = fn(dir : Double, seen : Array[ReusedDrawn]) {
    t.tree_frames_from_now()
    for dy in steps {
      t.wheel(at.0, at.1, dir * dy)
      t.draw()
      seen.push(drawn())
    }
    t.tree_frames().fold(init=0, fn(n, f) { n + f.made })
  }
  let down : Array[ReusedDrawn] = []
  let made_down = way(1.0, down)
  let made_up = way(-1.0, [])
  let back = drawn()
  assert_true(back == first, msg="back where it began, what it drew before any wheel: \{Repr(back)} against \{Repr(first)}")
  let again : Array[ReusedDrawn] = []
  let made_again = way(1.0, again)
  for i, d in down {
    assert_true(again[i] == d, msg="step \{i} the second time down, what it drew the first: \{Repr(again[i])} against \{Repr(d)}")
  }
  (made_down, made_up, made_again)
}

///|
test "已归档 on 大屏, sixty chats over six days: its rows and days' headings wheeled away and back are taken for others as they come to show, drawn as made anew, and made no more" {
  reset()
  let base = @sffixture.fixture("archived")
  let src : Source = {
    ..base,
    topic_read: fn(name, params) {
      let got = base.topic(name, params).get().snapshot()
      guard name == "archive" && got.value is Some(Object(v)) else { return got }
      let rows = items(got.value, "days").map(fn(d) { items(Some(d), "items") }).fold(init=[], fn(a, b) { a + b })
      let days : Array[Json] = []
      for d in 0..<6 {
        let these : Array[Json] = []
        for i in 0..<10 {
          let r = rows[(d * 10 + i) % rows.length()]
          // (the made-up core's own first: the newest, opened beside the list, one it answers for)
          if d == 0 && i < rows.length() {
            these.push(r)
            continue
          }
          match r {
            Object(m) => {
              let o = m.copy()
              let id = "x\{d}-\{i}"
              o["id"] = Json::string(id)
              o["session"] = Json::string("s-" + id)
              o["title"] = Json::string(text(Some(r), "title") + " \{d * 10 + i}")
              these.push(Json::object(o))
            }
            _ => ()
          }
        }
        days.push(Json::object({ "label": Json::string("\{d + 1} 天前"), "items": Json::array(these) }))
      }
      let changed = v.copy()
      changed["days"] = Json::array(days)
      { ..got, value: Some(Json::object(changed)) }
    },
  }
  open_fixture_over("archived", src)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.run_for(squeeze_opening)
  // (the newest open beside the list as it opens: its row lit, which a row taken for another is not)
  let row = t.words().iter().find_first(fn(w) { w.0 == "试一下新的图标尺寸" }).unwrap()
  let (down, up, again) = reused_wheeled(t, (row.1 + 20.0, 400.0), (0.0, row.1 + row.3 + 40.0), 800.0, fn(_) { true }, [120.0, 120.0, 120.0, 120.0, 120.0, 120.0, 120.0, 120.0, 120.0, 120.0])
  println("ARCHIVE_REUSED made down \{down}, up \{up}, down again \{again}")
  // (each made anew as it comes to show, a row a dozen nodes and more: 346, 292 and 326 so, 2026-11-17; taken for
  // others, 64, 13 and 9)
  assert_true(down + up + again < 300, msg="its rows taken for others as they come to show, not made anew: made \{down}, \{up}, \{again}")
}

///|
test "a chat's things on 小屏, sixty files: their rows wheeled away and back are taken for others as they come to show, drawn as made anew, and made no more" {
  new_run()
  let base = @sffixture.fixture("chat")
  let src : Source = {
    ..base,
    topic_read: fn(name, params) {
      let got = base.topic(name, params).get().snapshot()
      guard name == "chatThings" && got.value is Some(Object(v)) else { return got }
      let files = items(got.value, "files")
      let many : Array[Json] = []
      for i in 0..<30 {
        for f in files {
          match f {
            Object(m) => {
              let o = m.copy()
              o["key"] = Json::string(i.to_string() + "/" + text(Some(f), "key"))
              o["seq"] = Json::number((100 - i).to_double())
              many.push(Json::object(o))
            }
            _ => ()
          }
        }
      }
      let changed = v.copy()
      changed["files"] = Json::array(many)
      changed["whole"] = Json::boolean(true)
      { ..got, value: Some(Json::object(changed)) }
    },
  }
  let r : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }
  open_chat(r)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t.run_for(@ui.move_most_ms)
  @sfpages.things_choose(r, "files")
  open_things(src, r, 7.0)
  t.run_for(sheet_way_ms(t))
  // (its rows' words alone, inside the capped sheet's visible scroll viewport above `sheet_panel_foot`: the chat under
  // the sheet and overscan rows clipped behind the 24pt bottom padding are no part of what shows)
  let (down, up, again) = reused_wheeled(t, (195.0, 600.0), (0.0, 0.0), 844.0 - @sf.sheet_panel_foot, fn(w) { w.has_suffix(".log") || w.has_suffix(".pdf") || w.contains(" · ") }, [90.0, 90.0, 90.0, 90.0, 90.0, 90.0, 90.0, 90.0, 90.0, 90.0])
  println("THINGS_REUSED made down \{down}, up \{up}, down again \{again}")
  // (each made anew as it comes to show, a row a dozen nodes and more: 179, 166 and 193 so, 2026-11-17; taken for
  // others, 29, 23 and 14)
  assert_true(down + up + again < 200, msg="its rows taken for others as they come to show, not made anew: made \{down}, \{up}, \{again}")
}
