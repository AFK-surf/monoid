// Settings' 共享调试 (adb_settings' description, station_parts.mbt) made once as nodes of the window's tree, one page in
// every frame (page_node), and a chat's station tab of it: the phone's switch, the first thing it lacks for a chat's
// grant, the grants from before signatures, the chats it is lent to now; off the person's own lock, that step alone.

///|
/// Settings' 共享调试 in node `v` (2026-10-29: as the vault's page): a chat's agent asks for the phone and its person
/// grants it on the card in the chat, which also takes the phone through what it lacks the first time (2026-11-11).
/// Here, on a phone: its switch (2026-10-30: off at first, on until turned off, `adb.on`), lent to no chat while off;
/// while a chat's grant is live and the phone lacks something for it, that step, as the chat's card says it; the grants
/// from before signatures, one tap from lending again; then the chats it is granted to now, each taken back with 收回.
/// Off a phone, only those chats. (2026-11-11, 左子健: each thing asked "when does a person need this?".) The one page of
/// 共享调试: a station's (its link in a chat, the desk's tab) is this one, `focus` the lent station whose step is said
/// first. (2026-11-06, 左子健: 如果这个共享调试之后必须用个人锁，那就整个页面只显示个人锁，开了才有后面的; 用专门的 UI) Off the
/// person's own lock nothing else here does anything: the page is the step alone while this device is to be approved,
/// or the lock was set up again elsewhere; with no lock yet there is no step (allowing a request begins it).
pub fn adb_node(
  v : @view.View,
  core : Core,
  focus : String,
  on_back~ : () -> Unit,
  frame~ : () -> @sf.PageFrame,
  said? : (@sf.PageSaid) -> Unit,
  width? : () -> Double,
  tips? : @sf.TipLayer,
  sub? : () -> String = fn() { "" },
) -> Unit {
  let view = fn() { (core.topic)("adbShare", Map([])).get().value }
  let phone = adb_phone_node(v)
  @sf.page_node(
    v,
    fn() { tr("android-misc.adb.title") },
    on_back~,
    frame~,
    said?,
    width?,
    tips?,
    // (what it is, in the ⓘ after its title, on every width: not a card of words over the page; wide, the page's own
    // about, its mark beside its title and said with it; narrow, the mark at the end of its bar's title line)
    about=fn() { tr("android-misc.adb.chats.about") },
    actions=fn(a) { @sf.narrow_about_node(a, fn() { tr("android-misc.adb.chats.about") }, tips.unwrap_or(@sf.window_tips())) },
    fn() { adb_keys(view(), phone(), sub()) },
    fn(b, k) { adb_block(b, core, view, phone, focus, sub, k) },
  )
}

///|
/// The person's own lock this device is off and has a step on (to be approved, or set up again elsewhere): the lock of
/// the account whose workspace is in view (`sub`) where the core lists it, by its standing alone (another account signed
/// in here being a member lends this one nothing); else, where it is on none as a member, the first with a step.
pub fn personal_lock_step(view : Json?, sub : String) -> Json? {
  let locks = items(view, "personal")
  let needs = fn(l : Json) {
    text(Some(l), "standing") == "outside" || text(Some(l), "standing") == "replaced"
  }
  if sub != "" {
    match locks.iter().find_first(fn(l) { text(Some(l), "sub") == sub }) {
      Some(own) => return if needs(own) { Some(own) } else { None }
      None => ()
    }
  }
  if locks.iter().any(fn(l) { text(Some(l), "standing") == "member" }) {
    return None
  }
  locks.iter().find_first(needs)
}

///|
/// The first thing to do on this phone for a live grant (adb_next: what the phone lacks, else what a station it is lent
/// to waits on of it, `focus`'s first), and the station it is for ("" the phone's own); None where nothing is, or no
/// grant is live, or this device lends no adb.
fn adb_phone_step(view : Json?, phone : Json?, focus : String) -> (AdbStep, String)? {
  let live = items(view, "grants").filter(fn(g) { text(Some(g), "status") == "granted" })
  if live.is_empty() || !flag(phone, "supported") {
    return None
  }
  match adb_next(None, phone, false) {
    Some(step) => Some((step, ""))
    None => {
      for l in adb_lent(view, focus) {
        match adb_next(l.1, phone, true) {
          Some(step) => return Some((step, l.0))
          None => ()
        }
      }
      None
    }
  }
}

