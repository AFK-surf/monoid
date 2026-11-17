///|
test "an icon under 24 widens its strokes by k^0.58, its points by k; at 24 and over both by k" {
  let near = fn(a : Double, b : Double) { (a - b).abs() < 1.0e-9 }
  // (a rail's 20, a bar's 16 and 14: one weight of ink, thinner by less than their size)
  let s20 = stroke_k(20.0 / 24.0)
  let s16 = stroke_k(16.0 / 24.0)
  let s14 = stroke_k(14.0 / 24.0)
  assert_true(near(s20, @dmath.pow(20.0 / 24.0, 0.58)), msg="20: \{s20}")
  assert_true(s20 > 20.0 / 24.0 && s16 > 16.0 / 24.0 && s14 > 14.0 / 24.0, msg="\{s20} \{s16} \{s14}")
  assert_true(s20 > s16 && s16 > s14, msg="still thinner as it is smaller: \{s20} \{s16} \{s14}")
  assert_eq(((1.75 * s20 * 100.0).round(), (1.75 * s16 * 100.0).round(), (1.75 * s14 * 100.0).round()), (157.0, 138.0, 128.0))
  // (at 24 and over, as its size)
  assert_true(near(stroke_k(1.0), 1.0))
  assert_true(near(stroke_k(1.5), 1.5))
  // (drawn so: a 16's stroke as wide as its weight says, its points where its size puts them)
  let shapes = icon_shapes([0.0, 2.0, 2.0, 4.0, 4.0, 20.0, 20.0], 16.0 / 24.0, 0x000000FFL)
  assert_eq(shapes.length(), 1)
  let width = shapes[0].width
  let pts = shapes[0].outlines[0].0
  assert_true(near(width, 2.0 * s16), msg="its stroke \{width}")
  assert_true(near(pts[2], 20.0 * 16.0 / 24.0), msg="its points \{Repr(pts)}")
}
