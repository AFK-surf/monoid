// What station/test/mb-station-e2e.test.ts asks of station_main's parts one at a time (the reader's `--builder
// harness-station-main`): a line a call, `{"id", "op", …}`, answered `{"id", "ok"}` or `{"id", "error"}`.
// - "prepareLocalLinks" {text, paths, workspace}: local.rs `prepare_local_links` on this machine's files;
// - "thumbnail" {image, dir}, "thumbhash" {image, dir?}: the drive's codecs;
// - "machine", "lanAddrs", "diskOf" {path}, "env" {name}, "envSet" {name, value}, "platform", "wallMs", "hostname",
//   "homedir", "tmpdir", "parentPid", "pidAlive" {pid}, "processUsage" {pids}: what sys.c says of the machine;
// - "spawn" {program, args, env?, cwd?, input?, group?, stdout?, stderr?}: a child run to its end ({code, signal,
//   stdout, stderr}), what it is given written on its stdin; "kill" {pid, signal, group};
// - "fileLock" {path}: the lock taken ({handle}), "fileUnlock" {handle};
// - "words": the catalogs the program carries; "iso" {ms}: an instant as toISOString says it;
// - "launcherEventLine" {line}, "launcherEvents" {data}: what the launcher kept, as launcher_events.mbt says it;
// - "loopback" {path, query, ready, place, lang}: what the loopback port says;
// - "p5_5" {step, …}: P5-5's live parts on a data directory of the test's (live_p5_5_harness.mbt);
// - "saidOf" {key, lang}, "log" {level, at, message}, "noted" {text}, "treeBytes" {program, path}, "helperEvict"
//   {dir}, "helperRequest" {program, app, dir, launch, ask}, "requestedCloseInFlight" {data, program, said}: what
//   station/test/mb-live-canary-fixes.test.ts holds of the parts live canaries found wrong;
// - "pipeTcpLost": a member's stream handed to a slice as a connection of 127.0.0.1 (live_p5_1_local.mbt
//   `shell_handle`) whose stream is lost after its first bytes; "driverErrors": the accounts' failures as the drivers
//   are given them (live_p5_2_io.mbt `driver_error_of`); "claudeLogins": what Claude's logins ask of the accounts
//   (live_p5_2_drivers.mbt `p52_claude_logins`), each with the token refused: the same test's too;
// - "fsOp" {name, args}: what the conversations' `fs.*` answers (live_p5_2_chats.mbt `host_fs_op`: `{ok}`, or
//   `{code, message}` as it throws); "repoWalk" {root, file}: the repositories' index walking `root` through it,
//   with whether each folder's listing let the program's other fibers run while it waited (never on its thread);
// - "watchDir" {dir, every}: a directory followed as the shared skills' logins are (live_p5_3_share.mbt
//   `p53_watch_dir`, looked at every `every` ms), answered with its handle once its first look is done; "watchDirSaid" {handle, count}: what it told once it
//   told `count` things (each a name changed, `"?"` for none, `"!failed"`); "watchDirClose" {handle}: let go, answered
//   once its fiber ended.

