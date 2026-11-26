// CSS Color 4's oklab() and oklch(), read and drawn.

///|
fn color_of(text : String) -> SColor raise Failure {
  guard parse_color_str(text) is Some(c) else { fail("not a colour: \{text}") }
  c
}

///|
fn rgba_of(c : SColor) -> (Int, Int, Int, Int) {
  (c.red, c.green, c.blue, c.alpha)
}

///|
fn rgba_said(p : (Int, Int, Int, Int)) -> String {
  let (r, g, b, a) = p
  "\{r},\{g},\{b},\{a}"
}

///|
test "oklab(): white, black, percentages, sRGB red and none" {
  assert_eq(rgba_of(color_of("oklab(1 0 0)")), (255, 255, 255, 255))
  assert_eq(rgba_of(color_of("oklab(0 0 0)")), (0, 0, 0, 255))
  // L as a percentage of 1, a/b as a percentage of 0.4, alpha as a percentage
  let gray = color_of("oklab(50% 0% 0% / 50%)")
  assert_true(
    gray.red == gray.green && gray.green == gray.blue && gray.red >= 97 && gray.red <= 101 && gray.alpha == 128,
    msg="50% gray \{rgba_said(rgba_of(gray))}",
  )
  // sRGB #ff0000 is about oklab(0.627955 0.224863 0.125846)
  let red = color_of("oklab(0.627955 0.224863 0.125846)")
  assert_true(red.red >= 253 && red.green <= 2 && red.blue <= 2 && red.alpha == 255, msg="red \{rgba_said(rgba_of(red))}")
  assert_eq(rgba_of(color_of("oklab(none none none / none)")), (0, 0, 0, 0))
  assert_eq(rgba_of(color_of("OKLAB(NONE 0 0)")), (0, 0, 0, 255))
}

///|
test "oklch(): Tailwind's purple-500, hue units, alpha and none" {
  // Tailwind v4 purple-500 oklch(0.627 0.265 303.9) is about #ad46ff (173, 70, 255), outside sRGB and clamped
  let purple = color_of("oklch(0.627 0.265 303.9)")
  assert_true(
    purple.red >= 170 && purple.red <= 176 && purple.green >= 67 && purple.green <= 73 && purple.blue >= 252 && purple.alpha == 255,
    msg="purple \{rgba_said(rgba_of(purple))}",
  )
  // 50% chroma is 0.2; deg, rad, grad and turn name the same hue
  let deg = color_of("oklch(70% 50% 180deg)")
  assert_eq(color_of("oklch(0.7 0.2 3.141592653589793rad)"), deg)
  assert_eq(color_of("oklch(0.7 0.2 200grad)"), deg)
  assert_eq(color_of("oklch(0.7 0.2 0.5turn)"), deg)
  assert_eq(color_of("oklch(0.7 0.2 180)"), deg)
  assert_eq(color_of("oklch(0.7 0.2 120 / 0.25)").alpha, 64)
  assert_eq(rgba_of(color_of("oklch(100% none none / 100%)")), (255, 255, 255, 255))
  // a negative chroma is zero: gray whatever the hue
  assert_eq(color_of("oklch(0.5 -0.1 40)"), color_of("oklab(0.5 0 0)"))
}

///|
test "oklab() and oklch() that do not read" {
  assert_true(parse_color_str("oklch(0.5 0.1)") is None)
  assert_true(parse_color_str("oklab(0.5 0.1 0.1 /)") is None)
  assert_true(parse_color_str("oklab(0.5 0.1 0.1") is None)
  assert_true(parse_color_str("oklab 0.5 0.1 0.1)") is None)
  assert_true(parse_color_str("oklch(0.5 0.1 nonedeg)") is None)
  // too large to be finite
  assert_true(parse_color_str("oklab(1e999 0 0)") is None)
  assert_true(parse_color_str("oklch(0.5 0.1 1e400)") is None)
}

///|
test "fill and stop-color in oklch() and oklab() drawn" {
  let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"60\" height=\"20\">" +
    "<rect x=\"0\" y=\"0\" width=\"30\" height=\"20\" fill=\"oklch(0.627 0.265 303.9)\"/>" +
    "<rect x=\"30\" y=\"0\" width=\"30\" height=\"20\" fill=\"url(#okg)\"/>" +
    "<defs><linearGradient id=\"okg\" x1=\"30\" y1=\"0\" x2=\"60\" y2=\"0\" gradientUnits=\"userSpaceOnUse\">" +
    "<stop stop-color=\"oklch(0.627955 0.257683 29.2339)\"/>" +
    "<stop offset=\"1\" stop-color=\"oklab(0.452014 -0.032457 -0.311528)\"/>" +
    "</linearGradient></defs></svg>"
  guard rasterize(@utf8.encode(svg), 60) is Some((w, h, rgba)) else { fail("not drawn") }
  assert_eq((w, h), (60, 20))
  let at = fn(x : Int, y : Int) {
    let i = (y * w + x) * 4
    (rgba[i].to_int(), rgba[i + 1].to_int(), rgba[i + 2].to_int(), rgba[i + 3].to_int())
  }
  let purple = color_of("oklch(0.627 0.265 303.9)")
  assert_eq(at(15, 10), (purple.red, purple.green, purple.blue, 255))
  // the gradient from sRGB red to sRGB blue
  let (r0, g0, b0, a0) = at(31, 10)
  assert_true(r0 > 220 && g0 < 30 && b0 < 30 && a0 == 255, msg="start \{rgba_said(at(31, 10))}")
  let (r1, g1, b1, a1) = at(59, 10)
  assert_true(r1 < 30 && g1 < 30 && b1 > 220 && a1 == 255, msg="end \{rgba_said(at(59, 10))}")
}
