// An agent's ask to sign in to a site, in place of its post's words ( 登录态, "Signing in from a
// card"; station vault/signin.ts): the one card a sign-in takes. Its person signs in from it with their own password
// manager, asked here as a page's login is filled from the remote screen (screen_fill.mbt: 1Password's command-line
// tool, which asks them itself, or the system's autofill service), and what it gives goes to the station
// (`signin.fill`), which types it into the chat's tab step by step and sends it; nothing of it is kept here, logged or
// shown. A code the page asks that the password manager did not give is typed on the card; where only the person can go
// on (a captcha, a code by mail), the card opens the tab's screen, and they say when they signed in. Signed in, kept in
// their vault as they chose on the card (登录后存入密钥库, the default, or not), approved here in place: no card of its
// own. Answered, on screen or not, the card goes as its room closes from that moment and one line saying how it went
// comes in its place, as a vault request's does (vault_ask_card).

///|
/// What the password manager is asked of for a sign-in's card, between frames: the run of `op` under way, the logins to
/// pick from (signals: what is made once of the card follows them), and what was had of the one picked.
priv struct SignInRun {
  run : @signals.Signal[@hostapi.OpRun?]
  choices : @signals.Signal[Array[@hostapi.PasswordLogin]]
  mut picked : String
  mut vault : String
  mut username : String
  mut password : String
}

///|
// kept across runs: emptied by signin_reset
let signin_runs : @sf.LiveMap[String, SignInRun] = @sf.LiveMap::new()

///|
/// Where each card's asking is (by its id): "" nothing asked, listing / getting / otp (1Password asked), auto (the
/// system's autofill service offers its logins), choosing (logins to pick from), sending / denying (to the station),
/// said (why it did not fill: `signin_notes`).
let signin_steps : @sf.LiveMap[String, String] = @sf.LiveMap::new()

///|
let signin_notes : @sf.LiveMap[String, String] = @sf.LiveMap::new()

///|
/// Whether each card's sign-in is to be kept in the vault (its menu's choice; kept unless said otherwise).
let signin_keep : @sf.LiveMap[String, Bool] = @sf.LiveMap::new()

///|
/// The keep menu open (its card's id).
let signin_menu : Ref[String] = Ref("")

///|
/// The vault requests keeping a sign-in this device approved (asked, or failed): approved once.
let signin_saving : @sf.LiveMap[String, String] = @sf.LiveMap::new()

///|
/// Each card's code field.
let signin_code : Map[String, @ui.Field] = Map([])

///|
fn signin_reset() -> Unit {
  signin_runs.clear()
  signin_steps.clear()
  signin_notes.clear()
  signin_keep.clear()
  signin_menu.val = ""
  signin_saving.clear()
  signin_code.clear()
  @hostapi.op_list_cache_reset()
}

///|
fn signin_run(id : String) -> SignInRun {
  match signin_runs.get(id) {
    Some(r) => r
    None => {
      let r = { run: @signals.signal_ref(None), choices: @signals.signal([]), picked: "", vault: "", username: "", password: "" }
      signin_runs[id] = r
      r
    }
  }
}

///|
/// Let go of what was asked for card `id`: the run stopped, what it gave forgotten.
fn signin_stop(id : String) -> Unit {
  match signin_runs.get(id) {
    Some(r) => {
      match r.run.untracked() {
        Some(run) => run.end()
        None => ()
      }
      if signin_steps.get(id) == Some("auto") {
        @hostapi.autofill_end()
      }
    }
    None => ()
  }
  signin_runs.remove(id)
  signin_steps.remove(id)
  signin_notes.remove(id)
}

///|
fn signin_said(id : String, note : String) -> Unit {
  signin_stop(id)
  signin_notes[id] = note
  signin_steps[id] = "said"
}

///|
/// Whether this device can ask a password manager for a login: 1Password's tool (macOS, Windows), else the system's
/// autofill service (Android).
fn signin_manager() -> Bool {
  @hostapi.passwords() || @hostapi.autofill()
}

