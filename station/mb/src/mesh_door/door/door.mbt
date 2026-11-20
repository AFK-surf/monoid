// The door of a mesh protocol whose connections are let in by their first line (station/src/mesh/door.ts). The first
// bidirectional stream is the control stream, one JSON line each way at a time: the hello and its answer, then any
// later line (a renewal) and its answer. Every other stream is one request (wire.mbt `request`), served only once the
// hello was let in. Who is let in, what the lines say and what a request is answered are given to it (`Admit`): it
// knows nothing of any program's credentials, locks or routes.

///|
/// How long after a refusal the door closes the connection: the refusal's line is to reach the other end first.
pub let refused_close_ms : Int = 200

///|
/// A hello refused: the line it is answered, the code and reason the door closes the connection with
/// `refused_close_ms` after it was refused, and what serving the connection fails with once it is closed.
pub(all) struct Refusal {
  line : Json
  code : Int
  reason : String
  error : Error
}

///|
/// Raised by `renew` where the renewal's refusal ends the connection: its message, the code and reason the door closes
/// the connection with `refused_close_ms` after, and the line it is answered (`{error}` where none is given).
pub(all) suberror Ending {
  Ending(String, Int, String, Json)
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for Ending with output(self, logger) {
  match self {
    Ending(m, _, _, _) => logger.write_string(m)
  }
}

///|
pub fn ending(message : String, code : Int, reason : String, line? : Json) -> Error {
  Ending(message, code, reason, line.unwrap_or({ "error": Json::string(message) }))
}

///|
/// What answers one request stream.
pub type Answering = async (Asked) -> Unit

///|
/// A connection let in (door.ts `In`).
pub(all) struct In {
  /// The line its hello is answered.
  line : Json
  /// Called once that line is written, before anything more is read of the connection.
  opened : () -> Unit
  /// A later line on the control stream: the line it is answered. What it raises is answered `{error}`, its message,
  /// and closes nothing; but an `Ending`, which is answered its line and ends the connection.
  renew : async (Json) -> Json
  /// Called as each request stream is accepted: what answers it; None where the connection is let in no longer.
  stream : () -> Answering?
  /// Called once no more streams are taken.
  ended : () -> Unit
}

///|
pub(all) enum Said {
  Let(In)
  Refused(Refusal)
}

///|
/// Who is let in: asked once, of the control stream's first line.
pub type Admit = async (Json, Connection) -> Said

///|
pub(all) suberror DoorError {
  DoorError(String)
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for DoorError with output(self, logger) {
  match self {
    DoorError(m) => logger.write_string(m)
  }
}

///|
/// What the packages over this one say of their own errors (each adds its words as it starts).
let words_of_others : Array[(Error) -> String?] = []

///|
pub fn add_words(f : (Error) -> String?) -> Unit {
  words_of_others.push(f)
}

///|
/// What an error says (an `Error`'s own words, as TS's `message`).
pub fn message_of(e : Error) -> String {
  for f in words_of_others {
    if f(e) is Some(w) {
      return w
    }
  }
  match e {
    WireError(m) => m
    DoorError(m) => m
    Ending(m, _, _, _) => m
    Failure(m) => m
    e => e.to_string()
  }
}

///|
/// One connection: its hello first, nothing served before it is let in; then a request a stream.
pub async fn door(conn : Connection, admit : Admit) -> Unit {
  let rt = @effect.runtime()
  guard (conn.accept_bi)() is Some(first) else { return }
  let control = Reader::new(first)
  guard control.line() is Some(hello) else {
    (first.reset)(0) catch {
      _ => ()
    }
    raise DoorError("no credential")
  }
  let said = admit(hello, conn)
  let in_ = match said {
    Refused(r) => {
      // Its close is set as it is refused, and its line not waited for.
      let off = after(rt, refused_close_ms, () => (conn.close)(r.code, r.reason))
      ignore(
        rt.fork_quiet(name="door refusal", () => {
          write_line(first, r.line)
          (first.finish)()
        } catch { _ => () }),
      )
      // Kept until it is closed, by whichever closes it first.
      ignore((conn.closed)()) catch {
        _ => ()
      }
      off()
      raise r.error
    }
    Let(in_) => in_
  }
  write_line(first, in_.line)
  (in_.opened)()
  // Later lines on the control stream, until one ends the connection.
  let ending : Ref[Error?] = Ref(None)
  ignore(
    rt.fork_daemon("door control", on_error=e => log("info", "mesh", "control stream ended", { "error": Json::string(message_of(e)) }), () => {
      while (try { control.line() } catch { _ => None }) is Some(line) {
        let reply = try {
          (in_.renew)(line)
        } catch {
          Ending(_, code, reason, l) as e => {
            ending.val = Some(e)
            ignore(after(rt, refused_close_ms, () => (conn.close)(code, reason)))
            l
          }
          e => { "error": Json::string(message_of(e)) }
        }
        write_line(first, reply) catch {
          _ => ()
        }
        if ending.val is Some(_) {
          break
        }
      }
      (first.finish)() catch {
        _ => ()
      }
    }),
  )
  defer (in_.ended)()
  while (conn.accept_bi)() is Some(stream) {
    if ending.val is Some(_) {
      ignore(rt.fork_quiet(name="door reset", () => (stream.reset)(0) catch { _ => () }))
      continue
    }
    guard (in_.stream)() is Some(answer) else { return }
    let failed = (e : Error) => {
      log("info", "mesh", "request failed", { "error": Json::string(message_of(e)) })
      ignore(rt.fork_quiet(name="door reset", () => (stream.reset)(0) catch { _ => () }))
    }
    ignore(
      rt.fork_daemon("door request", on_error=e => failed(e), () => request(stream, asked => ignore(
          rt.fork_daemon("door answer", on_error=e => failed(e), () => answer(asked) catch { e => failed(e) }),
        )) catch {
        e => failed(e)
      }),
    )
  }
  if ending.val is Some(e) {
    raise e
  }
}
