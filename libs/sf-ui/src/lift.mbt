// What a finger holds for its menu, lifted toward it (iOS's context menu; sf/motion.mbt kind 7, a control answering:
// held, its menu open): a little as it is held, all the way once its menu opens, back down as the menu goes. Lifted,
// it is drawn over the menu's scrim and under the menu (Stratum's OverScrim), so that what the menu is of stands out of what
// it dims; a sheet coming up over where it is, it goes up before it, clear of it, and back down with it as it goes.
// A chat's row (sfpages chat_row.mbt) and a message's picture (message_files.mbt) are.

///|
/// How far `key`'s thing is lifted this frame (0 … 1): `held` by a finger a while, `open` its menu up.
pub fn lift_of(c : @ui.Ctx, key : String, held : Bool, open : Bool) -> Double {
  @motion.animate(
    c,
    "lift/" + key,
    if open {
      1.0
    } else if held {
      lift_held
    } else {
      0.0
    },
    spec=@motion.tactile_bounce,
  )
}

///|
/// Node `i` (`key`'s) lifted `lift` of the way (lift_of), drawn `scale` times as large all the way up: over the scrim
/// of the menu up and under it, clear of the sheet the menu is in.
pub fn lift_over(c : @ui.Ctx, i : Int, key : String, lift : Double, scale : Double) -> Unit {
  if lift == 0.0 {
    return
  }
  c.look(i, @ui.look(scale=1.0 + (scale - 1.0) * lift))
  c.stratum(i, OverScrim)
  // (where the sheet is this frame, as it comes and goes: read once the frame is laid out, the same frame)
  let at = "lifted/" + key
  @motion.measure(c, i, at)
  @motion.placed(c, i, fn() {
    match (sheet_top_now(c), @motion.measured_rect(c, at)) {
      (Some(top), Some((_, y, _, h))) if y + h + lift_clear > top => {
        // no further than the sheet has come up into the window: what hangs past the window's foot is not thrown up
        // as the sheet starts out from under it, nor dropped back as it goes
        let (_, total) = c.window_size()
        let dy = dmin(0.0, dmax(top - lift_clear - (y + h), top - total))
        { ..@ui.still_look, dy }
      }
      _ => @ui.still_look
    }
  })
}

///|
/// How far it lifts while it is held (of all the way, its menu open), on a spring with a little give.
pub let lift_held : Double = 0.35

///|
// kept across runs: a value (no field of it changes)

///|
/// How far over a sheet coming up over it what is lifted stays.
let lift_clear : Double = 12.0

///|
/// What of the window's tree is lifted over the scrim (View::over_scrim: a chat's row) kept clear of the sheet up, as
/// lift_over keeps an old view's, and clear of it all the way once it is up (where it is and how tall).
fn init {
  @ui.over_scrim_floor.val = fn(c) {
    match @kit.sheet_place(c) {
      Some(p) => Some(p)
      // (a sheet of the window's tree up: where it was drawn this frame, sheet_node's)
      None =>
        match tree_sheet_place.val {
          Some(f) => f()
          None => None
        }
    }
  }
}

///|
/// Where the top of the sheet up is in the window this frame (kit's sheet_top's), the host's or the tree's.
fn sheet_top_now(c : @ui.Ctx) -> Double? {
  match @kit.sheet_top(c) {
    Some(top) => Some(top)
    None =>
      match tree_sheet_place.val {
        Some(f) => f().map(fn(p) { p.0 })
        None => None
      }
  }
}

///|
/// Where the sheet of the window's tree made last (sheet_node's: the topmost up) stands in the window as what is drawn
/// is drawn, its top and how tall it is (kit's sheet_place's, for what is lifted over the scrim to keep clear of it);
/// none while none is up.
// kept across runs: said by each sheet as it is made, put back as it is let go; each window's own (presented_windows)
let tree_sheet_place : Ref[(() -> (Double, Double)?)?] = Ref(None)
