// What a node holds revealed in the paint (View::spatial_reveal): each thing it draws (a glyph, a list's mark, a quote's
// bar, a rule, a code block's ground, a picture) faded in as it rises into place at its own turn, read in the order its
// place in what shows says: a line at a time down what shows of it, and along each line. Worked on what the paint puts
// out for it (ui's Ctx::view_paint), nothing of it made, laid out or measured again: what its words were made into is
// drawn as kept, each frame of its way; once its way is over, nothing of it at all. What is out of sight is there at
// once, and asks for no frame.

///|
/// How a node's holdings are revealed (View::spatial_reveal), as the paint reads it: from the moment `start_at` (none
/// before it: less than 0, or not a number), `end_at` the moment all of it is in at most; how long a line's reading
/// takes (`line_ms`, less where more lines show: all of them within `screen_most_ms`), a line's height for that
/// (`line_points`), how long each thing takes to come in (`glyph_ms`), how far before or after its turn a glyph may be
/// (`jitter_ms`), how far each rises (`rise_px`, points), which reveal it is (`salt`: the same each time); `span`: the
/// stretch down the window all of it takes, one reveal across the several nodes it is drawn in (View::list_item_span),
/// none its own box.
pub(all) struct SpatialReveal {
  start_at : Double
  end_at : Double
  line_ms : Double
  screen_most_ms : Double
  line_points : Double
  glyph_ms : Double
  jitter_ms : Double
  rise_px : Double
  salt : Int
  span : (() -> (Double, Double)?)?
}

///|
/// What it holds (its own drawing with it) revealed from moment `start_at` on, as that says it now (less than 0 or not
/// a number: shown as it is): each thing drawn faded in from nothing as it rises `rise_px` into place, at its turn in
/// the order what shows of it is read in, a line (`line_points` tall) every `line_ms`, all that shows within
/// `screen_most_ms` (each line shorter where more show), then each over `glyph_ms`; each glyph a little before or after
/// its turn (up to half of `jitter_ms`) and rising a little more or less, by `salt` (the same each time); what is not a
/// glyph (a mark, a bar, a ground) at its top's turn, as the words beside it. What is out of sight is there at once.
/// `span`: the stretch down the window (top, foot) its reveal reads across, where it is drawn in several nodes (a page's
/// list's slices of one key: View::list_item_span), one reading across them all. Paint's: nothing laid out, made or
/// measured again for it, its words drawn as kept, and asking for frames only while what shows of it comes in.
#callsite(autofill(loc))
pub fn View::spatial_reveal(
  self : View,
  start_at : Live[Double],
  line_ms? : Double = 120.0,
  screen_most_ms? : Double = 500.0,
  line_points? : Double = 22.0,
  glyph_ms? : Double = 220.0,
  jitter_ms? : Double = 50.0,
  rise_px? : Double = 6.0,
  salt? : Live[Int] = Is(7),
  span? : () -> (Double, Double)?,
  loc~ : SourceLoc,
) -> View {
  guard self.live() is Some(_) else { return self }
  let tree = self.tree
  let at = self.at
  let gen = self.gen
  let told : Live[(Double, Int)] = match (start_at, salt) {
    (Is(a), Is(b)) => Is((a, b))
    (a, b) =>
      By(fn() {
        (
          match a {
            Is(v) => v
            By(f) => f()
          },
          match b {
            Is(v) => v
            By(f) => f()
          },
        )
      })
  }
  self.bind(loc~, Reveals, told, Paint, fn(t) {
    let (start, salt) = t
    if !(start >= 0.0) {
      tree.reveals.remove(at)
      return
    }
    tree.reveals[at] = (
      gen,
      {
        start_at: start,
        end_at: start + screen_most_ms + line_ms + jitter_ms / 2.0 + glyph_ms,
        line_ms,
        screen_most_ms,
        line_points,
        glyph_ms,
        jitter_ms,
        rise_px,
        salt,
        span,
      },
    )
  })
  self.owns(fn() {
    match tree.reveals.get(at) {
      Some((g, _)) if g == gen => tree.reveals.remove(at)
      _ => ()
    }
  })
  |> ignore
  self
}

///|
/// How node `id` reveals what it holds, where it says it does (View::spatial_reveal) and its way is not over at moment
/// `now`; none else (none said, said none, over, or the node gone).
pub fn Tree::spatial_reveal_of(self : Tree, id : NodeId, now : Double) -> SpatialReveal? {
  guard !self.reveals.is_empty() else { return None }
  match self.reveals.get(id.at) {
    Some((g, r)) if g == id.gen && now < r.end_at => Some(r)
    _ => None
  }
}

///|
/// Whether any node says it reveals what it holds (View::spatial_reveal), over or not: none, the paint looks for none.
pub fn Tree::reveals_any(self : Tree) -> Bool {
  !self.reveals.is_empty()
}

///|
/// A number from 0 to 1 for thing `i` of reveal `salt`, the same each time (a hash: no chance in it).
pub fn reveal_noise(i : Int, salt : Int) -> Double {
  let mut h = (i * 374761393 + salt * 668265263).reinterpret_as_uint()
  h = (h ^ (h >> 13)) * 1274126177U
  h = h ^ (h >> 16)
  (h & 0xFFFFU).reinterpret_as_int().to_double() / 65535.0
}

///|
/// Whether node `id` reveals what it holds, or holds one that does (View::spatial_reveal), its way not over at moment
/// `now`: what is drawn of it changes frame by frame meanwhile, so nothing of it is kept drawn and moved whole (a page's
/// list's row, its list drawn as one).
pub fn Tree::reveal_in(self : Tree, id : NodeId, now : Double) -> Bool {
  if self.reveals.is_empty() {
    return false
  }
  for at, e in self.reveals {
    let (gen, r) = e
    if now >= r.end_at {
      continue
    }
    let rid : NodeId = { at, gen }
    if rid == id || self.holds_in_order(id, rid) {
      return true
    }
  }
  false
}

///|
/// Whether the node at `at` (made `gen`) reveals what it holds and its reveal is not yet begun by the clock as it shows:
/// none of it seen (Tree::each_drawn_in_order, Tree::drawn_one), as the paint draws none of it.
fn Tree::reveal_waits(self : Tree, at : Int, gen : Int) -> Bool {
  match self.reveals.get(at) {
    Some((g, r)) if g == gen => self.clock.untracked() <= r.start_at
    _ => false
  }
}
