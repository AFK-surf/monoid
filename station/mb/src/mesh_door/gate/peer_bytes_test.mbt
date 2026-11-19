// A request's bytes (peer.mbt `peer_call` with a body) whose sending fails once the answer came: kept by the request,
// never the runtime's defect.

///|
fn bytes_keeper() -> @gate.Keeper {
  @gate.Keeper::asking(
    async fn(name, _args) {
      match name {
        "peersCurrent" | "hasState" => Json::boolean(true)
        "home" => Json::string("w1")
        "station" => Json::string("a")
        "memberOf" => { "workspace": "w1", "peers": [{ "id": "b" }] }
        "membersAll" => [{ "workspace": "w1", "peers": [{ "id": "b" }] }]
        "unprotected" => []
        _ => Json::null()
      }
    },
    () => 0L,
    { oldest_core: 0, counted_from: 0, moved_from: 0, root_out_from: 0, logs_before: 0, logs_any_from: 0 },
    (_m, _k, _s) => false,
    @gate.SeenDevices::new(None, _ => ()),
    _ => () => (),
    _ => () => (),
  )
}

///|
/// Station `b` on the far end of `conn`: each request's head read, answered at once, its bytes never read.
fn answers_at_once(rt : @effect.Runtime, conn : @door.Connection) -> Unit {
  ignore(rt.fork(() => {
    while (conn.accept_bi)() is Some(s) {
      let reader = @door.Reader::new(s)
      ignore(reader.line())
      @door.write_line(s, { "result": { "ok": true } })
      (s.finish)()
    }
  } catch { _ => () }))
}

///|
/// A body whose first piece fails at its source once `gate` is done.
fn failing_body(gate : @effect.Deferred[Unit]) -> @gate.Body {
  {
    next: async fn() {
      gate.wait()
      raise Failure("the source went")
    },
    stop: async fn() { () },
    check: None,
  }
}

///|
fn bytes_call(rt : @effect.Runtime) -> @gate.StationCall {
  let (a, b) = @door.pair("a", "b", alpn=@gate.peer_bytes_alpn)
  answers_at_once(rt, b)
  let dialing : @gate.Dialing = {
    connect: async fn(_t, _ws, _given_up) { a },
    hold: None,
    goes_off: None,
    relays_changed: None,
  }
  @gate.peer_call(bytes_keeper(), dialing, rt)
}

///|
test "a request's bytes failing after its answer came: the answer given, no defect" {
  let rt = @effect.Runtime::new()
  let defects : Array[String] = []
  rt.on_defect(e => defects.push(@gate.words_of(e)))
  let station = bytes_call(rt)
  let gate : @effect.Deferred[Unit] = @effect.Deferred::new()
  let said = []
  ignore(rt.fork(() => {
    let (result, _) = (station.call)("b", None, { "method": "upload" }, Some(failing_body(gate)))
    said.push(result.stringify())
  } catch { e => said.push("failed: " + @gate.words_of(e)) }))
  ignore(rt.run_ready())
  assert_eq(said, ["{\"ok\":true}"])
  // The bytes fail now, nothing waiting on them.
  ignore(gate.succeed(()))
  ignore(rt.run_ready())
  rt.advance(@gate.bytes_idle_ms)
  assert_eq(defects, [])
}

///|
test "a request's bytes failing before its answer: the request fails, no defect" {
  let rt = @effect.Runtime::new()
  let defects : Array[String] = []
  rt.on_defect(e => defects.push(@gate.words_of(e)))
  let (a, b) = @door.pair("a", "b", alpn=@gate.peer_bytes_alpn)
  // Station `b` reads the head and never answers.
  ignore(rt.fork(() => {
    while (b.accept_bi)() is Some(s) {
      ignore(@door.Reader::new(s).line())
    }
  } catch { _ => () }))
  let dialing : @gate.Dialing = {
    connect: async fn(_t, _ws, _given_up) { a },
    hold: None,
    goes_off: None,
    relays_changed: None,
  }
  let station = @gate.peer_call(bytes_keeper(), dialing, rt)
  let gate : @effect.Deferred[Unit] = @effect.Deferred::new()
  ignore(gate.succeed(()))
  let said = []
  ignore(rt.fork(() => {
    let (result, _) = (station.call)("b", None, { "method": "upload" }, Some(failing_body(gate)))
    said.push(result.stringify())
  } catch { e => said.push("failed: " + @gate.words_of(e)) }))
  ignore(rt.run_ready())
  // (its stream reset as its bytes failed: the answer's wait fails with it, as before)
  assert_eq(said, ["failed: stream reset (2)"])
  assert_eq(defects, [])
}

///|
test "a peer's connection lost as a stream is awaited: serve_peer fails with it, no defect" {
  let rt = @effect.Runtime::new()
  let defects : Array[String] = []
  rt.on_defect(e => defects.push(@gate.words_of(e)))
  let (a, _b) = @door.pair("a", "b", alpn=@gate.peer_alpn)
  // (the front's stream accepted on a connection that went: its accept fails, as `FrontStream`'s does)
  let lost : @door.Connection = { ..a, accept_bi: fn() raise { raise @door.WireError("connection lost") } }
  let said = []
  ignore(rt.fork(() => {
    @gate.serve_peer(bytes_keeper(), lost, @gate.PeerBus::new())
    said.push("returned")
  } catch { e => said.push("failed: " + @gate.words_of(e)) }))
  ignore(rt.run_ready())
  assert_eq(said, ["failed: connection lost"])
  assert_eq(defects, [])
}
