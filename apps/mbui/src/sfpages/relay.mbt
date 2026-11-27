// A chat relayed to a channel (web/src/Relay.tsx useRelay, RelayDialog, and the phone's RelaySheet in
// mobile/Chat.tsx; Relay.css.ts), one on every screen: from a chat's row's menu, its title bar's panel or its info, the
// picking opens through the presenters (a dialog with 取消 and 接力 at its foot, a sheet from the foot with touch
// short of Large). It offers the channels and groups of every one of the station's connects' bots, each once (public
// channels none is in where one may join them), those relayed to before first, found by typing; one picked, who replies
// there under it (the chat's own bot where it is in it), 换一个 showing the bots of its workspace and where each stands
// (pengxiao, 2026-11-16: the place first, the bot a step after it); with a note if wanted, 接力 has the station start
// the conversation there (its bot joining it first where it is to) and the chat's agent go on in it too, and the panel goes with a
// toast saying where. A Slack message's link typed (pasted) into the search offers that message's thread instead. What
// it offers, and in what order, is the core's (sfbase relay.mbt, relay-pick.ts), asked as what it is asked by changes
// (relay_asks_node). The search has the keys as it opens where the keyboard is at hand (in a dialog, not on a sheet,
// where that would bring the keyboard up over the list: useRelay's `focus`; panel_search_at_hand_node); a place picked
// gives them to the note, let go of back to the search. An `@` typed in the note offers the people there under it
// (@sf.offers_node, as the composer's `@` menu): ↑ / ↓ choose, Enter or Tab put the one chosen in (its name in place of
// what was typed), Escape closes it for that `@`. Made once as nodes of the window's tree (panel_nodes); what it shows
// kept as it was while it goes (relayed: what it showed is let go of as it closes).

///|
/// The field to be given the keys as it is next made ("note" once a place is picked, "search" once it is let go of),
/// "" none: said by the press that causes it, taken by the field as it is made then, once.
// kept across runs: put back by the package's reset
let relay_focus : Ref[String] = Ref("")

///|
/// As at the start (the package's reset).
fn relay_focus_reset() -> Unit {
  relay_focus.val = ""
}

///|
/// Relays chat `thread` of `r`'s station: its places asked for (sfbase relay.mbt), the picking presented from `from`.
pub fn open_relay(src : Source, r : ChatRef, thread : Double, from~ : @sf.Anchor) -> Unit {
  relay_open(src, r.station, thread)
  relay_focus.val = ""
  @sf.panel_nodes(
    @sf.t("web-main.relay.title"),
    fn(v, _) { relay_body(v, src) },
    from~,
    description=@sf.t("web-main.relay.lead"),
    live=fn() { (@sf.t("web-main.relay.title"), "", @sf.t("web-main.relay.lead")) },
    foot=fn(v, close) { relay_foot(v, src, close) },
    gone=fn() {
      if !relaying.busy.get() {
        relay_reset()
      }
    },
  )
}

///|
/// What the picker shows, as one: what the core showed, the place picked, whether its places were read (0 being read,
/// 1 read, 2 not), why not, whether any connect is there.
priv struct RelayShown {
  view : Json?
  picked : Json?
  read : Int
  error : String
  connected : Bool
}

///|
/// What the picker shows now, read in node `v` (its body's or its foot's): as it was while it goes (relayed, what it
/// showed is let go of as it closes; kept as it was till it is gone, not emptied under it).
fn relay_shown(v : @view.View) -> () -> RelayShown {
  let last : Ref[RelayShown?] = Ref(None)
  fn() {
    match (v.leaving(), last.val) {
      (true, Some(was)) => was
      _ => {
        let now : RelayShown = {
          view: relay_view_now(),
          picked: relaying.picked.get(),
          read: relaying.read.get(),
          error: relaying.error.get(),
          connected: relaying.connects.get().length() > 0,
        }
        last.val = Some(now)
        now
      }
    }
  }
}

///|
/// What stands in the list's place while nothing is picked: the thread of a link typed, its places being read, not
/// read, none connected, or the places offered.
#derive(Eq)
priv enum RelayList {
  Thread
  Reading
  Failed
  NoConnects
  Places
}

