// A chat's state as a mark in a line:
// before a row's title in the chats' lists (sidebar.mbt, a finger's and a mouse's alike), on the rail's lists and
// workspaces. One meaning to a mark wherever it is (an agent's corner, agent_mark.mbt, says the same): yellow spokes
// stepping round at work, a blue dot when it is the viewer's turn (a card or an agent waiting on them, or something
// unread), a red one when something went wrong; nothing when nothing is for them. What kind of turn it is the row's
// second line says (its bell, card label, check), not a shape of its own here.

///|
/// The spokes' box.
let mark_busy_side : Double = 10.0

///|
/// The mark each chat has had, as its row was last drawn.
let marks_seen : Map[String, String] = Map([])

///|
fn marks_reset() -> Unit {
  marks_seen.clear()
}

///|
/// The icon (14), and how far it stands out of its 10 wide column on each side.
let state_icon : Double = 14.0

///|
let state_icon_out : Double = 2.0

///|
/// The loop's length (3.1 s) and each part's delay in it: waiting's dots 0, .3 s, .6 s; watching's arcs .18 s, .42 s
/// (its dot at once).
let lead_loop_ms : Double = 3100.0

///|
// kept across runs: a table, never written
let wait_delays : Array[Double] = [0.0, 300.0, 600.0]

///|
// kept across runs: a table, never written
let watch_delays : Array[Double] = [180.0, 420.0]

///|
/// A keyframe track at `f` (0 to 1): its stops (where, what), each step eased by `ease`.
fn keyframes(f : Double, stops : Array[(Double, Double)], ease : @ui.Ease) -> Double {
  for i in 1..<stops.length() {
    let (a, va) = stops[i - 1]
    let (b, vb) = stops[i]
    if f <= b {
      let t = if b > a { (f - a) / (b - a) } else { 1.0 }
      return va + (vb - va) * ease.at(t)
    }
  }
  stops[stops.length() - 1].1
}

///|
/// Waiting's dots (keyframes.css.ts leadBreathe, ease-in-out): .35, 1 at 23%, .35 from 52% on.
fn lead_breathe(f : Double) -> Double {
  keyframes(f, breathe_stops, InOut)
}

///|
// kept across runs: a table, never written
let breathe_stops : Array[(Double, Double)] = [(0.0, 0.35), (0.23, 1.0), (0.52, 0.35), (1.0, 0.35)]

///|
/// Watching's dot (leadBeat, ease-out): its size 1, 1.35 at 8%, 1 from 22% on.
fn lead_beat(f : Double) -> Double {
  keyframes(f, beat_stops, Out)
}

///|
// kept across runs: a table, never written
let beat_stops : Array[(Double, Double)] = [(0.0, 1.0), (0.08, 1.35), (0.22, 1.0), (1.0, 1.0)]

///|
/// Watching's arcs (leadLit, ease-out): .3, 1 at 10%, .3 from 32% on.
fn lead_lit(f : Double) -> Double {
  keyframes(f, lit_stops, Out)
}

///|
// kept across runs: a table, never written
let lit_stops : Array[(Double, Double)] = [(0.0, 0.3), (0.1, 1.0), (0.32, 0.3), (1.0, 0.3)]

///|
/// The line led by an icon: its words begin where a marked title's do, using the same gap for either native input.
fn state_lead_line() -> @ui.Style {
  state_lead_line_base.then(@ui.style(gap=@sf.theme().chat_list.head.base.gap.unwrap_or(S0)))
}

///|
// kept across runs: a value (no field of it changes)
let state_lead_line_base : @ui.Style = @ui.css("row w=Full align=ACenter")

///|
/// The title's mark's column: 10 wide, 14 high (leadSlot).
// kept across runs: a value (no field of it changes)
let state_slot : @ui.Style = @ui.css("w=S2_5 h=S3_5")

///|
// kept across runs: a value (no field of it changes)
let state_row : @ui.Style = @ui.css("row w=Full align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let state_rest_cut : @ui.TextStyle = @ui.text_style(w=Cut)
