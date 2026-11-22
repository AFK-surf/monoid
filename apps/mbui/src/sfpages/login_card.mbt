// A station's login to a command-line tool its agents use, as a card, the one on every screen (still.fail
// web/src/MachineLogins.tsx LoginCard, ActiveCard, CancelLogin, PasteSteps, CodeField, CardCode, StepButton;
// MachineLogins.css.ts card…; the web's phone the same card): in a chat under the agent's message (decision.mbt), on
// the station page's 登录 while it is under way (station_cards.mbt, settings' station_logins.mbt).
// Its title with 取消 as its × in the card's corner; what the person does now by its step — a device code with 复制并打开,
// a page to open, a loopback login's page once the core listens for the browser's callback, a page whose code is pasted
// back — the step's button the card's width, solid while it is the next thing to do, and where the station has a
// browser of its own the same step there in a ⋯ beside it (seldom used: the step itself only where this device cannot
// do it); while its agent answers the command or it is checked, how it stands. Ended, one quiet line saying how. What it shows is the core's
// (`machineLogins`, `machineLogin`); what is done goes through its calls, under way on its button (the core's `doing`).
// How it looks, made once as nodes, is the library's (libs/sf-ui login_step_card_node.mbt: its card, lines, code, step
// and pasted code, and their looks, which the old view here draws with too): this file works out what it says and
// does what is pressed.

///|
/// What was pressed here, by login (a step's button plain grey once pressed: the eye on to what follows; followed, the
/// card made once reading it), whether a code is typed in its field, and the field: these two by the place its card is
/// drawn in as well (login_field), a login's card being in its chat and on its station's page at once.
priv struct LoginsHere {
  pressed : @sf.LiveMap[String, Bool]
  fields : Map[String, @ui.Field]
  /// each login's card as it last showed under way, by station and id: what it shows as it closes once ended (an old
  /// view's, decision.mbt's message_decision)
  last : Map[String, Json]
}

///|
let logins_here : LoginsHere = { pressed: @sf.LiveMap::new(), fields: {}, last: {} }

///|
/// As at the start (tests).
pub fn login_cards_reset() -> Unit {
  logins_here.pressed.clear()
  logins_here.fields.clear()
  logins_here.last.clear()
  st_logins_open.clear()
}

// ── what a card says and does (its old view's and its node's) ─────────────

///|
/// Login `id` of `station` as the core says it now (None: one it does not know, ended long ago).
fn login_of(core : Core, station : String, id : String) -> Json? {
  let ask = login_ask(station, id)
  match (core.topic)(ask.0, ask.1).get().value {
    Some(Object(_)) as v => v
    _ => None
  }
}

///|
/// Login `id` of `station` as its card shows it: the one a person started again from it, where it was (`again`: its
/// card follows it), else itself as the core says it now (None: one it does not know).
fn login_followed(core : Core, station : String, id : String) -> Json? {
  let mut l = login_of(core, station, id)
  // (a few times at most: each started again from the one before)
  for _ in 0..<4 {
    match text(l, "again") {
      "" => break
      next =>
        match login_of(core, station, next) {
          Some(_) as n => l = n
          None => break
        }
    }
  }
  l
}

///|
/// Whether login `l`'s card stands: under way, or ended without logging in and offered again (its 重新发起).
fn login_carded(l : Json?) -> Bool {
  flag(l, "active") || flag(l, "canAgain")
}

///|
/// A login under way runs out of time (`expiresAt`, the station's 15 minutes): how long is left as of `now`, said on
/// its card while the person has a step to do (red its last 3 minutes); None where it is not known, or none is left.
fn login_left(l : Json?, now : Double) -> @sfbase.LoginSaid? {
  let ends = number(l, "expiresAt")
  guard ends > 0.0 && flag(l, "active") else { return None }
  // (whole minutes, rounded up: 14:59 left is 15)
  let minutes = ((ends - now + 59999.0) / 60000.0).floor().to_int()
  guard minutes > 0 else { return None }
  let words = if minutes <= 1 {
    @sf.t("web-main.logins.leftLast")
  } else {
    @sf.t("web-main.logins.left", args=[("minutes", minutes.to_string())])
  }
  Some(said_line(words, red=minutes <= 3))
}

