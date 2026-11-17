// The package's harness (reader `--builder harness-adb-devices`): what station/test/mb-adb-devices.test.ts holds these
// parts to the TypeScript of station/src/adb/ and station/src/devices/ with. A line a message both ways, JSON:
// - asked of the program: `{"seq": n, "op": …}` (`fn` a function of no world, `new` a part made, `call` a part's
//   method, `cb` a function given the test called back, `words`, `lang`), answered `{"re": n, "ok": value}` or
//   `{"re": n, "error": message, "kind": kind}`; each runs as a fiber of its own, so a part waiting on the test goes
//   on as the test asks more;
// - what the program asks of the test (its world: the station, the machine, the clock): `{"ask": m, "name": name,
//   "args": [...]}`, answered `{"answer": m, "result": value}` or `{"answer": m, "threw": message, "kind": kind}`;
// - every message the test sends may say its clock (`now`), what the parts read as the time.

///|
priv enum Inst {
  GrantsI(PhoneGrants)
  AdbI(Adb)
  SharesI(Shares)
  ServersI(GrantServers)
  DisplaysI(PhoneDisplays)
  RegistryI(DeviceRegistry)
  DevicesI(Devices)
}

///|
priv struct Harness {
  host : @host.Host
  insts : Map[String, Inst]
}

///|
fn Harness::say(self : Harness, v : J) -> Unit {
  self.host.say(stringify(v))
}

///|
fn error_fields(e : Error) -> Array[(String, J)] {
  [("error", js(message_of(e))), ("kind", js(kind_of(e)))]
}

///|
fn opt_s(v : J?) -> String? {
  match v {
    Some(Str(_)) => str_of(v)
    _ => None
  }
}

///|
fn arg(args : Array[J], i : Int) -> J {
  args.get(i).unwrap_or(Null)
}

///|
fn sarg(args : Array[J], i : Int) -> String {
  text_of(args.get(i))
}

///|
fn narg(args : Array[J], i : Int) -> Double {
  num_of(args.get(i)).unwrap_or(0.0)
}

///|
fn ints(v : J) -> Array[Int] {
  list_of(Some(v)).map(x => num_of(Some(x)).unwrap_or(0.0).to_int())
}

///|
fn strings(v : J) -> Array[String] {
  list_of(Some(v)).map(x => text_of(Some(x)))
}

///|
fn req_j(r : Req?) -> J {
  match r {
    Some(r) => r.v
    None => Null
  }
}

///|
fn opt_j(s : String?) -> J {
  jopt(s)
}

///|
fn result_j(r : Result[J, String]) -> J {
  match r {
    Ok(v) => jo([("ok", v)])
    Err(why) => jo([("refused", js(why))])
  }
}

