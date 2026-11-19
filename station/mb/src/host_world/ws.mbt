// Shared `ws.*` WebSocket client over `@host.Host` (used by `browser` CDP and `cloud_net` presence).

///|
pub(all) struct WsHandle {
  send : (String) -> Unit
  close : () -> Unit
}

///|
/// Open a shell WebSocket (`ws.open`), pump incoming text frames on a fiber (`ws.next`), and return `send`/`close`.
/// `on_close(errored)` is called once when the reader loop ends (`true` on read error, `false` on clean EOF).
pub async fn ws_open(
  host : @host.Host,
  url : String,
  name : String,
  headers? : Array[(String, String)] = [],
  entry? : (String, Int)? = None,
  on_message~ : (String) -> Unit,
  on_error? : (String) -> Unit = _ => (),
  on_close~ : (Bool) -> Unit,
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
  let (answer, _) = host.shell("ws.open", @json.Json::object(args))
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
          return
        }
      }
      match json_str_field(frame, "text") {
        Some(t) => on_message(t)
        None => {
          on_close(false)
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
