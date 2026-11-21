// What waits, drawn one way everywhere (web/ui waiting.tsx, waiting.css.ts, styles/spinner.css.ts; sf/align.mbt
// 「等待」; Android's ui/Waiting.kt the same), the phone's pages and the desktop's alike. Three kinds:
// - a page or a list read for the first time: `waiting`, what will come drawn as it will be, of made-up words, in its
//   bones (`bones`: its words bars, its pictures and icons shapes, its outline its own), breathing, no words; what
//   could not be read said over them in red;
// - a row or a button at work: `spinner` in its place, in one of two sizes (14, 12 in a line of small text);
// - what has a size on its way: `progress`; in a spinner's place (a line saying how far, a picture going up),
//   `progress_spinner`.
// Words (a pill, a line) come only after a moment (later_ms), so what is there at once shows none; what failed says so
// at once, in red.
//
// A first read draws the real parts as bones, so the outline cannot differ from the content's. No bones where the
// content is already here (the user, 2026-10-31: 「进 chat 有加载骨架，按理说不应该存在」).

///|
/// Words about a wait show only once it has taken this long.
pub let later_ms : Double = 400.0

///|
/// Whether `ms` has passed on `v`'s clock since `since()` (a moment of that clock), followed: true at once where it
/// already has, else false till `since() + ms` comes due on the timeline, let go with `v`. Only while `going()`: once
/// it is not, nothing is due (the moment called off) and it is false.
pub fn waited_past_node(
  v : @view.View,
  since : () -> Double,
  ms : Double,
  going? : () -> Bool = fn() { true },
) -> () -> Bool {
  let past = @signals.signal(false)
  let due : Ref[() -> Unit] = Ref(fn() {  })
  v.owns(fn() { (due.val)() }) |> ignore
  v.reacts(fn() { if going() { Some(since()) } else { None } }, fn(at) {
    (due.val)()
    due.val = fn() {  }
    match at {
      Some(at) => {
        let seen = at + ms
        if v.cause_at() >= seen {
          past.set(true)
        } else {
          past.set(false)
          due.val = v.at_moment(seen, fn() { past.set(true) })
        }
      }
      None => past.set(false)
    }
  })
  fn() { past.get() }
}

///|
/// WaitLine's words: 13/18 on every width (lineHeight 18.sp).
// kept across runs: a value (no field of it changes)
let wait_words : @ui.TextStyle = @ui.text_style(size=Ui, leading=L5)

///|
/// The spinner's line: 2 wide (Waiting.kt Spinner: Stroke(2.dp)).
let spin_stroke : Double = 2.0

///|
/// How long the spinner takes to turn once (styles/spinner.css.ts: 0.8s).
pub let spinner_turn_ms : Double = 800.0

///|
let spin_pi : Double = 3.141592653589793

///|
/// The ring every wait turns or fills (spinner, spinner_node, progress_spinner, progress_spinner_node: one ring, worked
/// out here once): `size` across, its line `stroke` wide, its middle half the line in from the edge.
priv struct SpinRing {
  mid : Double
  r : Double
  stroke : Double
}

///|
fn SpinRing::new(size : Double, stroke : Double) -> SpinRing {
  let mid = size / 2.0
  { mid, r: mid - stroke / 2.0, stroke }
}

///|
/// Its whole round (the track, in line_strong).
fn SpinRing::round(self : SpinRing) -> Array[(Double, Double)] {
  @ui.arc(self.mid, self.mid, self.r, from=0.0, sweep=2.0 * spin_pi)
}

///|
/// The arc a spinner turns: `sweep` of a turn from a quarter before the top (the web's: a border whose top is the arc).
fn SpinRing::turning(self : SpinRing, sweep : Double) -> Array[(Double, Double)] {
  @ui.arc(self.mid, self.mid, self.r, from=-0.75 * spin_pi, sweep=sweep * 2.0 * spin_pi)
}

