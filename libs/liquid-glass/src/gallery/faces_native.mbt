// Native/Wasm UI typeface loader: registers `MBUI_LG_FONT` when provided for offscreen or desktop runs.

///|
fn give_ui_face() -> Unit {
  let path = @ui.env("MBUI_LG_FONT")
  if path != "" {
    ignore(@ui.face_add(@hostapi.face_ui, path))
  }
}
