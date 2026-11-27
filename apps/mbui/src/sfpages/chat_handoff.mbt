// A chat whose station does not answer gone on with on another station of its workspace, from its page's "…" (在其他
// station 接着做, for any member): the workspace's other stations picked among (one that does not answer faint, 离线
// under it), then what it means said before it is done (the station may still run, the two chats go on apart, the new
// one starts from the backup, the working directory stays behind), then asked of the station picked (`copies.handoff`,
// its station's replica/handoff.ts): a new chat there, its first message what the backup a station keeps holds of
// this one. Its dialog waits on it (tens of seconds: a backup read on another station), then the new chat opens; a
// refusal said in the station's own words in the dialog, to try again or let go of.

///|
/// The 在其他 station 接着做 of chat `r`'s menu, opened from `from`: where its station does not answer (its page's view
/// `offline`), its thread is known and its workspace has another station; else none.
fn chat_handoff_item(src : Source, r : ChatRef, from~ : () -> @sf.Beside) -> @sf.MenuItem? {
  guard @sfbase.chat_view_now(src, r) is Some(cv) && cv.offline else { return None }
  guard cv.thread is Some(thread) else { return None }
  let others = handoff_stations(src, r)
  guard !others.is_empty() else { return None }
  Some(
    @sf.menu_item_of(@sf.t("web-pages.chat.handoff.menu"), icon="move", further=true, fn() {
      open_chat_handoff(src, r, thread, from=from())
    }),
  )
}

///|
/// The stations of chat `r`'s workspace other than its own, as its marks have them (each with how it is reached).
fn handoff_stations(src : Source, r : ChatRef) -> Array[@sfbase.Station] {
  @sfbase.station_marks(src, @sfbase.workspace_of(r.station)).filter(fn(s) { s.address != r.station })
}

///|
/// Chat `r`'s (thread `thread`) station to go on with it on picked (`from` where its menu opened): one that answers,
/// the others faint with why; the one picked asked about in handoff_confirm.
fn open_chat_handoff(src : Source, r : ChatRef, thread : Double, from~ : @sf.Beside) -> Unit {
  let others = handoff_stations(src, r)
  let choices = others.map(fn(s) {
    let away = s.via == "offline"
    @sfbase.station_choice(s.address, s.name, s.emoji, s.icon, note=if away { @sf.t("web-pages.stations.offline") } else { "" }, disabled=away)
  })
  @sf.pick(@sf.t("web-pages.chat.handoff.pick"), choices, "", fn(address) {
    match others.iter().find_first(fn(s) { s.address == address }) {
      Some(to) => handoff_confirm(src, r, thread, to)
      None => ()
    }
  }, from~, search=false)
}

