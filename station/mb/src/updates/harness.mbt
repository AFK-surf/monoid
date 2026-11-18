// The tests' way in (station/test/mb-updates.test.ts, through stillfail-reader `--builder harness-updates`), held to
// the TypeScript of station/src/updates on the same worlds. A line a message both ways, JSON:
// - asked of the program: `{seq, op, …}`, answered `{re: seq, ok: value}` or `{re: seq, err: {kind, fields}}`; each
//   runs as a fiber of its own, so a part waiting on the test goes on as the test asks more;
// - what the program asks of the test's world: `{ask: n, name, args}`, answered `{answer: n, result}` or
//   `{answer: n, threw: {kind, fields}}`; what it tells without waiting: `{say: name, args}`;
// - `op`: "setup" (the words, the language, the machine), "fn" (a function by its TypeScript name), "updates.new" and
//   "updates.call" (the one Updates of the program), "set" (its origin and running turns), "config.set" (the config
//   edited elsewhere), "advance" (the part's clock moved on, each timer due taken in turn with what it set going),
//   "wall.fire" (the machine's timers come due), "watch" (a watched directory changed), "hold"/"letgo", and "sync",
//   answered once nothing here can go on before the test answers.
// Ed25519 is the shell's (`crypto.verify`).

///|
priv struct Harness {
  host : @host.Host
  mut next : Int
  waiting : Map[Int, @effect.Deferred[Result[J, Error]]]
  mut outstanding : Int
  mut answered : @effect.Deferred[Unit]
  mut now : Double
  timers : Array[(Double, Int, @effect.Deferred[Unit])]
  mut timer_seq : Int
  walls : Array[(Int, async () -> Unit)]
  watchers : Array[(Int, String, (String?) -> Unit)]
  mut updates : Updates?
  config : Config
  mut origin : String?
  mut running : Double
  holds : Map[String, () -> Unit]
  fibers : Ref[Fibers?]
}

///|
fn Harness::send(self : Harness, j : J) -> Unit {
  self.host.say(stringify(j))
}

///|
async fn Harness::ask(self : Harness, name : String, args : Array[J]) -> J {
  self.next += 1
  let n = self.next
  let d : @effect.Deferred[Result[J, Error]] = @effect.Deferred::new()
  self.waiting[n] = d
  self.outstanding += 1
  self.send(jo([("ask", ji(n)), ("name", js(name)), ("args", ja(args))]))
  let r = d.wait()
  match r {
    Ok(v) => v
    Err(e) => raise e
  }
}

///|
/// Until nothing here can go on before the test answers (no fiber runnable, nothing asked unanswered).
async fn Harness::quiet(self : Harness) -> Unit {
  while true {
    @effect.pause()
    if self.outstanding > 0 {
      self.answered.wait()
      continue
    }
    if self.host.rt.idle() {
      @effect.pause()
      if self.host.rt.idle() && self.outstanding == 0 {
        break
      }
    }
  }
}

///|
/// The part's clock moved on by `ms`: each timer due taken in its turn, what it set going run before the next.
async fn Harness::advance(self : Harness, ms : Double) -> Unit {
  let target = self.now + ms
  self.quiet()
  while true {
    let mut best = -1
    for i, t in self.timers {
      if t.0 <= target &&
        (best < 0 || t.0 < self.timers[best].0 || (t.0 == self.timers[best].0 && t.1 < self.timers[best].1)) {
        best = i
      }
    }
    if best < 0 {
      break
    }
    let (due, _, d) = self.timers.remove(best)
    if due > self.now {
      self.now = due
    }
    ignore(d.succeed(()))
    self.quiet()
  }
  self.now = target
}

