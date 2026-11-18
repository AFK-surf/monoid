// A page's login filled from this device's password manager ("Filling a login"): while
// this viewer drives a tab of a station's browser whose focus is in a login field, the station says the site (the
// tab's address, not the page's word); the person's own 1Password (@hostapi passwords.mbt: its command-line tool,
// which asks them itself) is asked for that site's logins, they pick one where there are more, and its account and
// password go to the station to fill the form (`screen.input` fill), for that site only. Where there is no such tool
// but the system has an autofill service (Android's: @hostapi autofill.mbt), that service is asked for the site's
// login instead and offers its logins itself; the one picked goes the same way. Nothing of a password is kept here,
// logged or shown.

///|
/// Which login input `(host, field, address)` the view's state currently reports in focus; `None` when in none.
fn login_slot_of(state : Json?) -> (String, String, String)? {
  match field(state, "login") {
    Some(Object(_) as l) => {
      let host = text(Some(l), "host")
      if host == "" {
        None
      } else {
        Some((host, text(Some(l), "field"), text(state, "address")))
      }
    }
    _ => None
  }
}

///|
/// The login field in focus, while this viewer drives the screen: the site's host; None in none, already filled,
/// dismissed for this field and address, or only looking.
fn ScreenSess::login_host(self : ScreenSess) -> String? {
  let dismissed = self.fill_dismissed.get()
  if !self.driving() {
    return None
  }
  match field(self.state, "login") {
    Some(Object(_) as l) => {
      let host = text(Some(l), "host")
      if host == "" || flag(Some(l), "filled") || (dismissed is Some(w) && login_slot_of(self.state) == Some(w)) {
        None
      } else {
        Some(host)
      }
    }
    _ => None
  }
}

///|
/// 填入 pressed: the password manager asked for the site's logins.
fn ScreenSess::fill_start(self : ScreenSess) -> Unit {
  guard self.login_host() is Some(host) else { return }
  self.fill_stop()
  self.fill_host = host
  if !@hostapi.passwords() && @hostapi.autofill_ask(host) {
    // the system's autofill service offers the site's logins itself; the one picked comes back (fill_auto_took)
    self.fill_step.set("auto")
    return
  }
  self.fill_ask(["item", "list", "--categories", "Login", "--format", "json"], "listing")
}

///|
/// The login picked in the system's autofill service: filled, where it is for the site asked for (the station fills
/// the page's form only while its tab is on that site, as for 1Password's).
fn ScreenSess::fill_auto_took(self : ScreenSess, got : (String, String, String)) -> Unit {
  let (host, username, password) = got
  guard self.fill_step.get() == "auto" && host == self.fill_host else { return }
  @hostapi.autofill_end()
  self.fill_step.set("")
  if self.input_goes() {
    self.fill_send(username, password)
  } else {
    // (the service's sign-in took the app out of sight: the view opens again, then it is sent)
    self.fill_owed = Some((username, password))
  }
}

///|
/// The login's account and password sent to the station to fill the page's form, for the site asked for only.
fn ScreenSess::fill_send(self : ScreenSess, username : String, password : String) -> Unit {
  let input : Map[String, Json] = { "t": Json::string("fill"), "host": Json::string(self.fill_host) }
  if username != "" {
    input["username"] = Json::string(username)
  }
  if password != "" {
    input["password"] = Json::string(password)
  }
  self.input(self.src, Json::object(input))
}

///|
/// `op` run with `args`, the step it is for set; one that cannot run said so.
fn ScreenSess::fill_ask(self : ScreenSess, args : Array[String], step : String) -> Unit {
  match @hostapi.op_run(args) {
    Some(r) => {
      self.fill_run = Some(r)
      self.fill_step.set(step)
    }
    None => self.fill_said(@sf.t("android-misc.screen.fill.noOp"))
  }
}

