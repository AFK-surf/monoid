// Pure closed-form glyph reveal (`glyph_in`), non-overlapping glyph crossfade (`glyph_change`),
// and cell-aligned single-line text morphing (`TextMorph`) with seamless mid-flight interruption.

///|
/// Default span (ms) over which one line of glyphs begins arriving or changing.
pub let glyph_line_ms : Double = 120.0

///|
/// Default per-glyph start-time jitter span (ms).
pub let glyph_jitter_ms : Double = 50.0

///|
/// Default single-glyph reveal duration (ms).
pub let glyph_reveal_ms : Double = 220.0

///|
/// Default single-glyph vertical rise distance (points).
pub let glyph_rise_px : Double = 6.0

///|
/// Default total span (ms) for a full non-overlapping glyph change including maximum speed variation.
pub let glyph_change_in_ms : Double = glyph_line_ms + glyph_reveal_ms * 1.2

///|
/// Deterministic hash in `[0.0, 1.0]` for glyph `index` and `salt`.
pub fn glyph_noise(index : Int, salt : Int) -> Double {
  let mut h = (index * 374761393 + salt * 668265263).reinterpret_as_uint()
  h = (h ^ (h >> 13)) * 1274126177U
  h = h ^ (h >> 16)
  (h & 0xFFFFU).reinterpret_as_int().to_double() / 65535.0
}

///|
/// Per-glyph arrival look at elapsed time `ms` given reading-order bias `turn`:
/// fades in and rises gently with deterministic per-glyph timing and height variation.
pub fn glyph_in(
  ms : Double,
  turn : Double,
  index : Int,
  salt : Int,
  jitter_ms? : Double = glyph_jitter_ms,
  glyph_ms? : Double = glyph_reveal_ms,
  rise_px? : Double = glyph_rise_px,
) -> @ui.GlyphLook {
  let still : @ui.GlyphLook = { alpha: 1.0, dx: 0.0, dy: 0.0, scale: 1.0, sx: 1.0 }
  let (j0, j1) = (glyph_noise(index, salt), glyph_noise(index, salt + 7919))
  let start = dmax(turn + (j0 - 0.5) * jitter_ms, 0.0)
  let p = if glyph_ms > 0.0 {
    (ms - start) / glyph_ms
  } else if ms >= start {
    1.0
  } else {
    0.0
  }
  if p <= 0.0 {
    return { alpha: 0.0, dx: 0.0, dy: 0.0, scale: 1.0, sx: 1.0 }
  }
  if p >= 1.0 {
    return still
  }
  let rise = rise_px * (0.7 + 0.6 * j1)
  {
    alpha: @ui.Ease::Out.at(dmin(p / 0.7, 1.0)),
    dx: 0.0,
    dy: rise * (1.0 - @ui.Ease::Out.at(p)),
    scale: 1.0,
    sx: 1.0,
  }
}

///|
/// Non-overlapping per-glyph transition: outgoing glyphs fade out in the first half (`p in [0, 0.5]`) before incoming
/// glyphs rise and fade in during the second half (`p in [0.5, 1.0]`).
pub fn glyph_change(
  ms : Double,
  turn : Double,
  index : Int,
  salt : Int,
  incoming : Bool,
  line_ms? : Double = glyph_line_ms,
  glyph_ms? : Double = glyph_reveal_ms,
  rise_px? : Double = glyph_rise_px,
) -> @ui.GlyphLook {
  let start = turn * 0.25 + line_ms * glyph_noise(index, salt) * 0.75
  let duration = glyph_ms * (0.8 + 0.4 * glyph_noise(index, salt + 7919))
  let p = if duration > 0.0 {
    dmax(dmin((ms - start) / duration, 1.0), 0.0)
  } else if ms >= start {
    1.0
  } else {
    0.0
  }
  let rise = rise_px * (0.7 + 0.6 * glyph_noise(index, salt + 15838))
  if incoming {
    let q = @ui.Ease::Out.at(dmax(p * 2.0 - 1.0, 0.0))
    { alpha: q, dx: 0.0, dy: rise * (1.0 - q), scale: 1.0, sx: 1.0 }
  } else {
    let q = @ui.Ease::Leave.at(dmin(p * 2.0, 1.0))
    { alpha: 1.0 - q, dx: 0.0, dy: -rise * 0.25 * q, scale: 1.0, sx: 1.0 }
  }
}

