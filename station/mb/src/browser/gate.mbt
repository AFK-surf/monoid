// What a chat's agent may do over its connection to the station's browser (src/browser/gate.ts, "A chat's own
// environment"): the browser is one Chrome for every chat, each chat's pages in a browser context of its own, and the
// gate between the agent's connection and Chrome's DevTools lets through only what touches that context. It reads
// every message the agent sends: one on a target session goes only to a session of a target of its own; one to the
// browser itself only when its method is among those below, its targets its own and its context (cookies,
// permissions, downloads, new tabs) put as its own. Of what Chrome sends, it reads only the browser's own news of
// targets (small) and the answers it asked to look at: news of another chat's target never reaches the agent, and a
// target it was attached to on its own (auto-attach) is let go of at once. What it refuses is answered as an error,
// as Chrome answers a method it does not know. A tab asked for is opened in a window of its own behind the others,
// and one asked to be brought forward is answered as done (`behind`, `front`).

///|
/// How a tab is opened: in a window of its own, behind the person's (measured on a Mac, Edge 156, 2026-10-29).
pub fn behind() -> Array[(String, J)] {
  [("newWindow", jb(true)), ("background", jb(true))]
}

///|
/// Methods on the browser's own target, and what of them is the agent's: `target` names a target of its own in
/// params.targetId, `context` puts the chat's context as params.browserContextId (or one the agent made), `answer` is
/// answered here, `pass` goes as it is.
fn browser_method(method : String) -> String? {
  match method {
    "Browser.getVersion" => Some("pass")
    "Browser.getWindowForTarget" => Some("target")
    "Browser.getWindowBounds" => Some("pass")
    "Browser.setWindowBounds" => Some("pass")
    "Browser.setDownloadBehavior" => Some("context")
    "Browser.grantPermissions" => Some("context")
    "Browser.resetPermissions" => Some("context")
    "Browser.setPermission" => Some("context")
    "Schema.getDomains" => Some("pass")
    "Storage.getCookies" => Some("context")
    "Storage.setCookies" => Some("context")
    "Storage.clearCookies" => Some("context")
    "Target.setDiscoverTargets" => Some("pass")
    "Target.setAutoAttach" => Some("pass")
    "Target.setRemoteLocations" => Some("pass")
    "Target.getTargets" => Some("pass")
    "Target.getTargetInfo" => Some("target")
    "Target.attachToTarget" => Some("target")
    "Target.detachFromTarget" => Some("own")
    "Target.closeTarget" => Some("target")
    "Target.activateTarget" => Some("answer")
    "Target.exposeDevToolsProtocol" => Some("target")
    "Target.autoAttachRelated" => Some("target")
    "Target.sendMessageToTarget" => Some("own")
    "Target.createTarget" => Some("context")
    "Target.createBrowserContext" => Some("pass")
    "Target.disposeBrowserContext" => Some("context")
    "Target.getBrowserContexts" => Some("answer")
    _ => None
  }
}

///|
/// A context's cookies: gated as on the browser's target wherever they are asked (they name a context).
fn cookie_method(m : String) -> Bool {
  m == "Storage.getCookies" || m == "Storage.setCookies" || m == "Storage.clearCookies"
}

///|
/// Target sessions' methods that operate a tab (navigation, input, script evaluation, file selection).
fn acting_method(m : String) -> Bool {
  match m {
    "Page.navigate"
    | "Page.reload"
    | "Page.navigateToHistoryEntry"
    | "Page.setDocumentContent"
    | "Input.dispatchMouseEvent"
    | "Input.dispatchKeyEvent"
    | "Input.dispatchTouchEvent"
    | "Input.insertText"
    | "Input.imeSetComposition"
    | "Runtime.callFunctionOn"
    | "Runtime.evaluate"
    | "DOM.focus"
    | "DOM.setFileInputFiles" => true
    _ => false
  }
}

