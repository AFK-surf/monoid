// A panel of the presenters' beside what opened it (@sf.panel_nodes) on 中屏 and 大屏: what it does held, as it was
// when the panels whose bodies were old views were measured beside it (PANELSAID).

///|
/// A panel's body: words, and a button at its foot that closes it, said into `said`.
fn panel_test_body(said : Array[String]) -> (@view.View, () -> Unit) -> Unit {
  fn(v, close) {
    @sf.words_node(v, fn() { "面板里的话，长一些，好看它怎么折行" }, fn() { @sf.paragraph }) |> ignore
    v.box(fn(f) {
      @sf.style_node(f, @sf.panel_corner_foot)
      @sf.button_node(f, fn() { "好的" }, fn() {
        said.push("ok")
        close()
      }, tone=Primary)
      |> ignore
    })
    |> ignore
  }
}

///|
/// A panel's body: a mark 12 square in 0x23A1DF, then words in 0xB45A29.
fn panel_marked_body() -> (@view.View, () -> Unit) -> Unit {
  fn(v, _) {
    v.box(fn(b) { b.width(Is(Some(12.0))).height(Is(Some(12.0))).ground(Is(0x23A1DFFFL)) |> ignore }) |> ignore
    @sf.words_node(v, fn() { "一起退场" }, fn() { @ui.text_style(color=Data(0xB45A29FFL)) }) |> ignore
  }
}

///|
test "a panel's words, controls and surface fade out together" {
  let t = menu_tester(1280.0, 800.0, 0)
  @sf.panel_nodes("面板", from=At(600.0, 300.0, 0.0, 0.0), fade_out_together=true, panel_marked_body())
  t.run_for(@ui.move_most_ms)
  let original = t.drawn_instances().filter(fn(a) { a.length() > 15 && a[5] == 6.0 && a[0] == 600.0 && a[1] == 306.0 && a[2] > 200.0 })[0]
  t.key(@ui.key_escape)
  let mut previous = 255L
  for _ in 0..<5 {
    t.run_for(@motion.pop_out_ms / 6.0)
    let surface = t.drawn_instances().filter(fn(a) {
      a.length() > 15 && a[5] == 6.0 &&
      (a[0] - original[0]).abs() < 10.0 && (a[1] - original[1]).abs() < 10.0 &&
      a[2] > original[2] * 0.96 && a[3] > original[3] * 0.96
    })
    let mark = t.drawn_rects().filter(fn(r) { r.4 >> 8 == 0x23A1DFL })
    let glyphs = t.drawn_glyphs().filter(fn(g) { g.2 >> 8 == 0xB45A29L })
    assert_eq(surface.length(), 1, msg="the surface remains during its fade")
    assert_eq(mark.length(), 1, msg="the control remains during its fade")
    assert_true(!glyphs.is_empty(), msg="the words remain during their fade")
    let alpha = (surface[0][15] * 255.0).round().to_int64()
    assert_true(alpha > 0L && alpha < previous, msg="the panel fades continuously")
    assert_eq(mark[0].4 & 0xFFL, alpha, msg="the control and surface fade together")
    assert_true(glyphs.iter().all(fn(g) { (g.2 & 0xFFL) == alpha }), msg="the words and surface fade together")
    previous = alpha
  }
  t.run_for(@motion.pop_out_ms)
  assert_false(@sf.presenter_visible())
}

///|
test "a panel closed while opening fades from its current appearance" {
  let t = menu_tester(1280.0, 800.0, 0)
  @sf.panel_nodes("面板", from=At(600.0, 300.0, 0.0, 0.0), fade_out_together=true, panel_marked_body())
  t.run_for(@motion.pop_ms / 2.0)
  let painted = fn() {
    (t.drawn_rects().filter(fn(r) { r.4 >> 8 == 0x23A1DFL }), t.drawn_glyphs().filter(fn(g) { g.2 >> 8 == 0xB45A29L }))
  }
  let before = painted()
  assert_true(!before.0.is_empty() && !before.1.is_empty())
  t.key(@ui.key_escape)
  assert_eq(painted(), before, msg="closing does not change the current appearance")
  t.run_for(@motion.pop_out_ms)
  assert_false(@sf.presenter_visible())
}

///|
/// Where what the panel shows is: its dialog, its title, its words, its button.
fn panel_said(t : @ui.Tester) -> String {
  let r = fn(role : @ui.Role, label : String) { t.query(role, label~).map(fn(s) { s.rect }) }
  let w = fn(s : String) { t.words().filter(fn(x) { x.0 == s }).map(fn(x) { (x.1, x.2, x.3, x.4) }) }
  "dialog \{@ui.some_text(r(Dialog, "面板").map(@ui.rect_text))} title \{@ui.list_text(w("面板").map(@ui.rect_text))} words \{@ui.list_text(w("面板里的话，长一些，好看它怎么折行").map(@ui.rect_text))} button \{@ui.some_text(r(Button, "好的").map(@ui.rect_text))} focus \{@ui.some_text(t.focused().map(fn(s) { "\{s.role} \{s.label}" }))}"
}

///|
test "panel, 大屏 keyboard and mouse: at a point, its title, words and button; the button: said, closed; another, Escape: closed unsaid, its gone told" {
  let said : Array[String] = []
  let t = menu_tester(1280.0, 800.0, 0)
  @sf.panel_nodes("面板", panel_test_body(said), from=At(600.0, 300.0, 0.0, 0.0))
  t.run_for(@ui.move_most_ms)
  println("PANELSAID point \{panel_said(t)}")
  let (x, y, w, h) = t.get(Button, label="好的").rect
  t.tap(x + w / 2.0, y + h / 2.0)
  t.run_for(@ui.move_most_ms)
  let pressed = (said.copy(), @sf.presenting())
  let gone = Ref(0)
  @sf.panel_nodes("面板", panel_test_body(said), from=At(600.0, 300.0, 0.0, 0.0), gone=fn() { gone.val = gone.val + 1 })
  t.run_for(@ui.move_most_ms)
  t.key(@ui.key_escape)
  t.run_for(@ui.move_most_ms)
  assert_eq((pressed, said, @sf.presenting(), gone.val), ((["ok"], false), ["ok"], false, 1))
}

