// A column that scrolls up and down in a node (View::scrolls), as an old view's box kept to a height does (ui's
// Ctx::capped): what it holds laid out as tall as it is, drawn off by how far it is scrolled and cut to the node, found
// by a finger or the pointer within the node alone; the wheel over any of it moves it while it can go that way (at its
// end the wheel goes on to what holds it: View::on_wheel_moves), a finger or the pointer held on any of it and moved up
// or down past the slop drags it (View::claims: what it went down on called off; across, or at its end, what holds it
// is asked) and, let go, flings it on, slowing; the focus come to what it holds brings that into sight once laid out
// (View::shows). As tall as what it holds
// where there is the room, it gives way (to nothing) where what holds it is short of room (a dialog no taller than the
// window), how far it can go worked out as it is laid out, in that layout (what it holds measured there: its fill, a
// page's list's blocks made and measured first). Where it is, a function of the time while
// flung, is the column's own (Scroll), let go with the node. One made as a page's list (Scroll::list) moves as an old
// view's list does on the platform it is on instead (scroll_list.mbt). One made to scroll across (Scroll::across) is a
// row that scrolls sideways the same way (an old view's Ctx::sideways): along its width, the wheel and a hold across,
// its bar along its foot, what holds it asked what goes up or down.

///|
/// A fling under way: set out from `x0` at `v0` (points a ms, down the column) at `t0`, at rest at `end_x` at `end_t`;
/// a page's list's its platform's way (none: a box kept to a height's).
priv struct Fling {
  x0 : Double
  v0 : Double
  t0 : Double
  end_t : Double
  end_x : Double
  /// the end it went toward as it set out: its top, or its foot as far as it could go then
  till : Double
  way : ListWay?
}

///|
/// Brought on by the hand held past its edge (Scroll::edge_toward): from `x0` at `t0`, `v` points a ms, steady, as far
/// as `bound` (how far it could go, or its top, as last laid out); at `end_t` there, after which `parked` (at `x0`,
/// still said: what holds it laid out further, on again from there then).
priv struct Edge {
  x0 : Double
  v : Double
  t0 : Double
  bound : Double
  end_t : Double
  parked : Bool
}

///|
/// How far a column that scrolls (View::scrolls) is scrolled: where it is at rest (or where a fling set out from), the
/// fling under way, how far it can go as last laid out, and the hand on it.
pub struct Scroll {
  priv x : @signals.Signal[Double]
  priv fling : @signals.Signal[Fling?]
  /// how far it can go, as laid out (worked out as it is laid out, in that layout: View::scrolls; none before it first
  /// is)
  priv mut room : () -> Double?
  /// how big it shows what it holds (its own content box, as it is laid out: none before it first is), and what is done
  /// as it is laid out before what it holds is measured, given the room it shows it in (a page's list: its blocks made
  /// and measured for it, View::scrolls_window)
  priv seen : @signals.Signal[(Double, Double)?]
  priv mut fill : (Double?, (Double?, Double)?, Bool) -> Unit
  /// where its fill puts it once measured, told as one with `seen` and `room`
  priv mut fill_put : () -> Unit
  /// how tall what it holds comes to, where what fills it knows it as it fills it (a page's list: its blocks as they
  /// are counted, its foot's room), not measured again
  priv mut whole : (() -> Double)?
  /// what ends the fling's settling at its end (View::at_moment's), as it is called off: one for what scrolls beside it
  /// (Scroll::beside), whose fling is one, so the hand stopping it on any of them calls off the end said on another
  priv settle_off : Ref[() -> Unit]
  /// the fingers held on it, in the order they went down, each where it was last (its own terms and the window's, down):
  /// the last down leads it, the others' moves kept, moving nothing (on_drag's `fingers`); cumulative driven delta along
  /// the scroll axis and its velocity tracker, and how fast it went (points a ms, down the column)
  priv hand_fingers : Array[(Int, Double, Double)]
  priv mut hand_cum : Double
  priv hand_track : Tracker
  priv mut hand_v : Double
  /// signed fling velocity (points a ms) caught when the hand stopped an active glide, and the moment it was caught
  priv mut caught_v : Double
  priv mut caught_at : Double
  /// the hand on it now: from its press to its let go (Scroll::in_hand)
  priv hand_on : @signals.Signal[Bool]
  /// taken over from what it went down on (View::claims): its first move from where it went down counted past the slop
  priv mut claimed : Bool
  /// what is told as it scrolls (its bar, and those of what scrolls beside it: Scroll::beside), at the moment, by the
  /// node each scrolls in
  priv peers_scrolled : Map[Int, (Double) -> Unit]
  /// the live host nodes and their scrolls in the same Scroll::beside group, by host node index
  priv peers_hosts : Map[Int, (View, Scroll)]
  /// which column it is, of all made (what hosts the tree tells its glides by: Tree::on_glides)
  priv serial : Int
  /// it moves as a page's list does on the platform it is on (Scroll::new / Scroll::list): what shows past its ends,
  /// pulled there or going back (none: nothing)
  priv as_list : Bool
  /// whether it is a page's main rows list (Scroll::list): registers `Tree::rows_list` host pixel grid and enforces
  /// `Tree::rows_list_nested_said`; `Scroll::new()` sets this false so nested scrolls work safely
  priv rows_list : Bool
  priv past : @signals.Signal[Past?]
  /// a page's list's wheel's notches easing in (none: none)
  priv notch : @signals.Signal[Notch?]
  /// how tall it is as laid out (its own points), as it is asked
  priv mut tall : () -> Double
  /// the node it scrolls in, while it is (View::scrolls): what it is on by itself said on its timeline
  priv mut host : View?
  /// it scrolls across, along its width (Scroll::across: a row that scrolls sideways), not up and down: what is said
  /// down the column above said along the row, its start for its top
  priv across : Bool
  /// brought on by the hand held past its edge (Scroll::edge_toward), while it is said
  priv edge : @signals.Signal[Edge?]
  /// how far it was put to tuck a node over its top as that was first laid out (Scroll::tucks: none, never), whether it
  /// is to be put there still (the hand not on it since), and the room a page's list's foot keeps for it
  priv tuck_at : @signals.Signal[Double?]
  priv mut tuck_owed : Bool
  priv tuck_room : @signals.Signal[Double]
  /// whether the scroll viewport is given an exact main-axis height (`Exactly`): only then does a short list need
  /// `tuck_room` at its foot; adaptive (`AtMost`/`Undefined`) containers size themselves without the tucked header
  priv tuck_exact : @signals.Signal[Bool]
  /// whether `held.margin_bottom` subtracts `tuck` (true for `self.whole is None` or `adaptive_window`)
  priv mut tuck_margin_sub : Bool
  /// how tall a page's list's foot is laid out (View::scrolls_window's `foot`: what is pinned over the foot of what
  /// shows), as it was last laid out: 0 where it holds none
  priv mut foot_tall : Double
  /// the node it scrolls in that keeps that room, while it does
  priv mut tuck_in : View?
  /// whether what is tucked is kept so (Scroll::tucks' `kept`)
  priv mut tuck_kept : () -> Bool
  /// what is tucked gone out of sight by the hand: its top held where what is tucked ends (Scroll::top_now), till the
  /// hand pulls on past it from there anew (Scroll::pulled)
  priv tuck_shut : @signals.Signal[Bool]
  /// the hand came down on it with it at that held top: what it pulls toward the top from there shows what is tucked
  priv mut pull_free : Bool
  /// pulled on past that top, what is tucked not shown since: not held there again till it shows, or the hand is set
  /// going anew
  priv mut pull_open : Bool
  /// the moment of the wheel it was last turned by (none: never)
  priv mut wheel_last : Double
  /// how far it was put in all for what came in or out over what shows, or was measured anew there
  /// (Scroll::grew_above): no move of the column's, what shows held where it was
  priv mut corrected : Double
  /// its foot gone to at once at a moment (End: scroll_keys.mbt), where what fills it knows it better than how far it
  /// was last laid out to go (a page's list: ListPlace::to_end); false where it does not
  priv mut to_foot : (Double) -> Bool
  /// a page's list at the foot it follows, left where it is as what shows grows (Scroll::holds_here), till it is
  /// followed again (View::scrolls_window's fill says when); and what its list does as that is said (what it holds
  /// then kept: blocks come or gone since are told from it)
  priv mut held : Bool
  priv mut held_said : () -> Unit
  /// what it does as a node in it is pressed (what was pressed held where it is, press_stays.mbt: a page's list's
  /// View::scrolls_window's, a plain column's View::scrolls'): given the node before the press is done, what to do once
  /// it is
  priv mut pressed_said : (View) -> () -> Unit
  /// what it does as a node in it says what is read in its block starts at it (View::read_from): a page's list's
  /// (View::scrolls_window) keeps it for that block; elsewhere nothing
  priv mut read_from_said : (View) -> Unit
  /// where a page's list's first block's top is now (under its head, as tall as that is laid out: View::scrolls_window);
  /// elsewhere 0: for what judges its rows (lists_seen.mbt) to move them with that head, not with what covers its top
  priv mut keys_start : () -> Double
  /// what it does as a node in it says it holds what a go-to brings (View::sought): a page's list's
  /// (View::scrolls_window) keeps it for its block; elsewhere nothing
  priv mut sought_said : (View, () -> ((Double, Double) -> (Double, Double, Double, Double)?)?) -> Unit
  /// whether it is at its foot, followed, told only as that changes (Scroll::at_foot_now): a page's list's by its own
  /// blocks and anchor (View::scrolls_window), else by how far it goes as last laid out (View::scrolls)
  priv mut at_foot_said : (() -> Bool)?
  /// how tall what is pinned over its foot covers what it shows (a page's list's foot, as tall as the room it keeps
  /// under its last block: View::scrolls_window's), what a part brought into sight comes to rest over (View::scrolls'
  /// `shows`)
  priv mut foot_covered : () -> Double
  /// how tall the top of that foot is that covers nothing (room it keeps under its last block the rows show through:
  /// View::scrolls_window's `foot_clear`), read through Scroll::foot_hides_now
  priv mut foot_clear : () -> Double
  /// how tall what lies over its top covers what it shows (the bar a page's list runs under: View::scrolls'
  /// `top_covered`), read through Scroll::top_covered
  priv mut top_cover : () -> Double
  /// the foot pinned over what it shows (a page's list's foot: View::scrolls_window's), its node; -1 none: what of the
  /// column it covers is not seen of a picture flying from it (Tree::stays_bounds), and what flies from a
  /// thing in the column or in it is drawn in the list over both (Tree::incoming_host)
  mut foot_at : Int
  /// the logic's moment it was last put at once by Scroll::put or a scroll key (Tree::scroll_put_at).
  /// Its rows and its bar's thumb can move with it in that frame.
  priv mut put_at : Double
  /// the logic's moment the wheel last moved it directly (rows_steady.mbt)
  priv mut wheel_at : Double
  /// the logic's moment the keys of the page's list it scrolls last changed by data (Scroll::keys_changed), for the
  /// Tester's judges: its bar's thumb, where the reader is in what the list holds, changes with them in that frame
  /// (Tree::scroll_keys_at)
  priv mut keys_at : Double
  /// scrolled beside another as one (Scroll::beside, either of them): what it is scrolled to is theirs together, so
  /// what a list's block taken for another key keeps by its key keeps nothing of it (reused_state.mbt)
  priv mut shared : Bool
}

///|
/// Columns' scrolls made: each one's own number (Scroll's `serial`).
// kept across runs: it goes on counting
let scrolls_made : Ref[Int] = Ref(0)

///|
// kept across runs: each scroll's entry while it scrolls in a node (View::scrolls's owns removes it)
let scroll_notch_landed : Map[Int, Bool] = Map([])

///|
// kept across runs: each scroll's entry while it scrolls in a node (View::scrolls's owns removes it)
let scroll_follows_said : Map[Int, () -> Bool] = Map([])

///|
// kept across runs: each scroll's entry while it scrolls in a node (View::scrolls's owns removes it)
let scroll_glides_foot_said : Map[Int, () -> Bool] = Map([])