///|
/// The browser's news of targets the gate reads (with a target's info, or its id).
fn news_method(m : String) -> Bool {
  match m {
    "Target.targetCreated" | "Target.targetInfoChanged" | "Target.targetDestroyed" | "Target.targetCrashed" | "Target.attachedToTarget"
    | "Target.detachedFromTarget" | "Target.receivedMessageFromTarget" => true
    _ => false
  }
}

///|
/// Ids of what the gate itself asks of Chrome (letting go of a target): far from any a client counts to.
let own_ids : Int = 2_000_000_000

///|
pub(all) struct GateParts {
  /// The chat's context.
  context : String
  /// The context of a target, as the station knows it (tabs.mbt), when it does.
  context_of : (String) -> String?
  /// A tab the agent asked for, opened (its id).
  opened : ((String) -> Unit)?
  /// A deliberate action on a tab (not page background traffic).
  used : ((String, String?) -> Unit)?
  /// An operating command on a tab (`acting_method`, `Target.closeTarget`): returns why it is refused, or None.
  act : ((String, String) -> String?)?
}

///|
/// What to do with a message: send these to Chrome, these back to the agent.
pub(all) struct Passed {
  up : Array[String]
  down : Array[String]
}

///|
fn none_passed() -> Passed {
  { up: [], down: [] }
}

///|
/// An error as Chrome answers one: `{id, sessionId?, error: {code, message}}` (an id of none left out, as
/// JSON.stringify leaves out undefined).
fn gate_error(id : J?, session_id : J?, message : String) -> String {
  let fs : Array[(String, J)] = []
  match id {
    Some(i) => fs.push(("id", i))
    None => ()
  }
  match session_id {
    Some(Str(_) as s) => fs.push(("sessionId", s))
    _ => ()
  }
  fs.push(("error", jo([("code", ji(-32601)), ("message", js(message))])))
  stringify(jo(fs))
}

///|
/// `{id, sessionId?, result}`.
fn gate_answer(id : J?, session_id : String?, result : J) -> String {
  let fs : Array[(String, J)] = []
  match id {
    Some(i) => fs.push(("id", i))
    None => ()
  }
  match session_id {
    Some(s) => fs.push(("sessionId", js(s)))
    None => ()
  }
  fs.push(("result", result))
  stringify(jo(fs))
}

///|
pub struct Gate {
  priv p : GateParts
  /// Contexts the agent made itself (Target.createBrowserContext): its own too.
  priv contexts : Array[String]
  /// Targets known to be the agent's (made by it, or told of in its contexts).
  priv mine : Map[String, Unit]
  /// Target sessions of the agent's own targets, on this connection.
  priv sessions : Map[String, Unit]
  priv targets : Map[String, String]
  /// Target sessions Chrome attached on its own to targets not the agent's: let go of, and nothing of them passed.
  priv foreign : Map[String, Unit]
  /// The agent's requests whose answers are looked at, by their id: what to do with each.
  priv asked : Map[String, (J) -> String?]
  /// What the gate itself asked of Chrome and is not answered yet, by id: its answers are its own.
  priv own : Map[Double, Unit]
  priv mut own_id : Int
}

///|
pub fn Gate::new(p : GateParts) -> Gate {
  {
    p,
    contexts: [],
    mine: {},
    sessions: {},
    targets: {},
    foreign: {},
    asked: {},
    own: {},
    own_id: own_ids,
  }
}

///|
/// Whether `ctx` is the agent's.
fn Gate::ours(self : Gate, ctx : J?) -> Bool {
  match ctx {
    Some(Str(u)) => {
      let c = @jsjson.text(u)
      c == self.p.context || self.contexts.contains(c)
    }
    _ => false
  }
}

///|
/// Whether target `id` is the agent's (what its info says of its context, else what is known of it).
fn Gate::target(self : Gate, id : J?, info? : J?) -> Bool {
  guard id is Some(Str(u)) else { return false }
  let tid = @jsjson.text(u)
  if self.mine.contains(tid) {
    return true
  }
  let ctx = match at(info.unwrap_or(None), "browserContextId") {
    None | Some(Null) => (self.p.context_of)(tid).map(js)
    some => some
  }
  if !self.ours(ctx) {
    return false
  }
  self.mine[tid] = ()
  true
}

