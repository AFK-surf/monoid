// feedback_send and feedback_reply (station/src/tools/feedback.ts): a bug report about still.fail itself, sent to the
// still.fail team, for a station on the stable channel; an answer on one, when the person it works for asks for it.
// And the part that has them (station/src/feedback/module.ts): from stations on the stable channel, in still.fail
// cloud only, each session told when one it sent is fixed and out.

///|
/// What a report is about, as still.fail cloud takes it.
let areas : Array[String] = [
  "station", "web", "android", "desktop", "slack", "cloud", "unknown",
]

///|
/// The report still.fail cloud is sent (feedback.ts `report`): the agent's words, and what the station adds of the
/// session. `key` is the same for the same report from the same session.
pub fn report(c : Ctx, session : JV, args : JV, link : JV) -> JV raise Failed {
  let t = (k : String) => trimmed(args.get(k))
  let title = t("title")
  let body = t("body")
  if title == "" || body == "" {
    raise Failed("title and body are required")
  }
  let area = if areas.contains(t("area")) { t("area") } else { "unknown" }
  let skey = js_string(session.get("key"))
  let key = slice(@cloud_net.sha256_hex("\{skey}\n\{title}\n\{body}"), 0, to=32)
  let context = [
    ("session", field(session, "key")),
    ("connect", field(session, "connect")),
    ("runtime", field(session, "runtime")),
    ("profile", field(session, "profile")),
    ("os", js(c.consts.os)),
    ("arch", js(rust_arch(c.consts.arch))),
  ]
  let model = field(session, "model")
  if !(model is Null) {
    context.push(("model", model))
  }
  if t("to") != "" {
    context.push(("thread", js(t("to"))))
  }
  if !(link is Null) {
    context.push(("link", link))
  }
  let os = t("desktopPlatform")
  if os == "macos" || os == "windows" {
    context.push(("desktopPlatform", js(os)))
  }
  let out = [
    ("key", js(key)),
    ("title", js(title)),
    ("body", js(body)),
    ("area", js(area)),
    ("reporter", js(t("reporter"))),
    ("context", jobj(context)),
  ]
  if t("logs") != "" {
    out.push(("logs", js(t("logs"))))
  }
  jobj(out)
}

///|
/// The tools: the store (`store`), a session's page on still.fail cloud (`link`), and the senders, each asked for as
/// it is used (`send`, `reply`: null while there is none, else a function by reference) or given (`senders`).
pub fn feedback_tools(
  c : Ctx,
  store? : String = "store",
  link? : async (String) -> JV,
  send? : async () -> (async (JV) -> JV)?,
  reply? : async () -> (async (JV) -> JV)?,
) -> Array[Tool] {
  let b = c.b
  let link = match link {
    Some(l) => l
    None => k => b.ask("feedback.link", [js(k)])
  }
  let by_ref = (name : String) => async fn() -> (async (JV) -> JV)? {
    let f = b.ask(name, [])
    match ref_of(f) {
      Some(_) => Some(x => b.invoke(f, [x]))
      None => None
    }
  }
  let send = match send {
    Some(s) => s
    None => by_ref("feedback.send")
  }
  let reply = match reply {
    Some(r) => r
    None => by_ref("feedback.reply")
  }
  [
    Tool::new(c.decl("feedback_send"), (key, args, _) => {
      let session = b.ask("\{store}.getSession", [js(key)])
      if !truthy(Some(session)) {
        raise Failed("unknown session")
      }
      let made = report(c, session, args, link(key))
      guard send() is Some(sender) else {
        raise Failed(
          "this station is not connected to still.fail cloud, so the report cannot be sent; give the person the report to pass on themselves",
        )
      }
      let answer = sender(made) catch {
        e =>
          raise Failed(
            "the report was not sent (\{message_of(e)}); give the person the report to pass on themselves",
          )
      }
      let number = match answer.get("number") {
        Some(Num(n)) if is_integer(n) && n >= 0.0 => n
        _ =>
          raise Failed(
            "still.fail cloud answered without a number: \{stringify_or_undefined(answer)}",
          )
      }
      if answer.get("duplicate") is Some(Bool(true)) {
        "This report was already sent as FB-\{num_text(number)}."
      } else {
        "Sent to the still.fail team as FB-\{num_text(number)}."
      }
    }),
    Tool::new(c.decl("feedback_reply"), (key, args, _) => {
      if !truthy(Some(b.ask("\{store}.getSession", [js(key)]))) {
        raise Failed("unknown session")
      }
      let number = match args.get("number") {
        Some(Num(n)) if is_integer(n) && n >= 1.0 => n
        _ => raise Failed("number must be the report's number (12 for FB-12)")
      }
      let text = trimmed(args.get("text"))
      if text == "" {
        raise Failed("text is required")
      }
      guard reply() is Some(sender) else {
        raise Failed(
          "this station is not connected to still.fail cloud, so the answer cannot be sent; give the person the text to pass on themselves",
        )
      }
      ignore(
        sender(
          jobj([("number", jnum(number)), ("text", js(text)), ("session", js(key))]),
        ),
      ) catch {
        e => {
          let message = message_of(e)
          if index_of(message, "feedback_not_found") >= 0 {
            raise Failed(
              "FB-\{num_text(number)} is not a report this station sent, so it cannot be answered from here",
            )
          }
          raise Failed(
            "the answer was not sent (\{message}); give the person the text to pass on themselves",
          )
        }
      }
      "Sent to the still.fail team as a reply on FB-\{num_text(number)}."
    }),
  ]
}

