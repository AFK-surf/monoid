// A QR code the core made (qr.ts: its dark modules row by row, `1` dark), drawn as the web's QrCode.tsx draws it: on
// white whatever the theme, four modules of quiet zone round it, whole pixels a module. A Feishu bot made by scanning
// (the phone's and the desktop's new connect) shows it.

///|
let qr_quiet : Int = 4

///|
let qr_white : Int64 = 0xFFFFFFFFL

///|
let qr_black : Int64 = 0x000000FFL

///|
/// The same as a node of the window's tree in `parent` (qr_code's): `code` as the core says it now, `size` across, on
/// white whatever the theme, its corner the field's, each dark run of a row one rectangle of one shape drawn over its
/// ground (nothing made again but that shape as the code changes); a screen reader's image named `label`.
#callsite(autofill(loc))
pub fn qr_code_node(parent : @view.View, code : () -> Json?, size : Double, label : () -> String, loc~ : SourceLoc) -> Unit {
  parent.box(made_for=loc, fn(b) {
    style_node(b, fn() { qr_node_box.then(@ui.style(w=Fixed(size), h=Fixed(size))) })
    b
    .ground(Is(qr_white))
    .shapes(By(fn() { qr_shapes(code(), size) }))
    .says(By(fn() { Some(@view.said(Image, label=label())) }))
    |> ignore
  })
  |> ignore
}

///|
/// The dark modules of `code` drawn `size` across (qr_code's runs): one shape, each run of a row a rectangle of it.
fn qr_shapes(code : Json?, size : Double) -> Array[@ui.Shape] {
  let (n0, rows) = match code {
    Some(Object(m)) =>
      (
        match m.get("size") {
          Some(Number(v, ..)) => v.to_int()
          _ => 0
        },
        match m.get("rows") {
          Some(Array(a)) =>
            a.filter_map(fn(r) {
              match r {
                String(s) => Some(s)
                _ => None
              }
            })
          _ => []
        },
      )
    _ => (0, [])
  }
  let n = n0 + qr_quiet * 2
  let cell = (size / n.to_double()).floor()
  let start = (size - cell * n.to_double()) / 2.0 + cell * qr_quiet.to_double()
  let outlines : Array[(Array[Double], Bool)] = []
  for y, row in rows {
    let mut x = 0
    while x < row.length() {
      if row.unsafe_get(x).to_int() != 49 {
        x += 1
        continue
      }
      let mut end = x
      while end + 1 < row.length() && row.unsafe_get(end + 1).to_int() == 49 {
        end += 1
      }
      let x0 = start + x.to_double() * cell
      let y0 = start + y.to_double() * cell
      let x1 = x0 + (end - x + 1).to_double() * cell
      let y1 = y0 + cell
      outlines.push(([x0, y0, x1, y0, x1, y1, x0, y1], true))
      x = end + 1
    }
  }
  if outlines.is_empty() {
    []
  } else {
    [@ui.shape_of(outlines, fill=qr_black)]
  }
}

///|
/// qr_code_node's box: the field's corner (its quiet zone keeps every module clear of it).
// kept across runs: a value (no field of it changes)
let qr_node_box : @ui.Style = @ui.css("radius=Xl")