///|
/// `${x}` of a JSON value (undefined as "undefined").
fn key_part(v : J?) -> String {
  js_str(v)
}

///|
/// A message from the agent.
pub fn Gate::from_client(self : Gate, text_ : String) -> Passed {
  let m = parse(text_) catch { _ => return none_passed() }
  let mv = Some(m)
  guard m is (Obj(_) | Arr(_)) && at(mv, "method") is Some(Str(mu)) else {
    let id = match m {
      Obj(_) => at(mv, "id")
      _ => None
    }
    let sid = match m {
      Obj(_) => at(mv, "sessionId")
      _ => None
    }
    return { up: [], down: [gate_error(id, sid, "a message is {id, method, params}")] }
  }
  let method = @jsjson.text(mu)
  let params = match at(mv, "params") {
    Some(Obj(_) | Arr(_) as p) => p
    _ => Obj([])
  }
  match at(mv, "sessionId") {
    Some(Str(su)) => {
      let sid = @jsjson.text(su)
      if !self.sessions.contains(sid) {
        return {
          up: [],
          down: [gate_error(at(mv, "id"), at(mv, "sessionId"), "No such session of this chat's.")],
        }
      }
      match (self.targets.get(sid), self.p.act) {
        (Some(target), Some(act)) if target != "" && acting_method(method) =>
          match act(target, method) {
            Some(refused) =>
              return { up: [], down: [gate_error(at(mv, "id"), at(mv, "sessionId"), refused)] }
            None => ()
          }
        _ => ()
      }
      match self.targets.get(sid) {
        Some(target) if target != "" && at(mv, "id") is Some(Num(_)) &&
          (
            method == "Page.navigate" ||
            method == "Runtime.callFunctionOn" ||
            (method == "Input.dispatchMouseEvent" && text(at(Some(params), "type")) == "mousePressed") ||
            (method == "Input.dispatchKeyEvent" && text(at(Some(params), "type")) == "keyDown")
          ) => {
          let url = str_of(at(Some(params), "url"))
          self.asked["\{sid}\u{0}\{key_part(at(mv, "id"))}"] = answer => {
            if at(Some(answer), "error") is None {
              match self.p.used {
                Some(f) => f(target, url)
                None => ()
              }
            }
            None
          }
        }
        _ => ()
      }
      if method == "Page.bringToFront" {
        return { up: [], down: [gate_answer(at(mv, "id"), Some(sid), Obj([]))] }
      }
      // What reaches past the page (other targets, the browser, the cookies of a context) is gated as on the
      // browser's own target; a page's own auto-attach to its frames and workers goes as it is (what it attaches is
      // told, and gated, as Target.attachedToTarget).
      if method == "Target.setAutoAttach" || method == "Target.autoAttachRelated" {
        return { up: [text_], down: [] }
      }
      if method.has_prefix("Target.") || method.has_prefix("Browser.") || cookie_method(method) {
        return self.browser(m, method, params, Some(sid))
      }
      { up: [text_], down: [] }
    }
    _ => self.browser(m, method, params, None)
  }
}

