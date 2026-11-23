// Where lines under a marked line start (Tester::line_start_faults), measured on the frame just built as the first
// line's rule is (first_line.mbt): in a column whose first line leads with a mark (an icon, a logo) and its words after
// it, each line under it (a note, a state, a row of chips) starts where the mark does or where those words do, never
// between the two (a profile's row in 设置, its state line from the row's padding, under the middle of its logo: 「感觉
// 这个对齐有点问题」, which no check said, 2026-11-15). Where a line starts: the left of what it shows, its words as
// they are drawn, a ground or a drawing by its box, what is laid over it as a layer too (a station's offline picture
// and its line, laid over the room of the figures it has not). A mark: what first_line.mbt holds one to be, as large
// as `line_start_mark_most` (a card's 28 mark: a station's, a device's, never held to it till 2026-11-15, a Station
// card's lines reported as missed). A mark's start is its box's, as the layout lays it, a line within
// `line_start_near` after it under it: an icon's own margin in its box (a 28 server's ink 2.3 in) and a tile reaching
// out to be concentric with what holds it (an agent's card's, 2 out) are no line's fault. Each fault a line naming the
// line, where it starts, and the mark's and the words' starts over it.

///|
/// How large a mark leading a line is at most, either way, to be held to the rule (a card's 28 mark, an avatar's 40):
/// larger than first_line.mbt's, whose rule a tile beside lines would break on purpose.
let line_start_mark_most : Double = 40.0

///|
/// How far after a mark's start a line under it may start and still be under it (see the file's head).
let line_start_near : Double = 2.5

///|
/// Where the last frame breaks the rule of where lines start (see the file's head): one line for each line under a
/// marked line that starts between its mark and its words, the window's tree's nodes among the frame's as drawn
/// (Ctx::with_tree_nodes `facts`).
pub fn Tester::line_start_faults(self : Tester) -> Array[String] {
  self.reads_own()
  ignore(self)
  let c = g()
  c.with_tree_nodes(facts=true, fn() { c.line_start_faults() })
}

///|
fn Ctx::line_start_faults(self : Ctx) -> Array[String] {
  let out : Array[String] = []
  let n = self.count
  let (whole, layer) = self.shown_whole()
  let kids : Array[Array[Int]] = Array::makei(n, fn(_) { [] })
  for i in 0..<n {
    let p = self.nodes[i].parent
    if p >= 0 && p < n {
      kids[p].push(i)
    }
  }
  let worded = Array::make(n, false)
  for i in 0..<n {
    if whole[i] && self.first_line_words(i) {
      let mut k = i
      while k >= 0 && k < n && !worded[k] {
        worded[k] = true
        k = self.nodes[k].parent
      }
    }
  }
  let aside = fn(i : Int) {
    let b = self.nodes[i]
    b.layer || b.portal || b.placed_at() || b.moved_off() || b.opacity <= 0.01
  }
  // (where what `i` shows starts: its words as drawn, a drawing or a ground by its box; None where it shows nothing)
  let start = fn(i : Int) -> Double? {
    let mut x = 1.0e9
    let todo = [i]
    while todo.pop() is Some(k) {
      // (what is laid over a line as a layer shows there as much: only what is put elsewhere is not the line's)
      let b = self.nodes[k]
      if !whole[k] || b.portal || b.placed_at() || b.moved_off() || b.opacity <= 0.01 {
        continue
      }
      if self.first_line_words(k) {
        x = dmin(x, self.gap_drawn(k).0)
      } else if self.first_line_draws(k) {
        x = dmin(x, self.nodes[k].x)
      }
      for ch in kids[k] {
        todo.push(ch)
      }
    }
    if x < 1.0e8 {
      Some(x)
    } else {
      None
    }
  }
  // (whether `a` is a mark: it holds no words, draws, none of it pressed on its own, as large as a mark at most)
  let mark_of = fn(a : Int) -> Bool {
    if worded[a] {
      return false
    }
    let mut drew = false
    let todo = [a]
    while todo.pop() is Some(k) {
      let d = self.nodes[k]
      if d.hit && !d.points {
        return false
      }
      if whole[k] && self.first_line_draws(k) {
        if d.fw > line_start_mark_most + height_slack || d.fh > line_start_mark_most + height_slack {
          return false
        }
        drew = true
      }
      for ch in kids[k] {
        todo.push(ch)
      }
    }
    drew
  }
  for p in 0..<n {
    let pn = self.nodes[p]
    if !worded[p] || !whole[p] || pn.dir != Column || kids[p].length() < 2 {
      continue
    }
    let lines = kids[p].filter(fn(k) { whole[k] && !aside(k) && layer[k] == layer[p] })
    // (its first line: the first that shows, a row leading with a mark and words after it)
    let mut head = -1
    let mut top = 1.0e9
    for k in lines {
      if self.nodes[k].y < top && start(k) is Some(_) {
        top = self.nodes[k].y
        head = k
      }
    }
    if head < 0 || self.nodes[head].dir != Row || !worded[head] {
      continue
    }
    let parts = kids[head].filter(fn(k) { whole[k] && !aside(k) && layer[k] == layer[p] && start(k) is Some(_) })
    parts.sort_by(fn(a, b) { self.nodes[a].x.compare(self.nodes[b].x) })
    if parts.length() < 2 || !mark_of(parts[0]) || !worded[parts[1]] {
      continue
    }
    let (mark, words) = (parts[0], parts[1])
    let (mx, wx) = (start(mark).unwrap(), start(words).unwrap())
    // (a line laid from the column's start, its mark there or reaching out past it: lines centred in what holds them,
    // a button's icon and words over another button's, start where their own widths have them)
    if wx - mx <= 2.0 * gap_slack || mx > pn.x + pn.pad_l + gap_slack {
      continue
    }
    let hn = self.nodes[head]
    for k in lines {
      if k == head || self.nodes[k].y < hn.y + hn.fh - gap_slack {
        continue
      }
      guard start(k) is Some(x) else { continue }
      if x > mx + line_start_near && x < wx - gap_slack {
        out.push(
          "line start: \{self.named(k)} starts at \{(x * 10.0).round() / 10.0}, between the mark \{self.named(mark)} (at \{(mx * 10.0).round() / 10.0}) and the words \{self.named(words)} (at \{(wx * 10.0).round() / 10.0}) on the line over it, in \{self.named(p)}",
        )
      }
    }
  }
  out
}
