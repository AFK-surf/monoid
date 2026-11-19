// Sizes steady: what draws on the screen (a ground, an edge, words, a picture) neither steps in height nor in its place
// in its row (a list's, or what scrolls it), or in the window outside one, in one frame, nor goes in one frame at a speed off the frames
// round it, nor turns back again and again (2026-11-09 the user: 「chat 页面好像还存在高度突变的元素，查出来」, 「动画执行到
// 一半突变也算突变」). rows_steady.mbt holds where a list's rows stand; this, what is drawn in them and outside lists:
// a group opened at once, a toast pushed up by the next, a box grown as what it shows comes in.
//
// Measured as drawn (a reshape's ground where it draws it, a look's growing), what clips it aside (what is cut of it is
// hidden, not made another size), words by their place only (how tall they are is how many lines they take); by who it is
// in the frame (its ident, a tree node's id) and what it is (its kind, its ground): one made in another's place is
// another. Only while some of it shows. Not across a gap of more than a few frames,
// the window made another size (or words by the system's setting), what a node of the tree's lays out anew at another
// width in the frame it says so (View::lays_anew: what it holds), a frame with the pointer down, whoever holds the
// press (the old frame's, Ctx::down, or a node of the window's tree, view_holds: what the hand moves goes as it goes),
// nor, in a frame the hand did something since the one before (the wheel, a key: rows_steady_hand), what a column of the
// tree's moves by how far it is scrolled alone other than what it holds (its bar's thumb): a trackpad's wheel or a page
// key takes the column as far as it says in that frame, its thumb along with it, as what it holds is measured with the
// scroll taken out; nor while it does not show. Held on every frame a Tester draws, as rows_steady.mbt's rule; its
// known faults a file at a time (`sizes_steady_known`), each bar only falling.
//
// Across as down (the user, 2026-11-17, after 刚刚 under one's own message jumped 39 pt to its end with every test green:
// 「感觉是系统性问题吧」): what draws on the screen steps no more along a row than down a column, so a ground's left edge
// and width, and where words start, are measured by the same rule as its top and height, from the left of the
// row they are in where they are in one (a list's, what scrolls). Words whose own words change are new words there: where
// they stand along their line is laid out anew at once for them. Its faults are counted apart (`sizes_across_known`, the
// check `sizes_across`), each file's bar only falling, as they were found when it came. What shakes across on purpose
// (View::shakes_while: a control refusing a press) is not judged by where its left edge is drawn while it shakes, nor is
// what it holds: there and back is that way's; its top and its sizes are, and its left edge once it is over.

///|
priv struct SizesSteady {
  mut held : Bool
  mut file : String
  /// what each node drawn was seen at in its last frames, by who it is (its ident, kind and ground): one lookup a node a
  /// frame, all it is measured by in it (SizesSeen)
  mut seen : Map[(Int, Int, Int64), SizesSeen]
  mut found : Set[String]
  /// what this Tester found across (MEASURE_WIDTH, MEASURE_LEFT), counted apart against
  /// `sizes_across_known`'s bars
  mut found_across : Set[String]
  mut window : (Double, Double)
  /// the system's bars round the window as the last frame was drawn (system_bars): what they take of it laid out anew
  /// at once, as for the window made another size
  mut bars : (Double, Double, Double, Double)
  /// how much bigger the system's setting made words as the last frame was drawn (font_scale): all laid out anew for it
  /// at once, as for the window made another size
  mut words : Double
  /// when the hand last did something (rows_steady_hand) as the last frame was judged: what it did since is this frame's
  mut hand : Double
  /// when each column of the tree's was last put at once (Tree::scroll_put_at) and its list's keys last changed by data
  /// (Tree::scroll_keys_at) as the last frame was judged, by its node: either since is this frame's
  mut puts : Map[Int, (Double, Double)]
  /// the width each node of the tree's that says it lays what it holds out at (View::lays_anew) as the last frame was
  /// judged, by its node: another now is this frame's step of what it holds, laid out anew at it at once
  mut laids : Map[Int, Double]
  /// the moment of the last frame judged: what an answer changed at once since is this frame's (Tree::answered_between)
  mut judged : Double
}

///|
// kept across runs: begun anew by each Tester (sizes_steady_begin)
let sizes_steady : SizesSteady = {
  held: true,
  file: "",
  seen: {},
  found: Set([]),
  found_across: Set([]),
  window: (-1.0, -1.0),
  bars: (-1.0, -1.0, -1.0, -1.0),
  words: -1.0,
  hand: -1.0e9,
  puts: {},
  laids: {},
  judged: -1.0e9,
}

///|
/// What is measured of a node: its height, its top (in its row or the window), its width and its left edge.
const MEASURE_HEIGHT : Int = 0

///|
const MEASURE_TOP : Int = 1

///|
const MEASURE_WIDTH : Int = 2

///|
const MEASURE_LEFT : Int = 3

///|
/// What a node drawn was seen at in its last frames, each measure where it is (measure_slot): its samples
/// (rows_steady_fault's) and when it last turned back (rows_turn_ms); the words it said (words are new words across
/// where they say another thing: their place across seen anew); which slots this frame measured (`touched`, as of
/// `at`): one it did not is let go as the frame ends, as one never seen. And for each slot whether the frame of its
/// second sample came with nothing to cause it (`first_unasked`: frame_quiet), its first two frames its first ever
/// (`ever`: the slots seen so far, a slot seen anew after a gap no node's first frame). And how big it was drawn across and
/// down (its holders' scales and its own, as one) in its last frame and the one before, the frames as its samples have
/// them (a frame laid out again in half a period the same frame, `scale_at` when that frame began, `scale_end` when it was
/// last seen): what holds it grown or shrunk about a point since carries what is in it by as much more as it is further
/// from that holder's edge (Ctx::sizes_faults' carried).
priv struct SizesSeen {
  seen : FixedArray[Array[(Double, Double, Double)]]
  turned : FixedArray[Double]
  mut text : String
  mut at : Double
  mut touched : Int
  first_unasked : FixedArray[Bool]
  mut ever : Int
  mut scale_at : Double
  mut scale_end : Double
  mut scale_prev : (Double, Double)
  mut scale_now : (Double, Double)
}

