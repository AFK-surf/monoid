// station/src/logins/tool.ts: the agents' `login` tool (agent 的 login 工具): a command failed for want of a login, or
// a person asked for one, and the agent runs the tool's own login command on this station. The agent drives the
// command's terminal (用户定: CLI 的交互由 agent 操作): it reads the screen and answers its prompts (Y/n, menus, a host
// to pick) itself; a person does only the step that needs them, in their own browser (a code to enter, a page to sign
// in on), reached by a login card or the link. What the agent is told never holds the page's address or the code
// (each shown as <link>, <code>): it has no use for them, and so never posts them to Slack or a chat. Nothing types a
// secret: a prompt read without echo is refused.

///|
/// How long a call waits for the command to settle (go quiet: what it waits on is then known), at most.
const START_WAIT_MS : Int = 15000

///|
const INPUT_WAIT_MS : Int = 5000

///|
/// The keys the agent may send, as it names them, and as the terminal does.
let tool_keys : Array[(String, String)] = [
  ("enter", "Enter"),
  ("backspace", "Backspace"),
  ("up", "Up"),
  ("down", "Down"),
  ("left", "Left"),
  ("right", "Right"),
  ("tab", "Tab"),
  ("ctrl-c", "Ctrl-C"),
]

///|
/// The tool as the agents are given it (its name, description and parameters: tool.ts `LOGIN`).
pub fn login_tool() -> J {
  let s = (description : String) => jo([("type", js("string")), ("description", js(description))])
  jo([
    ("name", js("login")),
    (
      "description",
      js(
        "Log this station in to a command-line tool, when a command fails because it is not logged in (401, an expired token) or a person asks for it. command: the tool's own login command, with its browser or device-code option where it has one (skill stillfail-login says which for common CLIs, and what to avoid). You drive the command: each answer shows its screen and says what to do next (a prompt to answer with id and input or key, the login card to post for the person's browser step). Never type a password or token (a prompt that asks for one is refused), and take the answers that leave the OS keychain alone: nobody here can answer its dialog. The login is machine-wide: every chat's agent on this station uses it.",
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
              "command",
              jo([
                ("description", js("Start: the tool's own login command, as a line (gh auth login) or words.")),
                (
                  "anyOf",
                  ja([
                    jo([("type", js("string"))]),
                    jo([("type", js("array")), ("items", jo([("type", js("string"))]))]),
                  ]),
                ),
              ]),
            ),
            (
              "id",
              s(
                "A login's id (start answers it): how it stands, its screen; with input, key or cancel, act on it.",
              ),
            ),
            ("input", s("With id: text typed at its prompt (a key, e.g. enter, follows only if given).")),
            (
              "key",
              jo([
                ("type", js("string")),
                ("enum", jstrs(["enter", "up", "down", "left", "right", "tab", "backspace", "ctrl-c"])),
                ("description", js("With id: a key pressed (after input, if both).")),
              ]),
            ),
            ("cancel", jo([("type", js("boolean")), ("description", js("With id: end that login."))])),
            (
              "paste",
              jo([
                ("type", js("boolean")),
                (
                  "description",
                  js(
                    "With id: true when its screen says the page it gave hands out a code to paste back here (copy the code and paste it below, enter the verification code): the login card gets a field for the person to enter it; you never type it. false takes the field away. Only after a page to open; never for a password or token.",
                  ),
                ),
              ]),
            ),
            (
              "station",
              s(
                "Another station of the workspace to log in, by its name or id: the command runs there; give station with id, input, key, paste and cancel too. Left out: this station.",
              ),
            ),
          ]),
        ),
        ("additionalProperties", jb(false)),
      ]),
    ),
  ])
}

///|
/// JavaScript's `\s`.
fn js_space(c : Int) -> Bool {
  @jsjson.is_js_space(c)
}

///|
/// `text.replace(/https?:\/\/\S+/g, "<link>")`.
fn hide_links(s : String) -> String {
  let out = StringBuilder::new()
  let n = s.length()
  let mut i = 0
  let mut from = 0
  while i < n {
    let scheme = if s.unsafe_substring(start=i, end=n).has_prefix("https://") {
      8
    } else if s.unsafe_substring(start=i, end=n).has_prefix("http://") {
      7
    } else {
      0
    }
    if scheme > 0 && i + scheme < n && !js_space(s.code_unit_at(i + scheme).to_int()) {
      let mut j = i + scheme
      while j < n && !js_space(s.code_unit_at(j).to_int()) {
        j += 1
      }
      out.write_string(s.unsafe_substring(start=from, end=i))
      out.write_string("<link>")
      i = j
      from = j
      continue
    }
    i += 1
  }
  out.write_string(s.unsafe_substring(start=from, end=n))
  out.to_string()
}