///|
test "panel, 大屏 keyboard and mouse: at a point, a press outside: closed, its gone told" {
  let said : Array[String] = []
  let t = menu_tester(1280.0, 800.0, 0)
  let gone = Ref(0)
  @sf.panel_nodes("面板", panel_test_body(said), from=At(600.0, 300.0, 0.0, 0.0), gone=fn() { gone.val = gone.val + 1 })
  t.run_for(@ui.move_most_ms)
  t.tap(100.0, 700.0)
  t.run_for(@ui.move_most_ms)
  assert_eq((said, @sf.presenting(), gone.val), ([], false, 1))
}

///|
test "panel, 大屏 keyboard and mouse: tall 0.5, fits, at a point; and unanchored, in the middle (measured)" {
  let said : Array[String] = []
  let out = []
  for kind in ["tall", "fits", "middle", "form"] {
    let t = menu_tester(1280.0, 800.0, 0)
    match kind {
      "tall" => @sf.panel_nodes("面板", panel_test_body(said), from=At(600.0, 100.0, 0.0, 0.0), tall=0.5)
      "fits" => @sf.panel_nodes("面板", panel_test_body(said), from=At(600.0, 100.0, 0.0, 0.0), fits=true, w=400.0)
      "middle" => @sf.panel_nodes("面板", panel_test_body(said), from=Unanchored, description="说明的话")
      _ => @sf.panel_nodes("面板", panel_test_body(said), from=At(600.0, 100.0, 0.0, 0.0), form=true)
    }
    t.run_for(@ui.move_most_ms)
    out.push("\{kind}: \{panel_said(t)}")
  }
  println("PANELSAID kinds \{Repr(out)}")
}

///|
/// The panel's state at a moment of its way out: presenting, visible, its dialog where it is said, its words as drawn
/// (alpha), how many times its gone was told, what was said.
fn panel_out_said(t : @ui.Tester, gone : Ref[Int], said : Array[String]) -> String {
  let words = t.words().filter(fn(w) { w.0 == "好的" }).map(fn(w) { w.5 })
  "presenting \{@sf.presenting()} visible \{@sf.presenter_visible()} dialog \{@ui.some_text(t.query(Dialog, label="面板").map(fn(s) { @ui.rect_text(s.rect) }))} button \{@ui.list_text(words)} gone \{gone.val} said \{@ui.list_text(said)}"
}

///|
test "panel, 大屏 keyboard and mouse: its way out, closed by Escape, by a press outside, by its button: at once, midway, at its end (measured)" {
  let out = []
  for how in ["escape", "outside", "button"] {
    let said : Array[String] = []
    let gone = Ref(0)
    let t = menu_tester(1280.0, 800.0, 0)
    @sf.panel_nodes("面板", panel_test_body(said), from=At(600.0, 300.0, 0.0, 0.0), gone=fn() { gone.val = gone.val + 1 })
    t.run_for(@ui.move_most_ms)
    let (bx, by, bw, bh) = t.get(Button, label="好的").rect
    match how {
      "escape" => t.key(@ui.key_escape)
      "outside" => t.tap(100.0, 700.0)
      _ => t.tap(bx + bw / 2.0, by + bh / 2.0)
    }
    let at_once = panel_out_said(t, gone, said)
    t.run_for(@motion.pop_out_ms / 2.0)
    let mid = panel_out_said(t, gone, said)
    // (pressed midway where its button was: what that does)
    t.tap(bx + bw / 2.0, by + bh / 2.0)
    let mid_pressed = panel_out_said(t, gone, said)
    t.run_for(@motion.pop_out_ms)
    let end = panel_out_said(t, gone, said)
    out.push("\{how}: once {\{at_once}} mid {\{mid}} pressed {\{mid_pressed}} end {\{end}}")
  }
  println("PANELSAID out \{Repr(out)}")
}

///|
/// `r` to a tenth.
fn tenth4(r : (Double, Double, Double, Double)) -> (Double, Double, Double, Double) {
  let f = fn(v : Double) { (v * 10.0).round() / 10.0 }
  (f(r.0), f(r.1), f(r.2), f(r.3))
}

///|
test "panel, 大屏 keyboard and mouse: at a point, where it was beside the old one: its dialog, title, words and button" {
  let said : Array[String] = []
  let t = menu_tester(1280.0, 800.0, 0)
  @sf.panel_nodes("面板", panel_test_body(said), from=At(600.0, 300.0, 0.0, 0.0))
  t.run_for(@ui.move_most_ms)
  let w = fn(s : String) { t.words().filter(fn(x) { x.0 == s }).map(fn(x) { tenth4((x.1, x.2, x.3, x.4)) }) }
  debug_inspect(
    (tenth4(t.get(Dialog, label="面板").rect), w("面板"), w("面板里的话，长一些，好看它怎么折行"), tenth4(t.get(Button, label="好的").rect), t.focused().map(fn(s) { s.label })),
    content=(
      #|(
      #|  (600, 306, 296, 98),
      #|  [(622, 318, 252, 20)],
      #|  [(606, 342, 284, 22)],
      #|  (608, 364, 280, 32),
      #|  None,
      #|)

    ),
  )
}