///|
fn Harness::world(self : Harness) -> World {
  {
    ask: (name, args) => self.ask(name, args),
    say_now: (name, args) => self.send(jo([("say", js(name)), ("args", ja(args))])),
    wall_after: async fn(ms, f) {
      let id = self.ask("wall.after", [jn(ms)])
      let n = num(Some(id)).unwrap_or(0.0).to_int()
      self.walls.push((n, f))
      () => match self.walls.search_by(p => p.0 == n) {
        Some(i) => ignore(self.walls.remove(i))
        None => ()
      }
    },
    clock: {
      now: () => self.now,
      sleep: async fn(ms) {
        if ms <= 0.0 {
          return
        }
        self.timer_seq += 1
        let seq = self.timer_seq
        let d : @effect.Deferred[Unit] = @effect.Deferred::new()
        self.timers.push((self.now + ms, seq, d))
        let drop = () => match self.timers.search_by(t => t.1 == seq) {
          Some(i) => ignore(self.timers.remove(i))
          None => ()
        }
        errdefer drop()
        d.wait()
      },
    },
    rt: self.host.rt,
    json_error: async fn(t) { text(Some(self.ask("$json.error", [js(t)]))).unwrap_or("") },
    verify: fn(key, signature, message) {
      let args : Json = {
        "alg": Json::string("Ed25519"),
        "key": Json::string(hex(key)),
        "signature": Json::string(hex(signature)),
        "message": Json::string(hex(message)),
      }
      (try self.host.shell_sync("crypto.verify", args) catch { _ => Json::null() }) is True
    },
    watch: async fn(dir, f) {
      let id = num(Some(self.ask("fs.watch", [js(dir)]))).unwrap_or(0.0).to_int()
      self.watchers.push((id, dir, f))
      fn() {
        match self.watchers.search_by(p => p.0 == id) {
          Some(i) => {
            ignore(self.watchers.remove(i))
            self.send(jo([("say", js("fs.watch.close")), ("args", ja([js(dir)]))]))
          }
          None => ()
        }
      }
    },
    hash_stream: None,
  }
}

///|
fn sarg(args : Array[J], i : Int) -> String {
  if i < args.length() {
    text(Some(args[i])).unwrap_or("")
  } else {
    ""
  }
}

///|
fn oarg(args : Array[J], i : Int) -> String? {
  if i < args.length() {
    text(Some(args[i]))
  } else {
    None
  }
}

///|
fn jarg(args : Array[J], i : Int) -> J {
  if i < args.length() {
    args[i]
  } else {
    Null
  }
}

///|
fn darg(args : Array[J], i : Int) -> Double? {
  if i < args.length() {
    num(Some(args[i]))
  } else {
    None
  }
}

///|
fn strs(j : J) -> Array[String] {
  match j {
    Arr(xs) => xs.filter_map(x => text(Some(x)))
    _ => []
  }
}

///|
fn opt_j(s : String?) -> J {
  jopt(s)
}

///|
fn trusted_of(j : J) -> Array[(String, String)]? {
  match j {
    Arr(xs) =>
      Some(
        xs.filter_map(p => match p {
          Arr([Str(a), Str(b), ..]) => Some((@jsjson.text(a), @jsjson.text(b)))
          _ => None
        }),
      )
    _ => None
  }
}

///|
fn trusted_j(t : Array[(String, String)]) -> J {
  ja(t.map(p => ja([js(p.0), js(p.1)])))
}

///|
fn found_arg(j : J) -> Found {
  found_of(j).unwrap_or({ on_path: "", real: "" })
}

///|
fn node_of(j : J) -> OwnNode? {
  match j {
    Obj(_) =>
      Some({
        version: text(get(Some(j), "version")).unwrap_or(""),
        build: get(Some(j), "build").unwrap_or(Null),
        at: text(get(Some(j), "at")).unwrap_or(""),
        bin: text(get(Some(j), "bin")).unwrap_or(""),
      })
    _ => None
  }
}

///|
fn how_arg(j : J) -> How {
  let h = how_of(j)
  { ..h, node: node_of(get(Some(j), "node").unwrap_or(Null)) }
}

///|
fn header_j(h : Header) -> J {
  let r = (rs : Array[Range]) => ja(rs.map(x => jo([("at", jn(x.at)), ("len", jn(x.len))])))
  jo([
    ("files", jstrs(h.files)),
    ("inflate", r(h.inflate)),
    ("oldSize", jn(h.old_size)),
    ("oldSha256", js(h.old_sha256)),
    ("deflate", r(h.deflate)),
    ("madeSize", jn(h.made_size)),
    ("payload", ji(h.payload)),
  ])
}

///|
fn old_arg(j : J) -> Old {
  match text(get(Some(j), "dir")) {
    Some(d) => Dir(d)
    None => Apk(text(get(Some(j), "apk")).unwrap_or(""))
  }
}