///|
fn Scroll::is_notch_landed(self : Scroll) -> Bool {
  scroll_notch_landed.get(self.serial).unwrap_or(false)
}

///|
fn Scroll::set_notch_landed(self : Scroll, v : Bool) -> Unit {
  if v {
    scroll_notch_landed[self.serial] = true
  } else {
    scroll_notch_landed.remove(self.serial)
  }
}

///|
fn Scroll::set_follows_said(self : Scroll, f : (() -> Bool)?) -> Unit {
  match f {
    Some(cb) => scroll_follows_said[self.serial] = cb
    None => scroll_follows_said.remove(self.serial)
  }
}

///|
fn Scroll::set_glides_foot_said(self : Scroll, f : (() -> Bool)?) -> Unit {
  match f {
    Some(cb) => scroll_glides_foot_said[self.serial] = cb
    None => scroll_glides_foot_said.remove(self.serial)
  }
}

///|
/// Which scroll it is (each made its own number; one `beside` another its own too): what tells two apart, where
/// what is made in one is made again for another (a block of a page's list taken for another row).
pub fn Scroll::serial(self : Scroll) -> Int {
  self.serial
}

///|
/// A column's scroll, at its top: as a page's list on the platform it is on (scroll_list.mbt), with platform inertia,
/// overscroll/rubber-band feel, and `grew_above` support, without registering a top-level `rows_list` pixel grid so
/// nested scrolls work safely.
pub fn Scroll::new() -> Scroll {
  Scroll::made(true, rows_list=false)
}

///|
/// A column's scroll, at its top: as an old view's box kept to a height scrolls (ui's Ctx::capped), without platform
/// list fling/rubber-band physics.
pub fn Scroll::plain() -> Scroll {
  Scroll::made(false, rows_list=false)
}

///|
/// A row's scroll, at its start: across, as an old view's box scrolled sideways does (ui's Ctx::sideways).
pub fn Scroll::across() -> Scroll {
  Scroll::made(false, across=true, rows_list=false)
}

///|
/// A column's scroll, at its top: as a page's list on the platform it is on (scroll_list.mbt).
pub fn Scroll::list() -> Scroll {
  Scroll::made(true, rows_list=true)
}

///|
/// Another column or row that scrolls with `self` as one (a long table cut a few rows a block of a page's list, each
/// block's piece of it scrolled across where the others are): how far it is scrolled, its fling, the hand on it and
/// what brings it on past its edge the same, whichever of them the hand moves; how far it can go, how big it shows what
/// it holds and the node it scrolls in its own (all of them as wide, each goes as far). Each host takes its own, one
/// node each; `self` itself may be scrolled by none of them (only what they share).
pub fn Scroll::beside(self : Scroll) -> Scroll {
  self.shared = true
  {
    ..Scroll::made(self.as_list, across=self.across, rows_list=self.rows_list),
    shared: true,
    x: self.x,
    fling: self.fling,
    hand_on: self.hand_on,
    edge: self.edge,
    notch: self.notch,
    settle_off: self.settle_off,
    past: self.past,
    // (scrolled by the hand in any of them: the bar of each told, wherever it is)
    peers_scrolled: self.peers_scrolled,
    peers_hosts: self.peers_hosts,
  }
}

///|
fn Scroll::made(as_list : Bool, across? : Bool = false, rows_list? : Bool = false) -> Scroll {
  {
    across,
    x: @signals.signal(0.0, same=fn(a, b) { a == b }),
    fling: @signals.signal_by(None, same=fn(a, b) { same_ref(a, b) }),
    room: fn() { None },
    seen: @signals.signal(None, same=fn(a, b) { a == b }),
    fill: fn(_, _, _) {  },
    fill_put: fn() {  },
    whole: None,
    settle_off: Ref(fn() {  }),
    hand_fingers: [],
    hand_cum: 0.0,
    hand_track: Tracker::new(),
    hand_v: 0.0,
    caught_v: 0.0,
    caught_at: -1.0e9,
    hand_on: @signals.signal(false, same=fn(a, b) { a == b }),
    claimed: false,
    peers_scrolled: Map([]),
    peers_hosts: Map([]),
    to_foot: fn(_) { false },
    serial: {
      scrolls_made.val += 1
      scrolls_made.val
    },
    as_list,
    rows_list,
    past: @signals.signal_by(None, same=fn(a, b) { same_ref(a, b) }),
    notch: @signals.signal_by(None, same=fn(a, b) { same_ref(a, b) }),
    tall: fn() { 0.0 },
    host: None,
    edge: @signals.signal_by(None, same=fn(a, b) { same_ref(a, b) }),
    tuck_at: @signals.signal(None, same=fn(a, b) { a == b }),
    tuck_owed: false,
    tuck_room: @signals.signal(0.0, same=fn(a, b) { a == b }),
    tuck_exact: @signals.signal(false, same=fn(a, b) { a == b }),
    tuck_margin_sub: false,
    foot_tall: 0.0,
    tuck_in: None,
    tuck_kept: fn() { true },
    tuck_shut: @signals.signal(false, same=fn(a, b) { a == b }),
    pull_free: false,
    pull_open: false,
    wheel_last: -1.0e9,
    corrected: 0.0,
    held: false,
    held_said: fn() {  },
    pressed_said: fn(_) { fn() {  } },
    read_from_said: fn(_) {  },
    keys_start: fn() { 0.0 },
    sought_said: fn(_, _) {  },
    at_foot_said: None,
    foot_covered: fn() { 0.0 },
    foot_clear: fn() { 0.0 },
    top_cover: fn() { 0.0 },
    foot_at: -1,
    put_at: -1.0e9,
    wheel_at: -1.0e9,
    keys_at: -1.0e9,
    shared: false,
  }
}

///|
/// The same one, or both none.
fn[T] same_ref(a : T?, b : T?) -> Bool {
  match (a, b) {
    (None, None) => true
    (Some(x), Some(y)) => physical_equal(x, y)
    _ => false
  }
}

///|
/// Whether the hand holds it now (a finger's or a pointer's drag on it, from its press to its let go), followed: for
/// what tells others of what it shows only at rest (a chat's page telling the core what is read, none while the hand
/// scrolls: Scroll::glides_till for what it is on by itself after), never for what lays out or draws.
pub fn Scroll::in_hand(self : Scroll) -> Bool {
  self.hand_on.get()
}

///|
/// When the glide it is on now ends, on the tree's timeline (let go at a speed: View::scrolls' fling), as it is now:
/// none at rest, held, or stopped (pressed again, the wheel, what it holds shorter, let go of).
pub fn Scroll::glides_till(self : Scroll) -> Double? {
  @signals.untracked(fn() { self.rest_now() })
}

///|
/// When what it is on by itself now ends (a fling, what it meets its end with going back; what shows past an end going
/// back), followed: none at rest or held.
fn Scroll::rest_now(self : Scroll) -> Double? {
  // (the hand past its edge: at its end as said now; at rest there, parked)
  match self.edge.get() {
    Some(e) => return if e.parked { None } else { Some(e.end_t) }
    None => ()
  }
  match self.fling.get() {
    Some(f) =>
      match f.way {
        Some({ hit: Some({ back: Some(p), .. }), .. }) => Some(p.rest)
        _ => Some(f.end_t)
      }
    // (a page's list's notches easing in and what shows past an end going back, each its own: at rest as the later is)
    None => {
      let eased = self.notch.get().map(fn(n) { n.t0 + n.end })
      let back = match self.past.get() {
        Some({ back: Some(p), .. }) => Some(p.rest)
        _ => None
      }
      match (eased, back) {
        (Some(a), Some(b)) => Some(dmax(a, b))
        (a, None) => a
        (None, b) => b
      }
    }
  }
}

///|
/// How a fling slows: as an old view's box kept to a height does (ui's sideways_friction, a ms).
let scroll_friction : Double = 0.996

///|
/// The fastest fling (the window's points a ms): as an old view's list's (ui's max_fling, Android's 8000 dp/s).
let scroll_most_v : Double = 8.0

///|
/// Fastest chained fling speed (points a ms, 12000 dp/s) when repeated same-direction flicks carry momentum.
let scroll_chain_most_v : Double = 12.0

///|
/// Maximum interval (ms) from catching an active glide to releasing the next flick to carry momentum.
let flick_chain_ms : Double = 400.0

///|
/// Grace window (ms) bridging `view_caught` (`k > 0`) `Down -> Off` to `view_claimed`'s `Down`.
let flick_chain_down_ms : Double = 150.0

///|
/// Minimum residual and new release speed (points a ms, 500 dp/s) required to chain momentum.
let flick_chain_min_v : Double = 0.5

///|
/// Fraction of residual glide speed carried into a chained same-direction flick.
let flick_chain_carry : Double = 0.6

///|
/// How far before its top and its foot what it holds fades out, at most, where it goes on past them: as an old view's
/// box kept to a height's (ui's cut_soft_most).
let scroll_soft_most : Double = 24.0

///|
/// How long the wheel rests before its next turn is the hand set going anew (ms): a trackpad's momentum and a wheel
/// spun on come closer than this.
let wheel_anew_ms : Double = 200.0

///|
/// Below this (points a ms) a fling has stopped.
let scroll_stop_v : Double = 0.02

///|
/// How far a fling from `x0` at `v0` has gone `t` ms on, slowing by scroll_friction a ms: solved for the time, the same
/// at any frame rate.
fn scroll_fling_at(x0 : Double, v0 : Double, t : Double) -> Double {
  x0 + v0 * (@dmath.pow(scroll_friction, t) - 1.0) / @dmath.ln(scroll_friction)
}

///|
fn dmin(a : Double, b : Double) -> Double {
  if a < b {
    a
  } else {
    b
  }
}

///|
fn dmax(a : Double, b : Double) -> Double {
  if a > b {
    a
  } else {
    b
  }
}

///|
fn dclamp(v : Double, lo : Double, hi : Double) -> Double {
  dmax(lo, dmin(v, hi))
}

///|
/// Where it is at moment `t` (0 at its top, as far as it can go at most), as what is said of it now has it: followed
/// (where flung, the time: what reads it read again as it goes, till it is at rest).
fn Scroll::where_at(self : Scroll, t : Double) -> Double {
  let most = self.most_now()
  let top = self.top_now()
  match self.edge.get() {
    Some(e) => return dclamp(e.at(t), top, most)
    None => ()
  }
  match self.fling.get() {
    Some(f) =>
      if t >= f.end_t {
        dclamp(f.end_x, top, most)
      } else {
        match f.way {
          Some(w) => dclamp(w.at(f, t), top, most)
          None => dclamp(scroll_fling_at(f.x0, f.v0, t - f.t0), top, most)
        }
      }
    None =>
      match self.notch.get() {
        Some(n) =>
          dclamp(n.x0 + (if t - n.t0 >= n.end { n.total } else { ease_come(n.total, n.v0, t - n.t0, tau=n.tau) }), top, most)
        None => dclamp(self.x.get(), top, most)
      }
  }
}

///|
/// How far it is scrolled at the logic's moment of `tree` (the one it is in: what an event, a step or a test reads).
pub fn Scroll::at(self : Scroll, tree : Tree) -> Double {
  @signals.untracked(fn() { self.where_at(tree.logic_said()) })
}

///|
/// How far it is scrolled as what is drawn is drawn, followed: where it is on by itself (a fling, a page's list's wheel's
/// notches easing in), read again as the time goes till it is at rest; else as it stands. What works out what of what
/// it holds to make as it scrolls (a page's list built by the rows in sight) reads it so, never its own copy of how it
/// moves. Not what shows past an end (iOS's rubber band, Android's stretch: Scroll::past).
pub fn Scroll::drawn(self : Scroll, tree : Tree) -> Double {
  self.where_at(if self.goes_on() { tree.drawn_said() } else { 0.0 })
}

