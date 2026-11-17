// The agents' memory on a station (settings/Memory.kt; the core's `memory` topic: read each time one of its pages shows
// it, what was read last shown meanwhile, the app opened again too): the global memory by its parts, each project's
// memory (a skill whose description says when it applies), the station's other skills (the built-in ones folded), each
// opening a page of its own to read, Markdown; the memory of every station a row each from settings (MemoriesScreen).
// What 记忆's pages read of it (src/sfpages memory.mbt, memory_doc.mbt, one page each in every frame).

///|
/// A station's memory as the core holds it, and why it could not be read while it holds none.
pub(all) struct MemoryRead {
  value : Json?
  error : String
}

///|
/// A station's memory (the `memory` topic).
pub fn memory_of(core : Core, address : String) -> MemoryRead {
  let topic = (core.topic)("memory", { "station": str(address) }).get()
  {
    value: topic.value,
    error: match topic.error {
      Some(e) => error_text(e)
      None => ""
    },
  }
}

///|
/// The global memory's parts: by its headings, as the core reads them.
pub fn sections_of(m : Json?) -> Array[(String, String, String)] {
  items(field(m, "global"), "sections").map(fn(x) { (text(Some(x), "title"), text(Some(x), "text"), text(Some(x), "note")) })
}

///|
/// Whether the built-in skills are folded open, by station: kept as one goes back and comes in again, the same for
/// every page that shows that station's memory (builtin_open_of, builtin_turn).
// kept across runs: put back as a run begins (on_reset)
pub let builtin_open : Map[String, Bool] = Map([])

///|
fn init {
  // (a run begins with every station's folded)
  @ui.on_reset(fn() { builtin_open.clear() })
}

///|
/// How many times builtin_open was turned: what reads it by builtin_open_of follows it.
// kept across runs: it goes on counting
let builtin_turned : @signals.Signal[Int] = @signals.signal(0)

///|
/// Whether station `address`'s built-in skills are folded open, followed.
pub fn builtin_open_of(address : String) -> Bool {
  builtin_turned.get() |> ignore
  builtin_open.get(address).unwrap_or(false)
}

///|
/// Station `address`'s built-in skills folded open, or shut where they were open: told what follows them.
pub fn builtin_turn(address : String) -> Unit {
  builtin_open[address] = !builtin_open.get(address).unwrap_or(false)
  builtin_turned.set(builtin_turned.untracked() + 1)
}
