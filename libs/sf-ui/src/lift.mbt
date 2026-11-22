// What a finger holds for its menu, lifted toward it (iOS's context menu; sf/motion.mbt kind 7, a control answering:
// held, its menu open): a little as it is held, all the way once its menu opens, back down as the menu goes. Lifted,
// it is drawn over the menu's scrim and under the menu (Stratum's OverScrim), so that what the menu is of stands out of what
// it dims; a sheet coming up over where it is, it goes up before it, clear of it, and back down with it as it goes.
// A chat's row (sfpages chat_row.mbt) and a message's picture (message_files.mbt) are.

///|
/// How far it lifts while it is held (of all the way, its menu open), on a spring with a little give.
pub let lift_held : Double = 0.35

///|
/// What of the window's tree is lifted over the scrim (View::over_scrim: a chat's row) kept clear of the sheet up,
/// and clear of it all the way once it is up (where it is and how tall).
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
/// Where the sheet of the window's tree made last (sheet_node's: the topmost up) stands in the window as what is drawn
/// is drawn, its top and how tall it is (kit's sheet_place's, for what is lifted over the scrim to keep clear of it);
/// none while none is up.
// kept across runs: said by each sheet as it is made, put back as it is let go; each window's own (presented_windows)
let tree_sheet_place : Ref[(() -> (Double, Double)?)?] = Ref(None)
