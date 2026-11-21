// A linear gradient's ground, as CSS's linear-gradient(angle, from, to) paints a box (the notifications page's preview,
// web/src/pages/Notifications.css.ts screen): mbui's renderer has no gradient fill yet, so it is a small picture of
// the gradient made here from its two colours (sRGB, as CSS mixes them), laid stretched over the box. When mbui fills
// gradients itself, this goes onto that.

///|
/// How many pixels across the picture is made (its height in the box's proportion): the colours change slowly, so few
/// are needed, each stretched.
let gradient_px : Int = 64

///|
/// The picture of the gradient for a box `w` by `h` (as `gradient`'s), by the key the host keeps it at: made the first
/// time it is asked for, its key saying it all (a tree's node shows it by View::image).
pub fn gradient_key(w : Double, h : Double, angle : Double, from : Int64, to : Int64) -> String {
  let pw = gradient_px
  let ph = if w <= 0.0 { 2 } else { dmax_int(2, (h / w * pw.to_double()).round().to_int()) }
  let key = "mem:sf-gradient/\{from}/\{to}/\{angle}/\{pw}x\{ph}"
  // (made once while kept: its key says it all, the same picture each time it is asked for)
  gradients_made.ask(key, fn() { @ui.add_image(key, @pixels.png(pw, ph, gradient_pixels(pw, ph, w, h, angle, from, to))) })
  key
}

///|
/// The gradients' pictures kept (MadeImages): as many as a run shows at once, many times over.
// kept across runs: let go of as a run begins (on_reset)
let gradients_made : MadeImages = MadeImages::new(64)

///|
fn init {
  @ui.on_reset(fn() { gradients_made.clear() })
}

///|
fn dmax_int(a : Int, b : Int) -> Int {
  if a > b {
    a
  } else {
    b
  }
}

///|
/// The gradient's pixels (RGBA, row by row), each where its middle falls on the box's `w` by `h`: along the line through
/// the box's middle at `angle`, as long as the box reaches that way (CSS's gradient line), `from` at its start.
fn gradient_pixels(pw : Int, ph : Int, w : Double, h : Double, angle : Double, from : Int64, to : Int64) -> FixedArray[Byte] {
  let a = angle * @math.PI / 180.0
  let (dx, dy) = (@dmath.sin(a), -@dmath.cos(a))
  let len = (w * dx).abs() + (h * dy).abs()
  let px = FixedArray::make(pw * ph * 4, b'\x00')
  for j in 0..<ph {
    for i in 0..<pw {
      let x = (i.to_double() + 0.5) / pw.to_double() * w - w / 2.0
      let y = (j.to_double() + 0.5) / ph.to_double() * h - h / 2.0
      let t = if len <= 0.0 { 0.0 } else { (x * dx + y * dy) / len + 0.5 }
      let t = if t < 0.0 { 0.0 } else if t > 1.0 { 1.0 } else { t }
      let o = (j * pw + i) * 4
      for k in 0..<4 {
        let shift = 24 - k * 8
        let f = ((from >> shift) & 0xFFL).to_double()
        let g = ((to >> shift) & 0xFFL).to_double()
        px[o + k] = (f + (g - f) * t).round().to_int().to_byte()
      }
    }
  }
  px
}
