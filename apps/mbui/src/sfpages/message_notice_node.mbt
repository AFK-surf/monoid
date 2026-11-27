// What still.fail itself says in a chat (message.mbt's system_notice, notice_copy, notice_action, report_action, their
// styles the same), as nodes of the window's tree, made once: a pill across the chat, its words on one line (a failure
// in red); pressed, all of them, what failed said of it and its time under it. Each read through what it is given, as
// that changes; whether it is open, and when its 复制 was pressed, kept by the message (`opened`, `copied`: the
// caller's, by its ts), not on the nodes.
// Its 取消 makes its way along the row as a retry begins or ends (the framework's, along_row), the pill moved aside by
// as much. What lights the row across the list as the notice is gone to is hung on it by its page (`over`).

///|
/// What still.fail said (system_notice's) in its row's room (message_row_frame_node: `key`, its list's Entry::id; `side`,
/// `top`; `over`), as `m` says it as it changes: its pill across the chat, its words on one line, a failure's in red;
/// pressed, open (`opened`, by its ts: all its words, what failed said of it with 复制, its time under it) or closed again.
/// One about a profile, what to do of it at its end (· 重新登录, · 设置代理), else what went wrong, leads to the profile's
/// page; one saying the station lacks the chat's runtime ends in · 安装; a failure the station takes reports of in
/// · 上报 (asked first); one whose agent waits to retry, 取消 after the pill.
// the chat's page as nodes: held by its tests, not used by the app yet
#warnings("-unused_value")
fn notice_said_node(
  v : @view.View,
  src : Source,
  here : MessageNodeHere,
  key : () -> String,
  side : () -> Double,
  top : () -> Double,
  m : () -> Message,
  opened : @sf.LiveMap[String, Bool],
  copied : @sf.LiveMap[String, Double],
) -> MessageRowNode {
  message_row_frame_node(v, key, side, top, fn(r) {
    notice_body_node(r, src, here, m, opened, copied)
  })
}

///|
/// A notice's pill and its time under it (system_notice's notice_across) in `v`: notice_said_node's.
fn notice_body_node(
  v : @view.View,
  src : Source,
  here : MessageNodeHere,
  m : () -> Message,
  opened : @sf.LiveMap[String, Bool],
  copied : @sf.LiveMap[String, Double],
) -> Unit {
  let open = fn() { opened.get(m().ts).unwrap_or(false) }
  v.box(fn(across) {
    @sf.style_node(across, fn() { notice_across })
    across.box(fn(beside) {
      @sf.style_node(beside, fn() { notice_with_action })
      notice_pill_node(beside, src, here, m, open, opened, copied, across)
    })
    |> ignore
    // (its time under it while it is open: one against nothing said to leave, as a show said so would not (it holds
    // its place unfaded, then lets it go at once): coming, its place opens from the pill's foot as that is drawn on its
    // way and it is seen once that holds it whole, never cut, never over the pill still opening; going, it fades where
    // it is, its place closing after (msg_part_leave_ms; the coordinator of the migration, 2026-11-14))
    across.pick(open, leave=msg_part_leave_ms, fn(t, on) { if on { message_time_node(t, here.tips, fn() { m().time }) } })
  })
  |> ignore
}

///|
/// How a notice's words are drawn now (system_notice's): a chat's run changed, open, a line each (`Lines`), else to
/// another runtime or model each side after its mark (`Sides`), else on one line or what changed (`Short`); about a
/// profile, its link at its end (`Linked`); else its Markdown (`Md`). Linked and Md are the same words open or closed,
/// broken anew (open: all of them; closed: on one line, cut short), one node for both, so that opening never puts one
/// copy for another (a pick under a page's list draws those smaller and grows them back).
#derive(Eq)
priv enum NoticeWords {
  Lines
  Sides
  Short
  Linked
  Md
}