///|
pub async fn harness(host : @host.Host) -> Unit {
  let locks : Map[Int, FileLock] = Map([])
  let mut next_lock = 0
  while host.line() is Some(line) {
    if line == "" {
      continue
    }
    let ask = attempt(() => @json.parse(line)).unwrap_or(Json::null())
    let id = match ask {
      Object(m) => m.get("id").unwrap_or(Json::null())
      _ => Json::null()
    }
    let s = (k : String) => match ask {
      Object(m) =>
        match m.get(k) {
          Some(String(v)) => v
          _ => ""
        }
      _ => ""
    }
    let v = (k : String) => match ask {
      Object(m) => m.get(k)
      _ => None
    }
    let strs = (k : String) => match v(k) {
      Some(Array(xs)) => xs.filter_map(x => match x { String(t) => Some(t); _ => None })
      _ => []
    }
    let op = s("op")
    let answer : Result[Json, String] = match op {
      "prepareLocalLinks" =>
        match prepare_local_links(s("text"), strs("paths"), s("workspace")) {
          Ok((text, paths)) => Ok({ "text": Json::string(text), "paths": Json::array(paths.map(x => Json::string(x))) })
          Err(why) => Err(why)
        }
      "thumbnail" =>
        Ok(
          match thumbnail(s("image"), s("dir")) {
            Some(t) => { "path": Json::string(t.path), "type": Json::string(t.type_) }
            None => Json::null()
          },
        )
      "preview" =>
        Ok(
          match preview(s("image"), s("dir")) {
            Some(t) => { "path": Json::string(t.path), "type": Json::string(t.type_) }
            None => Json::null()
          },
        )
      "thumbhash" =>
        Ok(
          match thumbhash(s("image"), match v("dir") { Some(String(d)) => Some(d); _ => None }) {
            Some((hash, w, h)) => { "hash": Json::string(hash), "width": Json::number(w), "height": Json::number(h) }
            None => Json::null()
          },
        )
      // (a part's route matched as the admin API matches it: live_p5_1_admin.mbt)
      "partRoute" => Ok(part_route_match(s("pattern"), s("path")).unwrap_or(Json::null()))
      "machine" => Ok(machine())
      "lanAddrs" => Ok(Json::array(lan_addrs()))
      "diskOf" =>
        Ok(
          match disk_of(s("path")) {
            Some((f, t)) => { "free": Json::number(f), "total": Json::number(t) }
            None => Json::null()
          },
        )
      "env" =>
        Ok(
          match env_get(s("name")) {
            Some(e) => Json::string(e)
            None => Json::null()
          },
        )
      "envSet" => {
        env_set(s("name"), s("value"))
        Ok(Json::null())
      }
      "platform" => Ok({ "platform": Json::string(platform()), "arch": Json::string(arch()) })
      "wallMs" => Ok(Json::number(wall_ms().to_double()))
      "hostname" => Ok(Json::string(hostname()))
      "homedir" => Ok(Json::string(homedir()))
      "tmpdir" => Ok(Json::string(tmpdir()))
      "parentPid" => Ok(Json::number(parent_pid().to_double()))
      "pidAlive" =>
        Ok(Json::boolean(match v("pid") { Some(Number(p, ..)) => pid_alive(p.to_int()); _ => false }))
      "processUsage" => {
        let pids = match v("pids") {
          Some(Array(xs)) => xs.filter_map(x => match x { Number(p, ..) => Some(p.to_int()); _ => None })
          _ => []
        }
        Ok(Json::array(process_usage(pids).map(u => u.unwrap_or(Json::null()))))
      }
      "spawn" => {
        let sink = (k : String) => match v(k) {
          Some(String("pipe")) | None => Piped
          Some(String("ignore")) => Ignored
          Some(String(file)) => Appended(file)
          _ => Piped
        }
        let env = match v("env") {
          Some(Object(m)) => Some(m.iter().filter_map(kv => match kv.1 { String(t) => Some((kv.0, t)); _ => None }).collect())
          _ => None
        }
        let input = v("input")
        let spawned = try {
          Ok(
            spawn(
              host,
              s("program"),
              strs("args"),
              env?=env,
              cwd?=match v("cwd") { Some(String(c)) => Some(c); _ => None },
              stdin_piped=input is Some(String(_)),
              stdout=sink("stdout"),
              stderr=sink("stderr"),
              group=v("group") is Some(True),
            ),
          )
        } catch {
          SysError(why) => Err(why)
          e => Err("\{e}")
        }
        match spawned {
          Ok(p) => {
            if input is Some(String(t)) {
              ignore(p.write(@utf8.encode(t)))
              p.end_input()
            }
            if v("detach") is Some(True) {
              Ok({ "pid": Json::number(p.pid.to_double()) })
            } else {
              let (code, signal, out, err) = p.finished()
              Ok({
                "pid": Json::number(p.pid.to_double()),
                "code": match code { Some(c) => Json::number(c.to_double()); None => Json::null() },
                "signal": match signal { Some(g) => Json::string(g); None => Json::null() },
                "stdout": Json::string(@utf8.decode_lossy(out)),
                "stderr": Json::string(@utf8.decode_lossy(err)),
              })
            }
          }
          Err(why) => Err(why)
        }
      }
      "stdinBackpressure" => {
        // 1) multi-chunk write to cat drains cleanly and closes with EOF
        let cat_res = try {
          let cat_p = spawn(
            host,
            "cat",
            [],
            env=[("PATH", "/bin:/usr/bin")],
            stdin_piped=true,
            stdout=Piped,
            stderr=Piped,
          )
          let expected = @buffer.Buffer()
          let mut cat_writes_ok = true
          for i = 0; i < 8; i = i + 1 {
            let fill = (b'a'.to_int() + i).to_byte()
            let chunk = Bytes::make(32 * 1024, fill)
            expected.write_bytes(chunk)
            if !cat_p.write(chunk) {
              cat_writes_ok = false
            }
          }
          cat_p.end_input()
          let after_eof = cat_p.write(b"after-eof")
          let (cat_code, cat_sig, cat_out, cat_err) = cat_p.finished()
          Ok(
            cat_writes_ok &&
            !after_eof &&
            cat_code == Some(0) &&
            cat_sig == None &&
            cat_err == b"" &&
            cat_out == expected.to_bytes(),
          )
        } catch {
          SysError(why) => Err(why)
          e => Err("\{e}")
        }

        // 2) stalled child past STILLFAIL_STDIN_MOST does not block and is SIGKILLed
        let prev_most = env_get("STILLFAIL_STDIN_MOST")
        env_set("STILLFAIL_STDIN_MOST", "131072")
        let stalled_res = try {
          let sp = spawn(
            host,
            "sleep",
            ["30"],
            env=[("PATH", "/bin:/usr/bin")],
            stdin_piped=true,
            stdout=Piped,
            stderr=Piped,
          )
          let start = @host.now()
          let chunk = Bytes::make(32 * 1024, b'x')
          let mut rejected = false
          for _i = 0; _i < 64; _i = _i + 1 {
            if !sp.write(chunk) {
              rejected = true
              break
            }
          }
          let write_ms = @host.now() - start
          let (sc, ss, _so, _se) = sp.finished()
          let total_ms = @host.now() - start
          let alive = pid_alive(sp.pid)
          Ok((rejected, write_ms, total_ms, sc, ss, alive))
        } catch {
          SysError(why) => Err(why)
          e => Err("\{e}")
        }
        match prev_most {
          Some(pv) => env_set("STILLFAIL_STDIN_MOST", pv)
          None => env_unset("STILLFAIL_STDIN_MOST")
        }

        // 3) child exiting without end_input cleans up stdin handle
        let quick_res = try {
          let qp = spawn(
            host,
            "true",
            [],
            env=[("PATH", "/bin:/usr/bin")],
            stdin_piped=true,
            stdout=Piped,
            stderr=Piped,
          )
          let (qc, qs, _qo, _qe) = qp.finished()
          let late = qp.write(b"late")
          Ok((qc, qs, late))
        } catch {
          SysError(why) => Err(why)
          e => Err("\{e}")
        }

        match (cat_res, stalled_res, quick_res) {
          (Ok(cat_ok), Ok((rejected, write_ms, total_ms, sc, ss, alive)), Ok((qc, qs, late))) =>
            Ok({
              "catOk": Json::boolean(cat_ok),
              "rejected": Json::boolean(rejected),
              "writeMs": Json::number(write_ms.to_double()),
              "totalMs": Json::number(total_ms.to_double()),
              "stalledCode": match sc { Some(c) => Json::number(c.to_double()); None => Json::null() },
              "stalledSignal": match ss { Some(g) => Json::string(g); None => Json::null() },
              "stalledAlive": Json::boolean(alive),
              "quickCode": match qc { Some(c) => Json::number(c.to_double()); None => Json::null() },
              "quickSignal": match qs { Some(g) => Json::string(g); None => Json::null() },
              "lateWrite": Json::boolean(late),
            })
          (Err(why), _, _) | (_, Err(why), _) | (_, _, Err(why)) => Err(why)
        }
      }
      "stdoutBackpressure" => {
        let res = try {
          let rss_before = self_rss_bytes().unwrap_or(0.0)
          let mut rss_peak = rss_before
          let p = spawn(
            host,
            "/bin/sh",
            ["-c", "exec yes flood"],
            env=[("PATH", "/bin:/usr/bin")],
            stdout=Piped,
            stderr=Piped,
            group=true,
          )
          let cap = 1048576
          let kept = @buffer.Buffer()
          let mut truncated = false
          let mut chunks = 0
          let start = @host.now()
          let ended = @effect.timeout(1500, async fn() {
            while true {
              match p.events.take() {
                Out(b) | Err(b) => {
                  chunks += 1
                  let room = cap - kept.length()
                  if room <= 0 {
                    truncated = true
                  } else if b.length() > room {
                    kept.write_bytesview(b[:room])
                    truncated = true
                  } else {
                    kept.write_bytes(b)
                  }
                  if chunks % 64 == 0 {
                    match self_rss_bytes() {
                      Some(r) if r > rss_peak => rss_peak = r
                      _ => ()
                    }
                  }
                }
                Exit(code, _) => return code
              }
            }
            None
          })
          let elapsed_ms = @host.now() - start
          match self_rss_bytes() {
            Some(r) if r > rss_peak => rss_peak = r
            _ => ()
          }
          let timed_out = ended is None
          if timed_out {
            ignore(kill(p.pid, "SIGKILL", group=true))
            ignore(
              @effect.timeout(2000, async fn() {
                while true {
                  match p.events.take() {
                    Exit(_, _) => return ()
                    _ => ()
                  }
                }
              }),
            )
          }
          let rss_after = self_rss_bytes().unwrap_or(0.0)
          let alive = pid_alive(p.pid)
          Ok(
            Json::object({
              "timedOut": Json::boolean(timed_out),
              "elapsedMs": Json::number(elapsed_ms.to_double()),
              "chunks": Json::number(chunks.to_double()),
              "keptBytes": Json::number(kept.length().to_double()),
              "truncated": Json::boolean(truncated),
              "rssBefore": Json::number(rss_before),
              "rssPeak": Json::number(rss_peak),
              "rssAfter": Json::number(rss_after),
              "alive": Json::boolean(alive),
            }),
          )
        } catch {
          SysError(why) => Err(why)
          e => Err("\{e}")
        }
        res
      }
      "kill" =>
        Ok(
          Json::boolean(
            match v("pid") {
              Some(Number(p, ..)) => kill(p.to_int(), s("signal"), group=v("group") is Some(True))
              _ => false
            },
          ),
        )
      "fileLock" =>
        match (try { Ok(file_lock(host, s("path"))) } catch { e => Err("\{e}") }) {
          Ok(l) => {
            next_lock += 1
            locks[next_lock] = l
            Ok({ "handle": Json::number(next_lock.to_double()) })
          }
          Err(why) => Err(why)
        }
      "fileUnlock" => {
        let k = match v("handle") {
          Some(Number(h, ..)) => h.to_int()
          _ => 0
        }
        match locks.get(k) {
          Some(l) => {
            l.release()
            locks.remove(k)
            Ok(Json::boolean(true))
          }
          None => Ok(Json::boolean(false))
        }
      }
      "words" => {
        let (zh, en) = catalogs_json()
        Ok({ "zh": zh, "en": en })
      }
      "iso" => Ok(Json::string(iso_time(match v("ms") { Some(Number(m, ..)) => m; _ => 0.0 })))
      // (what the launcher kept, as the station that comes up says it: launcher_events.mbt)
      "launcherEventLine" =>
        Ok(
          match parse_launcher_event_line(s("line")) {
            Some((level, kind, fields)) => { "level": Json::string(level), "kind": Json::string(kind), "fields": fields }
            None => Json::null()
          },
        )
      "launcherEvents" => {
        let said : Array[Json] = []
        let n = report_launcher_events(s("data"), emit=(level, message, fields) => said.push({ "level": Json::string(level), "message": Json::string(message), "fields": fields }))
        Ok({ "n": Json::number(n.to_double()), "said": Json::array(said) })
      }
      // (what a driver's error says in the station's language: live_p5_2_io.mbt `said_of`)
      "saidOf" => {
        let lang = s("lang")
        p52_lang_fn.val = () => lang
        Ok(Json::string(said_of(@agent_drivers.Said(s("key")))))
      }
      // (a line of the station's log, and one a part noted, written to stderr: live_p5_1.mbt)
      "log" => {
        p51_log(s("level"), s("at"), s("message"))
        Ok(Json::null())
      }
      "noted" => {
        noted(s("text"))
        Ok(Json::null())
      }
      // (a tree's size measured by the footprint builder of the program at `program`: live_p5_3_remote.mbt)
      "treeBytes" => Ok(Json::number(p53_tree_bytes_by(host, s("program"), s("path"))))
      // (a still.fail Helper holding its lock with no socket ended before the next is launched: live_p5_4_screens.mbt)
      "helperEvict" => {
        p54_helper_evict(host, s("dir"))
        Ok(Json::null())
      }
      // (still.fail Helper asked as P5-4 asks it, over the shell's Unix socket: started, where it is not up, by
      // `launch` {program, args} given its socket and token, as `p54_helper_launch` launches it)
      "helperRequest" => {
        let launcher = strs("launch")
        let io = @screens.host_io(host, p54_screen_procs(host), p54_screen_os_of(s("program")), p54_screen_words(() => "zh"))
        let opened = async fn(_app : String, env : Array[(String, String)]) {
          ignore(spawn(host, launcher[0], launcher[1:].to_array(), env=env_all() + env, group=true)) catch {
            SysError(why) => raise Failure(why)
          }
        }
        let dir = s("dir")
        let helper = @screens.HelperApp::new(io, s("app"), dir, launch=Some(p54_helper_launch(host, dir, opened)))
        let said = of_jv(helper.request(to_jv(v("ask").unwrap_or(Json::null())))) catch {
          e => { "error": Json::string(said_of(e)) }
        }
        helper.quit() catch {
          _ => ()
        }
        Ok(said)
      }
      // (the readers closed while a builder's process answers an item: live_p5_1_readers.mbt `Requested::run`)
      "requestedCloseInFlight" => Ok(p51_requested_close_in_flight(host, s("data"), s("program"), s("said")))
      // (P5-5's live parts made on a data directory of the test's: live_p5_5_harness.mbt)
      "p5_5" => p5_5_harness(host, ask)
      "loopback" => {
        let r = loopback_answer(
          s("path"),
          match v("query") { Some(String(q)) => Some(q); _ => None },
          v("ready") is Some(True),
          match v("place") { Some(Null) | None => None; p => p },
          s("lang"),
        )
        Ok({
          "status": Json::number(r.status.to_double()),
          "headers": Json::object(Map::from_array(r.headers.map(h => (h.0, Json::string(h.1))))),
          "body": Json::string(@utf8.decode_lossy(r.body)),
        })
      }
      "parts" => Ok(parts_exercised(host))
      "pipeTcpLost" => Ok(pipe_tcp_lost(host))
      "driverErrors" => Ok(driver_errors_said())
      "claudeLogins" => Ok(claude_logins_asked(host))
      "fsOp" => Ok(fs_op_said(host, s("name"), match v("args") { Some(Array(a)) => a; _ => [] }))
      "repoWalk" => Ok(repo_walk_probed(host, s("root"), s("file")))
      "watchDir" => Ok(harness_watch_dir(host, s("dir"), match v("every") { Some(Number(n, ..)) => n.to_int(); _ => 50 }))
      "watchDirSaid" =>
        harness_watch_said(match v("handle") { Some(Number(n, ..)) => n.to_int(); _ => -1 }, match v("count") { Some(Number(n, ..)) => n.to_int(); _ => 0 })
      "watchDirClose" => harness_watch_close(match v("handle") { Some(Number(n, ..)) => n.to_int(); _ => -1 })
      "gcmSeal" => {
        let key = @vault_crypto.unhex(s("key"))
        let nonce = @vault_crypto.unhex(s("nonce"))
        let aad = @vault_crypto.unhex(s("aad"))
        let plain = @vault_crypto.unhex(s("plain"))
        Ok(Json::string(@drive.hex(p54_gcm_seal(key, nonce, aad, plain))))
      }
      "gcmOpen" => {
        let key = @vault_crypto.unhex(s("key"))
        let nonce = @vault_crypto.unhex(s("nonce"))
        let aad = @vault_crypto.unhex(s("aad"))
        let sealed = @vault_crypto.unhex(s("sealed"))
        Ok(match p54_gcm_open(key, nonce, aad, sealed) {
          Some(p) => Json::string(@drive.hex(p))
          None => Json::null()
        })
      }
      "p256Keygen" =>
        try {
          let d = p54_p256_new_scalar()
          let pub_ = p54_p256_public(d)
          let pem = p54_pem("PRIVATE KEY", p54_pkcs8(host, P256(d)))
          Ok({ "d": Json::string(@drive.hex(d)), "pub": Json::string(@drive.hex(pub_)), "pem": Json::string(pem) })
        } catch {
          e => Err(said_of(e))
        }
      "p256Shared" =>
        try {
          let shared = p54_p256_shared(@vault_crypto.unhex(s("d")), @vault_crypto.unhex(s("peer")))
          Ok(Json::string(@drive.hex(shared)))
        } catch {
          e => Err(said_of(e))
        }
      "p256Sign" =>
        try {
          let d = @vault_crypto.unhex(s("d"))
          let pub_ = p54_p256_public(d)
          let msg = @vault_crypto.unhex(s("message"))
          let raw = p54_ecdsa_raw(host, d, pub_, msg)
          let der = p54_der_seq([p54_der_uint(p54_sub(raw, 0, 32)), p54_der_uint(p54_sub(raw, 32, 64))])
          Ok({ "raw": Json::string(@drive.hex(raw)), "der": Json::string(@drive.hex(der)), "pub": Json::string(@drive.hex(pub_)) })
        } catch {
          e => Err(said_of(e))
        }
      "rsaSign" =>
        try {
          let ops = p54_key_ops(host)
          let key = (ops.3)(v("jwk").unwrap_or(Json::null()))
          let sig = (ops.5)(key, s("hash"), @vault_crypto.unhex(s("message")))
          Ok(Json::string(@drive.hex(sig)))
        } catch {
          e => Err(said_of(e))
        }
      "x509Make" =>
        try {
          Ok(x509_make_said(host, s("caName"), s("host"), match v("now") { Some(Number(n, ..)) => n; _ => 0.0 }))
        } catch {
          e => Err(said_of(e))
        }
      "httpServe" =>
        try {
          Ok(http_serve_start(host))
        } catch {
          e => Err(said_of(e))
        }
      "hostFetch" => Ok(host_fetch_said(host, ask))
      other => Err("no op \{other}")
    }
    let said : Json = match answer {
      Ok(ok) => { "id": id, "ok": ok }
      Err(why) => { "id": id, "error": Json::string(why) }
    }
    host.say(said.stringify())
  }
}

