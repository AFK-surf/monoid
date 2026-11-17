// The tools run against the station as a test says it (`harness-mcp-tools`, station/test/mb-mcp-tools.test.ts):
// every call of a part goes to the test on stdout, `{"call": n, "name", "args"}`, answered on stdin `{"ret": n,
// "value"}`, `{"ret": n, "throw": {kind, ...}}`, or `{"ret": n, "value": {"$pending": 1}}` for one that never answers.
// The first request is `{"setup": {zh, en, product, consts, ports, data, move, device}}`, answered `{"ready": true}`;
// then a request of the MCP endpoint `{"mcp": {id, method, authorization, body}}`, of the door `{"door": {id, method,
// url, headers, body}}` or its upgrade `{"upgrade": ...}`, or of one function `{"fn": {id, name, args}}`, each
// answered `{"ans": id, ...}`; `{"drain": true}` is answered `{"drained": true}` once what was set going is done.

///|
priv struct Harness {
  host : @host.Host
  waiting : Map[Int, @effect.Deferred[Result[JV, Error]]]
  mut next : Int
}

///|
fn Harness::say(self : Harness, v : JV) -> Unit {
  self.host.say(stringify(v))
}

///|
/// An argument as the test's world takes it: undefined given as `{"$undef": 1}`, left out of an object, null in an
/// array (as station/test encodes what TypeScript gives).
fn wire_arg(v : JV) -> JV {
  match v {
    Arr(items) =>
      jarr(items.map(x => if is_undef(x) { @api_routes.JV::Null } else { wire_arg(x) }))
    Obj(_) if is_undef(v) => v
    Obj(f) => Obj(f.filter(p => !is_undef(p.1)).map(p => (p.0, wire_arg(p.1))))
    x => x
  }
}

///|
async fn Harness::call(self : Harness, name : String, args : Array[JV]) -> JV {
  self.next += 1
  let n = self.next
  let done = @effect.Deferred::new()
  self.waiting[n] = done
  // (as it is: an undefined argument is said `{"$undef": 1}`)
  self.host.say(
    @api_routes.stringify(
      jobj([
        ("call", jint(n)),
        ("name", js(name)),
        ("args", jarr(args.map(wire_arg))),
      ]),
    ),
  )
  match done.wait() {
    Ok(v) => v
    Err(e) => raise e
  }
}

///|
fn bytes_field(v : JV?) -> Bytes {
  @base64.decode(text(v)) catch {
    _ => b""
  }
}

///|
fn error_jv(e : Error) -> JV {
  let kind = match e {
    Failed(_) => "Error"
    Refusal(_) => "Refused"
    ToolError(_, _) => "ToolError"
    @api_routes.Thrown(k, _) => k
    _ => "Error"
  }
  let fields = [("kind", js(kind)), ("message", js(message_of(e)))]
  match e {
    ToolError(code, _) => fields.push(("code", js(code)))
    _ => ()
  }
  jobj(fields)
}

///|
priv struct World {
  c : Ctx
  mcp : McpEndpoint
  door : Door
  computer : Computer
  moves : MoveAsks
  device : DeviceTools
  no_helper : Array[Tool]
  feedback : Ref[FeedbackPart?]
  home : String
}

///|
/// The harness's timers: each asked of the test (`timers.later`), which says whether it comes due now.
fn harness_timers(b : ToolsBackend) -> Timers {
  {
    later: (ms, f) => {
      let fire = b.ask("timers.later", [jnum(ms)]) catch { _ => Null }
      let cancelled = Ref::new(false)
      if truthy(Some(fire)) {
        ignore(
          @effect.runtime().fork(name="harness timer", async fn() {
            @effect.pause()
            if !cancelled.val {
              f() catch {
                _ => ()
              }
            }
          }),
        )
      }
      () => cancelled.val = true
    },
  }
}

