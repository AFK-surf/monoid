// A picture made as nodes (take_picture) cuts what a node that clips holds as the window's tree does (Ctx::view_paint,
// push_node_clip): to its ground as it is drawn (View::ground_drawn: off, bigger, its corners), and past its foot as far
// as it says (View::clips_past), not to the box it is laid out in.

///|
let clip_fill : Int64 = 0x12AB34FFL

///|
/// The instance of a rect of `color` among the `n` of `inst` (the last of them).
fn rect_of_color_in(inst : FixedArray[Double], n : Int, color : Int64) -> Array[Double] raise {
  let r = ((color >> 24) & 0xFFL).to_double() / 255.0
  let gr = ((color >> 16) & 0xFFL).to_double() / 255.0
  let mut found : Array[Double]? = None
  for k in 0..<n {
    let b = k * inst_size
    if inst[b + 5] == 0.0 && inst[b + 8] == r && inst[b + 9] == gr {
      found = Some(Array::makei(inst_size, fn(j) { inst[b + j] }))
    }
  }
  match found {
    Some(a) => a
    None => fail("no rect of \{color}")
  }
}

///|
/// Where the clip a rect `a` is drawn in is (x0, y0, x1, y1) from the rect's own corner, and its corners' radii.
fn clip_from_rect(a : Array[Double]) -> (Array[Double], Array[Double]) {
  ([a[16] - a[0], a[17] - a[1], a[18] - a[0], a[19] - a[1]], [a[24], a[25], a[26], a[27]])
}

///|
/// The clip the box of `clip_fill` that `make` makes is drawn in, in a picture made of it (take_picture's).
fn picture_fill_clip(make : (@view.View) -> Unit) -> (Array[Double], Array[Double]) raise {
  let t = Tester::new(fn(_c) {  }, w=200.0, h=120.0, scale=1.0)
  set_view_app(fn(root) { root.box(fn(b) { b.words(Is("here")) |> ignore }) |> ignore })
  t.draw()
  let seen : Ref[(FixedArray[Double], Int)?] = Ref(None)
  let was = shot_watch.val
  shot_watch.val = Some(fn(words, s) {
    let copy = FixedArray::make(s.ninst * inst_size, 0.0)
    s.inst.blit_to(copy, len=s.ninst * inst_size)
    seen.val = Some((copy, s.ninst))
    match was {
      Some(f) => f(words, s)
      None => ()
    }
  })
  let told = Ref(0)
  take_picture("clip", 150.0, make, fn(_) { told.val += 1 }, scale=1.0)
  t.draw()
  shot_watch.val = was
  assert_eq(told.val, 1)
  let (inst, n) = seen.val.unwrap()
  clip_from_rect(rect_of_color_in(inst, n, clip_fill))
}

///|
/// The clip the box of `clip_fill` that `make` makes is drawn in, in the window's tree.
fn window_fill_clip(make : (@view.View) -> Unit) -> (Array[Double], Array[Double]) raise {
  let t = Tester::new(fn(_c) {  }, w=200.0, h=200.0, scale=1.0)
  set_view_app(make)
  t.draw()
  clip_from_rect(rect_of_color(clip_fill))
}

///|
/// A box 100 by `h` rounded 8, clipping, its ground drawn as `ground` says and cut past its foot by `past`, holding a
/// box of `clip_fill` 100 by 80 at its corner; under it room, so the picture is taller than either.
fn clipped_fill(h : Double, ground : @view.GroundShape, past : Double) -> (@view.View) -> Unit {
  fn(root) {
    root.box(fn(b) {
      b
      .width(Is(Some(100.0)))
      .height(Is(Some(h)))
      .radius(Is(8.0))
      .clips(Is(true))
      .clips_past(Is(past))
      .ground_drawn(Is(ground))
      .box(fn(k) { k.width(Is(Some(100.0))).height(Is(Some(80.0))).ground(Is(clip_fill)) |> ignore })
      |> ignore
    })
    |> ignore
    root.box(fn(b) { b.height(Is(Some(80.0))) |> ignore }) |> ignore
  }
}

///|
test "a picture cuts what a node holds to its ground as it is drawn, off, bigger and as round as it says, as the window does" {
  let make = clipped_fill(60.0, { dx: 4.0, dy: 6.0, dw: 10.0, dh: -20.0, corners: Some((3.0, 5.0, 7.0, 9.0)) }, 0.0)
  let (box, corners) = picture_fill_clip(make)
  // (4 across and 6 down from where it is laid out, 110 by 40, its corners its ground's)
  assert_eq(box, [4.0, 6.0, 114.0, 46.0])
  assert_eq(corners, [3.0, 5.0, 7.0, 9.0])
  assert_eq(window_fill_clip(make), (box, corners))
}

///|
test "a picture cuts what a node holds as far past its foot as it says, as the window does" {
  let make = clipped_fill(40.0, @view.ground_as_laid, 15.0)
  let (box, corners) = picture_fill_clip(make)
  // (40 tall, cut 15 past its foot)
  assert_eq(box, [0.0, 0.0, 100.0, 55.0])
  assert_eq(corners, [8.0, 8.0, 8.0, 8.0])
  assert_eq(window_fill_clip(make), (box, corners))
}
