// Browser-side UI typeface loader: reads `inter.woff2` prefetched by `index.html` into `globalThis.__mbassets`.

///|
extern "js" fn carried(name : String) -> Bytes =
  #|(n) => { const a = globalThis.__mbassets; return (a && a[n]) || new Uint8Array(0) }

///|
fn give_ui_face() -> Unit {
  let b = carried("inter.woff2")
  if b.length() > 0 {
    ignore(@ui.face_add_bytes(@hostapi.face_ui, b))
  }
}