///|
/// The names people know the parts by.
fn part_name(part : String) -> String {
  match part {
    "station" => "the station"
    "web" => "the web app (app.still.fail; the desktop app from its next update)"
    "android" => "the Android app"
    "desktop" => "the desktop app"
    "cloud" => "still.fail cloud"
    p => p
  }
}

///|
fn u64_of(v : JV?) -> Double? {
  match v {
    Some(Num(n)) if is_integer(n) && n >= 0.0 => Some(n)
    _ => None
  }
}

///|
/// What a session's agent is told of a fixed report (feedback.ts `fixedNotice`).
pub fn fixed_notice(report : JV, station : String?) -> String {
  let number = num_text(u64_of(report.get("number")).unwrap_or(0.0))
  let title = text(report.get("title"))
  let version = u64_of(report.get("version")).unwrap_or(0.0)
  let parts = strings_of(report.get("parts"))
  let out = StringBuilder::new()
  out.write_string(
    "The still.fail team fixed a bug reported from this session: FB-\{number} \"\{title}\". ",
  )
  if parts.length() == 0 || (parts.length() == 1 && parts[0] == "cloud") {
    out.write_string("The fix is live now.")
  } else {
    let named = parts.map(p => if p == "cloud" {
      part_name(p)
    } else {
      "\{part_name(p)} 0.1.\{num_text(version)}"
    })
    out.write_string("The fix is released in \{named.join(", ")} and later.")
  }
  match station {
    Some(st) if parts.contains("station") => {
      let tail = slice(st, last_index_of(st, ".") + 1)
      let own = if tail != "" && tail.iter().all(ch => ch >= '0' && ch <= '9') {
        Some(@api_routes.js_number(tail))
      } else {
        None
      }
      match own {
        Some(o) if o >= version =>
          out.write_string(" This station runs \{st}: it has the fix.")
        Some(_) =>
          out.write_string(
            " This station runs \{st}: the fix applies once it is updated (in still.fail, the station's page).",
          )
        None => ()
      }
    }
    _ => ()
  }
  if parts.iter().any(p => p == "web" || p == "android" || p == "desktop") {
    out.write_string(
      " An app gets it once it is updated to that version or later.",
    )
  }
  match report.get("thread") {
    Some(Str(thread)) =>
      out.write_string(
        " Tell the person who reported it, in the thread it was reported in (\{thread}), briefly and in their language; nothing else needs doing.",
      )
    _ =>
      out.write_string(
        " Tell the person who reported it, where they reported it, briefly and in their language; nothing else needs doing.",
      )
  }
  out.to_string()
}

///|
/// Asks still.fail cloud for this station's fixed reports (`fixed`, given which were told) and tells each one's
/// session; then says which were told, so they are not again (feedback.ts `tellFixed`).
pub async fn tell_fixed(
  fixed : async (Array[String]) -> JV,
  notify : async (String, String) -> Unit,
) -> Int {
  let answer = fixed([])
  let station = jstr(answer.get("station"))
  let told = []
  for r in jitems(answer.get("fixed")) {
    guard r.get("id") is Some(Str(id)) else { continue }
    match r.get("session") {
      Some(Str(session)) => notify(session, fixed_notice(r, station)) catch { _ => () }
      _ => ()
    }
    told.push(id)
  }
  if told.length() > 0 {
    ignore(fixed(told))
  }
  told.length()
}

///|
/// The feedback part as the station has it once made (module.ts `FeedbackLive`): its tools, its route, what a
/// read-only member may ask of it, what the overview says, and the telling of fixed reports (a while after the start,
/// `told_after_ms`, and as each release is out).
pub struct FeedbackPart {
  tools : Array[Tool]
  routes : Array[ReportRoute]
  overview : async () -> Bool
  told_after_ms : Int
  telling_fixed : async () -> Unit
}

///|
/// Reporting changes nothing on the station: a read-only member may.
pub fn feedback_viewer_may(verb : String, path : String) -> Bool {
  verb == "POST" && @api_routes.re(report_path).matches(path)
}