///|
/// `text.split(sub).join(with)`.
fn replace_all(s : String, sub : String, with_ : String) -> String {
  @jsjson.js_replace_all(s, sub, with_)
}

///|
/// A login's text with its page's address and code hidden (the agent has no use for them).
fn hidden(login : J, s : String) -> String {
  let out = hide_links(s)
  match get(Some(login), "code") {
    Some(Str(c)) if c.length() > 0 => replace_all(out, c, "<code>")
    _ => out
  }
}

///|
/// The screen as its agent reads it: the lines with something on them (the last 30), the page's address and the code
/// hidden, the line the cursor is on marked.
pub fn screen_for(screen : Screen?, login : J) -> String {
  guard screen is Some(screen) else { return "" }
  let hide = (line : String) => js_trim_end(hidden(login, line))
  let lines = screen.rows.mapi((y, row) => if y == screen.cursor.1 && screen.live {
    hide(row) + "▏"
  } else {
    hide(row)
  })
  let mut end = lines.length()
  while end > 0 && @jscase.trim(lines[end - 1]) == "" {
    end -= 1
  }
  let kept = lines[:end].to_array()
  let shown = []
  for i, l in kept {
    if @jscase.trim(l) != "" || (i > 0 && @jscase.trim(kept[i - 1]) != "") {
      shown.push(l)
    }
  }
  shown[@cmp.maximum(0, shown.length() - 30):].to_array().join("\n")
}

///|
/// Where a login runs, as its agent is told: this station, or another of the workspace (its key, for the card, and its
/// name).
pub(all) struct Where {
  station : String
  name : String
}

///|
fn place_of(where_ : Where?) -> String {
  match where_ {
    Some(w) => "on " + w.name
    None => "on this station"
  }
}

///|
fn card_of(login : J, where_ : Where?) -> String {
  let ps = [("type", js("login")), ("login", or_null(get(Some(login), "id")))]
  if where_ is Some(w) {
    ps.push(("station", js(w.station)))
  }
  replace_all(replace_all(stringify(jo(ps)), ",", ", "), ":", ": ")
}

///|
fn command_line(login : J) -> String {
  match get(Some(login), "command") {
    Some(Arr(words)) => words.map(w => if w is Null { "" } else { js_string_of(w) }).join(" ")
    _ => ""
  }
}

///|
/// What the agent is told of a login: how it stands, its screen, and what to do next.
pub fn told(logins : Logins, login : J, link : String?, where_? : Where) -> String {
  told_with(logins.screen(text(get(Some(login), "id")).unwrap_or("")), login, link, where_?)
}

