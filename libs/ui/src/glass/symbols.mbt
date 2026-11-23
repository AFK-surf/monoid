// Reusable vector SF-Symbols-style glyphs for Liquid Glass controls & navigation chrome.
// Built on `@ui.shape_of` so every host (Metal, GLES3, D3D11, WebGL2) renders crisp resolution-independent vectors.

///|
fn sym_circle_pts(cx : Double, cy : Double, r : Double, steps : Int) -> Array[Double] {
  let pts : Array[Double] = []
  let pi2 = 6.283185307179586
  for i in 0..<steps {
    let a = pi2 * i.to_double() / steps.to_double()
    pts.push(cx + r * @dmath.cos(a))
    pts.push(cy + r * @dmath.sin(a))
  }
  pts
}

///|
fn sym_arc_pts(
  cx : Double,
  cy : Double,
  r : Double,
  a0 : Double,
  a1 : Double,
  steps : Int,
) -> Array[Double] {
  let pts : Array[Double] = []
  for i in 0..<=steps {
    let a = a0 + (a1 - a0) * i.to_double() / steps.to_double()
    pts.push(cx + r * @dmath.cos(a))
    pts.push(cy + r * @dmath.sin(a))
  }
  pts
}

///|
fn sym_norm(
  pts : Array[Double],
  cx : Double,
  cy : Double,
  mul : Double,
  scale : Double,
) -> Array[Double] {
  let out : Array[Double] = []
  let mut i = 0
  while i + 1 < pts.length() {
    out.push((12.0 + (pts[i] - cx) * mul) * scale)
    out.push((12.0 + (pts[i + 1] - cy) * mul) * scale)
    i = i + 2
  }
  out
}

///|
fn sym_star4_xy_pts(
  cx : Double,
  cy : Double,
  rx : Double,
  ry : Double,
  r_in : Double,
) -> Array[Double] {
  [
    cx, cy - ry,
    cx + r_in, cy - r_in,
    cx + rx, cy,
    cx + r_in, cy + r_in,
    cx, cy + ry,
    cx - r_in, cy + r_in,
    cx - rx, cy,
    cx - r_in, cy - r_in,
  ]
}

