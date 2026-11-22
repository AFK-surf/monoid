// The wire and the door on connections in memory, on the test's clock.

///|
fn text(b : Bytes) -> String {
  @utf8.decode_lossy(b)
}

///|
/// Runs `f` on a runtime of the test's, the clock moved on `ms` after it is set going.
fn on_clock(ms : Int, f : async (@effect.Runtime) -> Unit) -> Array[String] {
  let rt = @effect.Runtime::new()
  let errors = []
  ignore(rt.fork(() => f(rt) catch { e => errors.push(@door.message_of(e)) }))
  ignore(rt.run_ready())
  rt.advance(ms)
  errors
}

///|
test "a line comes in pieces, the rest after it stays for the body" {
  let said = []
  let errors = on_clock(0, rt => {
    let (a, b) = @door.pair("dev", "station")
    ignore(rt.fork(() => {
      let s = (a.open_bi)()
      (s.write)(b"{\"met")
      (s.write)(b"hod\":\"GET\"}\nbo")
      (s.write)(b"dy")
      (s.finish)()
    }))
    let s = (b.accept_bi)().unwrap()
    let r = @door.Reader::new(s)
    said.push(r.line().unwrap().stringify())
    said.push(text(r.rest()))
  })
  assert_eq(errors, [])
  assert_eq(said, ["{\"method\":\"GET\"}", "body"])
}

///|
test "a line past the head's bound is refused" {
  let errors = on_clock(0, _ => {
    let (a, b) = @door.pair("dev", "station")
    let s = (a.open_bi)()
    (s.write)(Bytes::make(@door.max_head + 2, b'a'))
    let r = @door.Reader::new((b.accept_bi)().unwrap())
    ignore(r.line())
  })
  assert_eq(errors, ["head too large"])
}

///|
test "a whole answer says its length unless compressed; one that comes ends as its chunks do" {
  let got = []
  let errors = on_clock(0, rt => {
    let (a, b) = @door.pair("dev", "station")
    let s = (a.open_bi)()
    let t = (b.accept_bi)().unwrap()
    @door.send(t, { status: 200, headers: [("content-type", "application/json")], body: Whole(b"{}") })
    (t.finish)()
    got.push(text(@door.Reader::new(s).rest()))
    let s2 = (a.open_bi)()
    let t2 = (b.accept_bi)().unwrap()
    let left = ["a", "b"]
    let stopped = Ref(false)
    ignore(rt.fork(() => {
      @door.send(t2, {
        status: 200,
        headers: [("content-type", "text/event-stream")],
        body: Coming({
          next: () => if left.length() > 0 { Some(@utf8.encode(left.remove(0))) } else { None },
          stop: () => stopped.val = true,
        }),
      })
      (t2.finish)()
    }))
    got.push(text(@door.Reader::new(s2).rest()))
    got.push(stopped.val.to_string())
  })
  assert_eq(errors, [])
  assert_eq(got, [
    "{\"status\":200,\"headers\":{\"content-type\":\"application/json\",\"content-length\":\"2\"}}\n{}",
    "{\"status\":200,\"headers\":{\"content-type\":\"text/event-stream\"}}\nab",
    "true",
  ])
}

///|
fn let_in(renew : async (Json) -> Json, served : Array[String]) -> @door.Admit {
  (hello, _) => if hello is { "credential": "good", .. } {
    Let({
      line: { "ok": true },
      opened: () => served.push("opened"),
      renew,
      stream: () => Some(asked => {
        served.push(asked.head.stringify())
        @door.write_line(asked.stream, { "status": 200 })
        (asked.stream.finish)()
      }),
      ended: () => served.push("ended"),
    })
  } else {
    Refused({ line: { "error": "no" }, code: 1, reason: "credential_refused", error: Failure("refused") })
  }
}

///|
test "a hello let in: its line answered, renewals answered, a request a stream" {
  let served = []
  let heard = []
  let errors = on_clock(1000, rt => {
    let (dev, st) = @door.pair("dev", "station")
    ignore(rt.fork(() => @door.door(st, let_in(line => if line is { "credential": "fail", .. } { raise @door.DoorError("bad renewal") } else { { "ok": true, "renewed": true } }, served))))
    let control = (dev.open_bi)()
    @door.write_line(control, { "credential": "good" })
    let r = @door.Reader::new(control)
    heard.push(r.line().unwrap().stringify())
    @door.write_line(control, { "credential": "again" })
    heard.push(r.line().unwrap().stringify())
    @door.write_line(control, { "credential": "fail" })
    heard.push(r.line().unwrap().stringify())
    let s = (dev.open_bi)()
    @door.write_line(s, { "method": "GET", "path": "/x" })
    (s.finish)()
    heard.push(text(@door.Reader::new(s).rest()))
    (dev.close)(0, "done")
  })
  assert_eq(errors, [])
  assert_eq(heard, [
    "{\"ok\":true}", "{\"ok\":true,\"renewed\":true}", "{\"error\":\"bad renewal\"}", "{\"status\":200}\n",
  ])
  assert_eq(served, ["opened", "{\"method\":\"GET\",\"path\":\"/x\"}", "ended"])
}

