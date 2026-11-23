// A session's cold storage off the station's thread (sessions/archive.ts: "None of their bytes are on the station's
// thread or in its heap"): the packing and the unpacking asked of `--builder packed` (sessions/packed-mb.ts), a
// room's measure of `--builder footprint` (sessions/footprint.ts), each a process of its own, as the TypeScript
// station asks them. Done in this program, a worktree's archive held the station's loop for 11.7 s.

///|
/// Active `workspace.pack` subprocess PIDs by workspace directory, killed on cancel.
let packing_pids : Map[String, Int] = Map([])

///|
/// Workspace directories whose cancellation arrived during the async `spawn` window before `packing_pids` was populated.
let cancelled_packs : Set[String] = Set::new()

///|
fn p52_cancel_pack(dir : String) -> Unit {
  match packing_pids.get(dir) {
    Some(pid) => {
      packing_pids.remove(dir)
      ignore(kill(pid, "SIGKILL"))
    }
    None => cancelled_packs.add(dir)
  }
}

///|
/// The storage's files, their packing and measuring asked of processes of their own.
fn p52_cold_files(bus : LiveBus) -> @session_storage.Files {
  @session_storage.Files::new(
    bus.host,
    sep=sep(),
    packed=ask => p52_packed(bus, ask),
    footprint=ask => p52_footprint(bus, ask),
    cancel_packed=dir => p52_cancel_pack(dir),
  )
}

///|
/// One ask of a program on its stdin, its first line of output parsed; the process ended if the wait is called off.
async fn p52_one_ask(
  bus : LiveBus,
  program : String,
  args : Array[String],
  ask : Json,
  track_dir? : String,
) -> Json {
  let proc = spawn(bus.host, program, args, stdin_piped=true, stdout=Piped, stderr=Ignored) catch {
    SysError(why) => {
      if track_dir is Some(dir) {
        cancelled_packs.remove(dir)
      }
      raise @session_storage.failed(why)
    }
  }
  if track_dir is Some(dir) {
    if cancelled_packs.contains(dir) {
      cancelled_packs.remove(dir)
      ignore(kill(proc.pid, "SIGKILL"))
      ignore(proc.finished() catch { _ => (None, None, b"", b"") })
      raise @session_storage.failed("workspace packing aborted")
    }
    packing_pids[dir] = proc.pid
  }
  ignore(proc.write(@utf8.encode(ask.stringify() + "\n")))
  proc.end_input()
  let (_, _, out, _) = proc.finished() catch {
    e => {
      if track_dir is Some(dir) {
        if packing_pids.get(dir) == Some(proc.pid) {
          packing_pids.remove(dir)
        }
        cancelled_packs.remove(dir)
      }
      ignore(kill(proc.pid, "SIGKILL"))
      raise e
    }
  }
  if track_dir is Some(dir) {
    if packing_pids.get(dir) == Some(proc.pid) {
      packing_pids.remove(dir)
    }
    cancelled_packs.remove(dir)
  }
  let text = @utf8.decode_lossy(out)
  let line = match text.find("\n") {
    Some(at) => text.view(end_offset=at).to_string()
    None => text
  }
  @json.parse(line) catch {
    _ => raise @session_storage.failed("the program ended without an answer")
  }
}

///|
/// What `--builder packed` answers an ask (packed-mb.ts `ask`), its `error` raised in the words `@packed.answer`'s
/// refusal says. `workspace.pack` runs backgrounded and tracked for immediate cancellation; interactive restores and
/// reads stay foreground so people never wait on throttled IO.
async fn p52_packed(bus : LiveBus, ask : Json) -> Json {
  let base_args = ["--builder", "packed", "--shell-dir", tmpdir()]
  let is_pack = jtext(ask, "op") == Some("workspace.pack")
  let (program, args) = if is_pack {
    backgrounded(reader_program(bus), base_args)
  } else {
    (reader_program(bus), base_args)
  }
  let track_dir = if is_pack { jtext(ask, "dir") } else { None }
  let said = p52_one_ask(bus, program, args, ask, track_dir?)
  match said {
    Object(m) =>
      match m.get("error") {
        Some(String(e)) => raise @session_storage.failed(e)
        Some(e) if e != Json::null() => raise @session_storage.failed(e.stringify())
        _ => {
          m.remove("id")
          Json::object(m)
        }
      }
    other => other
  }
}

///|
/// What `--builder footprint` answers a measure, as `@footprint.answer` says it: a builder nobody waits on, so it
/// yields the machine, its disk too, to the foreground (mb-reader.ts BACKGROUND_BUILDERS).
async fn p52_footprint(bus : LiveBus, ask : String) -> Json {
  let (program, args) = backgrounded(reader_program(bus), ["--builder", "footprint", "--sep", sep()])
  let parsed = @json.parse(ask) catch { _ => Json::null() }
  p52_one_ask(bus, program, args, parsed) catch {
    e => { "error": Json::string(@session_storage.message_of(e)) }
  }
}