///|
async fn make_world(b : ToolsBackend, setup : JV) -> World {
  let consts = setup.get("consts").unwrap_or(jobj([]))
  let c = Ctx::new(
    b,
    @api_routes.Words::new(
      setup.get("zh").unwrap_or(jobj([])),
      setup.get("en").unwrap_or(jobj([])),
      product=jstr(setup.get("product")).unwrap_or("still.fail"),
    ),
    {
      runtime_kinds: strings_of(consts.get("runtimes")),
      station_lang: jstr(consts.get("stationLang")).unwrap_or("zh"),
      os: jstr(consts.get("os")).unwrap_or("darwin"),
      arch: jstr(consts.get("arch")).unwrap_or("arm64"),
    },
  )
  let computer = Computer::new(c, timers=harness_timers(b))
  let has = setup.get("move").unwrap_or(jobj([]))
  let moves = MoveAsks::new(c, text(setup.get("data")), {
    ask: is_true(has.get("ask")),
    set_wait: is_true(has.get("setWait")),
    refusal: is_true(has.get("refusal")),
    room: is_true(has.get("room")),
    told: is_true(has.get("told")),
  })
  let dev = setup.get("device").unwrap_or(jobj([]))
  let device = DeviceTools::new(
    b,
    text(dev.get("home")),
    dev.get("env").unwrap_or(jobj([])),
    jstr(dev.get("sessions")),
  )
  let tools = [
    ..chat_tools(c),
    ..archive_tools(c),
    ..remote_tools(c),
    ..workspace_size_tools(c),
    ..job_tools(c),
    ..screen_tools(c),
    ..permission_tools(c),
    ..computer_tools(computer),
    ..forward_tools(c),
    ..relay_tools(c),
    ..feedback_tools(c),
    ..move_tools(moves),
    ..retire_tools(c),
    ..device_tools(c),
    ..rig_tools(c),
    ..search_tools(c),
  ]
  let feedback : Ref[FeedbackPart?] = Ref::new(None)
  // (the feedback part's tools, once it is made, in place of those made without it)
  let mcp = McpEndpoint::new(b, () => match feedback.val {
    Some(part) => {
      let names = part.tools.map(t => t.name)
      [..part.tools, ..tools.filter(t => !names.contains(t.name))]
    }
    None => tools
  })
  let ports = jitems(setup.get("ports")).map(p => jnumber(Some(p)).unwrap_or(0.0).to_int())
  {
    c,
    mcp,
    door: Door::new(mcp, b, ports),
    computer,
    moves,
    device,
    no_helper: permission_tools(c, grants=None),
    feedback,
    home: text(consts.get("home")),
  }
}

///|
fn opt_str(v : JV?) -> String? {
  jstr(v)
}

