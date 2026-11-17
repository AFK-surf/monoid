// core_engine.m's Linux twin, put in its place by mbui's scripts/linux.sh for APP=stillfail (moon.pkg cannot pick stubs
// per OS): the core in Hermes on the Rust shell (src/sfcore/linux_engine.c).
#include "../sfcore/linux_engine.c"
// this machine's station, the app's own native call (src/host/station_calls.h)
#include "../host/linux_station.c"
#include "../host/station_calls.h"

extern int sf_terminal_linked;

// main.mbt asks it before it starts the core (core_engine.m has the same on Apple's systems): what keeps this file in the
// link, and terminal_ghostty.c's object pulled out of the package archive.
int32_t mb_stillfail_core_linked(void) { return sf_terminal_linked; }

// What still.fail's own host is told (reports.mbt: crash reports, the bar's timing): only Android's takes it
// (src/host/android_reports.c); 0 says so.
int32_t mb_stillfail_tell(const void *what, const void *a, const void *b, int32_t n, int32_t m) {
  (void)what, (void)a, (void)b, (void)n, (void)m;
  return 0;
}
