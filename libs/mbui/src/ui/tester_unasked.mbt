// A frame nothing asks for draws what the frame before it drew (Tester::frame_unasked: no motion, no wake or timer due,
// nothing come from outside, no input, no step said): a host at rest draws none, so where one drawn all the same
// draws otherwise, what shows at rest is not what it is worked out of, and a device shows it so till something else
// draws a frame (a value told the window's tree a frame late, a state changed and told nobody). The Tester holds it
// three ways: the screen as it stands, drawn again at its moment (Tester::unasked_faults, Tester::audit's first); each
// frame it draws that nothing asked for, against the one before it (Tester::frame_shown_first, every Tester's); and a
// measure that steps in its first frame and then stands, which no frame at rest finds while something else moves
// (sizes_steady.mbt's sizes_steady_fault).

///|
/// The screen as a frame left it: what it draws (looks_seen's), how many, and where its nodes were laid out
/// (looks_nodes_of), to be compared with a frame drawn after it (unasked_said).
priv struct UnaskedSeen {
  inst : FixedArray[Double]
  n : Int
  nodes : Array[(Double, Double, Double, Double, String, Int, Double, Double, Double)]
}

///|
/// The screen of `c` as it stands now (its groups drawn out as a host draws them: Ctx::flat_from).
fn unasked_seen(c : Ctx) -> UnaskedSeen {
  c.flat_from(0)
  let (inst, n) = looks_seen(c.inst, c.ninst)
  { inst, n, nodes: looks_nodes_of(c) }
}

///|
/// What a frame drawn at `at` (`how`: how it came to be drawn) draws otherwise than `seen`, the screen before it,
/// said: the first instance that parts (what it is and where, before and after), the first node laid out elsewhere,
/// and where what is drawn there was made (Tester::sources_at); None where it draws the same.
fn Tester::unasked_said(self : Tester, seen : UnaskedSeen, at : Double, how : String) -> String? {
  let c = g()
  c.flat_from(0)
  let (now, m) = looks_seen(c.inst, c.ninst)
  let (q, slot) = drawn_parted(seen.inst, seen.n, now, m)
  if q < 0 {
    return None
  }
  let inst = fn(a : FixedArray[Double], k : Int) {
    if q >= k {
      "none"
    } else {
      let b = q * inst_size
      "kind \{a[b + 5]} at \{a[b]},\{a[b + 1]} \{a[b + 2]}×\{a[b + 3]}" +
      (if slot >= 0 { " (slot \{slot}: \{a[b + slot]})" } else { "" })
    }
  }
  // (what is drawn there: the middle of the instance as drawn after, else as before)
  let (a, b) = if q < m { (now, q * inst_size) } else { (seen.inst, q * inst_size) }
  let there = self.sources_at(a[b] + a[b + 2] / 2.0, a[b + 1] + a[b + 3] / 2.0)
  Some(
    "unasked-frame: the screen at rest at \{at.to_int()} ms (\{seen.n} instances) is not what \{how} draws (\{m}) at instance \{q}: \{inst(seen.inst, seen.n)}, drawn so \{inst(now, m)}; \{looks_node_moved(c, seen.nodes)}; drawn there: \{there}",
  )
}

///|
/// Whether nothing asks for a frame at `at` as these checks judge it: Tester::frame_unasked (what an idle host's run
/// skips, a replay's), and no cycle read as the last frame was built or painted, no wake the frame, its looks or its
/// paint asked for by then, nothing the fake host does by then (one at that very moment too), its glyphs as the frame
/// had them.
fn Tester::unasked_at(self : Tester, at : Double) -> Bool {
  let c = g()
  let hair = at + due_hair
  self.frame_unasked(at) &&
  !c.cycling &&
  !looks_own.cycling &&
  !(c.wake_at >= 0.0 && c.wake_at <= hair) &&
  !(looks_base.wake >= 0.0 && looks_base.wake <= hair) &&
  !(paint_base.wake >= 0.0 && paint_base.wake <= hair) &&
  !(fake_dues.length() > 0 && fake_dues[0].0 <= hair) &&
  atlas_said.val == Some(self.fake.generation)
}

///|
/// Where the screen as it stands, at rest (nothing asks for a frame at the display's next: Tester::frame_unasked; the
/// time of day not read as it was drawn), is not what a frame drawn again at its moment draws: what shows was not
/// what it is worked out of (a value told a frame late, a state changed that told nothing), as a device would show it
/// till something else draws. Each such fault a line, `unasked-frame:` first, with where what parts was made; none
/// where the screen is not at rest. The frame drawn to look is the Tester's own: not counted, not judged for how what
/// moves goes, and the screen after it is that frame's, at the same moment.
pub fn Tester::unasked_faults(self : Tester) -> Array[String] {
  self.reads_own()
  if wall_read.val || !self.unasked_at(self.at_due(self.tick_after(self.fake.time))) {
    return []
  }
  let seen = unasked_seen(g())
  let frames = self.frames
  let motion = motion_unjudged.val
  motion_unjudged.val = true
  self.frame_again()
  motion_unjudged.val = motion
  self.frames = frames
  if wall_read.val {
    return []
  }
  let at = self.fake.time
  match self.unasked_said(seen, at, "a frame drawn again at its moment") {
    Some(s) => [s]
    None =>
      if self.unasked_at(self.at_due(self.tick_after(at))) {
        []
      } else {
        [
          "unasked-frame: the screen at rest at \{at.to_int()} ms drawn again at its moment asks for another frame: built whole because \{built_why.val}; what is said to move: \{g().moving_now().join("; ")}",
        ]
      }
  }
}

///|
/// The screen before a frame of the display's at `now` that nothing asks for (Tester::frame_unasked), where the looks
/// are checked (looks_check) and the frame is judged: kept to be compared with what the frame draws
/// (Tester::unasked_after). None where the frame is asked for, the clock does not move on (a frame drawn again at its
/// moment: Tester::frame_again's, judged by Tester::unasked_faults), or the time of day was read as it was drawn.
fn Tester::unasked_before(self : Tester, now : Double) -> UnaskedSeen? {
  let c = g()
  // (and the old view's frame at rest as the next one begins: no clock read as it was built, laid out or painted, what
  // its build left laid out the same, its looks settled, what it told outside the same, nothing told its parts, what
  // the pointer is over as the hand was told it: each of which a frame takes as it begins, a window's tree's none of
  // them. A window not shown shows nothing (cycle_look.mbt))
  if looks_check.val &&
    !looks_unjudged.val &&
    !wall_read.val &&
    app_shown_said.untracked() &&
    now > self.fake.time &&
    self.unasked_at(now) &&
    clock_read_at.val == "" &&
    layout_clock_at.val == "" &&
    paint_clock_at.val == "" &&
    (old_islands.is_empty() || paint_base.laid_same) &&
    looks_base.settled &&
    looks_base.left &&
    looks_base.told_same &&
    !nodes_run.told &&
    hand_over_same(c) {
    Some(unasked_seen(c))
  } else {
    None
  }
}

///|
/// The frame at `at` that nothing asked for, drawn: where it draws otherwise than the screen before it (`seen`,
/// Tester::unasked_before), the test fails (looks_fail), saying what parts and where it was made.
fn Tester::unasked_after(self : Tester, seen : UnaskedSeen?, at : Double) -> Unit {
  guard seen is Some(seen) else { return }
  if wall_read.val {
    return
  }
  match self.unasked_said(seen, at, "the frame nothing asked for after it") {
    Some(s) => looks_fail(s)
    None => ()
  }
}
