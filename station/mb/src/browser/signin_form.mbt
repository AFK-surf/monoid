// A site's sign-in form in a chat's tab, filled by the station itself (src/browser/signin-form.ts, 登录态, "Signing in
// from a card"): what of a sign-in the page asks for now (an account, a password, a code), each field given what the
// person's app sent as typing gives it, and the form sent as Enter sends it, else by its button. Only while the tab is
// on the site asked for (its address as the browser has it, never what the page says), on a connection of its own,
// nothing of what is typed logged.

///|
/// What of a sign-in a page asks for, by its visible fields; `blocked`: something only a person can do is on it.
pub(all) struct FormAsks {
  username : Bool
  password : Bool
  code : Bool
  blocked : Bool
}

///|
pub fn FormAsks::to_j(self : FormAsks) -> J {
  jo([
    ("username", jb(self.username)),
    ("password", jb(self.password)),
    ("code", jb(self.code)),
    ("blocked", jb(self.blocked)),
  ])
}

///|
fn FormAsks::of_value(v : J?) -> FormAsks {
  {
    username: is_true(at(v, "username")),
    password: is_true(at(v, "password")),
    code: is_true(at(v, "code")),
    blocked: is_true(at(v, "blocked")),
  }
}

///|
fn FormAsks::asks(self : FormAsks, kind : String) -> Bool {
  match kind {
    "username" => self.username
    "password" => self.password
    _ => self.code
  }
}

///|
/// A tab's sign-in form as it is filled (a Chrome tab's: `tab_form`; a chat's Farview tab's: farview_form.mbt).
pub(all) struct SignInForm {
  host : async () -> String
  url : async () -> String
  on : async (String) -> Bool
  look : async () -> FormAsks
  type_ : async (String, String) -> Bool
  enter : async () -> Unit
  press : async () -> Bool
  mark : async () -> Unit
  marked : async () -> Bool
  close : () -> Unit
}

///|
/// A tab's sign-in form, on a connection of its own to the browser.
pub fn tab_form(cdp : Cdp, session : String, target_id : String) -> SignInForm {
  let world : Ref[(String, J?)?] = Ref(None)
  let s = Some(session)
  let url = async fn() -> String {
    let got = cdp.send("Target.getTargetInfo", jo([("targetId", js(target_id))]), None) catch {
      _ => jo([("targetInfo", Null)])
    }
    match at_path(Some(got), ["targetInfo", "url"]) {
      None | Some(Null) => ""
      u => js_str(u)
    }
  }
  let host = async fn() { host_of(url()) }
  // Runs `expression` in the page's top frame, in a world of the station's own (made again as the page moves on).
  let run = async fn(expression : String) -> J? {
    for tries in 0..<2 {
      let tree = cdp.send("Page.getFrameTree", Obj([]), s)
      let frame = match at_path(Some(tree), ["frameTree", "frame", "id"]) {
        None | Some(Null) => ""
        f => js_str(f)
      }
      let same = match world.val {
        Some((f, _)) => f == frame
        None => false
      }
      if !same || tries > 0 {
        let made = cdp.send(
          "Page.createIsolatedWorld",
          jo([("frameId", js(frame)), ("worldName", js("stillfail-signin"))]),
          s,
        )
        world.val = Some((frame, at(Some(made), "executionContextId")))
      }
      let fs : Array[(String, J)] = [("expression", js(expression))]
      match world.val {
        Some((_, Some(c))) => fs.push(("contextId", c))
        _ => ()
      }
      fs.push(("returnByValue", jb(true)))
      match attempt(async fn() { cdp.send("Runtime.evaluate", jo(fs), s) }) {
        Ok(r) =>
          if at(Some(r), "exceptionDetails") is None {
            return at_path(Some(r), ["result", "value"])
          }
        Err(e) => {
          // (the page went on meanwhile: its world went with it)
          let m = lower(message_of(e))
          if !(m.contains("context") || m.contains("not found") || m.contains("destroyed")) {
            raise e
          }
        }
      }
      world.val = None
    }
    None
  }
  {
    host,
    url,
    on: async fn(site) {
      let h = host()
      h != "" && of_sites(h, [site])
    },
    look: async fn() { FormAsks::of_value(run(look_script()) catch { _ => None }) },
    type_: async fn(kind, value) {
      if !is_true(run(pick_script(kind))) {
        return false
      }
      if kind == "code" {
        for ch in value {
          ignore(cdp.send("Input.insertText", jo([("text", js(ch.to_string()))]), s))
        }
      } else {
        ignore(cdp.send("Input.insertText", jo([("text", js(value))]), s))
      }
      true
    },
    enter: async fn() {
      for t in ["keyDown", "keyUp"] {
        let fs : Array[(String, J)] = [
          ("type", js(t)),
          ("key", js("Enter")),
          ("code", js("Enter")),
          ("windowsVirtualKeyCode", ji(13)),
          ("nativeVirtualKeyCode", ji(13)),
        ]
        if t == "keyDown" {
          fs.push(("text", js("\r")))
        }
        ignore(cdp.send("Input.dispatchKeyEvent", jo(fs), s))
      }
    },
    press: async fn() {
      let at_ = run(button_script)
      guard at(at_, "x") is Some(Num(_) as x) && at(at_, "y") is Some(Num(_) as y) else { return false }
      for t in ["mousePressed", "mouseReleased"] {
        ignore(
          cdp.send(
            "Input.dispatchMouseEvent",
            jo([("type", js(t)), ("x", x), ("y", y), ("button", js("left")), ("clickCount", ji(1))]),
            s,
          ),
        )
      }
      true
    },
    mark: async fn() { ignore(run("window.__stillfailSent = true")) },
    marked: async fn() { is_true(run("window.__stillfailSent === true") catch { _ => None }) },
    close: () => (cdp.close)(),
  }
}

