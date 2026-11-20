// A connection to Chrome's DevTools protocol (src/browser/cdp.ts, CDP) over its WebSocket: requests answered by id,
// events heard, sessions of targets flattened onto it (`sessionId`). The station's browser holds one to watch the tabs,
// and each screen view one of its own, so neither is in the way of the agents' own connections. The socket is the
// caller's (`CdpSocket`: the shell's `ws.open` in the station, a test's own); what goes over it is here.

///|
/// How long a connection is given to open, and a command to be answered (Chrome's time: the machine's clock).
pub let cdp_open_ms : Double = 10_000.0

///|
pub let cdp_answer_ms : Double = 30_000.0

///|
/// A WebSocket to Chrome's DevTools: a text sent, closed; what it hears is told the connection (`CdpLink::heard`,
/// `CdpLink::ended`).
pub(all) struct CdpSocket {
  send : (String) -> Unit
  close : () -> Unit
}

///|
/// What is waited for within a time (ops/fibers.ts `wall.within`): its value, or `words` raised once `ms` passed.
pub async fn[X] within(clock : Clock, ms : Double, f : async () -> X, words : String) -> X {
  let d : @effect.Deferred[X] = @effect.Deferred::new()
  let stop = (clock.after)(ms, async fn() { ignore(d.fail(fail_(words))) })
  (clock.spawn)(async fn() {
    let v = f() catch {
      e => {
        ignore(d.fail(e))
        return
      }
    }
    ignore(d.succeed(v))
  })
  let r = try Ok(d.wait()) catch { e => Err(e) }
  stop()
  match r {
    Ok(v) => v
    Err(e) => raise e
  }
}

///|
/// The connection's state: what is asked and not answered, who hears.
pub struct CdpLink {
  priv socket : CdpSocket
  priv clock : Clock
  priv mut next : Int
  priv pending : Map[Int, (@effect.Deferred[J], () -> Unit)]
  priv listeners : Array[(Int, (CdpEvent) -> Unit)]
  priv mut listener_id : Int
  priv mut gone : Bool
  priv done : @effect.Deferred[Unit]
}

///|
pub fn CdpLink::new(socket : CdpSocket, clock : Clock) -> CdpLink {
  {
    socket,
    clock,
    next: 0,
    pending: {},
    listeners: [],
    listener_id: 0,
    gone: false,
    done: @effect.Deferred::new(),
  }
}

///|
/// The connection ended, whichever side ended it: what waits for an answer fails.
pub fn CdpLink::ended(self : CdpLink) -> Unit {
  if self.gone {
    return
  }
  self.gone = true
  for _, p in self.pending {
    (p.1)()
    ignore(p.0.fail(fail_("the browser's DevTools connection closed")))
  }
  self.pending.clear()
  ignore(self.done.succeed(()))
}

///|
/// A message Chrome sent.
pub fn CdpLink::heard(self : CdpLink, raw : String) -> Unit {
  let message = parse(raw) catch { _ => return }
  let m = match message {
    Obj(_) => Some(message)
    _ => None
  }
  match at(m, "id") {
    Some(Num(n)) => {
      let id = n.to_int()
      if id.to_double() != n {
        return
      }
      guard self.pending.get(id) is Some((p, stop)) else { return }
      self.pending.remove(id)
      stop()
      let error = at(m, "error")
      if truthy(error) {
        let words = match at(error, "message") {
          None | Some(Null) => "CDP error"
          w => js_str(w)
        }
        let data = if truthy(at(error, "data")) { ": " + js_str(at(error, "data")) } else { "" }
        ignore(p.fail(fail_(words + data)))
      } else {
        ignore(
          p.succeed(
            match at(m, "result") {
              None | Some(Null) => Obj([])
              Some(r) => r
            },
          ),
        )
      }
    }
    _ =>
      match at(m, "method") {
        Some(Str(u)) => {
          let e : CdpEvent = {
            method: @jsjson.sanitize_str(u),
            params: match at(m, "params") {
              None | Some(Null) => Obj([])
              Some(p) => p
            },
            session_id: match at(m, "sessionId") {
              Some(x) => Some(js_str(Some(x)))
              None => None
            },
          }
          for l in self.listeners.copy() {
            (l.1)(e)
          }
        }
        _ => ()
      }
  }
}

///|
/// The connection as the browser's parts use it.
pub fn CdpLink::cdp(self : CdpLink) -> Cdp {
  {
    post: (method, params, session) => {
      let answer : @effect.Deferred[J] = @effect.Deferred::new()
      if self.gone {
        ignore(answer.fail(fail_("the browser's DevTools connection closed")))
        return Later::of(answer)
      }
      self.next += 1
      let id = self.next
      let fs : Array[(String, J)] = [("id", ji(id)), ("method", js(method)), ("params", params)]
      match session {
        Some(s) => fs.push(("sessionId", js(s)))
        None => ()
      }
      let stop = (self.clock.after)(cdp_answer_ms, async fn() {
        if self.pending.contains(id) {
          self.pending.remove(id)
          ignore(answer.fail(fail_("the browser did not answer \{method}")))
        }
      })
      self.pending[id] = (answer, stop)
      (self.socket.send)(stringify(jo(fs)))
      Later::of(answer)
    },
    on: listener => {
      self.listener_id += 1
      let id = self.listener_id
      self.listeners.push((id, listener))
      () => match self.listeners.search_by(l => l.0 == id) {
        Some(i) => ignore(self.listeners.remove(i))
        None => ()
      }
    },
    closed: async fn() { self.done.wait() catch { _ => () } },
    close: () => {
      if !self.gone {
        (self.socket.close)()
      }
      self.ended()
    },
  }
}

///|
/// A connection to Chrome's DevTools at `url` (cdp.ts `connectCdp`): `open` makes the socket (raising where it cannot),
/// given what hears it.
pub async fn connect_cdp(
  url : String,
  open : async (String, CdpLink) -> CdpSocket,
  clock : Clock,
) -> Cdp {
  let socket_ref : Ref[CdpSocket?] = Ref(None)
  let link = CdpLink::new(
    {
      send: t => match socket_ref.val {
        Some(s) => (s.send)(t)
        None => ()
      },
      close: () => match socket_ref.val {
        Some(s) => (s.close)()
        None => ()
      },
    },
    clock,
  )
  let socket = within(clock, cdp_open_ms, async fn() { open(url, link) }, "the browser's DevTools did not answer at \{url}")
  socket_ref.val = Some(socket)
  link.cdp()
}
