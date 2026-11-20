// An allowance as nodes of a page made once (fill_chip.mbt's, quota_chip.mbt's and dials' parts, the same look): a fill
// chip, an allowance's chips in a line, an allowance's windows as dials. What they show followed as it changes.

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
  let chip = parent.box(made_for=loc, fn(b) {
    // (as high as its words' line at the system's size of words where that is higher than the chip: at 1.3 a small
    // chip's 16 held words of 20, over the line above and below it, a station's row in 选择运行的 station, main
    // df98aad1 42956992852, 2026-11-11)
    style_node(b, fn() { chip_box_at(b.words_scale(), small) })
    b.bone_whole(Is(true)).shrink(Is(if squeezes { 1.0 } else { 0.0 })) |> ignore
    if squeezes {
      b.min_width(Is(Some(0.0))) |> ignore
    }
    // (its fill a plain rectangle cut along the chip's corners, its end square where it stops)
    b.box(fn(f) {
      style_node(f, fn() { chip_fill_row })
      f.over(Is(true)).clips(Is(true)) |> ignore
      f.box(fn(x) {
        style_node(x, fn() { chip_fill_part })
        x
        .grow(By(fn() { if is_refill() { 100.0 } else { part().to_double() } }))
        .basis(Is(Some(0.0)))
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
      f.box(fn(x) {
        style_node(x, fn() { chip_fill_part })
        x.grow(By(fn() { if is_refill() { 0.0 } else { (100 - part()).to_double() } })).basis(Is(Some(0.0))) |> ignore
      })
      |> ignore
    })
    |> ignore
    b.box(fn(w) {
      style_node(w, fn() {
        if is_refill() {
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
      })
      // (its mark made with it, none where it says none: a chip whose mark comes is the same chip, never one making its
      // way in across its words)
      // (a mark run on into its words, 磁盘剩 420 G, one line of words, never two touching)
      let joined = fn() { !is_refill() && !label_muted && chip_joined(mark(), words()) }
      let k = words_node(w, fn() { if joined() { "" } else { mark() } }, fn() {
        if is_refill() { chip_refill_label_text } else if label_muted { chip_label_text } else { chip_text }
      })
      match refill {
        Some(_) => {
          let ic = icon_node(w, "refresh", icon_sz, By(fn() { theme().p.red }))
          ic.laid_nowhere(By(fn() { !is_refill() })) |> ignore
          if squeezes {
            ic.shrink(Is(0.0)) |> ignore
          }
        }
        None => ()
      }
      let f = words_node(w, fn() { if joined() { mark() + words() } else { words() } }, fn() {
        if is_refill() { chip_refill_text } else { chip_text }
      })
      // (squeezed where it may be: its figure cut short with an ellipsis, as the old line's chips kept to the last are;
      // else whole, its mark and figure never squeezed over each other, so a line short of the room for it gives it
      // up whole: View::drops)
      if squeezes {
        w.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
        k.shrink(Is(0.0)) |> ignore
        f.shrink(Is(1.0)).min_width(Is(Some(0.0))).cuts(Is(true)).allow_ellipsis(Is(true)) |> ignore
      } else {
        w.shrink(Is(0.0)) |> ignore
        k.shrink(Is(0.0)) |> ignore
        f.shrink(Is(0.0)) |> ignore
      }
    })
    |> ignore
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
/// An allowance's windows as chips in a line (quota_chips', not worded, as a node) in `parent`, `q` as the core says it
/// now: a chip per window, what is left in it, filled as far as that, its mark before it where `marked`; `small` a lower
/// line; `gap` apart; nothing while the core cannot say or there is no window. Each says what is left of it and when it
/// fills again over it while it is pointed at, in `tips` (`tips_within`: while the pointer is within it, fill_chip_node's).
pub fn quota_chips_node(
  parent : @view.View,
  q : () -> Json?,
  small? : Bool = false,
  marked? : Bool = true,
  gap? : Double = 8.0,
  tips? : TipLayer,
  tips_within? : Bool = false,
) -> Unit {
  let windows = fn() {
    match chip_field(q(), "windows") {
      Some(Array(a)) => a
      _ => []
    }
  }
  parent.show(fn() { has_quota(q()) }, fn(x) {
    x.box(fn(r) {
      style_node(r, fn() { quota_chips_row.then(@ui.style(gap=room(gap))) }, in_row=true)
      r.shrink(Is(0.0)) |> ignore
      r.each(fn() { Array::makei(windows().length(), fn(i) { i }) }, fn(i) { i }, fn(c, i) {
        let k = i.untracked()
        let w = fn() { windows().get(k) }
        fill_chip_node(
          c,
          fn() { chip_left(w()) },
          fn() { chip_str(w(), "level") },
          fn() { if marked { quota_mark(w()) } else { "" } },
          fn() { quota_figure(w()) },
          small~,
          label_muted=true,
          refill=fn() { quota_is_refill(w()) },
          said=fn() { quota_said(w()) },
          tips?,
          tips_within~,
        )
        |> ignore
      })
    })
    |> ignore
  })
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
/// A machine's CPU, memory and disk (meter_line's, as nodes) in `parent`, as `meters` says them now: each a chip, what
/// is left in it, filled as far as is used, its mark before it; 8 apart in a line; what it is (its name, how much of
/// how much, a note) over it while it is pointed at, in `tips`.
#callsite(autofill(loc))
pub fn meter_chips_node(parent : @view.View, meters : () -> Array[Json], tips? : TipLayer, loc~ : SourceLoc) -> Unit {
  parent.box(made_for=loc, fn(r) {
    style_node(r, fn() { meter_line_way }, in_row=true)
    r.shrink(Is(0.0)) |> ignore
    r.each(fn() { Array::makei(meters().length(), fn(i) { i }) }, fn(i) { i }, fn(c, i) {
      let k = i.untracked()
      let m = fn() { meters().get(k) }
      fill_chip_node(
        c,
        fn() { 100 - chip_left(m()) },
        fn() { chip_str(m(), "level") },
        fn() { chip_str(m(), "short") },
        fn() { chip_str(m(), "remaining") },
        said=fn() {
          let note = chip_str(m(), "note")
          match chip_str(m(), "label") {
            "" => ""
            label => label + " " + chip_str(m(), "value") + (if note != "" { " · " + note } else { "" })
          }
        },
        tips?,
      )
      |> ignore
    })
  })
  |> ignore
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
/// Window names and figures in one row when they fit, else by their marks (quota_chips' worded ways). Where even that
/// line does not fit, its lines (quota_chips_lines'): the account's windows a line by their names, each multi-window
/// model pool a line of its own with its group name in a column on the left and its short `[5h │ %] [W │ %]` capsules
/// beside it, what single models have to themselves a line by their marks; a line going on in lines where it must.
/// Pointing at a chip shows its full quota and refill description.
#callsite(autofill(loc))
pub fn quota_worded_node(
  parent : @view.View,
  q : () -> Json?,
  gap? : Double = 8.0,
  tips? : TipLayer,
  loc~ : SourceLoc,
) -> Unit {
  let windows = fn() {
    match chip_field(q(), "windows") {
      Some(Array(a)) => a
      _ => []
    }
  }
  parent.show(fn() { has_quota(q()) }, fn(x) {
    x.by_room(loc~, fn(held, given) {
      // (how wide a line of its chips said `form`'s way stands, `gap` apart: each chip its words' room and theirs)
      let wide = fn(form : Int) {
        let look = @ui.style_words(chip_text)
        let label_look = @ui.style_words(chip_label_text)
        let size = node_sp(held, look.size)
        let fig_w = fn(s : String) { if s == "" { 0.0 } else { node_words_w(s, size, weight=look.weight) } }
        let mark_w = fn(s : String) { if s == "" { 0.0 } else { node_words_w(s, size, weight=label_look.weight) } }
        let side = @ui.Space::S2.px()
        let mut used = 0.0
        for i, w in windows() {
          let (mark, words) = quota_worded(Some(w), form)
          let refill = quota_is_refill(Some(w))
          let chip_w = if refill {
            2.0 * side + (if mark == "" { 0.0 } else { mark_w(mark) + 4.0 }) + 10.5 + 4.0 + fig_w(words)
          } else {
            let between = if mark == "" { 0.0 } else { @ui.Space::S1_25.px() }
            2.0 * side + mark_w(mark) + between + fig_w(words)
          }
          used = used + (if i > 0 { gap } else { 0.0 }) + chip_w
        }
        used
      }
      let form = fn() {
        if wide(1) <= given.width() + 0.01 {
          1
        } else {
          2
        }
      }
      // (where its windows come in pools, on one line where their marks fit it, else on its lines, each pool's under its
      // group's name: both made in its one box, which lays out one of them by the room, a row of chips or a column of
      // lines; an allowance with no pools makes its chips alone, as many nodes as a line of them takes)
      let parts = fn() { quota_parts(windows()) }
      let pooled = fn() { parts().iter().any(fn(p) { p.0 != "" }) }
      let lined = fn() { pooled() && !(wide(2) <= given.width() + 0.01) }
      let part = fn(k : Int) { parts().get(k).unwrap_or(("", [])) }
      let label_w = fn() { nav_quota_label_w(held, parts()) }
      // (a window's key its place among them; a pool's line's, `lines_from` on from its place among the pools)
      let lines_from = 1000
      held.box(fn(r) {
        r
        .row(By(fn() { !lined() }))
        .lines_up(By(fn() { if lined() { Some(Start) } else { Some(Middle) } }))
        .gap(By(fn() { if lined() { @ui.Space::S1_5.px() } else { gap } }))
        .wraps(By(fn() { if lined() { None } else { Some(gap) } }))
        |> ignore
        r.each(
          fn() {
            let ws = Array::makei(windows().length(), fn(i) { i })
            if pooled() {
              ws + Array::makei(parts().length(), fn(k) { lines_from + k })
            } else {
              ws
            }
          },
          fn(i) { i },
          fn(c, i) {
            let i = i.untracked()
            if i < lines_from {
              // (a window as a chip of the line, by its name where the line has the room, else by its mark)
              let w = fn() { windows().get(i) }
              c.laid_nowhere(By(lined)) |> ignore
              fill_chip_node(
                c,
                fn() { chip_left(w()) },
                fn() { chip_str(w(), "level") },
                fn() { quota_worded(w(), form()).0 },
                fn() { quota_figure(w()) },
                label_muted=true,
                refill=fn() { quota_is_refill(w()) },
                said=fn() { quota_said(w()) },
                tips?,
              )
              |> ignore
            } else {
              // (a pool's line: its name in a column as wide as the widest pool's, its short capsules beside it)
              let k = i - lines_from
              c.laid_nowhere(By(fn() { !lined() })).width_share(Is(1.0)) |> ignore
              style_node(c, fn() { quota_chips_part.then(@ui.style(gap=room(gap))) })
              c.show(fn() { part(k).0 != "" }, fn(n) {
                n.box(fn(l) {
                  l.width(By(fn() { Some(label_w()) })).shrink(Is(0.0)) |> ignore
                  words_node(l, fn() { part(k).0 }, fn() { nav_quota_group }) |> ignore
                })
                |> ignore
              })
              c.box(fn(cs) {
                style_node(cs, fn() { quota_chips_row.then(@ui.style(gap=room(gap))) })
                cs.grow(Is(1.0)).min_width(Is(Some(0.0))).wraps(Is(Some(quota_chips_part_lines))) |> ignore
                let ws = fn() { part(k).1 }
                cs.each(fn() { Array::makei(ws().length(), fn(j) { j }) }, fn(j) { j }, fn(d, j) {
                  let j = j.untracked()
                  let w = fn() { ws().get(j) }
                  fill_chip_node(
                    d,
                    fn() { chip_left(w()) },
                    fn() { chip_str(w(), "level") },
                    fn() { quota_line_mark(part(k).0, w()) },
                    fn() { quota_figure(w()) },
                    label_muted=true,
                    refill=fn() { quota_is_refill(w()) },
                    said=fn() { quota_said(w()) },
                    tips?,
                  )
                  |> ignore
                })
              })
              |> ignore
            }
          },
        )
      })
      |> ignore
    })
    |> ignore
  })
}

///|
/// A window's mark on its line of an allowance's lines (quota_chips_lines'): within its pool, less the pool's name
/// (`5h`, `W`); a single model's by its mark (`Fable`); the account's own by its name (`每周`).
fn quota_line_mark(group : String, w : Json?) -> String {
  if group != "" {
    quota_part_mark(group, w)
  } else {
    quota_worded(w, if chip_str(w, "scope") != "" { 2 } else { 1 }).0
  }
}

///|
/// The room an allowance's chips need on one line of a sidebar's row (nav_quota_line's, in node `v`'s tree: its words at
/// the system's size there), as nav_quota_chips_node lays them out: a pool's group's column and its short chips where
/// the windows come in groups, the widest of those; else every chip; 0 where it shows none.
pub fn nav_quota_line_node(v : @view.View, q : Json?) -> Double {
  guard has_quota(q) else { return 0.0 }
  let windows = match chip_field(q, "windows") {
    Some(Array(a)) => a
    _ => []
  }
  let chip = nav_quota_chip_w(v)
  let parts = quota_parts(windows)
  let label_w = nav_quota_label_w(v, parts)
  if label_w > 0.0 {
    return parts.fold(init=0.0, fn(most, p) {
      let mut sum = if p.0 == "" { 0.0 } else { label_w + @ui.Space::S1_5.px() }
      for i, w in p.1 {
        sum += chip(quota_part_mark(p.0, Some(w)), quota_figure(Some(w)), quota_is_refill(Some(w))) +
          (if i > 0 { @ui.Space::S1.px() } else { 0.0 })
      }
      dmax(most, sum)
    })
  }
  let mut sum = 0.0
  for i, w in windows {
    sum += chip(quota_mark(Some(w)), quota_figure(Some(w)), quota_is_refill(Some(w))) +
      (if i > 0 { @ui.Space::S1.px() } else { 0.0 })
  }
  sum
}

///|
/// How wide a small chip of `mark` and `words` is in node `v`'s tree (fill_chip_node's: its words' room and theirs, its
/// mark and figure 5 apart normally or separated by the refresh icon when spent).
fn nav_quota_chip_w(v : @view.View) -> (String, String, Bool) -> Double {
  let look = @ui.style_words(chip_text)
  let label_look = @ui.style_words(chip_label_text)
  let refill_label_look = @ui.style_words(chip_refill_label_text)
  let size = node_sp(v, look.size)
  let fig_w = fn(s : String) { if s == "" { 0.0 } else { node_words_w(s, size, weight=look.weight) } }
  let mark_w = fn(s : String) { if s == "" { 0.0 } else { node_words_w(s, size, weight=label_look.weight) } }
  let refill_mark_w = fn(s : String) { if s == "" { 0.0 } else { node_words_w(s, size, weight=refill_label_look.weight) } }
  fn(mark, words, refill) {
    let side = @ui.Space::S1_25.px()
    let gap = @ui.Space::S1.px()
    let w = if refill {
      2.0 * side + (if mark == "" { 0.0 } else { refill_mark_w(mark) + gap }) + 9.0 + gap + fig_w(words)
    } else {
      let between = if mark == "" || chip_joined(mark, words) { 0.0 } else { @ui.Space::S1_25.px() }
      2.0 * side + mark_w(mark) + between + fig_w(words)
    }
    w.ceil()
  }
}

///|
/// How wide each of an allowance's chips is (`q`'s windows, every one a marked capsule) in node `v`'s tree, and the room
/// all of it needs on one line (nav_quota_line_node): what a sidebar's rows of a provider are laid out by
/// (nav_quota_chips_node's `widest`).
pub fn nav_quota_room_node(v : @view.View, q : Json?) -> (Double, Array[Double]) {
  let windows = match chip_field(q, "windows") {
    Some(Array(a)) => a
    _ => []
  }
  let chip = nav_quota_chip_w(v)
  (nav_quota_line_node(v, q), windows.map(fn(w) { chip(quota_mark(Some(w)), quota_figure(Some(w)), quota_is_refill(Some(w))) }))
}

///|
/// How many lines chips `widths` wide take on lines `room` wide, each as many as its line holds, 4 apart: 1 for none.
fn nav_quota_lines(widths : Array[Double], room : Double) -> Int {
  let gap = @ui.Space::S1.px()
  let mut lines = 1
  let mut used = 0.0
  for cw in widths {
    if used > 0.0 && used + gap + cw > room + 0.01 {
      lines = lines + 1
      used = cw
    } else {
      used = used + (if used > 0.0 { gap } else { 0.0 }) + cw
    }
  }
  lines
}

///|
/// How wide the widest of `parts`' group names is in node `v`'s tree (nav_quota_group's words): 0 where none has one.
fn nav_quota_label_w(v : @view.View, parts : Array[(String, Array[Json])]) -> Double {
  let look = @ui.style_words(nav_quota_group)
  let size = node_sp(v, look.size)
  parts.fold(init=0.0, fn(m, p) { if p.0 == "" { m } else { dmax(m, node_words_w(p.0, size, weight=look.weight).ceil()) } })
}

///|
/// An allowance's chips across a sidebar's row (nav_quota_chips', as a node) in `parent`, `q` as the core says it now:
/// from under the row's mark, every window a marked capsule, all on one line where the room the widest of its
/// provider's rows needs fits (`widest`: that row's nav_quota_room_node, the one whose line is the longest), the same
/// for every row of a provider; else on as many lines as that widest one takes, every row of the provider (the user,
/// 2026-11-13: 「相同供应商的账号用同一种就行」), each line of a row as many of its chips as share them out, a pool's
/// group's name over its chips. Where its windows come
/// in pools, one line has the group's name in a column of its own, its short capsules beside it, a pool a line. Its
/// last capsules as far in from the row's foot corner as makes them concentric with it (the row's `foot_capsule`).
/// Each says what is left of it and when it fills again over it while it is pointed at, in `tips`. `at`: where its
/// row's list stands (its words' room: band_pad_in). Nothing while the core cannot say or there is no window.
#callsite(autofill(loc))
pub fn nav_quota_chips_node(
  parent : @view.View,
  q : () -> Json?,
  at : ListAt,
  widest : () -> (Double, Array[Double]),
  tips? : TipLayer,
  loc~ : SourceLoc,
) -> Unit {
  let windows = fn() {
    match chip_field(q(), "windows") {
      Some(Array(a)) => a
      _ => []
    }
  }
  let parts = fn() { quota_parts(windows()) }
  let inset = @ui.capsule_in(row_corner, fill_chip_small_h)
  let side = band_pad_in(at)
  // (a capsule reaches the corner until it is past the outer corner's circle-equivalent radius)
  let clear = dmax(0.0, inset + fill_chip_small_h / 2.0 - side)
  let pad_y = fn() { dmax(0.0, (theme().chat_list.meta_h - fill_chip_small_h) / 2.0) }
  // (the chips of `ws()`, each the window at its place there, its mark less its pool's name `group()`)
  let chips = fn(r : @view.View, ws : () -> Array[Json], group : () -> String) {
    r.each(fn() { Array::makei(ws().length(), fn(i) { i }) }, fn(i) { i }, fn(c, i) {
      let k = i.untracked()
      // (its window as it is now, told on only as it comes out otherwise: another's changing runs none of this one's)
      let held = @signals.computed(fn(_) { ws().get(k) })
      let w = fn() { held.get() }
      fill_chip_node(
        c,
        fn() { chip_left(w()) },
        fn() { chip_str(w(), "level") },
        fn() { quota_part_mark(group(), w()) },
        fn() { quota_figure(w()) },
        small=true,
        label_muted=true,
        refill=fn() { quota_is_refill(w()) },
        said=fn() { quota_said(w()) },
        tips?,
      )
      |> ignore
    })
  }
  // (the pool at `k` of them as it is now)
  let part = fn(k : Int) { parts().get(k).unwrap_or(("", [])) }
  let part_keys = fn() { Array::makei(parts().length(), fn(k) { k }) }
  parent.show(fn() { has_quota(q()) }, fn(x) {
    // (all of what its line leaves it: the room it is fitted to)
    x.grow(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
    x.by_room(loc~, fn(held, given) {
      // (on one line where the room the widest of its provider's rows needs fits beside the corner's: else on lines)
      let room = fn() { given.width() - (inset - side) - clear }
      let one = fn() { dmax(widest().0, nav_quota_line_node(held, q())) <= room() + 0.01 }
      // (on lines: as many as the widest of its provider's take, each of this row's as many of its chips as share them)
      let per = fn() {
        let n = windows().length()
        if one() {
          n
        } else {
          let lines = nav_quota_lines(widest().1, room())
          dmax(1.0, (n.to_double() / lines.to_double()).ceil()).to_int()
        }
      }
      let label_w = fn() { nav_quota_label_w(held, parts()) }
      held.pick(at_once=true, fn() { label_w() > 0.0 }, fn(b, pooled) {
        b.width_share(Is(1.0)) |> ignore
        if pooled {
          // one line a pool, its name in a column of its own, its short capsules beside it
          b.box(fn(a) {
            a
            .laid_nowhere(By(fn() { !one() }))
            .width_share(Is(1.0))
            .margin(By(fn() { (inset - side, pad_y(), 0.0, pad_y()) }))
            .padding(Is((0.0, 0.0, clear, 0.0)))
            .gap(Is(@ui.Space::px(S1)))
            |> ignore
            a.each(part_keys, fn(k) { k }, fn(p, k) {
              let k = k.untracked()
              p.row(Is(true)).width_share(Is(1.0)).lines_up(Is(Some(Middle))).gap(Is(@ui.Space::px(S1_5))) |> ignore
              p.show(fn() { part(k).0 != "" }, fn(n) {
                n.box(fn(l) {
                  l.width(By(fn() { Some(label_w()) })) |> ignore
                  words_node(l, fn() { part(k).0 }, fn() { nav_quota_group }) |> ignore
                })
                |> ignore
              })
              p.box(fn(r) {
                style_node(r, fn() { quota_chips_row.then(@ui.style(gap=S1)) }, in_row=true)
                chips(r, fn() { part(k).1 }, fn() { part(k).0 })
              })
              |> ignore
            })
          })
          |> ignore
          // on lines: a pool's name over its capsules, each pool's on as many lines as they take
          b.box(fn(a) {
            a
            .laid_nowhere(By(one))
            .width_share(Is(1.0))
            .margin(By(fn() { (inset - side, pad_y(), clear, pad_y()) }))
            .gap(Is(@ui.Space::px(S1)))
            |> ignore
            a.each(part_keys, fn(k) { k }, fn(p, k) {
              let k = k.untracked()
              p.width_share(Is(1.0)).gap(Is(@ui.Space::px(S0_5))) |> ignore
              p.show(fn() { part(k).0 != "" }, fn(n) {
                words_node(n, fn() { part(k).0 }, fn() { nav_quota_group }) |> ignore
              })
              p.box(fn(r) {
                style_node(r, fn() { quota_chips_part.then(@ui.style(gap=S1)) })
                r.wraps(Is(Some(@ui.Space::S1.px()))) |> ignore
                chips(r, fn() { part(k).1 }, fn() { part(k).0 })
              })
              |> ignore
            })
          })
          |> ignore
        } else {
          // every window a marked capsule, on one line where it has the room, else on as many as per() says
          b
          .margin(By(fn() { (inset - side, if one() { 0.0 } else { pad_y() }, clear, if one() { 0.0 } else { pad_y() }) }))
          .gap(Is(@ui.Space::px(S1)))
          |> ignore
          b.each(fn() { Array::makei((windows().length() + per() - 1) / dmax(1.0, per().to_double()).to_int(), fn(i) { i }) }, fn(i) { i }, at_once=true, fn(r, i) {
            let i = i.untracked()
            style_node(r, fn() { quota_chips_part.then(@ui.style(gap=S1)) })
            chips(r, fn() { windows().iter().drop(i * per()).take(per()).collect() }, fn() { "" })
          })
        }
      })
    })
    |> ignore
  })
}