///|
/// What it holds above where it is grew by `d` (less, where less than 0: rows above those in sight measured anew, come
/// or gone), as of the logic's moment, a page's list's alone (Scroll::list): where it is and what it is on by itself
/// moved by as much, so what is in sight stays where it is drawn; a wheel's notches easing in go on as they were; a
/// fling goes on as it was from where it set out moved as much, its foot moved as much, its top where it is: where it
/// meets the end it goes to worked out again (later, sooner, or not at all, its top moved away from it or toward it),
/// what it brings past that end from then, at rest then. No scroll of the hand's: nothing told as scrolled (its bar).
/// What shows past an end stays as it is.
pub fn Scroll::grew_above(self : Scroll, d : Double) -> Unit {
  guard self.as_list else { @halt.saying("Scroll::grew_above: a page's list's (Scroll::list) alone") }
  if d == 0.0 {
    return
  }
  @signals.untracked(fn() {
    let t = match self.host {
      Some(v) => v.tree.logic_said()
      None => 0.0
    }
    self.x.set(self.x.get() + d)
    self.corrected = self.corrected + d
    // (the hand past its edge: where it has it now as much further, its foot too where it goes down; on from there by
    // its own way, its end then: what is laid out after worked out again as that is)
    match (self.edge.get(), self.host) {
      (Some(e), Some(v)) => {
        let x0 = e.at(t) + d
        let bound = if e.v > 0.0 { e.bound + d } else { 0.0 }
        // (at its foot it is at its foot still; at its top, on to it again)
        self.edge_planned(v, e, x0, t, bound)
      }
      _ => ()
    }
    match self.fling.get() {
      Some({ way: Some(w), .. } as f) => self.fling_grew(f, w, t, d)
      _ => ()
    }
    match self.notch.get() {
      Some(n) => self.notch.set(Some({ ..n, x0: n.x0 + d }))
      None => ()
    }
    self.offset_said()
    // (at rest when it now is: said again on its timeline)
    match self.host {
      // (the hand past its edge: said on by its own way, above)
      Some(_) if self.edge.get() is Some(_) => ()
      Some(v) => {
        self.list_settles(v, t)
        // (a fling down toward its foot: its foot where all of it is laid out as this change leaves it, worked out
        // then, however far it can go came out, the same or not)
        if self.fling.get() is Some({ v0, way: Some(_), .. }) && v0 > 0.0 {
          v.tree.once_laid_out(fn() {
            // (still scrolling in it, as it was: not let go meanwhile, nor said to scroll in another)
            match self.host {
              Some(h) if physical_equal(h.tree, v.tree) && h.live() is Some(_) && h.at == v.at && h.gen == v.gen =>
                self.foot_moved(v, v.tree.logic_said(), self.most(), laid=true)
              _ => ()
            }
          })
        }
      }
      None => ()
    }
  })
}

///|
/// How far it can go, as it was last laid out (0 before it first is).
pub fn Scroll::most(self : Scroll) -> Double {
  @signals.untracked(fn() { self.most_now() })
}

///|
/// How far it can go, as it was last laid out, followed (0 before it first is): what keeps room at what it holds' foot
/// by it (a list's room for what is tucked over its rows) reads it so.
pub fn Scroll::reach(self : Scroll) -> Double {
  self.most_now()
}

///|
/// Whether what it holds is taller than it, as last laid out, followed (asked once it scrolls: View::scrolls): what is
/// painted by that alone reads it (cut at its box only while it scrolls, as @kit.in_room's held list), never what lays
/// it out.
pub fn Scroll::goes(self : Scroll) -> Bool {
  self.most_now() > 0.0
}

///|
/// How far it can go as last laid out, followed (0 before it first is).
fn Scroll::most_now(self : Scroll) -> Double {
  match (self.room)() {
    Some(r) => dmax(r, 0.0)
    None => 0.0
  }
}

///|
/// How far up the hand takes it, followed (0 when nothing is tucked or while pulled open / active): for top fade-out
/// and overflow checks that should ignore a tucked header.
pub fn Scroll::tuck_height(self : Scroll) -> Double {
  self.top_now()
}

///|
/// Whether what it holds overflows past its resting top (`top_now`), followed: false on short lists whose only scroll
/// room is a tucked header.
pub fn Scroll::overflows_past_tuck(self : Scroll) -> Bool {
  self.most_now() - self.tuck_room.get() > self.top_now() + 0.5
}

///|
/// How far up the hand takes it, followed: its top (0); where what is tucked over its top (Scroll::tucks) ends, once
/// the hand took that out of sight, till it pulls on past there anew (Scroll::pulled): scrolled back up, what is tucked
/// stays out of sight (asked 2026-11-15: 「往上滚动的时候不应该滚出搜索框，只有到顶了后再次下拉才出现搜索」).
fn Scroll::top_now(self : Scroll) -> Double {
  guard self.tuck_shut.get() && self.tuck_at.get() is Some(at) && (self.tuck_kept)() else { return 0.0 }
  dmax(0.0, dmin(at, self.most_now()))
}

///|
/// Come to `x`: past where what is tucked over its top ends, that held as its top from now (Scroll::top_now).
fn Scroll::tuck_met(self : Scroll, x : Double) -> Unit {
  guard self.tuck_at.untracked() is Some(at) else { return }
  if x < at - 0.5 {
    self.pull_open = false
    return
  }
  if !self.pull_open {
    self.tuck_shut.set(true)
  }
}

///|
/// The hand set going on it at `t` anew (come down on it, a wheel after a pause): pulled toward its top from where it
/// is held for what is tucked (Scroll::top_now), it shows that (`pull_free`); a pull from before that showed nothing
/// held there again.
fn Scroll::hand_anew(self : Scroll, t : Double) -> Unit {
  self.pull_open = false
  self.tuck_met(@signals.untracked(fn() { self.where_at(t) }))
  self.pull_free = self.at_held_top(t)
}

///|
/// Pulled on toward its top past where it is held there (Scroll::top_now) by a hand set going from there: its top
/// its own again, what is tucked shown as it pulls.
fn Scroll::pulled(self : Scroll) -> Unit {
  self.pull_free = false
  self.pull_open = true
  self.tuck_owed = false
  self.tuck_shut.set(false)
}

///|
/// Whether it is at the top the hand takes it to (Scroll::top_now) at `t`, held there for what is tucked.
fn Scroll::at_held_top(self : Scroll, t : Double) -> Bool {
  @signals.untracked(fn() {
    let top = self.top_now()
    top > 0.0 && self.where_at(t) <= top + 0.5
  })
}

///|
/// Signed velocity (points a ms) of an active fling at moment `t`, or 0.0 if none is under way.
fn Scroll::fling_speed_at(self : Scroll, t : Double) -> Double {
  match self.fling.untracked() {
    Some(f) if t < f.end_t =>
      match f.way {
        Some(w) => (if f.v0 < 0.0 { -1.0 } else { 1.0 }) * w.speed(f.v0, t - f.t0)
        None => f.v0 * @dmath.pow(scroll_friction, t - f.t0)
      }
    _ => 0.0
  }
}

///|
/// Stopped where it is at `t` (a fling under way stopped there): where that is.
fn Scroll::stopped(self : Scroll, t : Double) -> Double {
  let x = @signals.untracked(fn() { self.where_at(t) })
  // (brought on past its edge: as far as it came)
  if self.edge.untracked() is Some(e) {
    (self.settle_off.val)()
    self.settle_off.val = fn() {  }
    self.edge.set(None)
    self.x.set(x)
    if !e.parked {
      self.scrolled_at(t)
    }
  }
  // (a page's list's notches easing in: as far as they came)
  if self.notch.untracked() is Some(_) {
    (self.settle_off.val)()
    self.settle_off.val = fn() {  }
    self.set_notch_landed(false)
    self.notch.set(None)
  }
  if self.fling.untracked() is Some(f) {
    (self.settle_off.val)()
    self.settle_off.val = fn() {  }
    self.fling.set(None)
    self.x.set(x)
    // (stopped on its way: it scrolled till now, no further: its bar's showing from here)
    if t < f.end_t {
      self.scrolled_at(t)
    }
  }
  self.x.set(x)
  self.tuck_met(x)
  x
}

///|
/// Put at `to` (down the column) at the logic's moment of the tree it scrolls in, read as far as it can go as it is
/// laid out (a list's first place, past what is tucked over its rows; its top again): what it was on by itself stopped
/// there, no scroll of the hand's (nothing told as scrolled: its bar). Not scrolling in a node yet, there as it comes to.
pub fn Scroll::put(self : Scroll, to : Double) -> Unit {
  self.caught_v = 0.0
  self.caught_at = -1.0e9
  match self.host {
    Some(v) if v.alive() => {
      let t = v.tree.logic_said()
      self.put_at = t
      self.stopped(t) |> ignore
    }
    _ => ()
  }
  self.x.set(dmax(to, 0.0))
  self.tuck_met(to)
  self.offset_said()
}

///|
/// Node `v`, made in what it scrolls, tucked out of sight over its top (a page's list's search, as iOS's are): put, as
/// `v` is first laid out in it, so far down that `v`'s foot is `cover()` under its top (what lies over its top: a bar),
/// once for it (made again with another node in its place, it is where it was put then, as far as the hand left it);
/// put there again while what it holds comes short of that as it is laid out, till the hand is on it; its foot keeping
/// the room it lacks to go there however few what it holds is (a page's list's: View::scrolls_window) while `kept()`
/// says so, whether `v` shows or not. Where `v` is laid out is its own reading, not its caller's. What of `v` lies under
/// what covers the top (all of it, tucked) is out of sight and takes no finger nor pointer there, nor is reached from
/// round it (Tree::input_bounds), wherever it is scrolled to. Taken out of sight by the hand, the hand brings it back
/// up no further than where `v` ends till it pulls on from there anew (Scroll::top_now).
pub fn Scroll::tucks(self : Scroll, v : View, cover : () -> Double, kept? : () -> Bool = fn() { true }) -> Unit {
  guard self.host is Some(host) && v.alive() else { return }
  // (what of it lies under what covers its top is out of sight: found by no finger nor pointer, Tree::tucked_bound)
  v.tree.nodes[v.at].tucked_under = Some((host.at, cover))
  v.tree.hits = v.tree.hits + 1
  self.tuck_kept = kept
  v.reacts(fn() { v.laid_size_told() is Some(_) }, fn(laid) {
    guard laid && self.tuck_at.untracked() is None else { return }
    // (not scrolled yet: where it is in what it holds is where it is laid out in it)
    let (_, vy, _, vh) = v.placed_window_now()
    let (_, hy, _, _) = host.placed_window_now()
    let at = vy - hy + vh - @signals.untracked(cover)
    self.tuck_owed = true
    self.tuck_at.set(Some(at))
    self.put(at)
  })
  // (said once for the node it scrolls in, however many times what is tucked is made in it)
  match self.tuck_in {
    Some(h) if h.at == host.at && h.gen == host.gen => return
    _ => ()
  }
  self.tuck_in = Some(host)
  let host_style = host.tree.nodes[host.at].flex.style
  let adaptive_window = self.whole is Some(_) && !self.across && host_style.grow == 0.0 && host_style.height_kind() == @flex.LEN_AUTO
  self.tuck_margin_sub = self.whole is None || adaptive_window
  if self.whole is None {
    host.reacts(at_start=false, fn() { (self.tuck_at.get(), (self.tuck_kept)()) }, fn(_) {
      host.tree.layout_marked_at(host.at)
    })
  } else if adaptive_window {
    // (adaptive virtualized lists (`s.whole is Some`, e.g. `hugs=true` sheets) subtract the tucked bar from
    // `held.margin_bottom` via `host.reacts` so the effect survives `v` unmounting while scrolled off-screen)
    let held_at = host.tree.nodes[host.at].scroll_held
    if held_at >= 0 {
      host.reacts(
        at_start=false,
        fn() {
          match self.tuck_at.get() {
            Some(at) if (self.tuck_kept)() => at
            _ => 0.0
          }
        },
        fn(tuck) {
          host.tree.nodes[held_at].flex.style.set_margin_bottom(Pt(-tuck))
          host.tree.layout_marked_at(host.at)
        },
      )
    }
  }
  // (as far as it goes with less than it is tall: its foot keeps the room it lacks to go there; put there again where it
  // came short of it as it was laid out, till the hand is on it. Uses signed `(self.room)()` rather than clamped
  // `self.reach()` so short lists inside fixed-height viewports reserve exact bottom room.)
  host.reacts(fn() { (self.tuck_at.get(), (self.room)(), (self.tuck_kept)(), self.tuck_exact.get()) }, fn(now) {
    // (not kept tucked (what is tucked in use): held at no top for it, what shows of it as it is)
    if !now.2 {
      self.tuck_shut.set(false)
    }
    let had = self.tuck_room.untracked()
    let want = match now {
      (Some(at), Some(room), true, true) => dmax(0.0, at - (room - had))
      _ => 0.0
    }
    if (want - had).abs() >= 0.5 {
      self.tuck_room.set(want)
      return
    }
    match now {
      (Some(at), Some(room), true, _) if self.tuck_owed && self.at(host.tree) < at - 0.5 && room >= at - 0.5 => self.put(at)
      _ => ()
    }
  })
  // (the hand on it, or it gliding: put there no more)
  host.reacts(fn() { host.pointed_in() || self.in_hand() || self.goes_on() }, fn(on) {
    if on {
      self.tuck_owed = false
    }
  })
  host.owns(fn() {
    match self.tuck_in {
      Some(h) if h.at == host.at && h.gen == host.gen => {
        self.tuck_owed = false
        self.tuck_margin_sub = false
        self.tuck_room.set(0.0)
        self.tuck_in = None
        self.tuck_kept = fn() { true }
      }
      _ => ()
    }
  })
  |> ignore
}