///|
test "panel, 大屏 keyboard and mouse: at a point, its way out as it was beside the old one: closed, presenting no more and out of what is read out at once, drawn till its way out is over, pressed no more; gone told once by Escape, never by its own close" {
  let out = []
  for how in ["escape", "outside", "button"] {
    let said : Array[String] = []
    let gone = Ref(0)
    let t = menu_tester(1280.0, 800.0, 0)
    @sf.panel_nodes("面板", panel_test_body(said), from=At(600.0, 300.0, 0.0, 0.0), gone=fn() { gone.val = gone.val + 1 })
    t.run_for(@ui.move_most_ms)
    let (bx, by, bw, bh) = t.get(Button, label="好的").rect
    match how {
      "escape" => t.key(@ui.key_escape)
      "outside" => t.tap(100.0, 700.0)
      _ => t.tap(bx + bw / 2.0, by + bh / 2.0)
    }
    // (its button's words as they are drawn: there, and how opaque)
    let drawn = fn() { t.words().filter(fn(w) { w.0 == "好的" }).length() }
    let once = (@sf.presenting(), @sf.presenter_visible(), t.query(Dialog, label="面板") is Some(_), gone.val, said.copy(), drawn())
    t.run_for(@motion.pop_out_ms / 2.0)
    let mid = (@sf.presenting(), @sf.presenter_visible(), gone.val, drawn())
    t.tap(bx + bw / 2.0, by + bh / 2.0)
    let pressed = (said.copy(), gone.val)
    t.run_for(@motion.pop_out_ms)
    out.push((once, mid, pressed, (@sf.presenter_visible(), gone.val, drawn())))
  }
  debug_inspect(out, content=(
    #|[
    #|  (
    #|    (false, true, false, 1, [], 1),
    #|    (false, true, 1, 1),
    #|    ([], 1),
    #|    (false, 1, 0),
    #|  ),
    #|  (
    #|    (false, true, false, 1, [], 1),
    #|    (false, true, 1, 1),
    #|    ([], 1),
    #|    (false, 1, 0),
    #|  ),
    #|  (
    #|    (false, true, false, 0, ["ok"], 1),
    #|    (false, true, 0, 1),
    #|    (["ok"], 0),
    #|    (false, 0, 0),
    #|  ),
    #|]
  ))
}

///|
test "panel, 大屏 keyboard and mouse: at a point, drawn by the window's tree, a dialog titled so" {
  let said : Array[String] = []
  let _t = menu_tester(1280.0, 800.0, 0)
  @sf.panel_nodes("面板", panel_test_body(said), from=At(600.0, 300.0, 0.0, 0.0))
  _t.run_for(@ui.move_most_ms)
  assert_true(tree_said(Dialog, "面板") is Some(_))
}

///|
/// What is drawn of the panel open at (600, 306), 280 by 95.8, as it is now: how many of its glyphs are drawn at each
/// final alpha (0-255; the window's under it there at 255 too), its ground's alpha, its button's ground (to a
/// thousandth), the first and last of its glyphs fading (to a thousandth).
fn panel_out_drawn(t : @ui.Tester) -> String {
  let (x, y, w, h) = (600.0, 306.0, 280.0, 95.8)
  let inside = fn(px : Double, py : Double) { px >= x - 1.0 && px <= x + w + 1.0 && py >= y - 1.0 && py <= y + h + 1.0 }
  let f = fn(v : Double) { (v * 1000.0).round() / 1000.0 }
  let glyphs = t.drawn_glyphs().filter(fn(g) { inside(g.0, g.1) })
  let alphas : Map[Int, Int] = Map([])
  for g in glyphs {
    let a = (g.2 & 0xFF).to_int()
    alphas[a] = alphas.get(a).unwrap_or(0) + 1
  }
  let fading = glyphs.filter(fn(g) { (g.2 & 0xFF) != 0xFF }).map(fn(g) { (f(g.0), f(g.1)) })
  let rects = t.drawn_rects().filter(fn(q) { inside(q.0, q.1) })
  let ground = t
    .drawn_instances()
    .filter(fn(a) { a.length() > 15 && a[5] == 6.0 && a[0] == x && a[1] == y && a[15] > 0.0 })
    .map(fn(a) { (a[15] * 255.0).round().to_int() })
  let button = rects.filter(fn(q) { q.0 > 800.0 && q.2 > 40.0 && q.2 < 50.0 }).map(fn(q) { (f(q.0), f(q.1), f(q.2), f(q.3)) })
  "alphas {\{alphas.to_array().map(fn(e) { "\{e.0}: \{e.1}" }).join(", ")}} ground \{@ui.list_text(ground)} button \{@ui.list_text(button.map(@ui.rect_text))} fading \{@ui.some_text(fading.get(0).map(fn(p) { "(\{p.0}, \{p.1})" }))}..\{@ui.some_text(fading.last().map(fn(p) { "(\{p.0}, \{p.1})" }))}"
}

///|
test "panel, 大屏 keyboard and mouse: at a point, its way out drawn as it was beside the old one, closed by Escape, by a press outside, by its button: its words fading before its ground, shrunk into where it opened from, at once, a quarter, midway, three quarters and at its end" {
  let out = []
  for how in ["escape", "outside", "button"] {
    let said : Array[String] = []
    let t = menu_tester(1280.0, 800.0, 0)
    @sf.panel_nodes("面板", panel_test_body(said), from=At(600.0, 300.0, 0.0, 0.0))
    t.run_for(@ui.move_most_ms)
    let (bx, by, bw, bh) = t.get(Button, label="好的").rect
    match how {
      "escape" => t.key(@ui.key_escape)
      "outside" => t.tap(100.0, 700.0)
      _ => t.tap(bx + bw / 2.0, by + bh / 2.0)
    }
    let seen = [panel_out_drawn(t)]
    for _ in 0..<4 {
      t.run_for(@motion.pop_out_ms / 4.0)
      seen.push(panel_out_drawn(t))
    }
    out.push(seen)
  }
  // (each way the same)
  assert_eq(out[1], out[0])
  assert_eq(out[2], out[0])
  // (360 wide, its farthest edge kept within @sf's pop_max_shift, 8, as it shrinks: View::scale's max_shift)
  debug_inspect(out[0], content=(
    #|[
    #|  "alphas {255: 21} ground [255] button [] fading None..None",
    #|  "alphas {222: 21} ground [222] button [] fading Some((621.923, 320.948))..Some((747.483, 372.766))",
    #|  "alphas {128: 21} ground [128] button [] fading Some((621.703, 320.797))..Some((746, 372.095))",
    #|  "alphas {33: 21} ground [33] button [] fading Some((621.482, 320.647))..Some((744.517, 371.423))",
    #|  "alphas {} ground [] button [] fading None..None",
    #|]


  ))
}