///|
/// The panel's body in node `v`, made once as it opens: one of two, as a place is picked or not. Picking: the bots to
/// go on through, the search, the places (or what stands in their place), the note under a link's thread; picked: the
/// place (更换 on it), who replies there, the note (12 apart).
fn relay_body(v : @view.View, src : Source) -> Unit {
  relay_asks_node(v, src)
  let shown = relay_shown(v)
  v.box(fn(body) {
    @sf.style_node(body, fn() { relay_column })
    body.pick(fn() { shown().picked is Some(_) }, fn(col, picked) {
      @sf.style_node(col, fn() { relay_column })
      if picked {
        relay_picked(col, src, shown)
      } else {
        relay_picking(col, src, shown)
      }
    })
  })
  |> ignore
}

///|
/// What is shown while no place is picked, in column `col`: the search (also taking a Slack message's link; the keys
/// its as it opens where the keyboard is at hand, and again as what was picked is let go of), the places of every bot
/// or what stands in their place, the note once a link is typed. Which bot replies is a step after the place
/// (relay_picked; pengxiao, 2026-11-16: 「应该频道选择更重要吧」).
fn relay_picking(col : @view.View, src : Source, shown : () -> RelayShown) -> Unit {
  let link = fn() { opt_text(shown().view, "link") }
  let f = @sf.input_node(col, relaying.query, placeholder=@sf.t("web-main.relay.searchOrLink"))
  @sf.panel_search_at_hand_node(f)
  relay_focused(f, "search")
  col.pick(
    fn() {
      let s = shown()
      match opt_text(s.view, "link") {
        Some(_) => Thread
        None =>
          match s.read {
            0 => RelayList::Reading
            2 => RelayList::Failed
            _ if !s.connected => NoConnects
            _ => if s.view is None { RelayList::Reading } else { Places }
          }
      }
    },
    fn(p, k) {
      match k {
        Thread =>
          relay_list(p, fn(l) {
            relay_place(l, fn() { "slack" }, fn() { @sf.t("web-main.relay.thread") }, fn() {
              Some(@sf.t("web-main.relay.kind.thread"))
            }, true, false)
            relay_via(l, src, fn() { text(shown().view, "bot") })
          })
        Reading => @sf.wait_line_node(p, fn() { @sf.t("web-main.relay.reading") }) |> ignore
        Failed => @sf.words_node(p, fn() { shown().error }, fn() { relay_failed }) |> ignore
        NoConnects => relay_said(p, fn() { @sf.t("web-main.relay.noConnects") }, relay_empty)
        Places => relay_places(p, shown)
      }
    },
  )
  col.show(fn() { link() is Some(_) }, fn(s) { relay_note(s, src) })
}

///|
/// What is shown once a place is picked, in column `col`: it (更换 on it: pressed, let go of, the keys back to the
/// search), who replies there under it, and the note.
fn relay_picked(col : @view.View, src : Source, shown : () -> RelayShown) -> Unit {
  let row = fn() { shown().picked }
  relay_list(col, fn(l) {
    relay_place(
      l,
      fn() { text(row(), "kind") },
      fn() { text(row(), "name") },
      fn() { Some(text(row(), "note")) },
      true,
      true,
      on_press=fn() {
        relaying.picked.set(None)
        relaying.choosing.set(false)
        relay_focus.val = "search"
      },
    )
    let via = fn() { field(shown().view, "via") }
    relay_via(
      l,
      src,
      fn() {
        match opt_text(via(), "bot") {
          Some(b) if b != "" => b
          _ => text(row(), "connect")
        }
      },
      joins=fn() { flag(via(), "joins") },
      change=fn() { items(via(), "bots").length() > 1 && !relaying.choosing.get() },
    )
    l.show(fn() { relaying.choosing.get() && items(via(), "bots").length() > 1 }, fn(c) {
      relay_bot_choice(c, src, shown)
    })
  })
  relay_note(col, src)
}

///|
/// Field `f` given the keys as it is made where the press that made it said so (`which`: relay_focus), once.
fn relay_focused(f : @view.View, which : String) -> Unit {
  if relay_focus.val == which {
    relay_focus.val = ""
    f.ask_focus() |> ignore
  }
}

