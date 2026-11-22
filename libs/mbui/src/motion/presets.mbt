// The motion presets the old controls (`mbui/kit`) were made with and the tree's looks (an app's library) go on with:
// how long a thing comes and goes, how a panel by its trigger, a tooltip, a dialog and its ground come, how a sheet
// let go settles, and how a thing a finger moves follows it. Values and pure functions only; kit's names forward here.

///|
/// How long `presence` takes by default to come in (ms), and to go out: a tween each.
pub let presence_in_ms : Double = 150.0

///|
pub let presence_out_ms : Double = 100.0

///|
/// How a small panel by its trigger comes (still.fail's: controls.css.ts popover, popKeyframes): from 97% of its size
/// and clear to itself over 140 ms on the ease-out, growing out of the side of what it hangs on; it goes the way it
/// came, back to 97% and clear over 100 ms on the leaving fade's ease (not at once as the web's, unmounted: still.fail's Android
/// app, pengxiao 2026-10-25, its dialogs and menus vanishing as they closed). A popover's, a menu's, a select's, a
/// hover card's, a dialog's by default.
// kept across runs: a value (no field of it changes)
pub let pop_in : Trans = trans(fade=0.0, scale=0.97, spec=tween(pop_ms, ease=Out), ground_first=true)

///|
pub let pop_ms : Double = 140.0

///|
// kept across runs: a value (no field of it changes)
pub let pop_out : Trans = trans(fade=0.0, scale=0.97, spec=tween(pop_out_ms, ease=Leave), ground_first=true)

///|
pub let pop_out_ms : Double = 100.0

///|
/// How a liquid-glass popover or menu comes in: glass shell and content fade and scale together
/// (`ground_first=false`, avoiding a hollow refractive glass flash; `words_over` treats glass
/// instances as covering underlying words, while solid fallback uses `pop_in`).
// kept across runs: a value (no field of it changes)
pub let glass_pop_in : Trans = trans(fade=0.0, scale=0.97, spec=tween(pop_ms, ease=Out))

///|
/// How a liquid-glass popover or menu goes out: glass shell and content dissolve together over
/// `pop_out_ms` on `InOut` (`ground_first=false`: even 6-frame 60fps dissolve without a hollow
/// glass shell or final-frame cliff, and C0-continuous reversal if interrupted mid-`glass_pop_in`).
// kept across runs: a value (no field of it changes)
pub let glass_pop_out : Trans = trans(fade=0.0, scale=0.97, spec=tween(pop_out_ms, ease=InOut))

///|
/// How a tooltip comes (parts.css.ts tooltip: fadeKeyframes, 120 ms on the ease-out); it goes at once.
// kept across runs: a value (no field of it changes)
pub let tip_in : Trans = trans(fade=0.0, spec=tween(120.0, ease=Out), ground_first=true)

///|
/// How a dialog comes (still.fail's: parts.css.ts dialog, dialogInKeyframes): from 98% of its size, a little low and
/// clear, to itself over 200 ms on the ease-out; the page under it dimmed over 180 ms (parts.css.ts overlay). Both go
/// at once, as the web's (unmounted) do.
// kept across runs: a value (no field of it changes)
pub let dialog_in : Trans = trans(fade=0.0, scale=0.98, dy=6.0, spec=tween(dialog_ms, ease=Out), ground_first=true)

///|
pub let dialog_ms : Double = 200.0

///|
// kept across runs: a value (no field of it changes)
pub let ground_in : Trans = trans(fade=0.0, spec=tween(180.0, ease=Out))

///|
/// A dialog's ground going: as what it held goes (pop_out), faded as one, no words of its own.
// kept across runs: a value (no field of it changes)
pub let ground_out : Trans = trans(fade=0.0, scale=0.97, spec=tween(pop_out_ms, ease=Leave))

///|
/// How long a sheet's scrim takes to fade in or out (ms).
pub let sheet_scrim_ms : Double = 300.0

///|
/// Whether a sheet without detents let go `down` below its place, going `speed` down (points a ms), closes: landing past
/// `line` on from that speed (@ui.lands_past), or flicked down (@ui.flung_away) however short; else back. So one let
/// go back never goes on down past `line` before it turns (the coordinator of the migration, 2026-11-10). Its node
/// sheet's (sf's sheet_node) the same.
pub fn sheet_drag_closes(down : Double, speed : Double, line : Double) -> Bool {
  @ui.lands_past(down, speed, line) || speed >= @ui.flung_away
}

///|
/// Where a sheet with detents (`shares` of the window, `total` tall) let go `at` tall, going `speed` down (points a ms),
/// settles (none: it closes): flicked (@ui.flung_away) a detent on the way it was flicked from where it was let go,
/// down from its lowest closed, up from its highest its highest; else the detent nearest where it lands on from that
/// speed (@ui.lands_at), closed landing under `close_below` of the window. So one let go short of closing goes on
/// down no further than it was from closing before it turns (the coordinator of the migration, 2026-11-10). Its node
/// sheet's (sf's sheet_node) the same.
pub fn sheet_goes_to(shares : Array[Double], at : Double, speed : Double, total : Double, close_below : Double) -> Double? {
  let f = at / total
  if speed >= @ui.flung_away {
    // (the highest under it)
    let mut below : Double? = None
    for s in shares {
      if s < f && (match below { Some(b) => s > b; None => true }) {
        below = Some(s)
      }
    }
    below
  } else if speed <= -@ui.flung_away {
    // (the lowest over it; over the highest, the highest)
    let mut above : Double? = None
    let mut most = shares[0]
    for s in shares {
      most = if s > most { s } else { most }
      if s > f && (match above { Some(b) => s < b; None => true }) {
        above = Some(s)
      }
    }
    Some(above.unwrap_or(most))
  } else {
    let lands = @ui.lands_at(at, -speed) / total
    if lands < close_below {
      None
    } else {
      Some(nearest_share(shares, lands))
    }
  }
}

///|
/// Of `shares`, the one nearest `f`.
fn nearest_share(shares : Array[Double], f : Double) -> Double {
  let mut best = shares[0]
  for x in shares {
    if (x - f).abs() < (best - f).abs() {
      best = x
    }
  }
  best
}

///|
/// How long a progress bar's fill takes to a value told anew (still.fail's: waiting.css.ts progress, its width 200 ms
/// on the ease-out).
pub let progress_ms : Double = 200.0

///|
/// How long what runs along a progress bar while it is not known takes to draw itself into the part come (and back).
pub let progress_known_ms : Double = 360.0

///|
/// How long the band of a progress bar not known takes to sweep across once (its look's `period`).
pub let progress_sweep_ms : Double = 1400.0

///|
/// How much longer a thing a finger moves is drawn toward where it goes, and how much lower, by `v` (its way a frame
/// at 60): the bar's ball's (a frame's way times 1.6, at most 36; a fifth of that off its height, at most 6).
pub fn speed_stretch(v : Double) -> (Double, Double) {
  let longer = dmin(stretch_most, v.abs() * stretch_by)
  (longer, dmin(lower_most, longer * lower_by))
}

///|
let stretch_by : Double = 1.6

///|
let stretch_most : Double = 36.0

///|
let lower_by : Double = 0.2

///|
let lower_most : Double = 6.0

///|
/// How a picture let go slows: as e^(−t / this) (ms), Motion's inertia's own time constant (about the desktop's coasting,
/// 0.997 a ms), setting out as fast as the finger went.
pub let zoom_fling_ms : Double = 325.0
