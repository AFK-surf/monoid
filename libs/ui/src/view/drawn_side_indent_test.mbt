// What is set in at its start (a column's padding at its left, a node's margin at its left) and reaches its end (a
// row's short time at its right, a card as wide as what is left) grows from its start, not its end (Pivot's
// DrawnSide: the room what it draws is laid out in, Tree::drawn_room_of; how each thing drawn is laid,
// Tree::laid_side): an indent is no room of what is drawn, and a thing at a row's end beside a spacer is no end it is
// laid from while the row is laid from its start. A row whose first drawing sits a few points into its box (an icon
// centred in a box wider than it) keeps that first drawing's left edge. What is laid at an end (a bubble at a column's
// end, a row laid at its end, a bubble beside a spacer growing before it) keeps its right edge. Coming as a key of a
// page's list, opening and shutting under it (View::show), at every look 10 ms apart, in one jump and at 60, 120, 24
// and 7 a second, on no grid and on 3 pixels a point, within half a point.

///|
/// How what is drawn is laid out: rows set in at their start with a short time at their right; an icon in a box wider
/// than it, a title and a time at the row's right; a card as wide as what is left past an indent at its start; a
/// bubble at a column's end, at the end of a row laid at its end, beside a spacer growing before it.
priv enum IndentCase {
  DsiStepRows
  DsiIconRow
  DsiIndentCard
  DsiBubbleColumnEnd
  DsiBubbleRowEnd
  DsiBubbleSpacer
}

///|
/// How it shows: as a key of a page's list coming at its foot, opening under one (View::show), shutting under one.
priv enum IndentWay {
  DsiComes
  DsiOpens
  DsiShuts
}

///|
/// The ground of the icon, of the card, of the bubble.
let dsi_icon : Int64 = 0x3366CCFFL

///|
let dsi_card : Int64 = 0xEEEEEEFFL

///|
let dsi_bubble : Int64 = 0xDDDDDDFFL

///|
/// Words of several lines in a card 260 wide: forty of one width, twenty to a line.
let dsi_lines : String = "一二三四五六七八九十一二三四五六七八九十一二三四五六七八九十一二三四五六七八九十"

///|
/// One row of a step: its words at its start, a spacer growing, its time at its end.
fn dsi_step(v : @view.View, words : String) -> Unit {
  v.box(fn(r) {
    r.row(Is(true)) |> ignore
    r.box(fn(t) { t.words(Is(words)) |> ignore }) |> ignore
    r.box(fn(s) { s.grow(Is(1.0)) |> ignore }) |> ignore
    r.box(fn(t) { t.words(Is("4.2s")) |> ignore }) |> ignore
  })
  |> ignore
}

///|
/// A bubble as wide as its words.
fn dsi_bubble_in(v : @view.View) -> Unit {
  v.box(fn(w) { w.ground(Is(dsi_bubble)).padding(Is((8.0, 8.0, 8.0, 8.0))).words(Is("气泡")) |> ignore }) |> ignore
}

///|
/// `v` laid out as `how` says.
fn dsi_lay(v : @view.View, how : IndentCase) -> Unit {
  match how {
    DsiStepRows => {
      v.padding(Is((20.0, 4.0, 0.0, 4.0))) |> ignore
      dsi_step(v, "第一步")
      dsi_step(v, "第二步")
    }
    DsiIconRow => {
      v.row(Is(true)) |> ignore
      v.box(fn(i) {
        i.width(Is(Some(20.0))).height(Is(Some(20.0))).padding(Is((3.0, 3.0, 3.0, 3.0))) |> ignore
        i.box(fn(s) { s.width(Is(Some(14.0))).height(Is(Some(14.0))).ground(Is(dsi_icon)) |> ignore }) |> ignore
      })
      |> ignore
      v.box(fn(t) { t.words(Is("标题")) |> ignore }) |> ignore
      v.box(fn(s) { s.grow(Is(1.0)) |> ignore }) |> ignore
      v.box(fn(t) { t.words(Is("4.2s")) |> ignore }) |> ignore
    }
    DsiIndentCard => {
      v.padding(Is((20.0, 4.0, 0.0, 4.0))) |> ignore
      v.box(fn(c) {
        c.ground(Is(dsi_card)).padding(Is((8.0, 8.0, 8.0, 8.0))) |> ignore
        c.box(fn(t) { t.words(Is("短短的话")) |> ignore }) |> ignore
        c.box(fn(t) { t.words(Is(dsi_lines)) |> ignore }) |> ignore
      })
      |> ignore
    }
    DsiBubbleColumnEnd => {
      v.lines_up(Is(Some(End))) |> ignore
      dsi_bubble_in(v)
    }
    DsiBubbleRowEnd => {
      v.row(Is(true)).lies_along(Is(@view.Lies::End)) |> ignore
      dsi_bubble_in(v)
    }
    DsiBubbleSpacer => {
      v.row(Is(true)) |> ignore
      v.box(fn(s) { s.grow(Is(1.0)) |> ignore }) |> ignore
      dsi_bubble_in(v)
    }
  }
}

