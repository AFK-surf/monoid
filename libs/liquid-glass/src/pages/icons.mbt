// Crisp geometric vector icons for ui.monoid Liquid Glass Studio, built solely on `@paint.shape_of`, `@paint.arc`,
// and `@view.View::shapes` in a 24×24 logical coordinate system scaled by `size / 24.0`.

///|
let icon_pi : Double = 3.141592653589793

///|
let monoid_vermilion : Int64 = 0xEF6334FFL

///|
/// Flatten `(x, y)` points scaled by `k` into `[x0, y0, x1, y1, …]`.
fn flat_scaled(pts : Array[(Double, Double)], k : Double) -> Array[Double] {
  let out : Array[Double] = []
  for p in pts {
    out.push(p.0 * k)
    out.push(p.1 * k)
  }
  out
}

///|
/// Closed rounded rectangle outline in the 24×24 icon grid, scaled by `k`.
fn rrect_outline(x : Double, y : Double, w : Double, h : Double, r : Double, k : Double) -> (Array[Double], Bool) {
  let out : Array[Double] = []
  let push_arc = fn(cx : Double, cy : Double, from : Double, sweep : Double) {
    for p in @paint.arc(cx * k, cy * k, r * k, from~, sweep~) {
      out.push(p.0)
      out.push(p.1)
    }
  }
  push_arc(x + w - r, y + r, -icon_pi / 2.0, icon_pi / 2.0)
  push_arc(x + w - r, y + h - r, 0.0, icon_pi / 2.0)
  push_arc(x + r, y + h - r, icon_pi / 2.0, icon_pi / 2.0)
  push_arc(x + r, y + r, icon_pi, icon_pi / 2.0)
  (out, true)
}

///|
/// Closed circle outline in the 24×24 icon grid, scaled by `k`.
fn circle_outline(cx : Double, cy : Double, r : Double, k : Double) -> (Array[Double], Bool) {
  let out : Array[Double] = []
  for p in @paint.arc(cx * k, cy * k, r * k, from=0.0, sweep=2.0 * icon_pi) {
    out.push(p.0)
    out.push(p.1)
  }
  (out, true)
}

///|
/// Fixed `size × size` box drawing reactive vector `shapes`.
fn icon_box(parent : @view.View, size : Double, shapes : () -> Array[@paint.Shape]) -> Unit {
  parent.box(fn(b) {
    b.width(Is(Some(size))).height(Is(Some(size))).shrink(Is(0.0)).shapes(By(shapes)) |> ignore
  })
  |> ignore
}

///|
/// Monoid 2×2 rounded four-tile brand mark (top-right tile highlighted in Monoid Vermilion `#EF6334`).
fn icon_brand_mark(parent : @view.View, size : Double, ink : () -> Int64) -> Unit {
  let k = size / 24.0
  icon_box(parent, size, fn() {
    let c = ink()
    [
      @paint.shape_of(
        [
          rrect_outline(3.0, 3.0, 8.0, 8.0, 2.2, k),
          rrect_outline(3.0, 13.0, 8.0, 8.0, 2.2, k),
          rrect_outline(13.0, 13.0, 8.0, 8.0, 2.2, k),
        ],
        fill=c,
      ),
      @paint.shape_of([rrect_outline(13.0, 3.0, 8.0, 8.0, 2.2, k)], fill=monoid_vermilion),
    ]
  })
}

///|
/// Diamond prism / optical lens icon (Optics).
fn icon_prism(parent : @view.View, size : Double, ink : () -> Int64) -> Unit {
  let k = size / 24.0
  icon_box(parent, size, fn() {
    let c = ink()
    [
      @paint.shape_of(
        [
          (flat_scaled([(12.0, 2.8), (21.2, 12.0), (12.0, 21.2), (2.8, 12.0)], k), true),
          (flat_scaled([(5.2, 12.0), (18.8, 12.0)], k), false),
        ],
        stroke=c,
        width=1.8 * k,
      ),
      @paint.shape_of([circle_outline(12.0, 12.0, 2.2, k)], fill=c),
    ]
  })
}