///|
fn plan_arg(j : J) -> Plan {
  let env = match get(Some(j), "env") {
    Some(Obj(ps)) =>
      ps.map(p => (@jsjson.text(p.0), match p.1 { Str(u) => @jsjson.text(u); v => js_string(v) }))
    _ => []
  }
  let delta = match get(Some(j), "delta") {
    Some(Obj(_) as d) =>
      Some({
        from: num(get(Some(d), "from")).unwrap_or(0.0),
        url: text(get(Some(d), "url")).unwrap_or(""),
        sha256: get(Some(d), "sha256").unwrap_or(Null),
        size: num(get(Some(d), "size")).unwrap_or(0.0),
        raw_sha256: get(Some(d), "rawSha256").unwrap_or(Null),
        raw_size: get(Some(d), "rawSize").unwrap_or(Null),
      })
    _ => None
  }
  let archive = match get(Some(j), "archive") {
    Some(Obj(_) as a) =>
      Some(
        (
          text(get(Some(a), "url")).unwrap_or(""),
          get(Some(a), "sha256").unwrap_or(Null),
          num(get(Some(a), "size")).unwrap_or(0.0),
        ),
      )
    _ => None
  }
  {
    release: get(Some(j), "release").unwrap_or(Null),
    script: text(get(Some(j), "script")).unwrap_or(""),
    env,
    delta,
    archive,
  }
}

///|
fn pairs_j(ps : Array[(String, String)]) -> J {
  jo(ps.map(p => (p.0, js(p.1))))
}

///|
fn words_arg(j : J) -> Words {
  Words::of_j(Some(j)).unwrap_or(Text(""))
}

///|
fn words_j(w : Words?) -> J {
  match w {
    Some(x) => x.to_j()
    None => Null
  }
}

///|
/// The deflate the apk's ranges are made with (Node's zlib, the test's).
fn Harness::deflate(self : Harness) -> async (Bytes) -> Bytes {
  async fn(raw) { bytes_of(Some(self.ask("$deflate", [jbytes(raw)]))) }
}

