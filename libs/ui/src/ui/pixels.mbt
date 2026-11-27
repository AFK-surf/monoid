// An image's pixels, to make another picture from (an icon drawn from a picture, say): decoded by the host as Ctx::image
// has it (by its source, at most so many pixels on its long side) and read back from it once, kept while the run lasts.
// Not on a host that cannot read its images back (false from @hostapi.image_pixels): failed.

///|
/// What an image's pixels are so far.
#derive(Eq)
pub(all) enum ImagePixels {
  /// being decoded
  PixelsComing
  /// read: its width and height and its pixels (RGBA, premultiplied, rows from the top)
  PixelsRead(Int, Int, FixedArray[Byte])
  /// it did not decode, or cannot be read back here
  PixelsFailed
}

///|
/// What was read back of an image (pixels_for's): its pixels, its source, when it was last asked for (the frame, and
/// the count of asks then: which was asked longest ago), how many bytes its pixels are.
priv struct PixelsKept {
  pixels : ImagePixels
  src : String
  mut used : Int
  mut asked : Int
  bytes : Int
}

///|
/// Read back, by the long side asked for and the source ("BUCKET SRC").
let pixels_read : Map[String, PixelsKept] = Map([])

///|
/// The keys of pixels_read by each source (an image let go of lets go of what was read of it: forget_image).
let pixels_by_src : Map[String, Array[String]] = Map([])

///|
/// The bytes of the pixels read back kept (each PixelsRead's), told as pixels_read changes.
let pixels_bytes : Ref[Int] = Ref(0)

///|
/// How many reads that failed pixels_read keeps, told as it changes.
let pixels_failed : Ref[Int] = Ref(0)

///|
/// Each ask for pixels counted: which of those kept was asked for longest ago.
let pixels_asks : Ref[Int] = Ref(0)

///|
/// How many bytes of pixels read back are kept: past it, those asked for longest ago (and not this frame) let go,
/// read back again from their decode as they are asked for again.
let pixels_budget_most : Int = 32 * 1024 * 1024

///|
/// pixels_budget_most, but where a test says less.
let pixels_budget : Ref[Int] = Ref(pixels_budget_most)

///|
/// How many reads that failed are kept (each asked again once let go of: a decode tried again).
let pixels_failed_most : Int = 256

///|
/// What was read of `src` let go of (an image let go of, forget_image): read back again where it is asked for again.
fn pixels_forget(src : String) -> Unit {
  guard pixels_by_src.get(src) is Some(keys) else { return }
  pixels_by_src.remove(src)
  for key in keys {
    match pixels_read.get(key) {
      Some(k) => {
        pixels_read.remove(key)
        pixels_counted(k, -1)
      }
      None => ()
    }
  }
}

///|
/// What `k` counts for in pixels_bytes and pixels_failed, added (`sign` 1) or taken off (-1).
fn pixels_counted(k : PixelsKept, sign : Int) -> Unit {
  pixels_bytes.val = pixels_bytes.val + sign * k.bytes
  if k.pixels is PixelsFailed {
    pixels_failed.val = pixels_failed.val + sign
  }
}

///|
/// What was read back made no more than its budget (and its most failed): what was asked for longest ago let go first,
/// never `kept` (just read) nor one asked for in frame `used` (what this frame draws from).
fn pixels_trim(kept : String, used : Int) -> Unit {
  guard pixels_bytes.val > pixels_budget.val || pixels_failed.val > pixels_failed_most else { return }
  let all : Array[(String, PixelsKept)] = []
  for key, k in pixels_read {
    if key != kept && k.used < used {
      all.push((key, k))
    }
  }
  all.sort_by(fn(a, b) { a.1.asked.compare(b.1.asked) })
  for item in all {
    let (key, k) = item
    let over_bytes = pixels_bytes.val > pixels_budget.val && k.bytes > 0
    let over_failed = pixels_failed.val > pixels_failed_most && k.pixels is PixelsFailed
    if pixels_bytes.val <= pixels_budget.val && pixels_failed.val <= pixels_failed_most {
      break
    }
    if !over_bytes && !over_failed {
      continue
    }
    pixels_read.remove(key)
    pixels_counted(k, -1)
    match pixels_by_src.get(k.src) {
      Some(keys) => {
        keys.retain(fn(x) { x != key })
        if keys.is_empty() {
          pixels_by_src.remove(k.src)
        }
      }
      None => ()
    }
  }
}

///|
/// Everything read back let go of (Tester's reset).
fn pixels_reset() -> Unit {
  pixels_read.clear()
  pixels_by_src.clear()
  pixels_bytes.val = 0
  pixels_failed.val = 0
  pixels_asks.val = 0
  pixels_budget.val = pixels_budget_most
}

