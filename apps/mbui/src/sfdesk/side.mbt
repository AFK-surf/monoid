// A sidebar's top row (still.fail web/src/Sidebar.css.ts brand), the frame's; its rows are the library's (src/sf
// side_rows.mbt).

///|
/// The band's first row (side_top's) as a node in `parent`: `brand()` tall (where the block's move has got: the frame's
/// --brand), the window's buttons' row where they are in the app's top row, which drags the window while the sidebar is
/// open.
fn side_top_node(parent : @view.View, brand : () -> Double) -> Unit {
  parent.box(fn(top) {
    top.height(By(fn() { Some(brand()) })).moves_window(By(fn() { @ui.window_inset_now() && !side_folded() })) |> ignore
  })
  |> ignore
}

///|
/// The band's first row's height (side_top).
pub fn side_top_h() -> Double {
  wide.brand_h
}

///|
let side_top_inset : Double = 44.0

///|
let side_top_web : Double = 8.0

///|
// kept across runs: a value (no field of it changes)
let side_full : @ui.Style = @ui.css("w=Full")
