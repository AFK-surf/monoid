// permissions (station/src/tools/permissions.ts): what macOS lets still.fail Helper do on this Mac, and a grant asked
// for: the helper's window up on the Mac for it, with how a person gives it. The grants are the helper's
// (`grants`: `view`, `refresh`, `request`; a refusal `GrantRefused` by its words' `key`), the machine's name
// `os.hostname`.

///|
pub let grant_ids : Array[String] = [
  "capture", "control", "documents", "desktop", "downloads", "removable", "network", "localNetwork",
]

///|
/// What each grant is, and what goes without it.
fn grant_what(g : String) -> String {
  match g {
    "capture" => "Screen Recording: people see this Mac's screen from their still.fail app; the computer tool's screenshots of the desktop"
    "control" => "Accessibility: people drive this Mac's screen; the computer tool's clicks and typing on the desktop"
    "documents" => "Documents folder: the drive (people's 文件) reaches ~/Documents"
    "desktop" => "Desktop folder: the drive reaches ~/Desktop"
    "downloads" => "Downloads folder: the drive reaches ~/Downloads (and files people drop into the screen land there)"
    "removable" => "Removable volumes: the drive reaches disks plugged into this Mac"
    "network" => "Network volumes: the drive reaches network disks mounted on this Mac"
    "localNetwork" => "Local Network: devices on this Mac's LAN reach the station straight, and it reaches them (the station's own, not still.fail Helper's); without it they go through a relay or a router"
    _ => "undefined"
  }
}

///|
async fn machine(b : ToolsBackend) -> String {
  let h = said_text(b.ask("os.hostname", []))
  if h.has_suffix(".local") {
    slice(h, 0, to=h.length() - 6)
  } else {
    h
  }
}

///|
/// The grants as macOS has them now, in a line each.
async fn grants_listed(b : ToolsBackend, grants : String) -> String {
  let view = b.ask("\{grants}.view", [])
  if view is Null {
    return "still.fail Helper did not answer, so the grants are not known now."
  }
  let asking = strings_of(view.get("asking"))
  let rows = jitems(view.get("grants")).map(g => {
    let grant = js_string(g.get("grant"))
    let state = jstr(g.get("state"))
    let said = match state {
      Some("granted") => "granted"
      Some("denied") =>
        if grant == "localNetwork" {
          let name = match view.get("localNetworkName") {
            Some(Str(n)) => n
            _ => "the station"
          }
          "refused: the LAN is not reached (switched on for \{name} in System Settings › Privacy & Security › Local Network, or a firewall)"
        } else {
          "refused before (its window's Allow opens System Settings)"
        }
      _ => "not granted"
    }
    let up = if asking.contains(grant) {
      "; its window is up on the Mac now"
    } else {
      ""
    }
    "- \{grant} (\{grant_what(grant)}): \{said}\{up}"
  })
  let screen = if truthy(view.get("screen")) {
    "The screen can be seen and driven: a person can grant the rest from wherever they are, through the screen's link."
  } else {
    "The screen cannot be seen and driven: a person grants at the Mac itself."
  }
  "still.fail Helper's grants on \{machine(b)}:\n\{rows.join("\n")}\n\{screen}"
}

///|
/// `grants`: none where there is no helper (not a Mac); `base`: this station's place in its control plane's pages.
pub fn permission_tools(
  c : Ctx,
  grants? : String? = Some("grants"),
  base? : String = "base",
) -> Array[Tool] {
  let b = c.b
  [
    Tool::new(c.decl("permissions"), (_, args, _) => {
      guard grants is Some(grants) else {
        return "This station is not a Mac with still.fail Helper: there is nothing to grant here."
      }
      let asked = args.get("request")
      match asked {
        None | Some(Str("")) => {
          b.tell("\{grants}.refresh", [jbool(true)])
          return grants_listed(b, grants)
        }
        Some(x) if is_undef(x) => {
          b.tell("\{grants}.refresh", [jbool(true)])
          return grants_listed(b, grants)
        }
        _ => ()
      }
      let asked = match asked {
        Some(Str(g)) if grant_ids.contains(g) => g
        _ =>
          raise Failed(
            "no grant \{js_string(asked)} (there are: \{grant_ids.join(", ")})",
          )
      }
      let words = b.ask("helper/files.askWords", [js(c.consts.station_lang)])
      let answer = b.ask("\{grants}.request", [js(asked), words]) catch {
        e =>
          match thrown_as(e, "GrantRefused") {
            Some(said) => raise Failed(c.tr("en", js_string(said.get("key"))))
            None => raise e
          }
      }
      let name = split(grant_what(asked), ":")[0]
      let window = jstr(answer.get("window"))
      let screen = truthy(answer.get("screen"))
      if asked == "localNetwork" && window == Some("up") {
        let app = match jget(Some(b.ask("\{grants}.view", [])), "localNetworkName") {
          Some(Str(n)) => n
          _ => "the station"
        }
        let link = jstr(Some(b.ask(base, [])))
        let where_ = match link {
          Some(l) if screen =>
            "from wherever they are through the screen (post \{l}/screen/desktop on a line of its own with chat_post kind=need_human)"
          _ => "at \{machine(b)} itself (chat_post kind=need_human)"
        }
        return "System Settings › Privacy & Security › Local Network is open on \{machine(b)}. A person switches \{app} on there \{where_}; it takes once \{app} starts again. End your turn; call permissions again to see whether it was granted."
      }
      if window == Some("granted") {
        return "\{name} is granted already.\n\n\{grants_listed(b, grants)}"
      }
      if window == Some("none") {
        raise Failed("still.fail Helper's window could not be shown on this Mac.")
      }
      if window == Some("closed") {
        return "The window asking for \{name} was shown less than 3 minutes ago and closed without it; it is not shown again yet. Ask the person (chat_post kind=need_human) whether they want to grant it, and call this again in a few minutes."
      }
      let link = jstr(Some(b.ask(base, [])))
      let folder = if asked != "capture" && asked != "control" {
        ", then Allow in the prompt macOS shows (a folder refused before opens System Settings › Files and Folders instead, to switch it on there)"
      } else {
        ", then drag still.fail Helper into the list System Settings shows"
      }
      let how = match link {
        Some(l) if screen =>
          "The screen can be seen and driven, so a person can grant it from wherever they are: post \{l}/screen/desktop on a line of its own (it shows as the screen's card) with chat_post kind=need_human, asking them to open it and click Allow in the still.fail Helper window\{folder}."
        _ =>
          "The screen cannot be seen and driven\{if screen { " from a link here (this control plane has no pages)" } else { "" }}, so a person has to do it at the Mac itself: post chat_post kind=need_human asking them to go to \{machine(b)} and click Allow in the still.fail Helper window there\{folder}. Their app's station page shows the grants as they change."
      }
      "still.fail Helper's window asking for \{name} is up on \{machine(b)}. \{how} End your turn; call permissions again to see whether it was granted."
    }),
  ]
}