///|
/// What a progress spinner draws `shown` (0 to 1) of the way: the track `round` (its own, worked out once) in
/// line_strong, and the accent from the top clockwise as far round as that, none at 0.
fn SpinRing::come_lines(self : SpinRing, round : Array[(Double, Double)], shown : Double, p : Palette) -> Array[@paint.Line] {
  let lines = [@ui.line(round, width=self.stroke, color=p.line_strong)]
  if shown > 0.0 {
    let arc = @ui.arc(self.mid, self.mid, self.r, from=-0.5 * spin_pi, sweep=shown * 2.0 * spin_pi)
    lines.push(@ui.line(arc, width=self.stroke, color=p.accent))
  }
  lines
}

///|
/// How far a wait has come, said by what it waits on, kept to 0 to 1.
fn spin_part(k : Double) -> Double {
  if k < 0.0 {
    0.0
  } else if k > 1.0 {
    1.0
  } else {
    k
  }
}

///|
/// Private spinner for the retained legacy `button` helper.
fn spinner(
  c : @ui.Ctx,
  size? : Double = 14.0,
  stroke? : Double = spin_stroke,
  ring? : Int64,
  arc? : Int64,
  sweep? : Double = 0.25,
  period? : Double = spinner_turn_ms,
) -> Int {
  let t = theme()
  let ring = ring.unwrap_or(t.p.line_strong)
  let arc = arc.unwrap_or(t.p.accent)
  let at = SpinRing::new(size, stroke)
  let node = c.lines(
    [@ui.line(at.round(), width=stroke, color=ring), @ui.line(at.turning(sweep), width=stroke, color=arc)],
    w=Px(size),
    h=Px(size),
  )
  c.cycle_look(node, period, fn(f) { @ui.look(rot=f * 2.0 * spin_pi) })
  node
}

///|
/// The spinner as a node of the window's tree in `parent`: the same ring and arc, their lines said once
/// (View::lines, in the theme's colours as they change, or `ring` and `arc`'s), turned by the clock about the middle of
/// what its pieces cover as each frame is drawn (View::cycle, View::turn): nothing made again for it while it turns; its turning let go with it.
/// The node.
#callsite(autofill(loc))
pub fn spinner_node(
  parent : @view.View,
  size? : Double = 14.0,
  stroke? : Double = spin_stroke,
  ring? : () -> Int64,
  arc? : () -> Int64,
  sweep? : Double = 0.25,
  period? : Double = spinner_turn_ms,
  loc~ : SourceLoc,
) -> @view.View {
  let ring = ring.unwrap_or(fn() { theme().p.line_strong })
  let arc = arc.unwrap_or(fn() { theme().p.accent })
  // (its points worked out once: only its colours change as it lives)
  let at = SpinRing::new(size, stroke)
  let round = at.round()
  let part = at.turning(sweep)
  parent.box(made_for=loc, fn(v) {
    v
    .width(Is(Some(size)))
    .height(Is(Some(size)))
    .lines(By(fn() { [@ui.line(round, width=stroke, color=ring()), @ui.line(part, width=stroke, color=arc())] }))
    // (about the middle of what its pieces cover, as the old one's cycle look turns it)
    .turn(By(fn() { v.cycle(period) * 2.0 * spin_pi }), drawn=true)
    |> ignore
  })
}

///|
/// How long the update's mark takes from one arrow standing to the next, and how much of it the arrow
/// stands still.
pub let updating_rise_ms : Double = 1400.0

///|
/// (how much of updating_rise_ms an arrow stands)
let updating_stand : Double = 0.4

///|
/// What a page or a list waits on (WaitNote), from the core's note (a list's ListNote) or the page's own words: still
/// reading (its placeholders breathe), what it waits on (正在读取会话, 正在连接 Willow: said to a screen reader), what
/// could not be read (each said in red).
pub(all) struct WaitNote {
  reading : Bool
  text : String
  failing : Array[String]
}

