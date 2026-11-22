// 对话目录's rail on a chat's page made as nodes (sfbase's chat_page_nodes on; sfpages' chat_rail_node): what a person
// meets on a wide page. The long chat of two people (outline_fixture.mbt), the list away from its end at 昨天's 09:40
// (Ana's, seq 22, the reader's). The same actions on every screen, each arranged as is best for it: where the page
// leaves room at the list's right, the rail is there with the page, a tick for each message a person said; a tick
// pressed takes the reader to its message at once, and 回到刚才的位置 back where they were.

///|
/// The long chat away from its end (chat-outline-away) on its page made as nodes, `w` by `h` on a Mac, the core's calls
/// kept by name in `calls`; made, nothing run yet.
fn rail_nodes_tester(w : Double, h : Double, calls : Array[String]) -> @ui.Tester {
  new_run()
  @sf.presenters_reset()
  let base = fixture("chat-outline-away")
  let src : Source = {
    ..base,
    asks_outline: fn() { true },
    call: fn(name, params, done) {
      calls.push(name)
      (base.call)(name, params, done)
    },
  }
  open_fixture_over("chat-outline-away", src)
  @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform=0)
}

///|
/// The rail's press (a button 对话目录 at the list's right, within 20 of the window's `w` wide: not the round button
/// over the way to the newest, at the composer's column's side), where it is.
fn rail_nodes_rails(t : @ui.Tester, w : Double) -> Array[(Double, Double, Double, Double)] {
  outline_buttons(t).filter(fn(b) { b.0 + b.2 >= w - 20.0 })
}

///|
test "对话目录 on a wide page of a chat's page made as nodes: the rail there with the page, at the list's right in its middle, clear of the scroll bar; a tick for each said, the reader's longest in the ink; none where the page leaves it no room" {
  let calls : Array[String] = []
  let t = rail_nodes_tester(1280.0, 800.0, calls)
  // (there as the page is first drawn, a frame in, where it rests: it does not come in after)
  t.run_for(@ui.frame_period_default)
  let first = rail_nodes_rails(t, 1280.0)
  t.run_for(@ui.move_most_ms)
  t.run_for(@ui.move_most_ms)
  let rails = rail_nodes_rails(t, 1280.0)
  assert_eq(rails.length(), 1, msg="\{Repr(outline_buttons(t))}")
  assert_eq(first, rails)
  let (x, y, w, h) = rails[0]
  assert_true(w >= 44.0 && h >= 44.0, msg="\{Repr(rails)}")
  assert_true(x + w <= 1280.0 - @ui.scroll_bar_room + 0.5 && x + w >= 1280.0 - 20.0, msg="\{Repr(rails)}")
  assert_true((y + h / 2.0 - 400.0).abs() < 80.0, msg="\{Repr(rails)}")
  // (the round button over the way to the newest as well, the list being away from its end)
  assert_eq(outline_buttons(t).length(), 2, msg="\{Repr(outline_buttons(t))}")
  // its ticks: the 31 said by people, the reader's (the 16th) longest and in the ink, the rest in one quieter colour
  let ticks = outline_ticks(t, rails[0])
  assert_eq(ticks.length(), 31, msg="\{Repr(ticks)}")
  let ink = outline_hex(@sf.theme().p.text)
  assert_eq(ticks.mapi(fn(i, k) { (i, k) }).filter(fn(k) { k.1.1 == ink }).map(fn(k) { k.0 }), [15], msg="\{Repr(ticks)}")
  assert_eq(ticks[15].0, 20.0)
  assert_true(ticks.iter().all(fn(k) { k.1 == ink || (k.1 == ticks[0].1 && k.0 >= 6.0 && k.0 <= 14.0) }), msg="\{Repr(ticks)}")
  assert_eq(outline_faults(t), [])
  // (nothing asked of the core for it: the outline's index is what it shows)
  assert_eq(calls.filter(fn(c) { c == "chat.bring" || c == "chat.outline.rows" }), [])
  // a 1200 wide window leaves the column no room at its right: no rail, the round button alone
  let t = rail_nodes_tester(1200.0, 800.0, [])
  t.run_for(@ui.move_most_ms)
  assert_eq(rail_nodes_rails(t, 1200.0), [])
  assert_eq(outline_buttons(t).length(), 1)
}