///|
/// How a fill went: the page left its sign-in (`left`), it asks for a code it was not given (`code`), or only a person
/// can go on (`person`, and why: `blocked`, `refused`, `stuck`, `elsewhere`).
pub(all) struct Driven {
  state : String
  why : String?
}

///|
pub fn Driven::to_j(self : Driven) -> J {
  match self.why {
    Some(w) => jo([("state", js(self.state)), ("why", js(w))])
    None => jo([("state", js(self.state))])
  }
}

///|
/// How long the page is given to move on once its form is sent, and how often it is looked at meanwhile.
pub let move_ms : Double = 8000.0

///|
let look_every_ms : Double = 300.0

///|
/// The most steps a sign-in takes (an account, a password, a code, and one more a site may ask).
let sign_in_steps : Int = 5

///|
/// What the person's app gave: the account, its password, a one-time code.
pub(all) struct FormValues {
  username : String?
  password : String?
  code : String?
}

///|
fn FormValues::of(self : FormValues, kind : String) -> String? {
  match kind {
    "username" => self.username
    "password" => self.password
    _ => self.code
  }
}

///|
/// Goes through `site`'s sign-in on `form`'s tab with `values`: each step's fields typed (each of `used`, what an
/// earlier fill typed, not again), the form sent, until the page leaves its sign-in, asks a code not given, or needs a
/// person. `wait(ms)` waits (the station's time); what was typed is added to `used`.
pub async fn drive(
  form : SignInForm,
  site : String,
  values : FormValues,
  used : Array[String],
  wait : async (Double) -> Unit,
) -> Driven {
  for step in 0..<sign_in_steps {
    if !(form.on)(site) {
      return if step == 0 { { state: "person", why: Some("elsewhere") } } else { { state: "left", why: None } }
    }
    let asks = (form.look)()
    if asks.blocked {
      return { state: "person", why: Some("blocked") }
    }
    if !asks.username && !asks.password && !asks.code {
      return { state: "left", why: None }
    }
    let typed = []
    for kind in ["username", "password", "code"] {
      guard values.of(kind) is Some(value) && value != "" else { continue }
      if !asks.asks(kind) || used.contains(kind) {
        continue
      }
      if (form.type_)(kind, value) {
        typed.push(kind)
      }
    }
    if typed.length() == 0 {
      if asks.code && !used.contains("code") {
        return { state: "code", why: None }
      }
      return { state: "person", why: Some("refused") }
    }
    for kind in typed {
      if !used.contains(kind) {
        used.push(kind)
      }
    }
    let before = stringify(jo([("url", js((form.url)())), ("asks", asks.to_j())]))
    (form.mark)()
    let moved = async fn() -> Bool {
      let mut t = 0.0
      while t < move_ms {
        wait(look_every_ms)
        if !(form.marked)() {
          return true
        }
        let url = (form.url)()
        let now = (form.look)()
        if stringify(jo([("url", js(url)), ("asks", now.to_j())])) != before {
          return true
        }
        t += look_every_ms
      }
      false
    }
    (form.enter)()
    if !moved() && !((form.press)() && moved()) {
      return { state: "person", why: Some("stuck") }
    }
  }
  { state: "person", why: Some("stuck") }
}
