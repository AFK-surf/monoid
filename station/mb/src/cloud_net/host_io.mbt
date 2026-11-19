// The network as the station's program has it: the shell's (`@host.Host::shell`, client/shell's `run`), on the
// program's runtime. HTTP by `fetch`, a WebSocket by `ws.open`/`ws.next`/`ws.send`/`ws.close`, a file by `fs.put`.
// The shell offers no TLS socket of its own to hand on: an entry is said to `fetch` and `ws.open` themselves
// (`"entry": {"host", "port"}`: the TCP to that host and port, TLS's server name, the certificate checked and HTTP's
// Host the URL's own), each candidate of a dial a route (`TlsSocket`'s host and port: the origin's own for the direct
// one, which the shell resolves as it would without one). A candidate is dialed by asking `<origin>/healthz` on its
// route: any answer is its TLS made and verified, and the connection stays in the shell's pool of that route
// (`entries`, kept idle 60 s), which the request `over` it then takes, as transport.ts' HTTP takes the dial's socket;
// a WebSocket `over` it connects to the route that won anew (the shell's `ws.open` keeps no pool).

///|
fn pairs_json(h : Headers) -> Json {
  Json::array(h.pairs.map(p => Json::array([Json::string(p.0), Json::string(p.1)])))
}

///|
/// The shell's entry for a route a dial made.
fn entry_json(s : TlsSocket) -> Json {
  { "host": Json::string(s.host), "port": Json::number(s.port.to_double()) }
}

///|
/// The dial's IO on the shell: timers on `host`'s runtime, each candidate dialed by a `fetch` of `origin`'s
/// `/healthz` with its route as the entry (still.fail's canonical origin unless a test says its own).
pub fn host_dial_io(host : @host.Host, origin? : String = cloud_origin) -> DialIO {
  let timers = After::effect(host.rt)
  let next = Ref(0)
  {
    after: timers.after,
    tls: (h, port, _servername, events) => {
      next.val += 1
      let id = next.val
      let gone = Ref(false)
      let route = { id, host: h, port, destroy: () => () }
      let fiber = host.rt.fork(async fn() {
        let answered = try {
          ignore(
            host.shell("fetch", {
              "url": Json::string(origin + "/healthz"),
              "method": "GET",
              "headers": Json::array([]),
              "entry": entry_json(route),
            }),
          )
          None
        } catch {
          e => Some(error_words(e))
        }
        if gone.val {
          return
        }
        match answered {
          None => (events.secure)()
          Some(words) => (events.error)(words)
        }
      })
      {
        id,
        host: h,
        port,
        // (the shell's pool keeps the connection a route made; a pending dial is let go)
        destroy: () => if !gone.val {
          gone.val = true
          fiber.interrupt()
        },
      }
    },
  }
}

///|
/// HTTP on the shell: by itself, or on the route a dial made (its entry).
pub fn host_http(host : @host.Host) -> Http {
  let ask = async fn(req : HttpRequest, socket : TlsSocket?) -> HttpResponse {
    let args : Map[String, Json] = {
      "url": Json::string(req.url),
      "method": Json::string(req.http_method),
      "headers": pairs_json(req.headers),
    }
    match socket {
      Some(s) => args["entry"] = entry_json(s)
      None => ()
    }
    let call = async fn() {
      let (answer, body) = match req.body {
        Some(b) => host.shell("fetch", Json::object(args), bytes=@utf8.encode(b))
        None => host.shell("fetch", Json::object(args))
      }
      let status = safe_int(field(answer, "status")).unwrap_or(0L).to_int()
      let text = match body {
        Some(b) => @utf8.decode_lossy(b)
        None => ""
      }
      { status, body: text }
    }
    match @effect.timeout(req.timeout_ms, call) {
      Some(r) => r
      None => raise NetError("The operation was aborted due to timeout")
    }
  }
  { fetch: req => ask(req, None), over: (req, socket) => ask(req, Some(socket)) }
}