///|
/// A function of the updates by its TypeScript name.
async fn Harness::call_fn(self : Harness, w : World, name : String, a : Array[J]) -> J {
  let fibers = match self.fibers.val {
    Some(f) => f
    None => {
      let f = Fibers::new(w, "updates")
      self.fibers.val = Some(f)
      f
    }
  }
  match name {
    // versions.ts
    "channelOfId" => opt_j(channel_of_id(sarg(a, 0)))
    "feed" => js(feed(sarg(a, 0), sarg(a, 1)))
    "newer" => jb(newer(sarg(a, 0), sarg(a, 1)))
    "versionIn" => opt_j(version_in(sarg(a, 0)))
    "offer" => {
      let (n, d) = offer(oarg(a, 0), oarg(a, 1), sarg(a, 2), sarg(a, 3))
      ja([jb(n), jb(d)])
    }
    "curlPercent" => curl_percent(sarg(a, 0)).map(ji).unwrap_or(Null)
    "tail" => js(tail(sarg(a, 0), sarg(a, 1)))
    "stepOf" => words_j(step_of(sarg(a, 0)))
    "downloading" => {
      let (wd, p) = downloading(sarg(a, 0), darg(a, 1).unwrap_or(0.0), darg(a, 2))
      ja([wd.to_j(), p.map(ji).unwrap_or(Null)])
    }
    "say" => js(say(words_arg(jarg(a, 0)), sarg(a, 1)))
    "sameWords" => jb(same_words(Words::of_j(Some(jarg(a, 0))), Words::of_j(Some(jarg(a, 1)))))
    "platform" => opt_j(platform())
    "channelFrom" => js(channel_from(jarg(a, 0), oarg(a, 1)))
    "releaseChannel" => opt_j(release_channel(w, sarg(a, 0)))
    "releaseChannelSoon" => opt_j(release_channel_soon(w, sarg(a, 0)))
    "channelOf" => js(channel_of(w, jarg(a, 0), sarg(a, 1)))
    "channelOfSoon" => js(channel_of_soon(w, jarg(a, 0), sarg(a, 1)))
    "stationVersion" => opt_j(station_version(w, sarg(a, 0)))
    "stationVersionSoon" => opt_j(station_version_soon(w, sarg(a, 0)))
    "stationDownloadPercent" => station_download_percent(w, sarg(a, 0)).map(ji).unwrap_or(Null)
    // signed.ts
    "keyId" => js(key_id(sarg(a, 0)))
    "trustedKeys" => trusted_j(trusted_keys(oarg(a, 0)))
    "verifySigned" => verify_signed(w, jarg(a, 0), trusted_of(jarg(a, 1)).unwrap_or([]))
    "verifyFeed" => verify_feed(w, jarg(a, 0), trusted_of(jarg(a, 1)).unwrap_or([]))
    "allowed" => jb(allowed(jarg(a, 0), darg(a, 1), sarg(a, 2), oarg(a, 3)))
    "expected" => expected(jarg(a, 0), oarg(a, 1))
    "sha256" => js(sha256(bytes_of(Some(jarg(a, 0)))))
    "hashFile" => {
      let (sum, size) = w.hash_file(sarg(a, 0))
      jo([("sha256", js(sum)), ("size", jn(size))])
    }
    // delta.ts
    "checkPath" => {
      check_path(sarg(a, 0))
      Null
    }
    "parseHeader" => header_j(parse_header(bytes_of(Some(jarg(a, 0)))))
    "apply" => {
      let d = bytes_of(Some(jarg(a, 1)))
      let h = parse_header(d)
      let out = Buffer()
      let sinks = []
      apply(h, bytes_of(Some(jarg(a, 0))), d, fn(b) { out.write_bytes(b); sinks.push(ji(b.length())) }, self.deflate())
      jo([("made", jbytes(out.to_bytes())), ("sinks", ja(sinks))])
    }
    "readOld" => {
      let d = bytes_of(Some(w.call("fs.readFileSync", [js(sarg(a, 1))])))
      jbytes(read_old(w, parse_header(d), old_arg(jarg(a, 0))))
    }
    "applyFile" => {
      apply_file(w, old_arg(jarg(a, 0)), sarg(a, 1), sarg(a, 2), self.deflate())
      Null
    }
    // release.ts
    "readFeed" => {
      let wait : Wait? = if jarg(a, 3) is Bool(true) { Some(async fn(ms) { fibers.sleep(ms) }) } else { None }
      read_feed(w, sarg(a, 0), sarg(a, 1), request_by(w, sarg(a, 2)), wait?)
    }
    "verifiedOrNull" => {
      let (r, why) = verified_or_null(w, jarg(a, 0), trusted_of(jarg(a, 1)))
      jo([("release", r.unwrap_or(Null)), ("why", opt_j(why))])
    }
    "bundledInstaller" => js(bundled_installer(sarg(a, 0), sarg(a, 1)))
    "deltaFor" => match delta_for(jarg(a, 0), jarg(a, 1), oarg(a, 2), darg(a, 3), sarg(a, 4)) {
      Some(d) => d.to_j()
      None => Null
    }
    "planUpdate" => {
      let o = jarg(a, 0)
      let wait : Wait? = if get(Some(o), "wait") is Some(Bool(true)) {
        Some(async fn(ms) { fibers.sleep(ms) })
      } else {
        None
      }
      plan_update(
        w,
        text(get(Some(o), "base")).unwrap_or(""),
        text(get(Some(o), "channel")).unwrap_or(""),
        text(get(Some(o), "app")).unwrap_or(""),
        text(get(Some(o), "installed")).unwrap_or(""),
        text(get(Some(o), "lang")).unwrap_or(""),
        trusted_of(get(Some(o), "trusted").unwrap_or(Null)),
        request_by(w, text(get(Some(o), "request")).unwrap_or("fetch")),
        wait?,
      ).to_j()
    }
    "earlierIn" => {
      let (rs, why) = earlier_in(w, jarg(a, 0), trusted_of(jarg(a, 1)))
      jo([("releases", ja(rs)), ("why", jstrs(why))])
    }
    "backTo" =>
      ja(
        back_to(
          match jarg(a, 0) {
            Arr(xs) => xs
            _ => []
          },
          match jarg(a, 1) {
            Num(n) => Some(n)
            _ => None
          },
          oarg(a, 2),
        ),
      )
    "archiveUrl" => js(archive_url(sarg(a, 0), sarg(a, 1), jarg(a, 2), sarg(a, 3)))
    "planBack" => {
      let o = jarg(a, 0)
      let wait : Wait? = if get(Some(o), "wait") is Some(Bool(true)) {
        Some(async fn(ms) { fibers.sleep(ms) })
      } else {
        None
      }
      plan_back(
        w,
        text(get(Some(o), "base")).unwrap_or(""),
        text(get(Some(o), "channel")).unwrap_or(""),
        text(get(Some(o), "app")).unwrap_or(""),
        text(get(Some(o), "to")).unwrap_or(""),
        text(get(Some(o), "lang")).unwrap_or(""),
        trusted_of(get(Some(o), "trusted").unwrap_or(Null)),
        request_by(w, text(get(Some(o), "request")).unwrap_or("fetch")),
        wait?,
      ).to_j()
    }
    "takeArchive" => {
      let o = jarg(a, 1)
      let signal = Signal::new()
      if get(Some(o), "aborted") is Some(Bool(true)) {
        signal.abort(reason=timed_out())
      }
      let wait : Wait? = if get(Some(o), "wait") is Some(Bool(true)) {
        Some(async fn(ms) { fibers.sleep(ms) })
      } else {
        None
      }
      pairs_j(
        take_archive(
          w,
          plan_arg(jarg(a, 0)),
          signal,
          progress=fn(p) { w.now("takeArchive.progress", [ji(p)]) },
          request_by(w, text(get(Some(o), "request")).unwrap_or("fetch")),
          wait?,
        ),
      )
    }
    "takeDelta" => {
      let o = jarg(a, 1)
      let signal = Signal::new()
      if get(Some(o), "aborted") is Some(Bool(true)) {
        signal.abort(reason=timed_out())
      }
      let wait : Wait? = if get(Some(o), "wait") is Some(Bool(true)) {
        Some(async fn(ms) { fibers.sleep(ms) })
      } else {
        None
      }
      let applier = if get(Some(o), "apply") is Some(Str(u)) && @jsjson.text(u) == "apart" {
        apply_apart(w)
      } else {
        apply_here(w, self.deflate())
      }
      pairs_j(
        take_delta(
          w,
          plan_arg(jarg(a, 0)),
          text(get(Some(o), "app")).unwrap_or(""),
          applier,
          signal,
          progress=fn(p) { w.now("takeDelta.progress", [ji(p)]) },
          request_by(w, text(get(Some(o), "request")).unwrap_or("fetch")),
          wait?,
        ),
      )
    }
    // runtimes.ts
    "kindName" => js(kind_name(sarg(a, 0)))
    "kindCommand" => js(kind_command(sarg(a, 0)))
    "kindPackage" => js(kind_package(sarg(a, 0)))
    "ownNode" => own_node(w, sarg(a, 0), sarg(a, 1)).map(n => n.to_j()).unwrap_or(Null)
    "putOwnNodes" => {
      let env = env_of(jarg(a, 0))
      put_own_nodes(w, env, sarg(a, 1))
      env_j(env)
    }
    "putOwnNodesSoon" => {
      let env = env_of(jarg(a, 0))
      put_own_nodes_soon(w, env, sarg(a, 1))
      env_j(env)
    }
    "removeOwnNodeLinks" => {
      remove_own_node_links(w, env_of(jarg(a, 0)), sarg(a, 1))
      Null
    }
    "pinNpmVersion" => pin_npm_version(how_arg(jarg(a, 0)), sarg(a, 1), sarg(a, 2)).to_j()
    "findCommandSoon" => find_command_soon(w, sarg(a, 0), env_of(jarg(a, 1))).map(f => f.to_j()).unwrap_or(Null)
    "howToUpdateSoon" => how_to_update_soon(w, sarg(a, 0), found_arg(jarg(a, 1)), env_of(jarg(a, 2))).to_j()
    "howToInstallSoon" => how_to_install_soon(w, sarg(a, 0), env_of(jarg(a, 1)), node_of(jarg(a, 2))).to_j()
    "npmInstallSoon" =>
      npm_install_soon(w, env_of(jarg(a, 0)), node_of(jarg(a, 1)), strs(jarg(a, 2)), sarg(a, 3)).to_j()
    "isNpmInstall" => jb(is_npm_install(how_arg(jarg(a, 0))))
    "linkBesideNpm" => jb(link_beside_npm(w, sarg(a, 0), how_arg(jarg(a, 1)), env_of(jarg(a, 2))))
    "runLines" => {
      let (ok, said, code) = run_lines(
        w,
        sarg(a, 0),
        strs(jarg(a, 1)),
        env_of(jarg(a, 2)),
        darg(a, 3).unwrap_or(0.0),
        fn(line) { w.now("runLines.line", [js(line)]) },
        lang=oarg(a, 4).unwrap_or("zh"),
      )
      ja([jb(ok), js(said), code.map(jn).unwrap_or(Null)])
    }
    "run" => {
      let (ok, said) = run(w, sarg(a, 0), strs(jarg(a, 1)), env_of(jarg(a, 2)), darg(a, 3).unwrap_or(0.0), lang=oarg(a, 4).unwrap_or("zh"))
      ja([jb(ok), js(said)])
    }
    // codex-repair.ts
    "hasCodexHostSoon" => jb(has_codex_host_soon(w, sarg(a, 0)))
    "codexBinarySoon" => opt_j(codex_binary_soon(w, found_arg(jarg(a, 0))))
    "missingCodexHost" => missing_codex_host(w, found_arg(jarg(a, 0)), env_of(jarg(a, 1))).map(m => m.to_j()).unwrap_or(Null)
    "findMissingCodexHost" => find_missing_codex_host(w, sarg(a, 0), env_of(jarg(a, 1))).map(m => m.to_j()).unwrap_or(Null)
    "usesCodexHost" => jb(uses_codex_host(sarg(a, 0)))
    "canSwitchCodex" => jb(can_switch_codex(w, found_arg(jarg(a, 0)), env_of(jarg(a, 1))))
    "canSwitchCodexSoon" => jb(can_switch_codex_soon(w, found_arg(jarg(a, 0)), env_of(jarg(a, 1))))
    "switchCodex" | "captureAndSwitch" => {
      let found = found_arg(jarg(a, 0))
      match capture_codex_soon(w, found, env_of(jarg(a, 2))) {
        None => Null
        Some(c) => js(switch_codex(w, c, sarg(a, 1), env_of(jarg(a, 2))))
      }
    }
    "restoreCodex" => {
      restore_codex(w, sarg(a, 0), sarg(a, 1), sarg(a, 2))
      Null
    }
    // agy-download.ts
    "watchAgyDownload" => {
      let o = jarg(a, 0)
      let stop = watch_agy_download(w, {
        manifests: text(get(Some(o), "manifests")).unwrap_or(""),
        build: async fn() { text(Some(w.call("agy.build", []))) },
        staging: async fn(url) { text(Some(w.call("agy.staging", [js(url)]))) },
        after: (ms, f) => fibers.after(ms, f),
        said: fn(version, got, total) { w.now("agy.said", [js(version), jn(got), jn(total)]) },
      })
      self.holds["agy"] = stop
      Null
    }
    "stopAgy" => {
      match self.holds.get("agy") {
        Some(f) => f()
        None => ()
      }
      Null
    }
    // channel.ts
    "setChannelIn" => {
      set_channel_in(w, sarg(a, 0), sarg(a, 1))
      Null
    }
    "setChannel" => {
      set_channel(w, sarg(a, 0), sarg(a, 1), darg(a, 2).unwrap_or(0.0))
      Null
    }
    "channelCommand" => ji(channel_command(w, strs(jarg(a, 0)), sarg(a, 1)))
    "writeWhole" => {
      write_whole(w, sarg(a, 0), sarg(a, 1))
      Null
    }
    "answerChannelAsk" => {
      answer_channel_ask(w, sarg(a, 0), async fn(c) {
        let r = w.call("answer.set", [js(c)])
        ignore(r)
      })
      Null
    }
    // command.ts
    "releaseBaseIn" => opt_j(release_base_in(w, sarg(a, 0)))
    "updateCommand" => ji(update_command(w, strs(jarg(a, 0)), sarg(a, 1), trusted_of(jarg(a, 2)), self.deflate()))
    // holds.ts
    "holding" => ji(holding())
    _ => raise fail("no function \{name}")
  }
}

