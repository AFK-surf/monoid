// What a test reads of each page's list of the window's tree (View::scrolls_window) and asks of it, as it reads an old
// view's list (mbui/ui's Tester::rows, visible, at_end, scroll_to): which rows show, by where each is among its keys,
// where each is drawn, how many there are, where it is scrolled to, whether it is at its foot.

///|
/// What a page's list gives a test (Tree::lists_seen): its scroll, how many keys it has, and asked of it, a row brought to
/// its top by where it is among its keys (gliding there where said and near), and its foot.
priv struct ListAsked {
  scroll : Scroll
  count : () -> Int
  bring : (Int, Bool) -> Unit
  to_end : () -> Unit
  way_steady : () -> (Double, Bool, Array[(String, NodeId, Bool, Bool)])
}


///|
/// A page's list as a test reads it (Tree::lists_seen).
#derive(Debug)
pub(all) struct ListSeen {
  /// its node
  list : NodeId
  /// the rows drawn in sight (any of them within where it shows), top to bottom: where each is among its keys
  /// (View::row_order), its node (the slot it is made in), and where it is drawn in the window (x, y, w, h)
  rows : Array[(Int, NodeId, (Double, Double, Double, Double))]
  /// the first and last of `rows` the reader sees, between what covers its top and what is pinned over its foot
  /// (Scroll::top_covered, foot_covered_now): what its top is where a row is brought to (ListPlace::bring), as an old
  /// list's first and last in view; (-1, -1) where none is
  sight : (Int, Int)
  /// how many keys it has
  count : Int
  /// how far it is scrolled, as of the logic's moment (Scroll::at)
  at : Double
  /// how far it is scrolled at its top, as far up as the hand takes it (Scroll::top_now: past what is tucked over it
  /// once that was taken out of sight; else 0): `at` there, it is at its top
  top : Double
  /// how far it shows past an end (Scroll::past: from its top positive, from its foot negative)
  past : Double
  /// whether it is on by itself (a fling, what shows past an end going back)
  moving : Bool
  /// whether it is at its foot (Scroll::at_foot_now)
  at_foot : Bool
  /// where the top of its pinned foot is drawn in the window (View::scrolls_window's `foot`: the foot of where it
  /// shows less what the foot covers of it, Scroll::foot_covered_now; none, that foot)
  foot_top : Double
}

///|
/// Each page's list live now, in the order its node was made, as a test reads it (ListSeen), the tree laid out as of
/// the logic's moment, each where it is drawn (Tree::drawn_of's `drawn`: a row on a flip's way where the way has it).
pub fn Tree::lists_seen(self : Tree) -> Array[ListSeen] {
  self.laid_as_now()
  let ats = self.lists_asked.keys().to_array()
  ats.sort()
  ats.filter_map(fn(at) {
    guard self.nodes[at].live && self.held_from_root(at) && self.lists_asked.get(at) is Some(a) else { return None }
    let list : NodeId = { at, gen: self.nodes[at].gen }
    guard self.drawn_of(list, drawn=true) is Some(ld) else { return None }
    // (each row's outermost node named for it, drawn within where the list shows)
    let found : Array[(Int, NodeId, (Double, Double, Double, Double))] = []
    let named : Map[Int, Int] = Map([])
    self.rows_named.each(fn(k, r) {
      guard r.0 == list && self.nodes[k].live else { return }
      named[k] = (r.2)()
    })
    named.each(fn(k, order) {
      guard order >= 0 else { return }
      // (one held by another named for the same row: that one's)
      let mut p = self.nodes[k].parent
      while p >= 0 && p != at {
        if named.get(p) == Some(order) {
          return
        }
        p = self.nodes[p].parent
      }
      if p != at {
        return
      }
      match self.drawn_of({ at: k, gen: self.nodes[k].gen }, drawn=true) {
        Some(d) if d.y < ld.y + ld.h && d.y + d.h > ld.y && d.h > 0.0 => found.push((order, d.id, (d.x, d.y, d.w, d.h)))
        _ => ()
      }
    })
    found.sort_by(fn(p, q) { p.0.compare(q.0) })
    let s = a.scroll
    // (those the reader sees: under what covers its top, over its pinned foot, a point of them at least; a row drawn
    // under a bar over the list's top is in `rows`, not in sight, so a row brought to its top is the first in sight)
    let (cover, under) = @signals.untracked(fn() { (s.top_covered(), s.foot_covered_now()) })
    let seen_top = ld.y + cover
    let seen_end = ld.y + ld.h - under
    let mut first = -1
    let mut last = -1
    for r in found {
      let (_, y, _, h) = r.2
      if dmin(y + h, seen_end) - dmax(y, seen_top) >= 1.0 {
        if first < 0 {
          first = r.0
        }
        last = r.0
      }
    }
    Some({
      list,
      rows: found,
      sight: (first, last),
      count: (a.count)(),
      at: s.at(self),
      top: @signals.untracked(fn() { s.top_now() }),
      past: s.past(self),
      moving: s.glides_till() is Some(_),
      at_foot: @signals.untracked(fn() { s.at_foot_now() }),
      foot_top: ld.y + ld.h - @signals.untracked(fn() { s.foot_covered_now() }),
    })
  })
}