///|
/// Made-up words `n` letters long, for what a page's bones are drawn of (`waiting`'s `sample`): only how long they are
/// is seen, as a bar.
pub fn sample_words(n : Int) -> String {
  let out = StringBuilder()
  for _ in 0..<n {
    out.write_char('字')
  }
  out.to_string()
}

///|
/// A wait as nodes of the window's tree: nothing for a moment but its room (later_ms from as it is made: a
/// wait that ends sooner shows none), then a spinner and `words` in the muted ink, 8 apart. Its room is what it will
/// show from the first: as high as its words, wrapped in what the line leaves them past the spinner (wait_words: the Ui
/// size, L5's line, both as the system's size of words makes them), 18 at least, so nothing under it moves as they come
/// (words of two lines no taller then than before). Read out once they are seen.
#callsite(autofill(loc))
pub fn wait_line_node(parent : @view.View, words : () -> String, loc~ : SourceLoc) -> @view.View {
  let long = @signals.signal(false)
  parent.box(made_for=loc, fn(l) {
    l
    .row(Is(true))
    .gap(Is(8.0))
    .lines_up(Is(Some(Start)))
    .min_height(Is(Some(18.0)))
    |> ignore
    l.at_moment(l.cause_at() + later_ms, fn() { long.set(true) }) |> ignore
    // (the spinner on the words' first line, in the middle of it: never on the middle of words of two lines)
    l.box(fn(g) {
      g
      .width(Is(Some(12.0)))
      .height(By(fn() { Some(wait_words_line()) }))
      .lines_up(Is(Some(Middle)))
      .lies_along(Is(Middle))
      |> ignore
      // (the spinner's room while it is not yet there: one in the other's place, at once)
      g.pick(fn() { long.get() }, at_once=true, fn(s, on) {
        if on {
          spinner_node(s, size=12.0) |> ignore
        } else {
          s.width(Is(Some(12.0))).height(Is(Some(12.0))) |> ignore
        }
      })
    })
    |> ignore
    l.box(fn(w) {
      w.shrink(Is(1.0)).min_width(Is(Some(0.0))).hides(By(fn() { !long.get() })) |> ignore
      w
      .words(By(words))
      .words_look(By(fn() {
        let (size, _) = @ui.tree_theme().text_size(Ui)
        { size, weight: 400, line: wait_words_line(), wrap: true, tracking: @view.letters_own, balance: false, max_lines: 0 }
      }))
      .ink(By(fn() { if long.get() { theme().p.muted } else { alpha(theme().p.muted, 0.0) } }))
      |> ignore
    })
    |> ignore
  })
}

///|
/// How high a line of a wait's words is (wait_line_node's): L5's line at the Ui size, as the system's size of words makes
/// it.
fn wait_words_line() -> Double {
  let th = @ui.tree_theme()
  let (_, own) = th.text_size(Ui)
  th.leading(L5).unwrap_or(own)
}

