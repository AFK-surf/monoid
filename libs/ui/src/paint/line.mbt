// Lines (Compose's drawPath with a round-capped Stroke), as data: what an old view's box (Ctx::lines) and a node of the
// window's tree (View::lines) draw, each piece of one an instance the renderers draw as it is (ui's scene.mbt kind 10).

///|
/// A line through `points` (from the top left of the box it is drawn in), `width` wide, its ends and joins round, in
/// `color` (RRGGBBAA), drawn as far along its length as `upto` (a share of it, 0 … 1: a line as it is being drawn).
/// Its pieces' round ends lie over each other where they join: a colour that lets what is under it show (its alpha
/// under 1) shows darker there.
#derive(Eq, Debug)
pub(all) struct Line {
  points : Array[(Double, Double)]
  width : Double
  color : Int64
  upto : Double
}

///|
/// A line (see `Line`): whole unless `upto` says how much of it.
pub fn line(points : Array[(Double, Double)], width~ : Double, color~ : Int64, upto? : Double = 1.0) -> Line {
  { points, width, color, upto }
}

///|
/// How far from its circle a piece of an arc may stray at its middle: pieces short enough that the line through them
/// is round to the eye at any scale a screen has.
let arc_sag = 0.05

///|
/// Points along the arc of the circle about (`cx`, `cy`) of radius `r` from the angle `from` through `sweep` (radians,
/// clockwise on the screen from the right: 0 is 3 o'clock, π/2 is 6 o'clock), as many as keep each piece within
/// `arc_sag` of the circle.
pub fn arc(cx : Double, cy : Double, r : Double, from~ : Double, sweep~ : Double) -> Array[(Double, Double)] {
  let step = (8.0 * arc_sag / dmax(r, arc_sag)).sqrt()
  let n = @math.ceil(sweep.abs() / step).to_int()
  let n = if n < 1 { 1 } else { n }
  let out = []
  for k in 0..=n {
    let a = from + sweep * k.to_double() / n.to_double()
    out.push((cx + r * @dmath.cos(a), cy + r * @dmath.sin(a)))
  }
  out
}


///|
/// The piece of the line through `points` between `from` and `upto` of its length (shares, 0 … 1, each kept to that):
/// its points between, and where it is cut, worked out along the piece it is cut in. A line drawn from a share of it to
/// another (a tick drawn by its stroke from its middle, a part of a path lit), `width` wide in `color`. None of it
/// (`upto` at or before `from`, or no length): no points.
pub fn subline(
  points : Array[(Double, Double)],
  from~ : Double,
  upto~ : Double,
  width~ : Double,
  color~ : Int64,
) -> Line {
  let a = dclamp(from, 0.0, 1.0)
  let b = dclamp(upto, 0.0, 1.0)
  let lens : Array[Double] = []
  let mut whole = 0.0
  for i in 1..<points.length() {
    let (x0, y0) = points[i - 1]
    let (x1, y1) = points[i]
    let l = ((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0)).sqrt()
    lens.push(l)
    whole = whole + l
  }
  if b <= a || whole <= 0.0 {
    return line([], width~, color~)
  }
  let (sa, sb) = (a * whole, b * whole)
  // (the point `s` along piece `i`, which starts `at` along the line)
  let along = fn(i : Int, at : Double, s : Double) -> (Double, Double) {
    let (x0, y0) = points[i]
    let (x1, y1) = points[i + 1]
    let k = if lens[i] <= 0.0 { 0.0 } else { dclamp((s - at) / lens[i], 0.0, 1.0) }
    (x0 + (x1 - x0) * k, y0 + (y1 - y0) * k)
  }
  let out : Array[(Double, Double)] = []
  let mut at = 0.0
  for i in 0..<lens.length() {
    let end = at + lens[i]
    if end >= sa && at <= sb {
      if out.is_empty() {
        out.push(along(i, at, sa))
      }
      if end < sb {
        out.push(points[i + 1])
      } else {
        out.push(along(i, at, sb))
        break
      }
    }
    at = end
  }
  line(out, width~, color~)
}

///|
/// A line from (`x_rest`, 0) to (`x_rest`, `h`) pulled aside `pull_x` at the height `pull_y` (kept off its ends by a
/// quarter of `spread` or half of it, whichever is less): a string held at both ends and drawn aside by a finger. Its
/// way aside rises from rest `spread` over that height and falls back `spread` under it (or to its ends, whichever is
/// nearer) along half a cosine's wave each side (no step in it, nor in how it slopes: it leaves its rest and meets the
/// pull along it), points about every 2.5 along what bends, none along what is straight but its ends. Pulled less than
/// 0.05 (or no height): its two ends alone, straight.
pub fn tension_line(
  h : Double,
  x_rest : Double,
  pull_x : Double,
  pull_y : Double,
  spread? : Double = 72.0,
) -> Array[(Double, Double)] {
  if pull_x.abs() < 0.05 || h <= 0.0 {
    return [(x_rest, 0.0), (x_rest, h)]
  }
  let spread = dmax(spread, 1.0)
  let margin = dmin(h / 2.0, spread / 4.0)
  let y0 = dclamp(pull_y, margin, h - margin)
  let a = dmax(0.0, y0 - spread)
  let b = dmin(h, y0 + spread)
  let pi = @math.PI
  let x_at = fn(y : Double) -> Double {
    let k = if y <= y0 { (y - a) / (y0 - a) } else { (b - y) / (b - y0) }
    x_rest + pull_x * 0.5 * (1.0 - @dmath.cos(pi * dclamp(k, 0.0, 1.0)))
  }
  let out : Array[(Double, Double)] = [(x_rest, 0.0)]
  let n = dmax(2.0, ((b - a) / 2.5).ceil()).to_int()
  for i in 0..=n {
    let y = a + (b - a) * i.to_double() / n.to_double()
    // (the ends where the bend starts at the line's own ends: already there)
    if (i == 0 && a <= 0.0) || (i == n && b >= h) {
      continue
    }
    out.push((x_at(y), y))
  }
  out.push((x_rest, h))
  out
}