///|
/// The parts' registry as the e2e test holds it to parts.ts: each of its sayings and askings once.
async fn parts_exercised(host : @host.Host) -> Json {
  ignore(host)
  let parts = StationParts::new()
  let on = Ref(false)
  let tool = (name : String) => ({
    name,
    declared: { "name": Json::string(name) },
    call: async fn(_args, _ctx) { Json::null() },
  } : PartTool)
  parts.tools([tool("always")])
  parts.tools([tool("offered")], offered=() => on.val)
  let tool_names = () => Json::array(parts.all_tools().map(t => Json::string(t.name)))
  let tools_off = tool_names()
  on.val = true
  let tools = tool_names()
  // what came before a part was made, taken by it as it is made; what one gives, by its name
  parts.take_up({ "late": { "kept": true }, "a": { "n": 2 } })
  let took_early : Map[String, Json] = Map([])
  let took_now : Map[String, Json] = Map([])
  let twice = []
  try {
    parts.carry("a", async fn() { { "n": 1 } }, what => took_now["a"] = what)
    parts.carry("b", async fn() { Json::string("two") }, _ => ())
    parts.carry("late", async fn() { Json::null() }, what => took_early["late"] = what)
    parts.carry("a", async fn() { Json::null() }, _ => ())
  } catch {
    PartTwice(why) => twice.push(Json::string(why))
  }
  let carried = parts.carried()
  carried.remove("late")
  parts.door({ prefix: "peer", request: async fn(_r, _c) { None } })
  let door = ["/peer", "/peer/x", "/peers", "/other"].map(p => match parts.door_route_of(p) {
    Some(_) => Json::string(p)
    None => Json::null()
  })
  try {
    parts.card_choice("retire", { may: (_v, _c, _a) => None, chosen: (_v, _c, _o, _a) => () })
    parts.streams("adb", async fn(_ask) {  })
    parts.overview("f", async fn(_viewer, lang) { Json::string("\{lang}:me") })
    parts.overview("f", async fn(_viewer, _lang) { Json::null() })
  } catch {
    PartTwice(why) => twice.push(Json::string(why))
  }
  let card = [
    if parts.card_choice_of({ "retire": {}, "options": [] }) is Some(_) { Json::string("retire") } else { Json::null() },
    if parts.card_choice_of({ "retire": [] }) is Some(_) { Json::string("retire") } else { Json::null() },
  ]
  let stream = [
    Json::boolean(parts.stream_of({ "adb": { "x": 1 } }) is Some(_)),
    Json::boolean(parts.stream_of({ "adb": "no" }) is Some(_)),
  ]
  parts.viewer_may((m, p) => m == "PUT" && p == "/marks")
  let ended = []
  parts.session_ended(s => ended.push(Json::string(s)))
  parts.end_session("s1")
  let connected = Ref(0)
  parts.member_connected(() => connected.val += 1)
  parts.member_connected(() => connected.val += 1)
  parts.connected()
  parts.door_open("http://127.0.0.1:1/mcp")
  {
    "tools": tools,
    "toolsOff": tools_off,
    "carried": Json::object(carried),
    "tookEarly": Json::object(took_early),
    "tookNow": Json::object(took_now),
    "door": Json::array(door),
    "card": Json::array(card),
    "stream": Json::array(stream),
    "twice": Json::array(twice),
    "mayView": [Json::boolean(parts.may_view("PUT", "/marks")), Json::boolean(parts.may_view("POST", "/marks"))],
    "overview": Json::object(parts.overview_of(Json::null(), "zh")),
    "ended": Json::array(ended),
    "connected": Json::number(connected.val.to_double()),
    "doorUrl": match parts.door_url() { Some(u) => Json::string(u); None => Json::null() },
  }
}

