// Generic meter atoms as nodes of a page made once (fill_chip_node, dials_node, and their JSON/box helpers).

///|
/// A fill chip (fill_chip's, as a node) in `parent`: on the neutral ground, filled from the left as far as `fill` (0–100)
/// says now, grey while `level` is ok, faintly the level's colour once it is not; `mark` and `words` in the text's
/// colour; `small` a lower one. `said` (what is left and when it fills again) over it while it is pointed at, in `tips`.
/// In a page's bones, one piece. Never squeezed, but `squeezes`: given way to its row where that has not the room for it
/// left, its figure cut short with an ellipsis (meter_chips_brief_node's, the old line's `keep`).
#callsite(autofill(loc))
pub fn fill_chip_node(
  parent : @view.View,
  fill : () -> Int,
  level : () -> String,
  mark : () -> String,
  words : () -> String,
  small? : Bool = false,
  label_muted? : Bool = false,
  refill? : () -> Bool,
  said? : () -> String,
  tips? : TipLayer,
  tips_within? : Bool = false,
  squeezes? : Bool = false,
  loc~ : SourceLoc,
) -> @view.View {
  let part = fn() {
    let f = fill()
    if f < 0 {
      0
    } else if f > 100 {
      100
    } else {
      f
    }
  }
  let is_refill = match refill {
    Some(f) => {
      let sig = @signals.computed(fn(_) { f() })
      fn() { sig.get() }
    }
    None => fn() { false }
  }
  let icon_sz = if small { 9.0 } else { 10.5 }
  let in_overlay = parent.lent(floating_host_lent) is Some(_)
  let chip = parent.box(made_for=loc, fn(b) {
    // (as high as its words' line at the system's size of words where that is higher than the chip: at 1.3 a small
    // chip's 16 held words of 20, over the line above and below it, a station's row in 选择运行的 station, main
    // df98aad1 42956992852, 2026-11-11)
    style_node(b, fn() {
      let base = chip_box_at(b.words_scale(), small)
      let boxed = if in_overlay && theme().dark {
        base.then(chip_box_dark_overlay)
      } else {
        base
      }
      let words_st = if is_refill() {
        if small {
          if mark() == "" { chip_refill_words_small_unmarked } else { chip_refill_words_small }
        } else if mark() == "" {
          chip_refill_words_unmarked
        } else {
          chip_refill_words
        }
      } else {
        let s = if small { chip_words_small } else { chip_words }
        if mark() == "" || (!label_muted && chip_joined(mark(), words())) {
          s.then(chip_joined_gap)
        } else {
          s
        }
      }
      boxed.then(words_st)
    })
    b.bone_whole(Is(true)).shrink(Is(if squeezes { 1.0 } else { 0.0 })) |> ignore
    if squeezes {
      b.min_width(Is(Some(0.0))) |> ignore
    }
    // (its fill a plain rectangle cut along the chip's corners, its end square where it stops)
    b.clips(Is(true)) |> ignore
    b.box(fn(x) {
      x
      .over_at(Is((Some(0.0), Some(0.0), None, Some(0.0))))
      .height_share(Is(1.0))
      .width_share(By(fn() { if is_refill() { 1.0 } else { part().to_double() / 100.0 } }))
      .ground(By(fn() {
        let t = theme()
        if is_refill() {
          over(t.p.card, t.p.red_bg)
        } else {
          let lv = level()
          let tint = if lv == "amber" || lv == "red" {
            level_color(lv)
          } else if lv == "progress" {
            t.p.accent_text
          } else {
            t.p.muted
          }
          alpha(tint, chip_fill_share)
        }
      }))
      |> ignore
    })
    |> ignore
    // (its mark made with it, none where it says none: a chip whose mark comes is the same chip, never one making its
    // way in across its words)
    // (a mark run on into its words, 磁盘剩 420 G, one line of words, never two touching)
    let joined = fn() { !is_refill() && !label_muted && chip_joined(mark(), words()) }
    let k = words_node(b, fn() { if joined() { "" } else { mark() } }, fn() {
      if is_refill() { chip_refill_label_text } else if label_muted { chip_label_text } else { chip_text }
    })
    match refill {
      Some(_) =>
        b.each(at_once=true, fn() { if is_refill() { [0] } else { [] } }, fn(i) { i }, fn(x, _) {
          let ic = icon_node(x, "refresh", icon_sz, By(fn() { theme().p.red }))
          if squeezes {
            ic.shrink(Is(0.0)) |> ignore
          }
        })
      None => ()
    }
    let f = words_node(b, fn() { if joined() { mark() + words() } else { words() } }, fn() {
      if is_refill() { chip_refill_text } else { chip_text }
    })
    // (squeezed where it may be: its figure cut short with an ellipsis, as the old line's chips kept to the last are;
    // else whole, its mark and figure never squeezed over each other, so a line short of the room for it gives it
    // up whole: View::drops)
    if squeezes {
      k.shrink(Is(0.0)) |> ignore
      f.shrink(Is(1.0)).min_width(Is(Some(0.0))).cuts(Is(true)).allow_ellipsis(Is(true)) |> ignore
    } else {
      k.shrink(Is(0.0)) |> ignore
      f.shrink(Is(0.0)) |> ignore
    }
  })
  match (tips, said) {
    // (`tips_within`: shown by the pointer within it, where the chip stands in what takes no press and so is never
    // pointed at itself, an agent's card's; tip_node's `within`)
    (Some(t), Some(s)) => tip_node(t, chip, s, within=tips_within) |> ignore
    _ => ()
  }
  chip
}