///|
/// 共享调试's blocks by their keys: the step alone off the person's own lock ("lock"); else the phone's switch where it
/// lends ("switch"), its step ("phone-step"), an Android before 11 ("unsupported"), the grants from before signatures
/// ("confirm"), the chats it is lent to now ("live-heading", "live").
fn adb_keys(view : Json?, phone : Json?, sub : String) -> Array[String] {
  if personal_lock_step(view, sub) is Some(_) {
    return ["lock"]
  }
  let out : Array[String] = []
  if flag(phone, "supported") {
    out.push("switch")
  }
  // (its step's block there while the phone lends, the step in it coming and going in place, closed as it is done)
  if flag(phone, "supported") {
    out.push("phone-step")
  }
  // an Android before 11 (its host says so); a host with no adb at all (a computer's) has no phone to say it of
  if phone is Some(_) && !flag(phone, "supported") && !flag(phone, "none") {
    out.push("unsupported")
  }
  if count(view, "toConfirm") > 0 {
    out.push("confirm")
  }
  out + ["live-heading", "live"]
}

///|
/// 共享调试's block `k` (adb_keys') in `b`, as the core's `adbShare` (`view`) and the phone's host (`phone`) say it now.
fn adb_block(
  b : @view.View,
  core : Core,
  view : () -> Json?,
  phone : () -> Json?,
  focus : String,
  sub : () -> String,
  k : String,
) -> Unit {
  match k {
    "lock" => personal_lock_node(b, core, fn() { personal_lock_step(view(), sub()) })
    "switch" =>
      @sf.group_node(b, fn(g) {
        // (the library's switch row, as every setting's; 2026-11-06 左子健: 共享调试的标题为啥没有加粗)
        @sf.switch_row_node(g, fn() { tr("android-misc.adb.title") }, fn() { flag(view(), "on") }, fn(on) { adb_turn(core, on) }, note=fn() {
          tr("android-misc.adb.on.note")
        })
      })
    "phone-step" => {
      // (what else the phone lacks after the first, in view with it; which station where it is lent to more than one)
      let note_of = fn(s : AdbStep, at : String) {
        let p = phone()
        let lines : Array[String] = []
        if at != "" && adb_lent(view(), focus).length() > 1 {
          lines.push(adb_station_name(core, at))
        }
        if s.sub != "" {
          lines.push(s.sub)
        }
        if !flag(p, "developer") && !flag(p, "wifi") {
          lines.push(tr("android-misc.adb.wifi") + " " + tr("android-misc.adb.wifi.off"))
        }
        if (!flag(p, "developer") || !flag(p, "wifi")) && !flag(p, "wireless") {
          lines.push(tr("android-misc.adb.wireless") + " " + tr("android-misc.adb.offValue"))
        }
        lines.join("  ·  ")
      }
      // (the step, its station and what is said under it, as they are now; as they were last while it goes, its key
      // gone: what it says kept as it closes)
      let last : Ref[(AdbStep, String, String)?] = Ref(None)
      let now = fn() {
        match adb_phone_step(view(), phone(), focus) {
          Some((s, at)) => {
            last.val = Some((s, at, note_of(s, at)))
            last.val
          }
          None => last.val
        }
      }
      let step = fn() { now().map(fn(s) { s.0 }) }
      let note = fn() { now().map(fn(s) { s.2 }).unwrap_or("") }
      let acts = fn() { step().map(fn(s) { s.act != "" }).unwrap_or(false) }
      b.show(fn() { adb_phone_step(view(), phone(), focus) is Some(_) }, fn(b) {
        @sf.page_card_node(b, footed=true, fn(k) {
          // (its title's line and what is said under it one block, line under line, as card_lines_node's)
          k.box(fn(t) {
          t.min_width(Is(Some(0.0))).gap(Is(adb_step_lines_gap)) |> ignore
          t.box(fn(head) {
            @sf.style_node(head, fn() { adb_step_head })
            // (its pill after its title, as card_lines' `title_after` has it: not off in the card's corner)
            head.box(fn(w) {
              w.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
              @sf.words_node(w, fn() { step().map(fn(s) { s.title }).unwrap_or("") }, fn() { adb_step_title }) |> ignore
            })
            |> ignore
            // (on its title's line)
            @sf.first_line_node(head, Ui, leading=L6, fn(l) { @sf.pill_node(l, fn() { tr("web-main.attention.entry") }, tone=Amber) |> ignore }) |> ignore
          })
          |> ignore
          t.show(fn() { note() != "" }, fn(n) { @sf.words_node(n, note, fn() { adb_step_note }) |> ignore })
          })
          |> ignore
          k.show(acts, fn(f) {
            @sf.card_foot_node(f, fn(foot) {
              // (the call it makes under way: pairing with the code typed)
              let busy = fn() {
                match step() {
                  Some(s) => s.doing != "" && is_doing(core, [s.doing], [])
                  None => false
                }
              }
              @sf.button_node(
                foot,
                fn() { step().map(fn(s) { s.go }).unwrap_or("") },
                fn() {
                  match @signals.untracked(now) {
                    Some((s, at, _)) => adb_do(core, s.act, station=at)
                    None => ()
                  }
                },
                tone=Primary,
                busy~,
                disabled=busy,
                card_words=true,
              )
              |> ignore
            })
          })
        })
      })
    }
    "unsupported" =>
      @sf.group_node(b, fn(g) { @sf.link_row_node(g, fn() { tr("android-misc.adb.unsupported") }, fn() {  }, goes=false) })
    // the grants from before signatures, one tap (and the person asked once) from lending again
    "confirm" =>
      @sf.page_card_node(b, footed=true, fn(k) {
        @sf.card_lines_node(k, fn() { fill("android-misc.personal.toConfirm", [("n", count(view(), "toConfirm").to_string())]) }, note=fn() {
          tr("android-misc.personal.toConfirm.note")
        })
        @sf.card_foot_node(k, fn(f) {
          let doing = fn() { is_doing(core, ["adb.personalConfirm"], []) }
          @sf.button_node(
            f,
            fn() { tr("android-misc.personal.confirm") },
            fn() { act(core, tr("android-misc.personal.confirm"), "adb.personalConfirm", obj([])) },
            tone=Primary,
            busy=doing,
            disabled=doing,
            card_words=true,
          )
          |> ignore
        })
      })
    "live-heading" => @sf.section_heading_node(b, fn() { tr("android-misc.adb.chats.live") })
    "live" => adb_live_node(b, core, view, phone)
    _ => ()
  }
}