///|
/// Where the keyboard's focus is and what the host is told of it: what has the focus (its role and label), the field
/// the host is told of (active, its text, its selection).
fn panel_focus_said(t : @ui.Tester) -> String {
  let ime = t.ime()
  "focused \{@ui.some_text(t.focused().map(fn(s) { "\{s.role} \{s.label}" }))} ime (\{ime.0}, \{ime.1}, \{ime.2}, \{ime.3})"
}

///|
test "panel, 大屏 keyboard and mouse: at a point, the focus as it opens (focus, not focus, its field given it), typed into, closed by Escape, typed into again: as it was beside the old one" {
  let out = []
  for how in ["focus", "not focus", "field"] {
    let said : Array[String] = []
    let t = menu_tester(1280.0, 800.0, 0)
    let before = panel_focus_said(t)
    let pf = @ui.Field::new()
    let body = fn(v : @view.View, close : () -> Unit) {
      if how == "field" {
        // (its field given the focus as it opens where it is not a sheet: panel_search_at_hand_node)
        @sf.panel_search_at_hand_node(@sf.input_node(v, pf, placeholder="填一下", label="填一下"))
      }
      panel_test_body(said)(v, close)
    }
    match how {
      "not focus" => @sf.panel_nodes("面板", body, from=At(600.0, 300.0, 0.0, 0.0), focus=false)
      _ => @sf.panel_nodes("面板", body, from=At(600.0, 300.0, 0.0, 0.0))
    }
    t.run_for(@ui.move_most_ms)
    let open = panel_focus_said(t)
    t.type_text("甲")
    t.run_for(@ui.move_most_ms)
    let typed = "\{panel_focus_said(t)} panel field \{pf.text()}"
    t.key(@ui.key_escape)
    t.run_for(@ui.move_most_ms)
    let closed = panel_focus_said(t)
    t.type_text("乙")
    t.run_for(@ui.move_most_ms)
    let typed_after = "\{panel_focus_said(t)} panel field \{pf.text()} presenting \{@sf.presenting()}"
    out.push("\{how}: before {\{before}} open {\{open}} typed {\{typed}} closed {\{closed}} typed after {\{typed_after}}")
  }
  for o in out {
    println("PANELFOCUS \{o}")
  }
  debug_inspect(out, content=(
    #|[
    #|  "focus: before {focused Some(TextField 发消息) ime (true, , 0, 0)} open {focused None ime (false, , 0, 0)} typed {focused None ime (false, , 0, 0) panel field } closed {focused Some(TextField 发消息) ime (true, , 0, 0)} typed after {focused Some(TextField 发消息) ime (true, 乙, 1, 1) panel field  presenting false}",
    #|  "not focus: before {focused Some(TextField 发消息) ime (true, , 0, 0)} open {focused Some(TextField 发消息) ime (true, , 0, 0)} typed {focused Some(TextField 发消息) ime (true, 甲, 1, 1) panel field } closed {focused Some(TextField 发消息) ime (true, 甲, 1, 1)} typed after {focused Some(TextField 发消息) ime (true, 甲乙, 2, 2) panel field  presenting false}",
    #|  "field: before {focused Some(TextField 发消息) ime (true, , 0, 0)} open {focused Some(TextField 填一下) ime (true, , 0, 0)} typed {focused Some(TextField 填一下) ime (true, 甲, 1, 1) panel field 甲} closed {focused Some(TextField 发消息) ime (true, , 0, 0)} typed after {focused Some(TextField 发消息) ime (true, 乙, 1, 1) panel field 甲 presenting false}",
    #|]
  ))
}