///|
/// What the core is asked for login `id` of `station` (login_of's, its card's; its chat's as it opens, sfbase's
/// chat_opens): its `machineLogin`.
fn login_ask(station : String, id : String) -> (String, Map[String, Json]) {
  @sfbase.machine_login_ask(station, id)
}

///|
/// The station's logins as the core says them now (what may be done of them: `canLogin`, `canRelay`).
fn logins_of(core : Core, station : String) -> Json? {
  let ask = logins_ask(station)
  (core.topic)(ask.0, ask.1).get().value
}

///|
/// What the core is asked for station `station`'s logins (logins_of's, its page's 登录's): its `machineLogins`.
fn logins_ask(station : String) -> (String, Map[String, Json]) {
  @sfbase.machine_logins_ask(station)
}

///|
/// An ended login's line (as an answered decision's: 已在 willow 上登录 gh), and whether it failed (said in red).
fn login_ended(l : Json?) -> (String, Bool) {
  let words = match text(l, "endedText") {
    "" => text(l, "title") + " · " + text(l, "statusText")
    s => s
  }
  (words, text(l, "state") == "failed")
}

///|
/// A line of how a login stands or what to do (@sfbase.LoginSaid): red, busy, last as it says.
fn said_line(words : String, red? : Bool = false, busy? : Bool = false, last? : Bool = false) -> @sfbase.LoginSaid {
  { words, red, busy, last }
}

///|
/// A step's button (@sfbase.LoginStep), as its words, solid and what it does say; the rest as it is mostly.
fn step_of(
  key : String,
  label : String,
  solid : Bool,
  on_press~ : () -> Unit,
  busy? : Bool = false,
  external? : Bool = false,
  more? : Array[@sf.MenuItem] = [],
  last? : Bool = true,
  told? : String,
) -> @sfbase.LoginStep {
  { key, label, solid, busy, external, more, last, press: on_press, told }
}

///|
/// What a login under way shows, for one who may finish it (ActiveCard's): its lines, the device code, the step's own
/// button. One whose page gives a code to paste back is login_paste_shows'.
priv struct LoginShows {
  said : Array[@sfbase.LoginSaid]
  code : String
  step : @sfbase.LoginStep?
}

///|
/// What login `l` of `station` under way shows now (login_active's): what the person does now by its step (or, while
/// its agent answers the command or it is checked, how it stands), then the step; `relay`: this device may take the
/// browser's callback.
fn login_shows(core : Core, station : String, l : Json?, relay : Bool, now : Double) -> LoginShows {
  let shows = login_steps(core, station, l, relay)
  // (how long is left of it, first, while the person has a step to do)
  match login_left(l, now) {
    Some(left) if shows.step is Some(_) => { said: [left, ..shows.said], code: shows.code, step: shows.step }
    _ => shows
  }
}