///|
pub async fn harness(host : @host.Host) -> Unit {
  let now : Ref[Double] = { val: 0.0, }
  let asks : Map[Int, @effect.Deferred[J]] = Map::new()
  let cbs : Map[Int, async (Array[J]) -> J] = Map::new()
  let next_ask = Ref(0)
  let next_cb = Ref(0)
  let w = World::new(
    async fn(name, args) {
      next_ask.val += 1
      let id = next_ask.val
      let d = @effect.Deferred::new()
      asks[id] = d
      host.say(
        stringify(jo([("ask", ji(id)), ("name", js(name)), ("args", ja(args))])),
      )
      d.wait()
    },
    f => {
      next_cb.val += 1
      cbs[next_cb.val] = f
      jo([("$cb", ji(next_cb.val))])
    },
    () => now.val,
    f => ignore(host.rt.fork(f)),
    Words::empty(),
  )
  let h : Harness = { host, insts: Map::new(), }
  let mut words = Words::empty()
  let mut world = w
  while true {
    guard host.line() is Some(line) else { break }
    let c = @session_chats.parse_js(line) catch {
      e => {
        h.say(jo(error_fields(e)))
        continue
      }
    }
    match at(Some(c), "now") {
      Some(Num(n)) => now.val = n
      _ => ()
    }
    // an answer to what was asked of the test
    match at(Some(c), "answer") {
      Some(Num(n)) => {
        match asks.get(n.to_int()) {
          Some(d) => {
            asks.remove(n.to_int())
            match at(Some(c), "threw") {
              Some(Str(_) as m) =>
                ignore(
                  d.fail(refused(text_of(at(Some(c), "kind")), js_text(m))),
                )
              _ => ignore(d.succeed(at(Some(c), "result").unwrap_or(Null)))
            }
          }
          None => ()
        }
        continue
      }
      _ => ()
    }
    let op = text_of(at(Some(c), "op"))
    if op == "words" {
      words = Words::new(get(c, "zh"), get(c, "en"))
      let lang = world.lang
      world = World::new(w.call, w.callback, w.now, w.spawn, words)
      world.set_lang(lang)
      h.say(jo([("re", get(c, "seq")), ("ok", Null)]))
      continue
    }
    if op == "lang" {
      world.set_lang(text_of(at(Some(c), "lang")))
      h.say(jo([("re", get(c, "seq")), ("ok", Null)]))
      continue
    }
    let seq = get(c, "seq")
    let wd = world
    // (each case on a fiber of its own: one may wait on what the test answers while another is asked)
    ignore(
      host.rt.fork(async fn() {
        let answer = try {
          let args = list_of(at(Some(c), "args"))
          let v = match op {
            "fn" => pure(wd, text_of(at(Some(c), "name")), args)
            "new" => h.make(wd, c)
            "call" =>
              h.call(
                text_of(at(Some(c), "id")),
                text_of(at(Some(c), "name")),
                args,
              )
            "cb" =>
              match
                cbs.get(num_of(at(Some(c), "id")).unwrap_or(-1.0).to_int()) {
                Some(f) => f(args)
                None => raise fail_("no such callback")
              }
            op => raise fail_("no such op: \{op}")
          }
          jo([("re", seq), ("ok", v)])
        } catch {
          e => jo([("re", seq)] + error_fields(e))
        }
        h.say(answer)
      }),
    )
  }
}

