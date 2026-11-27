// What a chat's info says on 中屏 and 大屏 (ChatInfoBody; chat_page.mbt's chat_info till 2026-11-12) as nodes of the
// window's tree, made once as the panel the bar's 对话信息 presents opens (chat_pops_node), each part bound to what it
// is made of: what it is (where it came from if not here, who started it, who else takes part, when it was made and last
// written in), who works in it (its agents), the chats its agents made, what is in it (its pull requests, what else was
// said, the stations' files beside it, what its agents and other chats' wrote each other). Laid out as the old view's
// was, by the same styles. Each part there while it has something to say, each fact and row of it while it does, its
// words bound to what they say and its lists' rows by their keys: what changes in the chat changes only what says it.
// Pressed, a row does what it opens and the panel closes (`done`).

///|
/// Chat `r`'s info in `v` (the presented panel's body): its view as it is now (`view`), its pictures asked for on the
/// page's time (`stint`); `done` closes it.
fn chat_info_node(v : @view.View, src : Source, r : ChatRef, view : () -> ChatView?, stint : () -> Int, done : () -> Unit) -> Unit {
  // (the chat's head alone: sfbase's chat_head_json, told as it changes, not as a word comes into a message)
  let chat = fn() { @sfbase.chat_head_json(src, r) }
  let tips = match @sf.panel_tips_of(v) {
    Some(t) => t
    None => @sf.TipLayer::new(fn() { None })
  }
  // (what each part is made of worked out once for each change of the chat's head or its view, told on only as it
  // changes: a word come into a message runs none of what shows them)
  let facts = @signals.computed(fn(_) { info_facts_said(chat(), view()) })
  v.show(fn() { facts.get().known }, fn(f) { info_facts_node(f, src, fn() { facts.get() }, tips, stint, done) })
  @sfpages.chat_info_projects_section_node(v, src, r, view, in_sheet=false)
  let agents = fn() { items(chat(), "agents") }
  v.show(fn() { agents().length() > 0 }, fn(a) { info_agents_node(a, agents) })
  let opened = @signals.computed(fn(_) {
    match view() {
      Some(cv) if cv.opened.length() > 0 => Some(cv.opened_text)
      _ => None
    }
  })
  v.show(fn() { opened.get() is Some(_) }, fn(g) {
    @sf.style_node(g, fn() { info_tools(false) })
    info_row_node(
      g,
      "spawned",
      fn() { opened.get().unwrap_or("") },
      fn() { "" },
      fn() {
        done()
        side_tab_open(src, r, "subchats")
      },
    )
  })
  // (what is in it as every screen's info reads it: sfpages' chat_holds_said; beside the system's tabs, its rows fewer)
  let things = @signals.computed(fn(_) { (@sfpages.chat_holds_said(src, r, chat()), @sf.native_on()) })
  let jobs_summary = fn() { src.topic("chatJobs", chat_jobs_summary_params(r)).get().value }
  let bg_count = fn() { @sfbase.chat_jobs_background_count(jobs_summary()) }
  v.show(fn() { things.get().0.any() || bg_count() > 0 }, fn(g) {
    info_things_node(g, src, r, fn() { things.get() }, bg_count, done)
  })
}

///|
/// What the info's facts are made of (info_facts_node's): whether the chat's view is read, where it came from (its
/// place, and through what: sfpages' chat_through), its thread, who opened it, its people, and whether the system's
/// bars are on.
#derive(Eq)
priv struct InfoFacts {
  known : Bool
  place : String
  through : @sfpages.ChatThrough?
  thread : Json?
  opener : @sfbase.Opener?
  people : Array[Person]
  native : Bool
}

///|
/// The info's facts (info_facts_node's) as the chat's head `chat` and its view `view` say them.
fn info_facts_said(chat : Json?, view : ChatView?) -> InfoFacts {
  let thread = field(chat, "thread")
  let (opener, people) = match view {
    Some(cv) => (cv.opener, cv.people)
    None => (None, [])
  }
  {
    known: view is Some(_),
    place: text(chat, "place"),
    through: @sfpages.chat_through(chat),
    thread,
    opener,
    people,
    native: @sf.native_on(),
  }
}