///|
/// Three horizontal adjustment sliders icon (Inspect).
fn icon_sliders(parent : @view.View, size : Double, ink : () -> Int64) -> Unit {
  let k = size / 24.0
  icon_box(parent, size, fn() {
    let c = ink()
    [
      @paint.shape_of(
        [
          (flat_scaled([(3.5, 6.0), (7.0, 6.0)], k), false),
          (flat_scaled([(11.4, 6.0), (20.5, 6.0)], k), false),
          circle_outline(9.2, 6.0, 2.2, k),
          (flat_scaled([(3.5, 12.0), (13.4, 12.0)], k), false),
          (flat_scaled([(17.8, 12.0), (20.5, 12.0)], k), false),
          circle_outline(15.6, 12.0, 2.2, k),
          (flat_scaled([(3.5, 18.0), (8.2, 18.0)], k), false),
          (flat_scaled([(12.6, 18.0), (20.5, 18.0)], k), false),
          circle_outline(10.4, 18.0, 2.2, k),
        ],
        stroke=c,
        width=1.8 * k,
      ),
    ]
  })
}

///|
/// Stacked twin diamonds icon (Layers).
fn icon_layers(parent : @view.View, size : Double, ink : () -> Int64) -> Unit {
  let k = size / 24.0
  icon_box(parent, size, fn() {
    let c = ink()
    [
      @paint.shape_of(
        [
          (flat_scaled([(12.0, 3.5), (20.5, 8.5), (12.0, 13.5), (3.5, 8.5)], k), true),
          (flat_scaled([(3.5, 13.0), (12.0, 18.0), (20.5, 13.0)], k), false),
          (flat_scaled([(3.5, 17.0), (12.0, 21.5), (20.5, 17.0)], k), false),
        ],
        stroke=c,
        width=1.8 * k,
      ),
    ]
  })
}

///|
/// Four-point star / spark icon (Motion).
fn icon_spark(parent : @view.View, size : Double, ink : () -> Int64) -> Unit {
  let k = size / 24.0
  icon_box(parent, size, fn() {
    let c = ink()
    [
      @paint.shape_of(
        [
          (
            flat_scaled(
              [
                (12.0, 2.6),
                (14.3, 9.7),
                (21.4, 12.0),
                (14.3, 14.3),
                (12.0, 21.4),
                (9.7, 14.3),
                (2.6, 12.0),
                (9.7, 9.7),
              ],
              k,
            ),
            true,
          ),
        ],
        stroke=c,
        width=1.8 * k,
      ),
    ]
  })
}

///|
/// Terminal / code prompt `>_` icon (Tokens).
fn icon_terminal(parent : @view.View, size : Double, ink : () -> Int64) -> Unit {
  let k = size / 24.0
  icon_box(parent, size, fn() {
    let c = ink()
    [
      @paint.shape_of(
        [
          (flat_scaled([(4.5, 7.0), (10.5, 12.0), (4.5, 17.0)], k), false),
          (flat_scaled([(12.5, 17.0), (19.5, 17.0)], k), false),
        ],
        stroke=c,
        width=1.9 * k,
      ),
    ]
  })
}

///|
/// Crescent moon icon (Dark Studio toggle).
fn icon_moon(parent : @view.View, size : Double, ink : () -> Int64) -> Unit {
  let k = size / 24.0
  icon_box(parent, size, fn() {
    let c = ink()
    let pts : Array[Double] = []
    for p in @paint.arc(12.0 * k, 12.0 * k, 7.5 * k, from=0.10 * icon_pi, sweep=1.30 * icon_pi) {
      pts.push(p.0)
      pts.push(p.1)
    }
    for p in @paint.arc(16.2 * k, 7.8 * k, 7.15 * k, from=1.134 * icon_pi, sweep=-0.769 * icon_pi) {
      pts.push(p.0)
      pts.push(p.1)
    }
    [@paint.shape_of([(pts, true)], stroke=c, width=1.8 * k)]
  })
}

