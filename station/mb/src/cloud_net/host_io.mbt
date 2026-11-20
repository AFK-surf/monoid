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
          // (interrupted, `destroy`: the fetch is given up at the shell too, its TLS with it)
          ignore(host.fetch(origin + "/healthz", entry=(route.host, route.port)))
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
    let r = host.fetch(
      req.url,
      method_=req.http_method,
      headers=req.headers.pairs,
      body?=req.body.map(b => @utf8.encode(b)),
      entry?=socket.map(s => (s.host, s.port)),
      timeout_ms=req.timeout_ms,
    ) catch {
      @host.FetchTimeout => raise NetError(@host.fetch_timed_out)
      e => raise e
    }
    { status: r.status, body: r.text() }
  }
  { fetch: req => ask(req, None), over: (req, socket) => ask(req, Some(socket)) }
}

///|
/// A WebSocket on the shell: `ws.open` (with the signed headers, and the dial's route as its entry where one made it), its
/// frames read by `ws.next` on a fiber of its own.
pub fn host_ws(host : @host.Host) -> WsIO {
  {
    open: (url, headers, over, events) => {
      let handle : Ref[@host_world.WsHandle?] = Ref(None)
      let ended = Ref(false)
      let end = (code : Int, reason : String) => if !ended.val {
        ended.val = true
        (events.close)(code, reason)
      }
      let fiber = host.rt.fork(async fn() {
        let conn = @host_world.ws_open(
          host,
          url,
          "cloud",
          headers=headers.pairs,
          entry=over.map(s => (s.host, s.port)),
          // (as the TypeScript station's presence socket waits for its open, station/src/cloud/presence.ts)
          timeout_ms=20_000,
          on_message=events.message,
          on_error=events.error,
          on_close=_ => (),
          // (the plane's code and reason: 4000 replaced, 4004 removed, presence.mbt)
          on_closed=end,
        ) catch {
          e => {
            let words = @host_world.shell_error_msg(e)
            if words.has_prefix("websocket refused (") {
              let digits = words.unsafe_substring(start=19, end=words.length()).iter().take_while(c => c >= '0' && c <= '9').collect()
              if (try Some(@string.parse_int(String::from_array(digits))) catch { _ => None }) is Some(status) {
                (events.unexpected)(status)
              }
            }
            (events.error)(words)
            end(1006, "")
            return
          }
        }
        handle.val = Some(conn)
        (events.open)()
      })
      let shut = fn() {
        if handle.val is Some(c) {
          handle.val = None
          (c.close)()
        }
        fiber.interrupt()
        end(1006, "")
      }
      {
        send: t => if handle.val is Some(c) { (c.send)(t) },
        close: shut,
        terminate: shut,
        is_open: () => handle.val is Some(_) && !ended.val,
      }
    },
  }
}

///|
/// A file the shell writes whole (`fs.put`, truncated, made private); read back by `fs.bytes` once, as it starts.
pub fn host_kept(host : @host.Host, path : String) -> Kept {
  let text = match (try Some(host.shell_sync("fs.bytes", { "path": Json::string(path) })) catch { _ => None }) {
    Some(String(hex)) => Some(@utf8.decode_lossy(@host_world.hex_bytes(hex)))
    _ => None
  }
  let writing : @effect.Queue[String] = @effect.Queue::unbounded()
  ignore(
    host.rt.fork_daemon("cloud file writes", on_error=e => @host.note("\{path} no longer written: \{error_words(e)}"), async fn() {
      while true {
        let t = writing.take()
        @host_world.fs_put_whole(host, path, @utf8.encode(t), mode=384) catch {
          e => @host.note("\{path} not written: \{error_words(e)}")
        }
      }
    }),
  )
  { read: () => text, write: t => ignore(writing.try_offer(t)) }
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
