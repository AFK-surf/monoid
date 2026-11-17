// Where a node is seen in the window now, for what an app draws flying from it or back into it on its own nodes (a
// picture's viewer over the window, whose way in and out is its own, not a View::shared pair): what of it is seen cut by
// what holds it alone (Tree::seen_bounds), what covers what scrolls it said apart (`clear`), read where what draws the
// flight is drawn.

///|
/// A node as it is seen in the window (View::seen_place): its box (View::rect), the part of it seen (cut by what holds
/// it and its layer, not by what lies over what scrolls it: that is `clear`'s), None where
/// none of it is; and where the column that scrolls it nearest leaves things clear (under what covers its top, over
/// its pinned foot: Scroll::top_covered, foot_hides_now), None where none scrolls it.
pub(all) struct SeenPlace {
  box : (Double, Double, Double, Double)
  seen : (Double, Double, Double, Double)?
  clear : (Double, Double)?
}

///|
/// Where it is seen in the window now (SeenPlace), as it was last laid out and as what scrolls it is now: None where it
/// is let go of, held by none from the root (put by), placed by no layout, of no size, or wholly outside the window.
pub fn View::seen_place(self : View) -> SeenPlace? {
  guard self.live() is Some(n) && n.placed && self.tree.attached(self.at) && self.tree.held_from_root(self.at) else {
    return None
  }
  let (x, y, w, h) = self.rect()
  guard w > 0.0 && h > 0.0 else { return None }
  let (ww, wh) = self.window()
  guard x < ww && x + w > 0.0 && y < wh && y + h > 0.0 else { return None }
  // (cut by what holds it and its layer alone, as the old frame's rect_of had it: what lies over the top of what scrolls
  // it and is pinned over its foot covers it, drawn over it, but cuts nothing of it (that is `clear`'s): a picture half
  // under the bar is seen whole, the bar over it, and flies from all of it)
  let (bx0, by0, bx1, by1) = self.tree.seen_bounds({ at: self.at, gen: n.gen })
  let (lx, ly, lw, lh) = self.tree.placed_window(self.tree.top_node_of(self.at))
  let (x0, y0) = (dmax(dmax(x, bx0), lx), dmax(dmax(y, by0), ly))
  let (x1, y1) = (dmin(dmin(x + w, bx1), lx + lw), dmin(dmin(y + h, by1), ly + lh))
  let seen = if x1 > x0 && y1 > y0 { Some((x0, y0, x1 - x0, y1 - y0)) } else { None }
  // (the nearest column that scrolls it: what covers its top, what is pinned over its foot)
  let mut clear = None
  let mut i = n.parent
  while i >= 0 && clear is None {
    match self.tree.scrolls_at.get(i) {
      Some(sc) if !sc.across => {
        let (_, sy, s) = self.tree.placed(i, drawn=true)
        let sh = self.tree.nodes[i].flex.height * s
        let (over, under) = @signals.untracked(fn() { (sc.top_covered(), sc.foot_hides_now()) })
        clear = Some((sy + over * s, sy + sh - under * s))
      }
      _ => ()
    }
    i = self.tree.nodes[i].parent
  }
  Some({ box: (x, y, w, h), seen, clear })
}