///|
/// The places of every bot as the core offers them, in `p` (list): 最近接力过 over those relayed to before,
/// why none are, 显示全部 under the recent ones, the connects whose places were not read.
fn relay_places(p : @view.View, shown : () -> RelayShown) -> Unit {
  let view = fn() { shown().view }
  let recent = fn() { flag(view(), "recent") }
  relay_list(p, fn(l) {
    l.show(recent, fn(b) {
      @sf.style_node(b, fn() { relay_group_head_box })
      @sf.words_node(b, fn() { @sf.t("web-main.relay.recent") }, fn() { relay_group_head }) |> ignore
    })
    let key = fn(row : Json) { text(Some(row), "connect") + "/" + text(field(Some(row), "place"), "id") }
    l.each(fn() { items(view(), "rows") }, key, fn(cell, row) {
      cell.box(fn(r) {
        relay_place(
          r,
          fn() { text(Some(row.get()), "kind") },
          fn() { text(Some(row.get()), "name") },
          fn() { opt_text(Some(row.get()), "aside") },
          false,
          false,
          on_press=fn() {
            relaying.picked.set(Some(row.untracked()))
            relay_focus.val = "note"
          },
        )
      })
      |> ignore
    })
    l.show(fn() { text(view(), "empty") == "noPlaces" }, fn(e) {
      relay_said(e, fn() { @sf.t("web-main.relay.noPlaces") }, relay_empty)
    })
    l.show(fn() { text(view(), "empty") == "noMatch" }, fn(e) {
      relay_said(e, fn() { @sf.t("web-main.relay.noMatch") }, relay_empty)
    })
    let total = fn() { number(view(), "total").to_int() }
    l.show(fn() { recent() && total() > items(view(), "rows").length() }, fn(m) {
      @sf.text_action_node(
        m,
        fn() { @sf.t("web-main.relay.showAll", args=[("count", total().to_string())]) },
        fn() { relaying.all.set(true) },
        style=fn() { relay_more_words },
        box=fn() { relay_more },
      )
      |> ignore
    })
    l.each(
      fn() {
        let out : Array[String] = []
        for e in items(view(), "unread") {
          match e {
            String(e) => out.push(e)
            _ => ()
          }
        }
        out
      },
      fn(e) { e },
      fn(cell, e) {
        relay_said(cell, fn() { @sf.t("web-main.relay.unread", args=[("error", e.get())]) }, relay_unread)
      },
    )
  })
}

///|
/// Why none, why not read (empty, unread) in `parent`, 4 by 8 in.
fn relay_said(parent : @view.View, words : () -> String, style : @ui.TextStyle) -> Unit {
  parent.box(fn(b) {
    @sf.style_node(b, fn() { relay_note_box })
    @sf.words_node(b, words, fn() { style }) |> ignore
  })
  |> ignore
}

///|
/// The places in `parent`, scrolling within the panel past 300 (list: 2 apart).
fn relay_list(parent : @view.View, body : (@view.View) -> Unit) -> Unit {
  @sf.capped_node(parent, fn() { relay_list_most }, fn(c) {
    c.box(fn(b) {
      @sf.style_node(b, fn() { relay_list_box })
      body(b)
    })
    |> ignore
  })
  |> ignore
}

///|
/// A place to pick in `parent` (place): its platform's mark, its name, what relaying there does at its end (`note`, with
/// 更换 after it where `change`); picked (`on`), on the accent's ground; the hover grey pointed at. `on_press` as it is
/// pressed (none: not pressed).
fn relay_place(
  parent : @view.View,
  kind : () -> String,
  name : () -> String,
  note : () -> String?,
  on : Bool,
  change : Bool,
  on_press? : () -> Unit,
) -> Unit {
  @sf.place_row_node(parent, name, fn(b) { relay_mark(b, kind) }, fn() { on }, press?=on_press, end=fn(b) {
    b.show(fn() { note() is Some(_) }, fn(s) {
      @sf.place_note_node(s, fn() { note().unwrap_or("") }, fn() { on }, change?=if change {
        Some(fn() { @sf.t("web-main.relay.change") })
      } else {
        None
      })
      |> ignore
    })
  })
}