///|
test "panel, 大屏 keyboard and mouse: at a point, its way in and its way out after Escape painted alone: what it holds not built again, its words fading in and out as they do, gone at its end" {
  let said : Array[String] = []
  let t = menu_tester(1280.0, 800.0, 0)
  let built = Ref(0)
  let body = fn(v : @view.View, close : () -> Unit) {
    built.val = built.val + 1
    panel_test_body(said)(v, close)
  }
  // (its words' alpha as drawn: the panel's own glyphs (where it is open, but those of the window's under it there,
  // drawn whole), how many of them and theirs (-1: none fading, -2: not all as faded))
  let words = fn() {
    let (x, y, w, h) = (600.0, 306.0, 280.0, 95.8)
    let mine = t
      .drawn_glyphs()
      .filter(fn(g) { g.0 >= x - 1.0 && g.0 <= x + w + 1.0 && g.1 >= y - 1.0 && g.1 <= y + h + 1.0 })
    (mine.length(), mine.filter(fn(g) { (g.2 & 0xFF) != 0xFF }).map(fn(g) { (g.2 & 0xFF).to_int() }).fold(init=-1, fn(a, b) { if a < 0 || a == b { b } else { -2 } }))
  }
  // (the frames a host draws till `until`, each at the moment the app asks for it, however late (none once it asks for
  // none): what each was built for, its words as drawn and when)
  let frames_till = fn(until : Double) {
    let out = []
    while true {
      let w = t.wanted_after()
      if w == @double.infinity {
        break
      }
      let at = if w <= t.time() { t.next_frame_time() } else { t.display_frame(w) }
      if at > until {
        break
      }
      t.frame_at(at)
      out.push((t.time(), t.built_why() != "", words()))
    }
    out
  }
  // (each frame built as a host builds it: none of the looks alone drawn whole after it as well, Tester::check_looks;
  // this test's alone)
  t.check_looks(false)
  let bg = words().0
  let open_n = bg + 21
  let open_at = t.time()
  @sf.panel_nodes("面板", body, from=At(600.0, 300.0, 0.0, 0.0))
  // (the frame it opens in, and those after it of its own: then its way in, the clock alone, past its end)
  t.frames_owed()
  let opened = built.val
  let way_in = frames_till(open_at + @motion.pop_ms + 2.0 * t.frame_period())
  let after_in = built.val
  let close_at = t.time()
  t.key(@ui.key_escape)
  t.frames_owed()
  let closed = built.val
  let way_out = frames_till(close_at + @motion.pop_out_ms + 2.0 * t.frame_period())
  println("PANELBUILT in \{Repr(way_in)} out \{Repr(way_out)}")
  let alphas = fn(frames : Array[(Double, Bool, (Int, Int))]) { frames.map(fn(f) { f.2 }) }
  // (its way in: some frame of it drawn part way, its words whole by its end)
  let part_in = alphas(way_in).iter().any(fn(w) { w.0 == open_n && w.1 > 0 && w.1 < 255 })
  let whole_in = way_in.last().map(fn(f) { f.2 }) == Some((open_n, -1))
  // (its way out: its words no more opaque frame by frame, some frame part way, then gone, from the first frame at or
  // after its end, and gone thereafter)
  let out_a = alphas(way_out)
  let part_out = out_a.iter().any(fn(w) { w.0 == open_n && w.1 > 0 && w.1 < 255 })
  let fading = out_a.filter(fn(w) { w.0 == open_n }).map(fn(w) { if w.1 < 0 { 255 } else { w.1 } })
  let mut falls = true
  for i in 1..<fading.length() {
    falls = falls && fading[i] <= fading[i - 1]
  }
  let gone_from = out_a.search((bg, -1)).unwrap_or(out_a.length())
  let gone_at = way_out.get(gone_from).map(fn(f) { f.0 - close_at })
  let gone_stays = out_a.iter().drop(gone_from).all(fn(w) { w == (bg, -1) })
  // (its words fade out together with its liquid glass over pop_out_ms (glass_pop_out), the frame at or
  // after that the first they are gone in)
  let in_time = match gone_at {
    // (to a thousandth of a frame: the moments are sums of frame periods)
    Some(ms) => ms >= @motion.pop_out_ms && ms <= @motion.pop_out_ms + t.frame_period() + 0.001
    None => false
  }
  // (what is built meanwhile, the page under it as what it reads says (its own motions), built none of it)
  assert_eq(
    (after_in - opened, built.val - closed, part_in, whole_in, part_out, falls, gone_stays, in_time),
    (0, 0, true, true, true, true, true, true),
    msg="in \{Repr(way_in)}; out \{Repr(way_out)}",
  )
}

///|
test "panel, 大屏 keyboard and mouse: at a point, back (the system's): closed as by Escape, gone told once, out of what is read out at once, the focus back as it goes: as it was beside the old one" {
  let out = []
  for focus in [true, false] {
    let said : Array[String] = []
    let gone = Ref(0)
    let t = menu_tester(1280.0, 800.0, 0)
    @sf.panel_nodes("面板", panel_test_body(said), from=At(600.0, 300.0, 0.0, 0.0), focus~, gone=fn() { gone.val = gone.val + 1 })
    t.run_for(@ui.move_most_ms)
    t.back()
    let once = "\{panel_out_said(t, gone, said)} \{panel_focus_said(t)}"
    t.run_for(@ui.move_most_ms)
    out.push("focus \{focus}: once {\{once}} end {\{panel_out_said(t, gone, said)} \{panel_focus_said(t)}}")
  }
  debug_inspect(out, content=(
    #|[
    #|  "focus true: once {presenting false visible true dialog None button [1] gone 1 said [] focused Some(TextField 发消息) ime (true, , 0, 0)} end {presenting false visible false dialog None button [] gone 1 said [] focused Some(TextField 发消息) ime (true, , 0, 0)}",
    #|  "focus false: once {presenting false visible true dialog None button [1] gone 1 said [] focused Some(TextField 发消息) ime (true, , 0, 0)} end {presenting false visible false dialog None button [] gone 1 said [] focused Some(TextField 发消息) ime (true, , 0, 0)}",
    #|]

  ))
}

///|
/// A panel's body of `n` rows of words, a button under them.
fn panel_rows_body(n : Int) -> (@view.View, () -> Unit) -> Unit {
  fn(v, close) {
    for i in 0..<n {
      @sf.words_node(v, fn() { "第\{i}行" }, fn() { @sf.paragraph }) |> ignore
    }
    @sf.button_node(v, fn() { "好的" }, close, tone=Primary) |> ignore
  }
}