///|
/// Put at its foot however far that comes to be (where it is read, as far as it can go then; there still as that is
/// told otherwise, till it is moved: the hand, the wheel, a fling set out from there where it is then, Scroll::stopped),
/// what it was on by itself stopped (Scroll::put's).
fn Scroll::to_foot(self : Scroll) -> Unit {
  self.put(@double.infinity)
}

///|
/// What shows left where it is as what it holds grows, though it is a page's list at the foot it follows
/// (View::scrolls_window's `follows`): what the reader opens in a block there opens down from where the block is
/// (following its foot, the block went up as far as it opened, away from the hand that pressed it). Said at the press,
/// before what it opens. Followed again once the hand moves it, once it is back at its foot having left it, or as
/// blocks come or go while it has not left its foot (nothing opened after all). One that follows no foot, or is off
/// it: nothing.
pub fn Scroll::holds_here(self : Scroll) -> Unit {
  if self.at_foot() {
    self.held = true
    (self.held_said)()
  }
}

///|
/// Whether it is at its foot however far that comes to be (Scroll::to_foot), not moved off it since.
fn Scroll::at_foot(self : Scroll) -> Bool {
  self.x.untracked() == @double.infinity
}

///|
/// Whether it is at its foot, followed: told only as that comes to be so or stops (what follows the newest, a button
/// back to it, reads it), never as it scrolls on either side of that. A page's list's (View::scrolls_window) by its own
/// blocks as they are counted and its anchor, so in the same layout as a block measured anew or grown at its foot,
/// never a frame after it: at its foot where it follows it there, however far that comes to be, else where the top of
/// what shows is within half a point of where it would be at its foot. Else by how far it can go as last laid out.
pub fn Scroll::at_foot_now(self : Scroll) -> Bool {
  match self.at_foot_said {
    Some(f) => f()
    // (scrolling in nothing yet: where it is put)
    None => self.x.get() == @double.infinity
  }
}

///|
/// Whether it follows its foot, as what comes at it is to be followed (a chat's newest): told only as that comes to be
/// so or stops. A page's list's (View::scrolls_window): at its foot (Scroll::at_foot_now); held short of it by a
/// standing limit the reader has not moved it off (ListPlace::follow_from); or on its glide back to it
/// (ListPlace::to_end) not stopped by another way. Else whether it is at its foot.
pub fn Scroll::follows_now(self : Scroll) -> Bool {
  match scroll_follows_said.get(self.serial) {
    Some(f) => f()
    None => self.at_foot_now()
  }
}

///|
/// Whether it is on its glide back to its foot (a page's list's ListPlace::to_end), not stopped by another way (the
/// hand, the wheel, another ask): told only as that comes to be so or stops. A way back to its foot shows none
/// meanwhile, as the old view's list's `gliding`.
pub fn Scroll::glides_to_foot(self : Scroll) -> Bool {
  match scroll_glides_foot_said.get(self.serial) {
    Some(f) => f()
    None => false
  }
}

///|
/// Scrolled by the hand at `t` (the wheel, a finger, a fling, a part brought into sight): what is told so told (its
/// bar), and what hosts the tree that it moved (Scroll::offset_said).
fn Scroll::scrolled_at(self : Scroll, t : Double) -> Unit {
  for _, f in self.peers_scrolled {
    f(t)
  }
  self.offset_said()
}

///|
/// What it holds moved (or what it is on by itself set going or stopped), told the tree it scrolls in (Tree::offset_told):
/// what it moves by its offset alone (a page's list, its bar's thumb: Node's scroll_off) drawn moved by what hosts it,
/// nothing placed for it. Not scrolling in a node, nothing.
fn Scroll::offset_said(self : Scroll) -> Unit {
  match self.host {
    Some(v) if v.alive() => v.tree.offset_told(v.at)
    _ => ()
  }
}

///|
/// How far a page's list's held (node `at` of `tree`, up and down: Scroll::list) is drawn off where it is placed at `t`,
/// as far as it is scrolled and what shows past an end moves it (iOS's rubber band): by whole pixels, on its host's
/// grid where it sets the list's rows on it (the first row's top on a pixel wherever it is scrolled to, as it is placed:
/// Tree::rows_placed), else on the pixels the tree is drawn at (Tree::set_pixel_grid): what it holds drawn once, moved
/// so, its words stay on the pixels they were drawn on (an old view's list drew its boxes off by part of a pixel, its
/// words each set on a pixel as they came). Read as it is drawn, found or read out at a moment (Node's scroll_off),
/// nothing followed.
fn Scroll::held_dy(self : Scroll, tree : Tree, at : Int, t : Double) -> Double {
  self.drawn_off(tree, at, self.where_at(t), self.past_moved(t))
}

///|
/// Moved by `d` (down the column) at `t`, as far as it can go: whether it moved.
fn Scroll::moved(self : Scroll, t : Double, d : Double) -> Bool {
  let was = self.stopped(t)
  let to = dclamp(was + d, @signals.untracked(fn() { self.top_now() }), self.most())
  self.x.set(to)
  self.tuck_met(to)
  if to != was {
    self.scrolled_at(t)
  }
  to != was
}

///|
/// Brought to `to` at `t`, as far as it can go (a part of it brought into sight): whether it moved.
fn Scroll::sent(self : Scroll, t : Double, to : Double) -> Bool {
  let was = self.stopped(t)
  // (brought over the top it is held at for what is tucked (a part of that brought into sight): its own top again)
  if to < @signals.untracked(fn() { self.top_now() }) - 0.5 {
    self.pulled()
  }
  let to = dclamp(to, 0.0, self.most())
  self.x.set(to)
  if to != was {
    self.scrolled_at(t)
  }
  to != was
}

///|
/// Let go of at `t` at the hand's speed: flung on (held by `v`, at rest at its end: then where it is, at rest), or at
/// rest where it is.
fn Scroll::flung(self : Scroll, v : View, t : Double) -> Unit {
  let x0 = self.stopped(t)
  let v0 = self.hand_v
  let speed = v0.abs()
  if speed <= scroll_stop_v {
    return
  }
  let most = self.most()
  let top = @signals.untracked(fn() { self.top_now() })
  let lf = @dmath.ln(scroll_friction)
  let t_stop = @dmath.ln(scroll_stop_v / speed) / lf
  // (the end it goes to, if it gets there first: f^t = 1 + d ln f / v0)
  let bound = if v0 > 0.0 { most } else { top }
  let arg = 1.0 + (bound - x0) * lf / v0
  let t_hit = if arg > 0.0 { @dmath.ln(arg) / lf } else { 1.0e300 }
  let (t_end, end_x) = if t_hit < t_stop {
    (t_hit, bound)
  } else {
    (t_stop, dclamp(scroll_fling_at(x0, v0, t_stop), top, most))
  }
  if t_end <= 0.0 {
    return
  }
  let end_t = t + t_end.ceil()
  self.fling.set(Some({ x0, v0, t0: t, end_t, end_x, till: bound, way: None }))
  self.scrolled_at(t)
  // (what hosts the tree told it glides, which column it is and how to ask it when it ends now: Tree::on_glides)
  (v.tree.glides)(self.serial, fn() { self.glides_till() })
  // (at rest at its end, said on the timeline: then nothing reads the time for it)
  v.tree.hand_at_end(end_t)
  self.settle_off.val = v.at_moment(end_t, fn() {
    self.settle_off.val = fn() {  }
    // (scrolled till its end: told so while it still counts as under way, its bar's showing from there)
    self.scrolled_at(end_t)
    self.fling.set(None)
    // (within how far it can go as of then: what holds it may have come to be shorter meanwhile)
    let x = dclamp(end_x, @signals.untracked(fn() { self.top_now() }), self.most())
    self.x.set(x)
    self.tuck_met(x)
  })
}

///|
/// Gone on by itself at `speed` (points a ms, down the column or along the row; less than 0 toward its top or its
/// start) from where it is at the logic's moment, steady, till its end, as the hand held past its edge takes it (a
/// selection dragged out of it: an old view's select_edge); 0 stopped where it is. Said anew as the hand moves, it goes
/// on from where it is then at the new speed: where it is a function of the time, nothing stepped by frames. Not where
/// it scrolls in nothing (View::scrolls not said, or let go).
pub fn Scroll::edge_toward(self : Scroll, speed : Double) -> Unit {
  let active = match self.host {
    Some(v) if v.alive() => Some((v, self))
    _ => self.shown_peers().get(0)
  }
  guard active is Some((v, s)) else { return }
  @signals.untracked(fn() {
    let t = v.tree.logic_said()
    let x0 = s.stopped(t)
    if speed == 0.0 {
      return
    }
    // (from where it is, as far as it can go that way now: worked out, its end said, by edge_due)
    let bound = if speed > 0.0 { s.most() } else { s.top_now() }
    s.edge.set(Some({ x0, v: speed, t0: t, bound, end_t: t, parked: false }))
    s.edge_due(v, t)
  })
}

///|
/// Every currently alive and visible host node (and its `Scroll`) sharing this scroll group (`Scroll::beside`, or just
/// `self` when unshared).
pub fn Scroll::shown_peers(self : Scroll) -> Array[(View, Scroll)] {
  let out : Array[(View, Scroll)] = []
  self.peers_hosts.each(fn(_, pair) {
    if !pair.0.shown_nowhere() {
      out.push(pair)
    }
  })
  if out.is_empty() {
    match self.host {
      Some(v) if !v.shown_nowhere() => out.push((v, self))
      _ => ()
    }
  }
  out
}

///|
/// Where the hand past its edge has it at `t`, as far as its bound (as it was laid out as it was said).
fn Edge::at(self : Edge, t : Double) -> Double {
  if self.parked {
    return self.x0
  }
  let x = self.x0 + self.v * (dmax(t, self.t0) - self.t0)
  if self.v > 0.0 {
    dmin(x, self.bound)
  } else {
    dmax(x, self.bound)
  }
}

///|
/// The hand past its edge said on from where it has it at `t`, as far as it can go as laid out now: its end then, said
/// on the timeline (parked there); there already, parked now.
fn Scroll::edge_due(self : Scroll, v : View, t : Double) -> Unit {
  guard self.edge.untracked() is Some(e) else { return }
  let most = self.most()
  let top = @signals.untracked(fn() { self.top_now() })
  let x0 = dclamp(e.at(t), top, most)
  let bound = if e.v > 0.0 { most } else { top }
  self.edge_planned(v, e, x0, t, bound)
}