///|
fn timing_of(j : J) -> Timing {
  let n = (k : String, d : Double) => num(get(Some(j), k)).unwrap_or(d)
  {
    every: n("every", default_timing.every),
    runtime_limit: n("runtimeLimit", default_timing.runtime_limit),
    station_limit: n("stationLimit", default_timing.station_limit),
    done_shown: n("doneShown", default_timing.done_shown),
    follow_look: n("followLook", default_timing.follow_look),
    delta_limit: n("deltaLimit", default_timing.delta_limit),
  }
}

///|
/// A method of the program's Updates by its TypeScript name.
async fn Harness::call_updates(self : Harness, name : String, a : Array[J]) -> J {
  guard self.updates is Some(u) else { raise fail("no updates") }
  match name {
    "get" => ja(u.get(sarg(a, 0)))
    "check" => {
      u.check(station=!(jarg(a, 0) is Bool(false)))
      Null
    }
    "update" => {
      u.update(sarg(a, 0), sarg(a, 1), to?=oarg(a, 2))
      Null
    }
    "resumeAutoForTests" => {
      u.resume_auto_for_tests()
      Null
    }
    "autoAfter" => opt_j(u.auto_after())
    "setAuto" => {
      u.set_auto(jarg(a, 0) is Bool(true), sarg(a, 1))
      Null
    }
    "setChannel" => {
      u.set_channel(sarg(a, 0), sarg(a, 1))
      Null
    }
    "keepChannel" => {
      u.keep_channel(sarg(a, 0))
      Null
    }
    "answerChannelAsk" => {
      u.answer_channel_ask()
      Null
    }
    "missing" => {
      u.missing(sarg(a, 0))
      Null
    }
    "updateOldCodex" => {
      u.update_old_codex(oarg(a, 0), sarg(a, 1))
      Null
    }
    "repairCodex" => {
      u.repair_codex(sarg(a, 0))
      Null
    }
    "start" => {
      u.start()
      Null
    }
    "close" => {
      u.close()
      Null
    }
    "followStarted" => {
      u.follow_started()
      Null
    }
    "toUpdateTo" => opt_j(u.to_update_to())
    "channel" => js(u.channel())
    "auto" => jb(u.auto())
    "installed" => js(u.installed)
    "tried" => opt_j(u.tried)
    "stationWith" => u.station_with(sarg(a, 0), sarg(a, 1))
    "poke" => {
      u.poke(sarg(a, 0), jarg(a, 1))
      Null
    }
    m => raise fail("no method \{m}")
  }
}