///|
/// The info's facts in `f` (chat_info's first group), as `facts` says them now: in a column of their labels, as wide
/// as the widest in this language, 80 at least, each its words after it; each fact there while it says something.
fn info_facts_node(
  f : @view.View,
  src : Source,
  facts : () -> InfoFacts,
  tips : @sf.TipLayer,
  stint : () -> Int,
  done : () -> Unit,
) -> Unit {
  let thread = fn() { facts().thread }
  let labels = ["from", "started", "people", "created", "lastMessage"].map(fn(k) { @sf.t("web-pages.chat.info." + k) })
  // (a Comma Task's: in no place, Comma alone, as the old view's chat_info said it)
  let comma = fn() { facts().through is Some(@sfpages.ChatThrough::Comma) }
  let in_thread = fn() { opt_number(thread(), "id") is Some(_) }
  let creator = fn() { @sfpages.chat_creator_said(thread()) }
  // (its first fact's words as far under the panel's top as a menu's first item's: the fact's row taller than its
  // line, centred in it; its labels in a column 80 wide, or as wide as the widest of them in this language)
  let over = fn() {
    let diff : Double = @sf.fact_row_h - @sf.theme().t.ui_line
    @sf.menu_row_over - diff / 2.0
  }
  @sf.facts_list_node(f, labels, least=info_label_w, style=fn() { info_facts.then(@ui.style(pt=@sf.room_of(over()))) }, fn(list) {
    // (a fact while `when` holds: its label, then its words)
    let fact = fn(when : () -> Bool, label : String, value : (@view.View) -> Unit) {
      @sf.fact_row_node(list, label, value, show=when)
    }
    // where it came from, only when that is not here (a still.fail chat's says nothing)
    fact(fn() { facts().through is Some(_) }, labels[0], fn(row) {
      row.box(fn(i) {
        @sf.style_node(i, fn() { info_inline }, in_row=true)
        i.pick(at_once=true, fn() { if comma() { 0 } else if facts().through is Some(@sfpages.ChatThrough::Feishu) { 1 } else { 2 } }, fn(m, through) {
          match through {
            0 => @sf.drawable_node(m, @sf.origin_mark_name("comma"), 13.0, tint=fn() { Some(@sf.theme().p.text) }) |> ignore
            1 => @sf.drawable_node(m, "feishu", 13.0) |> ignore
            _ => @sf.drawable_node(m, "slack", 13.0) |> ignore
          }
        })
        @sf.words_node(i, fn() {
          let through = if comma() { "Comma" } else if facts().through is Some(@sfpages.ChatThrough::Feishu) { @sf.t("web-pages.connect.feishu.name") } else { "Slack" }
          match facts().place {
            "" => through
            place => through + " · " + place
          }
        }, fn() { info_words })
        |> ignore
      })
      |> ignore
    })
    // who started it: made by another chat's agent, that chat; else its creator, or that it is not known
    fact(in_thread, labels[1], fn(row) {
      row.pick(at_once=true, fn() { if facts().opener is Some(_) { 0 } else if creator() == "" { 1 } else { 2 } }, fn(s, by) {
        match by {
          // that chat, its mark before its title (已归档 after one in the archive); pressed, it opens
          0 => {
            // (what it says of that chat, as it says it now)
            let of = fn(said : (@sfbase.Opener) -> String) {
              match facts().opener {
                Some(o) => said(o)
                None => ""
              }
            }
            s.box(fn(b) {
              @sf.style_node(b, fn() { info_inline }, in_row=true)
              b.says(By(fn() { Some(@view.said(Link, label=of(fn(o) { o.text }))) })) |> ignore
              @sf.presses_node(b, fn() {
                done()
                match @signals.untracked(fn() { facts().opener }) {
                  Some(o) => open_page(Chat(o.chat))
                  None => ()
                }
              })
              @sf.icon_node(b, "spawned", 14.0, By(fn() { if @sf.lit_node(b) { @sf.theme().p.text } else { @sf.theme().p.muted } })) |> ignore
              @sf.words_node(b, fn() { of(fn(o) { o.chat.title }) }, fn() { if @sf.lit_node(b) { info_words_hot } else { info_words } })
              |> ignore
              b.show(at_once=true, fn() { facts().opener is Some({ archived: true, .. }) }, fn(n) {
                @sf.words_node(n, fn() { of(fn(o) { o.note }) }, fn() { info_quiet }) |> ignore
              })
              @sf.tip_node(tips, b, fn() { of(fn(o) { o.text }) }, repeats=true) |> ignore
            })
            |> ignore
          }
          1 => @sf.words_node(s, fn() { @sf.t("web-pages.chat.info.unknown") }, fn() { info_muted }) |> ignore
          // their face before their name, as the people's are
          _ =>
            s.box(fn(i) {
              @sf.style_node(i, fn() { info_inline }, in_row=true)
              i.pick(at_once=true, fn() { field(thread(), "creator") }, fn(face, p) {
                match p {
                  Some(Object(_) as p) => wide_people(face, src, [@sfbase.person_of(p)], 1, tips, stint)
                  _ => ()
                }
              })
              @sf.words_node(i, creator, fn() { info_words }) |> ignore
            })
            |> ignore
        }
      })
    })
    // who takes part, only when that is more than who started it
    let only_starter = fn() {
      let people = facts().people
      let creator_id = text(field(thread(), "creator"), "id")
      people.length() == 0 || (people.length() == 1 && creator_id != "" && people[0].id == creator_id)
    }
    fact(fn() { in_thread() && !only_starter() }, labels[2], fn(row) {
      row.pick(at_once=true, fn() { facts().native }, fn(s, native) {
        // (beside the system's tabs, no pointer to rest on them for their names: each its face and its name, the
        // people out of the chat's bar there, rail_native.mbt; the user 2026-10-27)
        if native {
          s.box(fn(list) {
            @sf.style_node(list, fn() { info_people_list }, in_row=true)
            list.each(fn() { facts().people }, fn(p) { p.id }, fn(i, p) {
              @sf.style_node(i, fn() { info_inline })
              i.pick(at_once=true, fn() { p.get() }, fn(face, p) { wide_people(face, src, [p], 1, tips, stint) })
              @sf.words_node(i, fn() { p.get().display }, fn() { info_words }) |> ignore
            })
          })
          |> ignore
        } else {
          s.box(fn(i) {
            @sf.style_node(i, fn() { info_inline }, in_row=true)
            i.pick(at_once=true, fn() { facts().people }, fn(faces, people) { wide_people(faces, src, people, 8, tips, stint) })
            @sf.words_node(i, fn() { @sf.t("web-pages.workspace.people", args=[("n", facts().people.length().to_string())]) }, fn() {
              info_words
            })
            |> ignore
          })
          |> ignore
        }
      })
    })
    fact(in_thread, labels[3], fn(row) { info_time_node(row, tips, fn() { field(field(thread(), "time"), "createdAt") }) })
    let last = fn() { field(field(field(thread(), "lastMessage"), "time"), "createdAt") }
    fact(fn() { in_thread() && last() is Some(Object(_)) }, labels[4], fn(row) { info_time_node(row, tips, last) })
  })
  |> ignore
}

