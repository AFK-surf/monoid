// terminal.mbt's calls on a native host (term.h, which each host's C includes).

///|
extern "C" fn tm_open(cols : Int, rows : Int) -> Int = "mb_host_term_open"

///|
#borrow(data)
extern "C" fn tm_write(id : Int, data : Bytes) -> Unit = "mb_host_term_write"

///|
extern "C" fn tm_resize(id : Int, cols : Int, rows : Int, cw : Int, ch : Int) -> Unit = "mb_host_term_resize"

///|
extern "C" fn tm_frame(id : Int, flags : Int) -> Bytes = "mb_host_term_frame"

///|
extern "C" fn tm_modes(id : Int) -> Int = "mb_host_term_modes"

///|
extern "C" fn tm_scroll(id : Int, kind : Int, value : Int) -> Unit = "mb_host_term_scroll"

///|
extern "C" fn tm_select(id : Int, kind : Int, x0 : Int, y0 : Int, x1 : Int, y1 : Int) -> Int = "mb_host_term_select"

///|
extern "C" fn tm_text(id : Int, sel : Int) -> String = "mb_host_term_text"

///|
extern "C" fn tm_mouse(
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
) -> Bytes = "mb_host_term_mouse"

///|
extern "C" fn tm_close(id : Int) -> Unit = "mb_host_term_close"