///|
/// The chats the phone is lent to now (`view`'s grants granted), on a card in `b`, each taken back here (收回), going
/// to its chat; none, said so (off a phone: the person's phone, not this device).
fn adb_live_node(b : @view.View, core : Core, view : () -> Json?, phone : () -> Json?) -> Unit {
  let live = fn() { items(view(), "grants").filter(fn(g) { text(Some(g), "status") == "granted" }) }
  @sf.group_node(b, fn(g) {
    g.show(fn() { live().is_empty() }, fn(n) {
      @sf.link_row_node(n, fn() { tr(if flag(phone(), "none") { "android-misc.adb.chats.noneYours" } else { "android-misc.adb.chats.none" }) }, fn() {  }, goes=false)
    })
    // (by id once: each grant's row reads its own grant, told only as that one changes)
    let by_id = g.keyed_by(live, fn(x) { text(Some(x), "id") })
    g.each(fn() { by_id.keys() }, fn(id) { id }, fn(row, id) {
      let request = id.untracked()
      let gv = fn() { by_id.get(request) }
      let station = fn() { text(gv(), "station") }
      let session = fn() { text(gv(), "session") }
      // (on the phone itself: granted, and not signed by a device on the person's own lock: it lends nothing on it)
      let when = fn() {
        let ago = stamp(gv(), "lastUsedAt", "ago")
        if flag(phone(), "supported") && field(gv(), "held") == Some(Json::boolean(false)) {
          tr("android-misc.personal.toConfirm.row")
        } else if ago == "" {
          tr("android-misc.adb.chats.noUsage")
        } else {
          ago
        }
      }
      let busy = fn() { is_doing(core, ["adb.revoke"], [("request", request)]) }
      // (收回 by its title alone, the line under it as wide as the row: 2026-11-06 左子健: 不要 title 和 description
      // 都被右边操作给挤压)
      @sf.link_row_node(
        row,
        fn() {
          match text(gv(), "chatTitle") {
            "" => @sf.t("android-chat.new.title")
            t => t
          }
        },
        fn() { (core.open_chat)(@signals.untracked(station), @signals.untracked(session), "") },
        note=fn() { if text(gv(), "reason") == "" { when() } else { when() + " · " + text(gv(), "reason") } },
        note_cut=true,
        // (as wide as its words: clear of 收回 over it at the row's end)
        note_own_width=true,

        goes=@signals.untracked(fn() { station() != "" && session() != "" }),
        // (its words where the row's value would end; on the card's first row, its ground concentric with the card's
        // corner: row_corner_button_node)
        control=fn(c) {
          let words = fn() { tr("android-misc.adb.chats.revoke") }
          let revoke = fn() {
            act(core, tr("android-misc.adb.chats.revoke"), "adb.revoke", obj([("station", str(@signals.untracked(station))), ("request", str(request))]))
          }
          c.pick(fn() { live().get(0).map(fn(x) { text(Some(x), "id") }) == Some(request) }, fn(p, first) {
            if first {
              @sf.row_corner_button_node(p, words, revoke, busy~, disabled=busy) |> ignore
            } else {
              @sf.row_end_button_node(p, words, revoke, busy~, disabled=busy) |> ignore
            }
          })
        },
      )
    })
  })
}

