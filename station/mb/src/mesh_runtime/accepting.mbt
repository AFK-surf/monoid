// A listener's next connection, taken through what fails one try and leaves the listener listening: the machine out of
// descriptors for a while (EMFILE, ENFILE), one connection given up before it was taken (ECONNABORTED). Each listener
// the program keeps for good takes its connections so (the front's streams' socket, the agents' door, the vault's
// sockets): one such failure ending its loop left it unanswered until the process was started again (2026-11-19).

///|
/// Whether a failed `tcp.accept` says its listener is gone (closed here: the shell's `no handle <id>`; never one: `not a
/// listening socket`), rather than one try failed.
pub fn listener_gone(e : Error) -> Bool {
  let said = "\{e}"
  said.contains("no handle") || said.contains("not a listening socket")
}

///|
/// How long a listener waits after a try that failed before taking the next connection.
pub let accept_again_ms : Int = 100

///|
/// The next of a listener's connections (`accept`), a try that failed waited out (`pause`) and taken again while the
/// listener is there; None once it is closed here (`closed`) or the shell has it no more (`listener_gone`).
pub async fn[T] accept_through(
  accept : async () -> T,
  closed? : () -> Bool = () => false,
  pause? : async () -> Unit = async fn() { @effect.sleep(accept_again_ms) }, // timer: a retry after a failure
) -> T? {
  while !closed() {
    let got = try { Ok(accept()) } catch { e => Err(e) }
    match got {
      Ok(c) => return Some(c)
      Err(e) => {
        if closed() || listener_gone(e) {
          return None
        }
        pause()
      }
    }
  }
  None
}