///|
/// A platform's mark (ElsewhereLogo, 16) in `parent`: Feishu's for Feishu and Lark, group's for a group connect, else
/// Slack's.
fn relay_mark(parent : @view.View, kind : () -> String) -> Unit {
  @sf.origin_mark_node(parent, fn() { relay_origin(kind()) }, relay_mark_size)
  |> ignore
}

///|
/// The mark a relay connect's kind is shown by (`@sf.origin_mark_name`'s): Lark is Feishu's.
fn relay_origin(kind : String) -> String {
  match kind {
    "feishu" | "lark" => "feishu"
    "group" => "group"
    _ => "slack"
  }
}

///|
/// A connect's bot as people see it (ConnectAvatar, 16) in `parent`: its picture; its kind's mark (three fifths of it)
/// till that is said.
fn relay_avatar(parent : @view.View, src : Source, conn : () -> Json?) -> Unit {
  let picture = fn() {
    match opt_text(conn(), "botImage") {
      Some(p) if p != "" => Some(p)
      _ => None
    }
  }
  parent.show(fn() { picture() is Some(_) }, at_once=true, fn(a) {
    @sf.avatar_node(a, fn() { text(conn(), "id") }, fn() { text(conn(), "name") }, fn() {
      match picture() {
        Some(p) => (src.picture)(p, 0)
        None => ""
      }
    }, relay_mark_size)
  })
  parent.show(fn() { picture() is None && conn() is Some(_) }, at_once=true, fn(b) {
    @sf.style_node(b, fn() { relay_avatar_box })
    @sf.origin_mark_node(b, fn() { relay_origin(text(conn(), "kind")) }, relay_kind_size)
    |> ignore
  })
}

///|
/// Which bot the agent speaks through there, under the place picked, in `parent` (Via): 「那里由 [picture] Claude 回复」,
/// at its right, its end in line with the place's note's; nothing for a bot not read. `joins`: 接力时加入 after it; `change`: 换一个 after
/// that, which shows the bots to choose another from.
fn relay_via(
  parent : @view.View,
  src : Source,
  bot : () -> String,
  joins? : () -> Bool = fn() { false },
  change? : () -> Bool = fn() { false },
) -> Unit {
  let conn = fn() { relay_connect(bot()) }
  let split = fn() -> Array[String] {
    @sf.t("web-main.relay.via", args=[("bot", "\u{E000}")]).split("\u{E000}").map(fn(w) { w.to_owned() }).collect()
  }
  parent.show(fn() { conn() is Some(_) }, fn(b) {
    @sf.style_node(b, fn() { relay_via_box })
    b.box(fn(g) { @sf.style_node(g, fn() { relay_grow }, in_row=true) }) |> ignore
    b.show(fn() { split()[0] != "" }, at_once=true, fn(w) {
      @sf.words_node(w, fn() { split()[0] }, fn() { relay_via_words }) |> ignore
    })
    b.box(fn(v) {
      @sf.style_node(v, fn() { relay_via_bot })
      relay_avatar(v, src, conn)
      @sf.words_node(v, fn() { text(conn(), "name") }, fn() { relay_via_name }) |> ignore
    })
    |> ignore
    b.show(fn() { split().length() > 1 && split()[1] != "" }, at_once=true, fn(w) {
      @sf.words_node(w, fn() { split()[1] }, fn() { relay_via_words }) |> ignore
    })
    // (接力时加入, where the bot is to join it as it relays)
    b.show(joins, at_once=true, fn(w) {
      @sf.words_node(w, fn() { " · " + @sf.t("web-main.relay.bot.join") }, fn() { relay_via_words }) |> ignore
    })
    // (换一个, where the place has other bots of its workspace: the bots shown under it to choose from)
    b.show(change, at_once=true, fn(w) {
      w.row(Is(true)).lines_up(Is(Some(Middle))) |> ignore
      @sf.words_node(w, fn() { " · " }, fn() { relay_via_words }) |> ignore
      @sf.text_action_node(
        w,
        fn() { @sf.t("web-main.relay.changeBot") },
        fn() { relaying.choosing.set(true) },
        style=fn() { relay_more_words },
        box=fn() { relay_via_change },
      )
      |> ignore
    })
  })
}

