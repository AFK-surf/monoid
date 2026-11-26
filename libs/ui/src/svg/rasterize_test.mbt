///|
test "an SVG's bytes drawn at the size asked, its longer side that many pixels" {
  let svg = @utf8.encode(
    "<svg xmlns='http://www.w3.org/2000/svg' width='40' height='20'><rect width='20' height='20' fill='#ff0000'/></svg>",
  )
  guard @svg.rasterize(svg, 80) is Some((w, h, rgba)) else { fail("not drawn") }
  assert_eq(w, 80)
  assert_eq(h, 40)
  // the left half red, straight alpha
  assert_eq((rgba[0].to_int(), rgba[1].to_int(), rgba[2].to_int(), rgba[3].to_int()), (255, 0, 0, 255))
  // the right half clear
  let i = (10 * w + 70) * 4
  assert_eq(rgba[i + 3].to_int(), 0)
  // a tall one: its height the longer side
  let tall = @utf8.encode("<svg xmlns='http://www.w3.org/2000/svg' width='10' height='30'/>")
  guard @svg.rasterize(tall, 90) is Some((tw, th, _)) else { fail("not drawn") }
  assert_eq((tw, th), (30, 90))
  assert_true(@svg.rasterize(@utf8.encode("not svg"), 50) is None)
}

///|
test "a style sheet's ^=, $= and *= attribute selectors (mermaid's markers: [id$=\"-extensionStart\"])" {
  // each rule's selector list has one of them first: the whole rule was dropped when it did not read
  let svg = @utf8.encode(
    "<svg xmlns='http://www.w3.org/2000/svg' width='30' height='10'><style>" +
    "rect{fill:#ff0000}" +
    "[id^=\"a-\"],.none{fill:#00ff00}" +
    "[id$=\"-b\"],.none{fill:#0000ff}" +
    "[id*=\"mid\"],.none{fill:#ffffff}" +
    "</style><rect id='a-1' width='10' height='10'/><rect id='x-b' x='10' width='10' height='10'/>" +
    "<rect id='xmidx' x='20' width='10' height='10'/></svg>",
  )
  guard @svg.rasterize(svg, 30) is Some((w, _, rgba)) else { fail("not drawn") }
  let at = fn(x) { (rgba[(5 * w + x) * 4].to_int(), rgba[(5 * w + x) * 4 + 1].to_int(), rgba[(5 * w + x) * 4 + 2].to_int()) }
  assert_eq(at(5), (0, 255, 0))
  assert_eq(at(15), (0, 0, 255))
  assert_eq(at(25), (255, 255, 255))
}

///|
/// One pixel of `rasterize`'s straight-alpha RGBA.
fn px_rgba(rgba : FixedArray[Byte], w : Int, x : Int, y : Int) -> (Int, Int, Int, Int) {
  let i = (y * w + x) * 4
  (rgba[i].to_int(), rgba[i + 1].to_int(), rgba[i + 2].to_int(), rgba[i + 3].to_int())
}

///|
fn rgba_said(p : (Int, Int, Int, Int)) -> String {
  let (r, g, b, a) = p
  "\{r},\{g},\{b},\{a}"
}

///|
/// Between stop 0 (#F29100) and stop 1 (#EC670F) about a third of the way: ~(240, 128, 6).
fn is_mid_orange(p : (Int, Int, Int, Int)) -> Bool {
  let (r, g, b, a) = p
  r >= 237 && r <= 242 && g >= 122 && g <= 135 && b >= 3 && b <= 9 && a == 255
}

///|
test "a linearGradient in <defs> after the shapes that use it (Figma's ocaml.org logo)" {
  let src = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"146\" height=\"40\" viewBox=\"0 0 146 40\" fill=\"none\">\n" +
    "  <path d=\"M10 10H40V35H10Z\" fill=\"url(#g0)\"/>\n" +
    "  <path d=\"M50 10H80V35H50Z\" fill=\"#111827\"/>\n" +
    "  <defs>\n" +
    "    <linearGradient id=\"g0\" x1=\"16.835\" y1=\"27.4364\" x2=\"16.835\" y2=\"39.999\" gradientUnits=\"userSpaceOnUse\">\n" +
    "      <stop stop-color=\"#F29100\"/>\n" +
    "      <stop offset=\"1\" stop-color=\"#EC670F\"/>\n" +
    "    </linearGradient>\n" +
    "  </defs>\n" +
    "</svg>"
  guard @svg.render_svg_to_width(src, 146, @svg.Options::default()) is Some(pm) else { fail("not drawn") }
  let at = fn(x : Int, y : Int) -> (Int, Int, Int, Int) raise {
    guard pm.pixel(x, y) is Some(p) else { fail("off the pixmap") }
    (p.r, p.g, p.b, p.a)
  }
  // y=22 is above y1=27.4364: padded with stop 0
  assert_eq(at(25, 22), (242, 145, 0, 255))
  // y=32 is between y1 and y2
  assert_true(is_mid_orange(at(25, 32)), msg="(25,32) \{rgba_said(at(25, 32))}")
  assert_eq(at(65, 22), (0x11, 0x18, 0x27, 255))
  guard @svg.rasterize(@utf8.encode(src), 146) is Some((w1, h1, rgba1)) else { fail("not drawn") }
  assert_eq((w1, h1), (146, 40))
  assert_eq(px_rgba(rgba1, w1, 25, 22), (242, 145, 0, 255))
  assert_true(is_mid_orange(px_rgba(rgba1, w1, 25, 32)), msg="146 (25,32) \{rgba_said(px_rgba(rgba1, w1, 25, 32))}")
  assert_eq(px_rgba(rgba1, w1, 65, 22), (0x11, 0x18, 0x27, 255))
  // twice the size: the gradient scales with it
  guard @svg.rasterize(@utf8.encode(src), 292) is Some((w2, h2, rgba2)) else { fail("not drawn") }
  assert_eq((w2, h2), (292, 80))
  assert_eq(px_rgba(rgba2, w2, 50, 44), (242, 145, 0, 255))
  assert_true(is_mid_orange(px_rgba(rgba2, w2, 50, 64)), msg="292 (50,64) \{rgba_said(px_rgba(rgba2, w2, 50, 64))}")
  assert_eq(px_rgba(rgba2, w2, 130, 44), (0x11, 0x18, 0x27, 255))
}

