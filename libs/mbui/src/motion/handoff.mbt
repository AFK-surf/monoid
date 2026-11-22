// One thing seen in turn on each of several nodes, handed from one to the next (a row's tips, a bar's hover ground):
// each node draws it as its own ground, and the one it comes to goes from where the one before drew it, as fast as
// that went, to where it is laid out (Handoff, a group of them; HandPart, each node's part). What is handed over is
// read of the one before at the moment of the cause (where it was placed, off as its ways had it then, how fast each
// went, how much of it was seen), never found by comparing frames; where it goes is where that cause lays the next one
// out (View::laid_window_now, as of that moment, what goes beside another beside its anchor). Each edge is a way of its
// own, set out with the speed it had (a spring takes it on, its place and speed going on where it turned), at rest the
// ground as laid out; what it carries inside (its words) goes from the middle of the one before to its place with it.

///|
/// How a thing handed on goes to the next of its group where it must be there before the hand would read it (a row's
/// tips, read as one rested on within 200 ms): a critically damped spring, within half a point of its rest in about
/// 145 ms over 150 points from still, taking on the speed it is handed.
// kept across runs: a constant: its fields are not mut, nothing changes it
pub let hand_spring : Spec = motion_spring(0.09, threshold=0.5)

///|
/// A group of nodes handing one ground on among them (HandPart): the one that showed it last (showing still, or gone
/// at a moment), and for how long after it went the next takes it over (`within`); how many parts it has had.
pub struct Handoff {
  priv within : Double
  priv mut last : HandPart?
  priv mut ids : Int
}

///|
/// A group, the next taking over from the one before while that shows, or within `within` ms of its going (and only
/// while some of it is seen then: HandPart's `seen`).
pub fn Handoff::new(within? : Double = @double.infinity) -> Handoff {
  { within, last: None, ids: 0 }
}

///|
/// A node's part in a group (Handoff::part): its group, which it is and what it can take over (`tag`: only from one
/// of the same), how much of it is seen at a moment (`seen`), what puts it out at once as another takes it over
/// (`gave`); its ground's ways off where it is laid out (across, down, wider, taller) and what it carries (across,
/// down), in the window's points; its node, where it is drawn; what it is to go from once that is made, and when it
/// went (infinity while it shows; never shown, -infinity).
pub struct HandPart {
  priv group : Handoff
  priv id : Int
  priv tag : Int
  priv seen : (Double) -> Double
  priv gave : () -> Unit
  priv ways : Array[Way]
  priv mut node : @view.View?
  priv mut due : () -> Unit
  priv mut pending : HandFrom?
  priv mut went : Double
}

///|
/// Where a part goes from (HandPart::came): the ground of the one before in the window and how fast each of its edges
/// went (per second), at moment `at`, by `spec`.
priv struct HandFrom {
  rect : (Double, Double, Double, Double)
  speed : (Double, Double, Double, Double)
  at : Double
  spec : Spec
}

///|
/// A part of the group's: `tag` (it takes over only from one of the same, a tip from a tip on the same side), how much
/// of it is seen at a moment (`seen`: 0 none, so none to take over from), what puts it out at once as another takes it
/// over (`gave`). Drawn by a node once it is said (HandPart::draws).
pub fn Handoff::part(
  self : Handoff,
  seen : (Double) -> Double,
  tag? : Int = 0,
  gave? : () -> Unit = fn() {  },
) -> HandPart {
  self.ids = self.ids + 1
  {
    group: self,
    id: self.ids,
    tag,
    seen,
    gave,
    ways: Array::makei(6, fn(_) { Way::new(0.0) }),
    node: None,
    due: fn() {  },
    pending: None,
    went: @double.neg_infinity,
  }
}

///|
/// Node `v` draws it (its ground going as it is handed on, View::ground_drawn), from now till it is let go; what it
/// carries inside, `carries` (its words: View::drawn_off), with it. What it was handed before its node was made goes
/// from now, at its moment.
pub fn HandPart::draws(self : HandPart, v : @view.View, carries? : @view.View) -> Unit {
  self.node = Some(v)
  v.owns(fn() {
    match self.node {
      Some(n) if n.id() == v.id() => self.node = None
      _ => ()
    }
  })
  |> ignore
  v.ground_drawn(By(fn() { self.ground(v) })) |> ignore
  match carries {
    Some(c) => {
      // (what it carries cut to its ground while that is on its way to another's shape: never past it, over what is
      // under it; at rest, not cut)
      v.clips(By(fn() {
        let g = self.ground(v)
        g.dx != 0.0 || g.dy != 0.0 || g.dw != 0.0
      }))
      |> ignore
      c.drawn_off(By(fn() { (self.ways[4].shown_on(c), self.ways[5].shown_on(c)) })) |> ignore
    }
    None => ()
  }
  self.start(v)
}

///|
/// How its ground is drawn on node `v` now: off where it is laid out as its ways have it, as laid out at rest.
fn HandPart::ground(self : HandPart, v : @view.View) -> @view.GroundShape {
  let k = fn(i : Int) { self.ways[i].shown_on(v) }
  let (dx, dy, dw, dh) = (k(0), k(1), k(2), k(3))
  if dx == 0.0 && dy == 0.0 && dw == 0.0 && dh == 0.0 {
    @view.ground_as_laid
  } else {
    { dx, dy, dw, dh, corners: None }
  }
}