///|
test "a hello refused: its line reaches the other end, the connection closed with its code and reason after REFUSED_CLOSE_MS" {
  let heard = []
  let rt = @effect.Runtime::new()
  let (dev, st) = @door.pair("dev", "station")
  let door_ended = Ref("")
  ignore(rt.fork(() => @door.door(st, let_in(_ => Json::null(), [])) catch { e => door_ended.val = @door.message_of(e) }))
  ignore(rt.fork(() => {
    let control = (dev.open_bi)()
    @door.write_line(control, { "credential": "bad" })
    heard.push(@door.Reader::new(control).line().unwrap().stringify())
  } catch { _ => () }))
  ignore(rt.run_ready())
  assert_eq(heard, ["{\"error\":\"no\"}"])
  assert_eq(@door.closed_with(dev), None)
  rt.advance(@door.refused_close_ms - 1)
  assert_eq(@door.closed_with(dev), None)
  rt.advance(1)
  assert_eq(@door.closed_with(dev), Some(("application", "credential_refused")))
  assert_eq(door_ended.val, "refused")
}

///|
test "a renewal that ends the connection: answered its line, later streams reset, closed after REFUSED_CLOSE_MS" {
  let heard = []
  let rt = @effect.Runtime::new()
  let (dev, st) = @door.pair("dev", "station")
  let door_ended = Ref("")
  let renew : async (Json) -> Json = _ => raise @door.ending("revoked", 3, "credential_revoked")
  ignore(rt.fork(() => @door.door(st, let_in(renew, [])) catch { e => door_ended.val = @door.message_of(e) }))
  ignore(rt.fork(() => {
    let control = (dev.open_bi)()
    @door.write_line(control, { "credential": "good" })
    let r = @door.Reader::new(control)
    heard.push(r.line().unwrap().stringify())
    @door.write_line(control, { "credential": "again" })
    heard.push(r.line().unwrap().stringify())
    let s = (dev.open_bi)()
    @door.write_line(s, { "method": "GET", "path": "/y" })
    heard.push(try { (s.read)().map(text).unwrap_or("end") } catch { e => @door.message_of(e) })
  } catch { _ => () }))
  ignore(rt.run_ready())
  assert_eq(heard, ["{\"ok\":true}", "{\"error\":\"revoked\"}", "stream reset (0)"])
  rt.advance(@door.refused_close_ms)
  assert_eq(@door.closed_with(dev), Some(("application", "credential_revoked")))
  assert_eq(door_ended.val, "revoked")
}