///|
/// A time as the core says it now (`stamp`: info_time's, ui.tsx Time) in `row`: how long ago, the date in its tip as
/// the pointer rests on it.
fn info_time_node(row : @view.View, tips : @sf.TipLayer, stamp : () -> Json?) -> Unit {
  row.box(fn(b) {
    @sf.words_node(b, fn() { text(stamp(), "ago") }, fn() { info_words }) |> ignore
    @sf.tip_node(tips, b, fn() { text(stamp(), "full") }, within=true) |> ignore
  })
  |> ignore
}

///|
/// Who works in it (info_agents's) in `a`, under who and when (the user, 2026-10-30: 信息和排布不是很合理), as `agents`
/// says them now: each agent's mark (its badge on the panel's ground) and label over its line, a row by its session.
fn info_agents_node(a : @view.View, agents : () -> Array[Json]) -> Unit {
  a.box(fn(list) {
    @sf.style_node(list, fn() { info_agents })
    list.each(agents, fn(one) { text(field(Some(one), "session"), "key") }, fn(ag, one) {
      let av = fn() { Some(one.get()) }
      let s = fn() { field(av(), "session") }
      @sf.style_node(ag, fn() { info_agent })
      ag.box(fn(head) {
        @sf.style_node(head, fn() { info_agent_head })
        head.pick(at_once=true, fn() { text(av(), "badge") }, fn(m, badge) {
          @sfpages.agent_mark_node(
            m,
            fn() { text(field(s(), "maker"), "id") },
            fn() { text(s(), "runtime") },
            info_mark_side,
            badge~,
            ground=@sf.panel_ground,
          )
        })
        @sf.words_node(head, fn() { text(s(), "agentText") }, fn() { info_words }) |> ignore
      })
      |> ignore
      ag.box(fn(line) {
        @sf.style_node(line, fn() { info_agent_line })
        @sf.words_node(line, fn() {
          let parts = []
          let connect = field(av(), "connect")
          if connect is Some(Object(_)) {
            parts.push(text(connect, "name"))
          }
          parts.push(text(s(), "processText"))
          parts.push(@sf.t("web-pages.chat.lastActive", args=[("time", text(field(field(s(), "time"), "lastActiveAt"), "ago"))]))
          parts.join(" · ")
        }, fn() { info_quiet })
        |> ignore
      })
      |> ignore
    })
  })
  |> ignore
}