///|
/// Where its ground is drawn in the window at `at`, how fast each edge goes then (per second) and how much of it is
/// seen: None where none is, or it has no node placed.
fn HandPart::drawn_at(
  self : HandPart,
  at : Double,
) -> ((Double, Double, Double, Double), (Double, Double, Double, Double), Double)? {
  let s = (self.seen)(at)
  guard s > 0.0 else { return None }
  match self.node {
    Some(v) if v.alive() && v.was_placed() => {
      let (x, y, w, h) = v.placed_window_now()
      let k = fn(i : Int) { self.ways[i].at(at) }
      let ((d0, v0), (d1, v1), (d2, v2), (d3, v3)) = (k(0), k(1), k(2), k(3))
      Some(((x + d0, y + d1, w + d2, h + d3), (v0, v1, v2, v3), s))
    }
    _ => None
  }
}

///|
/// Whether another part of its group shows at `at` or went within the group's time of it, whatever it is (its tag
/// any): what comes now comes at once.
pub fn HandPart::other_near(self : HandPart, at : Double) -> Bool {
  match self.group.last {
    Some(l) => l.id != self.id && (l.went == @double.infinity || at < l.went + self.group.within)
    None => false
  }
}

///|
/// It shows from `at` (its cause's moment), the last of its group: where another of its tag shows then or went within
/// the group's time, some of it seen, it goes from where that one is drawn then, as fast as that went, by `spec`, to
/// where its node is laid out (that one put out at once: its `gave`), and how much of that one was seen is said; the
/// last of its group already (shown again before another came), its ways going on, None said; else (`takes` false
/// too: a finger's, there at once) it is where it is laid out at once, None said.
pub fn HandPart::came(self : HandPart, at : Double, spec : Spec, takes? : Bool = true) -> Double? {
  // (the last of its group still, back before another came: its ways going on as they go)
  if takes && self.is_last() {
    self.went = @double.infinity
    return None
  }
  let from = match self.group.last {
    Some(l) if takes && l.id != self.id && l.tag == self.tag && (l.went == @double.infinity || at < l.went + self.group.within) =>
      match l.drawn_at(at) {
        Some(d) => Some((l, d))
        None => None
      }
    _ => None
  }
  self.group.last = Some(self)
  self.went = @double.infinity
  match from {
    Some((l, (rect, speed, seen))) => {
      (l.gave)()
      self.go_from({ rect, speed, at, spec })
      Some(seen)
    }
    None => {
      self.still()
      None
    }
  }
}

///|
/// It goes from `at` (shown no more): the next of its group takes it over from where it is drawn while it is seen,
/// within the group's time.
pub fn HandPart::left(self : HandPart, at : Double) -> Unit {
  self.went = at
}

///|
/// Whether it is the last of its group to show (showing, or gone, none come since).
pub fn HandPart::is_last(self : HandPart) -> Bool {
  match self.group.last {
    Some(l) => l.id == self.id
    None => false
  }
}

///|
/// Where it is laid out at once, going nowhere, nothing to go from waiting.
pub fn HandPart::still(self : HandPart) -> Unit {
  (self.due)()
  self.due = fn() {  }
  self.pending = None
  for w in self.ways {
    w.put(0.0)
  }
}

///|
/// It let go (its node's owner gone): nothing to take over from, nothing waiting.
pub fn HandPart::gone(self : HandPart) -> Unit {
  self.still()
  if self.is_last() {
    self.group.last = None
  }
}

///|
/// Told to go from `from`: set going on its node's timeline at its moment, once it has a node (HandPart::draws).
fn HandPart::go_from(self : HandPart, from : HandFrom) -> Unit {
  (self.due)()
  self.due = fn() {  }
  self.pending = Some(from)
  match self.node {
    Some(v) if v.alive() => self.start(v)
    _ => ()
  }
}

///|
/// What it was told to go from set going on node `v`'s timeline, at its moment: each edge from where the one before
/// had it, as fast, to where `v` is laid out then; what it carries from that one's middle, as fast as that went.
fn HandPart::start(self : HandPart, v : @view.View) -> Unit {
  guard self.pending is Some(f) else { return }
  self.due = v.at_moment(f.at, fn() {
    self.due = fn() {  }
    self.pending = None
    let (tx, ty, tw, th) = v.laid_window_now()
    let (fx, fy, fw, fh) = f.rect
    let (vx, vy, vw, vh) = f.speed
    let off = [fx - tx, fy - ty, fw - tw, fh - th, fx + fw / 2.0 - (tx + tw / 2.0), fy + fh / 2.0 - (ty + th / 2.0)]
    let speed = [vx, vy, vw, vh, vx + vw / 2.0, vy + vh / 2.0]
    for i, w in self.ways {
      w.put(off[i])
      w.go(0.0, f.spec, at=f.at, velocity=speed[i])
    }
  })
}
