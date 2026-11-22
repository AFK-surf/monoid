// The station's drive as members ask it (routes/drive.ts): its pinned folders, a folder's listing, a file's part
// read and written, folders made, renamed, removed, zipped, watched, a file staged for a message; and copies into it
// (routes/transfers.ts): a grant another station reads with, a transfer started, listed, cancelled, retried. A refusal
// is `{error, code}` with the code's status, in the asker's words (`station.drive.<code>`).

///|
/// A refusal of the drive's (drive/drive.ts DriveError): its code and message.
pub(all) suberror DriveErr {
  DriveErr(String, String)
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for DriveErr with output(self, logger) {
  match self {
    DriveErr(_, m) => logger.write_string(m)
  }
}

///|
fn drive_status(code : String) -> Int32 {
  @drive.code_status(code)
}

///|
const MANAGE : String = "a read-only member does not pin folders"

///|
const TOO_BIG : String = "too big to send"

///|
const MAX_READ : Double = 8388608.0

///|
const MOST_ROOTS : Int32 = 32

///|
const MOST_STAGED : Double = 1073741824.0

///|
const GRANT_MS : Double = 604800000.0

///|
fn base_name(p : String) -> String {
  @nodepath.basename("/", p)
}

///|
/// A refusal in the asker's words.
fn Admin::drive_refused(self : Admin, e : Error, lang : String) -> Answer {
  let (code, message, said) = match e {
    DriveErr(code, message) => (code, message, JV::Obj([]))
    Thrown("DriveError", said) =>
      (js_string(said.get("code")), message_of(e), said)
    _ => ("io", message_of(e), Obj([]))
  }
  let words = match said.get("need") {
    Some(Obj(_) as need) => {
      let key = match jstr(need.get("window")) {
        Some("up") => "station.drive.helperAsking"
        Some("closed") => "station.drive.helperClosed"
        _ => "station.drive.helperNeeded"
      }
      let grant = js_string(need.get("grant"))
      let top = js_string(need.get("top"))
      let folder = if grant == "documents" ||
        grant == "desktop" ||
        grant == "downloads" {
        let cap = grant.unsafe_substring(start=0, end=1).to_upper() +
          grant.unsafe_substring(start=1, end=grant.length())
        self.tr(lang, "station.drive.place.\{cap}")
      } else {
        let b = base_name(top)
        if b == "" {
          top
        } else {
          b
        }
      }
      self.tr(lang, key, args=[("folder", folder)])
    }
    _ =>
      self.tr(
        lang,
        if code == "permission" && message == MANAGE {
          "station.drive.manage"
        } else if code == "too_large" && message == TOO_BIG {
          "station.drive.tooBigToSend"
        } else {
          "station.drive.\{code}"
        },
      )
  }
  let about = said.get("about")
  let text = if is_truthy(about) {
    "\{js_string(about)}: \{words}"
  } else {
    words
  }
  let fields = [("error", js(text)), ("code", js(code))] +
    (match said.get("have") {
      Some(h) if !is_undef(h) => [("have", h)]
      _ => []
    })
  json(drive_status(code), stringify(jobj(fields)))
}

///|
/// The drive as the asker's workspace has it: its name for the calls (the station's, or a joined workspace's).
async fn Admin::drive_of(self : Admin, r : Request) -> String {
  if r.who("home") is Some(Bool(false)) {
    ref_of(
      self.backend.ask("drive.scoped", [r.who("workspace").unwrap_or(jundef)]),
    ).unwrap_or("drive")
  } else {
    "drive"
  }
}

///|
fn anywhere(r : Request) -> Bool {
  !read_only(r.viewer)
}

///|
/// A request's JSON object (none is `{}`); anything else refused as the drive refuses.
fn drive_body(r : Request) -> JV raise DriveErr {
  match body_or_empty(r) {
    Some(Obj(_) as o) => o
    _ => raise DriveErr("invalid_request", "a JSON object")
  }
}

///|
fn drive_text(v : JV?, name : String) -> String raise DriveErr {
  match v {
    Some(Str(s)) => s
    _ => raise DriveErr("invalid_request", "\{name} is required")
  }
}

///|
fn drive_num(r : Request, name : String, fallback : Double) -> Double {
  match r.param(name) {
    None => fallback
    Some(v) => if re("^[0-9]+$").matches(v) { js_number(v) } else { -1.0 }
  }
}

///|
async fn Admin::home_dir(self : Admin) -> JV {
  self.backend.ask("os.homedir", [])
}

///|
/// What GET /drive and the overview say: the folders pinned, what the viewer may do.
async fn Admin::drive_view(self : Admin, r : Request) -> JV {
  let roots = self.backend.ask(self.drive_of(r) + ".roots", [])
  let all = anywhere(r)
  jobj(
    [
      ("roots", roots),
      ("manage", jbool(manages_station(r.viewer))),
      ("write", jbool(!read_only(r.viewer))),
    ] +
    (if all {
      [("anywhere", jbool(true)), ("home", self.home_dir())].filter(f => {
        !is_undef(f.1)
      })
    } else {
      []
    }) +
    (if self.setup.has("platform.trash") {
      [("trash", jbool(true))]
    } else {
      []
    }) +
    [("watch", jbool(true))] +
    (if all { [("zip", jbool(true))] } else { [] }) +
    [("transfers", jbool(true))],
  )
}

///|
fn Admin::drive_routes(self : Admin) -> Array[Route] {
  let answer = (f : async (Request) -> JV) => {
    async fn(r : Request, _m : Array[String?]) -> Answer {
      ok(f(r)) catch {
        e => self.drive_refused(e, r.lang)
      }
    }
  }
  let root_of = (r : Request) => r.param("root").unwrap_or("")
  let path_of = (r : Request) => r.param("path").unwrap_or("")
  let stage = if self.setup.has("drive.stage") {
    [
      route(
        "POST",
        "^\\/drive\\/stage$",
        answer(async fn(r) {
          // Sending is writing (a read-only member sends nothing; the admin API refuses it first).
          if read_only(r.viewer) {
            raise DriveErr("permission", "a read-only member sends nothing")
          }
          let b = drive_body(r)
          let root = drive_text(b.get("root"), "root")
          let path = drive_text(b.get("path"), "path")
          let staging = self.callback_answering(async fn(args) {
            let name = jstr(args.get(0)).unwrap_or("")
            let (safe, path) = self.upload_path(
              join([self.setup.data.unwrap_or(""), "uploads"]),
              name,
            )
            jobj([("safe", js(safe)), ("path", js(path))])
          })
          self.backend.ask(self.drive_of(r) + ".stage", [
            js(root),
            js(path),
            staging,
            jnum(MOST_STAGED),
            jbool(anywhere(r)),
            jbool(b.get("zip") is Some(Bool(true))),
          ])
        }),
      ),
    ]
  } else {
    []
  }
  [
    route("GET", "^\\/drive$", answer(async fn(r) { self.drive_view(r) })),
    route(
      "PUT",
      "^\\/drive\\/roots$",
      answer(async fn(r) {
        if !anywhere(r) {
          raise DriveErr("permission", MANAGE)
        }
        let asked = drive_body(r).get("roots")
        guard asked is Some(Arr(asked)) &&
          asked.length() <= MOST_ROOTS &&
          asked.all(p => p is Str(_)) else {
          raise DriveErr(
            "invalid_request",
            "roots: at most \{MOST_ROOTS} paths",
          )
        }
        // The asker's workspace's own list: one the station joined keeps its own (`drive.workspaces`).
        let ws = if r.who("home") is Some(Bool(false)) {
          r.who("workspace").unwrap_or(jundef)
        } else {
          Null
        }
        let before = jitems(
          Some(self.backend.ask("drive/drive.rootsOf", [self.config_raw(), ws])),
        )
        let roots : Array[JV] = []
        for p in asked {
          // One named before stays even while it is not there: it is only checked when new.
          let clean = match before.iter().find_first(b => b == p) {
            Some(b) => b
            None => self.backend.ask("drive.checkRoot", [p])
          }
          if !roots.contains(clean) {
            roots.push(clean)
          }
        }
        self.config_update(raw => {
          let was = spread_of(raw.get("drive"))
          let next = if ws is Null {
            jset(was, "roots", jarr(roots))
          } else {
            let workspaces = match was.get("workspaces") {
              None | Some(Null) => JV::Obj([])
              v => spread_of(v)
            }
            jset(
              was,
              "workspaces",
              jset(workspaces, js_string(Some(ws)), jarr(roots)),
            )
          }
          jset(raw, "drive", next)
        })
        self.overview_changed()
        self.drive_view(r)
      }),
    ),
    route(
      "GET",
      "^\\/drive\\/folders$",
      answer(async fn(r) {
        if !anywhere(r) {
          raise DriveErr("permission", MANAGE)
        }
        self.backend.ask("drive.folders", [
          js(r.param("path").unwrap_or("")),
          self.home_dir(),
          js(r.lang),
        ])
      }),
    ),
    route(
      "GET",
      "^\\/drive\\/list$",
      answer(async fn(r) {
        self.backend.ask(self.drive_of(r) + ".list", [
          js(root_of(r)),
          js(path_of(r)),
          jbool(anywhere(r)),
        ])
      }),
    ),
    route(
      "GET",
      "^\\/drive\\/stat$",
      answer(async fn(r) {
        self.backend.ask(self.drive_of(r) + ".stat", [
          js(root_of(r)),
          js(path_of(r)),
          jbool(anywhere(r)),
        ])
      }),
    ),
    route("GET", "^\\/drive\\/read$", async fn(r, _) {
      try {
        let read = self.backend.ask(self.drive_of(r) + ".read", [
          js(root_of(r)),
          js(path_of(r)),
          jnum(drive_num(r, "offset", 0.0)),
          jnum(drive_num(r, "length", MAX_READ)),
          jbool(anywhere(r)),
        ])
        {
          status: 200,
          headers: {
            "content-type": js_string(read.get("type")),
            "cache-control": "no-store",
            "stillfail-total": js_string(read.get("total")),
            "stillfail-mtime": js_string(read.get("mtime")),
          },
          body: Whole(
            bytes_of(read.get("bytes").unwrap_or(Null)).unwrap_or(b""),
          ),
        }
      } catch {
        e => self.drive_refused(e, r.lang)
      }
    }),
    route(
      "PUT",
      "^\\/drive\\/upload$",
      answer(async fn(r) {
        self.backend.ask(self.drive_of(r) + ".upload", [
          js(root_of(r)),
          js(path_of(r)),
          js(r.param("id").unwrap_or("")),
          jnum(drive_num(r, "offset", 0.0)),
          jnum(drive_num(r, "total", -1.0)),
          jbytes(r.body),
          jbool(r.param("replace") == Some("1")),
          jbool(anywhere(r)),
        ])
      }),
    ),
    route(
      "POST",
      "^\\/drive\\/mkdir$",
      answer(async fn(r) {
        let b = drive_body(r)
        let root = drive_text(b.get("root"), "root")
        let path = drive_text(b.get("path"), "path")
        self.backend.ask(self.drive_of(r) + ".mkdir", [
          js(root),
          js(path),
          jbool(anywhere(r)),
        ])
      }),
    ),
    route(
      "POST",
      "^\\/drive\\/rename$",
      answer(async fn(r) {
        let b = drive_body(r)
        let root = drive_text(b.get("root"), "root")
        let from = drive_text(b.get("from"), "from")
        let to = drive_text(b.get("to"), "to")
        self.backend.ask(self.drive_of(r) + ".rename", [
          js(root),
          js(from),
          js(to),
          jbool(anywhere(r)),
        ])
      }),
    ),
    route(
      "POST",
      "^\\/drive\\/remove$",
      answer(async fn(r) {
        let b = drive_body(r)
        let root = drive_text(b.get("root"), "root")
        let path = drive_text(b.get("path"), "path")
        self.backend.tell(self.drive_of(r) + ".remove", [
          js(root),
          js(path),
          jbool(anywhere(r)),
          jbool(b.get("permanent") is Some(Bool(true))),
        ])
        Obj([])
      }),
    ),
    // A folder zipped to download, for a member who reaches every folder.
    route(
      "POST",
      "^\\/drive\\/zip$",
      answer(async fn(r) {
        if !anywhere(r) {
          raise DriveErr(
            "permission", "a read-only member does not download folders",
          )
        }
        let b = drive_body(r)
        let root = drive_text(b.get("root"), "root")
        let path = drive_text(b.get("path"), "path")
        self.backend.ask(self.drive_of(r) + ".zip", [
          js(root),
          js(path),
          jnum(MOST_STAGED),
          jbool(true),
        ])
      }),
    ),
    // Asked as events: a `changed` event each time something in the folder changes, while the stream is open; a client
    // from before asks it again and again (`{changed}`).
    route("GET", "^\\/drive\\/watch$", async fn(r, _) {
      let folder = async fn() {
        self.backend.ask(self.drive_of(r) + ".folderToWatch", [
          js(root_of(r)),
          js(path_of(r)),
          jbool(anywhere(r)),
        ])
      }
      if header_exact(r.headers, "accept")
        .unwrap_or("")
        .contains("text/event-stream") {
        let dir = folder() catch { e => return self.drive_refused(e, r.lang) }
        return self.drive_followed(dir)
      }
      try {
        let dir = folder()
        let changed = self.backend.ask("drive/watch.changed", [
          dir,
          js(r.param("id").unwrap_or("")),
        ])
        ok(jobj([("changed", changed)]))
      } catch {
        e => self.drive_refused(e, r.lang)
      }
    }),
  ] +
  stage
}

///|
/// GET /drive/watch as events: `changed` each time the folder changes, while the stream is open; a folder that cannot
/// be watched is refused.
async fn Admin::drive_followed(self : Admin, dir : JV) -> Answer {
  let changed = Ref(false)
  let closed = Ref(false)
  let wake : Ref[@effect.Deferred[Unit]?] = Ref(None)
  let told = self.callback(async fn(_) {
    changed.val = true
    match wake.val {
      Some(w) => ignore(w.succeed(()))
      None => ()
    }
  })
  let stop = self.backend.ask("drive/watch.follow", [dir, told])
  guard ref_of(stop) is Some(stop) else {
    return json(
      503,
      stringify(jobj([("error", js("the folder cannot be watched now"))])),
    )
  }
  let next = async fn() {
    while !closed.val && !changed.val {
      let w = @effect.Deferred::new()
      wake.val = Some(w)
      w.wait()
    }
    wake.val = None
    if closed.val {
      return None
    }
    changed.val = false
    Some(utf8("event: changed\ndata: {}\n\n"))
  }
  let close = async fn() {
    if !closed.val {
      closed.val = true
      self.backend.tell(stop, [])
      match wake.val {
        Some(w) => ignore(w.succeed(()))
        None => ()
      }
    }
  }
  { status: 200, headers: event_headers(), body: Streamed(next, close), }
}

///|
/// Names of a folder: at least one, each a name and not a path; each once.
fn names_of(v : JV?) -> Array[String] raise DriveErr {
  guard v is Some(Arr(items)) &&
    items.length() > 0 &&
    items.length() <= 1000 &&
    items.all(n => {
      n is Str(s) &&
      s != "" &&
      s != "." &&
      s != ".." &&
      !s.contains("/") &&
      !s.contains("\u{0}")
    }) else {
    raise DriveErr("invalid_request", "names: 1 to 1000 names of the folder")
  }
  let out = []
  for n in items {
    let s = jstr(Some(n)).unwrap()
    if !out.contains(s) {
      out.push(s)
    }
  }
  out
}

///|
fn conflicts_of(v : JV?) -> JV raise DriveErr {
  match v {
    None | Some(Null) => Obj([])
    Some(Obj(fields)) => {
      let mut out = JV::Obj([])
      for f in fields {
        match f.1 {
          Str("replace" | "keep" | "skip") => out = jset(out, f.0, f.1)
          _ =>
            raise DriveErr(
              "invalid_request", "conflicts: name → replace | keep | skip",
            )
        }
      }
      out
    }
    _ =>
      raise DriveErr(
        "invalid_request", "conflicts: name → replace | keep | skip",
      )
  }
}

///|
fn Admin::transfers_routes(self : Admin) -> Array[Route] {
  let answer = (f : async (Request, Array[String?]) -> JV) => {
    async fn(r : Request, m : Array[String?]) -> Answer {
      ok(f(r, m)) catch {
        e => self.drive_refused(e, r.lang)
      }
    }
  }
  let object_or_empty = (v : JV?) => {
    match v {
      Some(Obj(_) | Arr(_) as o) => o
      _ => Obj([])
    }
  }
  [
    route(
      "POST",
      "^\\/drive\\/grant$",
      answer(async fn(r, _) {
        let b = drive_body(r)
        let root = drive_text(b.get("root"), "root")
        let path = match b.get("path") {
          Some(Str(p)) => p
          _ => ""
        }
        let names = names_of(b.get("names"))
        let move_ = b.get("move") is Some(Bool(true))
        // Moving lets the originals go: a member who may write here.
        if move_ && !anywhere(r) {
          raise DriveErr(
            "permission", "a read-only member copies, and does not move",
          )
        }
        for name in names {
          let drive = self.drive_of(r)
          ignore(
            self.backend.ask(drive + ".stat", [
              js(root),
              js(if path == "" { name } else { "\{path}/\{name}" }),
              jbool(anywhere(r)),
            ]),
          )
        }
        let expires = jnumber(Some(self.backend.ask("transfers.now", []))).unwrap_or(
            0.0,
          ) +
          GRANT_MS
        let g = jobj([
          ("v", jint(1)),
          ("workspace", r.who("workspace").unwrap_or(jundef)),
          ("home", jbool(!(r.who("home") is Some(Bool(false))))),
          ("by", js(r.email())),
          ("anywhere", jbool(anywhere(r))),
          ("root", js(root)),
          ("path", js(path)),
          ("names", jstrs(names)),
          ("move", jbool(move_)),
          ("expires", jnum(expires)),
        ]).filter_undef()
        jobj([
          (
            "grant",
            self.backend.ask("drive/grants.sign", [
              jbytes(self.setup.grant_key),
              g,
            ]),
          ),
          ("expires", jnum(expires)),
        ])
      }),
    ),
    route(
      "POST",
      "^\\/drive\\/transfers$",
      answer(async fn(r, _) {
        // Writing here: a member who may write.
        if !anywhere(r) {
          raise DriveErr(
            "permission", "a read-only member does not copy into a station",
          )
        }
        let b = drive_body(r)
        let from = object_or_empty(b.get("from"))
        let to = object_or_empty(b.get("to"))
        let names = names_of(from.get("names"))
        let station = match from.get("station") {
          Some(Str(s)) if s != "" &&
            Some(js(s)) != Some(self.backend.ask("transfers.self", [])) =>
            Some(s)
          _ => None
        }
        if station is Some(_) && !(from.get("grant") is Some(Str(_))) {
          raise DriveErr(
            "invalid_request", "from.grant is required for another station's files",
          )
        }
        let into = jobj([
          ("root", js(drive_text(to.get("root"), "to.root"))),
          (
            "path",
            match to.get("path") {
              Some(Str(p)) => js(p)
              _ => js("")
            },
          ),
        ])
        // Where they go must be a folder this member may write in.
        let listed = self.backend.ask(self.drive_of(r) + ".stat", [
          into.get("root").unwrap(),
          into.get("path").unwrap(),
          jbool(true),
        ])
        if !is_truthy(listed.get("dir")) {
          raise DriveErr("not_a_directory", "that is not a folder")
        }
        let mut src = jobj([("station", jopt(station))])
        match station {
          Some(s) => {
            src = jset(
              src,
              "stationName",
              self.backend.ask("transfers.nameOf", [js(s)]),
            )
            src = jset(src, "grant", from.get("grant").unwrap())
          }
          None => ()
        }
        src = jset(src, "root", js(drive_text(from.get("root"), "from.root")))
        src = jset(
          src,
          "path",
          match from.get("path") {
            Some(Str(p)) => js(p)
            _ => js("")
          },
        )
        src = jset(src, "names", jstrs(names))
        let conflicts = conflicts_of(b.get("conflicts"))
        let t = self.backend.ask("transfers.start", [
          jobj([
            ("by", js(r.email())),
            ("workspace", r.who("workspace").unwrap_or(jundef)),
            ("home", jbool(!(r.who("home") is Some(Bool(false))))),
            ("anywhere", jbool(true)),
            ("move", jbool(b.get("move") is Some(Bool(true)))),
            ("from", src),
            ("to", into),
            ("conflicts", conflicts),
          ]).filter_undef(),
        ])
        jobj([("transfer", self.backend.ask("drive/transfers.shown", [t]))])
      }),
    ),
    route(
      "GET",
      "^\\/drive\\/transfers$",
      answer(async fn(r, _) {
        let all = jitems(
          Some(self.backend.ask("transfers.list", [js(r.email())])),
        )
        let shown = []
        for i, t in all {
          shown.push(
            self.backend.ask("drive/transfers.shown", [t, jint(i), jarr(all)]),
          )
        }
        jobj([("transfers", jarr(shown))])
      }),
    ),
    route(
      "POST",
      "^\\/drive\\/transfers\\/([A-Za-z0-9]{1,64})\\/(cancel|retry)$",
      answer(async fn(r, m) {
        let t = self.backend.ask("transfers." + m[1].unwrap(), [
          js(r.email()),
          js(m[0].unwrap()),
        ])
        jobj([("transfer", self.backend.ask("drive/transfers.shown", [t]))])
      }),
    ),
  ]
}