///|
/// The bots of the place picked's workspace to choose the one replying there from, in `parent` (the core's `via`
/// `bots`): under 由哪个机器人回复, each its picture, its name and where it stands at its end (在频道里, 接力时加入, 未加入,
/// 需要频道里的人邀请 with 复制邀请 after it); the one replying on the accent's ground; one in it or to join it pressed,
/// it replies there, the choice closed; one that cannot be pressed.
fn relay_bot_choice(parent : @view.View, src : Source, shown : () -> RelayShown) -> Unit {
  let via = fn() { field(shown().view, "via") }
  parent.box(fn(b) {
    @sf.style_node(b, fn() { relay_bots_box })
    b.box(fn(h) {
      @sf.style_node(h, fn() { relay_group_head_box })
      @sf.words_node(h, fn() { @sf.t("web-main.relay.bots") }, fn() { relay_group_head }) |> ignore
    })
    |> ignore
    // (the bots by id once, and the one replying by member: each row reads its own, told only as it changes or comes to
    // reply or stops)
    let by_id = b.keyed_by(fn() { items(via(), "bots") }, fn(x) { text(Some(x), "id") })
    let on_is = b.selected(fn() { Some(text(via(), "bot")) })
    b.each(fn() { by_id.keys() }, fn(id) { id }, fn(cell, id) {
      let id = id.untracked()
      let bot = fn() { by_id.get(id) }
      let state = fn() { text(bot(), "state") }
      let on = fn() { on_is(id) }
      let can = fn() { state() == "in" || state() == "join" }
      @sf.place_row_node(
        cell,
        fn() { text(bot(), "label") },
        fn(r) { relay_avatar(r, src, fn() { relay_connect(id) }) },
        on,
        can~,
        selected=on,
        press=fn() {
          if can() {
            relaying.bot.set(id)
            relaying.choosing.set(false)
          }
        },
        end=fn(r) {
          @sf.words_node(r, fn() { @sf.t("web-main.relay.bot." + state()) }, fn() { @sf.place_note_look(on()) }) |> ignore
          r.show(fn() { opt_text(bot(), "invite") is Some(_) }, at_once=true, fn(w) {
            @sf.text_action_node(
              w,
              fn() { @sf.t("web-main.relay.copyInvite") },
              fn() {
                let place = match shown().picked {
                  Some(row) => text(Some(row), "name")
                  None => ""
                }
                @sfbase.copy_out(text(bot(), "invite"), said=@sf.t("web-main.relay.inviteCopied", args=[("place", place)]))
              },
              style=fn() { relay_more_words },
              box=fn() { relay_via_change },
            )
            |> ignore
          })
        },
      )
    })
  })
  |> ignore
}

///|
/// The note in `parent` (noteField: its label over its field, 6 apart), the keys its as it is made where a place was
/// just picked; whom it can mention offered under it, as wide, while it has the keys and an `@` in it finds some
/// (@sf.offers_node): the one chosen put in for that `@` (its name in place of it and what was typed after it).
fn relay_note(parent : @view.View, src : Source) -> Unit {
  parent.box(fn(b) {
    @sf.style_node(b, fn() { relay_note_field })
    @sf.words_node(b, fn() { @sf.t("web-main.relay.note") }, fn() { relay_note_label }) |> ignore
    let f = @sf.input_node(b, relaying.note, placeholder=@sf.t("web-main.relay.notePlaceholder"))
    relay_focused(f, "note")
    // the `@` the people shown are for as they were last shown: where it starts, the note up to and with it then, and
    // what was after the caret then (the range the choice is for ends where that begins)
    let then : Ref[(Int, String, String)] = Ref((-1, "", ""))
    b.reacts(
      fn() {
        let at = number(relaying.mentions.get(), "at").to_int()
        (at, relaying.note.text(), relaying.note.selection().1)
      },
      fn(x) {
        let (at, t, k) = x
        let before = if at >= 0 && at < t.length() { t.clamped_view(end=at + 1).to_owned() } else { "" }
        let after = if k >= 0 && k <= t.length() { t.clamped_view(start=k).to_owned() } else { "" }
        then.val = (at, before, after)
      },
    )
    // whether what is shown is still this `@`'s: not closed nor chosen for it since, the note still holding it as it
    // was where it was, the caret where what was after it then begins (what was typed after it since the `@`'s)
    let offered = fn() {
      let (at, before, after) = then.val
      relaying.mention_closed.get() != at && relay_still_at(at, before, after)
    }
    let people = fn() { relay_mentions_now() }
    @sf.offers_node(
      b,
      f.parent().unwrap_or(f),
      fn() { f.focused() && people().length() > 0 },
      fn() { people().map(fn(p) { text(Some(p), "id") }) },
      relaying.mention_active,
      fn(r, id, _) { relay_person(r, src, id, people) },
      fn(id) {
        match @signals.untracked(people).iter().find_first(fn(p) { text(Some(p), "id") == id }) {
          Some(p) => text(Some(p), "name")
          None => ""
        }
      },
      fn(i) {
        // the one chosen put in for this `@`, while it is offered (a press's and a key's alike): it and what follows it
        // to the caret made `@name `, what is before it and after the caret as it is; this `@` done with then
        guard offered() else { return }
        guard @signals.untracked(people).get(i) is Some(p) else { return }
        let (at, _, _) = then.val
        let now = relaying.note.text()
        let caret = relaying.note.selection().1
        let name = text(Some(p), "name")
        relaying.note.set(
          now.clamped_view(end=at).to_owned() + "@" + name + " " + now.clamped_view(start=caret).to_owned(),
          caret=at + name.length() + 2,
        )
        relaying.mention_closed.set(at)
      },
      fn() { relay_mentions_close() },
      @sf.t("web-main.relay.people"),
      head=fn() { (@sf.t("web-main.relay.people"), relay_mention_query()) },
    )
  })
  |> ignore
}