///|
test "trailing <defs>: Figma ids, gradientTransform, stop-opacity, three stops, radial, clipPath, mask, two <defs>" {
  let src = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"120\" height=\"40\" viewBox=\"0 0 120 40\" fill=\"none\">\n" +
    "  <rect x=\"2\" y=\"2\" width=\"24\" height=\"36\" fill=\"url(#paint0_linear_12_34)\"/>\n" +
    "  <rect x=\"30\" y=\"2\" width=\"24\" height=\"36\" fill=\"url(#paint1_radial_5_6)\"/>\n" +
    "  <rect x=\"58\" y=\"2\" width=\"24\" height=\"36\" fill=\"#00ff00\" clip-path=\"url(#clip0_9_10)\"/>\n" +
    "  <rect x=\"86\" y=\"2\" width=\"24\" height=\"36\" fill=\"#0000ff\" mask=\"url(#mask0_11_12)\"/>\n" +
    "  <defs>\n" +
    "    <linearGradient id=\"paint0_linear_12_34\" x1=\"2\" y1=\"2\" x2=\"26\" y2=\"38\" gradientUnits=\"userSpaceOnUse\" gradientTransform=\"translate(0 0)\">\n" +
    "      <stop stop-color=\"#ff0000\" stop-opacity=\"0.5\"/>\n" +
    "      <stop offset=\"0.5\" stop-color=\"#00ff00\" stop-opacity=\"1\"/>\n" +
    "      <stop offset=\"1\" stop-color=\"#0000ff\" stop-opacity=\"1\"/>\n" +
    "    </linearGradient>\n" +
    "    <radialGradient id=\"paint1_radial_5_6\" cx=\"42\" cy=\"20\" r=\"16\" gradientUnits=\"userSpaceOnUse\">\n" +
    "      <stop stop-color=\"#ffff00\"/>\n" +
    "      <stop offset=\"1\" stop-color=\"#ff00ff\"/>\n" +
    "    </radialGradient>\n" +
    "  </defs>\n" +
    "  <defs>\n" +
    "    <clipPath id=\"clip0_9_10\"><rect x=\"58\" y=\"2\" width=\"12\" height=\"36\"/></clipPath>\n" +
    "    <mask id=\"mask0_11_12\"><rect x=\"86\" y=\"2\" width=\"12\" height=\"36\" fill=\"#ffffff\"/></mask>\n" +
    "  </defs>\n" +
    "</svg>"
  guard @svg.rasterize(@utf8.encode(src), 120) is Some((w, h, rgba)) else { fail("not drawn") }
  assert_eq((w, h), (120, 40))
  // linear: half-transparent red at the top left, opaque green mid-way, opaque blue at the bottom right
  let (lr0, _, _, la0) = px_rgba(rgba, w, 4, 4)
  assert_true(lr0 > 180 && la0 >= 120 && la0 <= 170, msg="stop-opacity top left \{rgba_said(px_rgba(rgba, w, 4, 4))}")
  let (_, lg1, _, la1) = px_rgba(rgba, w, 14, 20)
  assert_true(lg1 > 200 && la1 == 255, msg="three stops, green mid-way \{rgba_said(px_rgba(rgba, w, 14, 20))}")
  let (_, _, lb2, la2) = px_rgba(rgba, w, 24, 36)
  assert_true(lb2 > 200 && la2 == 255, msg="three stops, blue bottom right \{rgba_said(px_rgba(rgba, w, 24, 36))}")
  // radial: yellow at its centre (42,20), magenta at the rect's corner (53,36)
  let (rr0, rg0, rb0, ra0) = px_rgba(rgba, w, 42, 20)
  assert_true(rr0 > 240 && rg0 > 240 && rb0 < 20 && ra0 == 255, msg="radial centre \{rgba_said(px_rgba(rgba, w, 42, 20))}")
  let (rr1, rg1, rb1, ra1) = px_rgba(rgba, w, 53, 36)
  assert_true(rr1 > 240 && rg1 < 40 && rb1 > 220 && ra1 == 255, msg="radial outside \{rgba_said(px_rgba(rgba, w, 53, 36))}")
  // clipPath and mask from the second <defs>
  assert_eq(px_rgba(rgba, w, 64, 20), (0, 255, 0, 255))
  assert_eq(px_rgba(rgba, w, 76, 20).3, 0)
  assert_eq(px_rgba(rgba, w, 92, 20), (0, 0, 255, 255))
  assert_eq(px_rgba(rgba, w, 104, 20).3, 0)
}