///|
test "对话目录's rail on a chat's page made as nodes: a tick pressed takes the reader to its message, under the bar at once and flashing; 回到刚才的位置 back to where they were; a wheel over the rail scrolls the list" {
  let t = rail_nodes_tester(1280.0, 800.0, [])
  t.run_for(@ui.move_most_ms)
  t.run_for(@ui.move_most_ms)
  let back = fn() { t.semantics().iter().any(fn(s) { s.role == Button && s.label == "回到刚才的位置" }) }
  assert_false(back())
  guard rail_nodes_rails(t, 1280.0) is [(rx, ry, rw, rh)] else { fail("no rail: \{Repr(outline_buttons(t))}") }
  let ticks = outline_drawn(t, "rect").filter(fn(r) {
    r.0 >= rx && r.0 + r.2 <= rx + rw + 0.5 && r.1 >= ry && r.1 + r.3 <= ry + rh + 0.5 && r.3 <= 2.5
  })
  ticks.sort_by(fn(a, b) { a.1.compare(b.1) })
  assert_eq(ticks.length(), 31)
  // (the second tick: Ana's 09:40 the first day, 签名证书下周三过期, far over what shows)
  assert_true(place_within_line(t, said_3) is None)
  t.tap(rx + rw / 2.0, ticks[1].1 + 1.0)
  t.run_for(@ui.frame_period_default)
  guard place_within_line(t, said_3) is Some((at_once, _)) else { fail("not there at once") }
  t.run_for(@ui.move_most_ms)
  t.run_for(@ui.move_most_ms)
  guard place_within_line(t, said_3) is Some((top, foot)) else { fail("not there") }
  assert_eq(at_once, top)
  guard composer_top(t) is Some(under) else { fail("no composer") }
  assert_true(top > 40.0 && top < 300.0 && foot < under, msg="at \{top}…\{foot}, the composer at \{under}")
  assert_true(gone_lit(t, said_3), msg="ts3 flashing")
  // (no outline opened by it)
  assert_true(outline_panel(t) is None)
  assert_true(back())
  // back where the reader was: 22 at the top, nothing flashing anew, the way back gone
  t.click(Button, label="回到刚才的位置")
  t.run_for(@ui.move_most_ms)
  t.run_for(@ui.move_most_ms)
  assert_eq(outline_reading().top_seq, 22.0)
  assert_false(gone_lit(t, said_22), msg="ts22 flashing")
  assert_false(back())
  // a wheel over the rail scrolls the list as anywhere over it
  guard rail_nodes_rails(t, 1280.0) is [(rx, ry, rw, rh)] else { fail("no rail: \{Repr(outline_buttons(t))}") }
  guard place_within_line(t, said_22) is Some((y0, _)) else { fail("22 not drawn") }
  t.wheel(rx + rw / 2.0, ry + rh / 2.0, 60.0)
  t.run_for(@ui.move_most_ms)
  guard place_within_line(t, said_22) is Some((y1, _)) else { fail("22 not drawn after the wheel") }
  assert_true(y1 < y0 - 30.0, msg="\{y0} \{y1}")
}

