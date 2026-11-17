// screen (station/src/tools/screen.ts): the screens of this station a person can see and drive from their still.fail
// app, who is on each now, and the link that opens one, for the agent to post when a person has to do something there.
// The screens are the screen hub's (`screens`): `listed`, `get` (a source by reference, whose fields are given by
// `$source`), `takeControl`, `endView`, `watchOnly`, `endViews`, `refresh`; how a view is said, screens/hub.ts's
// `viewOn`; a refusal it throws is `ScreenRefused` (its words' `key` and `args`).

///|
/// A source's fields (its id, whether it is a person's own tab, whether it has `access` and `ui`), as the hub gives
/// them by its reference.
pub(all) struct Source {
  ref_ : JV
  id : String
  user_tab : Bool
  has_access : Bool
  has_ui : Bool
}

///|
/// The source `hub.get(id)` gives, if there is one.
pub async fn source_of(b : ToolsBackend, hub : String, id : String) -> Source? {
  let got = b.ask("\{hub}.get", [js(id)])
  source_from(b, got)
}

///|
async fn source_from(b : ToolsBackend, got : JV) -> Source? {
  guard ref_of(got) is Some(_) else { return None }
  let spec = b.ask("$source", [got])
  Some({
    ref_: got,
    id: js_string(spec.get("id")),
    user_tab: truthy(spec.get("userTab")),
    has_access: is_true(spec.get("access")),
    has_ui: is_true(spec.get("ui")),
  })
}

///|
fn Source::call(self : Source, method : String) -> String {
  "\{ref_of(self.ref_).unwrap_or("")}.\{method}"
}

///|
/// encodeURIComponent.
fn encode_component(s : String) -> String {
  @api_routes.encode_uri_component(s)
}

///|
/// A ScreenRefused's words in English: tr("en", e.key, e.args).
fn refused_words(c : Ctx, said : JV) -> String {
  let args = jfields(said.get("args")).map(p => (p.0, js_string(Some(p.1))))
  c.tr("en", js_string(said.get("key")), args~)
}

///|
/// What the agent is told: the screens (one, with `id`), and how to hand one to a person (screen.ts `described`).
pub async fn described(
  c : Ctx,
  hub : String,
  base : String?,
  id : String?,
) -> String {
  let b = c.b
  let listed = b.ask("\{hub}.listed", [js("en")])
  let all = jitems(listed.get("screens")).filter(s => !truthy(s.get("userTab")))
  let shown = match id {
    None => all
    Some(i) => all.filter(s => s.get("id") is Some(Str(x)) && x == i)
  }
  if id is Some(i) && shown.length() == 0 {
    match source_of(b, hub, i) {
      Some(s) if s.user_tab => raise Failed(c.tr("en", "station.screen.userOnly"))
      _ => ()
    }
    let ids = all.map(s => js_string(s.get("id"))).join(", ")
    raise Failed(
      "no screen \{i} on this station (it has: \{if ids == "" { "none" } else { ids }})",
    )
  }
  let screens = []
  for s in shown {
    let fields = jfields(Some(s)).filter(f => f.0 != "access" && f.0 != "views")
    let on = []
    for v in jitems(s.get("views")) {
      let entry = [("view", field(v, "id")), ("who", field(v, "name"))]
      if !truthy(v.get("agent")) {
        entry.push(("where", b.ask("screens/hub.viewOn", [v])))
      }
      entry.push(("controlling", field(v, "control")))
      on.push(jobj(entry))
    }
    fields.push(("on", jarr(on)))
    fields.push(
      (
        "link",
        match base {
          None => Null
          Some(base) =>
            js("\{base}/screen/\{encode_component(js_string(s.get("id")))}")
        },
      ),
    )
    if truthy(s.get("access")) {
      fields.push(("cannot", field(s.get("access").unwrap(), "message")))
    }
    screens.push(jobj(fields))
  }
  if screens.length() == 0 {
    return "This station has no screen a person can open now."
  }
  let head = "\{pretty(jarr(screens))}\n\n"
  head +
  (
    match base {
      None => "This station's control plane has no pages, so there is no link to give: a person opens its screens from the still.fail app."
      Some(_) => "To have a person act on a screen, post its link on a line of its own in the conversation (chat_post kind=need_human, saying what to do there; the link alone shows as the screen's card) and end your turn; it opens the screen in their still.fail app. viewers: who has it open now; controlledBy: those of them driving it; on: each of their views and the device it is on. A view you are held off by is let go of on that device, or disconnected or made watch-only under Screens on the station's page; or by you with action take_control, disconnect or watch_only, when a person asks you to in the chat."
    }
  )
}