///|
/// Return resolution-independent vector shapes for common iOS 27 / SF Symbols glyphs
/// (`"settings"`, `"sliders"`, `"layers"`, `"sparkles"`, `"moon"`, `"sun"`, `"heart"`, `"eye"`, `"search"`).
pub fn glass_symbol_shapes(name : String, size : Double, ink : Int64) -> Array[@ui.Shape] {
  let k = size / 24.0
  match name {
    "settings" => [
      // True SF Symbols `gearshape.fill`: solid 8-tooth rounded gear with circular center hole (even-odd fill),
      // normalized to fill [1.0, 23.0] (~92% viewBox) around (12, 12).
      @ui.shape_of(
        [
          (
            sym_norm(
              [
                8.681, 5.983, 9.365, 5.654, 9.574, 5.546, 9.7271, 5.4463, 9.8485, 5.3223,
                9.9381, 5.1738, 9.996, 5.001, 10.276, 3.775, 10.3365, 3.6131, 10.434, 3.4975,
                10.5685, 3.4281, 10.74, 3.405, 13.26, 3.405, 13.4315, 3.4281, 13.566, 3.4975,
                13.6635, 3.6131, 13.724, 3.775, 14.004, 5.001, 14.0619, 5.1738, 14.1515, 5.3223,
                14.2729, 5.4463, 14.426, 5.546, 14.635, 5.654, 15.319, 5.983, 15.534, 6.079,
                15.7072, 6.1365, 15.8797, 6.154, 16.0517, 6.1315, 16.223, 6.069, 17.355, 5.524,
                17.5199, 5.4704, 17.6715, 5.4745, 17.8099, 5.5364, 17.935, 5.656, 19.505, 7.626,
                19.5939, 7.7745, 19.6235, 7.923, 19.5939, 8.0715, 19.505, 8.22, 18.722, 9.203,
                18.6229, 9.3562, 18.5628, 9.5188, 18.5414, 9.6907, 18.559, 9.872, 18.604, 10.103,
                18.773, 10.844, 18.832, 11.071, 18.895, 11.2423, 18.989, 11.3883, 19.114, 11.5088,
                19.27, 11.604, 20.402, 12.149, 20.5464, 12.2444, 20.6375, 12.3655, 20.6754, 12.5124,
                20.66, 12.685, 20.099, 15.141, 20.0385, 15.3029, 19.941, 15.4185, 19.8065, 15.4879,
                19.635, 15.511, 18.378, 15.511, 18.1964, 15.5291, 18.0317, 15.5835, 17.8839, 15.6741,
                17.753, 15.801, 17.601, 15.981, 17.127, 16.575, 16.986, 16.763, 16.8915, 16.9187,
                16.836, 17.083, 16.8195, 17.2557, 16.842, 17.437, 17.122, 18.662, 17.1374, 18.8342,
                17.0995, 18.9807, 17.0084, 19.1017, 16.864, 19.197, 14.594, 20.29, 14.4296, 20.3436,
                14.2782, 20.3395, 14.1401, 20.2776, 14.015, 20.158, 13.232, 19.176, 13.1046, 19.045,
                12.9593, 18.95, 12.7961, 18.891, 12.615, 18.868, 12.38, 18.861, 11.62, 18.861,
                11.385, 18.868, 11.2039, 18.891, 11.0408, 18.95, 10.8954, 19.045, 10.768, 19.176,
                9.985, 20.158, 9.8599, 20.2776, 9.7218, 20.3395, 9.5704, 20.3436, 9.406, 20.29,
                7.136, 19.197, 6.9916, 19.1017, 6.9005, 18.9808, 6.8626, 18.8342, 6.878, 18.662,
                7.158, 17.437, 7.1805, 17.2557, 7.164, 17.083, 7.1085, 16.9188, 7.014, 16.763,
                6.873, 16.575, 6.399, 15.981, 6.247, 15.801, 6.1161, 15.6741, 5.9683, 15.5835,
                5.8036, 15.5291, 5.622, 15.511, 4.365, 15.511, 4.1935, 15.4879, 4.059, 15.4185,
                3.9615, 15.3029, 3.901, 15.141, 3.34, 12.685, 3.3246, 12.5124, 3.3625, 12.3655,
                3.4536, 12.2444, 3.598, 12.149, 4.73, 11.604, 4.886, 11.5088, 5.011, 11.3882,
                5.105, 11.2423, 5.168, 11.071, 5.227, 10.844, 5.396, 10.103, 5.441, 9.872,
                5.4586, 9.6907, 5.4372, 9.5187, 5.3771, 9.3562, 5.278, 9.203, 4.495, 8.22,
                4.4061, 8.0715, 4.3765, 7.923, 4.4061, 7.7745, 4.495, 7.626, 6.065, 5.656,
                6.1901, 5.5364, 6.3285, 5.4745, 6.4801, 5.4704, 6.645, 5.524, 7.777, 6.069,
                7.9483, 6.1315, 8.1202, 6.154, 8.2928, 6.1365, 8.466, 6.079,
              ],
              12.0,
              11.8743,
              1.268,
              k,
            ),
            true,
          ),
          (
            sym_norm(
              [
                9.15, 12.0, 9.2079, 12.5744, 9.374, 13.1093, 9.6367, 13.5935, 9.9847, 14.0153,
                10.4065, 14.3633, 10.8907, 14.626, 11.4256, 14.7921, 12.0, 14.85, 12.5744, 14.7921,
                13.1093, 14.626, 13.5935, 14.3633, 14.0153, 14.0153, 14.3633, 13.5935, 14.626, 13.1093,
                14.7921, 12.5744, 14.85, 12.0, 14.7921, 11.4256, 14.626, 10.8907, 14.3633, 10.4065,
                14.0153, 9.9847, 13.5935, 9.6367, 13.1093, 9.374, 12.5744, 9.2079, 12.0, 9.15,
                11.4256, 9.2079, 10.8907, 9.374, 10.4065, 9.6367, 9.9847, 9.9847, 9.6367, 10.4065,
                9.374, 10.8907, 9.2079, 11.4256,
              ],
              12.0,
              11.8743,
              1.268,
              k,
            ),
            true,
          ),
        ],
        fill=ink,
        even_odd=true,
      ),
    ]
    "sliders" => [
      // Bold SF Symbols `slider.horizontal.3` normalized to fill [1.0, 23.0].
      @ui.shape_of(
        [
          ([2.2 * k, 5.4 * k, 21.8 * k, 5.4 * k], false),
          ([2.2 * k, 12.0 * k, 21.8 * k, 12.0 * k], false),
          ([2.2 * k, 18.6 * k, 21.8 * k, 18.6 * k], false),
        ],
        stroke=ink,
        width=2.4 * k,
      ),
      @ui.shape_of(
        [
          (sym_circle_pts(8.4 * k, 5.4 * k, 3.05 * k, 18), true),
          (sym_circle_pts(16.2 * k, 12.0 * k, 3.05 * k, 18), true),
          (sym_circle_pts(10.2 * k, 18.6 * k, 3.05 * k, 18), true),
        ],
        fill=ink,
      ),
    ]
    "layers" => {
      // Bold solid stacked layers normalized to fill [1.0, 23.0] (~92% viewBox).
      let top_d : Array[Double] = [
        12.0 * k, 1.6 * k,
        22.6 * k, 6.9 * k,
        12.0 * k, 12.2 * k,
        1.4 * k, 6.9 * k,
      ]
      [
        @ui.shape_of([(top_d, true)], fill=ink),
        @ui.shape_of(
          [
            ([2.2 * k, 12.0 * k, 12.0 * k, 16.8 * k, 21.8 * k, 12.0 * k], false),
            ([2.2 * k, 16.4 * k, 12.0 * k, 21.2 * k, 21.8 * k, 16.4 * k], false),
          ],
          stroke=ink,
          width=2.4 * k,
        ),
      ]
    }
    "sparkles" => [
      // Plump solid 4-point SF Symbols `sparkles`, slightly tall aspect (~40x48 native proportion) filling [1.2, 22.6].
      @ui.shape_of(
        [
          (sym_star4_xy_pts(9.8 * k, 12.8 * k, 8.4 * k, 9.8 * k, 2.55 * k), true),
          (sym_star4_xy_pts(18.6 * k, 5.4 * k, 3.8 * k, 4.2 * k, 1.2 * k), true),
          (sym_star4_xy_pts(19.4 * k, 17.8 * k, 2.6 * k, 2.8 * k, 0.85 * k), true),
        ],
        fill=ink,
      ),
    ]
    "moon" => {
      // Solid crescent `moon.fill`.
      let outer = sym_arc_pts(12.2 * k, 12.0 * k, 8.0 * k, 0.50, 5.25, 24)
      let inner = sym_arc_pts(15.6 * k, 10.0 * k, 6.5 * k, 4.78, 1.00, 20)
      let poly : Array[Double] = []
      for v in outer {
        poly.push(v)
      }
      for v in inner {
        poly.push(v)
      }
      [@ui.shape_of([(poly, true)], fill=ink)]
    }
    "sun" => {
      // Solid `sun.max.fill`: plump disk + 8 bold short rays.
      let rays : Array[(Array[Double], Bool)] = []
      let pi2 = 6.283185307179586
      for i in 0..<8 {
        let a = pi2 * i.to_double() / 8.0
        let x0 = (12.0 + 7.2 * @dmath.cos(a)) * k
        let y0 = (12.0 + 7.2 * @dmath.sin(a)) * k
        let x1 = (12.0 + 10.2 * @dmath.cos(a)) * k
        let y1 = (12.0 + 10.2 * @dmath.sin(a)) * k
        rays.push(([x0, y0, x1, y1], false))
      }
      [
        @ui.shape_of([(sym_circle_pts(12.0 * k, 12.0 * k, 5.0 * k, 24), true)], fill=ink),
        @ui.shape_of(rays, stroke=ink, width=2.25 * k),
      ]
    }
    "heart" => {
      // Plump solid `heart.fill`.
      let pts : Array[Double] = [
        12.0 * k, 20.0 * k,
        4.8 * k, 13.0 * k,
        3.2 * k, 9.4 * k,
        4.3 * k, 5.8 * k,
        7.5 * k, 4.4 * k,
        10.5 * k, 5.5 * k,
        12.0 * k, 7.5 * k,
        13.5 * k, 5.5 * k,
        16.5 * k, 4.4 * k,
        19.7 * k, 5.8 * k,
        20.8 * k, 9.4 * k,
        19.2 * k, 13.0 * k,
      ]
      [@ui.shape_of([(pts, true)], fill=ink)]
    }
    "eye" => {
      // Crisp `eye` outline + solid iris.
      let top = sym_arc_pts(12.0 * k, 18.0 * k, 12.0 * k, -2.30, -0.84, 18)
      let bot = sym_arc_pts(12.0 * k, 6.0 * k, 12.0 * k, 0.84, 2.30, 18)
      let outline : Array[Double] = []
      for v in top {
        outline.push(v)
      }
      for v in bot {
        outline.push(v)
      }
      [
        @ui.shape_of([(outline, true)], stroke=ink, width=2.0 * k),
        @ui.shape_of([(sym_circle_pts(12.0 * k, 12.0 * k, 3.5 * k, 20), true)], fill=ink),
      ]
    }
    "search" => [
      // Crisp `magnifyingglass`.
      @ui.shape_of(
        [
          (sym_circle_pts(10.5 * k, 10.5 * k, 6.2 * k, 24), true),
          ([15.2 * k, 15.2 * k, 20.4 * k, 20.4 * k], false),
        ],
        stroke=ink,
        width=2.2 * k,
      ),
    ]
    _ => []
  }
}

///|
/// Mount a reusable resolution-independent vector symbol box inside `parent`.
#callsite(autofill(loc))
pub fn glass_symbol_node(
  parent : @view.View,
  name : String,
  size : Double,
  ink : () -> Int64,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(v) {
    v
    .width(Is(Some(size)))
    .height(Is(Some(size)))
    .shapes(By(fn() { glass_symbol_shapes(name, size, ink()) }))
    |> ignore
  })
}