///|
/// A page's list 300 by 400 on grid `g`, rows 0 to 9 (40 each), following its foot; key 72 laid out as `how` says: as
/// it comes (`DsiComes`: not there yet), or under its title, shown while `open` holds. Drawn once, at 0.
fn dsi_case(
  g : Double,
  how : IndentCase,
  way : IndentWay,
  open : @signals.Signal[Bool],
) -> (@view.Tree, @signals.Signal[Array[Int]]) {
  let first = Array::makei(10, fn(i) { i })
  if !(way is DsiComes) {
    first.push(72)
  }
  let keys = @signals.signal(first, same=fn(a, b) { a == b })
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(300.0))).height(Is(Some(400.0))) |> ignore
      o.scrolls_window(@view.Scroll::list(), fn() { keys.get() }, est=40.0, follows=fn() { true }, fn(b, k) {
        if k == 72 {
          match way {
            DsiComes => dsi_lay(b, how)
            _ => {
              b.box(fn(t) { t.height(Is(Some(24.0))).words(Is("标题行")) |> ignore }) |> ignore
              b.show(fn() { open.get() }, fn(v) { dsi_lay(v, how) })
            }
          }
        } else {
          b.height(Is(Some(40.0))).words(Is("行\{k}")) |> ignore
        }
      })
      |> ignore
    })
    |> ignore
  })
  if g > 0.0 {
    tree.set_rows_grid(g)
  }
  tree.frame(390.0, 844.0) |> ignore
  (tree, keys)
}

///|
/// Where the side `how` is laid from is drawn now: the first step's words' left edge, the icon's, the card's, the
/// bubble's right edge; rc_none where it is not seen.
fn dsi_at(tree : @view.Tree, how : IndentCase) -> Double {
  for d in tree.drawn() {
    guard d.alpha > 0.0 else { continue }
    match how {
      DsiStepRows if d.words == "第一步" => return d.x
      DsiIconRow if d.ground == dsi_icon => return d.x
      DsiIndentCard if d.ground == dsi_card => return d.x
      DsiBubbleColumnEnd | DsiBubbleRowEnd | DsiBubbleSpacer if d.ground == dsi_bubble => return d.x + d.w
      _ => ()
    }
  }
  rc_none
}

///|
/// Where `how` rests: the indent's 20, the icon's 3 in its box, the list's right edge.
fn dsi_rest(how : IndentCase) -> Double {
  match how {
    DsiStepRows | DsiIndentCard => 20.0
    DsiIconRow => 3.0
    _ => 300.0
  }
}

///|
/// What `how` and `way` are, for a fault's words.
fn dsi_name(how : IndentCase, way : IndentWay) -> String {
  let what = match how {
    DsiStepRows => "rows set in at their start, a time at their right"
    DsiIconRow => "an icon a few points into its box, a title, a time at the row's right"
    DsiIndentCard => "a card as wide as what is left past an indent at its start"
    DsiBubbleColumnEnd => "a bubble at a column's end"
    DsiBubbleRowEnd => "a bubble in a row laid at its end"
    DsiBubbleSpacer => "a bubble beside a spacer growing before it"
  }
  let how_shown = match way {
    DsiComes => "coming as a key"
    DsiOpens => "opening under a key"
    DsiShuts => "shutting under a key"
  }
  "\{what}, \{how_shown}"
}

///|
/// The faults of `hows` shown each `way`: where each look draws the side it is laid from off where it rests by more than
/// half a point (each case's first said, all run).
fn dsi_faults(hows : Array[IndentCase]) -> Array[String] {
  let faults : Array[String] = []
  for g in [0.0, 3.0] {
    for how in hows {
      for way in [DsiComes, DsiOpens, DsiShuts] {
        for rate in rc_rates {
          let open = @signals.signal(way is DsiShuts)
          let (tree, keys) = dsi_case(g, how, way, open)
          let looks = []
          let mut at = rc_at - rc_look_ms
          while at <= rc_at + @flex.move_most_ms + 100.0 {
            looks.push(at)
            at = at + rc_look_ms
          }
          let told = fn() {
            match way {
              DsiComes => {
                let more = Array::makei(10, fn(i) { i })
                more.push(72)
                keys.set(more)
              }
              DsiOpens => open.set(true)
              DsiShuts => open.set(false)
            }
          }
          let seen = rc_walk(tree, [(rc_at, told)], looks, rate, fn() { dsi_at(tree, how) })
          let rest = if way is DsiShuts { seen[0] } else { seen[seen.length() - 1] }
          let what = "\{dsi_name(how, way)}, grid \{g}, at \{rate} a second"
          if rest == rc_none {
            faults.push("\{what}: not drawn at rest")
            continue
          }
          if (rest - dsi_rest(how)).abs() > 0.5 {
            faults.push("\{what}: rests at \{rest}, \{dsi_rest(how)} wanted")
            continue
          }
          for i, m in seen {
            guard m != rc_none && (m - rest).abs() > 0.5 else { continue }
            faults.push("\{what}, look \{i}: its side at \{m}, \{rest} at rest")
            break
          }
        }
      }
    }
  }
  faults
}