///|
/// What is in it (chat_info's last group) in `g`, as `holds` says it now (and whether the system's bars are on): the pull requests linked in it, the latest 3
/// (the user, 2026-10-29: most chats have one or two, seen at a look), each a row by its link, 全部 N 个 to the rest
/// beside the chat, pressed, one opens in the browser; what else was said in it besides words, the stations' files
/// beside it, what its agents and other chats' wrote each other: each row there while it has something to say.
fn info_things_node(
  g : @view.View,
  src : Source,
  r : ChatRef,
  holds : () -> (@sfpages.ChatHolds, Bool),
  bg_count : () -> Int,
  done : () -> Unit,
) -> Unit {
  let said = fn() { holds().0 }
  g.box(fn(t) {
    @sf.style_node(t, fn() { info_tools(true) })
    // (beside the system's tabs, a phone's room: none of them by itself, 全部 N 个 alone, the user 2026-11-01)
    let named = fn() { if holds().1 { 0 } else { info_pulls_most } }
    let pulls = fn() {
      let all = said().pulls
      if all.length() > named() {
        all[:named()].to_owned()
      } else {
        all
      }
    }
    t.each(pulls, fn(p) { text(Some(p), "url") }, fn(row, pull) {
      let pv = fn() { Some(pull.get()) }
      info_pull_node(row, src, r, pv, fn() {
        done()
        @sfbase.open_link(text(@signals.untracked(pv), "url"))
      }, done)
    })
    t.show(fn() { said().pulls.length() > named() }, fn(row) {
      info_row_node(row, "list", fn() { @sf.t("web-main.things.pullsAll", args=[("n", said().pulls.length().to_string())]) }, fn() {
        ""
      }, fn() {
        done()
        @sfpages.things_choose(r, "pulls")
        side_tab_open(src, r, "things")
      })
    })
    // (sfpages things.mbt)
    t.show(fn() { said().said > 0 }, fn(row) {
      info_row_node(row, "photo", fn() { @sf.t("web-main.things.title") }, fn() { said().said.to_string() }, fn() {
        done()
        side_tab_open(src, r, "things")
      })
    })
    t.show(fn() { said().files }, fn(row) {
      info_row_node(row, "folder", fn() { @sf.t("web-pages.chat.files") }, fn() { "" }, fn() {
        done()
        side_toggle(src, r, "files")
      })
    })
    t.show(fn() { said().letters > 0 }, fn(row) {
      info_row_node(row, "chats", fn() { @sf.t("web-main.letters.title") }, fn() {
        @sf.t("web-main.letters.count", args=[("n", said().letters.to_string())])
      }, fn() {
        done()
        letters_to_list(r)
        side_toggle(src, r, "letters")
      })
    })
    t.show(fn() { bg_count() > 0 }, fn(row) {
      info_row_node(row, "boxes", fn() { @sf.t("web-main.jobs.jobs") }, fn() { bg_count().to_string() }, fn() {
        done()
        side_tab_open(src, r, "jobs")
      })
    })
  })
  |> ignore
}