///|
/// What going on with chat `r` (thread `thread`) on station `to` means, said in a dialog before it is done; its
/// 接着做 asks it of `to` under one key made as the dialog opens (pressed again after a refusal or a lost answer, the
/// station gives the chat it opened for it, never a second), busy while it runs. Answered, the dialog shuts and the
/// new chat opens; the dialog shut meanwhile, a toast says it is there with 打开. Refused, the station's words under
/// the dialog's, or a toast where it is shut. `asked`: 接着做 pressed as it opens (a fixture's step).
fn handoff_confirm(src : Source, r : ChatRef, thread : Double, to : @sfbase.Station, asked? : Bool = false) -> Unit {
  let from = if r.station_name != "" { r.station_name } else { @settings.station_name(r.station) }
  // (the source's time of day as the dialog opens: a key of its own after the app starts again, too)
  let key = "handoff-" + r.session + "-" + @settings.station_name(to.address) + "-" + (src.now)().to_int64().to_string()
  let running : @signals.Signal[Bool] = @signals.signal(false)
  let refused : @signals.Signal[String] = @signals.signal("")
  let refusal_words = st_problem_bad.then(@ui.text_style(dark=@ui.text_patch(color=Over(Danger, A(Fg, O25)))))
  let shown = Ref(true)
  let shut_by : Ref[() -> Unit] = Ref(fn() {  })
  let lines = [
    @sf.t("web-pages.chat.handoff.running"),
    @sf.t("web-pages.chat.handoff.files"),
  ]
  let go = fn() {
    if src.read_only {
      toast_later(@sfbase.read_only_words)
      return
    }
    running.set(true)
    refused.set("")
    let params = obj([
      ("station", str(to.address)),
      ("origin", str(@settings.station_name(r.station))),
      ("thread", Json::number(thread)),
      ("key", str(key)),
    ])
    (src.call)("copies.handoff", params, fn(res) {
      match res {
        Ok(v) => {
          @ui.haptic(Confirm)
          let title = match text(Some(v), "title") {
            "" => r.title
            t => t
          }
          let made : ChatRef = { station: to.address, session: text(Some(v), "session"), title, station_name: to.name }
          if shown.val {
            // (the dialog leaves as it stands, its words at work and 接着做 turning: a line let go of as it leaves
            // goes at once, its column a step shorter in a frame)
            shown.val = false
            (shut_by.val)()
            @sfbase.open_chat(made)
          } else {
            running.set(false)
            toast_later(
              @sf.t("web-pages.chat.handoff.made", args=[("station", to.name), ("title", title)]),
              action=@sf.t("web-pages.chat.handoff.open"),
              run=fn() { @sfbase.open_chat(made) },
            )
          }
        }
        Err(e) => {
          @ui.haptic(Reject)
          running.set(false)
          if shown.val {
            refused.set(error_words(e))
          } else {
            toast_later(error_words(e))
          }
        }
      }
    })
  }
  open_dialog_nodes(
    @sf.t("web-pages.chat.handoff.title"),
    fn(v, _) {
      station_info_card_node(v, [
        station_info_from_source(src, r.station, from, role=@sf.t("common.confirmFact.sourceStation"), show=StationInfoShow::compact()),
        station_info_from_source(src, to.address, to.name, role=@sf.t("common.confirmFact.targetStation"), show=StationInfoShow::target()),
      ])
      for line in lines {
        @sf.words_node(v, fn() { line }, fn() { st_memory }) |> ignore
      }
      v.show(fn() { running.get() }, fn(n) {
        @sf.words_node(n, fn() { @sf.t("web-pages.chat.handoff.doing") }, fn() {
          st_memory
        })
        |> ignore
      })
      v.show(fn() { refused.get() != "" && !running.get() }, fn(n) {
        @sf.words_node(n, fn() { refused.get() }, fn() { refusal_words }) |> ignore
      })
    },
    fn(v, shut) {
      shut_by.val = shut
      @sf.button_node(v, fn() { @sf.t("common.cancel") }, fn() {
        shown.val = false
        shut()
      }, tone=Ghost)
      |> ignore
      @sf.button_node(v, fn() { @sf.t("web-pages.chat.handoff.action") }, go, tone=Primary, busy=fn() { running.get() }, disabled=fn() {
        running.get()
      })
      |> ignore
    },
    on_gone=fn() { shown.val = false },
  )
  if asked {
    go()
  }
}

///|
/// 在其他 station 接着做 of chat `r` (its page open) at step `step`, without the presses before it, as a fixture mode
/// shows it (sfapp fixture_open.mbt): "pick" its stations to go on on, from `from`; "confirm" what going on on station
/// `to` means; "asked" that with 接着做 pressed.
pub fn open_chat_handoff_step(src : Source, r : ChatRef, step : String, to : String, from~ : @sf.Beside) -> Unit {
  guard @sfbase.chat_view_now(src, r) is Some(cv) && cv.thread is Some(thread) else { return }
  match step {
    "pick" => open_chat_handoff(src, r, thread, from~)
    _ => {
      let sts = handoff_stations(src, r)
      for i = 0; i < sts.length(); i = i + 1 {
        if sts[i].address == to {
          handoff_confirm(src, r, thread, sts[i], asked=step == "asked")
          break
        }
      }
    }
  }
}