///|
async fn Harness::run_op(self : Harness, w : World, c : J) -> J {
  let op = text(get(Some(c), "op")).unwrap_or("")
  let args = match get(Some(c), "args") {
    Some(Arr(xs)) => xs
    _ => []
  }
  match op {
    "setup" => {
      let m = get(Some(c), "machine").unwrap_or(Null)
      set_words(core_json(get(Some(c), "zh").unwrap_or(Null)), core_json(get(Some(c), "en").unwrap_or(Null)))
      set_station_lang(text(get(Some(c), "lang")).unwrap_or("zh"))
      set_path_sep(text(get(Some(c), "sep")).unwrap_or("/"))
      set_env_release_keys(text(get(Some(c), "releaseKeys")))
      set_process(text(get(Some(c), "configEnv")), num(get(Some(c), "pid")).unwrap_or(0.0).to_int())
      self.now = num(get(Some(c), "now")).unwrap_or(0.0)
      let how = (k : String, mark : String) => how_of(get(Some(m), k).unwrap_or(Null), mark~)
      set_machine({
        build_os: text(get(Some(m), "buildOs")),
        arch: text(get(Some(m), "arch")),
        installer_ext: text(get(Some(m), "installerExt")).unwrap_or("sh"),
        codex_standalone: get(Some(m), "codexStandalone") is Some(Bool(true)),
        plat: if text(get(Some(c), "sep")) == Some("\\") { Windows("") } else { Unix },
        claude_install: how("claudeInstall", "claude"),
        agy_install: how("agyInstall", "agy"),
        devin_install: how("devinInstall", "devin"),
        exec_path: text(get(Some(m), "execPath")).unwrap_or(""),
        applier: text(get(Some(m), "applier")).unwrap_or(""),
      })
      Null
    }
    "fn" => self.call_fn(w, text(get(Some(c), "name")).unwrap_or(""), args)
    // (the program's own world: the machine's files and the shell, the rest asked of the test as of Node)
    "host.fn" => {
      let hw = host_world(self.host, (name, a) => self.ask(name, a), (name, a) => self.send(jo([("say", js(name)), ("args", ja(a))])), w.clock, w.watch)
      self.call_fn(hw, text(get(Some(c), "name")).unwrap_or(""), args)
    }
    "updates.new" => {
      let o = get(Some(c), "opts").unwrap_or(Null)
      let s = (k : String) => text(get(Some(o), k)).unwrap_or("")
      self.config.raw = get(Some(o), "config").unwrap_or(jo([]))
      self.origin = text(get(Some(o), "origin"))
      let u = Updates::new(w, {
        app: s("app"),
        data: s("data"),
        config: self.config,
        origin: () => self.origin,
        env: env_of(get(Some(o), "env").unwrap_or(Null)),
        registry: s("registry"),
        devin_manifest: s("devinManifest"),
        claude_releases: s("claudeReleases"),
        agy_manifests: s("agyManifests"),
        node_dist: s("nodeDist"),
        running: () => self.running,
        station_only: get(Some(o), "stationOnly") is Some(Bool(true)),
        timing: timing_of(get(Some(o), "timing").unwrap_or(jo([]))),
        trusted: trusted_of(get(Some(o), "trusted").unwrap_or(Null)),
        node_version: s("nodeVersion"),
      })
      u.on_runtime_changed((kind, installed, replaced) => w.now("opts.runtimeChanged", [
        js(kind),
        jb(installed),
        jb(replaced),
      ]))
      ignore(u.changes(() => w.now("listener.changed", [])))
      self.updates = Some(u)
      Null
    }
    "updates.call" => self.call_updates(text(get(Some(c), "method")).unwrap_or(""), args)
    "set" => {
      match get(Some(c), "origin") {
        Some(Str(u)) => self.origin = Some(@jsjson.text(u))
        Some(Null) => self.origin = None
        _ => ()
      }
      match num(get(Some(c), "running")) {
        Some(n) => self.running = n
        None => ()
      }
      Null
    }
    "config.set" => {
      self.config.raw = get(Some(c), "raw").unwrap_or(jo([]))
      self.config.tell()
      Null
    }
    "advance" => {
      self.advance(num(get(Some(c), "ms")).unwrap_or(0.0))
      Null
    }
    "wall.fire" => {
      let due = self.walls.copy()
      self.walls.clear()
      for p in due {
        (p.1)()
      }
      Null
    }
    "watch" => {
      let dir = text(get(Some(c), "dir")).unwrap_or("")
      let name = text(get(Some(c), "name"))
      for p in self.watchers.copy() {
        if p.1 == dir {
          (p.2)(name)
        }
      }
      Null
    }
    "hold" => {
      self.holds[text(get(Some(c), "id")).unwrap_or("")] = hold()
      Null
    }
    "letgo" => {
      match self.holds.get(text(get(Some(c), "id")).unwrap_or("")) {
        Some(f) => f()
        None => ()
      }
      Null
    }
    "reset" => {
      // (what a case before left waiting stays waiting: its timers are dropped, never come due)
      self.timers.clear()
      self.config.listeners.clear()
      self.walls.clear()
      self.watchers.clear()
      self.updates = None
      self.fibers.val = None
      self.now = num(get(Some(c), "now")).unwrap_or(0.0)
      self.origin = None
      self.running = 0.0
      Null
    }
    "sync" => {
      self.quiet()
      Null
    }
    o => raise fail("no op \{o}")
  }
}

