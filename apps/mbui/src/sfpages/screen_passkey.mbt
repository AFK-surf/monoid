// A page's sign-in with a passkey, signed on this device ("Signing in with a passkey"):
// while this viewer drives a tab of a station's browser whose page asks for one, the station says the site and the
// client data to sign (the tab's origin, as the browser has its address); the person's own device (@hostapi
// passkeys.mbt: Windows, or a Mac whose app is entitled as a browser, which asks them itself) signs it with a passkey of theirs for that site, and what it signed
// goes to the station to answer the page (`screen.input` passkey). A no is answered as a browser answers it.

///|
/// The page's ask for a passkey, while this viewer drives the screen; None in none, dismissed, or only looking.
fn ScreenSess::passkey_ask(self : ScreenSess) -> Json? {
  if !self.driving() {
    return None
  }
  match field(self.state, "passkey") {
    Some(Object(_) as p) => {
      let id = text(Some(p), "id")
      if id != "" && self.passkey_dismissed.get() != Some(id) {
        Some(p)
      } else {
        None
      }
    }
    _ => None
  }
}

///|
/// Dismisses the passkey prompt (`×`): remembers the current ask's `id` so it hides immediately, cancels any host ask,
/// and tells the page `NotAllowedError` as cancelling in a browser does.
fn ScreenSess::passkey_dismiss(self : ScreenSess) -> Unit {
  let id = match field(self.state, "passkey") {
    Some(Object(_) as p) => text(Some(p), "id")
    _ => ""
  }
  if id != "" {
    self.passkey_dismissed.set(Some(id))
    self.input(self.src, Json::object({ "t": Json::string("passkey"), "id": Json::string(id), "error": Json::string("NotAllowedError") }))
  }
  self.passkey_stop()
}

///|
/// 登录 pressed: the device asked to sign the page's ask.
fn ScreenSess::passkey_start(self : ScreenSess) -> Unit {
  guard self.passkey_ask() is Some(p) else { return }
  self.passkey_stop()
  self.passkey_id = text(Some(p), "id")
  let allow = match field(Some(p), "allow") {
    Some(Array(a)) =>
      a
      .filter_map(fn(v) {
        match v {
          String(s) => Some(s)
          _ => None
        }
      })
    _ => []
  }
  match @hostapi.passkey_get(text(Some(p), "rpId"), text(Some(p), "clientData"), allow, text(Some(p), "userVerification")) {
    Some(r) => {
      self.passkey_run = Some(r)
      self.passkey_step.set("asking")
    }
    None => {
      self.passkey_note = @sf.t("android-misc.screen.passkey.failed", args=[("why", "webauthn.dll")])
      self.passkey_step.set("said")
    }
  }
}

///|
/// Let go of: the ask under way forgotten, nothing shown.
fn ScreenSess::passkey_stop(self : ScreenSess) -> Unit {
  match self.passkey_run {
    Some(r) => r.end()
    None => ()
  }
  self.passkey_run = None
  self.passkey_note = ""
  self.passkey_step.set("")
}

///|
/// The ask under way ended: what it signed sent, or the page told no (once).
fn ScreenSess::passkey_took(self : ScreenSess) -> Unit {
  guard self.passkey_run is Some(r) else { return }
  guard r.done() is Some(d) else { return }
  r.end()
  self.passkey_run = None
  let id = self.passkey_id
  if d.code == 0 && d.credential != "" && d.authenticator_data != "" && d.signature != "" {
    let input : Map[String, Json] = {
      "t": Json::string("passkey"),
      "id": Json::string(id),
      "credential": Json::string(d.credential),
      "authenticatorData": Json::string(d.authenticator_data),
      "signature": Json::string(d.signature),
    }
    if d.user_handle != "" {
      input["userHandle"] = Json::string(d.user_handle)
    }
    // (the device's own client data, where it made it: the station checks it says what it asked)
    if d.client_data != "" {
      input["clientData"] = Json::string(d.client_data)
    }
    self.input(self.src, Json::object(input))
    self.passkey_step.set("")
    return
  }
  // (the person said no, or no passkey of the site's here: the page told as a browser tells it; else why, kept for
  // them to read, the page still asking)
  if d.code == 1 {
    self.input(self.src, Json::object({ "t": Json::string("passkey"), "id": Json::string(id), "error": Json::string("NotAllowedError") }))
    self.passkey_step.set("")
    return
  }
  self.passkey_note = @sf.t("android-misc.screen.passkey.failed", args=[("why", d.err.trim(chars=" \n").to_owned())])
  self.passkey_step.set("said")
}

