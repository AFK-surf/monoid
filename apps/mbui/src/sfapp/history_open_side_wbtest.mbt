// A group opened in the history beside a chat grows its steps from their words' column, never in from the right: the
// steps stand 20 in from the rail (h_steps' `pl=S5`) with their marks (`4.2s`, a chevron) flush at their end, and were
// read as laid from that end, so they slid leftwards into place as they grew (a step's words 1110 → 975 over its
// way). Each step's line keeps the left edge it rests at, at every look 20 ms apart while it opens.

///|
/// How far apart the test looks while a step's line opens: several looks over a way.
let open_side_look_ms : Double = 20.0

///|
/// Where `words` is drawn across at each look `open_side_look_ms` apart over a whole way, from now: none where it is not seen yet.
fn open_side_xs(t : @ui.Tester, words : String) -> Array[Double] {
  let xs = []
  let mut ms = 0.0
  while ms < @ui.move_most_ms {
    t.run_for(open_side_look_ms)
    ms = ms + open_side_look_ms
    match t.drawn_of(words) {
      Some((x, _)) => xs.push(x)
      None => ()
    }
  }
  xs
}

///|
/// Whether there are some of `xs` seen while the way goes, every one within half a point of the last.
fn open_side_held(xs : Array[Double]) -> Bool {
  guard xs.length() >= 3 else { return false }
  let rest = xs[xs.length() - 1]
  xs.iter().all(fn(x) { (x - rest).abs() <= 0.5 })
}

///|
fn open_side_text(xs : Array[Double]) -> String {
  xs.map(fn(x) { x.to_string() }).join(" ")
}

///|
test "the history beside a chat: a group's steps open from their words' column, each line's left edge held" {
  let calls : Array[Made] = []
  let t = decide_core(calls, "chat-history-side", wide=true)
  t.tap_text("读了 src/ui/list.mbt 等 2 个文件，跑了测试")
  // (its first step's line, 读取 src/ui/list.mbt, starts with its verb)
  let first = open_side_xs(t, "读取")
  assert_true(open_side_held(first), msg="a group's first step: \{open_side_text(first)}")
  // (closed and opened again: its second step's line, 命令 跑一遍列表的测试)
  t.tap_text("读了 src/ui/list.mbt 等 2 个文件，跑了测试")
  t.run_for(@ui.move_most_ms)
  t.tap_text("读了 src/ui/list.mbt 等 2 个文件，跑了测试")
  let second = open_side_xs(t, "命令")
  assert_true(open_side_held(second), msg="a group's second step: \{open_side_text(second)}")
}