///|
fn Gate::browser(self : Gate, m : J, method : String, params : J, session_id : String?) -> Passed {
  let mv = Some(m)
  let pv = Some(params)
  let no = (why : String) => {
    up: [],
    down: [gate_error(at(mv, "id"), session_id.map(js), why)],
  }
  guard browser_method(method) is Some(how) else { return no("\{method} is not for one chat's browser.") }
  let key = "\{session_id.unwrap_or("")}\u{0}\{key_part(at(mv, "id"))}"
  match how {
    "answer" =>
      if method == "Target.getBrowserContexts" {
        // The chat's context is the agent's default one; those it made, its others.
        {
          up: [],
          down: [
            gate_answer(
              at(mv, "id"),
              session_id,
              jo([("browserContextIds", jsa(self.contexts)), ("defaultBrowserContextId", js(self.p.context))]),
            ),
          ],
        }
      } else {
        { up: [], down: [gate_answer(at(mv, "id"), session_id, Obj([]))] }
      }
    "target" => {
      // Without one, the browser's own target (Target.getTargetInfo): nothing of a chat's.
      if at(pv, "targetId") is None && method != "Target.attachToTarget" && method != "Target.closeTarget" {
        return { up: [stringify(m)], down: [] }
      }
      if !self.target(at(pv, "targetId")) {
        return no("No such target of this chat's.")
      }
      if method == "Target.closeTarget" {
        match self.p.act {
          Some(act) =>
            match act(js_str(at(pv, "targetId")), method) {
              Some(refused) => return no(refused)
              None => ()
            }
          None => ()
        }
      }
      if method == "Target.attachToTarget" {
        let target_id = js_str(at(pv, "targetId"))
        self.asked[key] = a => {
          match at_path(Some(a), ["result", "sessionId"]) {
            Some(Str(u)) => {
              let s = @jsjson.text(u)
              self.sessions[s] = ()
              self.targets[s] = target_id
            }
            _ => ()
          }
          None
        }
      }
      { up: [stringify(m)], down: [] }
    }
    "own" =>
      match at(pv, "sessionId") {
        Some(Str(u)) if self.sessions.contains(@jsjson.text(u)) => { up: [stringify(m)], down: [] }
        _ => no("No such session of this chat's.")
      }
    "context" => {
      let given = at(pv, "browserContextId")
      if given is Some(_) && !self.ours(given) {
        return no("No such browser context of this chat's.")
      }
      if method == "Target.disposeBrowserContext" {
        match given {
          None => return no("This chat's own context is not disposed of from here.")
          Some(Str(u)) if @jsjson.text(u) == self.p.context =>
            return no("This chat's own context is not disposed of from here.")
          Some(Str(u)) => {
            let g = @jsjson.text(u)
            match self.contexts.search(g) {
              Some(i) => ignore(self.contexts.remove(i))
              None => ()
            }
          }
          _ => ()
        }
        return { up: [stringify(m)], down: [] }
      }
      let ctx = match given {
        None | Some(Null) => js(self.p.context)
        Some(g) => g
      }
      let mut out_params = put(spread(Obj([]), params), "browserContextId", ctx)
      if method == "Target.createTarget" {
        for f in behind() {
          out_params = put(out_params, f.0, f.1)
        }
      }
      let out = put(m, "params", out_params)
      if method == "Target.createTarget" {
        self.asked[key] = a => {
          match at_path(Some(a), ["result", "targetId"]) {
            Some(Str(u)) => {
              let id = @jsjson.text(u)
              self.mine[id] = ()
              match self.p.opened {
                Some(f) => f(id)
                None => ()
              }
            }
            _ => ()
          }
          None
        }
      }
      { up: [stringify(out)], down: [] }
    }
    _ => {
      if method == "Target.createBrowserContext" {
        self.asked[key] = a => {
          match at_path(Some(a), ["result", "browserContextId"]) {
            Some(Str(u)) => {
              let c = @jsjson.text(u)
              if !self.contexts.contains(c) {
                self.contexts.push(c)
              }
            }
            _ => ()
          }
          None
        }
      }
      if method == "Target.getTargets" {
        self.asked[key] = a => {
          guard at_path(Some(a), ["result", "targetInfos"]) is Some(Arr(infos)) else { return None }
          let kept = infos.filter(t => self.target(at(Some(t), "targetId"), info=Some(t)))
          let result = put(spread(Obj([]), at(Some(a), "result").unwrap()), "targetInfos", ja(kept))
          Some(stringify(put(a, "result", result)))
        }
      }
      { up: [stringify(m)], down: [] }
    }
  }
}

///|
/// Whether a message from Chrome is one the gate reads: the browser's news of targets, or an answer it looks at.
/// Others pass unread (a page's screenshot is large: it is never parsed).
pub fn Gate::wants(self : Gate, text_ : String) -> Bool {
  if text_.length() > 1 << 20 {
    return false
  }
  if text_.has_prefix("{\"method\":\"Target.") {
    return true
  }
  if self.asked.length() == 0 && self.foreign.length() == 0 && self.own.length() == 0 {
    return false
  }
  text_.has_prefix("{\"id\":")
}

