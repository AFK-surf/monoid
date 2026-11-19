// A login a chat waits on its person for (the core's `workspaceMarks` items of the workspace in view with a `login`:
// a login card asking them), said in the app once as it comes while the app is shown and they are not in that chat: a
// toast naming the chat, 去登录 opening it at its card. A login runs out of time (15 minutes): a person elsewhere in the
// app is told at once rather than finding it ended. Only the card's decider has it in their items (decisions.ts
// `forViewer`), so nobody else in the workspace is told. Nothing of it with Source.read_only.

///|
/// The logins told already, by their chat's station and login: each told once (put back as a run begins).
// kept across runs: emptied as a run begins (login_asks_reset)
let login_asks_told : Map[String, Bool] = Map([])

///|
fn login_asks_reset() -> Unit {
  login_asks_told.clear()
}

///|
/// A login card waiting for the viewer, as 待处理 lists it: its chat's station and session, the chat's title, the
/// login.
#derive(Eq)
priv struct LoginAsk {
  station : String
  session : String
  title : String
  login : String
  /// when it runs out of time (0: not known)
  ends : Double
}

///|
/// Those of workspace `ws`'s 待处理 (`marks`, the core's `workspaceMarks`) that are login cards.
fn login_asks_of(marks : Json?, ws : String) -> Array[LoginAsk] {
  items(field(field(marks, "workspaces"), ws), "items").filter_map(fn(i) {
    let item = Some(i)
    match (text(item, "kind"), text(item, "login"), text(item, "session")) {
      ("wait", login, session) if login != "" && session != "" =>
        Some({ station: text(item, "station"), session, title: text(item, "title"), login, ends: number(item, "loginEnds") })
      _ => None
    }
  })
}

///|
/// What a login ask says in the toast as of `now`: the chat by its title (one with none, a chat), and how long is left of
/// it where that is known (· 剩 12 分钟).
fn login_ask_words(a : LoginAsk, now : Double) -> String {
  let asks = if a.title == "" {
    @sf.t("web-main.logins.asksUntitled")
  } else {
    @sf.t("web-main.logins.asks", args=[("chat", a.title)])
  }
  let minutes = ((a.ends - now + 59999.0) / 60000.0).floor().to_int()
  if a.ends <= 0.0 || minutes <= 0 {
    asks
  } else if minutes <= 1 {
    asks + " · " + @sf.t("web-main.attention.loginLast")
  } else {
    asks + " · " + @sf.t("web-main.attention.loginLeft", args=[("minutes", minutes.to_string())])
  }
}

///|
/// The login cards waiting for the viewer, told in node `v` at the moment they come (the marks' change, the app shown
/// again): each new one once, in a toast with 去登录, unless its chat is the one on top.
pub fn login_asks_node(v : @view.View, src : Source) -> Unit {
  v.reacts(
    fn() {
      match workspace_in_view(src).0 {
        Some(w) if !src.read_only && @ui.app_visible() =>
          login_asks_of(src.topic("workspaceMarks", marks_asked()).get().value, w.id)
        _ => []
      }
    },
    fn(asks) {
      let top = @signals.untracked(fn() { app.nav.top() })
      for a in asks {
        let key = a.station + "\u{1}" + a.login
        if login_asks_told.contains(key) {
          continue
        }
        login_asks_told[key] = true
        match top {
          Chat(r) if r.station == a.station && r.session == a.session => continue
          _ => ()
        }
        toast_later(login_ask_words(a, (src.now)()), action=@sf.t("web-main.logins.go"), run=fn() {
          open_chat({ station: a.station, session: a.session, title: a.title, station_name: "" })
        })
      }
    },
  )
}