///|
fn SizesSeen::new(text : String) -> SizesSeen {
  {
    seen: FixedArray::makei(6, fn(_) { [] }),
    turned: FixedArray::make(6, -1.0e9),
    text,
    at: -1.0e9,
    touched: 0,
    first_unasked: FixedArray::make(6, false),
    ever: 0,
    scale_at: -1.0e9,
    scale_end: -1.0e9,
    scale_prev: (1.0, 1.0),
    scale_now: (1.0, 1.0),
  }
}

///|
/// Where measure `m` of a node is kept in SizesSeen: a place in a row and one in the window two, never one stepping
/// from the other (what holds it starting or stopping to scroll moves nothing).
fn measure_slot(m : Int, in_row : Bool) -> Int {
  match m {
    MEASURE_HEIGHT => 0
    MEASURE_WIDTH => 1
    MEASURE_TOP => if in_row { 3 } else { 2 }
    _ => if in_row { 5 } else { 4 }
  }
}

///|
/// Whether a measure is along a row (sizes_across), not down a column.
fn measure_across(m : Int) -> Bool {
  m >= MEASURE_WIDTH
}

///|
/// Whether a measure is a place (an edge), not a size: what goes as what holds it went, by as far, is carried by it.
fn measure_place(m : Int) -> Bool {
  m == MEASURE_TOP || m == MEASURE_LEFT
}

///|
/// Each file's bar: how many faults a Tester made there may show.
// kept across runs: said once as a test program starts (its packages' `init`)
let sizes_steady_bars : Map[String, Int] = Map([])

///|
/// Each file's bar of what steps along a row (measure_across): how many faults a Tester made there may show.
// kept across runs: said once as a test program starts (its packages' `init`)
let sizes_across_bars : Map[String, Int] = Map([])

///|
/// The faults along a row known in the tests of the files `bars` names, each how many a Tester made there may show (as
/// sizes_steady_known): those there were as the check came (2026-11-17), the most one Tester found at the default rate
/// and at 60 and 120 a second, where how what moves goes is judged on run_for's frames too (MBUI_TEST_MOTION: a bar of
/// the default run's alone stopped every run at those rates on main). Said by a test package as it starts (`fn init`);
/// only falls.
pub fn sizes_across_known(bars : Array[(String, Int)]) -> Unit {
  motion_bars_said("sizes_across", bars)
  for b in bars {
    sizes_across_bars.set(b.0, b.1)
  }
}

///|
/// The faults known in the tests of the files `bars` names, each how many a Tester made there may show (as
/// rows_steady_known). Said by a test package as it starts (`fn init`); only falls.
pub fn sizes_steady_known(bars : Array[(String, Int)]) -> Unit {
  motion_bars_said("sizes_steady", bars)
  for b in bars {
    sizes_steady_bars.set(b.0, b.1)
  }
}

///|
fn sizes_steady_begin(loc : String, held : Bool) -> Unit {
  sizes_steady.held = held
  frame_end_sets.val = -1
  frame_quiet.val = false
  sizes_steady.seen.clear()
  sizes_steady.found.clear()
  sizes_steady.found_across.clear()
  sizes_steady.window = (-1.0, -1.0)
  sizes_steady.bars = (-1.0, -1.0, -1.0, -1.0)
  sizes_steady.words = -1.0
  sizes_steady.hand = -1.0e9
  sizes_steady.puts.clear()
  sizes_steady.laids.clear()
  sizes_steady.judged = -1.0e9
  sizes_steady.file = match loc.find(":") {
    Some(i) => loc.unsafe_substring(start=0, end=i)
    None => loc
  }
}

///|
/// How many signals had been set as the last frame ended (on_frame; -1 before the first): what was set after it,
/// between frames or as the next began, a cause of what that one draws.
// kept across runs: begun anew by each Tester (sizes_steady_begin)
let frame_end_sets : Ref[Int] = Ref(-1)

///|
/// Whether the frame being drawn began with nothing come since the one before it to cause anything of it (on_frame:
/// no signal set, no input, no message, nothing due, the window and its glyphs as they were): what steps in it steps for
/// no cause of its own.
// kept across runs: begun anew by each Tester (sizes_steady_begin)
let frame_quiet : Ref[Bool] = Ref(false)

///|
/// Whether node `n` draws anything of its own (a ground, an edge, a glass, a shadow, words, a picture).
fn Node::draws_own(n : Node) -> Bool {
  n.bg != 0L ||
  n.border_w > 0.0 ||
  n.glass is Some(_) ||
  n.shadow > 0.0 ||
  n.kind == kind_text ||
  n.kind == kind_rich ||
  n.kind == kind_editor ||
  n.kind == kind_image
}

///|
/// What node `i` is said as in a fault: its kind, its first words, its list's row, its size and place.
fn Ctx::sizes_steady_said(self : Ctx, i : Int) -> String {
  let n = self.nodes[i]
  let mut words = ""
  let stack = [i]
  let mut looked = 0
  while stack.length() > 0 && words == "" && looked < 400 {
    looked = looked + 1
    let m = self.nodes[stack.pop().unwrap()]
    if (m.kind == kind_text || m.kind == kind_rich || m.kind == kind_editor) && m.text != "" {
      words = m.text
      break
    }
    let kids = []
    let mut k = m.first
    while k >= 0 && kids.length() < 50 {
      kids.push(k)
      k = self.nodes[k].next
    }
    for j = kids.length() - 1; j >= 0; j = j - 1 {
      stack.push(kids[j])
    }
  }
  if words.length() > 40 {
    words = words.unsafe_substring(start=0, end=40)
  }
  let mut row = ""
  let mut q = i
  while q >= 0 {
    let p = self.nodes[q].parent
    if p >= 0 && self.nodes[p].kind == kind_list {
      match self.lists.get(self.nodes[p].id) {
        Some(st) => {
          let keys = match st.causes {
            Some(c) => c.keys
            None => []
          }
          let it = self.nodes[q].item
          row = " in row " + (if it >= 0 && it < keys.length() { keys[it] } else { "#\{it}" }) + " of " + st.named
        }
        None => ()
      }
      break
    }
    q = p
  }
  "\{laid_kind(n)} \{repr(words)}\{row}"
}