///|
/// The hand past its edge (`e`, as it was) said on from `x0` at `t` as far as `bound`: its end then said on the
/// timeline, told what hosts the tree (Tree::on_glides), parked there; there already, parked now.
fn Scroll::edge_planned(self : Scroll, v : View, e : Edge, x0 : Double, t : Double, bound : Double) -> Unit {
  (self.settle_off.val)()
  self.settle_off.val = fn() {  }
  let end_t = t + dmax(0.0, (bound - x0) / e.v).ceil()
  if end_t <= t {
    // (at its end: nothing moving, nothing reading the time; told so as it is there no more since now)
    self.edge.set(Some({ ..e, x0: bound, t0: t, bound, end_t: t, parked: true }))
    if !e.parked {
      self.scrolled_at(t)
    }
    return
  }
  self.edge.set(Some({ x0, v: e.v, t0: t, bound, end_t, parked: false }))
  self.scrolled_at(t)
  // (what hosts the tree told it goes on by itself, till when as it is asked: Tree::on_glides)
  (v.tree.glides)(self.serial, fn() { self.glides_till() })
  v.tree.hand_at_end(end_t)
  self.settle_off.val = v.at_moment(end_t, fn() {
    self.settle_off.val = fn() {  }
    self.scrolled_at(end_t)
    match self.edge.untracked() {
      Some(g) => self.edge.set(Some({ ..g, x0: g.bound, t0: end_t, end_t, parked: true }))
      None => ()
    }
  })
}

///|
/// What scrolls it or holds it nearest, up and down (`across` false) or across (Scroll::across): the column or the row
/// a hand held past its edge brings on (Scroll::edge_toward); none where nothing round it does.
pub fn View::scroll_holding(self : View, across? : Bool = false) -> Scroll? {
  // (a node let go of: nothing, whatever is in its place now)
  guard self.alive() else { return None }
  let mut at = self.at
  while at >= 0 {
    match self.tree.scrolls_at.get(at) {
      Some(s) if s.across == across && (s.host is Some(h) && h.alive()) => return Some(s)
      _ => ()
    }
    at = self.tree.nodes[at].parent
  }
  None
}

///|
/// Convenience scrollable column without declaring a `Scroll` state up front: creates `Scroll::new()` when `scroll` is
/// omitted, and fills its parent (`fill=true`) by default without overflowing flex containers.
#callsite(autofill(loc))
pub fn View::scroll_column(
  self : View,
  body : (View) -> Unit,
  scroll? : Scroll,
  fill? : Bool = true,
  bar? : ScrollBar,
  loc~ : SourceLoc,
) -> View {
  let s = match scroll {
    Some(s) => s
    None => Scroll::new()
  }
  self.scrolls(s, body, bar?, fill=false) |> ignore
  if fill {
    self.fill(loc~) |> ignore
  }
  self
}