///|
test "对话目录's rail on a chat's page made as nodes: 0ms hover highlight (none in a day's gap, that day named instead), 180ms hover panel without stealing focus, follow on rail slide, click row to jump, search lock with Escape/outside close, and ⌘G closes hover panel" {
  let calls : Array[String] = []
  let t = rail_nodes_tester(1280.0, 800.0, calls)
  t.run_for(@ui.move_most_ms)
  t.run_for(@ui.move_most_ms)
  assert_eq(calls.filter(fn(c) { c == "chat.bring" || c == "chat.outline.rows" }), [])
  guard rail_nodes_rails(t, 1280.0) is [(rx, ry, rw, rh)] else { fail("no rail") }
  let raw_ticks = fn() {
    let ts = outline_drawn(t, "rect").filter(fn(r) {
      r.0 >= rx && r.0 + r.2 <= rx + rw + 0.5 && r.1 >= ry && r.1 + r.3 <= ry + rh + 0.5 && r.3 <= 2.5
    })
    ts.sort_by(fn(a, b) { a.1.compare(b.1) })
    ts
  }
  let base_ticks = raw_ticks()
  assert_eq(base_ticks.length(), 31)
  let muted = outline_hex(@sf.theme().p.muted)
  // 0ms hover highlight on tick 1
  t.move_to(rx + rw / 2.0, base_ticks[1].1 + 1.0)
  t.draw()
  let hovered = raw_ticks()
  assert_eq(hovered[1].4, muted, msg="tick 1 should highlight Muted immediately")
  assert_true(hovered[1].2 >= 16.0, msg="tick 1 should elongate on hover: \{hovered[1].2}")
  assert_true(outline_panel(t) is None)
  // the day's gap between index 6 and index 7 is that day's, not a tick's: no tick lit, the hover panel not opened there
  // (a tip names the day instead)
  let gap_mid_y = (base_ticks[6].1 + base_ticks[7].1) / 2.0 + 1.0
  t.move_to(rx + rw / 2.0, gap_mid_y)
  t.draw()
  let in_gap = raw_ticks()
  assert_true(in_gap[6].4 != muted && in_gap[7].4 != muted, msg="no tick lit in a day's gap")
  t.run_for(@sf.hover_panel_open_ms + @ui.move_most_ms)
  assert_true(outline_panel(t) is None, msg="hover panel must not open from a day's gap")
  assert_eq(calls.filter(fn(c) { c == "chat.bring" }).length(), 0)
  // onto the day's first tick (index 7): lit at once
  t.move_to(rx + rw / 2.0, base_ticks[7].1 + 1.0)
  t.draw()
  assert_eq(raw_ticks()[7].4, muted, msg="tick 7 should highlight Muted immediately")
  // 180ms hover opens interactive outline panel on the left without stealing focus
  t.run_for(@sf.hover_panel_open_ms + @ui.move_most_ms)
  guard outline_panel(t) is Some((px, py, pw, ph)) else { fail("hover panel did not open") }
  assert_true(px + pw <= rx + 0.5, msg="panel at \{px}+\{pw} should be left of rail \{rx}")
  assert_eq(calls.filter(fn(c) { c == "chat.bring" }).length(), 1)
  let focused_in_panel = match t.focused() {
    Some(s) => s.rect.0 >= px && s.rect.0 + s.rect.2 <= px + pw + 0.5 && s.rect.1 >= py && s.rect.1 <= py + ph
    None => false
  }
  assert_false(focused_in_panel, msg="hover panel must not steal focus")
  assert_eq(outline_faults(t), [])
  // move into hover panel -> stays open, click search input -> locks open on leave, outside tap closes
  t.move_to(px + pw / 2.0, py + ph / 2.0)
  t.run_for(@sf.hover_panel_close_ms + @ui.move_most_ms)
  assert_true(outline_panel(t) is Some(_))
  t.tap_text(@sf.t("web-main.outline.placeholder"))
  t.draw()
  t.move_to(100.0, 100.0)
  t.run_for(@sf.hover_panel_close_ms + @ui.move_most_ms)
  assert_true(outline_panel(t) is Some(_), msg="focused search input holds panel open")
  t.tap(100.0, 100.0)
  t.run_for(@ui.move_most_ms)
  assert_true(outline_panel(t) is None, msg="outside click closes locked hover panel")
  // re-open hover panel, click a row inside it -> jumps to message and closes hover panel
  t.move_to(rx + rw / 2.0, base_ticks[1].1 + 1.0)
  t.run_for(@sf.hover_panel_open_ms + @ui.move_most_ms)
  assert_true(outline_panel(t) is Some(_))
  t.tap_text("签名证书下周三过期，我建议这次发布前就换新证书，不然商店那边会拒…")
  t.run_for(@ui.move_most_ms)
  t.run_for(@ui.move_most_ms)
  assert_true(outline_panel(t) is None)
  assert_true(gone_lit(t, said_3), msg="ts3 flashing after clicking hover panel row")
  // re-open hover panel, then ⌘G -> only 1 Dialog (never two stacked)
  t.move_to(rx + rw / 2.0, base_ticks[1].1 + 1.0)
  t.run_for(@sf.hover_panel_open_ms + @ui.move_most_ms)
  assert_eq(t.semantics().filter(fn(s) { s.role == Dialog && s.label == "对话目录" }).length(), 1)
  t.key(@ui.key_of_char('g'), mods=@ui.mod_cmd)
  t.run_for(@ui.move_most_ms)
  assert_eq(t.semantics().filter(fn(s) { s.role == Dialog && s.label == "对话目录" }).length(), 1)
  t.key(@ui.key_escape)
  t.run_for(@ui.move_most_ms)
  assert_true(outline_panel(t) is None)
  assert_eq(outline_faults(t), [])
}