///|
/// How notice `m`'s words are drawn, `open` or not (NoticeWords).
fn notice_words_of(m : Message, open : Bool) -> NoticeWords {
  if m.notice_short != "" || m.notice_lines.length() > 0 {
    if open && m.notice_lines.length() > 0 {
      Lines
    } else if m.notice_sides is Some(_) {
      Sides
    } else {
      Short
    }
  } else if m.profile != "" && m.notice_link >= 0 && m.notice_link <= m.notice_words.length() {
    Linked
  } else {
    Md
  }
}

///|
/// What a notice's pill ends in (system_notice's): · 安装 where the station lacks the chat's runtime, else its 取消, 重试
/// or 重新分配账号 while offered (notice_after), else what to do of the profile it is about (· 重新登录, · 设置代理:
/// its page), else · 上报 where the failure is reportable, else nothing.
#derive(Eq)
priv enum NoticeEnd {
  Install
  Software
  Act
  ProfileAction
  Report
  NoEnd
}

///|
/// A notice's pill (system_notice's `pill`) in `v`: round on the neutral ground (a failure's, the danger's), rounded less
/// open; pressed, open or closed; its words, what it ends in, and open, what failed said of it.
fn notice_pill_node(
  v : @view.View,
  src : Source,
  here : MessageNodeHere,
  m : () -> Message,
  open : () -> Bool,
  opened : @sf.LiveMap[String, Bool],
  copied : @sf.LiveMap[String, Double],
  across : @view.View,
) -> Unit {
  let failed = fn() { m().notice_failed }
  let ink = fn() -> @ui.Color { if failed() { Danger } else { Fg } }
  let end = fn() {
    let now = m()
    match now.install {
      Some(i) if i.action != "" => Install
      _ =>
        match now.notice_software {
          Some(sw) if sw.action != "" => Software
          _ =>
            if notice_after(now) is Some(_) {
              Act
            } else if now.profile != "" && now.notice_profile_action != "" {
              ProfileAction
            } else if now.reportable {
              Report
            } else {
              NoEnd
            }
        }
    }
  }
  @sf.notice_pill_node(
    v,
    fn() { notice_label(m()) },
    open,
    failed,
    fn() { m().notice_count },
    // (opened or closed by the person's press: its pill goes from the shape it had to the one it comes to, across and
    // down, its corners with it, on its list's way, @view.transition)
    fn() {
      let ts = @signals.untracked(m).ts
      // (its size said to change for the press before anything of it is laid out anew: its words broken anew are no
      // structure, so without it the list would take where all was drawn only once the words were laid out open, and
      // the pill would widen at once)
      @view.transition(fn() {
        across.resizes() |> ignore
        opened[ts] = !opened.get(ts).unwrap_or(false)
      })
    },
    fn(room) { room.pick(fn() { notice_words_of(m(), open()) }, fn(w, how) { notice_words_node(w, here, m, ink, open, how) }) },
    // (what follows its words held to the foot of their first line where they are Markdown)
    md_led=fn() { notice_words_of(m(), false) is Md },
    end=fn(line, strut) {
      line.pick(end, fn(e, which) {
        match which {
          Install => {
            let i = fn() { m().install.unwrap_or(mine_installed) }
            notice_action_node(e, fn() { i().action }, ink, fn() { install_busy(src, here.station, i()) }, strut~, fn() {
              install_runtime(src, here.station, @signals.untracked(i))
            })
          }
          Software => {
            let sw = fn() { m().notice_software.unwrap_or(no_notice_software) }
            notice_action_node(
              e,
              fn() { sw().action },
              ink,
              fn() { software_notice_busy(src, (here.view)().offline, here.station, sw()) },
              strut~,
              fn() { software_notice_act(src, (here.view)().offline, here.station, @signals.untracked(sw)) },
            )
          }
          Act => {
            // (as it was last offered while it goes)
            let last = Ref(("", "", ""))
            let after = fn() {
              match notice_after(m()) {
                Some(a) => {
                  last.val = a
                  a
                }
                None => last.val
              }
            }
            let on = fn() { [("station", here.station), ("key", after().0)] }
            notice_action_node(e, fn() { after().1 }, ink, fn() { src.read_only || (here.view)().offline || core_doing(src, [after().2], on()) }, strut~, fn() {
              let now = @signals.untracked(m)
              let (session, label, call) = @signals.untracked(after)
              if !src.read_only && !(here.view)().offline {
                act(src, label, "", call, {
                  "station": Json::string(here.station),
                  "key": Json::string(session),
                  "thread": Json::number(now.thread),
                  // (of a notice folding several, the last: what its turn is bound to)
                  "seq": Json::number(now.notice_last_seq),
                })
              }
            })
          }
          ProfileAction =>
            notice_action_node(e, fn() { m().notice_profile_action }, ink, fn() { false }, strut~, fn() {
              open_page(Setting(@settings.Route::Profile(here.station, @signals.untracked(m).profile)))
            })
          Report => notice_report_node(e, src, here, m, ink, strut~)
          NoEnd => ()
        }
      })
    },
    // (what failed said of it, as it said it)
    detailed=fn() { m().notice_detail != "" },
    detail=fn(d) {
      d.box(fn(w) {
        w
        .words_runs(By(fn() { [@ui.span(m().notice_detail, mono=true)] }))
        .words_look(By(fn() { @ui.style_words(notice_detail.then(@ui.text_style(color=ink()))) }))
        .ink(By(fn() { @ui.style_ink(notice_detail.then(@ui.text_style(color=ink()))) }))
        |> ignore
      })
      |> ignore
      notice_copy_node(d, m, ink, copied)
    },
  )
  |> ignore
}

