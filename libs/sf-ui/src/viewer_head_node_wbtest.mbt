// The floating bar of a file opened in the Small tier as nodes (viewer_head_node), alone in a window: drawn (its glass,
// its name cut short, its tools, ×) within the window; what it says changed once made (its name, another tool) drawn
// anew; never narrower once open; there and gone as it is awake, from where it is at that moment.

///|
/// What a head shows (head_tester's): the file's name, which tools it has (by their icons, × after them).
struct HeadState {
  name : @signals.Signal[String]
  tools : @signals.Signal[Array[String]]
  awake : @signals.Signal[Bool]
  closed : Ref[Int]
}

///|
fn HeadState::new(name : String, tools : Array[String]) -> HeadState {
  {
    name: @signals.signal(name, same=fn(a, b) { a == b }),
    tools: @signals.signal(tools, same=fn(a, b) { a == b }),
    awake: @signals.signal(true, same=fn(a, b) { a == b }),
    closed: Ref(0),
  }
}

///|
/// The tool `icon`'s words (its label, read out).
fn head_label(icon : String) -> String {
  "tool " + icon
}

///|
/// A window `w` wide with the head as nodes in it, saying what `s` says.
fn head_tester(s : HeadState, w? : Double = 390.0) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w~, h=300.0, platform=0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    viewer_head_node(
        root,
        fn() { s.name.get() },
        fn() { "" },
        fn() { s.awake.get() },
        fn(_) { 1.0 },
        fn() { (viewer_host().room)().0 },
        fn() { w },
        fn() { page_viewer_ink() },
        fn() { viewer_page_glass() },
        fn(row) {
          // (each it can have in its place, there while said)
          for icon in head_icons {
            row.show(fn() { s.tools.get().contains(icon) }, fn(r) {
              tool_node(r, fn() { { icon, label: head_label(icon), on: false, disabled: false } }, fn() { page_viewer_ink() }, Is(tool_side / 2.0), fn() {  })
              |> ignore
            })
          }
        },
        fn() { s.tools.get().join(",") },
        fn() { s.closed.val += 1 },
      )
      |> ignore
  })
  t.draw()
  t
}

///|
/// What the head draws (all of the window but its foot), and where its × is read out.
fn head_drawn(tt : @ui.Tester) -> (Array[String], (Double, Double, Double, Double)) raise {
  let x = tt.get(Button, label=t("web-main.preview.closeKey"))
  // (its numbers to a millionth: the same fade worked out by another way ending a last digit apart)
  let even = fn(line : String) {
    line
    .split(" ")
    .map(fn(v) {
      match number_of(v.to_owned()) {
        Some(d) => ((d * 1000000.0).round() / 1000000.0).to_string()
        None => v.to_owned()
      }
    })
    .collect()
    .join(" ")
  }
  (drawn_within(tt, (0.0, 0.0, tt.ctx().width, 120.0)).map(even), x.rect)
}

///|
/// The tools a head_tester's head can have, in their order.
let head_icons : Array[String] = ["edit", "copy", "check", "download"]

///|
/// A head as nodes in a window of its own, made as `s` says and taken through `steps`
/// (each a change to what it says and how long to go on after it; less than none, no frame after it), what it draws and where its × is after each:
/// one window at a time (a Tester's globals its own), all of what was seen kept before another is made.
fn head_run(
  name : String,
  tools : Array[String],
  steps : Array[(String, (HeadState) -> Unit, Double)],
  w? : Double = 390.0,
) -> Array[(String, Array[String], (Double, Double, Double, Double))] raise {
  let s = HeadState::new(name, tools)
  let t = head_tester(s, w~)
  let out = []
  let (d, x) = head_drawn(t)
  out.push(("made", d, x))
  for st in steps {
    let (what, change, ms) = st
    change(s)
    // (less than none: no frame drawn after it, what it read of it seen by what follows only)
    if ms < 0.0 {
      continue
    }
    if ms > 0.0 {
      t.run_for(ms)
    } else {
      t.draw()
      t.draw()
    }
    let (d, x) = head_drawn(t)
    out.push((what, d, x))
  }
  out
}

///|
/// The node's run, each step's head drawn and its × within the window (390 wide), what it draws after a change not
/// what it drew before it.
fn head_seen(name : String, tools : Array[String], steps : Array[(String, (HeadState) -> Unit, Double)]) -> Array[(String, Array[String], (Double, Double, Double, Double))] raise {
  let new = head_run(name, tools, steps)
  for i, n in new {
    assert_true(!n.1.is_empty(), msg="\{n.0}: drawn")
    let (x, _, w, _) = n.2
    assert_true(x >= 0.0 && x + w <= 390.0, msg="\{n.0}: its × within the window: \{Repr(n.2)}")
    if i > 0 {
      assert_true(n.1 != new[i - 1].1, msg="\{n.0}: drawn anew")
    }
  }
  new
}

