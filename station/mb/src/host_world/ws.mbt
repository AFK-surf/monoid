// Shared `ws.*` WebSocket client over `@host.Host` (used by `browser` CDP and `cloud_net` presence).

///|
pub(all) struct WsHandle {
  send : (String) -> Unit
  close : () -> Unit
}

///|
/// How a WebSocket ended, as `ws.next`'s end says it: the Close frame's code and reason where the other side gave
/// them (the plane's 4000, a presence socket replaced, 4004, its station removed), else 1005 (no status received).
pub fn ws_close_of(frame : @json.Json) -> (Int, String) {
  match frame {
    { "code": Number(code, ..), "reason": String(reason), .. } => (code.to_int(), reason)
    { "code": Number(code, ..), .. } => (code.to_int(), "")
    _ => (1005, "")
  }
}

///|
/// Open a shell WebSocket (`ws.open`), pump incoming text frames on a fiber (`ws.next`), and return `send`/`close`.
/// `timeout_ms`: how long its opening (TCP, TLS, Upgrade) may take at the shell (the shell's own 20 s where not
/// given). Interrupted while it opens, the opening is given up at the shell too (`fetch.cancel`), its socket with it.
/// `on_close(errored)` is called once when the reader loop ends (`true` on read error, `false` on clean EOF), and
/// `on_closed(code, reason)` with it: the Close frame's (`ws_close_of`), 1006 on a read error.
pub async fn ws_open(
  host : @host.Host,
  url : String,
  name : String,
  headers? : Array[(String, String)] = [],
  entry? : (String, Int)? = None,
  timeout_ms? : Int,
  on_message~ : (String) -> Unit,
  on_error? : (String) -> Unit = _ => (),
  on_close~ : (Bool) -> Unit,
  on_closed? : (Int, String) -> Unit = (_, _) => (),
) -> WsHandle {
  let args : Map[String, @json.Json] = {
    "url": @json.Json::string(url),
    "headers": @json.Json::array(
      headers.map(p => @json.Json::array([@json.Json::string(p.0), @json.Json::string(p.1)])),
    ),
  }
  if entry is Some((h, port)) {
    args["entry"] = { "host": @json.Json::string(h), "port": @json.Json::number(port.to_double()) }
  }
  if timeout_ms is Some(ms) {
    args["timeoutMs"] = @json.Json::number(ms.to_double())
  }
  let call : Ref[Int64?] = Ref(None)
  let (answer, _) = {
    // (a call the shell failed is gone there already: cancelling it then is a no-op)
    errdefer (if call.val is Some(i) { host.cancel_fetch(i) })
    host.shell("ws.open", @json.Json::object(args), called=i => call.val = Some(i))
  }
  let id = match json_num(answer, "id") {
    Some(n) => n
    None => fail("websocket did not answer at \{url}")
  }
  let fiber = host.rt.fork(async fn() {
    while true {
      let (frame, _) = host.shell("ws.next", { "id": @json.Json::number(id) }) catch {
        e => {
          on_error(shell_error_msg(e))
          on_close(true)
          on_closed(1006, "")
          return
        }
      }
      match json_str_field(frame, "text") {
        Some(t) => on_message(t)
        None => {
          on_close(false)
          let (code, reason) = ws_close_of(frame)
          on_closed(code, reason)
          return
        }
      }
    }
  })
  {
    send: text => ignore(
      host.rt.fork_quiet(name="\{name} ws send", async fn() {
        ignore(host.shell("ws.send", { "id": @json.Json::number(id), "text": @json.Json::string(text) })) catch { _ => () }
      }),
    ),
    close: () => {
      fiber.interrupt()
      ignore(
        host.rt.fork_quiet(name="\{name} ws close", async fn() {
          ignore(host.shell("ws.close", { "id": @json.Json::number(id) })) catch { _ => () }
        }),
      )
    },
  }
}