///|
/// What a notice's pill is read out as: its words, and how many it folds where it folds several (×n).
fn notice_label(m : Message) -> String {
  if m.notice_count > 1 {
    "\{m.notice_words} ×\{m.notice_count}"
  } else {
    m.notice_words
  }
}

///|
/// A notice's words (system_notice's, by NoticeWords) in `v`, in `ink`, at the notice's size and leading.
fn notice_words_node(
  v : @view.View,
  here : MessageNodeHere,
  m : () -> Message,
  ink : () -> @ui.Color,
  open : () -> Bool,
  how : NoticeWords,
) -> Unit {
  let style = fn(open : Bool) { (if open { notice_words_open } else { notice_words }).then(@ui.text_style(color=ink())) }
  match how {
    Lines =>
      v.each(fn() { m().notice_lines.mapi(fn(i, l) { (i, l) }) }, fn(l) { l.0 }, fn(b, l) {
        @sf.words_node(b, fn() { l.get().1 }, fn() { style(true) }) |> ignore
      })
    Sides =>
      // (where the line has not the room for both, what it ran on left out and what it runs on now led by 换成:
      // View::fits, View::drops)
      v.box(fn(r) {
        @sf.style_node(r, fn() { notice_sides }, in_row=true)
        r.fits(Is(true)) |> ignore
        let sides = fn() { m().notice_sides.unwrap_or(no_sides) }
        let st = fn() { style(false) }
        r.box(fn(lead) {
          @sf.style_node(lead, fn() { notice_sides_part }, in_row=true)
          lead.drops(Is(-1)) |> ignore
          @sf.words_node(lead, fn() { sides().to }, st) |> ignore
        })
        |> ignore
        r.box(fn(was) {
          @sf.style_node(was, fn() { notice_sides_part }, in_row=true)
          was.drops(Is(1)) |> ignore
          notice_side_node(was, fn() { (sides().was_maker, sides().was_runtime) }, fn() { sides().was }, st, cuts=false)
          @sf.words_node(was, fn() { "→" }, st) |> ignore
        })
        |> ignore
        notice_side_node(r, fn() { (sides().now_maker, sides().now_runtime) }, fn() { sides().now }, st, cuts=true)
      })
      |> ignore
    Short =>
      v.box(fn(w) {
        w
        .words(By(fn() { m().notice_words }))
        .words_look(By(fn() { @ui.style_words(style(false)) }))
        .ink(By(fn() { @ui.style_ink(style(false)) }))
        .shorter(By(fn() { [m().notice_short] }))
        .allow_ellipsis(Is(true))
        |> ignore
      })
      |> ignore
    Linked => {
      let runs = fn() {
        let now = m()
        [
          @ui.span(now.notice_words.clamped_view(end=now.notice_link).to_owned()),
          @ui.span(now.notice_words.clamped_view(start=now.notice_link).to_owned(), underline=true, link="profile"),
        ]
      }
      v.box(fn(w) {
        w
        .words_runs(By(runs))
        .words_look(By(fn() { @ui.style_words(style(open())) }))
        .runs_look(By(fn() {
          { ..@view.runs_plain, link: if m().notice_failed { @sf.theme().p.red } else { @sf.theme().p.text } }
        }))
        .ink(By(fn() { @ui.style_ink(style(open())) }))
        .allow_ellipsis(By(fn() { !open() }))
        |> ignore
        @ui.runs_links(w, runs, fn(_) {
          open_page(Setting(@settings.Route::Profile(here.station, @signals.untracked(m).profile)))
        })
        |> ignore
      })
      |> ignore
    }
    Md => {
      // (its words as Markdown, as the core read them (a chat it opened: a link to it), of the notice's size open or
      // closed; closed, their first block on one line)
      let th = @ui.tree_theme()
      let meta = th.text_size(notice_size).0
      @sf.markdown_node(
        v,
        fn() { m().notice_words },
        tree=fn() { m().notice_md },
        size=fn() { meta },
        line=fn() { th.leading(notice_leading).unwrap_or(0.0) / meta },
        one_line_by=fn() { !open() },
        ink=fn() { if m().notice_failed { @sf.theme().p.red } else { 0L } },
        on_link=fn(h) { open_link(h) },
        chat_title=fn(h) { chat_title_of(m())(h) },
      )
      |> ignore
    }
  }
}