///|
/// The functions of no part.
async fn pure(w : World, name : String, args : Array[J]) -> J {
  match name {
    "activity" => {
      let heard = []
      let a = AdbActivity::new(sarg(args, 0), force => heard.push(jb(force)))
      for chunk in list_of(Some(arg(args, 1))) {
        a.take(unb64(text_of(Some(chunk))))
      }
      ja(heard)
    }
    "failure" => js(failure(sarg(args, 0)))
    "displayOf" => display_of(sarg(args, 0))
    "densityOf" => jn(density_of(sarg(args, 0)))
    "sizeOf" => {
      let (wd, ht) = size_of(sarg(args, 0))
      jo([("width", jn(wd)), ("height", jn(ht))])
    }
    "rootTasksOn" =>
      ja(root_tasks_on(sarg(args, 0), narg(args, 1).to_int()).map(ji))
    "surfaceOf" =>
      opt_j(
        surface_of(sarg(args, 0), sarg(args, 1), narg(args, 2).to_int(), async fn() {
          js_text(w.ask("flinger", []))
        }),
      )
    "listed" => js(listed(list_of(Some(arg(args, 0)))))
    "reached" =>
      js(
        reached(
          list_of(Some(arg(args, 0))),
          num_of(args.get(1)).map(p => p.to_int()),
          gone=arg(args, 2),
          display=arg(args, 3),
        ),
      )
    "displayed" => js(displayed(arg(args, 0)))
    "linkSaid" => js(link_said(Req::new(arg(args, 0))))
    "said" => js(said(Req::new(arg(args, 0))))
    "scopeSaid" => js(scope_said(args.get(0)))
    "text" => js(text(args.get(0), narg(args, 1).to_int()))
    "isPackage" => jb(is_package(sarg(args, 0)))
    "usualPort" => ji(usual_port(sarg(args, 0)))
    "langOfCore" => js(lang_of_core(arg(args, 0)))
    "key" => js(key(w, arg(args, 0), arg(args, 1), arg(args, 2)))
    "adbCandidates" =>
      jsa(
        adb_candidates(
          arg(args, 0),
          opt_s(args.get(1)),
          sarg(args, 2),
          sarg(args, 3),
          sarg(args, 4),
        ),
      )
    "hostPort" => {
      let (host, port) = host_port(sarg(args, 0))
      jo([("host", js(host)), ("port", jn(port))])
    }
    "deviceRefusal" => opt_j(device_refusal(arg(args, 0)))
    "reachedAt" => js(reached_at(arg(args, 0), narg(args, 1).to_int()))
    "deviceListSaid" => js(device_list_said(list_of(Some(arg(args, 0)))))
    "named" => named(list_of(Some(arg(args, 0))), sarg(args, 1))
    "phoneId" => js(phone_id(sarg(args, 0), sarg(args, 1)))
    "isoTime" => js(iso_time(narg(args, 0)))
    "chatTitle" =>
      js(
        chat_title(
          arg(args, 0),
          opt_s(args.get(1)),
          opt_s(args.get(2)),
          sarg(args, 3),
          sarg(args, 4),
        ),
      )
    "grantChatTitle" => opt_j(grant_chat_title(w, arg(args, 0)))
    "decls" =>
      ja([
        adb_devices_decl, phone_use_decl, phone_send_decl, device_list_decl, device_use_decl,
      ])
    "gate" => {
      let deps : GateDeps = {
        session: async fn(id) { w.ask("gate.session", [js(id)]) },
        table: async fn() { w.ask("gate.table", []) },
        runners: async fn(id) { ints(w.ask("gate.runners", [js(id)])) },
        jobs: async fn() {
          list_of(Some(w.ask("gate.jobs", []))).mapi((i, j) => {
            (
              num_of(at(Some(j), "pgid")).unwrap_or(-1.0).to_int(),
              async fn(id : String) -> Bool {
                w.ask("gate.mine", [ji(i), js(id)]) is Bool(true)
              },
            )
          })
        },
        cwds: async fn(pids) { cwds_of(w.ask("gate.cwds", [ja(pids.map(ji))])) },
        self_pid: narg(args, 2).to_int(),
        elsewhere: opt_s(args.get(3)),
      }
      opt_j(gate(deps, w, sarg(args, 0), ints(arg(args, 1))))
    }
    "openDoor" => {
      let door = open_door(
        w,
        sarg(args, 0),
        sarg(args, 1),
        async fn(port) { ints(w.ask("door.holders", [ji(port)])) },
        async fn(id, holders) {
          opt_s(Some(w.ask("door.admit", [js(id), ja(holders.map(ji))])))
        },
      )
      ji(door.port)
    }
    "staged" => {
      let (name, size) = staged(w, sarg(args, 0), sarg(args, 1))
      jo([("name", js(name)), ("size", jn(size))])
    }
    "fetchOnPhone" =>
      fetch_on_phone(
        w,
        arg(args, 0),
        sarg(args, 1),
        sarg(args, 2),
        narg(args, 3),
        heard=async fn(at_) { ignore(w.ask("fetch.heard", [jn(at_)])) },
      )
    "run" =>
      js(run(w, sarg(args, 0), strings(arg(args, 1)), num_of(args.get(2))))
    "tunnel" => {
      tunnel(w, arg(args, 0), sarg(args, 1), arg(args, 2))
      Null
    }
    "keepTcp" => Null
    _ => raise fail_("no such function: \{name}")
  }
}

///|
fn Harness::db(self : Harness, path : String) -> @sql.Db raise {
  @sql.Db::create(self.host, path, wait=5000) catch {
    e => raise sql_err(e)
  }
}