///|
/// A stream that gives its first bytes and is then lost (`FrontStream::read`'s `connection lost`), handed to a slice as
/// a connection of 127.0.0.1 and read there to its end: what came, whether it ended, and the code the stream was reset
/// with. Its fibers fail nothing: no defect is said (the test reads stderr), and the program exits 0.
async fn pipe_tcp_lost(host : @host.Host) -> Json {
  let reset : @effect.Deferred[Int] = @effect.Deferred::new()
  let reads = Ref(0)
  let stream : @door.Stream = {
    read: fn() raise {
      reads.val += 1
      if reads.val == 1 {
        Some(b"first")
      } else {
        raise Failure("connection lost")
      }
    },
    write: fn(_b) {  },
    finish: fn() {  },
    stopped: fn() { None },
    reset: fn(code) { ignore(reset.succeed(code)) },
    media_datagrams: None,
  }
  let handle = shell_handle(host, stream, b"")
  guard handle is { "kind": "tcp", "stream": theirs, .. } else { raise BusError("no connection: \{handle.stringify()}") }
  let came = StringBuilder()
  // (a bound only on what must come: one that never ends fails the test, saying so)
  let ended = @effect.timeout(10000, () => {
    while true {
      match (host.tcp_read(theirs) catch { _ => break }) {
        None => break
        Some(b) => came.write_string(@utf8.decode_lossy(b))
      }
    }
  })
  let code = @effect.timeout(10000, () => reset.wait())
  host.tcp_close(theirs)
  {
    "came": Json::string(came.to_string()),
    "ended": Json::boolean(ended is Some(_)),
    "reset": match code {
      Some(c) => Json::number(c.to_double())
      None => Json::null()
    },
  }
}