///|
/// Dials side by side (dials', as nodes): `dials` as they are said, `details` a quiet line under each where there is one
/// (a GPU's model). Wide, each 96 wide at least (`columns` > 0: each 96), 36 apart, on as many lines as they take (12
/// between). Narrow: sharing the line's width, 16 apart, their cells narrower; `columns` > 0, that many a line (the last
/// line's room kept where it has fewer); `lines` > 0, the same, a note longer than its dial going on under itself (an
/// allowance's, two a line: its windows have no shorter words, and three in a line cut 每周 · Fable and 2 天 4 小时后刷新
/// at a third of a phone's card; with its models' own weeks, five, they ran past the card); else all in a line, in
/// their full words where the line has the room for all of them so, else all in their short ones (one way for all).
/// `press`: a dial that `turns` pressed (by its place), pressed with the hand, the keyboard or a screen reader.
#callsite(autofill(loc))
pub fn dials_node(
  parent : @view.View,
  dials : () -> Array[Dial],
  details? : () -> Array[String] = fn() { [] },
  columns? : Int = 0,
  lines? : Int = 0,
  press? : (Int) -> Unit,
  loc~ : SourceLoc,
) -> Unit {
  let narrow = part_of(parent).look == Narrow
  // (each dial its own, worked out once of them all, told only as it comes out otherwise: one dial's change runs nothing
  // of the others)
  let dial = fn(d : @view.View, i : Int, short : Bool, wraps : Bool) {
    let one = @signals.computed(fn(_) { dials().get(i) })
    let detail = @signals.computed(fn(_) { details().get(i) })
    let detailed = @signals.computed(fn(_) { !details().is_empty() })
    let pressed = match press {
      Some(p) => Some(fn() { p(i) })
      None => None
    }
    dial_node(d, fn() { one.get() }, fn() { detail.get() }, fn() { detailed.get() }, short, wraps, narrow, columns, pressed)
  }
  let line = fn(r : @view.View, short : Bool) {
    style_node(r, fn() { if narrow { dl_row_narrow } else { dl_row_wide } }, in_row=narrow)
    if !narrow {
      r.wraps(Is(Some(dl_lines))) |> ignore
    }
    r.each(fn() { Array::makei(dials().length(), fn(i) { i }) }, fn(i) { i }, fn(d, i) {
      dial(d, i.untracked(), short, false)
    })
  }
  // (a line `per` of them, the last one's room kept where it has fewer)
  let in_lines = fn(b : @view.View, per : Int, wraps : Bool) {
    style_node(b, fn() { dl_rows })
    b.each(fn() { Array::makei((dials().length() + per - 1) / per, fn(k) { k }) }, fn(k) { k }, fn(r, k) {
      let start = k.untracked() * per
      style_node(r, fn() { dl_row_narrow })
      for i in start..<(start + per) {
        r.pick(fn() { i < dials().length() }, fn(d, there) {
          if there {
            dial(d, i, false, wraps)
          } else {
            style_node(d, fn() { dl_dial_narrow }, in_row=true)
          }
        })
      }
    })
  }
  parent.box(made_for=loc, fn(b) {
    if narrow && columns > 0 {
      in_lines(b, columns, false)
    } else if narrow && lines > 0 {
      in_lines(b, lines, true)
    } else if narrow {
      // all of them in their full words where the line has the room for all, else all in their short ones: the full
      // line left out of its row where it has not the room, the short one there only while it is (View::drops)
      let ways = fn() { dials().iter().any(fn(d) { d.label_short != "" || d.note_short != "" }) }
      style_node(b, fn() { dl_row_ways })
      b.fits(Is(true)) |> ignore
      b.box(fn(r) {
        r.drops(By(fn() { if ways() { 1 } else { 0 } })) |> ignore
        line(r, false)
      })
      |> ignore
      b.show(ways, fn(s) {
        s.drops(Is(-1)) |> ignore
        line(s, true)
      })
    } else {
      line(b, false)
    }
  })
  |> ignore
}

