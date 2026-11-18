// What a search found as nodes of the window's tree (marked.mbt's found_line): the words found in a line marked, bold
// in the ink, and a hand-drawn stroke under each (stroke.mbt), drawn in one after another as the line comes.

///|
/// A found line (found_line's, as nodes) in `parent`: `text()` on one line cut at its end, in `style()`, the words
/// found (`marks()`) in `ink()` and bold, a hand-drawn stroke in the accent under each, where its words are drawn on
/// their one line (by the room the line is given, View::by_room: their widths as drawn, nothing read back of the
/// layout), drawn in from the left one after another as the line is made (strokes_ms: 520 ms each, one 180 ms after the
/// other). A mark past where the line is cut has none. The node that holds them.
#callsite(autofill(loc))
pub fn found_words_node(
  parent : @view.View,
  text : () -> String,
  marks : () -> Array[(Int, Int)],
  style : () -> @ui.TextStyle,
  ink : () -> Int64,
  loc~ : SourceLoc,
) -> @view.View {
  // (the marks that lie in the text, in order, none over another)
  let kept = fn() {
    let t = text()
    let out : Array[(Int, Int)] = []
    let mut at = 0
    for m in marks() {
      let (from, to) = m
      if from < at || to > t.length() || from > to {
        continue
      }
      out.push(m)
      at = to
    }
    out
  }
  let runs = fn() -> Array[@text.Run] {
    let t = text()
    let out : Array[@text.Run] = []
    let mut at = 0
    let k = ink()
    for m in kept() {
      let (from, to) = m
      out.push(@ui.span(t.clamped_view(start=at, end=from).to_owned()))
      out.push(@ui.span(t.clamped_view(start=from, end=to).to_owned(), weight=600, color=k))
      at = to
    }
    out.push(@ui.span(t.clamped_view(start=at).to_owned()))
    out
  }
  // (its strokes drawn in as it is made: one way over all of them, from the moment it is made)
  let drawn = @motion.NodeWay::new(0.0)
  parent.box(made_for=loc, fn(o) {
    o.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
    o.by_room(loc~, fn(held, given) {
      let w = held.box(fn(w) {
        w
        .words_runs(By(runs))
        .words_look(By(fn() { @ui.style_words(style()) }))
        .ink(By(fn() { @ui.style_ink(style()) }))
        .cuts(Is(true))
        .allow_ellipsis(Is(true))
        .min_width(Is(Some(0.0)))
        |> ignore
      })
      // (again as what it marks changes: its strokes drawn in anew)
      w.reacts(fn() { (text(), kept()) }, fn(now) {
        let total = strokes_ms(now.1.length())
        drawn.put(0.0)
        if now.1.length() > 0 {
          drawn.go_ms(w, total, total, ease=Linear)
        }
      })
      // (how wide a part of the words is drawn on their one line: the marked ones bold, at the line's size as the
      // system's size of words has them)
      let across = fn(from : Int, to : Int) {
        let look = @ui.style_words(style())
        let size = node_sp(held, look.size)
        let t = text()
        let mut x = 0.0
        let mut at = from
        for m in kept() {
          let (mf, mt) = m
          if mt <= at || mf >= to {
            continue
          }
          if mf > at {
            x = x + node_words_w(t.clamped_view(start=at, end=mf).to_owned(), size, weight=look.weight)
          }
          let e = if mt < to { mt } else { to }
          x = x + node_words_w(t.clamped_view(start=if mf > at { mf } else { at }, end=e).to_owned(), size, weight=600)
          at = e
        }
        if at < to {
          x = x + node_words_w(t.clamped_view(start=at, end=to).to_owned(), size, weight=look.weight)
        }
        x
      }
      // a stroke under each mark, where its words are drawn on their line (none past where the line is cut short):
      // its top left `stroke_corner` up and left of where it starts, 3 under the baseline, 2 past either end of the words
      let (cx, cy) = stroke_corner(line_stroke)
      held.each(fn() { Array::makei(kept().length(), fn(i) { i }) }, fn(i) { i }, at_once=true, fn(s, i) {
        let i = i.untracked()
        let range = fn() { kept().get(i).unwrap_or((0, 0)) }
        let start = fn() { across(0, range().0) }
        let wide = fn() { across(range().0, range().1) + 4.0 }
        // (whole within the line's room: a mark cut short by its ellipsis, or past it, has none)
        let shown = fn() { start() + wide() - 2.0 <= given.width() - node_words_w("…", node_sp(s, @ui.style_words(style()).size)) }
        let under = fn() {
          let look = @ui.style_words(style())
          let size = node_sp(s, look.size)
          let line = if look.line < 0.0 { -look.line * size } else { node_sp(s, look.line) }
          @ui.line_baseline(line, size~) + 3.0 - cy
        }
        s
        .over(Is(true))
        .offset(By(fn() { (start() - 2.0 - cx, under()) }))
        .width(By(fn() { Some(wide() + line_stroke.width) }))
        .height(Is(Some(cy + dmax(dmax(0.0, line_stroke.up), dmax(line_stroke.down, line_stroke.end)) + line_stroke.width / 2.0)))
        .lines(By(fn() {
          let part = stroke_part(drawn.shown(s), i)
          if part <= 0.0 || !shown() {
            []
          } else {
            let pts = stroke_points(line_stroke, wide()).map(fn(p) { (p.0 + cx, p.1 + cy) })
            [@ui.line(pts, width=line_stroke.width, color=theme().p.accent, upto=dmin(part, 1.0))]
          }
        }))
        |> ignore
      })
    })
    |> ignore
  })
}

///|
/// The keys of a search's list where it is up (the keymap's own, never changed): ↓ and ↑ where it has no line to choose,
/// taken all the same by what holds it (sfpages' finder_keys_node), nothing of them the field's; where it has, its
/// combobox's first (combobox_bindings: sfpages' finder_combobox_node, ⌘K's and the search's page's).
pub fn finder_bindings() -> Array[@view.Binding] {
  [
    { keys: [{ code: @ui.key_code_down, mods: 0 }], action: "finder.down", when: In("Finder") },
    { keys: [{ code: @ui.key_code_up, mods: 0 }], action: "finder.up", when: In("Finder") },
  ]
}