///|
fn ScreenSess::fill_said(self : ScreenSess, note : String) -> Unit {
  self.fill_note = note
  self.fill_step.set("said")
}

///|
/// One of the site's logins picked (or the only one): its account and password asked for.
fn ScreenSess::fill_pick(self : ScreenSess, l : @hostapi.PasswordLogin) -> Unit {
  self.fill_choices = []
  self.fill_ask(["item", "get", l.id, "--fields", "label=username,label=password", "--reveal", "--format", "json"], "getting")
}

///|
/// Closed (`×`): any run under way stopped, and this field on this page not offered again until the focus leaves it or
/// the tab goes elsewhere.
fn ScreenSess::fill_dismiss(self : ScreenSess) -> Unit {
  match login_slot_of(self.state) {
    Some(slot) => self.fill_dismissed.set(Some(slot))
    None => ()
  }
  self.fill_stop()
}

///|
/// Let go of: the run under way stopped, nothing shown.
fn ScreenSess::fill_stop(self : ScreenSess) -> Unit {
  match self.fill_run {
    Some(r) => r.end()
    None => ()
  }
  self.fill_run = None
  self.fill_owed = None
  if self.fill_step.get() == "auto" {
    @hostapi.autofill_end()
  }
  self.fill_choices = []
  self.fill_note = ""
  self.fill_step.set("")
}

///|
/// Why 1Password did not give a login, in the person's words (a page's fill and a sign-in's card say it alike).
fn op_trouble_words(t : @hostapi.OpTrouble) -> String {
  match t {
    NoTool => @sf.t("android-misc.screen.fill.noOp")
    Unreached => @sf.t("android-misc.screen.fill.unreached")
    Other(why) => @sf.t("android-misc.screen.fill.failed", args=[("why", why)])
  }
}

///|
/// The run under way ended: what it said taken (once).
fn ScreenSess::fill_took(self : ScreenSess) -> Unit {
  guard self.fill_run is Some(r) else { return }
  guard r.done() is Some(d) else { return }
  r.end()
  self.fill_run = None
  match d.trouble() {
    Some(t) => {
      self.fill_said(op_trouble_words(t))
      return
    }
    None => ()
  }
  match self.fill_step.get() {
    "listing" => {
      let found = @hostapi.logins_for(d.out, self.fill_host)
      if found.is_empty() {
        self.fill_said(@sf.t("android-misc.screen.fill.none", args=[("host", self.fill_host)]))
      } else if found.length() == 1 {
        self.fill_pick(found[0])
      } else {
        self.fill_choices = found
        self.fill_step.set("choosing")
      }
    }
    "getting" => {
      let (username, password) = @hostapi.login_fields(d.out)
      if username == "" && password == "" {
        self.fill_said(@sf.t("android-misc.screen.fill.empty"))
        return
      }
      self.fill_send(username, password)
      self.fill_step.set("")
    }
    _ => ()
  }
}

