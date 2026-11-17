// process.ts: a runtime process under a runner as the drivers find, end and take one up. Its lines are read by the
// program's reader (`--sessions`); what a driver needs of the runner itself is here: its id, how its exit is said, one
// left by an earlier station ended, up to where the station before acknowledged, and its output read again.

///|
/// How an exit is said (`describeExit`): its code, or the signal's name.
pub fn describe_exit(code : Int?, signal : String?) -> String {
  match code {
    Some(c) => c.to_string()
    None =>
      match signal {
        Some(sig) if ["TERM", "KILL", "INT", "HUP"].contains(sig) => "SIG\{sig}"
        Some(sig) => "signal \{sig}"
        None => "unknown"
      }
  }
}

///|
/// A runner of this id that keeps its process still (`findRunner`).
pub fn find_runner(m : Machine, data : String, id : String) -> Later[RunnerInfo?] {
  runner_of(m, data, id).bind(found => match found {
    Some(info) if info.id() == id =>
      listening_soon(m, info).map(yes => if yes { Some(info) } else { None })
    _ => Later::ok(m.lp, None)
  })
}

///|
/// A runner's output file (`outFile`).
pub fn out_file(m : Machine, data : String, id : String) -> String {
  m.join([runners_dir(m, data), "\{id}.out"])
}

///|
/// `Promise.race([a, sleep(ms)])`.
pub fn race_sleep(m : Machine, a : Later[Exit], ms : Double) -> Later[Unit] {
  let out = Later::new(m.lp)
  a.on(_ => out.resolve(()))
  m.sleep(ms).on(_ => out.resolve(()))
  out
}

///|
/// Ends a runner of this id an earlier station left, waiting for it to go: `only` that runner (`endRunner`). Whether
/// there was one to end.
pub fn end_runner(
  m : Machine,
  data : String,
  id : String,
  label : String,
  only? : RunnerInfo,
) -> Later[Bool] {
  find_runner(m, data, id).bind(found => {
    guard found is Some(info) else { return Later::ok(m.lp, false) }
    match only {
      Some(o) if info.runner() != o.runner() || info.started_at() != o.started_at() =>
        return Later::ok(m.lp, false)
      _ => ()
    }
    m.log(
      "warn",
      "agents::process",
      "ending a runtime process left by a previous run",
      obj([("label", s(label)), ("runner", n(info.runner())), ("pgid", n(info.pgid()))]),
    )
    listening_soon(m, info)
    .bind(listening => {
      if !listening {
        return done(m.lp)
      }
      let conn = RunnerConnection::open(m, info, (_, _, _, _) => done(m.lp))
      conn.signal("TERM", group=true)
      race_sleep(m, conn.exited, 2000.0)
      .bind(_ => {
        if m.group_alive(info.pgid()) {
          conn.signal("KILL", group=true)
        }
        race_sleep(m, conn.exited, 1000.0)
      })
      .map(_ => conn.finish())
    })
    .bind(_ => wait_gone(m, info.runner(), 300))
    .map(_ => true)
  })
}

///|
/// Up to `tries` looks 10 ms apart until `pid` is gone.
pub fn wait_gone(m : Machine, pid : Int, tries : Int) -> Later[Unit] {
  if tries <= 0 || !m.pid_alive(pid) {
    return done(m.lp)
  }
  m.sleep(10.0).bind(_ => wait_gone(m, pid, tries - 1))
}

///|
/// Where the runner will start sending stdout from, and where the station before kept (`ackedOffset`): asked by
/// attaching once without acknowledging anything.
pub fn acked_offset(m : Machine, info : RunnerInfo, out : String) -> Later[(Int, Int?)] {
  let result = Later::new(m.lp)
  let carry = Ref("")
  let finished = Ref(false)
  let ending = Ref(false)
  let quiet : Ref[() -> Unit] = Ref(() => ())
  let sock : Ref[Socket?] = Ref(None)
  let finish = (at : Int, keep : Int?) => {
    if !finished.val {
      finished.val = true
      (quiet.val)()
      match sock.val {
        Some(so) => (so.destroy)()
        None => ()
      }
      result.resolve((at, keep))
    }
  }
  let size = () => m.size(out).map(v => v.unwrap_or(0)).recover(_ => Later::ok(m.lp, 0))
  let at_end = () => if !finished.val && !ending.val {
    ending.val = true
    (quiet.val)()
    size().on(r => match r {
      Ok(end) => finish(end, None)
      Err(_) => finish(0, None)
    })
  }
  let socket = m.connect(info.socket(), {
    connected: () => match sock.val {
      Some(so) => (so.write)(json_text(obj([("op", s("attach"))])) + "\n")
      None => ()
    },
    data: chunk => {
      if ending.val {
        return
      }
      carry.val = carry.val + chunk
      while true {
        guard carry.val.find("\n") is Some(i) else { break }
        let text = carry.val.substring(end=i)
        carry.val = carry.val.substring(start=i + 1)
        guard parse_json(text) is Some(message) else { continue }
        let op = str_at(Some(message), "op")
        if op == Some("attached") && safe_integer(get(Some(message), "out")) {
          let o = num_at(Some(message), "out").unwrap().to_int()
          let keep = if safe_integer(get(Some(message), "keep")) {
            let k = num_at(Some(message), "keep").unwrap().to_int()
            Some(if k < o { k } else { o })
          } else {
            None
          }
          finish(o, keep)
          return
        }
        if op == Some("out") && str_at(Some(message), "stream") == Some("out") {
          finish(num_at(Some(message), "at").unwrap_or(0.0).to_int(), None)
          return
        }
        if op == Some("exit") {
          at_end()
          return
        }
      }
    },
    error: _ => at_end(),
    closed: () => (),
  })
  sock.val = Some(socket)
  quiet.val = m.lp.after(400.0, () => size().on(r => {
    let end = match r {
      Ok(e) => e
      Err(_) => 0
    }
    if !finished.val && !ending.val {
      quiet.val = m.lp.after(150.0, () => finish(end, None))
    }
  }))
  result
}

///|
/// How much of a runner's output `bytes_within` holds at once.
let read_chunk = 1048576

///|
/// The lines of a runner's output from `start` to `end` as bytes, each with where it begins (`bytesWithin`): where
/// the runner gave the disk back (zeros) skipped with the line it cut, a line's carriage return left off.
pub fn bytes_within(
  m : Machine,
  file : String,
  start : Int,
  end : Int,
  chunk? : Int = read_chunk,
) -> Later[Array[(Bytes, Int)]] {
  let found : Array[(Bytes, Int)] = []
  if end <= start {
    return Later::ok(m.lp, found)
  }
  let lines = Lines::new()
  let at = Ref(start)
  let base = Ref(start)
  fn go() -> Later[Array[(Bytes, Int)]] {
    if at.val >= end {
      return Later::ok(m.lp, found)
    }
    let want = if chunk < end - at.val { chunk } else { end - at.val }
    m
    .read_at(file, at.val, want)
    .bind(buf => {
      let got = buf.length()
      if got <= 0 {
        return Later::ok(m.lp, found)
      }
      let mut skip = 0
      if buf[0] == b'\x00' {
        while skip < got && buf[skip] == b'\x00' {
          skip += 1
        }
        lines.drop()
        base.val = at.val + skip
      }
      at.val += got
      for line in lines.take(buf[skip:got]) {
        let line_at = base.val
        base.val += line.length() + 1
        let cut = if line.length() > 0 && line[line.length() - 1] == b'\r' {
          line[0:line.length() - 1].to_owned()
        } else {
          line
        }
        found.push((cut, line_at))
      }
      go()
    })
  }

  go()
}
