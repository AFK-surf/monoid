// A terminal's screen, kept by the host (src/hostapi/terminal.mbt says what is asked and what comes back). Included by
// each host's C after post.h (its post_string). What a host answers where nothing keeps one: opening one answers 0, so
// the app shows no terminal. An app whose build links a terminal's library (still.fail's libghostty-vt) defines these
// calls itself, in its own C, and its ones take the place of these (weak where the compiler has them: clang's, gcc's).
#ifndef MB_TERM_H
#define MB_TERM_H

#if defined(__clang__) || defined(__GNUC__)
#define MB_TERM_WEAK __attribute__((weak))
#else
#define MB_TERM_WEAK
#endif

MB_TERM_WEAK int32_t mb_host_term_open(int32_t cols, int32_t rows) { (void)cols; (void)rows; return 0; }
MB_TERM_WEAK void mb_host_term_write(int32_t id, moonbit_bytes_t data) { (void)id; (void)data; }
MB_TERM_WEAK void mb_host_term_resize(int32_t id, int32_t cols, int32_t rows) { (void)id; (void)cols; (void)rows; }
MB_TERM_WEAK moonbit_string_t mb_host_term_lines(int32_t id) { (void)id; return post_string("", 0); }
MB_TERM_WEAK void mb_host_term_close(int32_t id) { (void)id; }

#endif