///|
/// The accounts' failures (and the routes' as P5-3 answers them) as a driver's `Later` fails with them: each one's kind
/// and words there, and as the station says it (`said_of`, `p53_words`, its show).
fn driver_errors_said() -> Json {
  let errors : Array[Error] = [
    @accounts_oauth.Said("signed out"),
    @accounts_oauth.RenewRefused(Some(401), "refused by its server"),
    @accounts_pool.Thrown("RenewRefused", @accounts_pool.jobj([("message", @accounts_pool.js("refused in the pool"))])),
    @api_routes.Thrown("RenewRefused", to_jv({ "message": "refused through the bus", "status": 400 })),
    @api_routes.Thrown("Said", to_jv({ "message": "said through the bus" })),
    @accounts_oauth.Failed("a plain failure"),
  ]
  Json::array(
    errors.map(e => {
      let d = driver_error_of(e)
      let kind = match d {
        @agent_drivers.Failed(_) => "Failed"
        @agent_drivers.Said(_) => "Said"
        @agent_drivers.RenewRefused(_) => "RenewRefused"
        _ => "other"
      }
      {
        "kind": Json::string(kind),
        "words": Json::string(@agent_drivers.words_of(d)),
        "said": Json::string(said_of(e)),
        "p53": Json::string(p53_words(e)),
        "shown": Json::string("\{e}"),
      }
    }),
  )
}

