// core_engine.m's Windows twin, put in its place by mbui's scripts/win.sh for APP=stillfail (moon.pkg cannot pick stubs
// per OS): the core in Hermes on the Rust shell (src/sfcore/win_engine.c).
#include "../sfcore/win_engine.c"
// this machine's station, the app's own native call (src/host/station_calls.h)
#include "../host/win_station.c"
#include "../host/station_calls.h"
// crash/hang/fault telemetry to PostHog (src/host/win_reports.c, after win_core.c for desktop_app_data)
#include "../host/win_reports.c"

extern int sf_terminal_linked;

// main.mbt asks it before it starts the core (core_engine.m has the same on Apple's systems): what keeps this file in the
// link, and, here, where the engine is handed over (and terminal_ghostty.c's object pulled out of the package archive).
int32_t mb_stillfail_core_linked(void) {
  use_hermes_engine();
  sf_app_calls_use();
  return sf_terminal_linked;
}