///|
/// Where node `i` of the frame (with the window's tree's among it) was made, said after a fault (", made at …"): its
/// own place where it is the tree's, else that of the tree's node it is drawn in (the app's, past the framework's own
/// boxes), or the old view's; "" none kept.
fn Ctx::sizes_steady_made(self : Ctx, i : Int) -> String {
  // (what an old view drew says so, and the tree's node it is drawn in, where it is in one: which old view it is)
  let old = i >= 0 && i < self.count && tree_frame_ids.get(i) is None
  let mut b = i
  while b >= 0 && b < self.count {
    match tree_frame_ids.get(b) {
      // (not the framework's own boxes (an old view's host, a scroller's): the app's that holds them)
      Some(id) if !source_said(id).has_prefix("made at mbui/src/view/") => {
        let s = source_said(id)
        return if s == "" {
          if old { " (old view)" } else { "" }
        } else if old {
          " (old view, in what was " + s + ")"
        } else {
          " (" + s + ")"
        }
      }
      _ => b = self.nodes[b].parent
    }
  }
  let s = self.old_source_said(i)
  if s != "" {
    " (" + s + ")"
  } else if old {
    " (old view)"
  } else {
    ""
  }
}

///|
/// How many times more speed a measure stopped dead loses in its last frame than it lost in each frame before it, at the
/// least (sizes_steady_fault): one slowing at one rate to rest loses as much each frame, once the frames' lengths and
/// the time between their middles are taken out, up to 1.21 where a frame half again as long as the rest falls between (新建 workspace's sheet, its invite
/// code's field turned back, 2026-11-11), and a half more than that is what no slowing at one rate comes to; every dead
/// stop CI's runs count, and each this check was there to find, loses more (1.66 times at the least) or was still
/// going as fast or faster the frame before.
let stop_jerk : Double = 1.5

///|
/// A measure's last frames (rows_steady_fault's samples, the display's frames `period` apart; it last turned back at
/// `turned`): the frame before the last a step or a spike (off both frames round it the same way), or a dead stop (at
/// speed, then at rest at once, slowing more at once than it slowed: stop_jerk); or a turn back again soon (rows_steady_fault's). A way setting out at its speed (from
/// rest, going on as fast or slowing) is none: an eased way out sets out so (sf/motion.mbt). In a list's row whose way
/// set out at `set_out` between them, as rows_steady_fault has a row's place: the speed it takes up then, from where it
/// was, is the way's (a row joining the rows' way under way goes on its share of it as they do: list_size.mbt).
/// Not said, known (the coordinator of the migration, 2026-11-13: taken up once the chat's page is switched, by a round
/// that only prints first): a step is said only as the middle of three frames, so one whose next frame no longer judges
/// its node (it shows no more, a hand's frame, a gap, the window resized: its samples cleared) is never said. A bar's
/// thumb stepping as its list was put at once passed at 60 judged where 120 failed for it, the thumb showing no more a
/// frame of 60 later (chat_page_nodes_wbtest, #5854). And not said, known (the coordinator of the migration,
/// 2026-11-14): a row of a page's list of the window's tree carried off its place in a frame is judged by nothing here
/// (what is in such a row is measured from its top) nor by rows_steady, which walks only the old view's lists
/// (rows_steady.mbt's rows_steady_faults: a list node of an old view's with its state); it is said today only where a
/// drawn box round its cause steps. A round that only prints comes before the chat's page is switched.
///|
/// Whether an interval of `dt` ms with change `dx` is a sub-half-frame sliver across the 0.5-period bucket edge where a
/// pixel-snapped coordinate at reference speed `v_ref` (pt/period) moves less than one device pixel `px`: a 0- or
/// 1-pixel step over that sliver is quantization, not a dead stop or velocity spike; a real step larger than one pixel
/// is still caught.
fn is_pixel_sliver(dt : Double, dx : Double, v_ref : Double, period : Double, px : Double) -> Bool {
  px > 0.0 && dt < 0.5 * period && dx.abs() <= px + 1.0e-9 && v_ref.abs() * (dt / period) < px
}