///|
/// The page's list a test reads where it names none (Tester::visible, scroll_to, at_end, rows): of those drawn now
/// (Tree::lists_seen), the main one of the page in front: one no modal layer is over and in use (Tree::takes_keys: not a
/// page behind a sheet or a dialog, nor one behind the page come over it), the widest of the window it shows over (a
/// chat's beside the sidebar's list of chats, not that list, made after it), the one made last of those as wide (a page
/// pushed over another as big). Where none is so (all behind something), the one made last, as before.
pub fn Tree::list_in_front(self : Tree) -> ListSeen? {
  let seen = self.lists_seen()
  let mut best : ListSeen? = None
  let mut most = -1.0
  for l in seen {
    guard self.takes_keys(l.list) && self.drawn_of(l.list) is Some(d) else { continue }
    let area = d.w * d.h
    if area >= most {
      most = area
      best = Some(l)
    }
  }
  match best {
    Some(_) => best
    None => seen.last()
  }
}

///|
/// Page's list `list`'s row `order` (where it is among its keys) brought to its top, as its ListPlace::bring is: done as
/// the list is next laid out, or gliding there from the cause's moment where `glide` and it is near (a place's tab
/// pressed again where it shows: back to its top). Nothing where it is no page's list or has no such row.
pub fn Tree::list_bring(self : Tree, list : NodeId, order : Int, glide? : Bool = false) -> Unit {
  match self.lists_asked.get(list.at) {
    Some(a) if self.alive_id(list) => (a.bring)(order, glide)
    _ => ()
  }
}

///|
/// Page's list `list` to its foot, at once, as its ListPlace::to_end is.
pub fn Tree::list_to_end(self : Tree, list : NodeId) -> Unit {
  match self.lists_asked.get(list.at) {
    Some(a) if self.alive_id(list) => (a.to_end)()
    _ => ()
  }
}

///|
/// A page's list of the window's tree (View::scrolls_window) as ui's rows_steady.mbt judges its rows on the frame just
/// drawn: its negative list id (its node's index) and that node's making (a list made anew where one was let go of is
/// another list, never the one before's: the pool hands its index on), where it was made, whether it is free of the hand / gliding / putting / an answer's
/// first settle, when a way in it last set out, whether a row in it is leaving, and each row drawn in it
/// `(row_number, y_from_list_top, h, shows, anew, faint)`.
pub(all) struct TreeListSteady {
  id : Int
  gen : Int
  named : String
  free : Bool
  set_out : Double
  left : Bool
  laids : Array[(Int, Double)]
  rows : Array[(Int, Double, Double, Bool, Bool, Bool)]
  /// where what it shows is held from, down from its top: how far what lies over its top covers it (`cover`), where what
  /// shows ends over its pinned foot (`end`), whether it is at its top (`held_top`: what moves the cover moves its rows
  /// with it), whether at its foot (`at_foot`: as that end moves it is scrolled with it), and how far it is scrolled
  cover : Double
  /// where its first block's top is, under its head (what moves its rows with it as the head grows or shrinks; what
  /// covers its top over that, a bar drawn over what it shows, moves none of them)
  start : Double
  end : Double
  held_top : Bool
  at_foot : Bool
  scrolled : Double
}

///|
fn Tree::holds_node_at(self : Tree, root : Int, k : Int) -> Bool {
  let mut p = k
  while p >= 0 && p < self.nodes.length() {
    if p == root {
      return true
    }
    p = self.nodes[p].parent
  }
  false
}

///|
/// The latest moment a way in or out set out at by `now` in node `at` or anything it holds (-1e9 none).
fn Tree::come_set_out_in(self : Tree, at : Int, now : Double) -> Double {
  guard at >= 0 && at < self.nodes.length() && self.nodes[at].live else { return -1.0e9 }
  let n = self.nodes[at]
  let ca = n.flex.style.come_at
  let mut out = if ca == ca && ca <= now { ca } else { -1.0e9 }
  if n.left_at >= 0.0 && n.left_at <= now && n.left_at > out {
    out = n.left_at
  }
  for k in n.kids {
    let c = self.come_set_out_in(k, now)
    if c > out {
      out = c
    }
  }
  out
}

