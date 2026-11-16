// A terminal's screen, kept by the host (src/hostapi/terminal.mbt says what is asked and what comes back). Included by
// each host's C after post.h (its post_string). What a host answers where nothing keeps one: opening one answers 0, so
// the app shows no terminal. An app whose build links a terminal's library (still.fail's libghostty-vt) defines these
// calls itself, in its own C, and its ones take the place of these (weak on clang/gcc; /alternatename defaults on MSVC).
#ifndef MB_TERM_H
#define MB_TERM_H

#if defined(_WIN32)
static inline int32_t mb_host_term_open_default(int32_t cols, int32_t rows) { (void)cols; (void)rows; return 0; }
static inline void mb_host_term_write_default(int32_t id, moonbit_bytes_t data) { (void)id; (void)data; }
static inline void mb_host_term_resize_default(int32_t id, int32_t cols, int32_t rows, int32_t cw, int32_t ch) { (void)id; (void)cols; (void)rows; (void)cw; (void)ch; }
static inline moonbit_bytes_t mb_host_term_frame_default(int32_t id, int32_t flags) { (void)id; (void)flags; return moonbit_make_bytes(0, 0); }
static inline int32_t mb_host_term_modes_default(int32_t id) { (void)id; return 0; }
static inline void mb_host_term_scroll_default(int32_t id, int32_t kind, int32_t value) { (void)id; (void)kind; (void)value; }
static inline int32_t mb_host_term_select_default(int32_t id, int32_t kind, int32_t x0, int32_t y0, int32_t x1, int32_t y1) { (void)id; (void)kind; (void)x0; (void)y0; (void)x1; (void)y1; return 0; }
static inline moonbit_string_t mb_host_term_text_default(int32_t id, int32_t sel) { (void)id; (void)sel; return post_string("", 0); }
static inline moonbit_bytes_t mb_host_term_mouse_default(int32_t id, int32_t action, int32_t button, int32_t mods, int32_t x, int32_t y, int32_t w, int32_t h, int32_t cw, int32_t ch) {
  (void)id; (void)action; (void)button; (void)mods; (void)x; (void)y; (void)w; (void)h; (void)cw; (void)ch;
  return moonbit_make_bytes(0, 0);
}
static inline void mb_host_term_close_default(int32_t id) { (void)id; }
// Non-inline external fallbacks referenced by /alternatename when terminal_ghostty.c is not linked.
int32_t mb_host_term_open_fallback(int32_t cols, int32_t rows) { return mb_host_term_open_default(cols, rows); }
void mb_host_term_write_fallback(int32_t id, moonbit_bytes_t data) { mb_host_term_write_default(id, data); }
void mb_host_term_resize_fallback(int32_t id, int32_t cols, int32_t rows, int32_t cw, int32_t ch) { mb_host_term_resize_default(id, cols, rows, cw, ch); }
moonbit_bytes_t mb_host_term_frame_fallback(int32_t id, int32_t flags) { return mb_host_term_frame_default(id, flags); }
int32_t mb_host_term_modes_fallback(int32_t id) { return mb_host_term_modes_default(id); }
void mb_host_term_scroll_fallback(int32_t id, int32_t kind, int32_t value) { mb_host_term_scroll_default(id, kind, value); }
int32_t mb_host_term_select_fallback(int32_t id, int32_t kind, int32_t x0, int32_t y0, int32_t x1, int32_t y1) { return mb_host_term_select_default(id, kind, x0, y0, x1, y1); }
moonbit_string_t mb_host_term_text_fallback(int32_t id, int32_t sel) { return mb_host_term_text_default(id, sel); }
moonbit_bytes_t mb_host_term_mouse_fallback(int32_t id, int32_t action, int32_t button, int32_t mods, int32_t x, int32_t y, int32_t w, int32_t h, int32_t cw, int32_t ch) {
  return mb_host_term_mouse_default(id, action, button, mods, x, y, w, h, cw, ch);
}
void mb_host_term_close_fallback(int32_t id) { mb_host_term_close_default(id); }
#pragma comment(linker, "/alternatename:mb_host_term_open=mb_host_term_open_fallback")
#pragma comment(linker, "/alternatename:mb_host_term_write=mb_host_term_write_fallback")
#pragma comment(linker, "/alternatename:mb_host_term_resize=mb_host_term_resize_fallback")
#pragma comment(linker, "/alternatename:mb_host_term_frame=mb_host_term_frame_fallback")
#pragma comment(linker, "/alternatename:mb_host_term_modes=mb_host_term_modes_fallback")
#pragma comment(linker, "/alternatename:mb_host_term_scroll=mb_host_term_scroll_fallback")
#pragma comment(linker, "/alternatename:mb_host_term_select=mb_host_term_select_fallback")
#pragma comment(linker, "/alternatename:mb_host_term_text=mb_host_term_text_fallback")
#pragma comment(linker, "/alternatename:mb_host_term_mouse=mb_host_term_mouse_fallback")
#pragma comment(linker, "/alternatename:mb_host_term_close=mb_host_term_close_fallback")
#else
#if defined(__clang__) || defined(__GNUC__)
#define MB_TERM_WEAK __attribute__((weak))
#else
#define MB_TERM_WEAK
#endif

MB_TERM_WEAK int32_t mb_host_term_open(int32_t cols, int32_t rows) { (void)cols; (void)rows; return 0; }
MB_TERM_WEAK void mb_host_term_write(int32_t id, moonbit_bytes_t data) { (void)id; (void)data; }
MB_TERM_WEAK void mb_host_term_resize(int32_t id, int32_t cols, int32_t rows, int32_t cw, int32_t ch) { (void)id; (void)cols; (void)rows; (void)cw; (void)ch; }
MB_TERM_WEAK moonbit_bytes_t mb_host_term_frame(int32_t id, int32_t flags) { (void)id; (void)flags; return moonbit_make_bytes(0, 0); }
MB_TERM_WEAK int32_t mb_host_term_modes(int32_t id) { (void)id; return 0; }
MB_TERM_WEAK void mb_host_term_scroll(int32_t id, int32_t kind, int32_t value) { (void)id; (void)kind; (void)value; }
MB_TERM_WEAK int32_t mb_host_term_select(int32_t id, int32_t kind, int32_t x0, int32_t y0, int32_t x1, int32_t y1) { (void)id; (void)kind; (void)x0; (void)y0; (void)x1; (void)y1; return 0; }
MB_TERM_WEAK moonbit_string_t mb_host_term_text(int32_t id, int32_t sel) { (void)id; (void)sel; return post_string("", 0); }
MB_TERM_WEAK moonbit_bytes_t mb_host_term_mouse(int32_t id, int32_t action, int32_t button, int32_t mods, int32_t x, int32_t y, int32_t w, int32_t h, int32_t cw, int32_t ch) {
  (void)id; (void)action; (void)button; (void)mods; (void)x; (void)y; (void)w; (void)h; (void)cw; (void)ch;
  return moonbit_make_bytes(0, 0);
}
MB_TERM_WEAK void mb_host_term_close(int32_t id) { (void)id; }
#endif

#endif