///|
/// Whether the note still holds the `@` at `at` the people shown were for: what is before it and it as they were then
/// (`before`), what was after the caret then as it was (`after`), the caret where that begins, nothing picked: the range
/// the choice is for, grown by what was typed in it since, not what the core makes of the words in it.
fn relay_still_at(at : Int, before : String, after : String) -> Bool {
  let now = relaying.note.text()
  let (a, caret) = relaying.note.selection()
  at >= 0 &&
  before != "" &&
  a == caret &&
  caret > at &&
  now.length() >= before.length() + after.length() &&
  caret == now.length() - after.length() &&
  now.has_prefix(before) &&
  now.has_suffix(after)
}

///|
/// A person the note can mention, in row `r` (the composer's `@` menu's row: ref_item): their picture, their name, their
/// full name at its end where it says more.
fn relay_person(r : @view.View, src : Source, id : String, people : () -> Array[Json]) -> Unit {
  let p = fn() -> Json? {
    let ps = people()
    for i = 0; i < ps.length(); i = i + 1 {
      if text(Some(ps[i]), "id") == id {
        return Some(ps[i])
      }
    }
    None
  }
  let name = fn() { text(p(), "name") }
  r.box(fn(l) {
    @sf.style_node(l, fn() { ref_logo })
    @sf.avatar_node(l, fn() { id }, name, fn() {
      let picture = text(p(), "picture")
      if picture == "" {
        ""
      } else {
        (src.picture)(picture, 0)
      }
    }, relay_person_size)
  })
  |> ignore
  r.box(fn(c) {
    @sf.style_node(c, fn() { ref_title_cell }, in_row=true)
    @sf.words_node(c, name, fn() { ref_title }) |> ignore
  })
  |> ignore
  r.show(fn() { opt_text(p(), "aka") is Some(_) }, at_once=true, fn(a) {
    @sf.words_node(a, fn() { opt_text(p(), "aka").unwrap_or("") }, fn() { ref_time }) |> ignore
  })
}

///|
/// The panel's foot in node `v`: 取消, and 接力 (to the place picked: 接力到 #dev), not to be pressed till a place is
/// picked or a link typed, waiting while the station relays it.
fn relay_foot(v : @view.View, src : Source, close : () -> Unit) -> Unit {
  let shown = relay_shown(v)
  @sf.button_node(v, fn() { @sf.t("common.cancel") }, fn() { close() }, tone=Ghost) |> ignore
  @sf.button_node(
    v,
    fn() {
      match shown().picked {
        Some(row) => @sf.t("web-main.relay.goTo", args=[("place", text(Some(row), "name"))])
        None => @sf.t("web-main.relay.go")
      }
    },
    fn() { relay_go(src, relay_view_now(), done=close) },
    tone=Primary,
    busy=fn() { relaying.busy.get() },
    disabled=fn() {
      let s = shown()
      !(s.picked is Some(_) || opt_text(s.view, "link") is Some(_))
    },
  )
  |> ignore
}