///|
/// How often an ask for a passkey under way is looked at: the host says nothing as it ends but by a frame
/// (@hostapi.PasskeyRun::done), so it is looked at while it is under way, a little after each look.
let passkey_look_ms : Double = 250.0

///|
/// 用通行密钥登录, over the stage in `c` while a page this viewer drives asks for a passkey (on a host whose device has
/// passkeys to ask): the site and 登录, what it is at, or why it did not sign. An ask under way looked at till it ends
/// (passkey_look_ms), its end taken then.
fn passkey_sign_node(c : @view.View, s : ScreenSess) -> Unit {
  let looking : Ref[() -> Unit] = Ref(fn() {  })
  fn look() -> Unit {
    looking.val = fn() {  }
    match s.passkey_run {
      Some(r) =>
        if r.done() is Some(_) {
          s.passkey_took()
        } else {
          looking.val = c.at_moment(c.logic_at() + passkey_look_ms, look, later=true)
        }
      None => ()
    }
  }

  c.reacts(fn() { s.passkey_step.get() }, fn(step) {
    (looking.val)()
    looking.val = fn() {  }
    if step == "asking" {
      look()
    }
  })
  let ask = fn() {
    s.said.get() |> ignore
    s.passkey_ask()
  }
  // (what it is about read first, so it is followed whatever the host has)
  c.show(at_once=true, fn() { !(ask() is None && s.passkey_step.get() == "") && @hostapi.passkeys() }, fn(card) {
    @sf.style_node(card, fn() { drops_box })
    floats_panel_node(card)
    let step = fn() { s.passkey_step.get() }
    card.pick(at_once=true, fn() { step() == "said" }, fn(slot, is_said) {
      if is_said {
        screen_notice_row_node(slot, "info", fn() { s.passkey_note }, fn() { s.passkey_dismiss() })
        return
      }
      slot.box(fn(row) {
        @sf.style_node(row, fn() { drop_notice_row_box }, in_row=true)
        @sf.first_line_node(row, Ui, fn(l) {
          @sf.icon_node(l, "key", drop_icon, By(fn() { @ui.tree_theme().color(Muted) })) |> ignore
        }).min_height(Is(Some(drop_key_side)))
        |> ignore
        @sf.row_lines_node(
          row,
          fn(first) {
            let title = fn() {
              match step() {
                "asking" => @sf.t("android-misc.screen.passkey.asking")
                _ => @sf.t("android-misc.screen.passkey.offer")
              }
            }
            first.box(fn(w) {
              @sf.style_node(w, fn() { drop_words }, in_row=true)
              @sf.words_node(w, title, fn() { drop_name }) |> ignore
            })
            |> ignore
            screen_row_key_node(first, "close", @sf.t("common.close"), fn() { s.passkey_dismiss() })
          },
          fn(under) {
            under.show(at_once=true, fn() { step() == "" }, fn(u) {
              // the site under the words, 登录 under it (as 用 1Password 填入 says it)
              u.show(at_once=true, fn() { ask() is Some(_) }, fn(h) {
                @sf.words_node(h, fn() { text(ask(), "host") }, fn() { drop_path_words }) |> ignore
              })
              u.box(fn(b) {
                @sf.style_node(b, fn() { drop_buttons }, in_row=true)
                soft_button_node(b, fn() { @sf.t("android-misc.screen.passkey.button") }, fn() { s.passkey_start() })
              })
              |> ignore
            })
          },
        )
      })
      |> ignore
    })
  })
}