///|
/// `told` with the login's screen as the logins have it (None: none, as one put away).
pub fn told_with(shown_screen : Screen?, login : J, link : String?, where_? : Where) -> String {
  let l = Some(login)
  let ps = [
    ("id", or_null(get(l, "id"))),
    ("command", js(command_line(login))),
    ("state", or_null(get(l, "state"))),
  ]
  match get(l, "step") {
    Some(Str(s)) if s.length() > 0 => ps.push(("step", Str(s)))
    _ => ()
  }
  if get(l, "waiting") is Some(Bool(true)) {
    ps.push(("waiting", jb(true)))
  }
  if get(l, "paste") is Some(Bool(true)) {
    ps.push(("paste", jb(true)))
  }
  match link {
    Some(k) if k != "" => ps.push(("link", js(k)))
    _ => ()
  }
  let screen = screen_for(shown_screen, login)
  let active = get(l, "endedAt") is None
  let state = text(get(l, "state"))
  let step = text(get(l, "step"))
  let waiting = get(l, "waiting") is Some(Bool(true))
  let paste = get(l, "paste") is Some(Bool(true))
  let station = if where_ is Some(_) { ", station" } else { "" }
  let link_text = match link {
    Some(k) if k != "" => " " + k
    _ => ""
  }
  let card_step = "chat_post with card \{card_of(login, where_)} (card.assignee: who should log in) and a sentence saying who should log in to what \{place_of(where_)} and why, without the link in still.fail chats (the card opens the page); in Slack or Feishu, include the link\{link_text} in the text with that same card; end need_human. You get a station notice when it ends."
  let next = if !active {
    if state == Some("done") {
      "It finished (its command exited 0)."
    } else if state == Some("cancelled") {
      "It was cancelled."
    } else {
      let error = match get(l, "error") {
        Some(Str(e)) if e.length() > 0 => ": " + hidden(login, e)
        _ => "."
      }
      "It failed\{if get(l, "timedOut") is Some(Bool(true)) { " (out of time)" } else { "" }}\{error}"
    }
  } else if (match shown_screen {
      Some(s) => !s.echo
      None => false
    }) &&
    waiting {
    "It asks for a secret (read without echo): do not type it, nothing is sent to such a prompt. Cancel it, and use the tool's browser or device-code login, or tell the person it cannot be logged in this way."
  } else if state == Some("verifying") {
    "What came back (the code the person entered, or the browser's callback) is being checked: you get a station notice when it ends."
  } else if paste {
    "The person's browser step is ready: they open the page and enter what it gives (a code) in the login card's field, which types it here; do not answer its prompt yourself. " +
    card_step
  } else if waiting {
    "It waits on the prompt above: answer it with login {id\{station}, input and/or key} (the tool's default, usually key enter, or what the task needs)" +
    (if step == Some("open") {
      ", unless it asks for what the page it gave hands out (a code to paste back): then do not answer it; login {id\{station}, paste: true} gives the login card a field for the person, and post the card as below"
    } else {
      ""
    }) +
    ". If you truly cannot decide, ask the person in the chat."
  } else if step == Some("device") || step == Some("loopback") || step == Some("open") {
    "The person's browser step is ready" +
    (if step == Some("open") {
      " (if the screen says the page gives a code to paste back here, first login {id\{station}, paste: true}: the card gets a field for it; never type it yourself)"
    } else {
      ""
    }) +
    ": " +
    card_step
  } else {
    "It is still working: look again with login {id\{station}}."
  }
  let state_json = jo(ps)
  let shown = match where_ {
    Some(w) => {
      let out = match state_json {
        Obj(xs) => xs.copy()
        _ => []
      }
      out.push(("station", js(w.station)))
      out.push(("stationName", js(w.name)))
      J::Obj(out)
    }
    None => state_json
  }
  pretty(shown) + "\n\nScreen:\n" + (if screen == "" { "(nothing yet)" } else { screen }) + "\n\n" + next
}

///|
/// Who may act on a login, and what a new one is for (act's `o`).
pub(all) struct Acting {
  starter : () -> Starter
  link : (String) -> String?
  where_ : Where?
  /// Whether the caller may act on a login (one of another station's agents may only on those it started).
  mine : ((String) -> Bool)?
}

///|
/// A call of the tool acted on this station's logins: started, looked at, answered or cancelled; what its agent is
/// told. Raises Failure with the words the agent is told, as the TypeScript's Error.
pub async fn act(logins : Logins, args : J, o : Acting) -> String {
  let a = Some(args)
  match get(a, "id") {
    Some(Str(u)) if u.length() > 0 => {
      let id = u
      if logins.get(id) is None ||
        (match o.mine {
          Some(m) => !m(id)
          None => false
        }) {
        raise Failure("no login \{id}")
      }
      if get(a, "cancel") is Some(Bool(true)) {
        logins.cancel(id) |> ignore
      } else if get(a, "paste") is Some(Bool(on)) {
        logins.paste(id, on) |> ignore
      } else if get(a, "input") is Some(Str(_)) || get(a, "key") is Some(Str(_)) {
        let key = match get(a, "key") {
          Some(Str(k)) => {
            let low = @jscase.lower(k)
            match tool_keys.search_by(p => p.0 == low) {
              Some(i) => Some(tool_keys[i].1)
              None => raise Failure("key: one of " + tool_keys.map(p => p.0).join(", "))
            }
          }
          _ => None
        }
        // (settled on by itself: a refused input leaves it going, as the TypeScript's promise)
        let waits = logins.settle_start(id)
        let done : @effect.Deferred[Unit] = @effect.Deferred::new()
        logins.spawn(async fn() {
          logins.settle_finish(id, waits, INPUT_WAIT_MS) |> ignore
          done.succeed(()) |> ignore
        })
        match get(a, "input") {
          Some(Str(t)) if t.length() > 0 => logins.input(id, text=Str(t))
          _ => ()
        }
        match key {
          Some(k) => logins.input(id, key=js(k))
          None => ()
        }
        done.wait()
      }
      let login = logins.get(id).unwrap()
      return told(logins, login, (o.link)(id), where_?=o.where_)
    }
    _ => ()
  }
  let command = match get(a, "command") {
    Some(Str(_) as c) | Some(Arr(_) as c) => c
    _ =>
      raise Failure(
        "command: the tool's own login command (e.g. gh auth login); or id to see or act on one",
      )
  }
  let started = logins.start(command, (o.starter)())
  let started_id = text(get(Some(started), "id")).unwrap_or("")
  let login = match logins.settle(started_id, START_WAIT_MS) {
    Some(l) => l
    None => started
  }
  told(logins, login, (o.link)(text(get(Some(login), "id")).unwrap_or("")), where_?=o.where_)
}

