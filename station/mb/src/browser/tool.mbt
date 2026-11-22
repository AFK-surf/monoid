// browser (src/browser/tool.ts): the chat's own Chrome (browsers.mbt), for its agent to drive over its DevTools with
// its own client (chrome-devtools-mcp, Playwright). Its profile keeps the sign-ins made in it, this chat's alone: no
// other chat's agent reaches them, and they go when the chat is archived. A person can see and drive its tabs from
// their app (the `screen` tool gives the link), which is how an agent asks for a sign-in or a captcha. The session
// reaches it at its own address on the door (proxy.mbt).

///|
/// The tool's declaration (its name, description and parameters), as the agents are given it.
pub fn browser_declaration() -> J {
  jo([
    ("name", js("browser")),
    (
      "description",
      js(
        "This chat's own browser (Chrome, or Farview where the station has it), its sign-ins this chat's alone until it is archived. action endpoint (default) starts it and says how to drive it; tabs lists its tabs; status says whether it runs; stop closes it (sign-ins stay). Skill stillfail-browser. Sign in to a site with `sign_in` on its sign-in page; a captcha or consent: give a person the tab with `screen`.",
      ),
    ),
    (
      "inputSchema",
      jo([
        ("type", js("object")),
        (
          "properties",
          jo([
            (
              "action",
              jo([
                ("type", js("string")),
                ("enum", jsa(["endpoint", "tabs", "status", "stop", "open", "close"])),
                ("description", js("Default endpoint. open, close: Farview's.")),
              ]),
            ),
            ("tab", jo([("type", js("string")), ("description", js("Farview tab id (default: first)."))])),
            ("url", jo([("type", js("string"))])),
            (
              "engine",
              jo([
                ("type", js("string")),
                ("enum", jsa(["chrome", "farview"])),
                ("description", js("This chat's browser from now on.")),
              ]),
            ),
          ]),
        ),
        ("additionalProperties", jb(false)),
      ]),
    ),
  ])
}

///|
/// This session's address of the browser (proxy.mbt), from the door's MCP URL; None without one (Chrome's own).
pub fn session_ws(door_url : String?, session : String) -> String? {
  match door_url {
    None => None
    Some(u) => {
      let a = if u.has_prefix("http:") { "ws:" + slice(u, 5) } else { u }
      let b = if a.has_suffix("/mcp") { slice(a, 0, b=a.length() - 4) } else { a }
      Some(b + session_path(session))
    }
  }
}

///|
fn opt_text(s : String?) -> String {
  s.unwrap_or("undefined")
}

///|
/// What `endpoint` tells the agent: where (`ws`, this session's address), how to connect, and how to share it.
pub fn how_to(s : BrowserStatus, ws : String?) -> String {
  let at_ = match ws {
    Some(w) => w
    None => opt_text(s.http)
  }
  let binary = match s.binary {
    Some(b) if b != "" => b
    _ => "Chrome"
  }
  let headless = if s.headless == Some(true) { ", headless" } else { "" }
  [
    "This chat's browser runs (\{binary}\{headless}).",
    "DevTools for this chat: \{at_}",
    "",
    "Connect with your own client at this address:",
    match ws {
      Some(w) => "- chrome-devtools-mcp: `npx -y chrome-devtools-mcp@latest --wsEndpoint \{w}`"
      None => "- chrome-devtools-mcp: `npx -y chrome-devtools-mcp@latest --browserUrl \{opt_text(s.http)}`"
    },
    "- Playwright: `const browser = await chromium.connectOverCDP(\"\{at_}\"); const page = await browser.contexts()[0].newPage();` — the default context holds the sign-ins; a new context has none.",
    "",
    "It is this chat's alone: its sign-ins are the ones made in it (none of another chat's). Close the tabs you are done with.",
    "Never launch another Chrome for work that needs a login: this one keeps them.",
    "To be signed in to a site, open its sign-in page here and call `sign_in {site, reason}`: it asks for the sign-in the vault keeps, or has the person sign in from a card with their own password manager. Never ask for a password in the chat.",
    "When a page needs a person for anything else (a captcha, a consent), give them that tab with the `screen` tool (a link to see and drive it from their app), ask in the chat (need_human), and end your turn; carry on when they say it is done.",
    match ws {
      Some(_) => "If the connection drops (the browser was restarted or closed after a long idle, the station restarted), connect again to the same address: it starts the browser if needed."
      None => "If the connection drops (the browser was restarted or closed after a long idle), call browser again: the address usually stays the same."
    },
  ].join("\n")
}

///|
pub fn tabs_text(tabs : Array[TabInfo]) -> String {
  if tabs.length() == 0 {
    return "No tabs open (or the browser is not running)."
  }
  tabs
  .map(t => {
    let title = if t.title != "" { quote(t.title) + " " } else { "" }
    let attached = if t.attached { " (a client is attached)" } else { "" }
    "- \{t.id} \{title}\{t.url}\{attached}"
  })
  .join("\n")
}

///|
/// What the tool asks of the browsers (browsers.mbt `Browsers`): each session's chat's.
pub(all) struct ToolBrowsers {
  endpoint : async (String) -> BrowserStatus
  tabs : (String) -> Array[TabInfo]
  status : (String) -> BrowserStatus
  stop : async (String) -> Unit
}