///|
/// One function of the package, by name, as a test asks it.
async fn run_fn(w : World, name : String, a : Array[JV]) -> JV {
  let b = w.c.b
  let arg = (i : Int) => a.get(i).unwrap_or(jundef)
  let s = (i : Int) => text(a.get(i))
  let n = (i : Int) => jnumber(a.get(i)).unwrap_or(0.0)
  match name {
    "typed" => typed(arg(0), arg(1))
    "fitted" => {
      let (declared, rest) = fitted((w.mcp.tools)(), n(0).to_int())
      jobj([
        ("declared", jstrs(declared.map(t => t.name))),
        ("indirect", jstrs(rest.map(t => t.name))),
      ])
    }
    "indirectTool" => {
      let names = strings_of(Some(arg(0)))
      declared(indirect_tool((w.mcp.tools)().filter(t => names.contains(t.name))))
    }
    "weights" => jobj((w.mcp.tools)().map(t => (t.name, jint(weight(t)))))
    "isSlackWrite" => jbool(is_slack_write(s(0)))
    "speaksInSlack" => jbool(speaks_in_slack(s(0)))
    "peerHttpBase" => js(peer_http_base(s(0)))
    "peerTarget" =>
      match peer_target(s(0)) {
        Some(t) => t.to_jv()
        None => Null
      }
    "notFromHere" => {
      let headers = jfields(Some(arg(0))).map(p => (p.0, js_string(Some(p.1))))
      let ports = jitems(Some(arg(1))).map(p => jnumber(Some(p)).unwrap_or(0.0).to_int())
      @api_routes.jopt(not_from_here(headers, ports))
    }
    "refuseUpgrade" =>
      js(@base64.encode(refuse_upgrade(n(0).to_int(), s(1))))
    "urlPathname" => js(url_pathname(s(0)))
    "toUnit" => {
      let (x, y) = to_unit(n(0), n(1), n(2), n(3))
      jobj([("x", jnum(x)), ("y", jnum(y))])
    }
    "keyPresses" => jarr(key_presses(s(0), extra=strings_of(a.get(1))))
    "typing" => jarr(typing(s(0)))
    "clicking" => jarr(clicking(n(0), n(1), s(2), is_true(a.get(3))))
    "dragging" => jarr(dragging(n(0), n(1), n(2), n(3), s(4)))
    "computerRun" =>
      match (w.mcp.tools)().iter().find_first(t => t.name == "computer") {
        Some(t) => js((t.run)(s(0), arg(1), jundef))
        None => Null
      }
    "computerOpen" => jstrs(w.computer.open())
    "computerCloseSession" => {
      w.computer.close_session(s(0))
      Null
    }
    "computerCloseAll" => {
      w.computer.close_all()
      Null
    }
    "described" => js(described(w.c, "screens", opt_str(a.get(0)), opt_str(a.get(1))))
    "letGo" =>
      js(let_go(w.c, "screens", arg(0), a.get(1), s(2), a.get(3)))
    "probeRelay" =>
      match probe_relay(b, s(0)) {
        Reached(ms) => jobj([("ok", jbool(true)), ("ms", jnum(ms))])
        Not(why) => jobj([("ok", jbool(false)), ("why", js(why))])
      }
    "noHelper" => js((w.no_helper[0].run)(s(0), arg(1), jundef))
    "report" => report(w.c, arg(0), arg(1), arg(2))
    "fixedNotice" => js(fixed_notice(arg(0), opt_str(a.get(1))))
    "tellFixed" =>
      jint(
        tell_fixed(told => b.ask("feedback.fixed", [jstrs(told)]), (session, text) => b.tell(
          "feedback.notify",
          [js(session), js(text)],
        )),
      )
    "reachedAt" => js(reached_at(arg(0), n(1).to_int()))
    "summaryOf" => summary_of(arg(0), arg(1))
    "planWords" => js(plan_words(arg(0), s(1), is_true(a.get(2))))
    "outcomeOf" => outcome_of(arg(0))
    "roomWords" => js(room_words(arg(0)))
    "outcomeWords" => js(outcome_words(arg(0), s(1), s(2)))
    "moveTool" => w.moves.tool(s(0), arg(1))
    "moveAnswer" => w.moves.answer(s(0), s(1), arg(2))
    "moveMay" => @api_routes.jopt(w.moves.may(arg(0), arg(1), arg(2)))
    "moveChosen" => {
      w.moves.chosen(arg(0), arg(1), s(2), arg(3))
      w.moves.settle()
      Null
    }
    "parseIso" => {
      let v = parse_iso(s(0))
      if v.is_nan() {
        Null
      } else {
        jnum(v)
      }
    }
    "isoString" => js(iso_string(n(0)))
    "logLines" =>
      js(
        log_lines_of(b, s(0), n(1), n(2), strings_of(a.get(3)), s(4), s(5)),
      )
    "failedTurnOf" =>
      match failed_turn_of(b, "store", arg(0), n(1)) {
        Some((session, turn)) =>
          jobj([("session", session), ("turn", turn)])
        None => Null
      }
    "readTail" => @api_routes.jopt(read_tail(b, s(0), n(1).to_int()))
    "noticeReport" =>
      notice_report(w.c, "store", arg(0), arg(1), arg(2), report_deps(w))
    "reportRoute" => {
      let routes = report_routes(w.c, report_deps(w), r => b.ask("feedback.sendReport", [
        r,
      ]))
      answer_jv(route_answer(routes, arg(0)))
    }
    "formatSkill" => js(format_skill_from_catalog(arg(0), s(1), s(2)))
    "skillForPeer" =>
      skill_for_peer(
        ws => b.ask("readCatalog", [jundef_or(ws)]),
        arg(0),
        opt_str(a.get(1)),
        opt_str(a.get(2)),
      )
    "searchForPeer" =>
      search_for_peer(b, arg(0), opt_str(a.get(1)), opt_str(a.get(2)))
    "device" => w.device.run(s(0), arg(1), arg(2), s(3))
    "deviceClose" => {
      w.device.close()
      Null
    }
    "accessOf" => js(access_of(arg(0)))
    "feedbackLive" =>
      match feedback_live(w.c, w.home) {
        Some(part) => {
          w.feedback.val = Some(part)
          jobj([
            ("tools", jstrs(part.tools.map(t => t.name))),
            ("after", jint(part.told_after_ms)),
          ])
        }
        None => {
          w.feedback.val = None
          Null
        }
      }
    "feedbackOverview" =>
      match w.feedback.val {
        Some(part) => jbool((part.overview)())
        None => Null
      }
    "feedbackViewerMay" => jbool(feedback_viewer_may(s(0), s(1)))
    "feedbackTell" =>
      match w.feedback.val {
        Some(part) => {
          (part.telling_fixed)()
          Null
        }
        None => Null
      }
    "feedbackRoute" =>
      match w.feedback.val {
        Some(part) => answer_jv(route_answer(part.routes, arg(0)))
        None => Null
      }
    _ => raise Failed("no function \{name}")
  }
}

