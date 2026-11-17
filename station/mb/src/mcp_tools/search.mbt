// The agents' search (station/src/search/tool.ts) and skill_read (src/search/skills.ts): what a few words find in the
// workspace, on every station of it at once, each station answering for its own (`search.query`, asked over the
// mesh), with the links of its chats; a skill read in full by its name. What they ask (`searchDeps.*`): the search
// itself (`search.query`), a skill's file (`readSkill`), a session's place (`workspaceOf`), a chat's link (`link`),
// the workspace's stations (`stations`) and another station (`ask`).

///|
/// What another station is asked.
pub let search_method : String = "search.query"

///|
pub let skill_read_method : String = "skill.read"

///|
/// How long another station has to answer before it is said not to have.
let wait_ms : Int = 20000

///|
/// What is said of each kind at most, and of each hit.
let shown_most : Int = 5

///|
let text_chars : Int = 200

///|
pub let search_kinds : Array[String] = [
  "chat", "message", "history", "job", "skill", "memory", "profile", "file",
]

///|
/// Within `ms`, or failed with `why` (ops/fibers.ts `wall.within`).
async fn[X] within_ms(ms : Int, f : async () -> X, why : String) -> X {
  match @effect.timeout(ms, f) {
    Some(x) => x
    None => raise Failed(why)
  }
}

///|
/// Each hit with the link of its chat, where it is in one.
async fn linked(b : ToolsBackend, deps : String, groups : JV) -> JV {
  let out = []
  for g in jitems(Some(groups)) {
    let hits = []
    for h in jitems(g.get("hits")) {
      match h.get("chat") {
        Some(Str(chat)) => {
          let l = b.ask("\{deps}.link", [js(chat)])
          if truthy(Some(l)) && !is_undef(l) {
            hits.push(spread(h, [("link", b.ask("\{deps}.link", [js(chat)]))]))
          } else {
            hits.push(h)
          }
        }
        _ => hits.push(h)
      }
    }
    out.push(spread(g, [("hits", jarr(hits))]))
  }
  jarr(out)
}

///|
/// What `request` asks of this station from another (`ws`: the workspace it was asked in; None: the home one).
pub async fn search_for_peer(
  b : ToolsBackend,
  request : JV,
  ws : String?,
  home : String?,
  deps? : String = "searchDeps",
) -> JV {
  let query = text(jget(Some(request), "query"))
  let asked = strings_of(jget(Some(request), "kinds"))
  // All of them, the execution history too, when none is named.
  let kinds = if asked.length() > 0 { asked } else { search_kinds }
  let limit = match jget(Some(request), "limit") {
    Some(Num(n)) => jnum(n)
    _ => jint(shown_most)
  }
  let asker = jobj([
    (
      "workspace",
      js(
        match (ws, home) {
          (Some(w), _) => w
          (None, Some(h)) => h
          _ => ""
        },
      ),
    ),
    ("home", jbool(ws is None || ws == home)),
    ("scopes", jstrs(["write"])),
  ])
  let found = b.ask("\{deps}.search.query", [
    js(query),
    asker,
    jobj([("kinds", jstrs(kinds)), ("limit", limit)]),
  ])
  jobj([
    ("groups", linked(b, deps, field(found, "groups"))),
    ("building", field(found, "building")),
  ])
}

///|
fn one_line(t : String) -> String {
  let flat = trim_js(squeeze_spaces(t))
  if flat.length() > text_chars {
    slice(flat, 0, to=text_chars) + "…"
  } else {
    flat
  }
}

///|
fn hit_line(h : JV) -> String {
  let where_ = []
  match h.get("chatTitle") {
    Some(Str(t)) if t != "" => where_.push("in “\{t}”")
    _ => ()
  }
  match h.get("link") {
    Some(Str(l)) => where_.push(l)
    _ => ()
  }
  match h.get("seq") {
    Some(Num(n)) => where_.push("message #\{num_text(n)}")
    _ => ()
  }
  match h.get("index") {
    Some(Num(n)) => where_.push("history #\{num_text(n)}")
    _ => ()
  }
  match h.get("job") {
    Some(Str(j)) => {
      let port = match h.get("port") {
        Some(Num(p)) => " (port \{num_text(p)})"
        _ => ""
      }
      where_.push("job \{j}\{port}")
    }
    _ => ()
  }
  match h.get("path") {
    Some(Str(p)) => where_.push(p)
    _ => ()
  }
  if h.get("archived") is Some(Bool(true)) {
    where_.push("archived")
  }
  let at = match h.get("at") {
    Some(Num(ms)) =>
      " (\{replace_all(slice(iso_string(ms), 0, to=16), "T", " ")} UTC)"
    _ => ""
  }
  let title = match h.get("title") {
    Some(Str("")) => ""
    t => "\{js_string(t)}: "
  }
  let where_text = if where_.length() > 0 {
    " — \{where_.join(", ")}"
  } else {
    ""
  }
  "- \{title}\{one_line(text(h.get("text")))}\{at}\{where_text}"
}