///|
pub fn Tree::rows_steady_seen(self : Tree, before : Double, now : Double, period : Double) -> Array[TreeListSteady] {
  if self.lists_scrolled.is_empty() {
    return []
  }
  // (read, not taken: sizes steady judges the same frame after and takes them, Tree::answered_in)
  let answered = self.answered_in(before, now)
  let ats = self.lists_scrolled.keys().to_array()
  ats.sort()
  let row_ks = self.rows_named.keys().to_array()
  row_ks.sort()
  ats.filter_map(fn(at) {
    guard at >= 0 && at < self.nodes.length() && self.nodes[at].live && self.held_from_root(at) && !self.out_at(at) &&
      self.lists_scrolled.get(at) is Some(s) else {
      return None
    }
    let list_id : NodeId = { at, gen: self.nodes[at].gen }
    let (_, ly, la, ls) = self.projected(at, drawn=true)
    let lw = self.nodes[at].lw * ls
    let lh = self.nodes[at].lh * ls
    guard la > 0.05 && lw > 0.0 && lh > 0.0 else {
      return None
    }
    let held_at = self.nodes[at].scroll_held
    let at_once = match self.list_inner.get(held_at) {
      Some((joins, _)) => !joins
      None => false
    }
    // (its keys changed since the frame judged before, at its moment too (after that frame's judge of it: a change
    // between two frames at the moment of the first), or at this very moment after a judge of it at this moment: a frame
    // judged twice at one moment, the second after the change)
    let keys_now = s.keys_at >= before || s.keys_at == now
    let keys_at_once = at_once && keys_now
    // (an answer's step in it, nothing on its way in it: judged within the list, what carries the list whole (a page
    // sliding in) no way in it, Tree::on_way_at's `within`)
    let answered_here = answered.iter().any(fn(ans) {
      self.holds_node_at(at, ans) && !self.on_way_at(ans, now, within=at)
    })
    let mut set_out = s.keys_at
    let mut left = false
    let stack = [at]
    while stack.length() > 0 {
      let cur = stack.pop().unwrap()
      guard cur >= 0 && cur < self.nodes.length() else { continue }
      let m = self.nodes[cur]
      guard m.live else { continue }
      let ca = m.flex.style.come_at
      if ca == ca && ca <= now && ca > set_out {
        set_out = ca
      }
      if m.left_at >= 0.0 && m.left_at <= now {
        left = true
        if m.left_at > set_out {
          set_out = m.left_at
        }
      }
      for kid in m.kids {
        stack.push(kid)
      }
    }
    // (and what set out beside it, or beside what holds it, in that column: a way there that moves the list or what it
    // shows (a part over it opening, the list held at its foot shrinking with it) sets its rows out too, as
    // Tree::on_way_at reads a way beside a node)
    let mut q = at
    while q >= 0 && q < self.nodes.length() {
      let p = self.nodes[q].parent
      if p >= 0 && p < self.nodes.length() {
        for kid in self.nodes[p].kids {
          if kid != q {
            let c = self.come_set_out_in(kid, now)
            if c > set_out {
              set_out = c
            }
          }
        }
      }
      q = p
    }
    // (a list whose rows go by a flip's way (View::scrolls_window's `flips`): when that way set out, whether it closes a
    // row's way, and which rows are new to it, as the list tells them)
    let flip_new : Map[Int, Bool] = Map([])
    match self.lists_asked.get(at) {
      Some(a) => {
        let (so, lf, items) = (a.way_steady)()
        if so > set_out {
          set_out = so
        }
        if lf {
          left = true
        }
        for it in items {
          if it.2 {
            flip_new[it.1.at] = true
          }
        }
      }
      None => ()
    }
    let (cover, under) = @signals.untracked(fn() { (s.top_covered(), s.foot_covered_now()) })
    let seen_top = ly + cover
    let seen_end = ly + lh - under
    let named_orders : Map[Int, Int] = Map([])
    for k in row_ks {
      if k >= 0 && k < self.nodes.length() && self.nodes[k].live && self.rows_named.get(k) is Some(r) && r.0 == list_id {
        named_orders[k] = (r.2)()
      }
    }
    // (whether one of its rows came or went by its keys' last change, or after, making its way: none, what came or went
    // did so at once, the rows where they stand after it no step of theirs; a way only in a row (a part of it opening or
    // closing with the same change) is none of its keys': its rows' places moved at once by them as ever)
    let way_with_keys = named_orders
      .keys()
      .any(fn(k) {
        let m = self.nodes[k]
        let ca = m.flex.style.come_at
        (ca == ca && ca <= now && ca >= s.keys_at) || (m.left_at >= 0.0 && m.left_at >= s.keys_at && m.left_at <= now)
      })
    let rows : Array[(Int, Int, Double, Double, Bool, Bool, Bool)] = []
    for k in row_ks {
      guard named_orders.get(k) is Some(order) && order >= 0 && self.rows_named.get(k) is Some(r) else { continue }
      // (a row of this list's own, in it now: one put by (View::park: held by nothing, its key the one it had) or held in
      // another row is none of its rows here, drawn nowhere it is laid out)
      let mut outer = true
      let mut p = self.nodes[k].parent
      while p >= 0 && p != at {
        if named_orders.contains(p) {
          outer = false
          break
        }
        p = self.nodes[p].parent
      }
      if !outer || p != at || self.out_at(k) {
        continue
      }
      let num = @signals.untracked(r.1)
      let m = self.nodes[k]
      let (_, dy, da, ds) = self.projected(k, drawn=true)
      let dw = m.lw * ds
      let dh = m.lh * ds
      let y = dy - ly
      let shows = da > 0.05 &&
        dw > 0.0 &&
        dh > 0.0 &&
        dmin(dy + dh, seen_end) > dmax(dy, seen_top)
      let anew = dh < 1.0 ||
        (m.coming && now - m.flex.style.come_at < 0.5 * period) ||
        (flip_new.contains(k) && set_out >= 0.0 && now - set_out < 0.5 * period)
      let faint = dh < 1.0 || da < 0.5 || m.left_at >= 0.0
      rows.push((order, num, y, dh, shows, anew, faint))
    }
    rows.sort_by(fn(a, b) {
      let c = a.0.compare(b.0)
      if c != 0 { c } else { a.1.compare(b.1) }
    })
    // (and every scroll that holds it: one the hand moves, or that glides, eases or is put somewhere, moves what shows of
    // the list, the rows it makes and lets go round that found anew: no step of the list's own (a page's list in a
    // settings page that scrolls, 2026-11-16))
    let mut outer_free = true
    let mut p = self.nodes[at].parent
    while p >= 0 && p < self.nodes.length() {
      match self.scrolls_at.get(p) {
        Some(o) =>
          outer_free = outer_free &&
            !o.hand_on.untracked() &&
            !o.claimed &&
            o.glides_till() is None &&
            @signals.untracked(fn() { o.notch.get() }) is None &&
            !(o.put_at > before || now - o.put_at <= 1.5 * period) &&
            !(o.wheel_at > before || now - o.wheel_at <= 1.5 * period)
        None => ()
      }
      p = self.nodes[p].parent
    }
    let free = outer_free &&
      !s.hand_on.untracked() &&
      !s.claimed &&
      s.glides_till() is None &&
      // (a wheel or a put since the frame judged before, whatever time it took to come to this one (a test's clock run
      // on in one jump, a slow rate's frames): where it put the rows is where it said, no step of theirs)
      !(s.wheel_last > before || now - s.wheel_last <= 1.5 * period) &&
      !(s.put_at > before || now - s.put_at <= 1.5 * period) &&
      !keys_at_once &&
      // (its keys changed with no way set out with them: what came or went did so at once (a message caught up on,
      // simply there), the list held at its foot with it; where the rows stand after is where they are, no step of
      // theirs)
      !(keys_now && !way_with_keys) &&
      !answered_here
    let named = match self.nodes[at].source {
      Some(src) => source_place(src.made_for.unwrap_or(src.made))
      None => "tree/\{at}"
    }
    // (the width it is laid out at itself, by its own key apart from its nodes' (a pane split, its rows laid out anew
    // narrower: their step their own, as the window made another size), and each ancestor's said, View::lays_anew)
    let laids : Array[(Int, Double)] = [(-(at + 1), self.nodes[at].lw)]
    let mut anc = at
    while anc >= 0 && anc < self.nodes.length() {
      match self.laid_said_of(anc) {
        Some(w) => laids.push((anc, w))
        None => ()
      }
      anc = self.nodes[anc].parent
    }
    Some({
      id: -(at + 1),
      gen: self.nodes[at].gen,
      named,
      free,
      set_out,
      left,
      laids,
      rows: rows.map(fn(x) { (x.1, x.2, x.3, x.4, x.5, x.6) }),
      cover,
      start: @signals.untracked(fn() { (s.keys_start)() }),
      end: lh - under,
      held_top: @signals.untracked(fn() { s.at(self) <= s.top_now() + 0.5 }),
      // (by where it is and how far it can go, plain values of its layout, judged each frame: never Scroll::at_foot_now,
      // whose scoped computed reads its keys, a judge's read of it holding their topic on past the list's own (what the
      // client tells the core changed by a Tester's look))
      at_foot: @signals.untracked(fn() { s.x.get() == @double.infinity || s.at(self) >= s.most_now() - 0.5 }),
      scrolled: s.at(self),
    })
  })
}
