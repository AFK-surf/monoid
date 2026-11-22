// Helpers of the tests of a chat's rows as they are drawn again and kept (kept_rows' and its kinds' suites, of the old
// page, gone): what the tests still using them share.

///|
/// How far apart the moments are that the messages are looked at.
let kept_rows_step_ms : Double = 120.0

///|
/// What the last frame's paint said of it besides its drawing (its targets, what scrolls, the words that can be picked,
/// the scroll bars, the lines of words: Tester::said), a line each.
fn kept_rows_said(t : @ui.Tester) -> Array[String] {
  t.said().split("\n").filter(fn(l) { l.length() > 0 }).map(fn(l) { "said " + l.to_owned() }).collect()
}

///|
/// An instance as `drawn_from` says it, a glyph's place in the atlas left out (the atlas fills in another order where
/// rows are built every frame: what is drawn the same).
fn kept_rows_inst(line : String) -> String {
  // ("inst", then its numbers: its kind the 6th, in 1/64ths; a glyph's atlas rect the 13th to the 16th. Read in place:
  // split into its fields and joined again, every line of every moment, it was a third of the kinds' sweep's time)
  guard line.has_prefix("inst ") else { return line }
  // (where each field after "inst" starts: its numbers are ASCII, so a char's place is its code unit's)
  let starts : Array[Int] = []
  let mut i = 0
  for ch in line {
    if ch == ' ' {
      starts.push(i + 1)
      if starts.length() > 16 {
        break
      }
    }
    i = i + 1
  }
  guard starts.length() >= 16 else { return line }
  let field = fn(k : Int) {
    let e = if k < starts.length() { starts[k] - 1 } else { line.length() }
    line.unsafe_substring(start=starts[k - 1], end=e)
  }
  let kind = field(6)
  guard kind == "64" || kind == "192" || kind == "448" else { return line }
  let rest = if starts.length() > 16 { line.unsafe_substring(start=starts[16] - 1, end=line.length()) } else { "" }
  line.unsafe_substring(start=0, end=starts[12]) + "_ _ _ _" + rest
}

///|
/// How far apart the moments are that a chat left still is looked at (no step of a clock's falls on one).
let kept_rows_still_ms : Double = 70.0

///|
/// Chat `mode` opened `w` by `h`: on 小屏 (a phone's width), on 中屏's tape (the page brought over the sidebar), or on
/// 大屏 (a desktop's window, 1000 wide or more: with a mouse).
fn kept_rows_open(mode : String, w : Double, h : Double) -> @ui.Tester {
  new_run()
  let src = fixture(mode)
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let large = w >= 1000.0
  // (two ways of drawing compared: the corner rule is held where the chats' pictures are tested)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform=if large { 0 } else { 2 }, corners_held=false)
  let tape = w > 600.0 && !large
  if tape {
    say_room(t, "medium", "medium")
  }
  t.run_for(@ui.move_most_ms)
  if tape {
    t.tap(w - @sfdesk.tape_shows / 2.0, h / 2.0)
    t.run_for(@ui.move_most_ms)
  }
  t
}
