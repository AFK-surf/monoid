// What reads a runtime's processes (mb-agents.ts `AgentsHost`, `HostedProcess`): the program's `--sessions`, which a
// driver tells what it does to a process (a line written, a turn begun, a signal) and is told what the program read
// of it (`Heard`) and how it ended. The drivers here speak to it through `Procs` and `Proc`: the station's program, or a
// test's that keeps what it is told.

///|
/// What the program read of a process's lines (`Heard`), as the JSON it says it in.
pub(all) struct Heard {
  json : JValue
}

///|
pub fn Heard::events(self : Heard) -> Array[JValue] {
  arr_at(Some(self.json), "events").unwrap_or([])
}

///|
pub fn Heard::turn(self : Heard) -> JValue? {
  get(Some(self.json), "turn")
}

///|
pub fn Heard::to(self : Heard) -> Int {
  num_at(Some(self.json), "to").unwrap_or(0.0).to_int()
}

///|
/// The lines given Node to read, each its text.
pub fn Heard::lines(self : Heard) -> Array[String] {
  arr_at(Some(self.json), "lines").unwrap_or([]).filter_map(l => str_at(Some(l), "text"))
}

///|
pub fn Heard::routed(self : Heard) -> Bool {
  is_true(Some(self.json), "routed")
}

///|
/// What a process's owner made of what the program read (`HostedOptions.heard`'s answer).
pub enum HeardSaid {
  Took(Bool)
  Writing(Later[Unit])
}

///|
/// How a process's lines are read and what its owner is told of them (`HostedOptions`).
pub struct HostedOptions {
  label : String
  /// "claude", "codex", "dsh", "cursor", "acp", "pi"
  kind : String
  flavor : String?
  kept : Bool
  orphans : Bool
  /// what the program read: taken at once (true where a batch of it was taken by its actor in the program), or once
  /// what its session writes of it is written
  heard : (Heard) -> HeardSaid
  attached : () -> Unit
  handed : () -> Unit
  exit : (String, String) -> Later[Unit]
}

///|
/// A process as the program reads it (`HostedProcess`).
pub(all) struct Proc {
  info : RunnerInfo
  write : (String) -> Unit
  /// "begin", "compact", "aborting", "renewed"
  tell : (String) -> Unit
  /// "acpSession", "acpOpened", "acpPrompt", "acpInject", with their fields
  say : (String, JValue) -> Unit
  keep_from : (Int) -> Unit
  freeze : () -> Unit
  /// where it stood as its lines were held (turn, live), none where it was not
  frozen_state : () -> (JValue, JValue)?
  detach : () -> Unit
  kill : (Double) -> Later[Unit]
  released : () -> Later[Unit]
  has_exited : () -> Bool
  handed : () -> Bool
  /// a Codex app-server's thread and its live steps, read for it from now on; its actor in the program taking its events
  /// from the first (routed: one taken up with its router, mb-agents.ts `thread`)
  thread : (String, JValue, Bool) -> Unit
  drop_thread : (String) -> Unit
  /// its actor in the program takes a thread's events (true), or no longer (false); was it said before
  route_thread : (String, Bool, Bool) -> Bool
  route : (Bool) -> Unit
  orphans_off : () -> Unit
}

///|
/// What reads the drivers' processes (`AgentsHost`).
pub(all) struct Procs {
  /// starts a program under a runner of this id (one left by an earlier station ended first)
  start : (String, String, Array[String], Env, String, HostedOptions, JValue) -> Later[Proc]
  /// takes up the process a runner keeps, with its turn and live steps
  adopt : (RunnerInfo, HostedOptions, JValue, JValue) -> Proc
  /// a process's output read again after a crash (`replayOwn`): kind, file, from where, what else it is told
  replay_own : (String, String, Int, JValue) -> Later[JValue]
  /// a Codex app-server's notifications read again: fed in runs, their live steps by thread at the end
  replay : (Array[Array[JValue]]) -> Later[JValue]
  freeze : (Array[Proc]) -> Later[Unit]
  thaw : (Array[Proc]) -> Unit
  /// let go by a driver for good
  close : () -> Later[Unit]
}

///|
/// A random UUID (v4), as the runtimes take for ids (`uuid`): the station's, or a test's in turn.
pub(all) struct Ids {
  next : () -> String
}