///|
/// A part made: `{kind, id, ...}`.
async fn Harness::make(self : Harness, w : World, c : J) -> J {
  let id = text_of(at(Some(c), "id"))
  let inst = match text_of(at(Some(c), "kind")) {
    "grants" => {
      let db = self.db(text_of(at(Some(c), "db")))
      GrantsI(
        PhoneGrants::new(
          w,
          db,
          async fn(r) { opt_s(Some(w.ask("grants.title", [r.v]))) },
          async fn(r, ws, change) {
            ignore(w.ask("grants.told", [r, ws, js(change)]))
          },
          outcomes=at(Some(c), "outcomes") is Some(Bool(true)),
        ),
      )
    }
    "adb" => {
      let db = self.db(text_of(at(Some(c), "db")))
      AdbI(
        Adb::new(
          w,
          db,
          text_of(at(Some(c), "file")),
          record?=opt_s(at(Some(c), "record")),
          admit=at(Some(c), "admit") is Some(Bool(true)),
          outcomes=at(Some(c), "outcomes") is Some(Bool(true)),
        ),
      )
    }
    "servers" => {
      let admit : Admit? = if at(Some(c), "admit") is Some(Bool(true)) {
        Some(async fn(grant, holders) {
          opt_s(Some(w.ask("servers.admit", [js(grant), ja(holders.map(ji))])))
        })
      } else {
        None
      }
      ServersI(
        GrantServers::new(w, record?=opt_s(at(Some(c), "record")), admit?),
      )
    }
    "shares" => {
      let servers = match self.insts.get(text_of(at(Some(c), "servers"))) {
        Some(ServersI(s)) => Some(s)
        _ => None
      }
      let limits = match at(Some(c), "limits") {
        Some(Obj(_) as l) =>
          {
            quick: num_of(at(Some(l), "quick")),
            long: num_of(at(Some(l), "long")),
          }
        _ => { quick: Some(5000.0), long: Some(30000.0), }
      }
      SharesI(
        Shares::new(
          w,
          limits~,
          cloud=at(Some(c), "cloud") is Some(Bool(true)),
          servers?,
          granted?=if at(Some(c), "granted") is Some(Bool(true)) {
            Some(async fn(email) {
              strings(w.ask("shares.granted", [js(email)]))
            })
          } else {
            None
          },
          stated=async fn(email, state) {
            ignore(w.ask("shares.stated", [js(email), state]))
          },
          used=async fn(grant, force) {
            ignore(w.ask("shares.used", [js(grant), jb(force)]))
          },
        ),
      )
    }
    "displays" =>
      DisplaysI(
        PhoneDisplays::new(
          w,
          text_of(at(Some(c), "file")),
          async fn(grant) { w.ask("displays.usedAt", [js(grant)]) },
          async fn(owner) { ignore(w.ask("displays.changed", [js(owner)])) },
          idle_most?=num_of(at(Some(c), "idleMs")),
        ),
      )
    "registry" =>
      RegistryI(DeviceRegistry::new(w, self.db(text_of(at(Some(c), "db")))))
    "devices" => {
      let registry = DeviceRegistry::new(w, self.db(text_of(at(Some(c), "db"))))
      let phones = match self.insts.get(text_of(at(Some(c), "phones"))) {
        Some(AdbI(a)) => Some(a)
        _ => None
      }
      DevicesI(
        Devices::new(
          w,
          registry,
          phones?,
          rigs=at(Some(c), "rigs") is Some(Bool(true)),
        ),
      )
    }
    k => raise fail_("no such part: \{k}")
  }
  self.insts[id] = inst
  Null
}