///|
/// What login `l` of `station` under way shows now by its step (login_shows', without the time left).
fn login_steps(core : Core, station : String, l : Json?, relay : Bool) -> LoginShows {
  let id = text(l, "id")
  let url = text(l, "url")
  // checking what came back (the browser's callback): nothing left for the person but to wait
  let step = if flag(l, "waiting") || text(l, "state") == "verifying" { "" } else { text(l, "step") }
  let domain = match text(l, "domain") {
    "" => ""
    d => @sf.t("web-main.logins.domain", args=[("domain", d)])
  }
  let pressed = logins_here.pressed.get(id).unwrap_or(false)
  let code = text(l, "code")
  // the same step in the station's own browser, for the ⋯ beside the step's button
  let elsewhere = match login_station_way(core, station, l) {
    Some(way) => [way]
    None => []
  }
  match step {
    "device" if code != "" => {
      let page = match text(l, "codeUrl") {
        "" => url
        u => u
      }
      // one press: the code copied first, then its page; the code stays on show for a clipboard that refused it
      let go = step_of("login-main/" + id, @sf.t("web-main.logins.copyOpen"), !pressed, more=login_page_ways(page, elsewhere), on_press=fn() {
        @settings.confirm_claude_auth(text(l, "name") == "claude", fn() {
          logins_here.pressed[id] = true
          @sfbase.copy_out(code)
          login_open(core, page)
        })
      })
      { said: [said_line(@sf.t("web-main.logins.device", args=[("domain", text(l, "domain"))]))], code, step: Some(go) }
    }
    // this device cannot take the browser's callback (a web page), or its port was taken just now: the station's
    // browser, which can, is the step (this device's again in its ⋯), else what is wrong is said; the page's host all
    // the same
    "loopback" if elsewhere.length() > 0 && (!relay || text(l, "relayText") != "") => {
      let said : Array[@sfbase.LoginSaid] = []
      if text(l, "relayText") != "" && relay {
        said.push(said_line(text(l, "relayText"), red=true))
      }
      if domain != "" {
        said.push(said_line(domain))
      }
      let busy = @settings.is_doing(core, ["machineLogin.browser"], [("station", station), ("id", id)])
      let again = if relay {
        [
          @sf.menu_item_of(@sf.t("web-main.logins.signIn"), fn() {
            @settings.confirm_claude_auth(text(l, "name") == "claude", fn() { login_relay_now(core, station, id, text(l, "title")) })
          }),
        ]
      } else {
        []
      }
      // (confirmed first where it asks to be, done as it is confirmed; else told once the frame's builds are over)
      let asks = login_station_asks(l)
      let go = step_of(
        "login-station/" + id,
        text(l, "browserText"),
        true,
        busy~,
        more=again,
        told?=if asks { None } else { Some("login-station/" + id) },
        on_press=fn() {
          if asks {
            @settings.confirm_claude_auth(true, fn() { login_station_go(core, station, l) })
          } else {
            login_station_go(core, station, l)
          }
        },
      )
      { said, code: "", step: Some(go) }
    }
    "loopback" if !relay => {
      let said : Array[@sfbase.LoginSaid] = [said_line(@sf.t("web-main.logins.needsDesktop"), last=domain == "")]
      if domain != "" {
        said.push(said_line(domain, last=true))
      }
      { said, code: "", step: None }
    }
    "loopback" => {
      let opened = flag(l, "listening")
      let said : Array[@sfbase.LoginSaid] = []
      if opened {
        said.push(said_line(@sf.t("web-main.logins.waitingBrowser"), busy=true))
      } else if text(l, "relayText") != "" {
        said.push(said_line(text(l, "relayText"), red=true))
        if domain != "" {
          said.push(said_line(domain))
        }
      } else if domain != "" {
        said.push(said_line(domain))
      }
      let busy = @settings.is_doing(core, ["machineLogin.open"], [("station", station), ("id", id)])
      let label = @sf.t(if opened { "web-main.logins.openAgain" } else { "web-main.logins.signIn" })
      // (confirmed first for Claude: done as it is confirmed; else told once the frame's builds are over)
      let claude = text(l, "name") == "claude"
      let go = step_of(
        "login-main/" + id,
        label,
        !opened,
        busy~,
        more=elsewhere,
        told?=if claude { None } else { Some("login-open/" + id) },
        on_press=fn() {
          if claude {
            @settings.confirm_claude_auth(true, fn() { login_relay_now(core, station, id, text(l, "title")) })
          } else {
            login_relay_now(core, station, id, text(l, "title"))
          }
        },
      )
      { said, code: "", step: Some(go) }
    }
    "open" if url != "" => {
      let go = step_of("login-main/" + id, @sf.t("web-main.logins.signIn"), !pressed, more=login_page_ways(url, elsewhere), on_press=fn() {
        @settings.confirm_claude_auth(text(l, "name") == "claude", fn() {
          logins_here.pressed[id] = true
          login_open(core, url)
        })
      })
      { said: if domain != "" { [said_line(domain)] } else { [] }, code: "", step: Some(go) }
    }
    _ => { said: [said_line(text(l, "statusText"), busy=true, last=true)], code: "", step: None }
  }
}

///|
/// What a login whose page gives a code to paste back shows now (PasteSteps'): where to sign in and what to bring back,
/// then 打开登录页 (solid until pressed here or a code is in: `typed`), and whether what is typed is sent or checked
/// (`busy`: 完成 turning, nothing more sent).
priv struct LoginPaste {
  lead : @sfbase.LoginSaid
  step : @sfbase.LoginStep
  busy : Bool
}