///|
// kept across runs: a value (no field of it changes)
let info_row_round : @ui.Style = @ui.style(radius=@sf.panel_in)

///|
// kept across runs: a value (no field of it changes)
let info_row_round_sheet : @ui.Style = @ui.style(radius=@sf.radius_between(@sf.quiet_row_corner))

///|
/// Concentric corner radius for chat info rows: `panel_in` (18pt) in a small 24pt popover panel, `quiet_row_corner`
/// (14pt) in a 38pt sheet/dialog.
fn info_row_round_in(b : @view.View) -> @ui.Style {
  if @sf.in_small_panel_node(b) { info_row_round } else { info_row_round_sheet }
}

///|
/// A row of the info (info_row's, ui.tsx PanelRow) in `parent` (@sf.panel_content_row_node's button): its icon (14, muted) at the panel's words' inset, as
/// the facts' words and the agents' marks over it, and words 10 apart, what is at its end (`end`, while it says
/// something) muted, under its words where the line has not the room; round with the panel, the pointer's ground over
/// it (info_tool's hovered); `press` as it is pressed.
fn info_row_node(parent : @view.View, icon : String, label : () -> String, end : () -> String, press : () -> Unit) -> Unit {
  @sf.panel_content_row_node(parent, label, fn(_) { press() }, highlighted=@sf.lit_node, fn(b) {
    @sf.style_node(b, fn() { info_tool().then(info_row_round_in(b)) })
    @sf.focus_ring_node(b)
    b.box(fn(i) {
      @sf.style_node(i, fn() { info_tool_icon }, in_row=true)
      @sf.icon_node(i, icon, 14.0, By(fn() { @sf.theme().p.muted })) |> ignore
    })
    |> ignore
    b.box(fn(l) {
      @sf.style_node(l, fn() { info_label_flow }, in_row=true)
      l.wraps(Is(Some(0.0))) |> ignore
      @sf.words_node(l, label, fn() { info_words }) |> ignore
      l.show(at_once=true, fn() { end() != "" }, fn(e) { @sf.words_node(e, end, fn() { info_end }) |> ignore })
    })
    |> ignore
  })
}

///|
/// A pull request in the info (info_pull_row's, as info_row_node) laid on `b`, as `pull` says it now: its mark where a
/// row's icon is, its title cut to the line, its number at the line's end, muted; pointed at, its card (as a message's
/// link to it, at the info's left: under it, it would cover the info's rows after it; the user, 2026-10-29: 显示到左边);
/// held or right clicked, its menu (在对话中查看, its link copied); `press` as it is pressed, `done` closing the info
/// for its menu's choice.
fn info_pull_node(b : @view.View, src : Source, r : ChatRef, pull : () -> Json?, press : () -> Unit, done : () -> Unit) -> Unit {
  let title = fn() { @sfpages.pull_title(pull()) }
  let url = fn() { text(pull(), "url") }
  @sf.style_node(b, fn() { info_tool().then(info_row_round_in(b)) })
  b.says(By(fn() { Some(@view.said(Link, label=title())) })) |> ignore
  @sf.hover_ground_node(b, color=fn() { @sf.theme().p.hover })
  @sf.menu_presses_node(b, press, fn(x, y, _) {
    let p = @signals.untracked(pull)
    @sfpages.thing_menu_node_at(x, y, number(p, "seq"), text(p, "url"), fn(seq) {
      done()
      @sfbase.go_to(r, seq)
    })
  })
  b.box(fn(i) {
    @sf.style_node(i, fn() { info_tool_icon }, in_row=true)
    @sfpages.pull_mark_node(i, pull, 14.0)
  })
  |> ignore
  b.box(fn(w) {
    @sf.style_node(w, fn() { info_pull_words }, in_row=true)
    // (its words as wide as they are, cut short where the line has not the room: in a row of their own)
    w.row(Is(true)) |> ignore
    @sf.words_node(w, title, fn() { info_pull_title }) |> ignore
  })
  |> ignore
  @sf.words_node(b, fn() { "#" + count(pull(), "number").to_string() }, fn() { info_end }) |> ignore
  @sfpages.web_peek_node(b, src, r.station, url, title, side=Left, peek=fn() { text(pull(), "peek") })
}