///|
/// A dial (dials' draw): what is left large, its unit after it quieter on its line; its ten cells, as many lit as `fill`
/// says in its level's colour; its label and its note under (`short`: their short words where they have them), its
/// `detail` under that where there is one (`detailed`: the note in the detail's look, as wide as it is). `press`: done as
/// it is pressed while it `turns` (the whole dial the button, read out by its label and its figure).
#callsite(autofill(loc))
fn dial_node(
  d : @view.View,
  dial : () -> Dial?,
  detail : () -> String?,
  detailed : () -> Bool,
  short : Bool,
  wraps : Bool,
  narrow : Bool,
  columns : Int,
  press : (() -> Unit)?,
  loc~ : SourceLoc,
) -> Unit {
  let blank : Dial = { number: "", unit: "", fill: 0, level: "", label: "", note: "", label_short: "", note_short: "", turns: false }
  let now = fn() { dial().unwrap_or(blank) }
  // (its colour, whether it runs low and how many cells are lit, each worked out once of it, told only as it comes out
  // otherwise: its figure or its words changing run nothing of its ten cells)
  let ink_now = @signals.computed(fn(_) {
    let t = theme()
    match now().level {
      "amber" | "warn" => t.p.warn_ink
      "red" => t.p.red
      _ => t.p.green
    }
  })
  let ink = fn() { ink_now.get() }
  let low_now = @signals.computed(fn(_) {
    match now().level {
      "amber" | "warn" | "red" => true
      _ => false
    }
  })
  let low = fn() { low_now.get() }
  let lit_now = @signals.computed(fn(_) {
    let f = now().fill
    let fill = if f < 0 { 0 } else if f > 100 { 100 } else { f }
    (fill.to_double() / 10.0).round().to_int()
  })
  let lit = fn() { lit_now.get() }
  style_node(d, fn() { if narrow { dl_dial_narrow } else if columns > 0 { dl_dial_wide_fixed } else { dl_dial_wide } }, in_row=true)
  // (the dial itself the button where it turns: its look is what follows, drawn alike pressable or not)
  if press is Some(p) {
    let turns = @signals.computed(fn(_) { now().turns })
    @headless.button(
      made_for=loc,
      d,
      fn() { now().label },
      fn(_) { p() },
      fn(_, _) {  },
      disabled=fn() { !turns.get() },
      value=fn() { now().number + now().unit },
      in_node=true,
    )
    |> ignore
  }
  // (the figure and its unit one line's runs: the unit on the figure's baseline)
  let number = fn() { if low() { dl_number.then(@ui.text_style(color=Data(ink()))) } else { dl_number } }
  d.box(made_for=loc, fn(w) {
    w
    .words_runs(By(fn() {
      let t = theme()
      [@ui.span(now().number), @ui.span(now().unit, weight=500, scale=t.t.meta / dl_number_size, color=t.p.muted)]
    }))
    .words_look(By(fn() { @ui.style_words(number()) }))
    .ink(By(fn() { @ui.style_ink(number()) }))
    |> ignore
  })
  |> ignore
  d.box(fn(cells) {
    style_node(cells, fn() { if narrow { dl_cells_narrow } else { dl_cells_wide } })
    let cell = if narrow { dl_cell_narrow } else { dl_cell_wide }
    for i in 0..<10 {
      cells.box(fn(x) { style_node(x, fn() { if i < lit() { cell.then(@ui.style(bg=Data(ink()))) } else { cell } }, in_row=true) })
      |> ignore
    }
  })
  |> ignore
  words_node(d, fn() { if short && now().label_short != "" { now().label_short } else { now().label } }, fn() {
    if wraps { dl_label_lines } else { dl_label }
  })
  |> ignore
  words_node(
    d,
    fn() {
      let n = now()
      if n.note == "" {
        " "
      } else if short && n.note_short != "" {
        n.note_short
      } else {
        n.note
      }
    },
    fn() { if detailed() { dl_detail } else if wraps { dl_reset_lines } else { dl_reset } },
  )
  |> ignore
  d.show(fn() { detail().unwrap_or("") != "" }, fn(s) { words_node(s, fn() { detail().unwrap_or("") }, fn() { dl_detail }) |> ignore })
}