///|
fn login_paste_shows(core : Core, station : String, l : Json?, typed : Bool, now : Double) -> LoginPaste {
  let id = text(l, "id")
  let sending = @settings.is_doing(core, ["machineLogin.answer"], [("station", station), ("id", id)])
  let checking = text(l, "state") == "verifying"
  let busy = sending || checking
  let opened = logins_here.pressed.get(id).unwrap_or(false)
  let lead = if checking {
    text(l, "statusText")
  } else {
    match text(l, "domain") {
      "" => text(l, "statusText")
      d => @sf.t("web-main.logins.pasteLead", args=[("domain", d)])
    }
  }
  // (how long is left of it, after what to do, while there is something to do)
  let (lead, red) = match login_left(l, now) {
    Some(left) if !busy => (lead + " · " + left.words, left.red)
    _ => (lead, false)
  }
  let elsewhere = match login_station_way(core, station, l) {
    Some(way) => [way]
    None => []
  }
  let step = step_of(
    "login-paste-open/" + id,
    @sf.t("web-main.logins.openPage"),
    !opened && !typed && !busy,
    external=true,
    more=login_page_ways(text(l, "url"), elsewhere),
    last=false,
    on_press=fn() {
      @settings.confirm_claude_auth(text(l, "name") == "claude", fn() {
        logins_here.pressed[id] = true
        login_open(core, text(l, "url"))
      })
    },
  )
  { lead: said_line(lead, red~), step, busy }
}

///|
/// The code pasted back for login `id` of `station` sent (`machineLogin.answer`).
fn login_answer(core : Core, station : String, id : String, code : String) -> Unit {
  @settings.act(core, @sf.t("web-main.logins.answerWhat"), "machineLogin.answer", {
    "station": Json::string(station),
    "id": Json::string(id),
    "text": Json::string(code),
  })
}

///|
/// Login `id` of `station` started again (`machineLogin.again`), as its card's 重新发起 is pressed: its card follows the
/// new one as the station says it.
fn login_again_now(core : Core, station : String, id : String) -> Unit {
  @settings.act(core, @sf.t("web-main.logins.againWhat"), "machineLogin.again", { "station": Json::string(station), "id": Json::string(id) })
}

///|
/// What a login ended without logging in shows on its card, for one who may start it again: how it ended (red: 超时了…),
/// and 重新发起.
fn login_again_shows(core : Core, station : String, l : Json?) -> LoginShows {
  let id = text(l, "id")
  let busy = @settings.is_doing(core, ["machineLogin.again"], [("station", station), ("id", id)])
  let go = step_of("login-again/" + id, @sf.t("web-main.logins.again"), true, busy~, on_press=fn() {
    login_again_now(core, station, id)
  })
  // (how it ended, short: its title says what it was)
  { said: [said_line(text(l, "statusText"), red=true)], code: "", step: Some(go) }
}

///|
/// Whether login `id` of `station` is being cancelled (its × spinning).
fn login_cancelling(core : Core, station : String, id : String) -> Bool {
  @settings.is_doing(core, ["machineLogin.cancel"], [("station", station), ("id", id)])
}

///|
/// Login `id` of `station` cancelled (`machineLogin.cancel`), as its × is pressed.
fn login_cancel_now(core : Core, station : String, id : String) -> Unit {
  @settings.act(core, @sf.t("web-main.logins.cancelWhat"), "machineLogin.cancel", { "station": Json::string(station), "id": Json::string(id) })
}

///|
/// The step in the station's own browser (`machineLogin.browser`), where the station has one: what it is called (在 … 的
/// 浏览器中打开, or 回到 … 的浏览器 while its tab is open) and what does it: its page opened in a tab there (the one open,
/// if it is), whose view opens here and goes back by itself once the login ends; a loopback's callback comes back to the
/// command there, nothing relayed or pasted.
fn login_station_way(core : Core, station : String, l : Json?) -> @sf.MenuItem? {
  if !flag(l, "browser") || text(l, "browserText") == "" {
    return None
  }
  // (a ⋯'s item chosen, outside a build: done as it is chosen, or as it is confirmed)
  Some(
    @sf.menu_item_of(text(l, "browserText"), fn() {
      @settings.confirm_claude_auth(login_station_asks(l), fn() { login_station_go(core, station, l) })
    }),
  )
}

///|
/// Whether the station's own browser is asked for a login only once confirmed: Claude's, no tab of it open yet.
fn login_station_asks(l : Json?) -> Bool {
  text(l, "name") == "claude" && text(l, "screen") == ""
}