///|
test "panel, 大屏 keyboard and mouse: at a point, held short of what it holds by the window: what scrolls (out to its sides), where, how far" {
  let t = menu_tester(1280.0, 500.0, 0)
  @sf.panel_nodes("面板", panel_rows_body(40), from=At(600.0, 100.0, 0.0, 0.0))
  t.run_for(@ui.move_most_ms)
  let w = fn(s : String) { t.words().filter(fn(x) { x.0 == s }).map(fn(x) { tenth4((x.1, x.2, x.3, x.4)) }) }
  let at = fn() { "title \{@ui.list_text(w("面板").map(@ui.rect_text))} row0 \{@ui.list_text(w("第0行").map(@ui.rect_text))} row10 \{@ui.list_text(w("第10行").map(@ui.rect_text))} button \{@ui.some_text(t.query(Button, label="好的").map(fn(s) { @ui.rect_text(tenth4(s.rect)) }))}" }
  let (dx, dy, dw, dh) = t.get(Dialog, label="面板").rect
  let first = "dialog \{@ui.rect_text(tenth4((dx, dy, dw, dh)))} \{at()}"
  // (the wheel over its middle, then over its padding at its left side, then at its foot under its words)
  t.wheel(dx + dw / 2.0, dy + dh / 2.0, 120.0)
  t.run_for(@ui.move_most_ms)
  let middle = at()
  t.wheel(dx + 4.0, dy + dh / 2.0, 120.0)
  t.run_for(@ui.move_most_ms)
  let side = at()
  t.wheel(dx + dw / 2.0, dy + 6.0, 120.0)
  t.run_for(@ui.move_most_ms)
  let top = at()
  let said = "\{first} || wheel middle \{middle} || wheel side \{side} || wheel top padding \{top}"
  inspect(said, content=(
    #|dialog (600, 8, 296, 484) title [(622, 20, 252, 20)] row0 [(606, 44, 284, 22)] row10 [(606, 264, 284, 22)] button Some((606, 924, 284, 32)) || wheel middle title [(622, 20, 252, 20)] row0 [(606, -76, 284, 22)] row10 [(606, 144, 284, 22)] button Some((606, 804, 284, 32)) || wheel side title [(622, 20, 252, 20)] row0 [(606, -196, 284, 22)] row10 [(606, 24, 284, 22)] button Some((606, 684, 284, 32)) || wheel top padding title [(622, 20, 252, 20)] row0 [(606, -196, 284, 22)] row10 [(606, 24, 284, 22)] button Some((606, 684, 284, 32))

  ))
}

///|
/// A panel's body: a column of its own (capped_node, 360 at most) of `rows()` rows of words.
fn panel_column_body(rows : @signals.Signal[Int]) -> (@view.View, () -> Unit) -> Unit {
  fn(v, _close) {
    @sf.capped_node(v, fn() { 360.0 }, fn(s) {
      s.each(fn() { Array::makei(rows.get(), fn(i) { i }) }, fn(i) { i }, fn(r, i) {
        @sf.words_node(r, fn() { "第\{i.untracked()}行" }, fn() { @sf.paragraph }) |> ignore
      })
    })
    |> ignore
  }
}

///|
test "panel, 大屏 keyboard and mouse: at a point, a column of its own in it: in a tall window, in a short one then grown, its rows from many to few: where it is, what the wheel scrolls: as it was beside the old one" {
  let w = fn(t : @ui.Tester, s : String) { t.words().filter(fn(x) { x.0 == s }).map(fn(x) { tenth4((x.1, x.2, x.3, x.4)) }) }
  // (where it is, then the wheel over its middle and where its rows are after)
  let said = fn(t : @ui.Tester) {
    let d = t.query(Dialog, label="面板").unwrap().rect
    let before = "dialog \{@ui.rect_text(tenth4(d))} row0 \{@ui.list_text(w(t, "第0行").map(@ui.rect_text))} row4 \{@ui.list_text(w(t, "第4行").map(@ui.rect_text))}"
    t.wheel(d.0 + d.2 / 2.0, d.1 + d.3 / 2.0, 120.0)
    t.run_for(@ui.move_most_ms)
    let after = "row0 \{@ui.list_text(w(t, "第0行").map(@ui.rect_text))} row4 \{@ui.list_text(w(t, "第4行").map(@ui.rect_text))}"
    // (and back where it was)
    t.wheel(d.0 + d.2 / 2.0, d.1 + d.3 / 2.0, -240.0)
    t.run_for(@ui.move_most_ms)
    "\{before} | wheel: \{after}"
  }
  let out = []
  // (a tall window, 30 rows)
  let rows = @signals.signal(30)
  let t = menu_tester(1280.0, 800.0, 0)
  @sf.panel_nodes("面板", panel_column_body(rows), from=At(600.0, 100.0, 0.0, 0.0))
  t.run_for(@ui.move_most_ms)
  out.push("tall: \{said(t)}")
  // (its rows from 30 to 4)
  rows.set(4)
  t.run_for(@ui.move_most_ms)
  out.push("tall, 4 rows: \{said(t)}")
  // (a short window, 30 rows; then grown)
  let rows2 = @signals.signal(30)
  let t2 = menu_tester(1280.0, 300.0, 0)
  @sf.panel_nodes("面板", panel_column_body(rows2), from=At(600.0, 100.0, 0.0, 0.0))
  t2.run_for(@ui.move_most_ms)
  out.push("short: \{said(t2)}")
  t2.resize(1280.0, 800.0)
  t2.run_for(@ui.move_most_ms)
  out.push("short, grown: \{said(t2)}")
  rows2.set(4)
  t2.run_for(@ui.move_most_ms)
  out.push("short, grown, 4 rows: \{said(t2)}")
  for o in out {
    println("PANELCOLUMN \{o}")
  }
  debug_inspect(out, content=(
    #|[
    #|  "tall: dialog (600, 106, 296, 402) row0 [(606, 142, 284, 22)] row4 [(606, 230, 284, 22)] | wheel: row0 [(606, 22, 284, 22)] row4 [(606, 110, 284, 22)]",
    #|  "tall, 4 rows: dialog (600, 106, 296, 130) row0 [(606, 142, 284, 22)] row4 [] | wheel: row0 [(606, 142, 284, 22)] row4 []",
    #|  "short: dialog (600, 8, 296, 284) row0 [(606, 44, 284, 22)] row4 [(606, 132, 284, 22)] | wheel: row0 [(606, -76, 284, 22)] row4 [(606, 12, 284, 22)]",
    #|  "short, grown: dialog (600, 106, 296, 402) row0 [(606, 142, 284, 22)] row4 [(606, 230, 284, 22)] | wheel: row0 [(606, 22, 284, 22)] row4 [(606, 110, 284, 22)]",
    #|  "short, grown, 4 rows: dialog (600, 106, 296, 130) row0 [(606, 142, 284, 22)] row4 [] | wheel: row0 [(606, 142, 284, 22)] row4 []",
    #|]
  ))
}

