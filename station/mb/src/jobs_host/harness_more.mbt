// The harness's cases of the workspaces' limits, the remote tasks' files and the jobs' processes.

///|
/// A reader's steps: `size` {path, limit, at} answered at once; `done` {size | error, at}: the walk under way ends.
async fn workspace_reader_case(host : @host.Host, c : Json) -> Json raise {
  let now = Ref(0.0)
  let walks : Array[@effect.Deferred[WorkspaceSize]] = []
  let walked = []
  let warned = []
  let reader = WorkspaceReader::new(
    () => now.val,
    async fn(path, limit) {
      walked.push(obj([("path", jstr(path)), ("limit", jnum(limit))]))
      let d = @effect.Deferred::new()
      walks.push(d)
      d.wait()
    },
    f => ignore(host.rt.fork(f)),
    warn=(path, _) => warned.push(jstr(path)),
  )
  let out = []
  for s in list_of(field(c, "steps")) {
    now.val = num(field(s, "at")).unwrap_or(now.val)
    match text(s, "do") {
      "size" => {
        let got = reader.size(text(s, "path"), limit=num(field(s, "limit")).unwrap_or(default_limit))
        out.push(or_null(got.map(x => x.to_json())))
      }
      "done" => {
        // (let the forked walk register its Deferred first)
        for i in 0..<16 {
          ignore(i)
          @effect.pause()
        }
        guard walks.length() > 0 else { raise HostError("no walk under way") }
        let d = walks.remove(0)
        match field(s, "size") {
          Some({ "bytes": Number(b, ..), "complete": complete, .. } as size) =>
            ignore(d.succeed({ bytes: b, complete: complete is True, truncated: field(size, "truncated") is Some(True) }))
          _ => ignore(d.fail(HostError("walk failed")))
        }
        // (what that wakes runs before the next step)
        for i in 0..<8 {
          ignore(i)
          @effect.pause()
        }
        out.push(jint(reader.kept()))
      }
      _ => ()
    }
  }
  obj([("out", Json::array(out)), ("walked", Json::array(walked)), ("warned", Json::array(warned))])
}

///|
/// A watch's steps over `data`: `look` {at, readings, working}, `set` {session, station, gib}, `limit`, `forget`;
/// what it told and each step's answer.
async fn workspace_watch_case(host : @host.Host, c : Json) -> Json raise {
  let now = Ref(0.0)
  let readings : Ref[Array[WorkspaceReading]] = Ref([])
  let working : Ref[Array[Json]] = Ref([])
  let told = []
  let watch = WorkspaceWatch::new(host, text(c, "data"), {
    now: () => now.val,
    readings: async fn() { readings.val },
    working: s => working.val.contains(jstr(s)),
    notify: async fn(s, words) { told.push(Json::array([jstr(s), jstr(words)])) },
    warn: (_, _) => (),
  })
  let out = []
  for s in list_of(field(c, "steps")) {
    now.val = num(field(s, "at")).unwrap_or(now.val)
    match text(s, "do") {
      "look" => {
        readings.val = list_of(field(s, "readings")).filter_map(WorkspaceReading::from_json)
        working.val = list_of(field(s, "working"))
        watch.look()
        out.push(Json::null())
      }
      "set" =>
        out.push(
          try {
            jnum(watch.set_limit(text(s, "session"), text(s, "station"), num(field(s, "gib")).unwrap_or(0.0)))
          } catch {
            e => obj([("error", jstr(words_of(e)))])
          },
        )
      "limit" => out.push(jnum(watch.limit(text(s, "session"), text(s, "station"))))
      "forget" => {
        watch.forget(text(s, "session"))
        out.push(Json::null())
      }
      _ => ()
    }
  }
  obj([("out", Json::array(out)), ("told", Json::array(told))])
}