///|
/// 用 1Password 填入 (用密码管理器填入 where the system's autofill service is asked), over the stage in `c` while the focus
/// is in a login field of a page this viewer drives (on a host that has a password manager to ask): what it is at, the
/// logins to pick from, or why it did not fill. A run's end, the login picked in the service's offer, and a login owed
/// to the view while it could take no input, each taken as it is told.
fn login_fill_node(c : @view.View, s : ScreenSess) -> Unit {
  // a run under way: its end taken once it came
  c.reacts(fn() {
    s.fill_step.get() |> ignore
    match s.fill_run {
      Some(r) => r.done() is Some(_)
      None => false
    }
  }, fn(ended) { if ended { s.fill_took() } })
  // the login picked in the service's offer, once it came (the page's focus may have left the login meanwhile: the
  // app's own tap on 填入 can take it, before the service answers; it is filled as 1Password's is)
  c.reacts(fn() { if s.fill_step.get() == "auto" { @hostapi.autofill_take() } else { None } }, fn(got) {
    match got {
      Some(g) => s.fill_auto_took(g)
      None => ()
    }
  })
  c.reacts(fn() { s.fill_step.get() |> ignore; s.said.get() |> ignore; s.fill_owed is Some(_) && s.input_goes() }, fn(now) {
    if now {
      match s.fill_owed {
        Some((username, password)) => {
          s.fill_owed = None
          s.fill_send(username, password)
        }
        None => ()
      }
    }
  })
  let op = fn() { @hostapi.passwords() }
  let host = fn() {
    s.said.get() |> ignore
    s.login_host()
  }
  // (what it is about read first, so it is followed whatever the host has: a host's manager is its from its start)
  c.show(at_once=true, fn() { !(host() is None && s.fill_step.get() == "") && (op() || @hostapi.autofill()) }, fn(card) {
    @sf.style_node(card, fn() { drops_box })
    floats_node(card)
    card.box(fn(row) {
      @sf.style_node(row, fn() { drop_row_box }, in_row=true)
      let step = fn() { s.fill_step.get() }
      @sf.first_line_node(row, Ui, fn(l) {
        @sf.icon_node(l, "key", drop_icon, By(fn() { @ui.tree_theme().color(Muted) }), name_now=fn() { if step() == "said" { "info" } else { "key" } })
        |> ignore
      })
      // (its first line as high as its close key: across its middle)
      .min_height(Is(Some(drop_key_side)))
      |> ignore
      @sf.row_lines_node(
        row,
        fn(first) {
          let title = fn() {
            match step() {
              "listing" | "getting" => @sf.t("android-misc.screen.fill.asking")
              "auto" => @sf.t("android-misc.screen.fill.autoPick", args=[("host", s.fill_host)])
              "choosing" => @sf.t("android-misc.screen.fill.pick", args=[("host", s.fill_host)])
              "said" => s.fill_note
              _ => @sf.t(if op() { "android-misc.screen.fill.offer" } else { "android-misc.screen.fill.offerAuto" })
            }
          }
          first.box(fn(w) {
            @sf.style_node(w, fn() { drop_words }, in_row=true)
            @sf.words_node(w, title, fn() { if step() == "said" { drop_path_words } else { drop_name } }) |> ignore
          })
          |> ignore
          screen_row_key_node(first, "close", @sf.t("common.close"), fn() { s.fill_dismiss() })
        },
        fn(under) {
          under.pick(at_once=true, step, fn(u, st) {
            match st {
              "" => {
                // the site under the words, 填入 under it (as a file sent says where it is, then what is done with it)
                u.show(at_once=true, fn() { host() is Some(_) }, fn(h) {
                  @sf.words_node(h, fn() { host().unwrap_or("") }, fn() { drop_path_words }) |> ignore
                })
                u.box(fn(b) {
                  @sf.style_node(b, fn() { drop_buttons }, in_row=true)
                  soft_button_node(b, fn() { @sf.t("android-misc.screen.fill.button") }, fn() { s.fill_start() })
                })
                |> ignore
              }
              "choosing" =>
                // one under another, as wide as its words (none out to the panel's corner)
                u.box(fn(list) {
                  @sf.style_node(list, fn() { fill_choice_list })
                  list.each(at_once=true, fn() { s.fill_step.get() |> ignore; s.fill_choices.copy() }, fn(l) { l.id }, fn(slot, l) {
                    let l = l.untracked()
                    let words = if l.username == "" { l.title } else { l.title + " · " + l.username }
                    soft_button_node(slot, fn() { words }, fn() { s.fill_pick(l) })
                  })
                })
                |> ignore
              _ => ()
            }
          })
        },
      )
    })
    |> ignore
  })
}

///|
/// The logins to pick from: one under another, each as wide as its words.
// kept across runs: a value (no field of it changes)
let fill_choice_list : @ui.Style = @ui.css("align=AStart pt=S2 gap=S2")
