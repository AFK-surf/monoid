// The forwards (peer_forward.mbt) on sockets and tunnels of the test's, on its clock.

///|
fn fake_socket(log : Array[String], name : String) -> @gate.Socket {
  let gone = Ref(false)
  let closed : @effect.Deferred[Unit] = @effect.Deferred::new()
  {
    remote_port: Some(1),
    abort: () => if !gone.val {
      gone.val = true
      log.push("\{name} aborted")
      ignore(closed.succeed(()))
    },
    destroyed: () => gone.val,
    closed: async fn() { closed.wait() },
    pipe: async fn(_stream, carry) {
      log.push("\{name} piped \{carry.length()}")
      gone.val = true
      ignore(closed.succeed(()))
    },
    join: async fn(_other) { log.push("\{name} joined") },
  }
}

///|
test "a forward: opened on its own port or another, its connections tunnelled, a station unreachable held off, let go idle" {
  let rt = @effect.Runtime::new()
  let log = []
  let taken = [8080]
  let takers : Map[Int, (@gate.Socket) -> Unit] = Map([])
  let next_port = Ref(40000)
  let sockets : @gate.Sockets = {
    listen: async fn(port, _mine, take) {
      if taken.contains(port) {
        return None
      }
      let p = if port == 0 {
        next_port.val += 1
        next_port.val
      } else {
        port
      }
      taken.push(p)
      takers[p] = take
      Some({ port: p, close: () => log.push("closed \{p}") })
    },
    holders: async fn(_p) { [] },
  }
  let reachable = Ref(true)
  let tunnels : @gate.Tunnels = {
    tunnel: async fn(station, port, probe) {
      log.push("tunnel \{station} \{port} \{probe}")
      if !reachable.val {
        raise @gate.HttpRefusal(504, "station down", true)
      }
      if probe {
        None
      } else {
        let (a, _b) = @door.pair("x", "y")
        ignore(a)
        Some((@door.Stream::{ read: async fn() { None }, write: async fn(_b) { () }, finish: async fn() { () }, stopped: async fn() { None }, reset: async fn(_c) { () }, media_datagrams: None }, b"ab"))
      }
    },
    tunnel_device: None,
  }
  let forwards = @gate.Forwards::new(rt, () => Some(tunnels), async fn(s) { (s + "-id", s + "-name") }, sockets)
  let said = []
  ignore(rt.fork(() => {
    said.push(forwards.open("chat", "s1", 3000).stringify())
    said.push(forwards.open("chat", "s1", 3000).stringify())
    said.push(forwards.open("chat", "s1", 8080).stringify())
    said.push((try { forwards.open("chat", "s1", 9000, local=8080).stringify() } catch { e => @gate.words_of(e) }))
    said.push((try { forwards.open("chat", "s1", 0).stringify() } catch { e => @gate.words_of(e) }))
  } catch { e => said.push("failed: " + @gate.words_of(e)) }))
  ignore(rt.run_ready())
  assert_eq(said[0], "{\"local\":\"127.0.0.1:3000\",\"url\":\"http://127.0.0.1:3000/\",\"station\":\"s1-name\",\"port\":3000,\"connections\":0,\"served\":0}")
  assert_true(said[1].contains("\"note\":\"already forwarded\""))
  assert_true(said[2].contains("\"local\":\"127.0.0.1:40001\"") && said[2].contains("port 8080 is taken here, so it is at 40001"))
  assert_eq(said[3], "127.0.0.1:8080 is taken here (something listens on it, at 127.0.0.1 or [::1]); give another local_port, or none")
  assert_eq(said[4], "port: 1 to 65535")
  assert_true(forwards.forwarded(3000) && forwards.count() == 2)
  // A connection to it: tunnelled, its bytes piped with what came after the answer.
  (takers[3000])(fake_socket(log, "c1"))
  ignore(rt.run_ready())
  assert_true(log.contains("tunnel s1-id 3000 false") && log.contains("c1 piped 2"))
  // The station unreachable: refused, and held off DOWN_MS (its next connection refused at once, not tunnelled).
  reachable.val = false
  (takers[3000])(fake_socket(log, "c2"))
  ignore(rt.run_ready())
  let before = log.filter(l => l.has_prefix("tunnel")).length()
  (takers[3000])(fake_socket(log, "c3"))
  ignore(rt.run_ready())
  assert_true(log.contains("c2 aborted") && log.contains("c3 aborted"))
  assert_eq(log.filter(l => l.has_prefix("tunnel")).length(), before)
  // Listed: the station probed, offline; then idle past IDLE_MS, let go.
  let listed = []
  ignore(rt.fork(() => for v in forwards.list("chat") { listed.push(v.stringify()) }))
  ignore(rt.run_ready())
  assert_true(listed[0].contains("\"station_state\":\"offline: station down\"") && listed[0].contains("\"last_error\":\"station down\""))
  rt.advance(@gate.forward_idle_ms)
  assert_true(log.contains("closed 3000") && log.contains("closed 40001"))
  assert_eq(forwards.count(), 0)
}