///|
/// What Claude's logins ask of the accounts, each given the token the session saw refused: the machine's, a profile's,
/// one lent by another station and one of this station's own asked as lent.
async fn claude_logins_asked(host : @host.Host) -> Json {
  let pump = Pump::new(host)
  let asked : Array[Json] = []
  let logins = p52_claude_logins(pump, host, fn(op, arg) {
    asked.push({ "op": Json::string(op), "arg": arg })
    { "token": Json::string("tok-new-\{asked.length()}"), "expiresAt": 5.0 }
  })
  let own = to_jv({ "id": "sub", "home": "homes/sub" })
  let lent = to_jv({ "id": "lent", "access": { "kind": "subscription" }, "share": { "borrowed": true, "host": "st-b" } })
  let lent_api = to_jv({
    "id": "lent-api",
    "access": { "kind": "api-provider", "provider": "google-vertex" },
    "share": { "borrowed": true, "host": "st-b" },
  })
  let given = []
  let took = (t : (String, Double)) => given.push(Json::string(t.0))
  took(pump.wait((logins.machine_token)(Some("tok-old"))))
  took(pump.wait((logins.subscription_token.unwrap())(own)(Some("tok-old"))))
  took(pump.wait((logins.lent_token.unwrap())(lent)(Some("tok-old"))))
  took(pump.wait((logins.lent_token.unwrap())(lent_api)(Some("tok-old"))))
  took(pump.wait((logins.lent_token.unwrap())(own)(Some("tok-old"))))
  took(pump.wait((logins.machine_token)(None)))
  let is_borrowed = logins.lent_borrowed.unwrap()
  {
    "asked": Json::array(asked),
    "given": Json::array(given),
    "borrowed": {
      "lent": Json::boolean(is_borrowed(lent)),
      "lentApi": Json::boolean(is_borrowed(lent_api)),
      "own": Json::boolean(is_borrowed(own)),
    },
  }
}