///|
async fn remote_or_jobs_case(host : @host.Host, op : String, c : Json) -> Json raise {
  let t = (k : String) => text(c, k)
  let asked = []
  let double = () => station_double(
    host,
    t("remoteRoot"),
    !(field(c, "older") is Some(True)),
    or_null(field(c, "told")),
    asked,
  )
  match op {
    "remote.filePath" => jstr(file_path(host, t("root"), t("relative"), field(c, "create") is Some(True)))
    "remote.put" => {
      let body = match field(c, "whole") {
        Some(String(_)) as w => Some(Data(base64_of(w)))
        _ => None
      }
      file_put(host, t("path"), or_null(field(c, "request")), body)
    }
    "remote.get" => {
      let (answer, body) = file_get(host, t("path"), or_null(field(c, "request")))
      match body {
        Some(b) => merged(without(answer, []), obj([("bytes", jstr(@base64.encode(read_body(host, b, max_file))))]))
        None => answer
      }
    }
    "remote.download" => {
      let peer = double()
      let size = download(
        host,
        Bulk::new(),
        async fn(r) { peer("s", r, None) },
        or_null(field(c, "request")),
        t("path"),
        field(c, "replace") is Some(True),
      )
      obj([("size", jnum(size)), ("asked", Json::array(asked))])
    }
    "remote.fetchFile" => {
      let peer = double()
      let got = fetch_file(
        host,
        Bulk::new(),
        async fn(r) { peer("s", r, None) },
        t("path"),
        num(field(c, "limit")).unwrap_or(0.0),
      )
      or_null(got.map(b => jstr(@base64.encode(b))))
    }
    "remote.stationFile" =>
      station_file(
        host,
        Bulk::new(),
        double(),
        "s",
        or_null(field(c, "request")),
        or_null(field(c, "args")),
        t("root"),
      )
    "remote.bringBack" =>
      bring_back(host, Bulk::new(), double(), or_null(field(c, "entry")), str_opt(field(c, "workspace")), t("root"))
    "remote.latest" => {
      let l = latest_in(host, t("path"), most=num(field(c, "most")).unwrap_or(latest_most.to_double()).to_int())
      if l == @double.infinity {
        jstr("Infinity")
      } else {
        jnum(l)
      }
    }
    "remote.tidyBack" =>
      Json::array(tidy_back(host, list_of(field(c, "workspaces")).map(js_text), num(field(c, "now")).unwrap_or(0.0)).map(jstr))
    "remote.list" => {
      let answers = or_null(field(c, "answers"))
      list_stations(
        or_null(field(c, "roster")),
        t("own"),
        t("version"),
        async fn() { or_null(field(c, "ownLoad")) },
        async fn(id) {
          match field(answers, id) {
            Some({ "ok": v, .. }) => v
            Some({ "refused": String(m), .. }) => raise Refused(m)
            Some({ "offline": String(m), .. }) => raise NoLink(m)
            Some({ "error": String(m), .. }) => raise HostError(m)
            _ => @effect.never()
          }
        },
        list_of(field(c, "sandboxes")).map(s => Sandbox::{ name: text(s, "name"), described: or_null(field(s, "described")) }),
        None,
      )
    }
    "remote.rooms" => {
      let rooms = Rooms::new(host, t("root"))
      let out = []
      for s in list_of(field(c, "steps")) {
        match text(s, "do") {
          "seen" =>
            out.push(rooms.seen(text(s, "workspace"), text(s, "peer"), text(s, "session"), num(field(s, "at")).unwrap_or(0.0)))
          "room" => out.push(jstr(rooms.room(text(s, "workspace"), text(s, "peer"), text(s, "session"))))
          "close" => {
            let closed = rooms.close_room(text(s, "room"), list_of(field(s, "dirs")).map(js_text), num(field(s, "since")))
            // (the names it gave are random: whether each was moved)
            out.push(
              match closed {
                Null => Json::null()
                _ =>
                  obj([
                    ("aside", jint(list_of(field(closed, "aside")).length())),
                    ("room", jbool(!(field_or_null(closed, "room") is Null))),
                  ])
              },
            )
          }
          _ => ()
        }
      }
      Json::array(out)
    }
    "jobs.tail" => jstr(tail(host, t("path"), num(field(c, "lines")).unwrap_or(50.0).to_int()))
    "jobs.outputAt" => or_null(output_at(host, t("path")).map(jnum))
    "jobs.rotate" =>
      jbool(rotate_in_place(host, t("path"), num(field(c, "cap")).unwrap_or(0.0), keep?=num(field(c, "keep"))))
    "jobs.collect" => {
      let jobs = host_jobs(host, c)
      let known = or_null(field(c, "jobs"))
      let gone = jobs.collect(
        num(field(c, "now")).unwrap_or(0.0),
        list_of(field(c, "up")).map(js_text),
        id => some_json(field(known, id)),
      )
      Json::array(gone.map(jstr))
    }
    "jobs.notify" => {
      let heard = []
      let (status, body) = notify_endpoint(str_opt(field(c, "authorization")), base64_of(field(c, "body")), async fn(
        token,
        words,
      ) {
        if token != "good" {
          raise HostError("no job with this token")
        }
        heard.push(jstr(words))
      })
      obj([("status", jint(status)), ("body", body), ("heard", Json::array(heard))])
    }
    "jobs.screen" => {
      let (status, body) = screen_endpoint(str_opt(field(c, "authorization")), base64_of(field(c, "body")), async fn(
        token,
        what,
        pid,
      ) {
        if token != "good" {
          raise HostError("no job with this token")
        }
        obj([("screen", jstr(if what == "take" { "yours" } else { "given" })), ("pid", jnum(pid))])
      })
      obj([("status", jint(status)), ("body", body)])
    }
    "jobs.run" => jobs_run_case(host, c)
    _ => raise HostError("no such case: \{op}")
  }
}