///|
/// A part's method.
async fn Harness::call(
  self : Harness,
  id : String,
  name : String,
  args : Array[J],
) -> J {
  match self.insts.get(id) {
    Some(GrantsI(g)) => grants_call(g, name, args)
    Some(AdbI(a)) =>
      match name {
        "stream" => {
          a.stream(arg(args, 0), arg(args, 1), arg(args, 2), arg(args, 3))
          Null
        }
        "reach" => js(a.reach(sarg(args, 0), sarg(args, 1)))
        "phoneUse" => js(a.phone_use(sarg(args, 0), arg(args, 1)))
        "phoneSend" => js(a.phone_send(sarg(args, 0), arg(args, 1)))
        "adbDevices" => js(a.adb_devices())
        "phoneEntries" => ja(a.phone_entries(sarg(args, 0)))
        "phonesShown" => ja(a.phones_shown(sarg(args, 0)))
        "phoneDeviceUse" =>
          js(a.phone_device_use(sarg(args, 0), arg(args, 1), sarg(args, 2)))
        "phoneDone" => jsa(a.phone_done(sarg(args, 0), arg(args, 1)))
        "nameOf" => js(a.name_of(sarg(args, 0)))
        "list" => ja(a.shares.list())
        "gone" => jo(a.shares.gone.iter().map(p => (p.0, p.1)).collect())
        "close" => {
          a.close()
          Null
        }
        _ => grants_call(a.grants, name, args)
      }
    Some(SharesI(s)) =>
      match name {
        "answerAdb" => {
          answer_adb(s, arg(args, 0), arg(args, 1), arg(args, 2), arg(args, 3))
          Null
        }
        "list" => ja(s.list())
        "close" => {
          s.close()
          Null
        }
        "screens" => {
          s.screens(sarg(args, 0), strings(arg(args, 1)))
          Null
        }
        "regrant" => {
          s.regrant(sarg(args, 0))
          Null
        }
        "gone" => jo(s.gone.iter().map(p => (p.0, p.1)).collect())
        "tcpAsked" => jsa(s.tcp_asked.iter().collect())
        "state" =>
          match s.by_key.get(sarg(args, 0)) {
            Some(sh) =>
              jo([
                ("state", sh.state),
                ("version", ji(sh.version)),
                ("streams", ji(sh.streams)),
                ("failures", ji(sh.failures)),
                ("offer", ji(sh.offer)),
                ("port", ji(sh.port)),
                ("line", sh.line()),
              ])
            None => Null
          }
        "keepTcp" =>
          match s.by_key.get(sarg(args, 0)) {
            Some(sh) => {
              keep_tcp(s, sh, sarg(args, 1), strings(arg(args, 2)))
              Null
            }
            None => raise fail_("no such share")
          }
        "serversOf" =>
          match s.by_key.get(sarg(args, 0)) {
            Some(sh) =>
              match servers_of(s, sh) {
                Some(out) => ja(out.map(jsa))
                None => Null
              }
            None => raise fail_("no such share")
          }
        _ => raise fail_("no such method: \{name}")
      }
    Some(ServersI(s)) =>
      match name {
        "reap" =>
          ji(
            s.reap(previous_gone=async fn() {
              ignore(s.w.ask("previous.gone", []))
            }),
          )
        "ensure" =>
          match s.ensure(sarg(args, 0)) {
            Some(sv) => jo([("port", ji(sv.port)), ("child", sv.child)])
            None => Null
          }
        "stop" => {
          s.stop(sarg(args, 0))
          Null
        }
        "ids" => jsa(s.ids())
        "owner" => opt_j(s.owner(arg(args, 0), strings(arg(args, 1))))
        "written" => {
          s.written()
          Null
        }
        "close" => {
          s.close()
          Null
        }
        _ => raise fail_("no such method: \{name}")
      }
    Some(DisplaysI(d)) =>
      match name {
        "open" =>
          d.open(
            sarg(args, 0),
            sarg(args, 1),
            sarg(args, 2),
            narg(args, 3).to_int(),
            sarg(args, 4),
          )
        "titles" => jsa(d.titles(sarg(args, 0)))
        "has" => jb(d.has(sarg(args, 0)))
        "close" => {
          d.close(sarg(args, 0))
          Null
        }
        "idle" => {
          d.idle()
          Null
        }
        "closeAll" => {
          d.close_all()
          Null
        }
        _ => raise fail_("no such method: \{name}")
      }
    Some(RegistryI(r)) =>
      match name {
        "of" => ja(r.of(sarg(args, 0)))
        "get" => r.get(sarg(args, 0), sarg(args, 1)).unwrap_or(Null)
        "add" =>
          result_j(
            r.add(sarg(args, 0), arg(args, 1), arg(args, 2), narg(args, 3)),
          )
        "remove" => jb(r.remove(sarg(args, 0), sarg(args, 1)))
        _ => raise fail_("no such method: \{name}")
      }
    Some(DevicesI(d)) =>
      match name {
        "deviceList" => js(d.device_list(sarg(args, 0)))
        "deviceUse" => js(d.device_use(sarg(args, 0), arg(args, 1)))
        "all" => ja(d.all(sarg(args, 0), sarg(args, 1)))
        "listed" => ja(d.listed(sarg(args, 0)))
        "changed" => {
          d.changed(arg(args, 0))
          Null
        }
        "sideDevice" =>
          d.side_device(
            sarg(args, 0),
            sarg(args, 1),
            arg(args, 2) is Bool(true),
          )
        "busList" => d.bus_list(arg(args, 0))
        "route" =>
          match
            d.route(sarg(args, 0), sarg(args, 1), arg(args, 2), sarg(args, 3)) {
            Some((status, body)) => jo([("status", ji(status)), ("body", body)])
            None => Null
          }
        _ => raise fail_("no such method: \{name}")
      }
    None => raise fail_("no such part: \{id}")
  }
}