///|
fn said_groups(name : String, groups : Array[JV], station : String) -> String {
  if groups.length() == 0 {
    return "## \{name}\nNothing found."
  }
  let parts = groups.map(g => {
    let kind = js_string(g.get("kind"))
    let left = if truthy(g.get("left")) {
      "\n- … \{js_string(g.get("left"))} older sessions' history not looked through (out of time): narrow the words, or ask this station alone"
    } else {
      ""
    }
    let more = if truthy(g.get("more")) && !truthy(g.get("left")) {
      "\n- … more: ask with kinds=[\"" + kind + "\"] and a higher limit"
    } else {
      ""
    }
    let lines = jitems(g.get("hits")).map(h => {
      let read = match h.get("skill") {
        Some(Str(skill)) if kind == "skill" =>
          " — read with skill_read \{stringify(jobj([("station", js(station)), ("name", js(skill))]))}"
        _ => ""
      }
      hit_line(h) + read
    })
    "### \{kind}\n\{lines.join("\n")}\{more}\{left}"
  })
  "## \{name}\n\{parts.join("\n")}"
}

///|
/// `selection` of skills.ts: the skill and its file asked for.
fn selection(args : JV) -> (String, String) raise Failed {
  let name = match args.get("name") {
    Some(Str(n)) if trim_js(n) != "" => n
    _ => raise Failed("name is required: use a skill name returned by search")
  }
  let file = match args.get("file") {
    None => "SKILL.md"
    Some(x) if is_undef(x) => "SKILL.md"
    Some(Str(f)) if f != "" => f
    _ => raise Failed("file must be a listed Markdown filename")
  }
  (name, file)
}

///|
/// A skill's file as `skill_read` gives it, out of the catalog of the workspace it is read in.
pub fn format_skill_from_catalog(
  catalog : JV,
  name : String,
  file : String,
) -> String raise Failed {
  guard jitems(catalog.get("skills")).iter().find_first(s => jstr(s.get("name")) ==
      Some(name))
    is Some(skill) else {
    raise Failed("No skill \{quoted(name)} in this workspace on this station")
  }
  let files = jitems(skill.get("files"))
  let text = if file == "SKILL.md" {
    skill.get("text")
  } else {
    match files.iter().find_first(f => jstr(f.get("name")) == Some(file)) {
      Some(f) => f.get("text")
      None => None
    }
  }
  guard text is Some(Str(text)) else {
    raise Failed(
      "No file \{quoted(file)} in skill \{quoted(name)}; read SKILL.md for the available files",
    )
  }
  let names = ["SKILL.md", ..files.map(f => js_string(f.get("name")))]
  "Skill \{quoted(name)}, file \{quoted(file)}\nAvailable files: \{names.map(quoted).join(", ")}\n\n\{text}"
}

///|
/// Another station of the workspace reading a skill here (`skill.read` on the bus): `read_catalog` reads the catalog
/// of a workspace (None: the home one's).
pub async fn skill_for_peer(
  read_catalog : async (String?) -> JV,
  request : JV,
  workspace : String?,
  home : String?,
) -> JV {
  let req = match request {
    Null => jobj([])
    x if is_undef(x) => jobj([])
    x => x
  }
  let (name, file) = selection(req)
  let catalog = read_catalog(
    if workspace is None || workspace == home {
      None
    } else {
      workspace
    },
  )
  jobj([("text", js(format_skill_from_catalog(catalog, name, file)))])
}

///|
/// The workspace's stations, as `stations` answers them.
fn stations_of(v : JV) -> Array[(String, String, Bool)] {
  jitems(Some(v)).map(s => (
    js_string(s.get("id")),
    js_string(s.get("name")),
    truthy(s.get("here")),
  ))
}