///|
/// The places' most before they scroll (list: maxHeight 300); a mark and a bot's picture (16), its kind's mark in it
/// (three fifths: ConnectKindIcon).
let relay_list_most : Double = 300.0

///|
let relay_mark_size : Double = 16.0

///|
let relay_kind_size : Double = 10.0

///|
/// A person's picture (a menu row's mark).
let relay_person_size : Double = 16.0

///|
/// One column, 12 apart (body).
// kept across runs: a value (no field of it changes)
let relay_column : @ui.Style = @ui.css("w=Full gap=S3")

///|
/// The places, 2 apart (list).
// kept across runs: a value (no field of it changes)
let relay_list_box : @ui.Style = @ui.css("w=Full gap=SPx")

///|
/// 最近接力过 (groupHead: 2 by 8 in, the meta's size, muted).
// kept across runs: a value (no field of it changes)
let relay_group_head_box : @ui.Style = @ui.css("px=S2 py=S0_5")

///|
// kept across runs: a value (no field of it changes)
let relay_group_head : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, w=Full)

///|
// kept across runs: a value (no field of it changes)
let relay_grow : @ui.Style = @ui.style(w=@sf.grow)

///|
/// 显示全部 (more: 4 by 8 in, the accent's text, the meta's size).
// kept across runs: a value (no field of it changes)
let relay_more : @ui.Style = @ui.css("px=S2 py=S1")

///|
// kept across runs: a value (no field of it changes)
let relay_more_words : @ui.TextStyle = @ui.text_style(size=Meta, color=AccentText, wrap=false)

///|
/// Why none, why not read (empty, unread: 4 by 8 in, the meta's size, muted or red); why the places were not read at
/// all (fieldError).
// kept across runs: a value (no field of it changes)
let relay_note_box : @ui.Style = @ui.css("w=Full px=S2 py=S1")

///|
// kept across runs: a value (no field of it changes)
let relay_empty : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, w=Full)

///|
// kept across runs: a value (no field of it changes)
let relay_unread : @ui.TextStyle = @ui.text_style(size=Meta, color=Danger, w=Full)

///|
// kept across runs: a value (no field of it changes)
let relay_failed : @ui.TextStyle = @ui.text_style(size=Meta, color=Danger, w=Full)

///|
/// The note (noteField: its label over its field, 6 apart; noteLabel: the meta's size, muted).
// kept across runs: a value (no field of it changes)
let relay_note_field : @ui.Style = @ui.css("w=Full gap=S1_5")

///|
// kept across runs: a value (no field of it changes)
let relay_note_label : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
/// Via: under the place picked, at its right (2 down, its end the row's 10 in, as the place's note's), the meta's
/// size, muted; the bot (viaBot) its picture 4 before its name, in the text's colour.
// kept across runs: a value (no field of it changes)
let relay_via_box : @ui.Style = @ui.css("row w=Full pt=S0_5 px=S2_5 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let relay_via_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
/// 换一个 and 复制邀请: pressed as a link is, in the accent's text; their end the line's, in line with the place's note's.
// kept across runs: a value (no field of it changes)
let relay_via_change : @ui.Style = @ui.css("pl=S1")

///|
/// The bots to choose from under the place picked: 6 under its via line, 2 apart.
// kept across runs: a value (no field of it changes)
let relay_bots_box : @ui.Style = @ui.css("w=Full pt=S1_5 gap=SPx")

///|
// kept across runs: a value (no field of it changes)
let relay_via_bot : @ui.Style = @ui.css("row gap=S1 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let relay_via_name : @ui.TextStyle = @ui.text_style(size=Meta, color=Fg, wrap=false)

///|
/// A bot's kind's mark where it has no picture: on a 16 square.
// kept across runs: a value (no field of it changes)
let relay_avatar_box : @ui.Style = @ui.css("w=S4 h=S4 align=ACenter justify=JCenter")