///|
/// The login's page opened in the station's own browser (`machineLogin.browser`), its view opened here.
fn login_station_go(core : Core, station : String, l : Json?) -> Unit {
  let label = text(l, "browserText")
  @settings.act(core, label, "machineLogin.browser", { "station": Json::string(station), "id": Json::string(text(l, "id")) }, then=fn(v) {
    (core.open_screen)(station, text(Some(v), "screen"))
  })
}

///|
/// What a ⋯ beside a login page's button offers: its address copied (for a browser elsewhere), then `elsewhere`.
fn login_page_ways(url : String, elsewhere : Array[@sf.MenuItem]) -> Array[@sf.MenuItem] {
  [@sf.menu_item_of(@sf.t("common.link.copy"), fn() { @sfbase.copy_out(url, said=@sf.t("common.link.copied")) }), ..elsewhere]
}

///|
/// A login's page, opened in the browser.
fn login_open(core : Core, url : String) -> Unit {
  if url != "" && !@ui.open_tab(url) {
    (core.say)(@sf.t("android-misc.link.cantOpen"))
  }
}

///|
/// A loopback login's browser, on this device (useRelay), the app held up meanwhile: the core listens for the browser's
/// callback (not on the station's own machine: the browser comes back there by itself), then answers the page to open;
/// this device's port taken is said on the card (the core's `relayText`), nothing opened. Asked for as its step is
/// pressed (told so in an old view), as a confirm's or a ⋯'s item's is chosen.
fn login_relay_now(core : Core, station : String, id : String, title : String) -> Unit {
  let here = this_machine() == station
  // the app held up while the core waits for the browser, by a notice saying which login (LoginRelay.kt: its title;
  // where the system keeps nothing up, nothing)
  @ui.hold_words(
    channel=@sf.t("web-main.logins.title"),
    title=if title == "" { @sf.t("web-main.logins.title") } else { title },
    body=@sf.t("web-main.logins.waitingBrowser"),
  )
  (core.call)(
    "machineLogin.open",
    { "station": Json::string(station), "id": Json::string(id), "here": Json::boolean(here) },
    fn(r) {
      match r {
        Ok(v) => login_open(core, text(Some(v), "url"))
        Err(e) if text(Some(e), "code") == "port_taken" => ()
        Err(e) =>
          (core.say)(
            @sf.t("android-misc.act.failed", args=[
              ("what", @sf.t("web-main.logins.openWhat")),
              ("error", error_words(e)),
            ]),
          )
      }
    },
  )
}

///|
/// The field a login's code is pasted in, by its key (login_paste's: the place, station and login; kept across frames).
/// One a place: a card shown in its chat and on its station's page beside it is two editors, and one Field given to
/// both faulted, the chat in its place 这部分显示出错了 as it opened (2026-11-06).
fn login_field(key : String) -> @ui.Field {
  match logins_here.fields.get(key) {
    Some(f) => f
    None => {
      let f = @ui.Field::new()
      logins_here.fields[key] = f
      f
    }
  }
}