///|
/// What a report is made with, as the test's world gives it.
fn report_deps(w : World) -> ReportDeps {
  let b = w.c.b
  {
    log_tail: most => match b.ask("reportDeps.logTail", [jint(most)]) {
      Str(t) => Some(t)
      _ => None
    },
    versions: () => b.ask("reportDeps.versions", []),
    env_names: () => strings_of(Some(b.ask("reportDeps.envNames", []))),
    link: k => b.ask("reportDeps.link", [js(k)]),
    home: w.home,
  }
}

///|
/// A route's answer to `{path, body, lang, viewer}`, the route found by its pattern.
async fn route_answer(
  routes : Array[ReportRoute],
  q : JV,
) -> @api_routes.Answer {
  let path = text(q.get("path"))
  let r : ReportAsk = {
    body: bytes_field(q.get("body")),
    viewer: q.get("viewer").unwrap_or(jobj([])),
    lang: jstr(q.get("lang")).unwrap_or("en"),
  }
  for route in routes {
    match @api_routes.re(route.pattern).exec(path) {
      Some(found) => return (route.handle)(r, found[1:].to_array())
      None => ()
    }
  }
  @api_routes.error(404, "no route")
}

///|
async fn answer_jv(a : @api_routes.Answer) -> JV {
  let body = a.bytes()
  let headers = []
  for k, v in a.headers {
    headers.push((k, js(v)))
  }
  jobj([
    ("status", jint(a.status)),
    ("headers", jobj(headers)),
    ("body", js(@base64.encode(body))),
  ])
}

///|
fn door_request(q : JV) -> DoorRequest {
  {
    method: jstr(q.get("method")).unwrap_or("GET"),
    url: jstr(q.get("url")).unwrap_or("/"),
    headers: jfields(q.get("headers")).map(p => (lower(p.0), js_string(Some(p.1)))),
    body: bytes_field(q.get("body")),
  }
}

