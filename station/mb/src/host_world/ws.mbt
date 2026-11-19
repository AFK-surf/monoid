// Shared `ws.*` WebSocket client over `@host.Host` (used by `browser` CDP and `cloud_net` presence).

///|
pub(all) struct WsConn {
  send : (String) -> Unit
  close : () -> Unit
  is_open : () -> Bool
}

///|
fn ws_open_args(url : String, headers : Array[(String, String)], entry : (String, Int)?) -> @json.Json {
  let args : Map[String, @json.Json] = {
    "url": @json.Json::string(url),
    "headers": @json.Json::array(
      headers.map(p => @json.Json::array([@json.Json::string(p.0), @json.Json::string(p.1)])),
    ),
  }
  match entry {
    Some((h, port)) =>
      args["entry"] = {
        "host": @json.Json::string(h),
        "port": @json.Json::number(port.to_double()),
      }
    None => ()
  }
  @json.Json::object(args)
}

///|
fn ws_send_quiet(host : @host.Host, name : String, id : Double, text : String) -> Unit {
  ignore(
    host.rt.fork_quiet(name="\{name} ws send", async fn() {
      ignore(host.shell("ws.send", { "id": @json.Json::number(id), "text": @json.Json::string(text) })) catch {
        _ => ()
      }
    }),
  )
}

///|
fn ws_close_quiet(host : @host.Host, name : String, id : Double) -> Unit {
  ignore(
    host.rt.fork_quiet(name="\{name} ws close", async fn() {
      ignore(host.shell("ws.close", { "id": @json.Json::number(id) })) catch {
        _ => ()
      }
    }),
  )
}

///|
fn parse_refused_status(words : String) -> Int? {
  if !words.has_prefix("websocket refused (") {
    return None
  }
  let digits = words
    .unsafe_substring(start=19, end=words.length())
    .iter()
    .take_while(c => c >= '0' && c <= '9')
    .collect()
  try Some(@string.parse_int(String::from_array(digits))) catch {
    _ => None
  }
}

///|
/// Open a WebSocket asynchronously, returning the live handle once connected (for callers like CDP).
pub async fn ws_open_sync(
  host : @host.Host,
  url : String,
  name : String,
  headers? : Array[(String, String)] = [],
  entry? : (String, Int)? = None,
  on_message~ : (String) -> Unit,
  on_close~ : () -> Unit,
) -> WsConn {
  let (answer, _) = host.shell("ws.open", ws_open_args(url, headers, entry))
  let id = match json_num(answer, "id") {
    Some(n) => n
    None => fail("websocket did not answer at \{url}")
  }
  let ended = Ref(false)
  let end = () => if !ended.val {
    ended.val = true
    on_close()
  }
  let fiber = host.rt.fork(async fn() {
    while true {
      let (frame, _) = host.shell("ws.next", { "id": @json.Json::number(id) }) catch {
        _ => {
          end()
          return
        }
      }
      match json_str_field(frame, "text") {
        Some(t) => on_message(t)
        None => {
          end()
          return
        }
      }
    }
  })
  {
    send: text => ws_send_quiet(host, name, id, text),
    close: () => {
      fiber.interrupt()
      ws_close_quiet(host, name, id)
    },
    is_open: () => !ended.val,
  }
}

///|
/// Open a WebSocket in a background fiber and report lifecycle events through callbacks (for callers like `cloud_net`).
pub fn ws_connect(
  host : @host.Host,
  url : String,
  name : String,
  headers? : Array[(String, String)] = [],
  entry? : (String, Int)? = None,
  on_open~ : () -> Unit,
  on_message~ : (String) -> Unit,
  on_error~ : (String) -> Unit,
  on_unexpected? : (Int) -> Unit = _ => (),
  on_close~ : (Int, String) -> Unit,
) -> WsConn {
  let id : Ref[Double?] = Ref(None)
  let ended = Ref(false)
  let end = (code : Int, reason : String) => if !ended.val {
    ended.val = true
    on_close(code, reason)
  }
  let fiber = host.rt.fork(async fn() {
    let (answer, _) = host.shell("ws.open", ws_open_args(url, headers, entry)) catch {
      e => {
        let words = shell_error_msg(e)
        match parse_refused_status(words) {
          Some(status) => on_unexpected(status)
          None => ()
        }
        on_error(words)
        end(1006, "")
        return
      }
    }
    let n = json_num(answer, "id").unwrap_or(-1.0)
    id.val = Some(n)
    on_open()
    while true {
      let (frame, _) = host.shell("ws.next", { "id": @json.Json::number(n) }) catch {
        e => {
          on_error(shell_error_msg(e))
          end(1006, "")
          return
        }
      }
      match json_str_field(frame, "text") {
        Some(t) => on_message(t)
        None => {
          end(1005, "")
          return
        }
      }
    }
  })
  {
    send: text => match id.val {
      Some(n) => ws_send_quiet(host, name, n, text)
      None => ()
    },
    close: () => {
      match id.val {
        Some(n) => {
          id.val = None
          ws_close_quiet(host, name, n)
        }
        None => ()
      }
      fiber.interrupt()
      end(1006, "")
    },
    is_open: () => id.val is Some(_) && !ended.val,
  }
}