///|
/// A run's change with no sides (a notice's words that are none such: drawn as nothing).
// kept across runs: a value (no field of it changes)
let no_sides : RunSides = { was: "", now: "", to: "", was_maker: "", was_runtime: "", now_maker: "", now_runtime: "" }

///|
/// A side of a run's change (notice_words_node's `Sides`) in `v`: the mark of who made its model (`mark`: its maker,
/// its runtime), then its words in `style`, cut short where the line has not the room where it `cuts`.
fn notice_side_node(
  v : @view.View,
  mark : () -> (String, String),
  words : () -> String,
  style : () -> @ui.TextStyle,
  cuts~ : Bool,
) -> Unit {
  let size = @ui.tree_theme().text_size(notice_size).0
  v.pick(mark, fn(b, now) { @sf.maker_mark_node(b, now.0, now.1, size) |> ignore })
  v.box(fn(w) {
    w
    .words(By(words))
    .words_look(By(fn() { @ui.style_words(style()) }))
    .ink(By(fn() { @ui.style_ink(style()) }))
    .allow_ellipsis(Is(true))
    .cuts(Is(cuts))
    // (the side that cuts kept whole first: the one beside it given up where both have not the room, as the old
    // view's notice kept it (message.mbt's `keep`), never this one cut to its least)
    .fit_whole(Is(cuts))
    |> ignore
  })
  |> ignore
}

///|
/// A word at a notice's end that acts on it (notice_action's) in `v`: " · " at 60%, then `action`, underlined, in `ink`;
/// not offered while it is under way (`busy`: fainter).
fn notice_action_node(
  v : @view.View,
  action : () -> String,
  ink : () -> @ui.Color,
  busy : () -> Bool,
  strut? : () -> Double = fn() { 0.0 },
  run : () -> Unit,
) -> Unit {
  @sf.notice_end_action_node(v, action, fn() { ink() == Danger }, busy, run, strut~) |> ignore
}