///|
/// What the tool's `run` is given of the station (tool.ts LoginToolDeps).
pub(all) struct LoginToolDeps {
  logins : () -> Logins?
  /// A login on another station of the workspace (`station`, by its name or id): what that station answers its
  /// agent's call with.
  remote : (async (String, String, J) -> String)?
  /// Who a session's login is for: its chat's starter and workspace, its chat and title.
  starter : (String) -> Starter
  /// The link that opens a login in a person's client (None outside a workspace with pages).
  link : (String, String) -> String?
}

///|
/// The tool's call by `session`.
pub async fn run_login_tool(deps : LoginToolDeps, session : String, args : J) -> String {
  match get(Some(args), "station") {
    Some(Str(u)) if @jscase.trim(u) != "" => {
      guard deps.remote is Some(remote) else {
        raise Failure("logging in another station is not there yet: log in on this station")
      }
      return remote(@jscase.trim(u), session, args)
    }
    _ => ()
  }
  guard (deps.logins)() is Some(logins) else { raise Failure("the station is starting: try again in a moment") }
  act(logins, args, {
    starter: () => (deps.starter)(session),
    link: id => (deps.link)(session, id),
    where_: None,
    mine: None,
  })
}

///|
/// What a session that started a login, or posted its card, is told when it ends.
pub fn ended_notice(login : J, link : String?, where_? : Where) -> String {
  let l = Some(login)
  let which = command_line(login) + " (login \{text(get(l, "id")).unwrap_or("")})"
  let state = text(get(l, "state"))
  let how = if state == Some("done") {
    "finished (its command exited 0). Carry on with what needed it, and check it works"
  } else if state == Some("cancelled") {
    "was cancelled. Ask whether it is still wanted before starting another"
  } else {
    let error = match get(l, "error") {
      Some(Str(e)) if e.length() > 0 => {
        let lines = e.split("\n").map(x => x.to_string()).collect()
        ": " + hidden(login, lines[@cmp.maximum(0, lines.length() - 9):].to_array().join(" / "))
      }
      _ => ""
    }
    "failed\{error}. Start it again if it is still needed"
  }
  let link_text = if state == Some("done") {
    ""
  } else {
    match link {
      Some(k) if k != "" => " (Its link was \{k}.)"
      _ => ""
    }
  }
  "The login \{place_of(where_)} you started or posted a card for, \{which}, \{how}.\{link_text} Its card was closed."
}

///|
/// What its agent is told when, after its person's browser step, the command asks something again.
pub fn prompt_notice(logins : Logins, login : J, link : String?, where_? : Where) -> String {
  prompt_notice_with(logins.screen(text(get(Some(login), "id")).unwrap_or("")), login, link, where_?)
}

///|
/// `prompt_notice` with the login's screen.
pub fn prompt_notice_with(screen : Screen?, login : J, link : String?, where_? : Where) -> String {
  "The login \{place_of(where_)} you started, \{command_line(login)} (login \{text(get(Some(login), "id")).unwrap_or("")}), asks something again:\n\n" +
  told_with(screen, login, link, where_?)
}