///|
/// Login `id` of `station` as its card (login_card's, as nodes of a page made once), all of it as the core says it now:
/// nothing for one it does not know; ended, one quiet line; else its title, its × where it may be finished here, what
/// to do now and its step (a code to paste back, its field). `marked`, `place`: login_card's. The chat's card is the
/// old view's till its page is made once.
pub fn login_card_node(
  p : @view.View,
  core : Core,
  station : String,
  id : String,
  marked? : Bool = false,
  place? : String = "chat",
) -> Unit {
  let l = fn() { login_followed(core, station, id) }
  let all = fn() { logins_of(core, station) }
  // (the one shown: the one started again from it, where it was)
  let shown_id = fn() {
    match text(l(), "id") {
      "" => id
      shown => shown
    }
  }
  // the time, said again as each minute of a login's time left goes
  let now = @sf.countdown_now_node(p, core.now, fn() { number(l(), "expiresAt") })
  // signed in while its card is in view, felt as something done; failed, as something refused (feel.mbt)
  @sfbase.felt_change_node(p, fn() { text(l(), "state") == "done" }, Confirm)
  @sfbase.felt_change_node(p, fn() { text(l(), "state") == "failed" }, Reject)
  // (0: none; 1: ended; 2: under way, finished here; 3: under way, not here; 4: ended, started again here)
  let stands = fn() {
    match l() {
      None => 0
      Some(_) as v if !flag(v, "active") => if flag(v, "canAgain") && flag(all(), "canLogin") { 4 } else { 1 }
      _ => if flag(all(), "canLogin") { 2 } else { 3 }
    }
  }
  p.pick(stands, fn(x, k) {
    let in_sheet = place == "sheet"
    let title = fn() { text(l(), "title") }
    match k {
      0 => ()
      1 => @sfbase.login_ended_node(x, fn() { login_ended(l()).0 }, fn() { login_ended(l()).1 })
      // (in its login sheet its title alone: the sheet's own close is how it is put away)
      2 if in_sheet =>
        @sfbase.login_step_card_node(x, title, in_sheet~, marked~, fn(card) {
          login_active_node(card, core, station, l, fn() { flag(all(), "canRelay") }, place, now)
        })
      2 =>
        @sfbase.login_step_card_node(
          x,
          title,
          in_sheet~,
          marked~,
          cancel=(
            fn() { login_cancelling(core, station, shown_id()) },
            fn() { login_cancel_now(core, station, @signals.untracked(shown_id)) },
          ),
          fn(card) { login_active_node(card, core, station, l, fn() { flag(all(), "canRelay") }, place, now) },
        )
      4 =>
        @sfbase.login_step_card_node(x, title, in_sheet~, marked~, fn(card) {
          // (by the one it made: its step's press is a function made with it, no value to compare)
          let shows = @signals.computed_ref(fn(_) { login_again_shows(core, station, l()) })
          let shows = fn() { shows.get() }
          @sfbase.login_active_node(card, fn() { false }, fn(x, _) {
            @sfbase.login_lines_node(x, fn() { shows().said }, fn() { "" }, fn() { shows().step }, fn(_) {  })
          })
        })
      _ =>
        @sfbase.login_step_card_node(x, title, in_sheet~, marked~, fn(card) {
          @sfbase.login_said_node(card, fn() { said_line(text(l(), "statusText"), last=true) })
        })
    }
  })
}

///|
/// What a login under way shows (login_active's), as the core says it now: a code to paste back, else
/// login_shows' lines, its code and its step.
fn login_active_node(
  card : @view.View,
  core : Core,
  station : String,
  l : () -> Json?,
  relay : () -> Bool,
  place : String,
  now : () -> Double,
) -> Unit {
  @sfbase.login_active_node(card, fn() { flag(l(), "paste") && text(l(), "url") != "" }, fn(x, paste) {
    if paste {
      login_paste_node(x, core, station, l, place, now)
      return
    }
    // (by the one it made: its step's press is a function made with it, no value to compare)
    let shows = @signals.computed_ref(fn(_) { login_shows(core, station, l(), relay(), now()) })
    let shows = fn() { shows.get() }
    @sfbase.login_lines_node(x, fn() { shows().said }, fn() { shows().code }, fn() { shows().step }, fn(code) {
      @sfbase.copy_out(code)
      (core.say)(@sf.t("web-main.logins.codeCopied"))
    })
  })
}

///|
/// A login whose page gives a code to paste back (login_paste's), as the core says it now: its line and its step, then
/// the field (this place's: login_field), 完成 at its end once a code is in (Enter too), sent as the code pasted back.
fn login_paste_node(x : @view.View, core : Core, station : String, l : () -> Json?, place : String, now : () -> Double) -> Unit {
  let id = text(@signals.untracked(l), "id")
  let field = login_field(place + "\u{1}" + station + "\u{1}" + id)
  let words = fn() { field.text().trim(chars=" \n").to_owned() }
  // (by the one it made: its step's press is a function made with it, no value to compare)
  let shows = @signals.computed_ref(fn(_) { login_paste_shows(core, station, l(), words() != "", now()) })
  let shows = fn() { shows.get() }
  @sfbase.login_paste_node(x, fn() { shows().lead }, fn() { shows().step }, field, fn() { shows().busy }, fn(code) {
    login_answer(core, station, id, code)
  })
}

///|
/// A step left of something under an agent's message (step_card's, as nodes: the library's step_card_node), as it says
/// it now: its title, a line under it where there is one, the whole card the way to it (`go`) with a › in its corner;
/// none to go by, the card alone, taking no press.
pub fn step_card_node(
  v : @view.View,
  title : () -> String,
  line : () -> String,
  go : () -> (() -> Unit)?,
) -> Unit {
  @sfbase.step_card_node(v, title, line, go)
}
