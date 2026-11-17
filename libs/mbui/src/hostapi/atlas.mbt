// Where glyphs go in a host's atlas (glyph, glyph_put): its square plots, each filled a shelf at a time, left to right
// and top to bottom. Full, the shelf drawn from longest ago that is tall enough is emptied for what comes next and its
// glyphs said gone (a plot emptied whole only for a glyph taller than any such shelf), never one the frame being drawn
// draws from: what is on the screen stays where it is, drawn once, however much comes and goes round it. (Each host
// started its atlas over whole as it filled: every glyph on the screen drawn again in one frame, and its words shaped
// again, a list scrolled through new words stopping a moment each time it did. Till 2026-11-17 a plot was emptied
// whole: 64 of them in an atlas of 4096, a screen of Chinese scrolled through long enough drew from every one, none
// could be emptied, and the atlas started over, 446 glyphs drawn again in one frame. A shelf holds some nine glyphs of
// words where a plot held eighty, packed as tight as before.)

///|
/// A plot's side, in pixels: the largest glyph a host draws (a word of a joining script, an emoji at a large size).
pub let atlas_plot : Int = 512

///|
priv struct Plot {
  x : Int
  y : Int
  // where the room no shelf has taken yet starts, down it
  mut free_y : Int
  // its shelves (Atlas::shelves'), top to bottom
  shelves : Array[Int]
}

///|
priv struct Shelf {
  // its plot, where it starts down it and how tall it is, how far along it is filled
  mut plot : Int
  mut y : Int
  mut h : Int
  mut x : Int
  // the glyphs on it, and the last frame that drew from it
  keys : Array[Int]
  mut drawn : Int
}

///|
/// A host's atlas `side` pixels a side, as its glyphs are placed in it.
pub struct Atlas {
  // its plots' side, and the plots, a row at a time
  priv plot : Int
  priv plots : Array[Plot]
  // the shelves (one of a plot emptied whole, let go: its place taken by the next made, `spare`)
  priv shelves : Array[Shelf]
  priv spare : Array[Int]
  // the shelves being filled, the last opened last (atlas_open_most at most)
  priv opens : Array[Int]
  // the frame being drawn
  priv mut frame : Int
  // what marks what the frame draws from before a shelf is emptied (Atlas::before_full), and the frame it last did
  priv mut before_full : (() -> Unit)?
  priv mut full_frame : Int
}

///|
/// An atlas `side` pixels a side, empty (0: none, nothing placed in it).
pub fn Atlas::new(side : Int) -> Atlas {
  let plot = if side < atlas_plot { side } else { atlas_plot }
  let n = if plot > 0 { side / plot } else { 0 }
  let plots = []
  for j in 0..<n {
    for i in 0..<n {
      plots.push({ x: i * plot, y: j * plot, free_y: 0, shelves: [] })
    }
  }
  { plot, plots, shelves: [], spare: [], opens: [], frame: 0, before_full: None, full_frame: -1 }
}

///|
/// The most shelves filled at once: a glyph goes on the one of them it fits best (the least tall it fits on), so a
/// mark of punctuation goes on a short one and a Han ideograph on a tall one, neither leaving the other's half empty.
let atlas_open_most : Int = 16

///|
/// The next frame begins: what it draws from is kept through it.
pub fn Atlas::next_frame(self : Atlas) -> Unit {
  self.frame = self.frame + 1
}

///|
/// Shelf `plot` (Atlas::place's) drawn from in this frame.
pub fn Atlas::drawn(self : Atlas, plot : Int) -> Unit {
  self.shelves[plot].drawn = self.frame
}

///|
/// `f` asked, once a frame, before a shelf is emptied for what comes next: it says each shelf the frame draws from
/// (Atlas::drawn) that was not said as it was drawn, kept so through the frame. What draws from the atlas frame after
/// frame (what is made once and composed again) need not say so each frame, only when a shelf is to be emptied.
pub fn Atlas::before_full(self : Atlas, f : () -> Unit) -> Unit {
  self.before_full = Some(f)
}

///|
/// Whether it is an atlas at all (one of a side of 0 is none).
pub fn Atlas::sized(self : Atlas) -> Bool {
  !self.plots.is_empty()
}

///|
/// Whether a glyph `w` × `h` pixels has a place in it at all: something to draw, no larger than a plot.
pub fn Atlas::holds(self : Atlas, w : Int, h : Int) -> Bool {
  w > 0 && h > 0 && w <= self.plot && h <= self.plot && !self.plots.is_empty()
}

///|
/// A glyph `w` × `h` pixels (`key`) placed: its shelf and where its top left is, drawn from in this frame; the glyphs
/// of a shelf (or a plot) emptied for it said `gone` first. None when there is no room for it while this frame is drawn
/// (every shelf tall enough drawn from in it, and a plot of each), or none ever (Atlas::holds).
pub fn Atlas::place(self : Atlas, key : Int, w : Int, h : Int, gone : (Int) -> Unit) -> (Int, Int, Int)? {
  if !self.holds(w, h) {
    return None
  }
  let mut at = -1
  let mut at_h = 0
  for i in self.opens {
    let ih = if self.shelves[i].h > h { self.shelves[i].h } else { h }
    if self.fits(i, w, h) && (at < 0 || ih < at_h) {
      at = i
      at_h = ih
    }
  }
  if at < 0 {
    guard self.room(h, gone) is Some(s) else { return None }
    self.opens.push(s)
    if self.opens.length() > atlas_open_most {
      self.opens.remove(0) |> ignore
    }
    at = s
  }
  let s = self.shelves[at]
  let p = self.plots[s.plot]
  // (the last shelf of its plot made as tall as what goes on it)
  if h > s.h {
    s.h = h
    p.free_y = s.y + h + 1
  }
  let x = s.x
  s.x = x + w + 1
  s.keys.push(key)
  s.drawn = self.frame
  Some((at, p.x + x, p.y + s.y))
}