///|
/// A message from Chrome the gate reads (`wants`).
pub fn Gate::from_chrome(self : Gate, text_ : String) -> Passed {
  let m = parse(text_) catch { _ => return { up: [], down: [text_] } }
  let mv = match m {
    Obj(_) => Some(m)
    _ => None
  }
  match at(mv, "id") {
    Some(Num(n)) if self.own.contains(n) => {
      self.own.remove(n)
      return none_passed()
    }
    _ => ()
  }
  let sid = str_of(at(mv, "sessionId"))
  match at(mv, "id") {
    Some(id) => {
      let key = "\{sid.unwrap_or("")}\u{0}\{key_part(Some(id))}"
      match self.asked.get(key) {
        None =>
          return match sid {
            Some(s) if self.foreign.contains(s) => none_passed()
            _ => { up: [], down: [text_] }
          }
        Some(look) => {
          self.asked.remove(key)
          return { up: [], down: [look(m).unwrap_or(text_)] }
        }
      }
    }
    None => ()
  }
  match sid {
    Some(s) if self.foreign.contains(s) => return none_passed()
    _ => ()
  }
  let method = text(at(mv, "method"))
  if !(at(mv, "method") is Some(Str(_))) || !news_method(method) {
    return { up: [], down: [text_] }
  }
  let p = match at(mv, "params") {
    None | Some(Null) => (Obj([]) : J)
    Some(x) => x
  }
  let pv = Some(p)
  let psid = str_of(at(pv, "sessionId"))
  match method {
    "Target.attachedToTarget" => {
      let info = at(pv, "targetInfo")
      if self.target(at(info, "targetId"), info=info) {
        match psid {
          Some(s) => {
            self.sessions[s] = ()
            self.targets[s] = js_str(at(info, "targetId"))
          }
          None => ()
        }
        return { up: [], down: [text_] }
      }
      // Not the agent's: let go of at once (which lets it run on, if it waited for its debuggers), and never told.
      match psid {
        Some(s) => self.foreign[s] = ()
        None => ()
      }
      let id = self.own_id
      self.own_id += 1
      let detach_params = match at(pv, "sessionId") {
        Some(x) => jo([("sessionId", x)])
        None => Obj([])
      }
      let fs : Array[(String, J)] = [
        ("id", ji(id)),
        ("method", js("Target.detachFromTarget")),
        ("params", detach_params),
      ]
      match sid {
        Some(s) => fs.push(("sessionId", js(s)))
        None => ()
      }
      self.own[id.to_double()] = ()
      { up: [stringify(jo(fs))], down: [] }
    }
    "Target.detachedFromTarget" | "Target.receivedMessageFromTarget" => {
      match psid {
        Some(s) if self.foreign.contains(s) => {
          if method == "Target.detachedFromTarget" {
            self.foreign.remove(s)
          }
          return none_passed()
        }
        _ => ()
      }
      if method == "Target.detachedFromTarget" {
        match psid {
          Some(s) => {
            self.sessions.remove(s)
            self.targets.remove(s)
          }
          None => ()
        }
      }
      { up: [], down: [text_] }
    }
    "Target.targetDestroyed" | "Target.targetCrashed" => {
      let tid = match at(pv, "targetId") {
        Some(Str(u)) => Some(@jsjson.text(u))
        _ => None
      }
      match tid {
        Some(t) if self.mine.contains(t) => {
          if method == "Target.targetDestroyed" {
            self.mine.remove(t)
          }
          { up: [], down: [text_] }
        }
        _ => none_passed()
      }
    }
    _ => {
      let info = at(pv, "targetInfo")
      if self.target(at(info, "targetId"), info=info) {
        { up: [], down: [text_] }
      } else {
        none_passed()
      }
    }
  }
}