///|
/// A person's request carried out: `action` of the views of `id`, `by` the agent (screen.ts `letGo`).
pub async fn let_go(
  c : Ctx,
  hub : String,
  by : JV,
  id : JV?,
  action : String,
  view : JV?,
) -> String {
  let b = c.b
  guard id is Some(Str(id)) && id != "" else {
    raise Failed("\{action} needs id, the screen")
  }
  match source_of(b, hub, id) {
    Some(s) if s.user_tab => raise Failed(c.tr("en", "station.screen.userOnly"))
    _ => ()
  }
  let one = () => match view {
    Some(Str(v)) if v != "" => v
    _ => raise Failed("\{action} needs view, a view's id from the list")
  }
  let shown_view = js_string(view)
  try {
    match action {
      "take_control" => {
        let n = b.ask("\{hub}.takeControl", [js(id), by])
        "\{js_string(Some(n))} people's views of \{id} now only look; your input goes through until one of them takes it back. Tell them when you are done."
      }
      "disconnect" => {
        b.tell("\{hub}.endView", [js(id), js(one()), by])
        "View \{shown_view} of \{id} disconnected; it is not opened again by itself."
      }
      "watch_only" => {
        b.tell("\{hub}.watchOnly", [js(id), js(one())])
        "View \{shown_view} of \{id} now only looks."
      }
      "disconnect_all" => {
        let n = b.ask("\{hub}.endViews", [js(id), by])
        "\{js_string(Some(n))} people's views of \{id} disconnected."
      }
      _ =>
        raise Failed(
          "no action \{action}: list, take_control, disconnect, watch_only or disconnect_all",
        )
    }
  } catch {
    e =>
      match thrown_as(e, "ScreenRefused") {
        Some(said) => raise Failed(refused_words(c, said))
        None => raise e
      }
  }
}

///|
/// The tool. `base`: this station's place in its control plane's pages (`base`, null without pages); `name`: a
/// session's name among a screen's people (`agentName`).
pub fn screen_tools(
  c : Ctx,
  hub? : String = "screens",
  base? : String = "base",
  name? : String = "agentName",
) -> Array[Tool] {
  let b = c.b
  [
    Tool::new(c.decl("screen"), (session, args, _) => {
      match args.get("action") {
        Some(Str(action)) if action != "" && action != "list" => {
          let by = b.ask(name, [js(session)])
          let said = let_go(c, hub, by, args.get("id"), action, args.get("view"))
          b.log(
            "info",
            "screens",
            "an agent let go of a view",
            jobj([
              ("session", js(session)),
              ("screen", js(js_string(args.get("id")))),
              ("action", js(action)),
              (
                "view",
                js(
                  match args.get("view") {
                    None | Some(Null) => ""
                    Some(v) if is_undef(v) => ""
                    v => js_string(v)
                  },
                ),
              ),
            ]),
          )
          said
        }
        _ => {
          // The desktop as it is now (its size; on macOS its grants).
          b.tell("\{hub}.refresh", [])
          let base = jstr(Some(b.ask(base, [])))
          let id = match args.get("id") {
            Some(Str(i)) if i != "" => Some(i)
            _ => None
          }
          described(c, hub, base, id)
        }
      }
    }),
  ]
}