///|
/// The pixels of the image at `src` (a path, an http(s) URL, a key given to image_bytes) decoded to at most `px` on its
/// long side (a larger original made smaller; a smaller one as it is): coming until it is decoded, a frame asked for
/// as it is.
pub fn Ctx::image_pixels(self : Ctx, src : String, px : Int) -> ImagePixels {
  pixels_for(src, px, self.frame_no, self.clock)
}

///|
/// Ctx::image_pixels's, by whoever asks (image_entry_for's `used` and `at`): one decoder, one read back, for an old
/// view's build and a node alike.
fn pixels_for(src : String, px : Int, used : Int, at : Double) -> ImagePixels {
  let want = bucket(px.to_double())
  let key = "\{want} \{src}"
  pixels_asks.val = pixels_asks.val + 1
  match pixels_read.get(key) {
    Some(k) => {
      k.used = used
      k.asked = pixels_asks.val
      return k.pixels
    }
    None => ()
  }
  let p = match image_entry_for(src, px.to_double(), used, at) {
    Some(e) if e.state == 1 && e.px == want => {
      let w = e.w.to_int()
      let h = e.h.to_int()
      let out = FixedArray::make(w * h * 4, b'\x00')
      if h_image_pixels(e.id, out) {
        PixelsRead(w, h, out)
      } else {
        PixelsFailed
      }
    }
    _ =>
      match image_cache.get(src) {
        Some(list) if arr_any(list, fn(e) { e.state == -1 && e.px >= want }) => PixelsFailed
        _ => PixelsComing
      }
  }
  if p != PixelsComing {
    let bytes = match p {
      PixelsRead(_, _, out) => out.length()
      _ => 0
    }
    let k : PixelsKept = { pixels: p, src, used, asked: pixels_asks.val, bytes }
    pixels_read[key] = k
    pixels_counted(k, 1)
    pixels_by_src.get_or_init(src, fn() { [] }).push(key)
    pixels_trim(key, used)
  }
  p
}

///|
/// The pixels of the image at `src` decoded to at most `px` on its long side (Ctx::image_pixels's), for node `v` of the
/// window's tree, as it is made: its decode asked for then, at `v`'s moment (View::logic_at), as Ctx::image_pixels asks
/// it (the same decoder, the same pixels read back once and kept). None while it is coming; then its pixels (or
/// PixelsFailed: it did not decode, or cannot be read back here), set as what it waits on comes to hold: its decode to
/// that size done or failed (image_decoded: its DecodeState), or its bytes here where they were still on their way
/// (add_image). Nothing asked again till then. Read where `v` binds or reacts to it, followed. Another `px`, another
/// decode, another value.
pub fn tree_image_pixels(v : @view.View, src : String, px : Int) -> () -> ImagePixels? {
  let want = bucket(px.to_double())
  let asked = fn() {
    match pixels_for(src, px, g().frame_no, v.logic_at()) {
      PixelsComing => None
      p => Some(p)
    }
  }
  let got : @signals.Signal[ImagePixels?] = @signals.signal(asked())
  let said = image_said(src)
  let bytes = said.bytes
  let decodes = said.decodes
  let state = decode_state(src, want)
  // (asked again as what it waits on comes to hold or refreshes; keeps previous value during re-decode to avoid flicker,
  //  and propagates updated PixelsRead / PixelsFailed to every subscriber sharing pixels_read[key])
  v.reacts(fn() { (bytes.get(), decodes.get(), state.get()) }, fn(_) {
    match asked() {
      Some(p) =>
        if got.untracked() != Some(p) {
          got.set(Some(p))
        }
      None => ()
    }
  })
  fn() { got.get() }
}

///|
/// What the thing with `id` showed last frame, as the host drew it: its hit area as drawn (Ctx::rect_of, cut to its
/// clips) on the device's pixels, the frame drawn again by the host's renderer and read back (RGBA premultiplied, rows
/// from the top): a part of the screen to share as a picture. Failed where it was not drawn or the host cannot read its
/// frame back. Each read draws the frame again: asked once, as a press is told (Ctx::tell), not in every build. `inset`:
/// that much less of it on every side (what is round at its corners left out).
pub fn Ctx::drawn_pixels(self : Ctx, id : Int, inset? : Double = 0.0) -> ImagePixels {
  match self.rect_of(id) {
    Some((x0, y0, w0, h0)) => {
      let (x, y, w, h) = (x0 + inset, y0 + inset, w0 - 2.0 * inset, h0 - 2.0 * inset)
      let s = self.scale
      let x0 = (x * s).round().to_int()
      let y0 = (y * s).round().to_int()
      let pw = ((x + w) * s).round().to_int() - x0
      let ph = ((y + h) * s).round().to_int() - y0
      if x0 < 0 || y0 < 0 || pw <= 0 || ph <= 0 {
        return PixelsFailed
      }
      let out = FixedArray::make(pw * ph * 4, b'\x00')
      if h_drawn_pixels(x0, y0, pw, ph, out) {
        PixelsRead(pw, ph, out)
      } else {
        PixelsFailed
      }
    }
    None => PixelsFailed
  }
}