///|
/// 共享调试 while this device is off the person's own lock (`p`, as it is now: adb_lock_first's, as nodes) in `b`: a page
/// of its own, as a device waiting for a workspace's lock has (@sf.waiting_page_node, the shield), with the one step
/// this device takes there: be approved (发送批准请求: a code a trusted device of theirs shows, typed in here), or say
/// whether their trusted devices set up again elsewhere are theirs.
pub fn personal_lock_node(
  b : @view.View,
  core : Core,
  p : () -> Json?,
  outside_note? : () -> String = fn() { tr("android-misc.personal.outside.note") },
  restart_note? : () -> String = fn() { tr("android-misc.personal.restart.note") },
) -> Unit {
  let said = fn() { obj([("sub", str(text(p(), "sub")))]) }
  let doing = fn() { is_doing(core, ["adb.personalOpen", "adb.personalJoin", "adb.personalCode", "adb.personalForget", "adb.personalRestart"], []) }
  let primary = fn(at : @view.View, words : String, call : String) {
    @sf.button_node(at, fn() { words }, fn() { act(core, words, call, @signals.untracked(said)) }, tone=Primary, busy=doing, disabled=doing) |> ignore
  }
  b.pick(fn() { text(p(), "standing") }, fn(w, standing) {
    match standing {
      "outside" => {
        let state = fn() { text(field(p(), "pair"), "state") }
        @sf.waiting_page_node(w, "shield-check", fn() { tr("android-misc.adb.lock.join") }, outside_note, fn(col) {
          col.show(fn() { state() != "" && state() != "done" }, fn(j) { personal_join_node(j, core, p) })
          col.show(fn() { state() == "" || state() == "none" || state() == "failed" || state() == "done" }, fn(s) {
            primary(s, tr("web-pages.security.request"), "adb.personalJoin")
          })
          // (no device of theirs to be found: only then)
          col.show(fn() { state() == "none" || state() == "failed" }, fn(s) {
            @sf.button_node(s, fn() { tr("android-misc.personal.restart") }, fn() {
              act(core, tr("android-misc.personal.restart"), "adb.personalRestart", @signals.untracked(said))
            }, tone=Ghost, disabled=doing)
            |> ignore
            @sf.words_node(s, restart_note, fn() { personal_note_centred })
            .words_centered(Is(true))
            |> ignore
          })
        })
        |> ignore
      }
      "replaced" =>
        @sf.waiting_page_node(w, "shield-check", fn() { tr("android-misc.personal.replaced") }, fn() { tr("android-misc.personal.replaced.note") }, fn(
          col,
        ) {
          primary(col, tr("android-misc.personal.forget"), "adb.personalForget")
        })
        |> ignore
      _ => ()
    }
  })
}