///|
test "the floating head as nodes: drawn, its × within the window; another name (cut short), another tool, drawn anew" {
  head_seen("photo.png", ["edit", "copy"], []) |> ignore
  head_seen("a-very-long-name-of-a-picture-sent-from-far-away-2026-10-31.png", ["edit", "copy", "download"], []) |> ignore
  head_seen("photo.png", [], []) |> ignore
  // (changed once made: drawn as what it says then)
  head_seen("photo.png", ["copy"], [
    (
      "another name, other tools",
      fn(s) {
        s.name.set("another-picture.jpg")
        s.tools.set(["edit", "check", "download"])
      },
      0.0,
    ),
  ])
  |> ignore
}

///|
test "the floating head as nodes never narrower once open: tools gone, a shorter name, as wide as it was" {
  let new = head_seen("a-longer-name.png", ["edit", "copy", "download"], [
    (
      "fewer, shorter",
      fn(s) {
        s.name.set("a.png")
        s.tools.set([])
      },
      0.0,
    ),
  ])
  assert_eq(new[1].2, new[0].2, msg="its × where it was")
}

///|
/// How opaque the head is drawn (its glass's opacity, the last of what drawn_within says of the first it draws), as
/// head_run saw it.
fn head_alpha(drawn : Array[String]) -> Double {
  match drawn {
    [first, ..] =>
      match first.split(" ").map(fn(v) { v.to_owned() }).to_array() {
        [.., last] => number_of(last).unwrap_or(-1.0)
        _ => -1.0
      }
    [] => 0.0
  }
}

///|
test "the floating head as nodes going as it sleeps and coming as it wakes, from where it is at that moment: at each moment as its way says (sleep_ms out, wake_ms in, eased out)" {
  let new = head_run("photo.png", ["copy"], [
    ("half asleep", fn(s) { s.awake.set(false) }, sleep_ms / 2.0),
    ("woken half way, half back", fn(s) { s.awake.set(true) }, wake_ms / 2.0),
    ("awake", fn(_) {  }, wake_ms),
    ("asleep", fn(s) { s.awake.set(false) }, sleep_ms + 10.0),
  ])
  let ease = fn(p : Double) { @ui.Ease::Out.at(p) }
  let half = 1.0 - ease(0.5)
  let back = half + (1.0 - half) * ease(0.5)
  let want = [1.0, half, back, 1.0, 0.0]
  for i, w in want {
    let got = head_alpha(new[i].1)
    assert_true((got - w).abs() < 0.001, msg="\{new[i].0}: \{got}, its way says \{w}")
  }
}

///|
/// The glyphs drawn of words `s`'s line where the draw list has them (kind 1, a glyph's): how far right each is cut to
/// (its clip's right, the window's where nothing cuts it nearer).
fn glyph_clips_right(t : @ui.Tester, top : Double, bottom : Double) -> Array[(Double, Double)] {
  let out = []
  for line in t.drawlist().split("\n") {
    let f = line.split(" ").map(fn(v) { v.to_owned() }).to_array()
    if f.length() >= 21 && f[0] == "i" && f[6] == "1" {
      match (number_of(f[1]), number_of(f[2]), number_of(f[19])) {
        (Some(x), Some(y), Some(r)) if y >= top && y <= bottom => out.push((x, r))
        _ => ()
      }
    }
  }
  out
}

///|
/// A head 196 wide with three tools and a long name as nodes: each tool's (and ×'s) rect and what
/// is drawn within it; the name's words read out, and the glyphs drawn of it with how far right each is cut to, and
/// where the first tool begins.
fn narrow_head() -> (Array[((Double, Double, Double, Double), Array[String])], Bool, Array[(Double, Double)], Double) raise {
  let name = "a-very-long-name-of-a-picture.png"
  let tools = ["edit", "copy", "download"]
  let tt = head_tester(HeadState::new(name, tools), w=190.0)
  let rects = []
  for icon in tools + ["close"] {
    let label = if icon == "close" { t("web-main.preview.closeKey") } else { head_label(icon) }
    let b = tt.get(Button, label~)
    rects.push((b.rect, drawn_within(tt, b.rect)))
  }
  let words = tt.all(Text, label=name)
  let first = tt.get(Button, label=head_label("edit")).rect.0
  let glyphs = match words {
    [w, ..] => glyph_clips_right(tt, w.rect.1 - 2.0, w.rect.1 + w.rect.3 + 2.0)
    _ => []
  }
  (rects, words.length() == 1, glyphs, first)
}

///|
test "the floating head as nodes with next to no room for its name: what is drawn of it within the room it is given, the tools whole in the window one after another, the name read out whole" {
  let (new_tools, new_read, glyphs, first) = narrow_head()
  for i, tool in new_tools {
    let ((x, _, w, _), drawn) = tool
    assert_true(x >= 0.0 && x + w <= 190.0 && !drawn.is_empty(), msg="tool \{i} whole: \{Repr(tool)}")
    if i > 0 {
      assert_true(x >= new_tools[i - 1].0.0 + new_tools[i - 1].0.2 - 0.01, msg="tool \{i} after the one before")
    }
  }
  assert_true(new_read, msg="the name read out whole")
  assert_true(glyphs.length() > 0, msg="something of the name drawn")
  for g in glyphs {
    let (x, right) = g
    assert_true(right <= first + 0.01, msg="a glyph at \{x} cut at \{right}, past the first tool at \{first}: \{Repr(glyphs)}")
  }
}