///|
test "panel, 大屏 keyboard and mouse: tall 0.5, at a point high and low in the window, its body a column that fills it and its rows: where it is, how tall, what the wheel scrolls: as it was beside the old one" {
  let out = []
  for at in [100.0, 500.0, 700.0] {
    let rows = @signals.signal(40)
    let t = menu_tester(1280.0, 800.0, 0)
    @sf.panel_nodes("面板", panel_column_body(rows), from=At(600.0, at, 0.0, 0.0), tall=0.5)
    t.run_for(@ui.move_most_ms)
    let w = fn(s : String) { t.words().filter(fn(x) { x.0 == s }).map(fn(x) { tenth4((x.1, x.2, x.3, x.4)) }) }
    let d = t.query(Dialog, label="面板").map(fn(s) { tenth4(s.rect) })
    let before = "dialog \{@ui.some_text(d.map(@ui.rect_text))} row0 \{@ui.list_text(w("第0行").map(@ui.rect_text))}"
    match d {
      Some((x, y, dw, dh)) => t.wheel(x + dw / 2.0, y + dh / 2.0, 120.0)
      None => ()
    }
    t.run_for(@ui.move_most_ms)
    out.push("at \{at}: \{before} | wheel: row0 \{@ui.list_text(w("第0行").map(@ui.rect_text))}")
  }
  for o in out {
    println("PANELTALL \{o}")
  }
  debug_inspect(out, content=(
    #|[
    #|  "at 100: dialog Some((600, 106, 296, 400)) row0 [(606, 142, 284, 22)] | wheel: row0 [(606, 22, 284, 22)]",
    #|  "at 500: dialog Some((600, 94, 296, 400)) row0 [(606, 130, 284, 22)] | wheel: row0 [(606, 10, 284, 22)]",
    #|  "at 700: dialog Some((600, 294, 296, 400)) row0 [(606, 330, 284, 22)] | wheel: row0 [(606, 210, 284, 22)]",
    #|]
  ))
}

///|
test "panel, 大屏 keyboard and mouse: tall 0.5, at a point: its title, words and button where they were beside the old one, drawn by the window's tree" {
  let said : Array[String] = []
  let t = menu_tester(1280.0, 800.0, 0)
  @sf.panel_nodes("面板", panel_test_body(said), from=At(600.0, 100.0, 0.0, 0.0), tall=0.5)
  t.run_for(@ui.move_most_ms)
  assert_true(tree_said(Dialog, "面板") is Some(_))
  inspect(panel_said(t), content=(
    #|dialog Some((600, 106, 296, 400)) title [(622, 118, 252, 20)] words [(606, 142, 284, 22)] button Some((608, 164, 280, 32)) focus None

  ))
}

///|
test "panel, 大屏 keyboard and mouse: tall 0.5 with a foot of its own, its body a column: opened, the window made shorter and taller again, and opened at that height: where its body and foot are, what the wheel scrolls: as it was beside the old one" {
  let w = fn(t : @ui.Tester, s : String) { t.words().filter(fn(x) { x.0 == s }).map(fn(x) { tenth4((x.1, x.2, x.3, x.4)) }) }
  let said = fn(t : @ui.Tester) {
    let d = t.query(Dialog, label="面板").unwrap().rect
    let foot = t.query(Button, label="好的").map(fn(s) { tenth4(s.rect) })
    let before = "dialog \{@ui.rect_text(tenth4(d))} row0 \{@ui.list_text(w(t, "第0行").map(@ui.rect_text))} foot \{@ui.some_text(foot.map(@ui.rect_text))}"
    // (the wheel over the middle of what it holds)
    t.wheel(d.0 + d.2 / 2.0, d.1 + 120.0, 120.0)
    t.run_for(@ui.move_most_ms)
    let after = "row0 \{@ui.list_text(w(t, "第0行").map(@ui.rect_text))}"
    t.wheel(d.0 + d.2 / 2.0, d.1 + 120.0, -240.0)
    t.run_for(@ui.move_most_ms)
    "\{before} | wheel: \{after}"
  }
  let open = fn() {
    let rows = @signals.signal(40)
    @sf.panel_nodes(
      "面板",
      panel_column_body(rows),
      from=At(600.0, 100.0, 0.0, 0.0),
      tall=0.5,
      foot=fn(v, close) { @sf.button_node(v, fn() { "好的" }, close, tone=Primary) |> ignore },
    )
  }
  let out = []
  let t = menu_tester(1280.0, 800.0, 0)
  open()
  t.run_for(@ui.move_most_ms)
  out.push("800: \{said(t)}")
  t.resize(1280.0, 500.0)
  t.run_for(@ui.move_most_ms)
  out.push("800 to 500: \{said(t)}")
  t.resize(1280.0, 800.0)
  t.run_for(@ui.move_most_ms)
  out.push("500 to 800: \{said(t)}")
  let t2 = menu_tester(1280.0, 500.0, 0)
  open()
  t2.run_for(@ui.move_most_ms)
  out.push("opened at 500: \{said(t2)}")
  for o in out {
    println("PANELTALLFOOT \{o}")
  }
  debug_inspect(out, content=(
    #|[
    #|  "800: dialog (600, 106, 296, 400) row0 [(606, 142, 284, 22)] foot Some((834, 466, 54, 32)) | wheel: row0 [(606, 22, 284, 22)]",
    #|  "800 to 500: dialog (600, 106, 296, 250) row0 [(606, 142, 284, 22)] foot Some((834, 316, 54, 32)) | wheel: row0 [(606, 22, 284, 22)]",
    #|  "500 to 800: dialog (600, 106, 296, 400) row0 [(606, 142, 284, 22)] foot Some((834, 466, 54, 32)) | wheel: row0 [(606, 22, 284, 22)]",
    #|  "opened at 500: dialog (600, 106, 296, 250) row0 [(606, 142, 284, 22)] foot Some((834, 316, 54, 32)) | wheel: row0 [(606, 22, 284, 22)]",
    #|]

  ))
}