///|
/// Cell-aligned single-line text morph geometry between `was_cells` and `now_cells` (each `(center_x, width)` from
/// `@ui.glyph_cells`), supporting seamless mid-flight retargeting via `from` and `set_out`.
#derive(Eq, Debug)
pub(all) struct TextMorph {
  was_cells : Array[(Double, Double)]
  now_cells : Array[(Double, Double)]
  whole_from : Double
  whole_to : Double
  places : Int
  salt : Int
  from : Double?
  set_out : Array[(Double, Double)]
}

///|
/// Total horizontal width spanned by `cells` up to the right edge of its last cell (`0.0` when empty).
pub fn TextMorph::cells_width(cells : Array[(Double, Double)]) -> Double {
  match cells.last() {
    Some((x, w)) => x + w / 2.0
    None => 0.0
  }
}

///|
/// Construct a `TextMorph` from old/new glyph cell arrays, visible slot count `places`, deterministic `salt`,
/// and optional mid-flight continuation state (`from` width and per-glyph `set_out` `(dx, sx)`).
pub fn TextMorph::new(
  was_cells : Array[(Double, Double)],
  now_cells : Array[(Double, Double)],
  places : Int,
  salt : Int,
  from? : Double,
  set_out? : Array[(Double, Double)] = [],
) -> TextMorph {
  {
    was_cells,
    now_cells,
    whole_from: TextMorph::cells_width(was_cells),
    whole_to: TextMorph::cells_width(now_cells),
    places,
    salt,
    from,
    set_out,
  }
}

///|
/// Interpolated line width at progress `k` (`0..1`), clamped to `visible` room.
pub fn TextMorph::across(self : TextMorph, k : Double, visible : Double) -> Double {
  let from = self.from.unwrap_or(dmin(self.whole_from, visible))
  let to = dmin(self.whole_to, visible)
  from + (to - from) * k
}

///|
/// Horizontal offset `dx` and width scale `sx` for glyph `index` (outgoing or `incoming`) at width progress `k`.
/// Paired indices travel together while the wider glyph narrows smoothly; unmatched tails track the paired boundary.
pub fn TextMorph::place(self : TextMorph, k : Double, index : Int, incoming : Bool) -> (Double, Double) {
  let olds = self.was_cells
  let news = self.now_cells
  let set_out = fn(n : Int) { if n < self.set_out.length() { self.set_out[n] } else { (0.0, 1.0) } }
  if index < olds.length() && index < news.length() {
    let (old_x, old_w) = olds[index]
    let (new_x, new_w) = news[index]
    let (d0, s0) = set_out(index)
    let distance = new_x - old_x - d0
    let width = old_w * s0 + (new_w - old_w * s0) * k
    let face_w = if incoming { new_w } else { old_w }
    (
      if incoming { -distance * (1.0 - k) } else { d0 + distance * k },
      if face_w > 0.0 { dmin(width / face_w, 1.0) } else { 1.0 },
    )
  } else if index < olds.length() && news.length() > 0 {
    let n = news.length() - 1
    let (old_x, old_w) = olds[n]
    let (new_x, new_w) = news[n]
    let (d0, s0) = set_out(index)
    (d0 + (new_x + new_w / 2.0 - old_x - old_w / 2.0 - d0) * k, s0 + (1.0 - s0) * k)
  } else if index < news.length() && olds.length() > 0 {
    let n = olds.length() - 1
    let (old_x, old_w) = olds[n]
    let (new_x, new_w) = news[n]
    let (dn, _) = set_out(n)
    ((old_x + old_w / 2.0 + dn - new_x - new_w / 2.0) * (1.0 - k), 1.0)
  } else {
    (0.0, 1.0)
  }
}

///|
/// Combined glyph appearance at `reveal` (`0..1`) and width progress `k` (`0..1`): non-overlapping fade/rise from
/// `glyph_change` composed with cell-aligned `(dx, sx)` from `TextMorph::place`.
pub fn TextMorph::look(
  self : TextMorph,
  reveal : Double,
  k : Double,
  at : @ui.GlyphAt,
  incoming : Bool,
  in_ms? : Double = glyph_change_in_ms,
  line_ms? : Double = glyph_line_ms,
) -> @ui.GlyphLook {
  let intervals = if self.places > 1 { self.places - 1 } else { 1 }
  let along = dmin(at.index.to_double() / intervals.to_double(), 1.0)
  let look = glyph_change(
    reveal * in_ms,
    along * line_ms,
    at.index,
    self.salt,
    incoming,
    line_ms~,
  )
  let (dx, sx) = self.place(k, at.index, incoming)
  { ..look, dx, sx }
}