///|
/// A head as nodes in a window of its own, the system's size of words `scale` after it is first drawn:
/// what it draws then.
fn head_scaled(scale : Double) -> Array[String] raise {
  let t = head_tester(HeadState::new("photo.png", ["copy"]))
  t.set_font_scale(scale)
  t.draw()
  t.draw()
  head_drawn(t).0
}

///|
test "the floating head as nodes at the system's size of words, changed once made: drawn bigger than at 1" {
  assert_true(head_scaled(1.3) != head_scaled(1.0), msg="bigger than at 1")
}

///|
test "the floating head as nodes never narrower once open: the system's size of words made bigger, then as it was: as wide as it grew to" {
  let t = head_tester(HeadState::new("a-longer-name-of-a-file.png", ["copy"]))
  let x0 = head_drawn(t).1
  t.set_font_scale(1.3)
  t.draw()
  t.draw()
  let grown = head_drawn(t).1
  assert_true(grown.0 > x0.0, msg="bigger words: wider (its × further right) \{Repr(grown)} \{Repr(x0)}")
  t.set_font_scale(1.0)
  t.draw()
  t.draw()
  assert_eq(head_drawn(t).1, grown, msg="as it was: as wide as it grew to")
}

///|
test "the floating head as nodes never narrower once open: a longer name then a shorter one, a frame between or none, as wide as the longer laid it out" {
  let long = fn(s : HeadState) { s.name.set("a-much-longer-name-of-a-picture.png") }
  let short = fn(s : HeadState) { s.name.set("a.png") }
  let framed = head_run("photo.png", ["copy"], [("longer", long, 0.0), ("shorter", short, 0.0)])
  let unframed = head_run("photo.png", ["copy"], [("longer", long, -1.0), ("shorter", short, 0.0)])
  assert_eq(unframed[unframed.length() - 1].2, framed[framed.length() - 1].2, msg="its ×, no frame between, as with one")
  assert_true(framed[2].2.0 > framed[0].2.0, msg="wider than as made: \{Repr(framed[2].2)} \{Repr(framed[0].2)}")
}

///|
test "the floating head as nodes never narrower once open: tools added, then taken away, a frame between or none, as wide as with them" {
  let more = fn(s : HeadState) { s.tools.set(["edit", "copy", "download"]) }
  let fewer = fn(s : HeadState) { s.tools.set(["copy"]) }
  let framed = head_run("photo.png", ["copy"], [("more", more, 0.0), ("fewer", fewer, 0.0)])
  let unframed = head_run("photo.png", ["copy"], [("more", more, -1.0), ("fewer", fewer, 0.0)])
  assert_true(framed[1].2.0 > framed[0].2.0, msg="more tools: wider \{Repr(framed[1].2)} \{Repr(framed[0].2)}")
  assert_eq(framed[2].2, framed[1].2, msg="fewer, a frame between: as wide as with them")
  assert_eq(unframed[unframed.length() - 1].2, framed[2].2, msg="fewer, no frame between: the same")
}

///|
test "the floating head as nodes: its meta on its name's baseline (a Body line at 600 beside a Meta one), lines as the web's or the host's, the system's size of words 1 or 1.3" {
  for web in [true, false] {
    @ui.set_web_lines(web)
    for scale in [1.0, 1.3] {
      let t = @ui.Tester::new(fn(_c) {  }, w=800.0, h=300.0, platform=if web { 0 } else { 2 })
      t.check_looks(false)
      @ui.set_view_app(fn(root) {
        viewer_head_node(
          root,
          fn() { "deploy-plan.md" },
          fn() { "Markdown · 12 KB" },
          fn() { true },
          fn(_) { 1.0 },
          fn() { 0.0 },
          fn() { 800.0 },
          fn() { page_viewer_ink() },
          fn() { viewer_page_glass() },
          fn(_) {  },
          fn() { "" },
          fn() {  },
        )
        |> ignore
      })
      if scale != 1.0 {
        t.set_font_scale(scale)
      }
      t.draw()
      let runs = t.text_runs()
      let n = runs.filter(fn(r) { r.text == "deploy-plan.md" })
      let m = runs.filter(fn(r) { r.text == "Markdown · 12 KB" })
      assert_true(n.length() > 0 && m.length() > 0, msg="web=\{web} scale=\{scale}: name or meta not drawn")
      assert_true(
        (n[0].base - m[0].base).abs() <= 0.01,
        msg="web=\{web} scale=\{scale}: name base=\{n[0].base} meta base=\{m[0].base}",
      )
      assert_eq(t.audit(), [])
    }
  }
  @ui.set_web_lines(false)
}
