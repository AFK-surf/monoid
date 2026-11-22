// A session's cold storage off the station's thread (sessions/archive.ts: "None of their bytes are on the station's
// thread or in its heap"): the packing and the unpacking asked of `--builder packed` (sessions/packed-mb.ts), a
// room's measure of `--builder footprint` (sessions/footprint.ts), each a process of its own, as the TypeScript
// station asks them. Done in this program, a worktree's archive held the station's loop for 11.7 s.

///|
/// The storage's files, their packing and measuring asked of processes of their own.
fn p52_cold_files(bus : LiveBus) -> @session_storage.Files {
  @session_storage.Files::new(
    bus.host,
    sep=sep(),
    packed=ask => p52_packed(bus, ask),
    footprint=ask => p52_footprint(bus, ask),
  )
}

///|
/// One ask of a program on its stdin, its first line of output parsed; the process ended if the wait is called off.
async fn p52_one_ask(bus : LiveBus, program : String, args : Array[String], ask : Json) -> Json {
  let proc = spawn(bus.host, program, args, stdin_piped=true, stdout=Piped, stderr=Ignored) catch {
    SysError(why) => raise @session_storage.failed(why)
  }
  ignore(proc.write(@utf8.encode(ask.stringify() + "\n")))
  proc.end_input()
  let (_, _, out, _) = proc.finished() catch {
    e => {
      ignore(kill(proc.pid, "SIGKILL"))
      raise e
    }
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
/// refusal says. A person may wait on a restore, so it is not backgrounded (mb-reader.ts BACKGROUND_BUILDERS has no
/// `packed`).
async fn p52_packed(bus : LiveBus, ask : Json) -> Json {
  let said = p52_one_ask(
    bus,
    reader_program(bus),
    ["--builder", "packed", "--shell-dir", tmpdir()],
    ask,
  )
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