///|
/// Joining the person's own lock `p` (as it is now: personal_join's, as nodes) in `j`, as far as it got: looking for a
/// device on it; where to read the code and the code's boxes (six); what stopped it. Its words in the middle.
fn personal_join_node(j : @view.View, core : Core, p : () -> Json?) -> Unit {
  let pair = fn() { field(p(), "pair") }
  let state = fn() { text(pair(), "state") }
  let note = fn(at : @view.View, words : () -> String) {
    @sf.words_node(at, words, fn() { personal_note_centred }).words_centered(Is(true)) |> ignore
  }
  // (what is typed, emptied for the next try where it is refused)
  let typed = @ui.Field::new()
  j.pick(fn() { if state() is ("code" | "wrong" | "checking") { "code" } else { state() } }, fn(s, at) {
    s.gap(Is(personal_join_gap)) |> ignore
    match at {
      "code" => {
        note(s, fn() {
          if state() == "wrong" {
            text(pair(), "error")
          } else {
            let names = strings(pair(), "showing")
            if names.is_empty() {
              tr("android-misc.personal.code")
            } else {
              fill("android-misc.personal.codeOn", [("device", names.join("、"))])
            }
          }
        })
        @ui.code_field_node(
          s,
          typed,
          fn(code) { (core.call)("adb.personalCode", obj([("code", str(code))]), fn(r) { if r is Err(_) { typed.set("") } }) },
          label=tr("android-misc.personal.code"),
          wrong=fn() { state() == "wrong" },
          enabled=fn() { state() != "checking" },
          inks=fn() {
            let th = @ui.tree_theme()
            { digits: th.color(Fg), off: th.color(Muted), edge: th.color(@sf.code_edge), next: th.color(Fg), wrong: th.color(Danger) }
          },
        )
        |> ignore
        // (the code typed being checked: a turning ring on the first line of what it waits for, as the waiting page
        // says it, where to look once the device showing the code asks its person there; how long the code holds
        // otherwise)
        s.show(fn() { state() == "checking" }, fn(c) {
          @sf.style_node(c, fn() { personal_checking })
          c.box(fn(row) {
            @sf.style_node(row, fn() { personal_checking_row })
            row.box(fn(g) {
              g
              .width(Is(Some(personal_spin)))
              .height(By(fn() { Some(@sf.node_sp(g, @ui.tree_theme().text_size(Meta).1)) }))
              .shrink(Is(0.0))
              .lines_up(Is(Some(Middle)))
              .lies_along(Is(Middle))
              |> ignore
              @sf.spinner_node(g, size=personal_spin) |> ignore
            })
            |> ignore
            row.box(fn(w) {
              w.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
              @sf.words_node(
                w,
                fn() {
                  match text(pair(), "checkingText") {
                    "" => tr("web-pages.security.pairChecking")
                    words => words
                  }
                },
                fn() { personal_checking_words },
              )
              |> ignore
            })
            |> ignore
          })
          |> ignore
        })
        s.show(fn() { state() != "checking" && text(pair(), "untilText") != "" }, fn(u) {
          note(u, fn() { text(pair(), "untilText") })
        })
      }
      "none" => note(s, fn() { tr("android-misc.personal.none.found") })
      "failed" => note(s, fn() { text(pair(), "error") })
      _ => note(s, fn() { tr("android-misc.personal.finding") })
    }
  })
}

///|
/// The step's title and its pill on its first line, 8 apart.
// kept across runs: a value (no field of it changes)
let adb_step_head : @ui.Style = @ui.css("row w=Full gap=S2 align=AStart")

///|
/// The code's words, its boxes and how long it holds, 12 apart.
let personal_join_gap : Double = 12.0

///|
/// The code being checked (personal_join_node): its line in the middle under the boxes, as wide as its words, the
/// ring 8 before them on their first line.
// kept across runs: a value (no field of it changes)
let personal_checking : @ui.Style = @ui.css("w=Full align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let personal_checking_row : @ui.Style = @ui.css("row gap=S2 align=AStart")

///|
// kept across runs: a value (no field of it changes)
let personal_checking_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted)

///|
let personal_spin : Double = 12.0

///|
/// The step's title (a card's line's: 13 on 24, 600) and what is said under it (12 on 24, muted), as card_lines_node's.
// kept across runs: a value (no field of it changes)
let adb_step_title : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, weight=Semibold, color=Fg, w=Full)

///|
// kept across runs: a value (no field of it changes)
let adb_step_note : @ui.TextStyle = @ui.text_style(size=Meta, leading=L6, color=Muted, w=Full)

///|
/// The step's title and what is said under it 2 apart (card_lines_node's).
let adb_step_lines_gap : Double = 2.0