///|
fn sizes_steady_fault(
  all : Array[(Double, Double, Double)],
  period : Double,
  turned~ : Double,
  set_out? : Double = -1.0,
  unasked? : Bool = true,
  px? : Double = 0.0,
) -> (String?, Double) {
  // (the last four; the one before them, where there is one, for whether they set out from rest)
  let seen = if all.length() > 4 { all[all.length() - 4:].to_owned() } else { all }
  let n = seen.length()
  // (its first three frames ever, one after another, the second come with nothing to cause it (`unasked`): a step in
  // its first frame and then standing still (a frame drawn by what was worked out late, a value told the tree a frame
  // after it was made), which no frame of four ever has before it, the step its first)
  if n == 3 &&
    unasked &&
    seen[0].1 < seen[1].1 &&
    seen[1].1 < seen[2].1 &&
    seen[1].1 - seen[0].1 <= 1.5 * period &&
    seen[2].1 - seen[1].1 <= 1.5 * period &&
    !(set_out > seen[0].1 && set_out <= seen[2].1) {
    let dt1 = seen[2].1 - seen[1].1
    let v0 = (seen[1].2 - seen[0].2) / (seen[1].1 - seen[0].1) * period
    let v1 = (seen[2].2 - seen[1].2) / dt1 * period
    if !is_pixel_sliver(dt1, seen[2].2 - seen[1].2, v0, period, px) && v0.abs() > rows_speed_least && v1.abs() <= 0.25 {
      return (
        Some("stepped \{v0} in its first frame then stood (\{v1}) at \{seen[1].1} seen=[\{all.map(fn(s) { "(\{s.0}, \{s.1}, \{s.2})" }).join(", ")}]"),
        turned,
      )
    }
  }
  if n >= 4 && seen[0].1 < seen[1].1 && seen[1].1 < seen[2].1 && seen[2].1 < seen[3].1 &&
    !(set_out > seen[0].1 && set_out <= seen[3].1) {
    let speed = fn(a : Int) { (seen[a + 1].2 - seen[a].2) / (seen[a + 1].1 - seen[a].1) * period }
    let v0 = speed(0)
    let v1 = speed(1)
    let v2 = speed(2)
    let least = rows_speed_least
    let at = seen[2].1
    // (from rest, going on its way: a way set out, eased out from its speed; set out between two frames, the first of
    // them partly)
    let rest_before = all.length() > 4 &&
      all[0].1 < seen[0].1 &&
      ((seen[0].2 - all[0].2) / (seen[0].1 - all[0].1) * period).abs() < 0.25 * v1.abs()
    let on = v1 * v2 > 0.0 && v2.abs() >= 0.25 * v1.abs() && v2.abs() <= v1.abs()
    let sets_out = on && (v0.abs() < 0.5 || (rest_before && v0 * v1 > 0.0 && v0.abs() < v1.abs()))
    let off = (v1 - (v0 + v2) / 2.0).abs()
    let sliver_end = is_pixel_sliver(seen[3].1 - seen[2].1, seen[3].2 - seen[2].2, v1, period, px)
    let sliver_mid = is_pixel_sliver(seen[2].1 - seen[1].1, seen[2].2 - seen[1].2, dmax(v0.abs(), v2.abs()), period, px)
    // (stopped dead: going, then all but still in a frame, the speed it lost that frame more than stop_jerk times what
    // it lost in either frame before (the lesser of the two, a frame further back where there is one: where its slowing
    // set in falls between frames as it likes); slowing at one rate to rest, whatever frame its rest falls on, none
    // (the coordinator of the migration, 2026-11-11: what stops dead is a step in how fast it slows, not where its rest
    // falls among the frames; what it does after, turning back or not, no part of it))
    if !sliver_end && v0.abs() > least && v1.abs() > least && v0 * v1 > 0.0 && v2.abs() < 0.2 * v1.abs() {
      let toward = if v1 > 0.0 { 1.0 } else { -1.0 }
      // (each loss of speed over the time between the middles of the two frames it is between, in two frames' time: a
      // slowing at one rate loses as much over the same time, a frame twice as long as the rest between them or not;
      // frames all `period` apart, as they were)
      let d1 = (v0 - v1) * toward * (2.0 * period) / (seen[2].1 - seen[0].1)
      let d2 = (v1 - v2) * toward * (2.0 * period) / (seen[3].1 - seen[1].1)
      // (the frame before those too, where it was seen moving then: one stopped dead at a moment between two frames is
      // sampled as at speed, a piece, still (10, 10, 5, 0), the piece as long as where that moment fell makes it, the
      // same numbers as a slowing set in at once and over in two frames; both are said, or one falling between frames
      // would go unsaid)
      // (one that set out in it, from rest at a moment between those two frames, a piece of a frame at speed (2, 25, …):
      // no slowing of its to go by, the frame after its first the one before)
      let back = all.length() > 4 && all[all.length() - 5].1 < seen[0].1
      let d0 = if back {
        let tb = all[all.length() - 5].1
        let vb = (seen[0].2 - all[all.length() - 5].2) / (seen[0].1 - tb) * period
        if vb * v0 >= 0.0 && vb.abs() < 0.25 * v0.abs() {
          d1
        } else {
          (vb - v0) * toward * (2.0 * period) / (seen[1].1 - tb)
        }
      } else {
        d1
      }
      let before = if d0 < d1 { d0 } else { d1 }
      if before <= 0.0 || d2 > stop_jerk * before {
        return (
          Some("stopped dead from \{v1} a frame (\{v0} before; slowing \{before} then \{d2}) at \{seen[3].1} seen=[\{all.map(fn(s) { "(\{s.0}, \{s.1}, \{s.2})" }).join(", ")}]"),
          turned,
        )
      }
    }
    // (at rest, or all but, then setting out: none)
    let resting = v0.abs() < least && v1.abs() < least
    if !sliver_end &&
      !sliver_mid &&
      !sets_out &&
      !resting &&
      (v1 - v0) * (v1 - v2) > 0.0 &&
      (v1 - v0).abs() > least &&
      (v1 - v2).abs() > least &&
      off > 0.5 * dmax(v0.abs(), v2.abs()) {
      return (Some("went \{v1} a frame between \{v0} and \{v2} at \{at} seen=[\{all.map(fn(s) { "(\{s.0}, \{s.1}, \{s.2})" }).join(", ")}]"), turned)
    }
  }
  // (only its turning back: what rows_steady_fault says of a speed is the list's way's, where it set out, and of a
  // step under a way's setting out a list's row's)
  rows_steady_fault(seen, period, set_out=seen[0].1 + 0.5 * period, turned~, faint=true)
}

///|
/// The nodes of the window's tree among the frame's that a scroller holds and moves (View::scrolls: its `scroll_held`),
/// however far it can go now (Tree::is_scroll_held): what is in one measured from its top all the while it is in one,
/// never switched to the window's as what it holds comes to fit in it or grows past it on its way, and never what
/// stands beside it in the scroller (its bar, a page's list's pinned foot: Ctx::sizes_steady_faults).
// kept across runs: filled and emptied round each asking of the frame with the tree's nodes (Ctx::with_tree_nodes)
let tree_scroll_held_at : Set[Int] = Set([])

///|
/// The faults down a column the frame just drawn (at `now`, the display's frames `period` apart) shows, each said once: of
/// whom, how (Ctx::sizes_faults, those along a row left out).
// (held by its tests: a Tester holds both through Ctx::sizes_faults)
#warnings("-unused_value")
fn Ctx::sizes_steady_faults(self : Ctx, now : Double, period : Double) -> Array[String] {
  self.sizes_faults(now, period).filter(fn(f) { !f.0 }).map(fn(f) { f.1 })
}

