// mbui's film (src/film) on a host that has none (Android, Windows, iOS): every C call film_native.mbt declares
// that is film's alone (mbf_*), answered as a host without film answers, so any program that takes mbui's film in
// links on every host and its film says at once that there is none (mbf_supported 0: film.run returns false, saying
// so). Apple's own are src/host/apple_film.m, Linux's src/host/linux_film.c; a call film gains is written in all
// three, in one change (scripts/film_calls.sh holds it). Linked with the host by scripts/android.sh, win.sh and ios.sh.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include "moonbit.h"

static moonbit_string_t none(void) { return moonbit_make_string(0, 0); }

int32_t mbf_supported(void) { return 0; }
void mbf_set_view(double w, double h, double scale) { (void)w; (void)h; (void)scale; }
void mbf_text_scale(double scale) { (void)scale; }
void mbf_dirty(double x, double y, double w, double h) { (void)x; (void)y; (void)w; (void)h; }
int32_t mbf_open(moonbit_string_t path, int32_t w, int32_t h, int32_t fps) {
  (void)path; (void)w; (void)h; (void)fps;
  return 0;
}
int32_t mbf_draw(const double *inst, int32_t count, double r, double g, double b) {
  (void)inst; (void)count; (void)r; (void)g; (void)b;
  return 0;
}
int32_t mbf_put(int32_t k) { (void)k; return 0; }
int32_t mbf_close(int32_t frames) { (void)frames; return 0; }
int32_t mbf_finish(int32_t publish) { (void)publish; return 0; }
void mbf_spin(double ms) { (void)ms; }
moonbit_string_t mbf_arg(moonbit_string_t name) { (void)name; return none(); }
// (what film says, on the standard error where the host has one: its ASCII, the rest as '?')
void mbf_say(moonbit_string_t s) {
  int32_t n = Moonbit_array_length(s);
  for (int32_t i = 0; i < n; i++) fputc(s[i] < 128 ? (int)s[i] : '?', stderr);
  fputc('\n', stderr);
}
moonbit_string_t mbf_read_text(moonbit_string_t path) { (void)path; return none(); }
int32_t mbf_write_text(moonbit_string_t path, moonbit_string_t text) { (void)path; (void)text; return 0; }
int32_t mbf_snapshot(moonbit_string_t path) { (void)path; return 0; }
int32_t mbf_snapshot_transparent(moonbit_string_t path) { (void)path; return 0; }
double mbf_now_ms(void) { return 0.0; }
void mbf_exit(int32_t code) { exit(code); }