///|
/// A WebSocket on the shell: `ws.open` (with the signed headers, and the dial's route as its entry where one made it), its
/// frames read by `ws.next` on a fiber of its own.
pub fn host_ws(host : @host.Host) -> WsIO {
  {
    open: (url, headers, over, events) => {
      let id : Ref[Int?] = Ref(None)
      let ended = Ref(false)
      let end = (code : Int, reason : String) => if !ended.val {
        ended.val = true
        (events.close)(code, reason)
      }
      let fiber = host.rt.fork(async fn() {
        let args : Map[String, Json] = {
          "url": Json::string(url),
          "headers": pairs_json(headers),
        }
        match over {
          Some(s) => args["entry"] = entry_json(s)
          None => ()
        }
        let (answer, _) = host.shell("ws.open", Json::object(args)) catch {
          e => {
            let words = error_words(e)
            // "websocket refused (404)": an answer other than the Upgrade
            if words.has_prefix("websocket refused (") {
              let digits = words
                .unsafe_substring(start=19, end=words.length())
                .iter()
                .take_while(c => c >= '0' && c <= '9')
                .collect()
              match (try Some(@string.parse_int(String::from_array(digits))) catch {
                _ => None
              }) {
                Some(status) => (events.unexpected)(status)
                None => ()
              }
            }
            (events.error)(words)
            end(1006, "")
            return
          }
        }
        let n = safe_int(field(answer, "id")).unwrap_or(-1L).to_int()
        id.val = Some(n)
        (events.open)()
        while true {
          let (frame, _) = host.shell("ws.next", { "id": Json::number(n.to_double()) }) catch {
            e => {
              (events.error)(error_words(e))
              end(1006, "")
              return
            }
          }
          match text_of(field(frame, "text")) {
            Some(t) => (events.message)(t)
            None => {
              // (the shell says no close code: the socket ended as the server closed it)
              end(1005, "")
              return
            }
          }
        }
      })
      let shut = fn() {
        match id.val {
          Some(n) => {
            id.val = None
            ignore(
              host.rt.fork_quiet(name="cloud ws close", async fn() {
                ignore(host.shell("ws.close", { "id": Json::number(n.to_double()) })) catch {
                  _ => ()
                }
              }),
            )
          }
          None => ()
        }
        fiber.interrupt()
        end(1006, "")
      }
      {
        send: text => match id.val {
          Some(n) =>
            ignore(
              host.rt.fork_quiet(name="cloud ws send", async fn() {
                ignore(
                  host.shell("ws.send", {
                    "id": Json::number(n.to_double()),
                    "text": Json::string(text),
                  }),
                ) catch {
                  _ => ()
                }
              }),
            )
          None => ()
        },
        close: shut,
        terminate: shut,
        is_open: () => id.val is Some(_) && !ended.val,
      }
    },
  }
}

///|
/// A file the shell writes whole (`fs.put`, truncated, made private); read back by `fs.bytes` once, as it starts.
pub fn host_kept(host : @host.Host, path : String) -> Kept {
  let text = match
    (try Some(host.shell_sync("fs.bytes", { "path": Json::string(path) })) catch {
      _ => None
    }) {
    Some(String(hex)) => Some(@utf8.decode_lossy(hex_bytes(hex)))
    Some(_) => None
    None => None
  }
  let writing : @effect.Queue[String] = @effect.Queue::unbounded()
  ignore(
    host.rt.fork_daemon("cloud file writes", on_error=e => @host.note("\{path} no longer written: \{error_words(e)}"), async fn() {
      while true {
        let t = writing.take()
        ignore(
          host.shell(
            "fs.put",
            { "path": Json::string(path), "truncate": true, "mode": 384 },
            bytes=@utf8.encode(t),
          ),
        ) catch {
          e => @host.note("\{path} not written: \{error_words(e)}")
        }
      }
    }),
  )
  { read: () => text, write: t => ignore(writing.try_offer(t)) }
}

///|
fn hex_bytes(hex : String) -> Bytes {
  let out = FixedArray::make(hex.length() / 2, b'\x00')
  for i in 0..<(hex.length() / 2) {
    let hi = hex_value(hex.get_char(2 * i).unwrap_or('0')).unwrap_or(0)
    let lo = hex_value(hex.get_char(2 * i + 1).unwrap_or('0')).unwrap_or(0)
    out[i] = (hi * 16 + lo).to_byte()
  }
  Bytes::from_array(out)
}

///|
/// A relay asked whether it answers (`<relay>/ping`, 10 s), and measured again where `pinged` is given.
pub fn host_pinger(http : Http, pinged? : (String, Int64) -> Unit) -> Pinger {
  {
    ping: async fn(relay : String) {
      let answer = (http.fetch)({
        url: relay + "/ping",
        http_method: "GET",
        headers: Headers::new(),
        body: None,
        timeout_ms: 10_000,
      })
      answer.status >= 200 && answer.status <= 299
    },
    pinged,
  }
}