///|
/// A failure sent to the still.fail team (report_action's) in `v`: · 上报, asked first, saying what goes; what it was
/// filed as said once sent; not offered while it goes.
fn notice_report_node(
  v : @view.View,
  src : Source,
  here : MessageNodeHere,
  m : () -> Message,
  ink : () -> @ui.Color,
  strut? : () -> Double = fn() { 0.0 },
) -> Unit {
  let action = fn() { @sf.t("common.report.action") }
  let on = fn() {
    let now = m()
    [("station", here.station), ("thread", now.thread.to_int().to_string()), ("seq", now.notice_last_seq.to_int().to_string())]
  }
  notice_action_node(v, action, ink, fn() { core_doing(src, ["chat.report"], on()) }, strut~, fn() {
    let now = @signals.untracked(m)
    let said = @signals.untracked(action)
    @sf.confirm(@sf.t("common.report.title"), @sf.t("common.report.lead") + "\n\n" + @sf.t("common.report.sends"), said, fn() {
      act(
        src,
        said,
        "",
        "chat.report",
        { "station": Json::string(here.station), "thread": Json::number(now.thread), "seq": Json::number(now.notice_last_seq) },
        ok=fn(v) {
          @ui.haptic(Confirm)
          let number = match field(Some(v), "number") {
            Some(Number(n, ..)) => n.to_int().to_string()
            _ => "?"
          }
          toast_later(
            @sf.t(if flag(Some(v), "duplicate") { "common.report.again" } else { "common.report.done" }, args=[
              ("number", number),
            ]),
          )
        },
      )
    })
  })
}

///|
/// What failed said of a notice, copied (notice_copy's) in `v`: 复制, underlined, in `ink`'s; 已复制 for copied_ms from
/// the moment it was pressed (pressed again while it says so, from then). By the message (`copied`, by its ts): its row
/// made again while that lasts says 已复制 till its end.
fn notice_copy_node(v : @view.View, m : () -> Message, ink : () -> @ui.Color, copied : @sf.LiveMap[String, Double]) -> Unit {
  let said = @signals.signal(false, same=fn(a, b) { a == b })
  let off : Ref[() -> Unit] = Ref(fn() {  })
  let said_from = fn(at : Double) {
    (off.val)()
    if v.cause_at() < at + @sf.copied_ms {
      said.set(true)
      off.val = v.at_moment(at + @sf.copied_ms, fn() { said.set(false) })
    } else {
      said.set(false)
    }
  }
  // (as the message it is of says: copied a moment ago, till that one's end)
  v.reacts(fn() { m().ts }, fn(ts) {
    match @signals.untracked(fn() { copied.get(ts) }) {
      Some(at) => said_from(at)
      None => {
        (off.val)()
        said.set(false)
      }
    }
  })
  v.owns(fn() { (off.val)() }) |> ignore
  let words = fn() { @sf.t(if said.get() { "common.copied" } else { "common.copy" }) }
  @sf.action_box_node(v, words, fn(b) {
    let now = @signals.untracked(m)
    @ui.clipboard_set(now.notice_detail)
    let at = b.cause_at()
    copied[now.ts] = at
    said_from(at)
  }, fn(b) {
    @sf.style_node(b, fn() { notice_copy_room })
    let look = fn() { if ink() == Danger { notice_act_failed } else { notice_act } }
    b.box(fn(w) {
      w
      .words_runs(By(fn() { [@ui.span(words(), underline=true)] }))
      .words_look(By(fn() { @ui.style_words(look()) }))
      .ink(By(fn() { @ui.style_ink(look()) }))
      |> ignore
    })
    |> ignore
  })
  |> ignore
}