///|
pub fn Browsers::tool_browsers(self : Browsers) -> ToolBrowsers {
  {
    endpoint: async fn(s) { self.endpoint(s) },
    tabs: s => self.tabs(s),
    status: s => self.status(s),
    stop: async fn(s) { self.stop(s) },
  }
}

///|
/// One of the station's tools: its declaration and what it does for a session with its arguments.
pub(all) struct BrowserTool {
  declaration : J
  run : async (String, J) -> String
}

///|
fn int_text(n : Int?) -> String {
  match n {
    Some(v) => v.to_string()
    None => "undefined"
  }
}

///|
/// The tool (tool.ts `browserTools`). `door_url`: the agents' door's MCP URL once it is open, where each session is
/// given its address. `farview`: the chats' Farview, used in place of Chrome for the chats it is the browser of.
pub fn browser_tools(
  browser : ToolBrowsers,
  door_url? : () -> String? = () => None,
  farview? : FarviewTabs,
) -> Array[BrowserTool] {
  [
    {
      declaration: browser_declaration(),
      run: async fn(session, args) {
        let av = Some(args)
        let action = match at(av, "action") {
          Some(Str(u)) => @jsjson.sanitize_str(u)
          _ => "endpoint"
        }
        let engine = text(at(av, "engine"))
        if engine == "chrome" || engine == "farview" {
          guard farview is Some(f) && f.active() is Some(_) else {
            raise fail_(
              "This station has no Farview (config.json `browser.farview` is false, or no release for this system): this chat's browser is Chrome.",
            )
          }
          f.choose(session, engine)
          // (Farview chosen: the chat's Chrome closed, as choosing Chrome ends its Farview; its sign-ins stay)
          if engine == "farview" {
            (browser.stop)(session)
          }
        }
        match farview {
          Some(f) =>
            match f.active() {
              Some(config) if f.active_for(session) =>
                return farview_run(f, config, session, action, text(at(av, "tab")), text(at(av, "url")))
              _ => ()
            }
          None => ()
        }
        match action {
          "endpoint" => how_to((browser.endpoint)(session), session_ws(door_url(), session))
          "tabs" => tabs_text((browser.tabs)(session))
          "status" => {
            let s = (browser.status)(session)
            if s.running {
              let at_ = match session_ws(door_url(), session) {
                Some(w) => w
                None => opt_text(s.http)
              }
              let headless = if s.headless == Some(true) { ", headless" } else { "" }
              "Running: \{at_}, \{int_text(s.tabs)} tab(s), \{int_text(s.viewing)} view(s) by people\{headless}."
            } else {
              "Not running: `browser` (action endpoint) starts it."
            }
          }
          "stop" => {
            (browser.stop)(session)
            "This chat's browser is closed (its profile and sign-ins stay)."
          }
          "open" | "close" =>
            raise fail_("\{action} is Farview's: in Chrome, open and close tabs over its DevTools (action endpoint)")
          _ => raise fail_("unknown action \{action}: endpoint, tabs, status or stop")
        }
      },
    },
  ]
}

///|
fn farview_tabs_text(tabs : Array[FarviewTab]) -> String {
  if tabs.length() == 0 {
    return "No tabs open (or the browser is not running): `browser` (action endpoint) starts it."
  }
  tabs
  .map(t => {
    let title = if t.info.title != "" { quote(t.info.title) + " " } else { "" }
    "- \{t.info.id} \{title}\{t.info.url} (agent port \{t.agent})"
  })
  .join("\n")
}

///|
async fn farview_run(
  farview : FarviewTabs,
  config : FarviewConfig,
  session : String,
  action : String,
  tab : String,
  url : String,
) -> String {
  match action {
    "endpoint" => {
      ignore(farview.endpoint(session))
      if tab != "" && farview.agent_port(session, id=tab) is None {
        raise fail_("no such tab in this chat's browser: \{tab}")
      }
      farview_how_to(config, farview.tabs(session))
    }
    "tabs" => farview_tabs_text(farview.tabs(session))
    "open" => {
      ignore(farview.endpoint(session))
      let t = farview.open(session, url)
      let on = if url == "" { "about:blank" } else { url }
      "Opened \{t.info.id} on \{on}. Drive it with: `\{config.agent} 127.0.0.1 \{t.agent} <step>...`"
    }
    "close" => {
      if tab == "" {
        raise fail_("close: say which tab (`tab`, an id from tabs)")
      }
      farview.close_tab(session, tab)
      "Closed \{tab}."
    }
    "status" => {
      let s = farview.status(session)
      if !s.running {
        return "Not running: `browser` (action endpoint) starts it."
      }
      let port = match farview.agent_port(session, id=tab) {
        Some(p) => ", agent port \{p}"
        None => ""
      }
      "Running: Farview, \{int_text(s.tabs)} tab(s)\{port}, \{int_text(s.viewing)} view(s) by people."
    }
    "stop" => {
      farview.stop(session)
      "This chat's browser is closed (its cookies and storage stay)."
    }
    _ => raise fail_("unknown action \{action}: endpoint, tabs, open, close, status or stop")
  }
}