///|
/// Sun icon (Light Studio toggle).
fn icon_sun(parent : @view.View, size : Double, ink : () -> Int64) -> Unit {
  let k = size / 24.0
  icon_box(parent, size, fn() {
    let c = ink()
    let d = 0.70710678
    let r1 = 7.0
    let r2 = 9.5
    [
      @paint.shape_of(
        [
          circle_outline(12.0, 12.0, 4.2, k),
          (flat_scaled([(12.0, 12.0 - r1), (12.0, 12.0 - r2)], k), false),
          (flat_scaled([(12.0, 12.0 + r1), (12.0, 12.0 + r2)], k), false),
          (flat_scaled([(12.0 - r1, 12.0), (12.0 - r2, 12.0)], k), false),
          (flat_scaled([(12.0 + r1, 12.0), (12.0 + r2, 12.0)], k), false),
          (flat_scaled([(12.0 - r1 * d, 12.0 - r1 * d), (12.0 - r2 * d, 12.0 - r2 * d)], k), false),
          (flat_scaled([(12.0 + r1 * d, 12.0 - r1 * d), (12.0 + r2 * d, 12.0 - r2 * d)], k), false),
          (flat_scaled([(12.0 - r1 * d, 12.0 + r1 * d), (12.0 - r2 * d, 12.0 + r2 * d)], k), false),
          (flat_scaled([(12.0 + r1 * d, 12.0 + r1 * d), (12.0 + r2 * d, 12.0 + r2 * d)], k), false),
        ],
        stroke=c,
        width=1.8 * k,
      ),
    ]
  })
}

///|
/// Precision optical grid `#` icon.
fn icon_grid(parent : @view.View, size : Double, ink : () -> Int64) -> Unit {
  let k = size / 24.0
  icon_box(parent, size, fn() {
    let c = ink()
    [
      @paint.shape_of(
        [
          (flat_scaled([(8.5, 4.0), (8.5, 20.0)], k), false),
          (flat_scaled([(15.5, 4.0), (15.5, 20.0)], k), false),
          (flat_scaled([(4.0, 8.5), (20.0, 8.5)], k), false),
          (flat_scaled([(4.0, 15.5), (20.0, 15.5)], k), false),
        ],
        stroke=c,
        width=1.8 * k,
      ),
    ]
  })
}

///|
/// Lightning bolt icon (GPU / Signal boost).
fn icon_bolt(parent : @view.View, size : Double, ink : () -> Int64) -> Unit {
  let k = size / 24.0
  icon_box(parent, size, fn() {
    let c = ink()
    [
      @paint.shape_of(
        [(flat_scaled([(13.4, 2.5), (5.5, 13.0), (11.6, 13.0), (10.6, 21.5), (18.5, 11.0), (12.4, 11.0)], k), true)],
        fill=c,
      ),
    ]
  })
}

///|
/// Solid play triangle icon.
fn icon_play(parent : @view.View, size : Double, ink : () -> Int64) -> Unit {
  let k = size / 24.0
  icon_box(parent, size, fn() {
    let c = ink()
    [@paint.shape_of([(flat_scaled([(7.5, 5.0), (19.0, 12.0), (7.5, 19.0)], k), true)], fill=c)]
  })
}

///|
/// Circular reset arrow icon.
fn icon_refresh(parent : @view.View, size : Double, ink : () -> Int64) -> Unit {
  let k = size / 24.0
  icon_box(parent, size, fn() {
    let c = ink()
    let arc_pts : Array[Double] = []
    for p in @paint.arc(12.0 * k, 12.0 * k, 7.2 * k, from=0.15 * icon_pi, sweep=1.55 * icon_pi) {
      arc_pts.push(p.0)
      arc_pts.push(p.1)
    }
    [
      @paint.shape_of(
        [
          (arc_pts, false),
          (flat_scaled([(12.2, 6.6), (16.5, 6.2), (16.0, 2.1)], k), false),
        ],
        stroke=c,
        width=1.8 * k,
      ),
    ]
  })
}

///|
/// Bottom tab face for `LiquidBottomTabs`: 22pt vector icon, 4pt gap, 12pt medium label.
fn studio_tab_face(name : String, icon : (@view.View, Double, () -> Int64) -> Unit) -> (@view.View, () -> Int64) -> Unit {
  fn(f, ink) {
    f.box(fn(col) {
      col.lines_up(Is(Some(Middle))).gap(Is(4.0)) |> ignore
      icon(col, 22.0, ink)
      col.box(fn(w) {
        w.words(Is(name), look=@lg.words_at(@lg.type_tab, weight=@lg.weight_medium)).ink(By(ink)) |> ignore
      })
      |> ignore
    })
    |> ignore
  }
}