///|
async fn grants_call(g : PhoneGrants, name : String, args : Array[J]) -> J {
  match name {
    "ask" => {
      let of = opt_s(args.get(3))
      let r = match of {
        Some(o) =>
          g.ask(
            sarg(args, 0),
            sarg(args, 1),
            reask=arg(args, 2) is Bool(true),
            of=o,
          )
        None =>
          g.ask(sarg(args, 0), sarg(args, 1), reask=arg(args, 2) is Bool(true))
      }
      r.v
    }
    "cardPending" =>
      match g.card_pending(Req::new(arg(args, 0))) {
        Some(b) => jb(b)
        None => Null
      }
    "get" => req_j(g.get(sarg(args, 0)))
    "held" => ja(g.held(sarg(args, 0)).map(r => r.v))
    "ofOwner" =>
      ja(
        match opt_s(args.get(1)) {
          Some(ws) => g.of_owner(sarg(args, 0), workspace=ws)
          None => g.of_owner(sarg(args, 0))
        },
      )
    "grantedOfOwner" => ja(g.granted_of_owner(sarg(args, 0)).map(r => r.v))
    "live" => ja(g.live_all().map(r => r.v))
    "starter" => opt_j(g.starter(sarg(args, 0)))
    "shown" => g.shown(Req::new(arg(args, 0)))
    "used" => {
      g.used(sarg(args, 0), arg(args, 1) is Bool(true))
      Null
    }
    "linked" => {
      g.linked(sarg(args, 0), arg(args, 1))
      Null
    }
    "decide" =>
      opt_j(
        g.decide(
          sarg(args, 0),
          sarg(args, 1),
          opt_s(args.get(2)),
          sarg(args, 3),
          signed?=args.get(4),
        ),
      )
    "sign" =>
      opt_j(g.sign(sarg(args, 0), sarg(args, 1), args.get(2), sarg(args, 3)))
    "revoke" => opt_j(g.revoke(sarg(args, 0), sarg(args, 1), sarg(args, 2)))
    "release" => {
      let ended = match opt_s(args.get(1)) {
        Some(o) => g.release(sarg(args, 0), owner=o)
        None => g.release(sarg(args, 0))
      }
      ja(ended.map(r => r.v))
    }
    "changed" => {
      g.changed(arg(args, 0))
      Null
    }
    "phoneUse" =>
      js(
        phone_use(
          g,
          async fn(owner, grant) {
            js_text(g.w.ask("phone.reach", [js(owner), js(grant)]))
          },
          sarg(args, 0),
          arg(args, 1),
        ),
      )
    _ => raise fail_("no such method: \{name}")
  }
}