///|
/// What `host_fs_op` answers `name` with `args`: `{ok}`, or what it threw (`{code, message}`).
async fn fs_op_said(host : @host.Host, name : String, args : Array[Json]) -> Json {
  try {
    { "ok": host_fs_op(host, name, args) }
  } catch {
    DispatchFsError(code, message) | @session_chats.Thrown(code, message) => { "code": Json::string(code), "message": Json::string(message) }
    e => { "code": Json::string(""), "message": Json::string(said_of(e)) }
  }
}

///|
/// The repositories' index (session_chats `RepoIndex::walk`) over `root`, its folders listed and its files read by
/// `host_fs_op` as the station's own conversations have them. Before each listing a fiber is started that only notes
/// it ran: a listing that waits off the program's thread lets it run before it is answered, one done on the program's
/// thread (the walk's 28–40 s with every fiber held) answers first. The repositories' paths, how many folders were
/// listed and how many of those let the noting fiber run.
async fn repo_walk_probed(host : @host.Host, root : String, file : String) -> Json {
  let lists = Ref(0)
  let yielded = Ref(0)
  let w : @session_chats.World = {
    call: async fn(name, args) {
      let a = args.map(of_jv)
      let text = (i : Int) => match a.get(i) { Some(String(t)) => t; _ => "" }
      match name {
        "repoIndex.roots" => to_jv([Json::string(root)])
        "repoIndex.besides" => to_jv([])
        "repoIndex.guarded" => to_jv(false)
        "repoIndex.file" => to_jv(Json::string(file))
        "repoIndex.now" => to_jv(0.0)
        "repoIndex.list" => {
          lists.val += 1
          let ran = Ref(false)
          ignore(host.rt.fork_quiet(name="listing's probe", fn() { ran.val = true }))
          let got = host_fs_op(host, "readdirTypes", a)
          if ran.val {
            yielded.val += 1
          }
          to_jv(got)
        }
        n if n.has_prefix("fs.") => to_jv(host_fs_op(host, n[3:].to_owned(), a))
        _ => to_jv(Json::null())
      }
    },
    callback: _ => to_jv(Json::null()),
    words: @session_chats.Words::empty(),
    lang: Ref("zh"),
    thrown: Ref(to_jv(Json::null())),
    live: None,
  }
  let index = @session_chats.RepoIndex::new()
  index.walk(w)
  let (repos, _) = index.repos(w)
  let paths = repos.map(r => of_jv(r)).filter_map(r => match r { { "path": String(p), .. } => Some(Json::string(p)); _ => None })
  { "repos": Json::array(paths), "lists": Json::number(lists.val.to_double()), "yielded": Json::number(yielded.val.to_double()) }
}

///|
/// Generates a P-256 CA and leaf certificate for `host_name` using `p54_key_ops` + `@vault_service.make_ca`/`make_leaf`.
async fn x509_make_said(host : @host.Host, ca_name : String, host_name : String, now : Double) -> Json {
  let crypto = @vault_crypto.Crypto::of_host(host)
  let keys = p54_key_ops(host)
  let m : @vault_service.Machine = {
    temp_dir: async fn(_) { "" },
    remove: async fn(_) {  },
    chmod: async fn(_, _) {  },
    write_file: async fn(_, _, _) {  },
    read_file: async fn(_) { None },
    mkdir: async fn(_, _) {  },
    shell_for: async fn(_) { "/bin/sh" },
    spawn: async fn(_) { { code: None, signal: None, timed_out: false, error: None } },
    p256_new: keys.0,
    key_of_pem: keys.1,
    ed25519_of_seed: keys.2,
    rsa_of_jwk: keys.3,
    key_pem: keys.4,
    sign: keys.5,
    sha1: keys.6,
    roots: async fn() { [] },
    tls_context: async fn(_, _) { "" },
    proxy_listen: async fn(_, _) { 0 },
    proxy_close: () => (),
    unix_serve: async fn(_, _) { () => () },
    random: n => crypto.random(n) catch { _ => @drive.random_bytes(n) },
  }
  let ca = @vault_service.make_ca(m, now, ca_name)
  let leaf = @vault_service.make_leaf(m, ca, ca_name, host_name, now)
  let ca_pem = p54_pem("CERTIFICATE", ca.0)
  let leaf_pem = p54_pem("CERTIFICATE", leaf.0)
  let leaf_key_pem = (keys.4)(leaf.1)
  { "caPem": Json::string(ca_pem), "leafPem": Json::string(leaf_pem), "leafKeyPem": Json::string(leaf_key_pem) }
}