///|
/// A fill chip's box (chip_box's, chip_box_small's) at the system's size of words `scale`: as high as chip_text's line
/// drawn at that size where that is higher than the chip (box_at: kept for the last theme and size, each its own).
fn chip_box_at(scale : Double, small : Bool) -> @ui.Style {
  if small {
    box_at(chip_small_kept, chip_box_small, fill_chip_small_h, chip_text, scale)
  } else {
    box_at(chip_kept, chip_box, fill_chip_h, chip_text, scale)
  }
}

///|
// kept across runs: the last theme and size of words a fill chip was asked at and its box (box_at), worked out again
// for any other
let chip_kept : Ref[WordsBoxKept?] = Ref(None)

///|
// kept across runs: the same of a small fill chip
let chip_small_kept : Ref[WordsBoxKept?] = Ref(None)

///|
/// A machine's chips' line one way (in words, or by their figures), 8 apart.
// kept across runs: a value (no field of it changes)
let meter_line_way : @ui.Style = @ui.css("row gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let meter_chips_line : @ui.Style = @ui.css("row w=Full gap=S1 align=ACenter")

///|
/// A worded line of them: as wide as what holds it, the room its ways are fitted to.
// kept across runs: a value (no field of it changes)
let quota_chips_line : @ui.Style = @ui.css("row w=Full align=ACenter")

///|
pub fn chip_field(v : Json?, key : String) -> Json? {
  match v {
    Some(Object(o)) => o.get(key)
    _ => None
  }
}

///|
pub fn chip_str(v : Json?, key : String) -> String {
  match chip_field(v, key) {
    Some(String(s)) => s
    _ => ""
  }
}

///|
/// What is left (0–100) of a window or a meter (`left`).
pub fn chip_left(v : Json?) -> Int {
  let n = match chip_field(v, "left") {
    Some(Number(x, ..)) => x.to_int()
    _ => 0
  }
  if n < 0 {
    0
  } else if n > 100 {
    100
  } else {
    n
  }
}