///|
/// The faults the frame just drawn (at `now`, the display's frames `period` apart) shows, each said once: whether it is
/// along a row (measure_across), of whom, how.
fn Ctx::sizes_faults(self : Ctx, now : Double, period : Double) -> Array[(Bool, String)] {
  let out : Array[(Bool, String)] = []
  let words = @signals.untracked(font_scale)
  // (the system's bars said otherwise: the room they leave the window laid out anew at once, no motion of anything in
  // it, as the window made another size is)
  let b = @signals.untracked(system_bars)
  let bars = (b.top, b.bottom, b.left, b.right)
  let resized = sizes_steady.window != (self.width, self.height) || sizes_steady.words != words || sizes_steady.bars != bars
  sizes_steady.window = (self.width, self.height)
  sizes_steady.bars = bars
  sizes_steady.words = words
  // (the hand did something since the frame before was judged (rows_steady_hand: the wheel, a key, a press, let go))
  let hand_now = rows_steady.hand != sizes_steady.hand
  sizes_steady.hand = rows_steady.hand
  let here : Set[(Int, Int, Int64)] = Set([])
  self.with_tree_nodes(fn() {
    let tree = view_tree()
    // (one ident twice in the frame: who either is, unsaid)
    let count : Map[Int, Int] = Map([])
    for i in 0..<self.count {
      let id = self.nodes[i].ident
      count[id] = count.get(id).unwrap_or(0) + 1
    }
    // (each with what it measures (measure_*), and how far it went in the last frame)
    let faults : Array[(Int, String, Int, Double)] = []
    // (each node's drawn down the window as its looks and theirs over it have it, y -> a * y + b; how opaque; what
    // of the window its holders' clips leave it; its row's top as drawn, where it is in a list's row, or in what a node of
    // the tree scrolls (View::scrolls) or an old view's scroll: there the one node it holds, drawn moved by how far it is
    // scrolled alone (Node's scroll_off), so what is in it measured from that node's top has the scroll taken out, but
    // for where a page's list's scroll was put for what came out another height over what shows (Tree::scroll_corrected),
    // what shows held where it was by it: worked out from what holds it)
    let k = self.count
    let ya = Array::make(k, 1.0)
    // (and how big it is drawn across and down, its holders' scales and its own (corner_scale_at for a node of the
    // window's tree, as the tree's walk worked it out; else its holder's by its look's); its drawn edges, left and top, in
    // the window's terms; and how big it was drawn in the frame before over how big now, across and down)
    let sx_at = Array::make(k, 1.0)
    let sy_at = Array::make(k, 1.0)
    let drawn_pos : Array[(Double, Double)] = Array::make(k, (0.0, 0.0))
    let scale_ratio : Array[(Double, Double)] = Array::make(k, (1.0, 1.0))
    let yb = Array::make(k, 0.0)
    let al = Array::make(k, 1.0)
    let c_top = Array::make(k, -1.0e9)
    let c_bot = Array::make(k, 1.0e9)
    // (and across: how far its looks put it off where it is laid out, and what clips it there, so what is cut off to a
    // side, a page slid off out of its column, shows as little as what is cut off above or below)
    let xb = Array::make(k, 0.0)
    let c_left = Array::make(k, -1.0e9)
    let c_right = Array::make(k, 1.0e9)
    let row_at = Array::make(k, 0.0)
    // (and its row's left edge as drawn, where it is in one: what is in it measured from there across)
    let col_at = Array::make(k, 0.0)
    let in_row = Array::make(k, false)
    // (and when the rows' way of the list it is in last set out: list_size.mbt's RowCauses, -1 none)
    let set_out = Array::make(k, -1.0)
    // (and whether it is moved by how far a column of the tree's is scrolled, by its offset alone (Node's scroll_off,
    // Tree::scroll_off_by), other than as the one node the column holds: its bar's thumb and what that holds, along its
    // track as the column goes, so in a frame the hand scrolled it as far in one frame as the hand did)
    let by_scroll = Array::make(k, false)
    // (and whether that column was put at once since the frame before (Scroll::put: a page's list brought to a block or
    // its foot), or its list's keys changed by data since (what it holds another length): what it moves by its offset
    // alone goes there with it in this frame, as far as the put took it, its thumb as long as what the column holds came
    // to in that frame's layout, as it does in a frame the hand scrolled it (the coordinator of the migration,
    // 2026-11-13: a thumb says where the reader is in what the column holds, which the keys changing changes at once))
    let put_now = Array::make(k, false)
    // (and whether it shakes across now, itself or what holds it (View::shakes_while, motion's ShakeWay::shakes): where
    // its left edge is drawn is that way's while it goes, turning back on purpose; its top and its sizes judged as ever)
    let shaken = Array::make(k, false)
    // (and whether it is held at a top as what scrolls it moves, itself or what holds it in its row (View::sticky):
    // where it is down its row is the hold's, stopping as it is caught and going on as it is let go on purpose; its
    // sizes, where it is across and where it is down out of a row judged as ever)
    let stuck = Array::make(k, false)
    let puts_now : Map[Int, (Double, Double)] = Map([])
    let laids_now : Map[Int, Double] = Map([])
    // (what holds each before it: a node of the window's tree put among the frame's may come after what it holds)
    let order : Array[Int] = []
    let ordered = Array::make(k, false)
    let up : Array[Int] = []
    for i in 0..<k {
      up.clear()
      let mut q = i
      while q >= 0 && q < k && !ordered[q] {
        ordered[q] = true
        up.push(q)
        q = self.nodes[q].parent
      }
      for j = up.length() - 1; j >= 0; j = j - 1 {
        order.push(up[j])
      }
    }
    for i in order {
      let n = self.nodes[i]
      let p = n.parent
      let (pa, pb, palpha) = if p >= 0 && p < k { (ya[p], yb[p], al[p]) } else { (1.0, 0.0, 1.0) }
      let (la, lb, lalpha, ldx, lax) = match self.drawn_entry(i) {
        Some(e) => {
          let l = e.look_now()
          let oy = n.y + l.oy * n.fh
          (l.sy, oy * (1.0 - l.sy) + l.dy, l.alpha, l.dx, l.sx)
        }
        None => (1.0, 0.0, 1.0, 0.0, 1.0)
      }
      if tree_frame_ids.contains(i) {
        let ts = corner_scale_at.get(i).unwrap_or(1.0)
        sx_at[i] = ts
        sy_at[i] = ts
      } else {
        sx_at[i] = (if p >= 0 && p < k { sx_at[p] } else { 1.0 }) * lax
        sy_at[i] = (if p >= 0 && p < k { sy_at[p] } else { 1.0 }) * la
      }
      xb[i] = (if p >= 0 && p < k { xb[p] } else { 0.0 }) + ldx
      ya[i] = pa * la
      yb[i] = pa * lb + pb
      al[i] = palpha * n.opacity * lalpha
      by_scroll[i] = (p >= 0 && p < k && by_scroll[p]) ||
        (match (tree, tree_frame_ids.get(i)) {
          (Some(tr), Some(id)) => {
            let by = tr.scroll_off_by(id)
            // (not the one node the column holds, laid out in it: what is in that is measured with the scroll taken out)
            let moved = by >= 0 && !(tree_frame_ids.get(p) is Some(pid) && pid.at == by)
            if moved {
              let at = (tr.scroll_put_at(by), tr.scroll_keys_at(by))
              puts_now[by] = at
              if sizes_steady.puts.get(by) is Some(was) && was != at {
                put_now[i] = true
              }
            }
            moved
          }
          _ => false
        })
      // (a node that lays what it holds out at another width than when the last frame was judged (View::lays_anew):
      // what it holds laid out anew at once, its step in this frame its own, as the window made another size is)
      match (tree, tree_frame_ids.get(i)) {
        (Some(tr), Some(id)) =>
          match tr.laid_said_of(id.at) {
            Some(w) => {
              laids_now[id.at] = w
              if sizes_steady.laids.get(id.at) is Some(was) && was != w {
                put_now[i] = true
              }
            }
            None => ()
          }
        _ => ()
      }
      if p >= 0 && p < k && put_now[p] {
        put_now[i] = true
      }
      match (tree, tree_frame_ids.get(i)) {
        (Some(tr), Some(id)) if tr.sticks_any() && tr.is_sticky(id) => stuck[i] = true
        _ => ()
      }
      shaken[i] = (p >= 0 && p < k && shaken[p]) ||
        (match (tree, tree_frame_ids.get(i)) {
          (Some(tr), Some(id)) => tr.shakes_at(id.at, now)
          _ => false
        })
      if p >= 0 && p < k {
        let pn = self.nodes[p]
        c_top[i] = c_top[p]
        c_bot[i] = c_bot[p]
        c_left[i] = c_left[p]
        c_right[i] = c_right[p]
        if pn.clip {
          let top = ya[p] * pn.y + yb[p]
          c_top[i] = dmax(c_top[i], top)
          c_bot[i] = dmin(c_bot[i], top + ya[p] * pn.fh)
          let left = pn.x + xb[p]
          c_left[i] = dmax(c_left[i], left)
          c_right[i] = dmin(c_right[i], left + pn.fw)
        }
        if pn.tree_rows {
          // (a row of a page's list of the window's tree: its place the list's (rows_steady.mbt, Scroll::grew_above),
          // what is in it measured from its top)
          row_at[i] = ya[i] * n.y + yb[i]
          col_at[i] = n.x + xb[i]
          in_row[i] = true
          set_out[i] = -1.0
        } else if pn.kind == kind_list || pn.kind == kind_scroll || pn.scroller != 0 ||
          tree_scroll_held_at.contains(i) {
          // (less how far its scroll was put for what came out another height over what shows: what is under that moved
          // down in it as far, held where it was)
          row_at[i] = ya[i] * (n.y + pn.tree_corrected) + yb[i]
          col_at[i] = n.x + xb[i]
          in_row[i] = true
          // (the moment its rows' way set out; or an old list's put elsewhere at once, Ctx::app_scrolled's `put_at`, as
          // rows_steady.mbt has it for the rows themselves: what it holds at its top, a head stuck under its edge
          // (Node::stick), steps in its row then for no cause of its own)
          set_out[i] = match self.lists.get(pn.id) {
            Some(st) if pn.kind == kind_list => {
              let rows = match st.causes {
                Some(c) => c.start
                None => -1.0
              }
              dmax(rows, st.put_at)
            }
            _ => -1.0
          }
        } else {
          row_at[i] = row_at[p]
          col_at[i] = col_at[p]
          in_row[i] = in_row[p]
          set_out[i] = set_out[p]
          stuck[i] = stuck[i] || stuck[p]
        }
        // (on a flight's way: drawn in the window's terms, in no row of what it is drawn among (shared.mbt), what it
        // holds measured from it as ever)
        match (tree, tree_frame_ids.get(i)) {
          (Some(tr), Some(id)) if tr.lifted_at(id.at) => {
            row_at[i] = 0.0
            col_at[i] = 0.0
            in_row[i] = false
            set_out[i] = -1.0
          }
          _ => ()
        }
      }
    }
    puts_now.each(fn(by, at) { sizes_steady.puts[by] = at })
    laids_now.each(fn(at, w) { sizes_steady.laids[at] = w })
    // (what an answer changed at once since the frame before (the window's tree's answer_marked.mbt): the column it is in
    // (what scrolls round it, else what holds the page) changed with it in this frame, as it must, no jolt of its own,
    // but for what is on a way not at its end then, its own or what carries it: a step of that is in the middle of a way,
    // said as ever (the coordinator of the migration, 2026-11-14))
    let answered_in = Array::make(k, -1)
    match tree {
      Some(tr) => {
        let marked = tr.answered_between(sizes_steady.judged, now)
        if marked.length() > 0 {
          let of : Map[Int, Int] = Map([])
          for i in 0..<k {
            match tree_frame_ids.get(i) {
              Some(id) => if !of.contains(id.at) { of[id.at] = i }
              None => ()
            }
          }
          let roots : Set[Int] = Set([])
          for at in marked {
            guard of.get(at) is Some(i) else { continue }
            // (up to what scrolls round it, else the outermost but one: the page it is on, never all of the window)
            let mut q = i
            let mut root = -1
            while q >= 0 && q < k {
              let p = self.nodes[q].parent
              if p < 0 || p >= k {
                break
              }
              let pn = self.nodes[p]
              if pn.tree_rows || pn.kind == kind_list || pn.kind == kind_scroll || pn.scroller != 0 ||
                tree_scroll_held_at.contains(q) {
                root = p
                break
              }
              if self.nodes[p].parent < 0 {
                root = q
                break
              }
              q = p
            }
            if root >= 0 {
              roots.add(root)
            }
          }
          for i in order {
            let p = self.nodes[i].parent
            answered_in[i] = if roots.contains(i) {
              i
            } else if p >= 0 && p < k {
              answered_in[p]
            } else {
              -1
            }
          }
          // (what is on a way not at its end, its own or what carries it (Tree::on_way_at): its step a jolt as ever)
          let tid = Array::make(k, -1)
          for i in order {
            let p = self.nodes[i].parent
            tid[i] = match tree_frame_ids.get(i) {
              Some(id) => id.at
              None => if p >= 0 && p < k { tid[p] } else { -1 }
            }
          }
          for i in 0..<k {
            // (judged within the column the answer changed: what moves that column whole, a page sliding in, is no step
            // in it)
            let within = if answered_in[i] >= 0 && answered_in[i] < k { tid[answered_in[i]] } else { -1 }
            if answered_in[i] >= 0 && !(tid[i] >= 0 && tr.on_way_at(tid[i], now, within~)) {
              put_now[i] = true
            }
          }
        }
      }
      None => ()
    }
    for i in 0..<k {
      let n = self.nodes[i]
      // (words the window's tree draws in a box of its own, laid out as that box, no size of their own (ident 0, width
      // 0): where they stand is that box's, who they are its; measured across alone, as down they never were)
      let words = n.kind == kind_text || n.kind == kind_rich || n.kind == kind_editor
      let p = n.parent
      let boxed = words && n.fw <= 0.0 && p >= 0 && p < k
      let (ident, nx, nw, ny, nh) = if boxed {
        let pn = self.nodes[p]
        (pn.ident, pn.x + xb[p] - xb[i], pn.fw, (ya[p] * pn.y + yb[p] - yb[i]) / ya[i], pn.fh * ya[p] / ya[i])
      } else {
        (n.ident, n.x, n.fw, n.y, n.fh)
      }
      if count.get(ident).unwrap_or(0) != 1 || !n.draws_own() {
        continue
      }
      let gy = ya[i] * ny + yb[i]
      let gh = ya[i] * nh
      // (and across: where its ground starts and how wide it is drawn, the same way)
      let (top0, bot0, ground_left, ground_w) = match self.drawn_entry(i) {
        Some({ ground: Some((x, y, w, h, _)), .. }) => (y, y + h, x, w)
        // (a node of the window's tree: its ground as drawn, off where it is laid out (Tree::ground_drawn_of: a
        // ground grown on a list's one way, Node's flip_in, down and across))
        _ =>
          match (tree, tree_frame_ids.get(i)) {
            (Some(tr), Some(id)) => {
              let gd = tr.ground_drawn_of(id)
              (gy + ya[i] * gd.dy, gy + gh + ya[i] * (gd.dy + gd.dh), nx + xb[i] + gd.dx, nw + gd.dw)
            }
            _ => (gy, gy + gh, nx + xb[i], nw)
          }
      }
      // (words are measured where they stand, their box's; a ground where it is drawn)
      let left0 = if words { nx + xb[i] } else { ground_left }
      let nw = if words { nw } else { ground_w }
      // (none of an old view the window's tree places nowhere now: laid out nowhere, its page off to a side)
      let placed = match n.island {
        Some(id) => old_placed.iter().any(fn(p) { p.0 == id })
        None => true
      }
      let shows = placed &&
        al[i] > 0.05 &&
        nw > 0.0 &&
        dmin(bot0, c_bot[i]) > dmax(top0, c_top[i]) &&
        dmin(left0 + nw, c_right[i]) > dmax(left0, c_left[i]) &&
        // (nor what is off the window to a side: a page slid off out of its sheet, an old view's held in it)
        left0 + nw > 0.0 &&
        left0 < self.width
      let row_top = row_at[i]
      let row_left = if in_row[i] { col_at[i] } else { 0.0 }
      let in_row = in_row[i]
      // (words: where they stand, down and where they start across; how tall is how many lines they take, no motion's;
      // words are drawn from the start of their box, and how far their ink goes on is how wide what they say is or where
      // they are cut short, never the box's other edge, which a box grown in its row moves with what is beside it, the
      // words staying where they are; words that say another thing are new words where they stand across, keyed by what
      // they say)
      let measures = if boxed {
        [(MEASURE_LEFT, left0 - row_left)]
      } else if words {
        [(MEASURE_TOP, top0 - row_top), (MEASURE_LEFT, left0 - row_left)]
      } else {
        [
          (MEASURE_HEIGHT, bot0 - top0),
          (MEASURE_TOP, top0 - row_top),
          (MEASURE_WIDTH, nw),
          (MEASURE_LEFT, left0 - row_left),
        ]
      }
      let key = (ident, n.kind, n.bg)
      here.add(key)
      let ns = match sizes_steady.seen.get(key) {
        Some(s) => s
        None => {
          let s = SizesSeen::new(n.text)
          sizes_steady.seen[key] = s
          s
        }
      }
      drawn_pos[i] = (left0, top0)
      if ns.at != now {
        ns.at = now
        ns.touched = 0
        // (how big it is drawn, its frames as its samples': once a frame)
        let scale = (sx_at[i], sy_at[i])
        let scale_gap = ns.scale_end > -1.0e8 && now - ns.scale_end > 2.5 * period
        if scale_gap || resized || !shows || self.down || view_holds() || (hand_now && by_scroll[i]) || put_now[i] {
          ns.scale_at = -1.0e9
          ns.scale_end = -1.0e9
          ns.scale_prev = scale
          ns.scale_now = scale
        } else if ns.scale_at < -1.0e8 {
          ns.scale_at = now
          ns.scale_end = now
          ns.scale_prev = scale
          ns.scale_now = scale
        } else if now - ns.scale_at < 0.5 * period {
          ns.scale_end = now
          ns.scale_now = scale
        } else {
          ns.scale_at = now
          ns.scale_end = now
          ns.scale_prev = ns.scale_now
          ns.scale_now = scale
        }
      }
      scale_ratio[i] = (
        if sx_at[i] > 0.0 { ns.scale_prev.0 / sx_at[i] } else { 1.0 },
        if sy_at[i] > 0.0 { ns.scale_prev.1 / sy_at[i] } else { 1.0 },
      )
      // (words saying another thing: new words where they stand across)
      if words && !physical_equal(ns.text, n.text) && ns.text != n.text {
        ns.text = n.text
        for s in [4, 5] {
          ns.seen[s].clear()
          ns.turned[s] = -1.0e9
          ns.first_unasked[s] = false
        }
      }
      for m in measures {
        let slot = measure_slot(m.0, in_row)
        ns.touched = ns.touched | (1 << slot)
        let seen = ns.seen[slot]
        let gap = seen.length() > 0 && now - seen[seen.length() - 1].1 > 2.5 * period
        // (what the hand's scroll moves by its offset alone, in the frame it did: as far as the hand took it; and in the
        // frame its column was put at once, or its list's keys changed by data, as far as that took it)
        if gap || resized || !shows || self.down || view_holds() || (hand_now && by_scroll[i]) || put_now[i] {
          seen.clear()
          ns.first_unasked[slot] = false
          continue
        }
        // (its left edge while it shakes across: the shake's, there and back on purpose; seen anew from its first frame
        // at rest, as one never seen)
        if shaken[i] && m.0 == MEASURE_LEFT {
          seen.clear()
          ns.turned[slot] = -1.0e9
          ns.first_unasked[slot] = false
          continue
        }
        // (where it is down its row while it is held at a top (View::sticky): the hold's, caught and let go on purpose;
        // seen anew from its first frame at rest)
        if stuck[i] && in_row && m.0 == MEASURE_TOP {
          seen.clear()
          ns.turned[slot] = -1.0e9
          ns.first_unasked[slot] = false
          continue
        }
        if seen.length() > 0 && now - seen[seen.length() - 1].0 < 0.5 * period {
          // (laid out again in the frame: one frame, as it stands now: rows_steady.mbt; its second laid out again for a
          // cause, a step in it that cause's)
          if seen.length() == 2 && !frame_quiet.val {
            ns.first_unasked[slot] = false
          }
          seen[seen.length() - 1] = (seen[seen.length() - 1].0, now, m.1)
        } else {
          // (its second frame ever: whether it stepped with nothing before it to cause it)
          if seen.length() == 1 && (ns.ever & (1 << slot)) == 0 {
            ns.first_unasked[slot] = frame_quiet.val && (m.1 - seen[0].2).abs() > 0.01
            ns.ever = ns.ever | (1 << slot)
          }
          seen.push((now, now, m.1))
        }
        while seen.length() > 5 {
          seen.remove(0) |> ignore
        }
        let turned = ns.turned[slot]
        let px = if self.scale > 0.0 { 1.0 / self.scale } else { 0.0 }
        let (fault, turn) = sizes_steady_fault(
          seen,
          period,
          turned~,
          set_out=set_out[i],
          unasked=ns.first_unasked[slot],
          px~,
        )
        ns.turned[slot] = turn
        match fault {
          Some(f) => {
            let went = if seen.length() >= 2 { seen[seen.length() - 1].2 - seen[seen.length() - 2].2 } else { 0.0 }
            let said = match m.0 {
              MEASURE_HEIGHT => "its height "
              MEASURE_WIDTH => "its width "
              MEASURE_LEFT => if in_row { "its left edge in its row " } else { "its left edge " }
              _ => if in_row { "its place in its row " } else { "its place " }
            }
            faults.push((i, said + f, m.0, went))
          }
          None => ()
        }
      }
    }
    // (what goes as what holds it went, by as far in the frame, carried by it: that one said, the outermost so carried,
    // not each thing in it; down by its top, across by its left edge. What holds it drawn grown or shrunk about a point
    // since the frame before, from s0 to s1, carries it by as far again as it stands from that holder's edge times
    // 1 - s0 / s1, where it is now: what is further in goes further as it grows, nothing of its own)
    let placed : Map[(Int, Bool), Double] = Map([])
    for f in faults {
      if measure_place(f.2) {
        placed[(f.0, measure_across(f.2))] = f.3
      }
    }
    let carried : Set[Int] = Set([])
    for k, f in faults {
      if !measure_place(f.2) {
        continue
      }
      let across = measure_across(f.2)
      let cpos = if across { drawn_pos[f.0].0 } else { drawn_pos[f.0].1 }
      let mut p = self.nodes[f.0].parent
      while p >= 0 {
        match placed.get((p, across)) {
          Some(w) => {
            let ppos = if across { drawn_pos[p].0 } else { drawn_pos[p].1 }
            let ratio = if across { scale_ratio[p].0 } else { scale_ratio[p].1 }
            let expected = w + (cpos - ppos) * (1.0 - ratio)
            if (expected - f.3).abs() < 0.01 {
              carried.add(k)
              break
            }
          }
          None => ()
        }
        p = self.nodes[p].parent
      }
    }
    // (else the innermost of what goes together, down or across: what holds it goes with it)
    let holds : Set[(Int, Bool)] = Set([])
    for k, f in faults {
      if carried.contains(k) {
        continue
      }
      let mut p = self.nodes[f.0].parent
      while p >= 0 {
        holds.add((p, measure_across(f.2)))
        p = self.nodes[p].parent
      }
    }
    for k, f in faults {
      if !carried.contains(k) && !holds.contains((f.0, measure_across(f.2))) {
        out.push((measure_across(f.2), self.sizes_steady_said(f.0) + ": " + f.1 + self.sizes_steady_made(f.0)))
      }
    }
  })
  sizes_steady.judged = now
  let gone : Array[(Int, Int, Int64)] = []
  sizes_steady.seen.each(fn(k, ns) {
    if !here.contains(k) {
      gone.push(k)
    } else {
      // (a measure not taken this frame is let go, as one never seen)
      for s in 0..<6 {
        if (ns.touched & (1 << s)) == 0 {
          ns.seen[s].clear()
          ns.turned[s] = -1.0e9
          ns.first_unasked[s] = false
        }
      }
    }
  })
  for k in gone {
    sizes_steady.seen.remove(k)
  }
  out
}

