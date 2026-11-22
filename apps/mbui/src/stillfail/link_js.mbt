///|
/// Whether the page gives the core (still.fail's web/src/mbui/core.ts: `globalThis.__mbcore`, mbui/core's js.mbt).
extern "js" fn core_linked() -> Int =
  #|() => (globalThis.__mbcore ? 1 : 0)

///|
/// What the web host is told (web/src/mbui/reports.ts: `globalThis.__mbreports`): 0 when none is attached (dev, tests).
extern "js" fn host_tell(what : String, a : String, b : String, n : Int, m : Int) -> Int =
  #|(w, a, b, n, m) => (globalThis.__mbreports ? globalThis.__mbreports.tell(w, a, b, n, m) : 0)