///|
pub async fn harness(host : @host.Host) -> Unit {
  let h : Harness = { host, waiting: Map::new(), next: 0 }
  let b = ToolsBackend::new((name, args) => h.call(name, args))
  let world : @effect.Deferred[World] = @effect.Deferred::new()
  let background : Array[@effect.Fiber[Unit]] = []
  let serve = (id : JV, work : async (World) -> Array[(String, JV)]) => {
    background.push(
      host.rt.fork(name="harness request", async fn() {
        let w = world.wait()
        let fields = work(w) catch {
          e => [("error", error_jv(e))]
        }
        h.say(jobj([("ans", id), ..fields]))
      }),
    )
  }
  while host.line() is Some(line) {
    let said = try_parse(line).unwrap_or(Null)
    match said {
      Obj(_) => ()
      _ => continue
    }
    match said.get("ret") {
      Some(Num(n)) => {
        match h.waiting.get(n.to_int()) {
          Some(done) =>
            match said.get("throw") {
              Some(t) => {
                h.waiting.remove(n.to_int())
                ignore(
                  done.succeed(
                    Err(
                      @api_routes.Thrown(jstr(t.get("kind")).unwrap_or("Error"), t),
                    ),
                  ),
                )
              }
              None => {
                let value = said.get("value").unwrap_or(jundef)
                // (one that never answers: what asked it waits on)
                if !(value.get("$pending") is Some(_)) {
                  h.waiting.remove(n.to_int())
                  ignore(done.succeed(Ok(value)))
                }
              }
            }
          None => ()
        }
        continue
      }
      _ => ()
    }
    match said.get("setup") {
      Some(setup) => {
        ignore(
          host.rt.fork(name="harness setup", async fn() {
            let w = make_world(b, setup)
            ignore(world.succeed(w))
            h.say(jobj([("ready", jbool(true))]))
          }),
        )
        continue
      }
      None => ()
    }
    match said.get("mcp") {
      Some(q) => {
        serve(q.get("id").unwrap_or(Null), async fn(w) {
          let auth = match q.get("authorization") {
            Some(Str(a)) => Some(a)
            _ => None
          }
          let reply = w.mcp.handle(
            jstr(q.get("method")).unwrap_or("POST"),
            auth,
            bytes_field(q.get("body")),
            signal=@api_routes.Signal::new(),
          )
          [
            ("status", jint(reply.status)),
            (
              "body",
              match reply.body {
                Some(v) => v
                None => Null
              },
            ),
          ]
        })
        continue
      }
      None => ()
    }
    match said.get("door") {
      Some(q) => {
        serve(q.get("id").unwrap_or(Null), async fn(w) {
          let a = w.door.handle(door_request(q))
          [
            ("status", jint(a.status)),
            ("headers", jobj(a.headers.map(p => (p.0, js(p.1))))),
            ("body", js(@base64.encode(a.body))),
            ("destroyed", jbool(a.destroyed)),
          ]
        })
        continue
      }
      None => ()
    }
    match said.get("upgrade") {
      Some(q) => {
        serve(q.get("id").unwrap_or(Null), async fn(w) {
          match w.door.upgrade(door_request(q)) {
            Refused(bytes) => [("refused", js(@base64.encode(bytes)))]
            Routed => [("routed", jbool(true))]
            Destroyed => [("destroyed", jbool(true))]
          }
        })
        continue
      }
      None => ()
    }
    match said.get("fn") {
      Some(q) => {
        serve(q.get("id").unwrap_or(Null), async fn(w) {
          [
            (
              "ok",
              run_fn(w, text(q.get("name")), jitems(q.get("args"))),
            ),
          ]
        })
        continue
      }
      None => ()
    }
    if said.get("drain") is Some(_) {
      ignore(
        host.rt.fork(name="harness drain", async fn() {
          let w = world.wait()
          while background.length() > 0 {
            let f = background.remove(0)
            ignore(f.wait())
          }
          w.moves.settle()
          w.device.drained()
          h.say(jobj([("drained", jbool(true))]))
        }),
      )
    }
  }
}
