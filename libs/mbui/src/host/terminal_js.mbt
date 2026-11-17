// terminal.mbt's calls in a browser, backed by ghostty-vt.wasm in web/host.js when carried beside host.js.

///|
extern "js" fn tm_open(cols : Int, rows : Int) -> Int =
  #|(cols, rows) => __mbhost.termOpen(cols, rows)

///|
extern "js" fn tm_write(id : Int, data : Bytes) -> Unit =
  #|(id, data) => __mbhost.termWrite(id, data)

///|
extern "js" fn tm_resize(id : Int, cols : Int, rows : Int, cw : Int, ch : Int) -> Unit =
  #|(id, cols, rows, cw, ch) => __mbhost.termResize(id, cols, rows, cw, ch)

///|
extern "js" fn tm_frame(id : Int, flags : Int) -> Bytes =
  #|(id, flags) => __mbhost.termFrame(id, flags)

///|
extern "js" fn tm_modes(id : Int) -> Int =
  #|(id) => __mbhost.termModes(id)

///|
extern "js" fn tm_scroll(id : Int, kind : Int, value : Int) -> Unit =
  #|(id, kind, value) => __mbhost.termScroll(id, kind, value)

///|
extern "js" fn tm_select(id : Int, kind : Int, x0 : Int, y0 : Int, x1 : Int, y1 : Int) -> Int =
  #|(id, kind, x0, y0, x1, y1) => __mbhost.termSelect(id, kind, x0, y0, x1, y1)

///|
extern "js" fn tm_text(id : Int, sel : Int) -> String =
  #|(id, sel) => __mbhost.termText(id, sel)

///|
extern "js" fn tm_mouse(
  id : Int,
  action : Int,
  button : Int,
  mods : Int,
  x : Int,
  y : Int,
  w : Int,
  h : Int,
  cw : Int,
  ch : Int,
) -> Bytes =
  #|(id, action, button, mods, x, y, w, h, cw, ch) => __mbhost.termMouse(id, action, button, mods, x, y, w, h, cw, ch)

///|
extern "js" fn tm_close(id : Int) -> Unit =
  #|(id) => __mbhost.termClose(id)