///|
async fn host_jobs(host : @host.Host, c : Json) -> JobsHost raise {
  JobsHost::new(host, text(c, "data"))
}

///|
/// A job run as the station runs one: started in a group of its own and followed to its end (`stop`: asked to end
/// first, `adopt`: followed by a second host, as the next station takes one up); what its end said, its exit file and
/// its log.
async fn jobs_run_case(host : @host.Host, c : Json) -> Json raise {
  let jobs = JobsHost::new(host, text(c, "data"))
  let job = JobStart::from_json(or_null(field(c, "job")))
  let ended : @effect.Deferred[Json] = @effect.Deferred::new()
  let said = (id : String, code : Double?) => {
    ignore(
      ended.succeed(
        obj([("id", jstr(id)), ("code", or_null(code.map(jnum)))]),
      ),
    )
  }
  jobs.on_ended(async fn(id, _, code, _) { said(id, code) })
  let pgid = jobs.spawn(job, nice=0)
  if field(c, "adopt") is Some(True) {
    // the next station: this one stops following, another takes it up by its group
    jobs.shutdown()
    let next = JobsHost::new(host, text(c, "data"))
    next.on_ended(async fn(id, _, code, _) { said(id, code) })
    next.follow(job.id, pgid, 0.0)
  }
  if field(c, "stop") is Some(True) {
    @effect.sleep(300)
    jobs.signal(pgid, "SIGTERM")
    jobs.grace(job.id)
  }
  let end = @effect.timeout(30_000, async fn() { ended.wait() })
  guard end is Some(e) else { raise HostError("the job's end was not heard") }
  let exit_text = read_text(host, jobs.exit_file(job.id))
  obj([
    ("ended", e),
    ("exit", or_null(exit_text.map(jstr))),
    ("tmpLeft", jbool(there(host, jobs.exit_file(job.id) + ".tmp"))),
    ("log", or_null(read_text(host, job.log).map(jstr))),
    ("groupAlive", jbool((Processes::shell(host).group_alive)(pgid))),
  ])
}
