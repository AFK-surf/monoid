// What a station's program gives Slack's parts on its host (`@host.Host`, the shell's IO on the program's runtime):
// HTTP by `fetch`, Socket Mode by `ws.open`/`ws.next`/`ws.send`/`ws.close`, an attachment's bytes by `fs.bytes`, the
// machine's clock and the runtime's timers and fibers.

///|
fn shell_words(e : Error) -> String {
  match e {
    @wire.ShellError(m) => m
    e => message_of(e)
  }
}

///|
fn json_field(j : Json, k : String) -> Json? {
  match j {
    Object(m) => m.get(k)
    _ => None
  }
}

///|
/// The wall's time (milliseconds since 1970), which the program has only as its station tells it (`told`), carried on
/// by its own steady clock (`@host.now`) since.
pub struct Wall {
  mut wall : Double
  mut steady : Int64
}

///|
pub fn Wall::new(wall : Double) -> Wall {
  { wall, steady: @host.now() }
}

///|
pub fn Wall::told(self : Wall, wall : Double) -> Unit {
  self.wall = wall
  self.steady = @host.now()
}

///|
pub fn Wall::now(self : Wall) -> Double {
  self.wall + (@host.now() - self.steady).to_double()
}

///|
/// HTTP on the shell, the machine's time the wall's: a request whose answer the shell did not get (no way there, a
/// timeout) is `Unanswered`.
pub fn host_net(host : @host.Host, wall : Wall) -> Net {
  let fetch = async fn(
    meth : String,
    url : String,
    headers : Array[(String, String)],
    body : Bytes?,
    timeout_ms : Int,
  ) -> HttpAnswer {
    let args : Map[String, Json] = {
      "url": Json::string(url),
      "method": Json::string(meth),
      "headers": Json::array(headers.map(h => Json::array([Json::string(h.0), Json::string(h.1)]))),
    }
    let call = async fn() -> HttpAnswer {
      let (answer, bytes) = shell_fetch(host, args, body)
      let status = match json_field(answer, "status") {
        Some(Number(n, ..)) => n.to_int()
        _ => 0
      }
      let pairs = match json_field(answer, "headers") {
        Some(Array(xs)) =>
          xs.filter_map(x => match x {
            Array([String(k), String(v)]) => Some((k, v))
            _ => None
          })
        _ => []
      }
      { status, headers: pairs, body: bytes.unwrap_or(b""), redirected: false }
    }
    match @effect.timeout(timeout_ms, call) {
      Some(r) => r
      None => raise Unanswered("The operation was aborted due to timeout")
    }
  }
  { fetch, now: () => wall.now(), sleep: async fn(ms : Int) { @effect.sleep(ms) } }
}

///|
async fn shell_fetch(host : @host.Host, args : Map[String, Json], body : Bytes?) -> (Json, Bytes?) {
  try {
    match body {
      Some(b) => host.shell("fetch", Json::object(args), bytes=b)
      None => host.shell("fetch", Json::object(args))
    }
  } catch {
    e => raise Unanswered(shell_words(e))
  }
}

///|
/// The runtime's clock and fibers; `now`, what it keeps as a time (a name's `at`), ms since the epoch where it is
/// given (the runtime's clock counts from the machine's start).
pub fn host_clock(host : @host.Host, now? : () -> Double) -> Clock {
  {
    now: now.unwrap_or(() => host.rt.now().to_double()),
    sleep: async fn(ms : Int) { @effect.sleep(ms) },
    fork: f => host.rt.fork(f),
  }
}

///|
/// A file's bytes, as `readFile` reads them (its failure in Node's words).
pub fn host_read_file(host : @host.Host) -> async (String) -> Bytes {
  async fn(path) {
    let (v, _) = host.shell("fs.bytes", Json::object({ "path": Json::string(path) })) catch {
      e => raise fail_(shell_words(e))
    }
    match v {
      String(hex) => decode_hex(hex)
      _ => raise fail_("ENOENT: no such file or directory, open '\{path}'")
    }
  }
}

///|
fn decode_hex(hex : String) -> Bytes {
  let n = hex.length() / 2
  let out = FixedArray::make(n, b'\x00')
  let v = (c : Int) => if c >= '0'.to_int() && c <= '9'.to_int() {
    c - '0'.to_int()
  } else if c >= 'a'.to_int() && c <= 'f'.to_int() {
    c - 'a'.to_int() + 10
  } else if c >= 'A'.to_int() && c <= 'F'.to_int() {
    c - 'A'.to_int() + 10
  } else {
    0
  }
  for i in 0..<n {
    out[i] = (v(hex.unsafe_charcode_at(2 * i)) * 16 + v(hex.unsafe_charcode_at(2 * i + 1))).to_byte()
  }
  Bytes::from_array(out)
}

///|
/// Socket Mode on the shell: `ws.open`, its frames read by `ws.next`. The shell answers Slack's pings itself and says
/// nothing of pongs: its socket has no `ping` of the surface's.
pub fn host_ws(host : @host.Host) -> WsIO {
  {
    open: async fn(url) {
      let (answer, _) = host.shell(
        "ws.open",
        Json::object({ "url": Json::string(url), "headers": Json::array([]) }),
      ) catch {
        e => {
          let words = shell_words(e)
          // "websocket refused (404)": an answer other than the Upgrade
          if words.has_prefix("websocket refused (") {
            let digits = words.unsafe_substring(start=19, end=words.length()).iter().take_while(c => c >= '0' && c <= '9').collect()
            let n = String::from_array(digits)
            if n != "" {
              raise WsRefused(js_num(Some(js(n))).to_int(), "")
            }
          }
          raise Unanswered(words)
        }
      }
      let id = match json_field(answer, "id") {
        Some(Number(n, ..)) => n
        _ => raise fail_("the shell gave no socket")
      }
      let closed = Ref(false)
      {
        next: async fn() {
          if closed.val {
            return None
          }
          let (frame, _) = host.shell("ws.next", Json::object({ "id": Json::number(id) })) catch {
            e => raise fail_(shell_words(e))
          }
          match json_field(frame, "text") {
            Some(String(t)) => Some(t)
            _ => None
          }
        },
        send: t => if !closed.val {
          ignore(
            host.rt.fork_quiet(name="slack ws send", async fn() {
              ignore(host.shell("ws.send", Json::object({ "id": Json::number(id), "text": Json::string(t) }))) catch {
                _ => ()
              }
            }),
          )
        },
        close: () => if !closed.val {
          closed.val = true
          ignore(
            host.rt.fork_quiet(name="slack ws close", async fn() {
              ignore(host.shell("ws.close", Json::object({ "id": Json::number(id) }))) catch {
                _ => ()
              }
            }),
          )
        },
        ping: None,
      }
    },
  }
}

///|
/// What the station logs, on the program's stderr (`@host.note`): its level, part, words and details.
pub fn host_log() -> Log {
  (level, part, words, fields) => @host.note("\{level} \{part}: \{words} \{stringify(fields)}")
}