///|
test "what is set in at its start and reaches its end (a time at a row's right, a card as wide as what is left) grows from its start as it comes, opens and shuts under a page's list; an icon a few points into its box keeps its left edge; at every look" {
  let faults = dsi_faults([DsiStepRows, DsiIconRow, DsiIndentCard])
  assert_true(faults.is_empty(), msg=faults.join("\n"))
}

///|
test "what is laid at an end (a bubble at a column's end, in a row laid at its end, beside a spacer before it) keeps its right edge as it comes, opens and shuts under a page's list; at every look" {
  let faults = dsi_faults([DsiBubbleColumnEnd, DsiBubbleRowEnd, DsiBubbleSpacer])
  assert_true(faults.is_empty(), msg=faults.join("\n"))
}

///|
/// A column 300 wide, its lines laid at `side`, holding a box hugging one short line of words set in from its start by
/// `margin` (their margin at their left) or `pad` (the box's padding at its left), the words scaled by `s` about
/// DrawnSide(0.0). Drawn once at 0.
fn dsi_held(side : @view.Along, margin : Double, pad : Double, s : @signals.Signal[Double]) -> @view.Tree {
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(300.0))).lines_up(Is(Some(side))) |> ignore
      o.box(fn(h) {
        h.padding(Is((pad, 0.0, 0.0, 0.0))) |> ignore
        h.box(fn(w) {
          w.margin(Is((margin, 0.0, 0.0, 0.0))).words(Is("刚刚")).scale(By(fn() { s.get() }), about=DrawnSide(0.0))
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  tree.frame(390.0, 844.0) |> ignore
  tree
}

///|
test "DrawnSide, a short line set in from its start by its margin in a box hugging it, at a column's start: grown about its start" {
  for pad in [0.0, 20.0] {
    let margin = 20.0 - pad
    let s = @signals.signal(1.0, same=fn(a, b) { a == b })
    let t = dsi_held(Start, margin, pad, s)
    let (x0, _) = phs_across(t)
    assert_true((x0 - 20.0).abs() < 0.5, msg="刚刚 starts at \{x0} at rest, 20 wanted")
    s.set(0.5)
    t.frame(390.0, 844.0) |> ignore
    let (x, e) = phs_across(t)
    assert_true((x - x0).abs() < 0.5, msg="margin \{margin}, padding \{pad}: 刚刚 drawn \{x} to \{e} at half its size: its start moved from \{x0}")
  }
}

///|
test "DrawnSide, a short line set in from its start by its margin in a box hugging it, at a column's end: grown about its end" {
  for pad in [0.0, 20.0] {
    let margin = 20.0 - pad
    let s = @signals.signal(1.0, same=fn(a, b) { a == b })
    let t = dsi_held(End, margin, pad, s)
    let (_, e0) = phs_across(t)
    assert_true((e0 - 300.0).abs() < 0.5, msg="刚刚 ends at \{e0} at rest, 300 wanted")
    s.set(0.5)
    t.frame(390.0, 844.0) |> ignore
    let (x, e) = phs_across(t)
    assert_true((e - e0).abs() < 0.5, msg="margin \{margin}, padding \{pad}: 刚刚 drawn \{x} to \{e} at half its size: its end moved from \{e0}")
  }
}

///|
test "DrawnSide, a ground filling the window but a gutter at its end (its margin, or a box's padding round it): grown about its start" {
  for gutter_by_margin in [true, false] {
    let s = @signals.signal(1.0, same=fn(a, b) { a == b })
    let t = @view.Tree::new(fn(root) {
      root.box(fn(o) {
        // (as wide as the window, 390: no column further out with room to spare, its side from its gutter alone)
        let block = fn(b : @view.View) {
          b.box(fn(g) {
            if gutter_by_margin {
              g.margin(Is((0.0, 0.0, 20.0, 0.0))) |> ignore
            }
            g.height(Is(Some(20.0))).ground(Is(dsi_card)).scale(By(fn() { s.get() }), about=DrawnSide(0.0)) |> ignore
          })
          |> ignore
        }
        if gutter_by_margin {
          block(o)
        } else {
          o.box(fn(h) {
            h.padding(Is((0.0, 0.0, 20.0, 0.0))) |> ignore
            block(h)
          })
          |> ignore
        }
      })
      |> ignore
    })
    t.frame(390.0, 844.0) |> ignore
    let at = fn() {
      match t.drawn().filter(fn(d) { d.ground == dsi_card }) {
        [d, ..] => (d.x, d.x + d.w)
        _ => (-1.0, -1.0)
      }
    }
    let (x0, e0) = at()
    let what = if gutter_by_margin { "its margin" } else { "a box's padding" }
    assert_true(x0.abs() < 0.5 && (e0 - 370.0).abs() < 0.5, msg="\{what}: drawn \{x0} to \{e0} at rest, 0 to 370 wanted")
    s.set(0.5)
    t.frame(390.0, 844.0) |> ignore
    let (x, e) = at()
    assert_true((x - x0).abs() < 0.5, msg="\{what}: drawn \{x} to \{e} at half its size: its start moved from \{x0}")
  }
}
