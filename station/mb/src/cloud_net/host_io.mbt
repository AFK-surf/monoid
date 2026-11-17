// The network as the station's program has it: the shell's (`@host.Host::shell`, client/shell's `run`), on the
// program's runtime. HTTP by `fetch`, a WebSocket by `ws.open`/`ws.next`/`ws.send`/`ws.close`, a file by `fs.put`; a
// TLS connection to an entry's host and port that verifies the canonical origin's certificate by `tls.open` (and HTTP
// on it by `fetch` with its `socket`, a WebSocket by `ws.open` with it), which the shell is to offer: until it does,
// what asks it is told the shell's own refusal, and a dial goes on with the direct candidate alone.

///|
fn pairs_json(h : Headers) -> Json {
  Json::array(h.pairs.map(p => Json::array([Json::string(p.0), Json::string(p.1)])))
}

///|
/// The dial's IO on the shell: timers on `host`'s runtime, TLS by `tls.open`.
pub fn host_dial_io(host : @host.Host) -> DialIO {
  let timers = After::effect(host.rt)
  let next = Ref(0)
  {
    after: timers.after,
    tls: (h, port, servername, events) => {
      next.val += 1
      let id = next.val
      let opened : Ref[Int?] = Ref(None)
      let gone = Ref(false)
      let fiber = host.rt.fork(async fn() {
        let (answer, _) = host.shell("tls.open", {
          "host": Json::string(h),
          "port": Json::number(port.to_double()),
          "servername": Json::string(servername),
          "alpn": ["http/1.1"],
        }) catch {
          e => {
            (events.error)(error_words(e))
            return
          }
        }
        match safe_int(field(answer, "id")) {
          Some(n) =>
            if gone.val {
              ignore(host.shell("tls.close", { "id": int_json(n) })) catch {
                _ => ()
              }
            } else {
              opened.val = Some(n.to_int())
              (events.secure)()
            }
          None => (events.error)("the shell gave no socket")
        }
      })
      {
        id,
        host: h,
        port,
        destroy: () => {
          gone.val = true
          match opened.val {
            Some(n) => {
              opened.val = None
              ignore(
                host.rt.fork(async fn() {
                  ignore(host.shell("tls.close", { "id": Json::number(n.to_double()) })) catch {
                    _ => ()
                  }
                }),
              )
            }
            None => fiber.interrupt()
          }
        },
      }
    },
  }
}

///|
/// HTTP on the shell: by itself, or on a socket a dial made.
pub fn host_http(host : @host.Host) -> Http {
  let ask = async fn(req : HttpRequest, socket : Int?) -> HttpResponse {
    let args : Map[String, Json] = {
      "url": Json::string(req.url),
      "method": Json::string(req.http_method),
      "headers": pairs_json(req.headers),
    }
    match socket {
      Some(s) => args["socket"] = Json::number(s.to_double())
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
  { fetch: req => ask(req, None), over: (req, socket) => ask(req, Some(socket.id)) }
}

///|
/// A WebSocket on the shell: `ws.open` (with the signed headers, and the dial's socket where it went by an entry), its
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
          Some(s) => args["socket"] = Json::number(s.id.to_double())
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
              host.rt.fork(async fn() {
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
              host.rt.fork(async fn() {
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
    Some(answer) =>
      match field(answer, "value") {
        Some(String(hex)) => Some(@utf8.decode_lossy(hex_bytes(hex)))
        _ => None
      }
    None => None
  }
  let writing : @effect.Queue[String] = @effect.Queue::unbounded()
  ignore(
    host.rt.fork(async fn() {
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
