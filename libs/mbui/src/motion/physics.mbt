// What a finger's way comes to, worked out in closed form (no frame stepped): how far what is pulled past where it may
// rest is drawn (Apple's rubber band: UIScrollView's, 0.55), where a fling let go at a speed would come to rest
// (UIScrollView's deceleration, Apple's "projection": WWDC 2018 Designing Fluid Interfaces), and which of the places a
// thing may rest at (a sheet's detents, a segment, a tab) that landing is nearest. Pure functions of their arguments:
// what reads them is a handler at its event's moment (Drag's `at`, `vy()`) or a binding at the moment it is drawn.

///|
/// How far something pulled `offset` past where it may rest is drawn, over a room `dimension` long (Apple's rubber
/// band, UIScrollView's 0.55 by default): its sign kept, `coeff * |offset| * dimension / (dimension + coeff *
/// |offset|)`, so one to one times `coeff` at first (its slope at 0 is `coeff`, the same from either side), less and
/// less as it is pulled further, never as far as `dimension`. 0 where nothing is pulled or there is no room.
pub fn rubber_band(offset : Double, dimension : Double, coeff? : Double = 0.55) -> Double {
  if dimension <= 0.0 || offset == 0.0 {
    return 0.0
  }
  let a = offset.abs()
  let r = coeff * a * dimension / (dimension + coeff * a)
  if offset < 0.0 {
    -r
  } else {
    r
  }
}

///|
/// `value` as it is drawn where it may rest between `min` and `max`: there one to one, past either end only what
/// rubber_band draws of how far past it it is, over a room `dimension` long. Continuous at both ends.
pub fn rubber_band_clamped(
  value : Double,
  min : Double,
  max : Double,
  dimension : Double,
  coeff? : Double = 0.55,
) -> Double {
  if value < min {
    min + rubber_band(value - min, dimension, coeff~)
  } else if value > max {
    max + rubber_band(value - max, dimension, coeff~)
  } else {
    value
  }
}

///|
/// How far a fling at 1 unit a second goes on before it is at rest, slowing by `decel_rate` each ms (UIScrollView's: its
/// speed each ms that rate of the ms before's, all of them added up: `decel_rate / (1 - decel_rate)` ms' worth of its
/// speed a ms): 0.499 s of it at the normal rate
/// (UIScrollView.DecelerationRate.normal, 0.998).
pub fn landing_reach(decel_rate? : Double = 0.998) -> Double {
  if decel_rate <= 0.0 || decel_rate >= 1.0 {
    return 0.0
  }
  decel_rate / (1.0 - decel_rate) / 1000.0
}

///|
/// Where something at `pos` let go going `velocity_per_s` (its units a second) would come to rest, slowing as
/// UIScrollView's deceleration does (landing_reach): Apple's projection, what decides where a thing flung goes.
pub fn project_landing(pos : Double, velocity_per_s : Double, decel_rate? : Double = 0.998) -> Double {
  pos + velocity_per_s * landing_reach(decel_rate~)
}

///|
/// Which of the places something may rest at (`detents`, each a place in its units: a sheet's, a segment's middle) it
/// goes to, let go at `pos` going `velocity_per_s`: the one nearest where it would land (project_landing; the first of
/// two as near). `close_past`: where it would land past that, further than it on the way the places' values grow (a
/// sheet's way down: off the window), it goes to none, put away: None. None too where there is no place.
pub fn snap_detent(
  pos : Double,
  velocity_per_s : Double,
  detents : Array[Double],
  close_past? : Double,
  decel_rate? : Double = 0.998,
) -> Int? {
  let projected = project_landing(pos, velocity_per_s, decel_rate~)
  match close_past {
    Some(c) if projected > c => return None
    _ => ()
  }
  let mut best = -1
  let mut far = @double.infinity
  for i, d in detents {
    let f = (d - projected).abs()
    if f < far {
      far = f
      best = i
    }
  }
  if best < 0 {
    None
  } else {
    Some(best)
  }
}