///|
/// A page's or a list's content while it is read the first time, as nodes (waiting's): what will come in its bones
/// (`sample`: what it will show, made of made-up words by the parts that draw it when it comes, in a node of its own
/// drawn as its bones, View::bones), breathing as waiting's do (breathe's: whole to 0.5 and back in breath_ms, from
/// moment 0 on); still and whole as what it waits on failed. Over them in red what could not be read (`error`, `note`'s
/// failing), each in a pill, at once; what it waits on (`note`'s words, where it says any) said only to a screen reader,
/// while it is read. `fill`: it takes the room left (a page's body). `fits`: in a row that fits what it holds to its
/// room (View::fits), its sample laid out as narrow as that leaves it, what it drops to fit dropped (a chooser's model
/// read in a narrow row), a column again while what failed is said over it. Made inside what is in its bones already:
/// only its sample, breathing as that does (one breath).
#callsite(autofill(loc))
pub fn waiting_node(
  parent : @view.View,
  sample : (@view.View) -> Unit,
  error? : () -> String = fn() { "" },
  note? : () -> WaitNote = fn() { { reading: true, text: "", failing: [] } },
  fill? : Bool = false,
  fits? : Bool = false,
  loc~ : SourceLoc,
) -> Unit {
  if parent.in_bones() {
    sample(parent)
    return
  }
  // (as waiting's: what failed, `error` first; still reading unless `error` says what failed or `note` that it is not)
  let failing = fn() {
    let out = if error() != "" { [error()] } else { [] }
    out + note().failing
  }
  let reading = fn() { error() == "" && note().reading }
  parent.box(made_for=loc, fn(w) {
    w.min_width(Is(Some(0.0))) |> ignore
    // (`fits`: in a row that fits what it holds to its room (View::fits), its sample as narrow as that leaves it, what
    // it drops to fit dropped; what failed said over it, a column again, its pills on a line of their own)
    if fits {
      w.row(By(fn() { failing().is_empty() })).shrink(Is(1.0)).fits(Is(true)) |> ignore
    }
    if fill {
      w.grow(Is(1.0)) |> ignore
    }
    w.says(By(fn() {
      if reading() && note().text != "" {
        Some(@view.said(Status, label=note().text))
      } else {
        None
      }
    }))
    |> ignore
    w.show(fn() { failing().length() > 0 }, fn(p) {
      p
      .padding(Is((wait_pills_x, wait_pills_top, wait_pills_x, wait_pills_foot)))
      .gap(Is(wait_pills_gap))
      .lines_up(Is(Some(Middle)))
      |> ignore
      p.each(failing, fn(f) { f }, fn(pill, f) { wait_pill_node(pill, fn() { f.get() }) })
    })
    w.box(fn(b) {
      // (as narrow as `w` comes to, what it holds laid out in that)
      b.min_width(Is(Some(0.0))) |> ignore
      if fits {
        b.row(Is(true)).shrink(Is(1.0)).min_width(Is(Some(0.0))).fits(Is(true)) |> ignore
      }
      if fill {
        b.grow(Is(1.0)) |> ignore
      }
      b
      .bones(By(fn() { theme().p.line }))
      .alpha(By(fn() {
        if !reading() {
          1.0
        } else {
          let f = b.cycle(breath_ms)
          let way = if f < 0.5 { f * 2.0 } else { 2.0 - f * 2.0 }
          1.0 - (1.0 - wait_low) * @ui.Ease::InOut.at(way)
        }
      }))
      |> ignore
      sample(b)
    })
    |> ignore
  })
  |> ignore
}

///|
/// A wait's placeholders at their faintest (breathe's `low`).
let wait_low : Double = 0.5

///|
/// wait_pills' room (px=S5, pt=S3_5, pb=S1, gap=S2).
let wait_pills_x : Double = 20.0

///|
let wait_pills_top : Double = 14.0

///|
let wait_pills_foot : Double = 4.0

///|
let wait_pills_gap : Double = 8.0

///|
/// What could not be read, in a grey capsule, in red at once (wait_pill's `error`, as a node): its words 12 on 18,
/// 12 and 6 in.
#callsite(autofill(loc))
fn wait_pill_node(parent : @view.View, words : () -> String, loc~ : SourceLoc) -> Unit {
  parent.box(made_for=loc, fn(p) {
    p
    .row(Is(true))
    .padding(Is((12.0, 6.0, 12.0, 6.0)))
    .radius(Is(15.0))
    .ground(By(fn() { theme().p.neutral_bg }))
    .lines_up(Is(Some(Middle)))
    |> ignore
    p.box(fn(w) {
      w
      .words(By(words))
      .words_look(By(fn() {
        let th = @ui.tree_theme()
        let (size, _) = th.text_size(Meta)
        { size, weight: 400, line: 18.0, wrap: true, tracking: @view.letters_own, balance: false, max_lines: 0 }
      }))
      .ink(By(fn() { theme().p.red }))
      .words_centered(Is(true))
      |> ignore
    })
    |> ignore
  })
  |> ignore
}