///|
/// The rule held on the frame just drawn: a fault not found before by this Tester, past its file's bar, fails the test
/// at once, with what and where.
fn Tester::hold_sizes_steady(self : Tester) -> Unit {
  let faults = g().sizes_faults(self.fake.time, self.motion_period())
  if !sizes_steady.held {
    return
  }
  for fa in faults {
    let (across, f) = fa
    // (each one's once)
    let who = match f.find(": ") {
      Some(i) => f.unsafe_substring(start=0, end=i)
      None => f
    }
    let (check, found, bars) = if across {
      ("sizes_across", sizes_steady.found_across, sizes_across_bars)
    } else {
      ("sizes_steady", sizes_steady.found, sizes_steady_bars)
    }
    if found.contains(who) {
      continue
    }
    found.add(who)
    let bar = bars.get(sizes_steady.file).unwrap_or(0)
    motion_known_said(check, sizes_steady.file, found.length(), bar, f)
    if self.motion == Count {
      println("MOTION \{check} \{sizes_steady.file}: \{f} (the Tester made at \{looks_made_at.val})")
      continue
    }
    if found.length() > bar {
      let said = "sizes not steady (sizes_steady.mbt, \{check}), on a frame drawn \{self.w}×\{self.h} at \{self.fake.time}, the Tester made at \{looks_made_at.val}: " +
        "\{f}; \{found.length()} now, \{bar} known in \{sizes_steady.file}"
      @halt.saying(said)
    }
  }
}