///|
/// skill_read and search.
pub fn search_tools(c : Ctx, deps? : String = "searchDeps") -> Array[Tool] {
  let b = c.b
  let read_skill = async fn(place : JV, name : String, file : String) -> String {
    let ws = if truthy(place.get("home")) {
      jundef
    } else {
      field(place, "workspace")
    }
    said_text(b.ask("\{deps}.readSkill", [ws, js(name), js(file)]))
  }
  [
    Tool::new(c.decl("skill_read"), (session, args, _) => {
      let (name, file) = selection(args)
      let place = b.ask("\{deps}.workspaceOf", [js(session)])
      if !truthy(Some(place)) || is_undef(place) {
        raise Failed("unknown session")
      }
      let only = lower(trimmed(args.get("station")))
      if only == "" || only == "this station" {
        return read_skill(place, name, file)
      }
      let stations = stations_of(
        b.ask("\{deps}.stations", [field(place, "workspace")]),
      )
      let chosen = stations.filter(s => lower(s.0) == only || lower(s.1) == only)
      if chosen.length() != 1 {
        raise Failed(
          if chosen.length() > 0 {
            "Station name is ambiguous; use the station id from search"
          } else {
            "No such station in this workspace"
          },
        )
      }
      let (id, _, here) = chosen[0]
      if here {
        return read_skill(place, name, file)
      }
      let answer = within_ms(
        wait_ms,
        () => b.ask("\{deps}.ask", [
          js(id),
          jobj([
            ("method", js(skill_read_method)),
            ("workspace", field(place, "workspace")),
            ("session", js(session)),
            ("name", js(name)),
            ("file", js(file)),
          ]),
        ]),
        "Station did not answer skill.read within 20 s",
      )
      match jget(Some(answer), "text") {
        Some(Str(t)) => t
        _ =>
          raise Failed(
            "Station did not return a skill; it may need an update to support skill.read",
          )
      }
    }),
    Tool::new(c.decl("search"), (session, args, _) => {
      let query = trimmed(args.get("query"))
      if query == "" {
        raise Failed("query is required")
      }
      if query.length() > 200 {
        raise Failed("a search is at most 200 characters")
      }
      let asked = strings_of(args.get("kinds"))
      let kinds = if asked.length() > 0 { asked } else { search_kinds }
      let limit = {
        let l = match args.get("limit") {
          Some(Num(n)) => n.floor()
          _ => shown_most.to_double()
        }
        let l = if l < 50.0 { l } else { 50.0 }
        if l > 1.0 {
          l
        } else {
          1.0
        }
      }
      let place = b.ask("\{deps}.workspaceOf", [js(session)])
      if place is Null || is_undef(place) {
        raise Failed("unknown session")
      }
      let only = lower(trimmed(args.get("station")))
      let mut stations = stations_of(
        b.ask("\{deps}.stations", [field(place, "workspace")]),
      ) catch {
        // In no workspace's mesh yet: this station alone.
        _ => []
      }
      if !stations.iter().any(s => s.2) {
        stations = [("", "this station", true), ..stations]
      }
      let chosen = if only == "" {
        stations
      } else {
        stations.filter(s => lower(s.0) == only || lower(s.1) == only)
      }
      if chosen.length() == 0 {
        raise Failed(
          "no station \{stringify_or_undefined(field(args, "station"))} in this workspace",
        )
      }
      let parts = @effect.all(
        chosen.map(s => async fn() -> String {
          let (id, sname, here) = s
          let name = if here { "\{sname} (this station)" } else { sname }
          try {
            if here {
              let found = b.ask("\{deps}.search.query", [
                js(query),
                spread(place, [("scopes", jstrs(["write"]))]),
                jobj([("kinds", jstrs(kinds)), ("limit", jnum(limit))]),
              ])
              let groups = linked(b, deps, field(found, "groups"))
              said_groups(name, jitems(Some(groups)), if id != "" { id } else { sname })
            } else {
              let answer = within_ms(
                wait_ms,
                () => b.ask("\{deps}.ask", [
                  js(id),
                  jobj([
                    ("method", js(search_method)),
                    ("session", js(session)),
                    ("workspace", field(place, "workspace")),
                    ("query", js(query)),
                    ("kinds", jstrs(kinds)),
                    ("limit", jnum(limit)),
                  ]),
                ]),
                "did not answer within \{wait_ms / 1000} s",
              )
              let groups = match jget(Some(answer), "groups") {
                Some(Arr(g)) => g
                _ => []
              }
              said_groups(name, groups, id)
            }
          } catch {
            error => "## \{name}\nNot searched: \{message_of(error)}"
          }
        }),
      )
      "Search for \{quoted(query)}:\n\n\{parts.join("\n\n")}"
    }),
  ]
}