///|
test "compressed stream compresses +json, calls finish once on normal EOF (including empty), never on stop or error" {
  let log = []
  let packer : @door.Packer = {
    whole: async fn(b, _) { b },
    stream: async fn() {
      {
        push: async fn(b) {
          log.push("push:" + text(b))
          b
        },
        finish: async fn() {
          log.push("finish")
          b"<END>"
        },
        close: () => log.push("close"),
      }
    },
  }
  let asks = [("accept-encoding", "zstd")]
  let batch_lines = ["application/vnd.stillfail.batch-lines+json"]
  let errors = on_clock(0, _ => {
    // 0. Arbitrary +json is NOT compressed; only explicit extra_types are.
    let other = @door.compressed(
      packer,
      {
        status: 200,
        headers: [("content-type", "application/problem+json")],
        body: Coming({ next: async fn() { None }, stop: () => () }),
      },
      asks,
      "/batch",
      extra_types=batch_lines,
    )
    assert_eq(@door.header_of(other.headers, "content-encoding"), None)
    // 1. Non-empty explicit batch-lines stream: compressed, finish called once on EOF, tail emitted, then closed.
    let items = [b"a\n", b"b\n"]
    let ans = @door.compressed(
      packer,
      {
        status: 200,
        headers: [("content-type", "application/vnd.stillfail.batch-lines+json")],
        body: Coming({
          next: async fn() { if items.length() > 0 { Some(items.remove(0)) } else { None } },
          stop: () => log.push("src_stop"),
        }),
      },
      asks,
      "/batch",
      extra_types=batch_lines,
    )
    assert_eq(@door.header_of(ans.headers, "content-encoding"), Some("zstd"))
    match ans.body {
      Coming(c) => {
        let got = []
        while (c.next)() is Some(p) {
          got.push(text(p))
        }
        // Second EOF call is a no-op; finish is not called again.
        assert_eq((c.next)(), None)
        assert_eq(got, ["a\n", "b\n", "<END>"])
      }
      Whole(_) => fail("expected Coming")
    }
    // 2. Empty stream: finish still called once on normal EOF.
    log.push("---")
    let empty_ans = @door.compressed(
      packer,
      {
        status: 200,
        headers: [("content-type", "application/vnd.stillfail.batch-lines+json")],
        body: Coming({ next: async fn() { None }, stop: () => () }),
      },
      asks,
      "/batch",
      extra_types=batch_lines,
    )
    match empty_ans.body {
      Coming(c) => {
        assert_eq((c.next)().map(text), Some("<END>"))
        assert_eq((c.next)(), None)
      }
      Whole(_) => fail("expected Coming")
    }
    // 3. Cancelled stream: stop closes without calling finish.
    log.push("---")
    let cancel_ans = @door.compressed(
      packer,
      {
        status: 200,
        headers: [("content-type", "application/vnd.stillfail.batch-lines+json")],
        body: Coming({ next: async fn() { Some(b"x\n") }, stop: () => log.push("cancel_stop") }),
      },
      asks,
      "/batch",
      extra_types=batch_lines,
    )
    match cancel_ans.body {
      Coming(c) => {
        assert_eq((c.next)().map(text), Some("x\n"))
        (c.stop)()
        assert_eq((c.next)(), None)
      }
      Whole(_) => fail("expected Coming")
    }
    // 4. Errored source: closes without calling finish.
    log.push("---")
    let fail_ans = @door.compressed(
      packer,
      {
        status: 200,
        headers: [("content-type", "application/x-ndjson")],
        body: Coming({ next: async fn() { raise @door.WireError("boom") }, stop: () => () }),
      },
      asks,
      "/batch",
    )
    match fail_ans.body {
      Coming(c) => {
        let mut threw = false
        ignore((c.next)()) catch { _ => threw = true }
        assert_eq(threw, true)
      }
      Whole(_) => fail("expected Coming")
    }
  })
  assert_eq(errors, [])
  assert_eq(log, [
    "push:a\n", "push:b\n", "finish", "close",
    "---",
    "finish", "close",
    "---",
    "push:x\n", "close", "cancel_stop",
    "---",
    "close",
  ])
}

///|
test "compressed stream returns None without emitting bytes if stopped during push or finish" {
  let rt = @effect.Runtime::new()
  let push_gate : @effect.Deferred[Unit] = @effect.Deferred::new()
  let finish_gate : @effect.Deferred[Unit] = @effect.Deferred::new()
  let push_res : Ref[String] = Ref("unset")
  let finish_res : Ref[String] = Ref("unset")
  let batch_lines = ["application/vnd.stillfail.batch-lines+json"]
  let asks = [("accept-encoding", "zstd")]
  let packer : @door.Packer = {
    whole: async fn(b, _) { b },
    stream: async fn() {
      {
        push: async fn(b) {
          push_gate.wait()
          b
        },
        finish: async fn() {
          finish_gate.wait()
          b"<END>"
        },
        close: () => (),
      }
    },
  }
  ignore(rt.fork(() => {
    let ans = @door.compressed(
      packer,
      {
        status: 200,
        headers: [("content-type", "application/vnd.stillfail.batch-lines+json")],
        body: Coming({ next: () => Some(b"chunk"), stop: () => () }),
      },
      asks,
      "/batch",
      extra_types=batch_lines,
    )
    match ans.body {
      Coming(c) => {
        ignore(rt.fork(() => {
          push_res.val = match (c.next)() { Some(b) => text(b); None => "none" }
        }))
        (c.stop)()
        ignore(push_gate.succeed(()))
      }
      Whole(_) => ()
    }
  } catch { _ => () }))
  ignore(rt.fork(() => {
    let ans = @door.compressed(
      packer,
      {
        status: 200,
        headers: [("content-type", "application/vnd.stillfail.batch-lines+json")],
        body: Coming({ next: () => None, stop: () => () }),
      },
      asks,
      "/batch",
      extra_types=batch_lines,
    )
    match ans.body {
      Coming(c) => {
        ignore(rt.fork(() => {
          finish_res.val = match (c.next)() { Some(b) => text(b); None => "none" }
        }))
        (c.stop)()
        ignore(finish_gate.succeed(()))
      }
      Whole(_) => ()
    }
  } catch { _ => () }))
  ignore(rt.run_ready())
  assert_eq(push_res.val, "none")
  assert_eq(finish_res.val, "none")
}
