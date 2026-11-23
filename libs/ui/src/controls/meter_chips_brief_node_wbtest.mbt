// A machine's CPU, memory and disk in brief as nodes (meter_chips_brief_node): all of them where the line has the room,
// and short of it the ones still plenty left out, the last of them first, one running low staying; in a line short even of those at their
// narrowest (meter_brief_wide), the last of them left out as well, nothing cut past knowing; with keyboard and mouse
// and touch.

///|
/// A meter as the core says one (its short name, how much is left in %, its level, its figure and unit).
fn mb_meter(short : String, left : Int, level : String, big : String, unit : String) -> Json {
  {
    "short": Json::string(short),
    "left": Json::number(left.to_double()),
    "level": Json::string(level),
    "remaining": Json::string(if unit == "%" { "空闲 " + big + "%" } else { "剩 " + big + " G" }),
    "big": Json::string(big),
    "unit": Json::string(unit),
    "label": Json::string(short),
    "value": Json::string(big),
  }
}

///|
// kept across runs: a value (no field of it changes)
let mb_meters : Array[Json] = [
  mb_meter("CPU", 91, "ok", "91", "%"),
  mb_meter("内存", 9, "red", "1.4", "GB"),
  mb_meter("磁盘", 12, "amber", "28", "GB"),
  mb_meter("交换", 80, "ok", "3.2", "GB"),
]

///|
/// The line in a row `w` wide at the window's top left, started as `platform`, at rest. The Tester.
fn mb_tester(w : Double, platform : Int) -> @ui.Tester {
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=400.0, h=200.0, platform~)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(b) {
      b.width(Is(Some(w))) |> ignore
      meter_chips_brief_node(b, fn() { mb_meters })
    })
    |> ignore
  })
  t.run_for(@ui.move_most_ms)
  t
}

///|
/// Which of mb_meters' short names the line draws, in order.
fn mb_shown(t : @ui.Tester) -> Array[String] {
  let said = t.words().map(fn(w) { w.0 })
  ["CPU", "内存", "磁盘", "交换"].filter(fn(s) { said.iter().any(fn(w) { w == s }) })
}

///|
test "meter_chips_brief_node in a line with the room for all and in one short of it: all of them, then the plenty left out, the last first, the low ones staying; keyboard and mouse and touch" {
  for platform in [0, 2] {
    let all = mb_shown(mb_tester(300.0, platform))
    assert_eq(all, ["CPU", "内存", "磁盘", "交换"], msg="platform \{platform}: 300 wide")
    let short = mb_shown(mb_tester(150.0, platform))
    assert_eq(short, ["内存", "磁盘"], msg="platform \{platform}: 150 wide")
  }
}

///|
/// How narrow each of mb_meters' chips may be (meter_brief_wide), as the tree started as `platform` sets their words.
fn mb_leasts(platform : Int) -> Array[Double] {
  let got : Ref[Array[Double]] = Ref([])
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=400.0, h=200.0, platform~)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(b) { got.val = mb_meters.map(fn(m) { meter_brief_wide(b, m, cut=true) }) }) |> ignore
  })
  t.run_for(@ui.move_most_ms)
  got.val
}

///|
test "meter_chips_brief_node in a line short even of the low ones: those it has the room for at their narrowest, each in the line, none over another, two of its figure's characters at least; nothing squeezed; keyboard and mouse and touch" {
  for platform in [0, 2] {
    let least = mb_leasts(platform)
    // (内存 and 磁盘, the two running low, 4 apart: just the room for both at their narrowest)
    let both = least[1] + @ui.Space::S1.px() + least[2]
    for w in [both, 110.0, 70.0] {
      let at = "platform \{platform} \{w} wide (least \{Repr(least)})"
      let t = mb_tester(w, platform)
      // (each chip's ground and fill: a rect as high as a small chip on the line's top; a chip, the widest at its start)
      let chips : Map[Int, (Double, Double)] = Map([])
      for r in t.drawn_rects() {
        if r.1.abs() < 0.01 && (r.3 - 16.0).abs() < 0.01 {
          let k = (r.0 * 100.0).round().to_int()
          match chips.get(k) {
            Some((_, was)) if was >= r.2 => ()
            _ => chips[k] = (r.0, r.2)
          }
        }
      }
      let spans = chips.values().collect()
      spans.sort_by(fn(a, b) { a.0.compare(b.0) })
      // (both where there is the room for both at their narrowest, the first alone where only for it, else none)
      let shown = if w >= both - 0.01 {
        2
      } else if w >= least[1] - 0.01 {
        1
      } else {
        0
      }
      assert_eq(spans.length(), shown, msg="\{at}: \{Repr(spans)}")
      let glyphs = t.drawn_instances().filter(fn(a) { a[5] == 1.0 })
      for i, c in spans {
        assert_true(c.0 >= -0.01 && c.0 + c.1 <= w + 0.01, msg="\{at}: \{Repr(c)} out of the line")
        if i > 0 {
          assert_true(c.0 >= spans[i - 1].0 + spans[i - 1].1 - 0.01, msg="\{at}: \{Repr(spans)} over each other")
        }
        // (its mark's two characters and two of its figure's at least, an ellipsis or not)
        let drawn = glyphs.filter(fn(a) { a[0] + a[2] / 2.0 >= c.0 && a[0] + a[2] / 2.0 <= c.0 + c.1 }).length()
        assert_true(drawn >= 4, msg="\{at}: \{Repr(c)} draws \{drawn} characters")
      }
      assert_eq(t.squeeze_faults(), [], msg="\{at}: \{Repr(t.squeeze_faults())}")
    }
  }
}