///|
/// 用 1Password 登录 pressed: the password manager asked for the site's logins.
fn signin_start(core : @settings.Core, station : String, ask : SignInAsk) -> Unit {
  signin_stop(ask.id)
  if !@hostapi.passwords() && @hostapi.autofill_ask(ask.site) {
    signin_steps[ask.id] = "auto"
    return
  }
  let cached = @hostapi.op_list_cached_for(ask.site)
  if cached.length() == 1 {
    signin_pick(core, station, ask, cached[0])
    return
  }
  if cached.length() > 1 {
    signin_run(ask.id).choices.set(cached)
    signin_steps[ask.id] = "choosing"
    return
  }
  signin_op(core, station, ask, ["item", "list", "--categories", "Login", "--format", "json"], "listing")
}

///|
fn signin_op(_core : @settings.Core, _station : String, ask : SignInAsk, args : Array[String], step : String) -> Unit {
  match @hostapi.op_run(args) {
    Some(r) => {
      signin_run(ask.id).run.set(Some(r))
      signin_steps[ask.id] = step
    }
    None => signin_said(ask.id, @sf.t("android-misc.screen.fill.noOp"))
  }
}

///|
/// One of the site's logins picked (or the only one): its account, password and any TOTP asked in one call.
fn signin_pick(core : @settings.Core, station : String, ask : SignInAsk, l : @hostapi.PasswordLogin) -> Unit {
  let r = signin_run(ask.id)
  r.choices.set([])
  r.picked = l.id
  r.vault = l.vault
  signin_op(core, station, ask, op_item_get_args(l, fields=false), "getting")
}

///|
/// The run under way ended: what it said taken (once).
fn signin_took(core : @settings.Core, station : String, ask : SignInAsk) -> Unit {
  let r = signin_run(ask.id)
  guard r.run.untracked() is Some(run) else { return }
  guard @signals.untracked(fn() { run.done() }) is Some(d) else { return }
  run.end()
  r.run.set(None)
  let step = signin_steps.get(ask.id).unwrap_or("")
  // (a login without a one-time code: sent without one; the page asks it on the card if it wants one)
  if step == "otp" {
    let code = if d.code == 0 { d.out.trim(chars=" \n").to_owned() } else { "" }
    signin_send(core, station, ask, r.username, r.password, code)
    return
  }
  match d.trouble() {
    Some(t) => {
      if step == "getting" {
        @hostapi.op_list_cache_reset()
      }
      signin_said(ask.id, op_trouble_words(t))
      return
    }
    None => ()
  }
  match step {
    "listing" => {
      @hostapi.op_list_cache_keep(d.out)
      let found = @hostapi.logins_for(d.out, ask.site)
      if found.is_empty() {
        signin_said(ask.id, @sf.t("android-misc.screen.fill.none", args=[("host", ask.site)]))
      } else if found.length() == 1 {
        signin_pick(core, station, ask, found[0])
      } else {
        r.choices.set(found)
        signin_steps[ask.id] = "choosing"
      }
    }
    "getting" => {
      let (username, password, code, has_otp) = @hostapi.login_secret(d.out)
      if username == "" && password == "" {
        signin_said(ask.id, @sf.t("android-misc.screen.fill.empty"))
        return
      }
      r.username = username
      r.password = password
      // (a full item JSON already holds the live `totp` code; fall back to `--otp` only when an OTP field lacked one)
      if has_otp && code == "" {
        signin_op(core, station, ask, op_item_otp_args(r.picked, r.vault), "otp")
      } else {
        signin_send(core, station, ask, username, password, code)
      }
    }
    _ => ()
  }
}

///|
/// What the password manager gave sent to the station, for the card's site only (the station types it into the tab
/// only while it is on that site); forgotten here once it went.
fn signin_send(core : @settings.Core, station : String, ask : SignInAsk, username : String, password : String, code : String) -> Unit {
  let login : Map[String, Json] = Map([])
  if username != "" {
    login["username"] = Json::string(username)
  }
  if password != "" {
    login["password"] = Json::string(password)
  }
  if code != "" {
    login["code"] = Json::string(code)
  }
  signin_stop(ask.id)
  signin_steps[ask.id] = "sending"
  // (the login an object: the core's doing keeps no copy of it)
  let params : Json = {
    "station": Json::string(station),
    "id": Json::string(ask.id),
    "login": Json::object(login),
    "keep": Json::boolean(signin_keep.get(ask.id).unwrap_or(true)),
  }
  (core.call)("signin.fill", params, fn(r) {
    match r {
      Ok(_) => signin_steps.remove(ask.id)
      Err(e) => signin_said(ask.id, @sf.t("android-misc.signin.failed", args=[("why", @settings.error_text(e))]))
    }
  })
}