///|
/// Whether a glyph `w` × `h` goes on shelf `i` as it is: along it, as tall as it, or the last of its plot with room
/// under it to be made as tall.
fn Atlas::fits(self : Atlas, i : Int, w : Int, h : Int) -> Bool {
  let s = self.shelves[i]
  let p = self.plots[s.plot]
  s.x + w <= self.plot &&
  (h <= s.h || (p.free_y == s.y + s.h + 1 && s.y + h <= self.plot))
}

///|
/// A shelf for a glyph `h` tall, empty: a new one in a plot's room no shelf has taken (the last opened's plot first);
/// else the one drawn from longest ago as tall as it, emptied (one not much taller first); else a plot drawn from
/// longest ago emptied whole. None of what this frame draws from; None where there is none such.
fn Atlas::room(self : Atlas, h : Int, gone : (Int) -> Unit) -> Int? {
  // room no shelf has taken
  let first = match self.opens.last() {
    Some(i) => self.shelves[i].plot
    None => 0
  }
  for k in 0..<self.plots.length() {
    let pi = (first + k) % self.plots.length()
    let p = self.plots[pi]
    if p.free_y + h <= self.plot {
      let s = self.shelf(pi, p.free_y, h)
      p.shelves.push(s)
      p.free_y = p.free_y + h + 1
      return Some(s)
    }
  }
  // (what the frame draws from said first, once a frame, before anything is emptied: Atlas::before_full)
  match self.before_full {
    Some(f) if self.full_frame != self.frame => {
      self.full_frame = self.frame
      f()
    }
    _ => ()
  }
  // a shelf emptied: drawn from longest ago, of those not much taller than the glyph, else of any tall enough
  let mut best = -1
  let mut fit = false
  for i, s in self.shelves {
    if s.h < h || s.drawn >= self.frame || s.plot < 0 {
      continue
    }
    let close = s.h <= h * 2 + 8
    if best < 0 ||
      (close && !fit) ||
      (close == fit && s.drawn < self.shelves[best].drawn) {
      best = i
      fit = close
    }
  }
  if best >= 0 {
    self.opens.retain(fn(i) { i != best })
    let s = self.shelves[best]
    for k in s.keys {
      gone(k)
    }
    s.keys.clear()
    s.x = 0
    // (the last of its plot gives what is under it back to the plot's room, to be made as tall as what comes)
    let pi = s.plot
    let p = self.plots[pi]
    if p.free_y == s.y + s.h + 1 {
      p.free_y = s.y
      p.shelves.pop() |> ignore
      self.spare.push(best)
      s.plot = -1
      let n = self.shelf(pi, p.free_y, h)
      p.shelves.push(n)
      p.free_y = p.free_y + h + 1
      return Some(n)
    }
    return Some(best)
  }
  // a plot emptied whole: none of its shelves drawn from in this frame, the last drawn from longest ago
  let mut at = -1
  let mut at_last = self.frame
  for pi, p in self.plots {
    let mut last = -1
    for i in p.shelves {
      if self.shelves[i].drawn > last {
        last = self.shelves[i].drawn
      }
    }
    if last < at_last {
      at = pi
      at_last = last
    }
  }
  guard at >= 0 else { return None }
  let p = self.plots[at]
  self.opens.retain(fn(i) { self.shelves[i].plot != at })
  for i in p.shelves {
    let s = self.shelves[i]
    for k in s.keys {
      gone(k)
    }
    s.keys.clear()
    s.plot = -1
    self.spare.push(i)
  }
  p.shelves.clear()
  p.free_y = 0
  let s = self.shelf(at, 0, h)
  p.shelves.push(s)
  p.free_y = h + 1
  Some(s)
}

///|
/// A new shelf, empty, `h` tall, `y` down plot `p`: its index (one let go of taken again where there is one).
fn Atlas::shelf(self : Atlas, p : Int, y : Int, h : Int) -> Int {
  match self.spare.pop() {
    Some(i) => {
      let s = self.shelves[i]
      s.plot = p
      s.y = y
      s.h = h
      s.x = 0
      s.keys.clear()
      s.drawn = -1
      i
    }
    None => {
      self.shelves.push({ plot: p, y, h, x: 0, keys: [], drawn: -1 })
      self.shelves.length() - 1
    }
  }
}

///|
/// Everything placed let go (what the host drew is gone: atlas_generation).
pub fn Atlas::clear(self : Atlas) -> Unit {
  for p in self.plots {
    p.free_y = 0
    p.shelves.clear()
  }
  self.shelves.clear()
  self.spare.clear()
  self.opens.clear()
}