///|
pub async fn harness(host : @host.Host) -> Unit {
  let h : Harness = {
    host,
    next: 0,
    waiting: {},
    outstanding: 0,
    answered: @effect.Deferred::new(),
    now: 0.0,
    timers: [],
    timer_seq: 0,
    walls: [],
    watchers: [],
    updates: None,
    config: Config::new(jo([])),
    origin: None,
    running: 0.0,
    holds: {},
    fibers: Ref(None),
  }
  let w = h.world()
  while true {
    guard host.line() is Some(line) else { break }
    let c = parse(line) catch {
      _ => {
        h.send(jo([("error", js("not JSON"))]))
        continue
      }
    }
    match num(get(Some(c), "answer")) {
      Some(n) => {
        let id = n.to_int()
        match h.waiting.get(id) {
          Some(d) => {
            h.waiting.remove(id)
            h.outstanding -= 1
            match get(Some(c), "threw") {
              Some(t) =>
                ignore(
                  d.succeed(
                    Err(Thrown(text(get(Some(t), "kind")).unwrap_or("Error"), get(Some(t), "fields").unwrap_or(jo([])))),
                  ),
                )
              None => ignore(d.succeed(Ok(get(Some(c), "result").unwrap_or(Null))))
            }
            let was = h.answered
            h.answered = @effect.Deferred::new()
            ignore(was.succeed(()))
          }
          None => ()
        }
        continue
      }
      None => ()
    }
    let seq = get(Some(c), "seq").unwrap_or(Null)
    ignore(
      host.rt.fork(async fn() {
        let r = (try Ok(h.run_op(w, c)) catch { e => Err(e) })
        match r {
          Ok(v) => h.send(jo([("re", seq), ("ok", v)]))
          Err(e) => h.send(jo([("re", seq), ("err", error_j(e))]))
        }
      }),
    )
  }
}
