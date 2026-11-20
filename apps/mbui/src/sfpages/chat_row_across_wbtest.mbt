// A chat row's head line as what stands in it comes or goes (chat_row_node.mbt): its lead mark (a chat's state, a blue
// dot while it has news) and the marks at its line's end make their way along the line (View::show's and pick's
// `along_row`), the title moving aside with them frame by frame, never a jump; what is told at first (an answer, a
// block of the list taken for another chat) at once, as were it made so.

///|
/// Where the row's title `title` starts across, as drawn now.
fn row_across_title_x(t : @ui.Tester, title : String) -> Double? {
  match t.words().filter(fn(w) { w.0 == title && w.5 > 0.0 }) {
    [w, ..] => Some(w.1)
    _ => None
  }
}

///|
/// A row of a chat (its tone `tone`'s) on its own on `platform`, drawn once.
fn row_across_at(platform : Int, tone : @signals.Signal[String]) -> @ui.Tester {
  @sfbase.reset()
  @sf.set_words(@sfbase.fill)
  let base = { ..sample_chat(0), title: "A chat" }
  let t = @ui.Tester::new(fn(c) { @sf.begin(c) |> ignore }, w=320.0, h=200.0, platform~)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(@sf.ui_theme_now)
    let popup = root.box(fn(v) { v.over(Is(true)) |> ignore })
    let tips = @sf.TipLayer::new(fn() { Some(popup) })
    let item = fn() { { ..base, tone: tone.get() } }
    chat_row_node(root, @sfbase.sample_source, tips, item, "agents", fn() { false }, Side, fn() { 0 }) |> ignore
  })
  t.draw()
  t
}

///|
/// Each frame's start of the title `title` from the one before `change` is made, through `ms` of the frames a host
/// draws after it.
fn row_across_frames(t : @ui.Tester, title : String, change : () -> Unit, ms : Double) -> Array[Double] {
  let xs = [row_across_title_x(t, title).unwrap_or(-1000.0)]
  t.each_frame(Some(fn() { xs.push(row_across_title_x(t, title).unwrap_or(-1000.0)) }))
  change()
  t.run_shown(ms)
  t.each_frame(None)
  xs
}

///|
/// What steps more than `most` across in a frame among `xs`, as words.
fn row_across_steps(xs : Array[Double], most : Double) -> Array[String] {
  let out = []
  for i in 1..<xs.length() {
    let d = xs[i] - xs[i - 1]
    if d > most || d < -most {
      out.push("frame \{i}: \{xs[i - 1]} → \{xs[i]}")
    }
  }
  out
}

///|
test "a chat row's title settles at once outside a transition (and as an answer), and makes way along its line inside a transition, never a step of 8 in a frame" {
  for platform in [0, 2] {
    let tone = @signals.signal("")
    let t = row_across_at(platform, tone)
    let x0 = row_across_title_x(t, "A chat").unwrap_or(-1000.0)
    // background tone change outside a transition: settles at once, never sliding unprompted
    let plain_in = row_across_frames(t, "A chat", fn() { tone.set("done") }, @ui.move_most_ms)
    let x1 = plain_in[plain_in.length() - 1]
    assert_true(x1 - x0 >= 8.0, msg="the mark made room before the title, platform \{platform}: \{x0} → \{x1}")
    assert_true(plain_in.length() >= 2, msg="drawn, platform \{platform}")
    assert_eq(plain_in[1], x1, msg="outside a transition, mark settles at once, platform \{platform}: \{Repr(plain_in)}")
    let plain_out = row_across_frames(t, "A chat", fn() { tone.set("") }, @ui.move_most_ms)
    assert_true(plain_out.length() >= 2, msg="drawn, platform \{platform}")
    assert_eq(plain_out[1], x0, msg="outside a transition, cleared mark settles at once, platform \{platform}: \{Repr(plain_out)}")
    // inside an explicit transition: the title moves aside along its line
    let came = row_across_frames(t, "A chat", fn() { @view.transition(fn() { tone.set("done") }) }, @ui.move_most_ms)
    assert_eq(came[came.length() - 1], x1, msg="reached mark place, platform \{platform}")
    assert_true(came.length() > 3, msg="drawn on its way, platform \{platform}: \{Repr(came)}")
    assert_eq(row_across_steps(came, 8.0), [], msg="its way in, platform \{platform}: \{Repr(came)}")
    let went = row_across_frames(t, "A chat", fn() { @view.transition(fn() { tone.set("") }) }, @ui.move_most_ms)
    assert_eq(went[went.length() - 1], x0, msg="back where it was, platform \{platform}")
    assert_eq(row_across_steps(went, 8.0), [], msg="its way out, platform \{platform}: \{Repr(went)}")
    // told as an answer (a subscription's first value, a block of the list taken for another chat): at once, no way
    let told = row_across_frames(t, "A chat", fn() { @view.answering(fn() { tone.set("done") }) }, @ui.move_most_ms)
    assert_true(told.length() >= 2, msg="drawn, platform \{platform}")
    assert_eq(told[1], x1, msg="an answer's mark in its place at once, platform \{platform}: \{Repr(told)}")
    t.assert_idle()
  }
}
