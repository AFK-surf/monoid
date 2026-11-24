///|
/// The formulas' outlines, gzipped (math_glyphs.mbt on the native hosts), as the page fetched them after the app started
/// (font_assets_js.mbt): empty until they came, a formula drawn in words until then, and read again as it is drawn.
fn math_glyphs() -> Bytes {
  carried("math_glyphs.gz")
}

///|
/// Releases the compressed `math_glyphs.gz` entry from `globalThis.__mbassets` once unzipped into `math_outlines`.
extern "js" fn math_glyphs_drop() -> Unit =
  #|() => { const a = globalThis.__mbassets; if (a) delete a["math_glyphs.gz"]; }