///|
/// The part, made (None: not here, a station not on the stable channel or a control plane without feedback). The
/// control plane is `plane` (its state `plane.state`, of which `state` is data), the station's key `key`, the agents'
/// parts `agents` (`updates`, `hub`, `pageOf`), the paths `paths` (`data`, a field).
pub async fn feedback_live(c : Ctx, home : String) -> FeedbackPart? {
  let b = c.b
  let cloud = jref("plane.state")
  let key = jref("key")
  let channel = b.ask("agents.updates.channel", [])
  if !(channel is Str("stable")) {
    return None
  }
  if !truthy(b.ask("plane.spec", []).get("feedback")) {
    return None
  }
  let removed = async fn() -> Bool { truthy(Some(b.ask("plane.state.removed", []))) }
  let state = async fn() -> JV { b.ask("plane.state.state", []) }
  let signed = async fn(path : String, purpose : String, body : JV) -> JV {
    b.ask("cloud/signed.signedPost", [cloud, key, js(path), js(purpose), body])
  }
  let send_report = async fn(report : JV) -> JV {
    if removed() {
      raise Failed("this station was removed from its workspace")
    }
    // The workspace its chat is in (a joined one's, else the home's): where the team's replies are shown.
    let session = match jget(report.get("context"), "session") {
      Some(Str(s)) => b.ask("store.getSession", [js(s)])
      _ => Null
    }
    let workspace = match jget(Some(session), "ws") {
      Some(w) if !(w is Null) && !is_undef(w) => Some(w)
      _ =>
        match state() {
          Obj(_) as st if !is_undef(st) => st.get("workspace")
          _ => None
        }
    }
    let context = match report.get("context") {
      Some(Obj(_) as ctx) if !is_undef(ctx) => ctx
      _ => jobj([])
    }
    let fields = [("version", b.ask("ops/version.version", []))]
    if truthy(workspace) {
      fields.push(("workspace", workspace.unwrap()))
    }
    let report = spread(report, [("context", spread(context, fields))])
    signed("/v1/feedback", "stillfail-station-feedback-v1", report)
  }
  let fixed = async fn(told : Array[String]) -> JV {
    if removed() {
      return jobj([("fixed", jarr([]))])
    }
    let answer = signed(
      "/v1/feedback/fixed",
      "stillfail-station-feedback-fixed-v1",
      jobj([("told", jstrs(told))]),
    )
    spread(answer, [("station", b.ask("ops/version.version", []))])
  }
  let answer = async fn(body : JV) -> JV {
    if removed() {
      raise Failed("this station was removed from its workspace")
    }
    signed("/v1/feedback/reply", "stillfail-station-feedback-reply-v1", body)
  }
  let data = said_text(b.ask("paths.data", []))
  let page_of = async fn(k : String) -> JV {
    let p = b.ask("agents.pageOf", [js(k)])
    if is_undef(p) {
      Null
    } else {
      p
    }
  }
  let tools = feedback_tools(
    c,
    link=page_of,
    send=async fn() {
      let s = state()
      if truthy(Some(s)) && !is_undef(s) {
        Some(send_report)
      } else {
        None
      }
    },
    reply=async fn() {
      let s = state()
      if truthy(Some(s)) && !is_undef(s) {
        Some(answer)
      } else {
        None
      }
    },
  )
  let deps : ReportDeps = {
    log_tail: most => read_tail(b, path_join([data, "stillfail.log"]), most),
    versions: async fn() {
      let out = []
      for v in jitems(Some(b.ask("agents.updates.get", [js("en")]))) {
        if truthy(v.get("installed")) && truthy(v.get("version")) {
          out.push((js_string(v.get("id")), field(v, "version")))
        }
      }
      jobj(out)
    },
    env_names: async fn() {
      let names = jfields(Some(b.ask("ops/agent-env.agentEnv", []))).map(p => p.0)
      names.sort_by((x, y) => js_compare(x, y))
      names
    },
    link: page_of,
    home,
  }
  let routes = report_routes(c, deps, send_report)
  let telling_fixed = async fn() {
    ignore(
      tell_fixed(fixed, (session, text) => b.tell("agents.hub.notify", [
        js(session),
        js(text),
      ])),
    ) catch {
      error =>
        b.log(
          "warn",
          "feedback",
          "fixed bug reports not read",
          jobj([("error", js(message_of(error)))]),
        )
    }
  }
  // What was fixed and came out while the station was not running, a while after it starts; then as each release is
  // out. On the hub's clock, ended with the station.
  b.tell("ops/fibers.Fibers.after", [jint(300000), jobj([("$fn", jbool(true))])])
  b.tell("plane.told", [js("release"), jobj([("$fn", jbool(true))])])
  Some({
    tools,
    routes,
    overview: async fn() {
      let s = state()
      !(s is Null) && !is_undef(s)
    },
    told_after_ms: 300000,
    telling_fixed,
  })
}