///|
/// Starts a real `serve_http` listener on 127.0.0.1:0 for HTTP conformance testing.
async fn http_serve_start(host : @host.Host) -> Json {
  let listening = host.tcp_listen_local(0)
  let port = listening.port
  let active = Ref(0)
  let handled = Ref(0)
  fork_bg(host, "harness http", async fn() {
    serve_http(host, listening.id, async fn(req, _id) {
      active.val += 1
      defer { active.val -= 1 }
      handled.val += 1
      match req.path() {
        "/health" => Some(json_reply(200, { "ok": Json::boolean(true), "active": Json::number(active.val.to_double()), "handled": Json::number(handled.val.to_double()) }))
        "/echo" => {
          let hdrs = Json::array(req.headers.map(h => Json::array([Json::string(h.0), Json::string(h.1)])))
          let sha = @drive.hex(p54_sha256(host, req.body))
          Some(json_reply(200, {
            "method": Json::string(req.meth),
            "target": Json::string(req.target),
            "headers": hdrs,
            "bodyLen": Json::number(req.body.length().to_double()),
            "bodySha256": Json::string(sha),
            "bodyText": Json::string(@utf8.decode_lossy(req.body)),
          }))
        }
        _ => Some(plain(404, "not found"))
      }
    })
  })
  { "port": Json::number(port.to_double()) }
}

///|
/// Calls `host.fetch` with the given parameters, returning `{status, headers, bodyBase64}` or `{error, isTimeout}`.
async fn host_fetch_said(host : @host.Host, ask : Json) -> Json {
  let url = jtext_or_empty(ask, "url")
  let method_ = match ask { { "method": String(m), .. } => m; _ => "GET" }
  let headers : Array[(String, String)] = match ask {
    { "headers": Array(xs), .. } =>
      xs.filter_map(x => match x { Array([String(k), String(v), ..]) => Some((k, v)); _ => None })
    _ => []
  }
  let body : Bytes? = match ask {
    { "bodyBase64": String(b), .. } => Some(@base64.decode(b) catch { _ => b"" })
    _ => None
  }
  let timeout_ms : Int? = match ask {
    { "timeoutMs": Number(n, ..), .. } => Some(n.to_int())
    _ => None
  }
  try {
    let r = host.fetch(url, method_~, headers~, body?=body, timeout_ms?=timeout_ms)
    {
      "status": Json::number(r.status.to_double()),
      "headers": Json::array(r.headers.map(h => Json::array([Json::string(h.0), Json::string(h.1)]))),
      "bodyBase64": Json::string(@drive.base64(r.body)),
    }
  } catch {
    @host.FetchTimeout => { "error": Json::string(@host.fetch_timed_out), "isTimeout": Json::boolean(true) }
    e => { "error": Json::string(said_of(e)), "isTimeout": Json::boolean(false) }
  }
}

///|
/// A directory followed for the harness ("watchDir"): what it told, in order, and its fiber's end.
priv struct HarnessWatch {
  watcher : @share_sync.Watcher
  told : Array[String]
  heard : Ref[@effect.Deferred[Unit]]
  ended : @effect.Deferred[Unit]
}

///|
let harness_watches : Map[Int, HarnessWatch] = Map([])

///|
async fn harness_watch_dir(host : @host.Host, dir : String, every : Int) -> Json {
  let told = []
  let heard = Ref(@effect.Deferred::new())
  let tell = (what : String) => {
    told.push(what)
    ignore(heard.val.succeed(()))
    heard.val = @effect.Deferred::new()
  }
  let ended = @effect.Deferred::new()
  let began = @effect.Deferred::new()
  let watcher = p53_watch_dir(host, @effect.Deferred::new(), dir, name => tell(name.unwrap_or("?")), () => tell("!failed"), every~, began~, ended~)
  let handle = harness_watches.length()
  harness_watches[handle] = { watcher, told, heard, ended }
  began.wait()
  Json::number(handle.to_double())
}

///|
async fn harness_watch_said(handle : Int, count : Int) -> Result[Json, String] {
  guard harness_watches.get(handle) is Some(w) else { return Err("no such watch") }
  // (a bound only on what must come: what never comes fails the test, saying so)
  let came = @effect.timeout(10000, () => while w.told.length() < count {
    w.heard.val.wait()
  })
  guard came is Some(_) else { return Err("told \{w.told.length()} of \{count} within 10s: \{Json::array(w.told.map(t => Json::string(t))).stringify()}") }
  Ok(Json::array(w.told.map(t => Json::string(t))))
}

///|
async fn harness_watch_close(handle : Int) -> Result[Json, String] {
  guard harness_watches.get(handle) is Some(w) else { return Err("no such watch") }
  (w.watcher.close)()
  guard @effect.timeout(10000, () => w.ended.wait()) is Some(_) else { return Err("its fiber did not end within 10s") }
  Ok(Json::array(w.told.map(t => Json::string(t))))
}