///|
/// A panel's body: the words `words` says.
fn fits_words_body(words : @signals.Signal[String]) -> (@view.View, () -> Unit) -> Unit {
  fn(v, _) { @sf.words_node(v, fn() { words.get() }, fn() { @sf.paragraph }) |> ignore }
}

///|
/// A button `label` of a panel's as the window shows it: where it is, how much of its ground the clips' rects it is drawn
/// in leave (x0, y0, x1, y1: its own, scene.mbt 16-19, and the rounded one outside it, 40-43; their round corners not:
/// the corner rule's), and whether presses just inside its capsule by its edges are its own (`pressed` told so): 0.5 in
/// from its right end and from its foot, each at its middle (`top`: from its top instead of its foot).
fn panel_reach_said(t : @ui.Tester, label : String, pressed : Ref[Int], top? : Bool = false) -> String raise {
  let (x, y, w, h) = t.get(Button, label~).rect
  let shown = t
    .drawn_instances()
    .filter(fn(d) { d[5] == 0.0 && (d[0] - x).abs() < 0.01 && (d[1] - y).abs() < 0.01 && (d[2] - w).abs() < 0.01 && (d[3] - h).abs() < 0.01 })
    .map(fn(d) {
      let outer = d[44] > 0.0 || d[45] > 0.0 || d[46] > 0.0 || d[47] > 0.0
      let (x0, y0) = (dmax(x, dmax(d[16], if outer { d[40] } else { x })), dmax(y, dmax(d[17], if outer { d[41] } else { y })))
      let (x1, y1) = (dmin(x + w, dmin(d[18], if outer { d[42] } else { x + w })), dmin(y + h, dmin(d[19], if outer { d[43] } else { y + h })))
      tenth4((x0, y0, x1, y1))
    })
  let points = [(x + w - 0.5, y + h / 2.0), (x + w / 2.0, if top { y + 0.5 } else { y + h - 0.5 })]
  let presses = []
  for q in points {
    let was = pressed.val
    t.tap(q.0, q.1)
    t.run_for(@ui.move_most_ms)
    presses.push(pressed.val - was)
  }
  "\{@ui.rect_text(tenth4((x, y, w, h)))} shows \{@ui.list_text(shown.map(@ui.rect_text))} pressed \{@ui.list_text(presses)}"
}

///|
test "panel, 大屏 keyboard and mouse: tall 0.5 and not, a foot's button in its foot corner: drawn whole where they reach into the panel's padding, pressed there: as it was beside the old one" {
  let out = []
  for kind in ["tall foot", "foot"] {
    let t = menu_tester(1280.0, 800.0, 0)
    let pressed = Ref(0)
    let foot = fn(v : @view.View, _close : () -> Unit) {
      @sf.button_node(v, fn() { "好的" }, fn() { pressed.val = pressed.val + 1 }, tone=Primary) |> ignore
    }
    match kind {
      "tall foot" =>
        @sf.panel_nodes("面板", panel_column_body(@signals.signal(40)), from=At(600.0, 100.0, 0.0, 0.0), tall=0.5, foot~)
      _ => @sf.panel_nodes("面板", fits_words_body(@signals.signal("面板里的话")), from=At(600.0, 100.0, 0.0, 0.0), foot~)
    }
    t.run_for(@ui.move_most_ms)
    out.push("\{kind}: \{panel_reach_said(t, "好的", pressed)}")
  }
  debug_inspect(out, content=(
    #|[
    #|  "tall foot: (834, 466, 54, 32) shows [(834, 466, 888, 498)] pressed [1, 1]",
    #|  "foot: (834, 172, 54, 32) shows [(834, 172, 888, 204)] pressed [1, 1]",
    #|]

  ))
}

///|
test "panel, 大屏 keyboard and mouse: at a point, whether it stands above what opened it: under it, flipped over it for want of room below, said to go over it" {
  let out = []
  for (y, side) in [(100.0, @ui.Side::Bottom), (780.0, @ui.Side::Bottom), (400.0, @ui.Side::Top)] {
    let t = menu_tester(1280.0, 800.0, 0)
    @sf.panel_nodes("面板", fits_words_body(@signals.signal("面板里的话")), from=At(600.0, y, 0.0, 0.0), side~)
    t.run_for(@ui.move_most_ms)
    out.push((y, t.get(Dialog, label="面板").rect.1 < y))
  }
  assert_eq(out, [(100.0, false), (780.0, true), (400.0, true)])
}

///|
test "panel, 大屏 keyboard and mouse: at a point, open as the window is made too short for it below what opened it and tall again: above it the frame it goes there, and there it stays as the window is tall again (it has the room where it is: no side changed without need)" {
  let t = menu_tester(1280.0, 800.0, 0)
  @sf.panel_nodes("面板", fits_words_body(@signals.signal("面板里的话")), from=At(600.0, 500.0, 0.0, 0.0))
  t.run_for(@ui.move_most_ms)
  let out = []
  let said = fn(t : @ui.Tester, h : Double) { (h, t.query(Dialog, label="面板").map(fn(s) { s.rect.1 < 500.0 })) }
  out.push(said(t, 800.0))
  for h in [560.0, 800.0] {
    // (the frame it is drawn at that height, then once it is at rest)
    t.resize(1280.0, h)
    out.push(said(t, h))
    t.run_for(@ui.move_most_ms)
    out.push(said(t, h))
  }
  // (above from the frame the window is too short below; above still as it is tall again: View::beside's holds_side)
  assert_eq(out, [(800.0, Some(false)), (560.0, Some(true)), (560.0, Some(true)), (800.0, Some(true)), (800.0, Some(true))])
}
