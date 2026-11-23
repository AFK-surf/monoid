// Where what the hand lets go of comes to rest, and whether that puts it away: the judgement every gesture that lets a
// thing go makes by the same model (a sheet drawn down, a toast swiped aside, a row archived), the framework's so that
// a headless component judges it too (ui's lands_past and flung_away say these again for the old view).

///|
/// Where what is let go at `at`, going `v` (points a ms, signed), comes to rest of itself: on from that speed as far as
/// it carries it (move_stop_points), the way a motion set off again from it goes first (flex's come_way).
pub fn lands_at(at : Double, v : Double) -> Double {
  if v > 0.0 {
    at + @flex.move_stop_points(v)
  } else if v < 0.0 {
    at - @flex.move_stop_points(v)
  } else {
    at
  }
}

///|
/// Whether what is let go at `at`, going `v` (points a ms, signed), lands past `line` (on its side of where it rests,
/// 0: over it where `line` is above 0, under it where below): where something let go goes (closed or back, archived or
/// back, a page back or not) is judged by where it lands, with a gesture's own fling, never by where it was let go
/// alone. So one judged back never goes on past its line before it turns: what it is carried on and turned is no more
/// than what it fell short of that line by (the coordinator of the migration, 2026-11-10: one model for where it goes
/// and how it goes there). Only the event's own place and speed as it is let go, never a frame's.
pub fn lands_past(at : Double, v : Double, line : Double) -> Bool {
  let x = lands_at(at, v)
  if line >= 0.0 {
    x > line
  } else {
    x < line
  }
}

///|
/// How fast (points a ms) a finger putting a thing away (a sheet down, a toast aside) lets go of it for that to put it
/// away however far it went: a flick (the coordinator of the migration, 2026-11-10: the same for the gestures of the
/// one kind).
pub let flung_away : Double = 0.5