///|
/// The person signs in on the tab's screen themselves (`done` false: the screen opened), or says they did.
fn signin_self(core : @settings.Core, station : String, ask : SignInAsk, done : Bool) -> Unit {
  if !done {
    (core.open_screen)(station, ask.screen)
  }
  (core.call)("signin.self", { "station": Json::string(station), "id": Json::string(ask.id), "done": Json::boolean(done) }, fn(r) {
    match r {
      Err(e) => (core.say)(@sf.t("android-misc.signin.failed", args=[("why", @settings.error_text(e))]))
      Ok(_) => ()
    }
  })
}

///|
/// The person cancels the sign-in: stops any password manager ask in flight and tells the station (`signin.deny`).
fn signin_deny(core : @settings.Core, station : String, ask : SignInAsk) -> Unit {
  if core.read_only != "" {
    (core.say)(core.read_only)
    return
  }
  signin_stop(ask.id)
  signin_steps[ask.id] = "denying"
  (core.call)("signin.deny", { "station": Json::string(station), "id": Json::string(ask.id) }, fn(r) {
    match r {
      Ok(_) => ()
      Err(e) => {
        signin_steps.remove(ask.id)
        (core.say)(
          @sf.t(
            "android-misc.act.failed",
            args=[("what", @sf.t("android-misc.signin.cancelWhat")), ("error", @settings.error_text(e))],
          ),
        )
      }
    }
  })
}

///|
/// Whether a sign-in's card has nothing more to answer: it ended, and what keeps it (where it is kept) was decided.
fn signin_over(ask : SignInAsk) -> Bool {
  match ask.status {
    "denied" | "withdrawn" | "expired" | "ended" => true
    "done" => ask.save == "" || ask.kept != ""
    _ => false
  }
}

///|
fn signin_outcome_words(ask : SignInAsk) -> String {
  let site = [("site", ask.site)]
  match ask.status {
    "done" if ask.kept == "granted" => @sf.t("android-misc.signin.outcome.kept", args=site)
    "done" if ask.save != "" || !ask.keep => @sf.t("android-misc.signin.outcome.notKept", args=site)
    "done" => @sf.t("android-misc.signin.outcome.done", args=site)
    "denied" => @sf.t("android-misc.signin.outcome.denied", args=site)
    "withdrawn" => @sf.t("android-misc.signin.outcome.withdrawn", args=site)
    "expired" => @sf.t("android-misc.signin.outcome.expired", args=site)
    _ => @sf.t("android-misc.signin.outcome.ended")
  }
}

///|
/// What the card says the person is needed for, where only they can go on.
fn signin_person_words(ask : SignInAsk) -> String {
  match ask.why {
    "blocked" | "refused" | "stuck" | "self" => @sf.t("android-misc.signin.person." + ask.why)
    "elsewhere" => @sf.t("android-misc.signin.person.elsewhere", args=[("site", ask.site)])
    "agent" => @sf.t("android-misc.signin.person.agent", args=[("said", ask.said)])
    _ => @sf.t("android-misc.signin.person.stuck")
  }
}

///|
/// A code's field or a site's logins over the card's buttons, as wide as the card's foot (vault_ask's ask_typed).
// kept across runs: a value (no field of it changes)
let signin_typed : @ui.Style = @ui.css("w=Full gap=S2")

///|
/// One of 1Password's logins for the site, in their order: a full-width capsule on the faint ground, its words on one
/// line cut short where an OAuth client id is long, a chevron at its end.
// kept across runs: a value (no field of it changes)
let signin_choice_base : @ui.Style = @ui.css("row w=Full radius=Full gap=S2 align=ACenter justify=JBetween")

///|
fn signin_choice_box() -> @ui.Style {
  let h = @sf.button_height()
  let padx = @sf.card_pad - @sf.card_foot_in(h)
  signin_choice_base.then(
    @ui.style(
      h=Fixed(h),
      pl=@sf.room_of(padx),
      pr=@sf.room_of(padx),
    ),
  )
}

///|
fn signin_choice_words() -> @ui.TextStyle {
  @ui.text_style(
    size=Ui,
    leading=L5,
    weight=if @sf.theme().touch { Semibold } else { Medium },
    color=Fg,
    wrap=false,
    w=Cut,
  )
}