///|
/// A column that scrolls up and down in it (see the file's head), `s` saying how far it is scrolled, `build` making
/// what it holds in the node that holds it all (laid out as tall as it is, drawn off by how far it is scrolled). It
/// gives way to nothing where what holds it is short of room (View::shrink, View::min_height). A hold that began on
/// what it holds is its own once it has moved `slop` (the window's points) up or down (View::claims; none: 8, a page's
/// list's its platform's, list_slop). `bar`: its bar
/// along its right, as that says (scroll_bar.mbt; none: none). Scrolling across (Scroll::across): a row, what it holds
/// laid out as wide as it is, given way to nothing across where what holds it is narrower; a hold its own once it moves
/// across past the slop; its bar along its foot, `bar_in` in from either end (under what it is for, where what it holds
/// reaches past that: Ctx::sideways's), over what it holds' foot, no room kept for it (the user, 2026-11-17:
/// 「滚动条不应该占位置，也不应该没有」, every container so). Every bar keeps clear of the round corners of what cuts
/// it (View::corner_clear). `top_covered`: down a column, how tall what lies over its top is now (the
/// bar a page's list runs under: its room), a live value its page says once (Scroll::top_covered); what is brought into
/// sight comes to rest under it. `bar_clear`: down a column, how much of its top and its foot its bar keeps clear of,
/// as it is now (by default what covers its top), as an old view's list's bar does. `bar_here`: whether this one has
/// its bar now, as that changes (one of several scrolled beside each other as one, Scroll::beside: the last of a long
/// table's pieces, its bar under its last row alone): the bar drawn only while it says so; a hand
/// on any of them shows it (Scroll's `peers_scrolled`). `for_in`: what holds the field whose choices it scrolls, its
/// keyboard kept as a finger scrolls them (View::claims' `for_in`).
pub fn View::scrolls(
  self : View,
  s : Scroll,
  build : (View) -> Unit,
  slop? : Double,
  bar? : ScrollBar,
  bar_in? : Double = 0.0,
  top_covered? : () -> Double = fn() { 0.0 },
  bar_clear? : () -> (Double, Double),
  bar_here? : () -> Bool,
  for_in? : NodeId,
  fill? : Bool = false,
) -> View {
  guard self.live() is Some(_) else { return self }
  self.mark_structure_own()
  // (where it says when it has it: drawn, and its room kept, only then)
  let bar = match (bar, bar_here) {
    (Some(b), Some(here)) => Some({ ..b, drawn: fn() { here() && (b.drawn)() } })
    _ => bar
  }
  let bar_room = match bar_here {
    Some(here) => here
    None => fn() { true }
  }
  let bar_clear = match bar_clear {
    Some(f) => f
    None => fn() { (top_covered(), 0.0) }
  }
  s.top_cover = if s.across { fn() { 0.0 } } else { top_covered }
  // (a page's list's as its platform's is as it is held: what hosts the tree may say it after it is made)
  let slop = fn() {
    match slop {
      Some(v) => v
      None => if s.as_list { list_slop((self.tree.list_feel)().0) } else { 8.0 }
    }
  }
  s.host = Some(self)
  s.peers_hosts[self.at] = (self, s)
  // (at its foot, told only as that changes: a page's list says it by its blocks (View::scrolls_window); else by how
  // far it can go as last laid out, where it is drawn)
  if s.at_foot_said is None && !s.across {
    // (scoped: read once outside any reader, it lets go of what it read again, as a page's list's does)
    let at_foot = @signals.computed_scoped(fn(_) {
      let most = s.most_now()
      s.x.get() == @double.infinity || s.drawn(self.tree) >= most - 0.5
    }, same=fn(a, b) { a == b })
    s.at_foot_said = Some(fn() { at_foot.get() })
  }
  // (its keys, down a column: Home, End, the pages, the lines, as an old view's list's: scroll_keys.mbt)
  if !s.across {
    self.scroll_keys(s)
  }
  // (found by what it holds: View::scroll_holding)
  self.tree.scrolls_at[self.at] = s
  // (in a page's list's block taken for other keys: how far it is scrolled the key's, kept and put back by the list,
  // reused_state.mbt)
  self.tree.reused_scroll(self, s)
  let across = s.across
  // (how tall it is, as it is asked: what shows past its ends is in its heights; across, how wide)
  s.tall = fn() { if self.live() is Some(n) { if across { n.flex.width } else { n.flex.height } } else { 0.0 } }
  let inner : Ref[View?] = Ref(None)
  self.clips(Is(true)).bounds_input(Is(true)) |> ignore
  // (across: a row, what it holds laid out along it as wide as it is; narrower than that where what holds it is)
  if across {
    self.row(Is(true)).min_width(Is(Some(0.0))) |> ignore
  } else {
    self.shrink(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
  }
  if fill {
    self.fill() |> ignore
  }
  // (what it holds laid out as tall as it is, whatever room it has: its content's own height, as CSS's overflow scroll
  // has it)
  self.tree.nodes[self.at].flex.style.overflow = @flex.Overflow::Scroll
  self.tree.soft_min_applied(self.at)
  self.tree.layout_marked_at(self.at)
  // (how far it can go and how big it shows what it holds, worked out as it is laid out, in that same layout: what it
  // holds measured there (as tall as it comes to; across, as wide), the room it shows it in its own; what reads them
  // said again there, in it; never told back once all of it is laid out)
  let reach : @signals.Signal[Double?] = @signals.signal(None, same=fn(a, b) { a == b })
  s.room = fn() { reach.get() }
  let tree = self.tree
  let me = self.at
  // (what it holds measured as it is laid out, how far it can go and how big it shows it told: whether either came out
  // otherwise)
  // (how big what it holds came to as it was last measured, and, where what holds it measured it by what it holds, how
  // big that made it and the most it could be: made otherwise as it is laid out (what shows measured anew), what holds
  // it laid out again by it)
  let last_whole = Ref(0.0)
  let sized_by : Ref[(Int, Double, Double)?] = Ref(None)
  let adaptive_gen : Ref[Int] = Ref(-1)
  let tucked_h = fn() -> Double {
    match s.tuck_at.get() {
      Some(at) if (s.tuck_kept)() => at
      _ => 0.0
    }
  }
  // (how big what it holds comes to, its natural height without tucked header/padding, and how big it shows it, given
  // `w` by `h` so)
  let sizes = fn(held : View, w : Double, wm : @flex.MeasureMode, h : Double, hm : @flex.MeasureMode) -> (Double, Double, Double) {
    let hs = tree.nodes[held.at].flex.style
    let pt = fn(k : Int, x : Double) { if k == @flex.LEN_PT { x } else { 0.0 } }
    if across {
      let along = pt(hs.margin_left_kind(), hs.margin_left_value()) +
        pt(hs.margin_right_kind(), hs.margin_right_value())
      let size = @flex.measured_width(tree.nodes[held.at].flex, 0.0 / 0.0) + along
      (size, size, if wm is Undefined { size } else if wm is AtMost { dmin(size, w) } else { w })
    } else {
      let side = pt(hs.margin_left_kind(), hs.margin_left_value()) +
        pt(hs.margin_right_kind(), hs.margin_right_value())
      let along = pt(hs.margin_top_kind(), hs.margin_top_value()) +
        pt(hs.margin_bottom_kind(), hs.margin_bottom_value())
      let held_h = match s.whole {
        Some(f) => f()
        None => @flex.measured_height(tree.nodes[held.at].flex, dmax(0.0, w - side))
      }
      let tuck = @signals.untracked(tucked_h)
      // (`held.margin_bottom` subtracts `tuck` when `tuck_margin_sub` is set so flex sizes adaptive containers
      // without the tucked header; add it back only then for total scrollable `whole`)
      let tuck_margin = if s.tuck_margin_sub { tuck } else { 0.0 }
      let whole = held_h + along + tuck_margin
      let natural = dmax(0.0, whole - s.tuck_room.untracked() - tuck)
      (whole, natural, if hm is Undefined { natural } else if hm is AtMost { dmin(natural, h) } else { h })
    }
  }
  // (a press in what it holds, down a column that is no page's list (a page's list holds its own: View::scrolls_window),
  // press_stays.mbt: what lies over what was pressed (each node before it or before what holds it, down a column), how
  // tall that was then and where it was scrolled to; none once the hand moves it or all the press set off has ended.
  // Where it was put for that last, and the room kept under what it holds for it: as much as that asks while it is
  // held, then no more than still shows of it)
  let press_pin : Ref[(View, Array[View], Double, Double)?] = Ref(None)
  let press_put = Ref(0.0)
  let press_ends = Ref(false)
  let press_unpin : Ref[() -> Unit] = Ref(fn() {  })
  let press_room : @signals.Signal[Double] = @signals.signal(0.0, same=fn(a, b) { a == b })
  let over_h = fn(over : Array[View]) {
    let mut h = 0.0
    for o in over {
      if o.alive() && tree.nodes[o.at].flex.style.display != @flex.Display::DisplayNone {
        h = h + @flex.measured_height(tree.nodes[o.at].flex, tree.nodes[o.at].flex.width)
      }
    }
    h
  }
  // (held by what was pressed, as it is laid out showing `shown` of `whole`: put where that is, the room under
  // it as that asks; held no more, that room no more than still shows)
  let press_held = fn(whole : Double, shown : Double) -> Bool {
    let room_was = press_room.untracked()
    let x = s.x.untracked()
    let base = whole - press_room.untracked()
    match press_pin.val {
      // (moved since by the hand, or put elsewhere, or what was pressed or what was over it let go: held no more)
      Some((v, over, _, _)) if x != press_put.val || !v.alive() || over.iter().any(fn(o) { !o.alive() }) => {
        press_pin.val = None
        (press_unpin.val)()
      }
      _ => ()
    }
    match press_pin.val {
      Some((_, over, was, x0)) => {
        let want = dmax(0.0, x0 + over_h(over) - was)
        press_room.set(dmax(0.0, want - (base - shown)))
        if want != x {
          s.x.set(want)
          s.offset_said()
        }
        press_put.val = want
        if press_ends.val {
          press_ends.val = false
          press_pin.val = None
        }
      }
      None => {
        let left = dmax(0.0, x + shown - base)
        if left < press_room.untracked() {
          press_room.set(left)
        }
      }
    }
    press_room.untracked() != room_was
  }
  if !across && s.whole is None {
    s.pressed_said = fn(v) {
      guard inner.val is Some(held) && held.alive() else { return fn() {  } }
      let over : Array[View] = []
      let mut i = v.at
      while i >= 0 && i != held.at {
        let up = tree.nodes[i].parent
        if up >= 0 && tree.nodes[up].flex.style.direction is Column {
          for c in tree.nodes[up].kids {
            if c == i {
              break
            }
            over.push(tree.handle(c))
          }
        }
        i = up
      }
      guard i == held.at else { return fn() {  } }
      let was = over_h(over)
      let x0 = s.x.untracked()
      fn() {
        (press_unpin.val)()
        press_pin.val = Some((v, over, was, x0))
        press_put.val = x0
        press_ends.val = false
        press_unpin.val = self.at_moment(tree.cause_now() + @flex.move_most_ms, fn() {
          press_ends.val = true
          tree.layout_marked_at(me)
        })
      }
    }
  }
  let measure_reach = fn(held : View, w : Double, wm : @flex.MeasureMode, h : Double, hm : @flex.MeasureMode) -> Bool {
    let (whole, natural, shown) = {
      let (whole, natural, shown) = sizes(held, w, wm, h, hm)
      // (the room under it for what was pressed changed: measured again with it)
      if !across && s.whole is None && press_held(whole, shown) {
        tree.room_bindings_run()
        sizes(held, w, wm, h, hm)
      } else {
        (whole, natural, shown)
      }
    }
    last_whole.val = natural
    let seen_now = Some(if across { (shown, h) } else { (w, shown) })
    let reach_now = Some(whole - shown)
    let exact_now = (if across { wm is Exactly } else { hm is Exactly }) &&
      (adaptive_gen.val != @flex.computes() || tree.nodes[me].flex.style.grow > 0.0)
    let changed = @signals.untracked(fn() {
      s.seen.get() != seen_now || reach.get() != reach_now || (s.tuck_in is Some(_) && s.tuck_exact.get() != exact_now)
    })
    // (told as one: where its fill puts it, how big it shows and how far it can go, so what follows where it is
    // scrolled to reads them together, never the one told and the other as it was (a list brought to an entry 969 down
    // read at its top, how far it could go none yet, and asked for the page before; a page come in over what shows
    // moving the scroll before how far it goes was told, clamped to how far it went before))
    @signals.start_batch()
    let put = s.fill_put
    s.fill_put = fn() {  }
    put()
    s.seen.set(seen_now)
    reach.set(reach_now)
    s.tuck_exact.set(exact_now)
    @signals.end_batch()
    tree.room_bindings_run()
    changed
  }
  match self.live() {
    Some(n) => {
      n.flex.room = true
      n.flex.measure = Some(fn(w, wm, h, hm) {
        guard inner.val is Some(held) && held.alive() else { return (0.0, 0.0) }
        let performing = @flex.performing()
        let marked = tree.in_room(me, fn() {
          // (the room it is laid out in, or one it is given exactly as it is measured first: not one it is only measured
          // within, which what is made by it would be made again by, and back)
          let given = fn(m : @flex.MeasureMode, v : Double) { if performing || m is Exactly { Some(v) } else { None } }
          // (how tall it shows: exactly as given, or within the most it may be, or bound by nothing; none told where it
          // is only measured within a room)
          let tall_given = if hm is Exactly {
            Some((Some(h), h))
          } else if performing {
            Some((None, if hm is AtMost { h } else { @double.infinity }))
          } else {
            None
          }
          (s.fill)(given(wm, w), tall_given, performing)
          // (laid out; or a row that scrolls across measured within a width (what holds it measuring first how tall it
          // comes to, its bar's room under it counted by how far it can go there): how far it can go and how big it
          // shows what it holds told. Down a column only measured within a room, neither is told: how big what it holds
          // comes to is kept for what holds it to be laid out again by, below, no more. The room it is measured within
          // is not the one it shows in (one taking what is left under a head is measured within all of its column
          // first), and what is told is acted on: where it is scrolled to put no further than it could go in that
          // room, a page's list then at its foot there taken to follow it (an agent's history beside its chat,
          // 2026-11-10: every move of the hand up from its foot undone as a row came to show))
          let told = performing || (across && !(wm is Undefined))
          if !performing && !(if across { wm is Exactly } else { hm is Exactly }) {
            adaptive_gen.val = @flex.computes()
          }
          if told || !(hm is Undefined) {
            if told {
              // (what reads them may change what it holds (room kept at its foot for its bar, or for what is tucked
              // over its top): measured again till it comes out as it was, in this same layout)
              let mut rounds = 0
              while measure_reach(held, w, wm, h, hm) {
                // (what shows of it made again by that: made and measured in turn)
                (s.fill)(None, None, true)
                rounds = rounds + 1
                if rounds > 8 {
                  @halt.saying("View::scrolls: how far it can go changes what it holds and that how far it can go, on and on")
                }
              }
            } else {
              last_whole.val = sizes(held, w, wm, h, hm).1
            }
            let (m, most) = if across { (wm, w) } else { (hm, h) }
            if !performing && !(m is Exactly) {
              // (measured by what it holds, within the most it may be: as big as that made it; within the same
              // compute pass a parent's perform pre-measure can re-measure with a tighter inner_h, which must not
              // overwrite the outer hugs container's real cap `most`, while still updating `was` for the current width)
              let gen = @flex.computes()
              let most = if m is AtMost { most } else { @double.infinity }
              let most = match sized_by.val {
                Some((g, _, prev_most)) if g == gen && prev_most > most => prev_most
                _ => most
              }
              sized_by.val = Some((gen, dmin(last_whole.val, most), most))
            } else if performing {
              // (laid out as big as what it held made it as it was measured, what it holds now another size within the
              // most it may be: what holds it laid out again by that once all of it is (outside its room, Tree::in_room))
              match sized_by.val {
                Some((g, was, most)) => {
                  sized_by.val = None
                  let target = dmin(last_whole.val, most)
                  let cur = if across { w } else { h }
                  if g == @flex.computes() &&
                    (target - was).abs() > 0.5 &&
                    (!(m is Exactly) || (target - cur).abs() > 0.5) {
                    tree.room_spill.push(me)
                  }
                }
                None => ()
              }
            }
          }
        })
        (if marked { 1.0 } else { 0.0 }, 0.0)
      })
    }
    None => ()
  }
  self.box(fn(held) {
    inner.val = Some(held)
    self.tree.nodes[self.at].scroll_held = held.at
    self.tree.nodes[self.at].scroll_across = across
    self.tree.soft_min_applied(self.at)
    self.tree.soft_min_applied(held.at)
    // (a page's list's rows set on its host's pixels as an old view's list's are: Tree::set_rows_grid)
    // (a page's list's, down a column, drawn off by how far it is scrolled by its offset alone, read as it is drawn
    // (Node's scroll_off): nothing of it placed again as it scrolls, what it holds drawn as it was, moved by what hosts
    // the tree; on iOS moved past its end as far as its rubber band shows it)
    if s.as_list && !across {
      if s.rows_list {
        self.tree.rows_list(held.at)
      }
      let lists = self.tree.lists_scrolled
      let at = self.at
      lists[at] = s
      self.owns(fn() { lists.remove(at) }) |> ignore
      let hn = self.tree.nodes[held.at]
      hn.scroll_by = self.at
      let tree = self.tree
      let at = held.at
      hn.scroll_off = Some(fn(t) { (0.0, s.held_dy(tree, at, if s.goes_on() { t } else { 0.0 })) })
      held.shrink(Is(0.0)) |> ignore
    } else {
      held
      .shrink(Is(0.0))
      .offset(By(fn() {
        let t = if s.goes_on() { held.tree.drawn_said() } else { 0.0 }
        if across {
          (-s.where_at(t), 0.0)
        } else {
          (0.0, -s.where_at(t) + s.past_moved(t))
        }
      }))
      |> ignore
    }
    // (down a column: room under what it holds for what was pressed in it (press_stays.mbt) and for a tucked header
    // on short lists (`tuck_room`), less `tucked_h` so adaptive containers (`AtMost`/`Undefined`) size to the visible
    // content without the tucked header)
    if !across && s.whole is None {
      held.margin(By(fn() { (0.0, 0.0, 0.0, press_room.get() + s.tuck_room.get() - tucked_h()) })) |> ignore
    }
    build(held)
  })
  |> ignore
  // (its bar, over what it holds, told as it scrolls; where it says when it has it (`bar_here`), made as it first does:
  // nothing made for one of several beside each other that never has it)
  match bar {
    Some(b) => {
      let made = Ref(false)
      let make = fn() {
        guard !made.val else { return }
        made.val = true
        // (a fling under way: till its end, as it is now, none once stopped)
        let state = BarState::new(fn() {
          match (s.fling.get(), s.edge.get()) {
            (Some(f), _) => f.end_t
            // (the hand past its edge: till its end as said now)
            (None, Some(e)) => e.end_t
            (None, None) => -1.0e9
          }
        })
        self.scroll_bar(s, b, state, bar_in~, bar_clear~)
        // (by the hand where it is on nothing by itself: Scroll::goes_on)
        s.peers_scrolled[self.at] = fn(t) {
          state.woke(b, self, t, scrolled=true, by_hand=!@signals.untracked(fn() { s.goes_on() }))
        }
      }
      if @signals.untracked(bar_room) {
        make()
      } else {
        self.reacts(bar_room, fn(on) { if on { make() } }, at_start=false)
      }
    }
    None => ()
  }
  // (stretched where Android's list is past an end, as it is drawn, one that moves as a page's list does: View::stretches)
  if s.as_list {
    self.stretches(By(fn() { s.stretch_drawn(if s.goes_on() { self.tree.drawn_said() } else { 0.0 }) })) |> ignore
  }
  // (what it holds faded out towards its top and its foot where it goes on past them, as far as it does, at most
  // scroll_soft_most: an old view's capped's fade_to; by the time while flung, as it is drawn. Every box that scrolls in
  // what holds it so, however it moves (Scroll::new's as a page's list does too: a panel's list, a menu, a card cut
  // mid-row is cut softly, never sharply); a page's own list's not (Scroll::list), as an old view's list's is not: its
  // ends are the window's or its bars')
  if !s.rows_list {
    self.fades(By(fn() {
      // (where it is as drawn, the time read while what it is on by itself has an end said: Scroll::rest_now)
      let x = s.where_at(if s.rest_now() is Some(_) { self.tree.drawn_said() } else { 0.0 })
      let top = if across { 0.0 } else { s.top_now() }
      let most = s.most_now()
      let (a, b) = (dclamp(x - top, 0.0, scroll_soft_most), dclamp(most - x, 0.0, scroll_soft_most))
      // (across: towards its start and its end)
      if across {
        (a, 0.0, b, 0.0)
      } else {
        (0.0, a, 0.0, b)
      }
    }))
    |> ignore
  }
  // (how far it can go told otherwise as it is laid out: where it is put within that, then and after, a fling under way
  // stopped where it is then; as an old view's box kept to a height is, sideways_after_layout)
  // (not laid out yet: how far it can go not known, nothing put)
  self.reacts(fn() { (s.room)().map(fn(r) { dmax(r, 0.0) }) }, fn(known) {
    guard known is Some(most) else { return }
    let t = self.tree.logic_said()
    // (the hand past its edge: on from where it has it now as far as it can go now, its end then; parked at its end, on
    // again where it can go further)
    match s.edge.untracked() {
      Some(e) if e.bound != (if e.v > 0.0 { most } else { @signals.untracked(fn() { s.top_now() }) }) || e.x0 > most =>
        s.edge_due(self, t)
      _ => ()
    }
    // (a page's list's fling down toward its foot meets it where it is as laid out now: worked out again)
    if s.as_list {
      s.foot_moved(self, t, most)
    }
    // (a box kept to a height's fling past how far it can go now: stopped there; a page's list's meets its foot instead,
    // worked out just now)
    if !s.as_list &&
      s.fling.untracked() is Some(_) &&
      @signals.untracked(fn() { s.where_at(t) }) >= most {
      s.stopped(t) |> ignore
    }
    // (no further than it can go, but at its foot however far that comes to be: Scroll::to_foot)
    if s.x.untracked() > most && !s.at_foot() {
      s.x.set(most)
    }
  })
  // (let go with it: no fling of it settles after)
  self.owns(fn() {
    match self.tree.scrolls_at.get(self.at) {
      Some(o) if physical_equal(o, s) => self.tree.scrolls_at.remove(self.at)
      _ => ()
    }
    s.peers_scrolled.remove(self.at)
    match s.peers_hosts.get(self.at) {
      Some((h, _)) if h.same(self) => s.peers_hosts.remove(self.at)
      _ => ()
    }
    guard s.host is Some(h) && h.same(self) else { return }
    // (no finger on it after it)
    s.hand_fingers.clear()
    s.hand_cum = 0.0
    s.hand_track.reset()
    s.caught_v = 0.0
    s.caught_at = -1.0e9
    // (the hand past its edge: at rest where it had it then, as far as it could go as it was said: how far it can go is
    // gone with what it was laid out in, as a fling's below)
    match s.edge.untracked() {
      Some(e) if s.peers_hosts.is_empty() => {
        s.edge.set(None)
        s.x.set(e.at(self.tree.logic_said()))
      }
      _ => ()
    }
    // (a fling under way at rest where it was then: nothing reads the time for it after)
    match s.fling.untracked() {
      Some(f) => {
        let t = self.tree.logic_said()
        let at = if t >= f.end_t {
          f.end_x
        } else {
          match f.way {
            Some(w) => w.at(f, t)
            None => scroll_fling_at(f.x0, f.v0, t - f.t0)
          }
        }
        s.fling.set(None)
        s.x.set(at)
      }
      None => ()
    }
    // (what shows past an end of a page's list gone with it, going back or not: nothing of it at rest after)
    s.past.set(None)
    // (a page's list's notches easing in at rest where they had come to)
    if s.notch.untracked() is Some(_) {
      let at = @signals.untracked(fn() { s.where_at(self.tree.logic_said()) })
      s.set_notch_landed(false)
      s.notch.set(None)
      s.x.set(at)
    }
    (s.settle_off.val)()
    s.settle_off.val = fn() {  }
    s.room = fn() { None }
    s.held = false
    s.held_said = fn() {  }
    s.pressed_said = fn(_) { fn() {  } }
    s.read_from_said = fn(_) {  }
    s.keys_start = fn() { 0.0 }
    s.sought_said = fn(_, _) {  }
    // (whether it is at its foot, by what it held: said again by what scrolls in it next; till then where it is put.
    // Kept, it held all it read (a page's list's blocks and keys) past its going, read again by any that asks it)
    s.at_foot_said = None
    s.set_follows_said(None)
    s.set_glides_foot_said(None)
    s.set_notch_landed(false)
    s.fill = fn(_, _, _) {  }
    s.fill_put = fn() {  }
    s.whole = None
    s.seen.set(None)
    s.tall = fn() { 0.0 }
    s.foot_covered = fn() { 0.0 }
    s.foot_clear = fn() { 0.0 }
    s.top_cover = fn() { 0.0 }
    s.foot_at = -1
    s.host = None
    s.to_foot = fn(_) { false }
    // (no glide of it told any more: Tree::on_glides)
    (self.tree.glides_gone)(s.serial)
  })
  |> ignore
  // (the soft keyboard come up or gone down: what the focus is kept in sight by down it placed anew in this same pass,
  // whether anything laid out reads the keyboard or not (Tree::holds_now: its room read as it is now))
  if !across {
    let tree = self.tree
    let at = self.at
    self.reacts(fn() { (tree.env.keyboard_inset)() }, fn(_) { if tree.focus_holds.contains(at) { tree.marked() } }, at_start=false)
  }
  self
  // (the wheel up or down more than across, as an old view's box kept to a height takes it: sideways_wheel_moves)
  .on_wheel_moves(fn(w) {
    // (a pinch zooms, never scrolls: an old view's list takes none of it either)
    guard (w.mods & wheel_pinch) == 0 else { return false }
    // (across: the wheel across more than up or down, as an old view's box scrolled sideways takes it, as far as it
    // goes that way: sideways_wheel_moves)
    if across {
      guard w.dx != 0.0 && w.dx.abs() >= w.dy.abs() else { return false }
      let ok = s.moved(w.at, w.dx)
      if ok {
        s.caught_v = 0.0
        s.caught_at = -1.0e9
      }
      return ok
    }
    guard w.dy != 0.0 && w.dy.abs() >= w.dx.abs() else { return false }
    // (the hand on it: what it kept in sight for the focus kept no more, Tree::holds_now)
    self.tree.focus_holds.remove(self.at) |> ignore
    // (a wheel after a pause is the hand set going anew (a browser's wheel says no more): turned toward the top from
    // where it is held for what is tucked, that shows; turned on with no pause (a trackpad's momentum, a wheel spun on),
    // it stays held)
    let anew = w.at - s.wheel_last >= wheel_anew_ms
    s.wheel_last = w.at
    if anew {
      s.hand_anew(w.at)
    }
    if s.pull_free && w.dy < 0.0 {
      // (from where it is held: what it was on by itself there, toward the top, stopped first)
      s.stopped(w.at) |> ignore
      s.pulled()
    }
    // (turned away from the top first: no pull of this turning)
    s.pull_free = false
    // (a page's list's fling stopped as the wheel comes, what shows past an end going on back as it was)
    // (a wheel's notch eased in, as an old view's list's is: Ctx::ease_list)
    if s.as_list {
      s.wheel_stops(self, w.at)
      if (w.mods & wheel_notch) != 0 {
        let ok = s.notched(self, w.at, w.dy)
        if ok {
          s.caught_v = 0.0
          s.caught_at = -1.0e9
          s.wheel_at = w.at
        }
        return ok
      }
    }
    let ok = s.moved(w.at, w.dy)
    if ok {
      s.caught_v = 0.0
      s.caught_at = -1.0e9
      s.wheel_at = w.at
    }
    ok
  })
  // (a hold that began on what it holds (a button, a field of an old view's, nothing that takes a press) its own once
  // it moves up or down past the slop, more than across, the way it can still go: else what holds it is asked)
  .claims(fn(dx, dy) {
    // (not by a pointer that drags nothing that scrolls, up or down or across: Tree::pointer_drags_scroll)
    if !(self.tree.drags_scroll)() {
      s.claimed = false
      return false
    }
    let x = s.at(self.tree)
    // (across: along the row, what holds it asked what goes up or down)
    let (along, other) = if across { (dx, dy) } else { (dy, dx) }
    // (a page's list's pulled past its end, where its platform's is)
    let can = (if along < 0.0 { x < s.most() } else { x > 0.0 }) ||
      (s.as_list && (self.tree.list_feel)().0 != Desktop)
    let takes = along.abs() > slop() && along.abs() >= other.abs() && can
    s.claimed = takes
    takes
  }, scrolls=true, for_in?)
  // (held, its own terms: what it holds moved as far as the hand, as big as it is drawn; multiple fingers at once, the
  // last down leading it, others' moves kept without moving it, velocity tracked over cumulative driven deltas)
  .on_drag(fn(d) {
    // (where the hand is along it, in its own terms and the window's, and how fast: across, along the row)
    let (hy, hwy) = if across { (d.x, d.wx) } else { (d.y, d.wy) }
    match d.kind {
      Down => {
        // (the hold's first finger (Tree::drag_at's downs: this one alone): it set going anew, what was kept of a hold
        // ended untold (its on_drag let go) let go of; another down beside it leads it from here, nothing else anew)
        let first_finger = self.tree.downs.length() <= 1
        if first_finger {
          s.hand_fingers.clear()
          // (the hand on it: what it kept in sight for the focus kept no more, Tree::holds_now)
          self.tree.focus_holds.remove(self.at) |> ignore
          let gv = s.fling_speed_at(d.at)
          if gv != 0.0 {
            s.caught_v = gv
            s.caught_at = d.at
          } else if d.at - s.caught_at > flick_chain_down_ms {
            s.caught_v = 0.0
            s.caught_at = -1.0e9
          }
          // (what shows past an end of a page's list caught where it shows: held by the finger from there)
          if s.as_list {
            s.past_held(d.at)
          }
          s.stopped(d.at) |> ignore
          s.hand_anew(d.at)
          s.hand_v = 0.0
          s.hand_on.set(true)
        }
        if first_finger || s.hand_track.count() <= 1 {
          s.hand_cum = 0.0
          s.hand_track.reset()
          let said = if across { d.speed.across } else { d.speed.down }
          match said {
            Some(tr) => tr.seed_deltas(s.hand_track, hwy)
            None => s.hand_track.add(d.at, 0.0)
          }
        }
        s.hand_fingers.retain(fn(f) { f.0 != d.finger })
        s.hand_fingers.push((d.finger, hy, hwy))
      }
      Moved => {
        guard s.hand_fingers.search_by(fn(f) { f.0 == d.finger }) is Some(i) else { return }
        let (_, prev_y, prev_wy) = s.hand_fingers[i]
        // (where it is kept, leading or not: what leads it again goes on from there)
        s.hand_fingers[i] = (d.finger, hy, hwy)
        guard i == s.hand_fingers.length() - 1 else { return }
        let dw = hwy - prev_wy
        s.hand_cum = s.hand_cum + dw
        s.hand_track.add(d.at, s.hand_cum)
        // (taken over by a move: held from there, though its press went down on what it holds)
        s.hand_on.set(true)
        // (taken over: the first move from where it went down past the slop alone, in the window's points, as big
        // in its own terms as it is drawn)
        let mut dy = hy - prev_y
        if s.claimed && dw != 0.0 {
          s.claimed = false
          let past = if dw > 0.0 { dmax(dw - slop(), 0.0) } else { dmin(dw + slop(), 0.0) }
          dy = dy * past / dw
        }
        // (pulled toward its top from where it was held for what is tucked as the hand came down: that shows)
        if s.pull_free && dy > 0.0 && !across {
          s.pulled()
        } else if dy < 0.0 {
          // (moved away from the top first: no pull of this hold)
          s.pull_free = false
        }
        if s.as_list {
          s.dragged(self, d.at, -dy)
        } else {
          s.moved(d.at, -dy) |> ignore
        }
      }
      // (let go: flung at the cumulative driven speed as of then, chained with caught glide momentum when repeated
      // quickly in the same direction; another finger still on it, it goes on by that one, nothing flung)
      Up => {
        let prev_wy = match s.hand_fingers.search_by(fn(f) { f.0 == d.finger }) {
          Some(i) => s.hand_fingers[i].2
          None => hwy
        }
        s.hand_fingers.retain(fn(f) { f.0 != d.finger })
        if !s.hand_fingers.is_empty() {
          return
        }
        s.hand_on.set(false)
        s.pull_free = false
        s.claimed = false
        let up_dw = hwy - prev_wy
        if up_dw != 0.0 {
          s.hand_cum = s.hand_cum + up_dw
          s.hand_track.up(d.at, s.hand_cum)
        }
        let hvy = s.hand_track.velocity_at(d.at)
        let (_, _, sc) = self.tree.placed(self.at)
        let scale = if sc > 0.0 { sc } else { 1.0 }
        let base_v = dclamp(-hvy, -scroll_most_v, scroll_most_v) / scale
        s.hand_v = if s.caught_v * base_v > 0.0 &&
          d.at - s.caught_at <= flick_chain_ms &&
          base_v.abs() >= flick_chain_min_v &&
          s.caught_v.abs() >= flick_chain_min_v &&
          s.past.untracked() is None {
          dclamp(
            base_v + s.caught_v * flick_chain_carry,
            -scroll_chain_most_v / scale,
            scroll_chain_most_v / scale,
          )
        } else {
          base_v
        }
        s.caught_v = 0.0
        s.caught_at = -1.0e9
        if s.as_list {
          s.let_go(self, d.at)
        } else {
          s.flung(self, d.at)
        }
      }
      // (called off: a page's list's let go of still; told once a finger down (Tree::drag_at), let go once)
      Off => {
        if s.hand_fingers.is_empty() && !s.hand_on.untracked() {
          return
        }
        s.hand_fingers.clear()
        s.hand_cum = 0.0
        s.hand_track.reset()
        s.claimed = false
        s.hand_on.set(false)
        s.pull_free = false
        if s.as_list {
          s.hand_v = 0.0
          s.let_go(self, d.at)
        } else {
          s.stopped(d.at) |> ignore
        }
      }
    }
  }, fingers=10)
  // (a part of what it holds brought into sight: its top or its foot to its own, as little as that takes)
  .shows(fn(top, foot) {
    let t = self.tree.logic_said()
    // (across: its start and its end, as wide as it is)
    // (down, less what is pinned over its foot: what is brought comes to rest over that, not under it; and under what
    // floats over its top (`top_covered`, what its page says lies there))
    let vh = if across {
      self.tree.nodes[self.at].flex.width
    } else {
      self.tree.nodes[self.at].flex.height -
      dmax(dmax(0.0, @signals.untracked(s.foot_covered)), @signals.untracked(fn() { self.keyboard_cover() }))
    }
    let tc = if across { 0.0 } else { dmax(0.0, @signals.untracked(fn() { (s.top_cover)() })) }
    // (where it is, read: stopped and sent only where something of it has to move. In sight already, it is left as it
    // is, on its way or at its foot following it, nothing written of it)
    let x = @signals.untracked(fn() { s.where_at(t) })
    if top < tc {
      s.sent(t, x + top - tc) |> ignore
    } else if foot > vh {
      s.sent(t, x + dmin(top - tc, foot - vh)) |> ignore
    } else {
      return 0.0
    }
    s.at(self.tree) - x
  }, across~, room?=if across {
    None
  } else {
    Some(fn() {
      (
        self.tree.nodes[self.at].flex.height,
        dmax(0.0, (s.top_cover)()),
        dmax(dmax(0.0, (s.foot_covered)()), self.keyboard_cover()),
      )
    })
  })
}

///|
/// How much of column `self`'s foot the soft keyboard covers (Tree::drawn_by's `keyboard_inset`, over the window's foot),
/// in its own terms: none where it ends over the keyboard's top (laid out above it already by what holds it, nothing
/// taken twice), or the keyboard is down.
fn View::keyboard_cover(self : View) -> Double {
  let kb = dmax(0.0, (self.tree.env.keyboard_inset)())
  let win = self.tree.last_h
  guard kb > 0.0 && win > 0.0 else { return 0.0 }
  let (_, vy, vs) = self.tree.placed(self.at)
  let sc = if vs > 0.0 { vs } else { 1.0 }
  dmax(0.0, (vy + self.tree.nodes[self.at].flex.height * sc - (win - kb)) / sc)
}

///|
/// Whether node `id` holds a page's list's rows (View::scrolls as a list, Scroll::list): each of what it holds is a row,
/// whose place is the list's, moved as the list moves it (what grows above kept where it is drawn: Scroll::grew_above).
pub fn Tree::holds_rows(self : Tree, id : NodeId) -> Bool {
  self.alive_id(id) && self.nodes[id.at].list_rows
}

///|
/// Whether node `id` scrolls what it holds up and down or across (View::scrolls) and it can go that way, as last laid
/// out (Scroll::goes: what it holds taller than it, or wider where it scrolls across, by more than half a point, as an old box kept to a height is, ui's scroll_still):
/// what lies in it moves under its top and foot as it scrolls, never in its container's corners for good (ui's corner
/// rule: a row of a list's as it scrolls).
pub fn Tree::scroll_corrected(self : Tree, id : NodeId) -> Double {
  guard self.alive_id(id) else { return 0.0 }
  match self.lists_scrolled.get(id.at) {
    Some(s) => s.corrected
    None => 0.0
  }
}

///|
/// Each page's list live now (View::scrolls over a Scroll::list, up and down: View::scrolls_window's), in the order its
/// node was made: how tall what it holds is laid out (its blocks each as tall as it was measured, one never made as tall
/// as it was counted: the whole its bar shows the share of), how tall it is, where it is scrolled to, and how far its
/// scroll was put in all for what came out another height over what shows (Tree::scroll_corrected). What a test reads of
/// how its list was reckoned against what it came to.
pub fn Tree::lists_reckoned(self : Tree) -> Array[(Double, Double, Double, Double)] {
  let ats = self.lists_scrolled.keys().to_array()
  ats.sort()
  ats.filter_map(fn(at) {
    let n = self.nodes[at]
    guard n.live && n.scroll_held >= 0 && n.scroll_held < self.nodes.length() && self.lists_scrolled.get(at) is Some(s) else {
      return None
    }
    Some((self.nodes[n.scroll_held].flex.height, n.flex.height, s.at(self), s.corrected))
  })
}

///|
/// Whether each page's list live now (Tree::lists_reckoned's, in the same order) is at its foot (Scroll::at_foot_now):
/// what a test reads of a page's list being at its end, as what follows the newest reads it.
pub fn Tree::lists_at_foot(self : Tree) -> Array[Bool] {
  let ats = self.lists_scrolled.keys().to_array()
  ats.sort()
  ats.filter_map(fn(at) {
    let n = self.nodes[at]
    guard n.live && n.scroll_held >= 0 && n.scroll_held < self.nodes.length() && self.lists_scrolled.get(at) is Some(s) else {
      return None
    }
    Some(s.at_foot_now())
  })
}

///|
/// Whether node `id` scrolls what it holds (View::scrolls), whether or not what it holds is taller than it now
/// (Tree::scrolls_now): the same all the while it is one, as what it holds comes to fit in it or grows past it.
pub fn Tree::is_scroller(self : Tree, id : NodeId) -> Bool {
  self.alive_id(id) && self.nodes[id.at].scroll_held >= 0
}

///|
/// Whether node `id` is the one node a scroller holds and moves (View::scrolls: its `scroll_held`), however far that
/// scroller can go now: not what stands beside it in the scroller (its bar, a page's list's pinned foot), which stays.
pub fn Tree::is_scroll_held(self : Tree, id : NodeId) -> Bool {
  guard self.alive_id(id) else { return false }
  let p = self.nodes[id.at].parent
  p >= 0 && self.nodes[p].scroll_held == id.at
}

///|
pub fn Tree::scrolls_now(self : Tree, id : NodeId) -> Bool {
  guard self.alive_id(id) else { return false }
  // (what it holds as tall as it is laid out, less its own: how far it can go, as its Scroll's room says it)
  let n = self.nodes[id.at]
  n.scroll_held >= 0 &&
  n.scroll_held < self.nodes.length() &&
  self.nodes[n.scroll_held].live &&
  // (the way it scrolls alone: up and down, or across, Scroll::across)
  (if n.scroll_across {
    self.nodes[n.scroll_held].flex.width - n.flex.width
  } else {
    self.nodes[n.scroll_held].flex.height - n.flex.height
  }) >
  0.5
}

///|
/// Whether node `id` is in what one that scrolls moves (View::scrolls: its held), however far that can go now: where it
/// is moves with that, as what an old view's box that scrolls (its capped, a sideways one) holds does. Not what stands
/// beside that in the one that scrolls (its bar, what is put over it), which stays.
pub fn Tree::in_scroller(self : Tree, id : NodeId) -> Bool {
  guard self.alive_id(id) else { return false }
  let mut child = id.at
  let mut i = self.nodes[id.at].parent
  while i >= 0 {
    if self.nodes[i].scroll_held == child {
      return true
    }
    child = i
    i = self.nodes[i].parent
  }
  false
}

///|
/// The logic's moment column `at` (View::scrolls) was last put at once by Scroll::put or moved by a scroll key.
/// The motion checks use it for the column's rows and its bar's thumb. Returns -1e9 if it never moved this way
/// or the node scrolls nothing.
pub fn Tree::scroll_put_at(self : Tree, at : Int) -> Double {
  guard at >= 0 && at < self.nodes.length() && self.nodes[at].live else { return -1.0e9 }
  match self.scrolls_at.get(at) {
    Some(s) => s.put_at
    None => -1.0e9
  }
}

///|
/// The keys of the page's list it scrolls changed by data (View::scrolls_window, as it takes them), at the logic's
/// moment of the tree it scrolls in: what it holds another length, its bar's thumb another length and elsewhere along
/// its track in the frame that takes it, where the reader is in what it holds (Tree::scroll_keys_at).
pub fn Scroll::keys_changed(self : Scroll) -> Unit {
  match self.host {
    Some(v) if v.alive() => self.keys_at = v.tree.logic_said()
    _ => ()
  }
}

///|
/// The logic's moment the keys of the page's list column `at` scrolls last changed by data (Scroll::keys_changed): what
/// its bar's thumb, moved by its offset alone, does in the frame that takes it is the change's (the Tester's judges:
/// ui's sizes_steady.mbt, as Tree::scroll_put_at); -1e9 where they never did, or it scrolls nothing.
pub fn Tree::scroll_keys_at(self : Tree, at : Int) -> Double {
  guard at >= 0 && at < self.nodes.length() && self.nodes[at].live else { return -1.0e9 }
  match self.scrolls_at.get(at) {
    Some(s) => s.keys_at
    None => -1.0e9
  }
}

///|
/// How tall what lies over its top covers what it shows now (View::scrolls' `top_covered`: the bar a page's list runs
/// under; 0 where its page says none, and across), read as it is said: followed where it is read tracked. Only what lies
/// over its own top edge: what scrolls with what it holds (a page's list's head) is none of it.
pub fn Scroll::top_covered(self : Scroll) -> Double {
  dmax(0.0, (self.top_cover)())
}

///|
/// How tall what is pinned over its foot covers what it shows now (a page's list's foot: View::scrolls_window's), read
/// as it is said.
pub fn Scroll::foot_covered_now(self : Scroll) -> Double {
  dmax(0.0, (self.foot_covered)())
}

///|
/// How tall what is pinned over its foot hides of what shows now: its foot (Scroll::foot_covered_now) but the top of it
/// the rows show through (View::scrolls_window's `foot_clear`), read as it is said; where a thing in it is seen clear of
/// what hides it, what is drawn flying from it reads (View::seen_place's `clear`, Tree::stays_bounds).
pub fn Scroll::foot_hides_now(self : Scroll) -> Double {
  dmax(0.0, (self.foot_covered)() - (self.foot_clear)())
}

///|
/// How tall its list's foot was last laid out (Scroll's `foot_tall`): for what is placed beside the list by what shows
/// over that foot (`View::beside`'s `piece`, asked as it is placed, in the layout that laid the foot out).
pub fn Scroll::foot_tall(self : Scroll) -> Double {
  self.foot_tall
}
