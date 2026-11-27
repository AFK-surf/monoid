// The sheets over a chat (slice 8): its own, from "…" (still.fail apps/android chat/screens/ChatInfo.kt openChatInfo,
// askTitle, InfoList, InfoRow), an agent's card (AgentSheet.kt openAgent, AgentStatus, AgentLines, AgentTiles,
// AgentNotes, StopButton), its services and jobs and one job (Jobs.kt openJobs, JobGroups, JobInfoRow, JobDot, metaOf,
// openJob, JobBody), and the jobs left up a long while at the top of Home. What they show is the core's
// (the `chat`, `agentCard`, `stations`, `chatJobs`, `jobLog` and `longJobs` views); what is done goes through its calls.
//
// An agent's station opens the station's card in its place (settings/station_peek.mbt), its account how it runs.
//
// The jobs' and a job's sheets drag between half and nearly all of the screen, as Android's.

// ── parts ───────────────────────────────────────────────────────────────

///|
/// An agent's state as its mark's badge says it (ChatAgent.state): block, run, failed, or "" (done).
fn state_of_badge(badge : String) -> String {
  match badge {
    "block" | "run" | "failed" => badge
    _ => ""
  }
}

///|
/// An agent's tile leading its row (a model's mark): as tall as its row's two lines (15 and 12 on the app's 1.4).
let info_tile : Double = 38.0

///|
/// A job's dot (job_dot: 8), and how far under its row's words' top it stands, on its name's line (7).
let job_dot_side : Double = 8.0

///|
let job_dot_over : Double = 7.0

///|
/// A chat's or an agent's title row, as wide as it is given.
// kept across runs: a value (no field of it changes)
let title_row_whole : @ui.Style = @ui.css("w=Full")

///|
/// A chat's name and ✎ in a line: ✎ right after the name, on its first line.
// kept across runs: a value (no field of it changes)
let info_title_line : @ui.Style = @ui.css("row w=Full gap=S2 align=AStart")

///|
/// A chat's name, as wide as it is, 4 down to stand on ✎'s middle.
// kept across runs: a value (no field of it changes)
let info_title_words : @ui.Style = @ui.css("w=Cut pt=S1")

///|
/// An agent's head column: 4 over, 16 under (panel_card_in); its three rows (mark + stop, title, status)
/// each inset to the sheet's 32pt text axis.
// kept across runs: a value (no field of it changes)
let agent_title_head : @ui.Style = @ui.css("w=Full pt=S1").then(
  @ui.style(pb=@sf.room_of(@sf.panel_card_in)),
)

///|
/// An agent's head Row 1: its mark on the left and its compact stop pill on the right (32 high, matching the
/// dialog close key, right edge concentric with the 42pt sheet corner).
// kept across runs: a value (no field of it changes)
let agent_title_row1 : @ui.Style = @ui.css("row w=Full align=ACenter").then(
  @ui.style(min_h=Fixed(agent_stop_h), pl=@sf.room_of(agent_words_in), pr=@sf.room_of(agent_stop_corner_in)),
)

///|
/// An agent's head Row 2 (its full-width model title): 8 under Row 1, inset to the 32pt text axis.
// kept across runs: a value (no field of it changes)
let agent_title_name_box : @ui.Style = @ui.css("w=Full pt=S2").then(
  @ui.style(px=@sf.room_of(agent_words_in)),
)

///|
/// An agent's head Row 3 (its full-width status line): 6 under the title, inset to the 32pt text axis.
// kept across runs: a value (no field of it changes)
let agent_title_status_box : @ui.Style = @ui.css("w=Full pt=S1_5").then(
  @ui.style(px=@sf.room_of(agent_words_in)),
)

///|
/// The chat renamed, asked for its name as it was (@sf.ask): said, the core's `chat.rename`.
fn open_rename(src : Source, r : ChatRef, thread : Double?, was : String, from~ : @sf.Anchor) -> Unit {
  @sf.ask(
    tr("android-chat.rename.title"),
    tr("common.save"),
    fn(title) { @sfpages.chat_rename_call(src, r.station, r.session, thread, title) },
    value=was,
    placeholder=tr("android-chat.rename.field"),
    hint=tr("android-chat.rename.note"),
    // (empty: named anew, as its note says)
    empty=true,
    from~,
  )
}

// ── an agent's card ─────────────────────────────────────

///|
/// A row of the card: what it is about, what there is of it (`under` it what goes with it:
/// an account's allowance, a line of its own), what is under way at its end (`trailing`), where a tap leads.
///|
// kept across runs: a value (no field of it changes)
let agent_row_body_style : @ui.Style = @ui.css("w=Full")

///|
// kept across runs: a value (no field of it changes)
let allowance_box : @ui.Style = @ui.css("row pt=S1")

///|
/// What an agent's row says (its account, its history): on a line, whole while what follows it may leave the row.
// kept across runs: a value (no field of it changes)
let agent_row_value : @ui.TextStyle = @ui.text_style(size=Ui, color=Fg, wrap=false, w=Cut)

///|
/// An agent's name in the chat's info (600) and how it is under it (the caption's, muted): each on a line, whole while
/// its allowance may leave the row.
// kept across runs: a value (no field of it changes)
let info_agent_name : @ui.TextStyle = @ui.text_style(size=Ui, weight=Semibold, color=Fg, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let info_agent_line : @ui.TextStyle = @ui.text_style(size=Caption, color=Muted, wrap=false, w=Cut)

///|
/// Whether any of the figures that say most is known (agent_tiles): none (a station from before tells none of an agent
/// at rest), no figures, its context's entry a row instead.
fn agent_tiles_known(card : Json?) -> Bool {
  text(card, "cost") != "" || field(card, "cache") is Some(Object(_)) || field(card, "context") is Some(Object(_))
}

///|
/// The chat itself, from ⓘ (chat_info_body's, as nodes of the window's tree made once in `v`, open_info's panel's body),
/// as the core's `chat` and the chat's view say it now: its name (with a way to change it) over who started it, how
/// many take part and when it was last written in; its agents, each where it stands (a tap opens its card); then what
/// is in it: its pull requests, what else was said, what its agents and other chats' wrote each other. What is done
/// with it is the "…"'s menu, a row of the list's. As tall as what it shows; a row that opens something closes the
/// panel (`close`) first.
fn chat_info_node(v : @view.View, src : Source, r : ChatRef, close : () -> Unit) -> Unit {
  // (the chat's head alone, as sfdesk's chat_info_node reads it: told as it changes, not as a message is patched in
  // place, none of its messages read again)
  let chat = fn() { @sfbase.chat_head_json(src, r) }
  let view = fn() { @sfbase.chat_head(src, r).0 }
  // archived or offline it is only read: no name to change
  let open = fn() {
    match view() {
      Some(cv) => !cv.archived && !cv.offline
      None => false
    }
  }
  let thread = fn() { field(chat(), "thread") }
  let thread_id = fn() { opt_number(thread(), "id") }
  // its cards, each there while it has a row to show (agents', the chats its agents made, what is done in the chat,
  // what is in it): 16 between two of them, none under the last
  let agents = fn() { items(chat(), "agents") }
  let opened_any = fn() {
    match view() {
      Some(v) => v.opened.length() > 0
      _ => false
    }
  }
  let finds = fn() { thread_id() is Some(_) }
  // (an outline only where it may be asked for: not in a replay of a run from before, whose app had none)
  let outlines = fn() { finds() && (src.asks_outline)() }
  let remote = fn() {
    match view() {
      Some(cv) => chat_has_remote(cv)
      None => false
    }
  }
  let tools = fn() { finds() || remote() }
  let holds = @signals.computed(fn(_) { @sfpages.chat_holds_said(src, r, chat()) })
  let pulls = fn() { holds.get().pulls }
  let jobs_summary = fn() { src.topic("chatJobs", chat_jobs_summary_params(r)).get().value }
  let bg_count = fn() { @sfbase.chat_jobs_background_count(jobs_summary()) }
  // (a card come or gone, or a row of one, a later answer's (what is in it told after the sheet came up): the sheet
  // goes on from as tall as it is seen then to its new height, @sf.panel_reshaped_node; said before what it shows is
  // made anew)
  v.reacts(
    at_start=false,
    fn() {
      let h = holds.get()
      (
        agents().length(),
        opened_any(),
        (finds(), outlines(), remote()),
        (h.pulls.length(), h.said, h.files, h.letters, bg_count()),
      )
    },
    fn(_) { @sf.panel_reshaped_node(v) },
  )
  |> ignore
  // (one column, its parts as close as they are laid out: not the panel's own gap between them)
  v.box(fn(col) {
    @sf.style_node(col, fn() { title_row_whole })
    // its name and ✎, clear of an untitled dialog's close button over its end
    col.box(fn(h) {
      @sf.style_node(h, fn() { @sf.untitled_clear_node(h).then(title_row_whole) })
      info_title_node(h, src, r, fn() { text(chat(), "title") }, open, fn() { opt_number(thread(), "id") })
    })
    |> ignore
    // opened by another chat's agent: the way back there (由「…」创建), pressed as a row is
    col.pick(
      fn() {
        match view() {
          Some({ opener: Some(o), .. }) => Some((o.chat, if o.archived { o.text + " · " + o.note } else { o.text }))
          _ => None
        }
      },
      fn(p, opener) {
        guard opener is Some((to, said)) else { return }
        p.box(fn(b) {
          @sf.style_node(b, fn() { info_opener })
          b.radius(Is(info_opener_corner)) |> ignore
          @sf.rippled_node(b, fn() {
            close()
            open_page(Chat(to))
          }, info_opener_corner, fn() { said })
          // (read out a link, not a button: where it goes is another chat)
          b.says(Is(Some(@view.said(Link, label=said)))) |> ignore
          @sf.icon_node(b, "spawned", info_opener_icon, By(fn() { @sf.theme().p.accent_text })) |> ignore
          @sf.words_node(b, fn() { said }, fn() { info_opener_words }) |> ignore
        })
        |> ignore
      },
    )
    // who started it and when, how many take part, when it was last written in: what there is of them, in a line, after
    // their faces
    col.box(fn(line) {
      @sf.style_node(line, fn() {
        if @sf.in_small_panel_node(line) {
          info_facts_line.then(@sf.panel_words_in_node(line)).then(@ui.css("pb=S2"))
        } else {
          info_facts_line
        }
      })
      let faces = fn() {
        match view() {
          Some(cv) => if cv.people.length() > 5 { cv.people[:5].to_owned() } else { cv.people }
          None => []
        }
      }
      line.pick(
        fn() { faces().map(fn(p) { (p.id, p.display, p.picture) }) },
        fn(s, said) {
          guard said.length() > 0 else { return }
          let shown = @signals.untracked(faces)
          // (ringed in the sheet's ground)
          @sf.avatar_stack_node(s, stack_faces(src, shown, fn() { 0 }), info_face, fn() { @sf.theme().p.card }) |> ignore
        },
      )
      line.box(fn(w) {
        @sf.style_node(w, fn() { info_fill }, in_row=true)
        // (in as many lines as they take: words of no length known, none of them cut)
        @sf.words_node(w, fn() { info_facts_said(chat(), view()) }, fn() { info_facts_words }) |> ignore
      })
      |> ignore
    })
    |> ignore
    let projects_on = fn() {
      match view() {
        Some(cv) => cv.projects
        None => false
      }
    }
    // divider between header/facts and the first visible section
    info_rule_node(col, fn() { projects_on() || agents().length() > 0 || opened_any() || tools() || holds.get().any() || bg_count() > 0 })
    // classification section ("项目与标签"), strictly gated on cv.projects
    col.show(projects_on, at_once=true, fn(p) {
      @sfpages.chat_info_projects_section_node(p, src, r, view, in_sheet=true)
      info_rule_node(p, fn() { agents().length() > 0 || opened_any() || tools() || holds.get().any() || bg_count() > 0 })
    })
    // its agents, each a flat row: its mark, its name, how it is and its allowance, a tap to its card
    // (kept by their session's key once, each row reading its own, told only as that one changes: an agent come or
    // gone makes or lets go its row alone)
    let agent_key = fn(a : Json) { text(field(Some(a), "session"), "key") }
    col.show(fn() { agents().length() > 0 }, fn(p) {
      info_agent_section_node(p, fn(k) {
        let by_key = k.keyed_by(agents, agent_key)
        k.each(fn() { by_key.keys() }, fn(key) { key }, fn(row, key) {
          let key = key.untracked()
          info_agent_row_node(row, src, fn() { by_key.get(key) }, flat=true, fn() {
            close()
            open_agent(src, r, key)
          })
        })
      })
    })
    // the chats its agent made (after who works in it): one row, 创建了 N 个对话, each of them in the menu it opens
    col.pick(
      fn() {
        match view() {
          Some(v) if v.opened.length() > 0 =>
            Some((v.opened.map(fn(o) { (o.chat.station, o.chat.session, o.archived) }), v.opened_text))
          _ => None
        }
      },
      fn(p, made) {
        guard made is Some((_, words)) else { return }
        info_rule_node(p, fn() { agents().length() > 0 })
        let opened = fn() {
          match view() {
            Some(cv) => cv.opened
            None => []
          }
        }
        info_section_node(p, fn(k) {
          let at : Ref[@view.View?] = Ref(None)
          at.val = Some(
            @sf.quiet_row_node(
              k,
              fn() { words },
              look=info_flat_row,
              fn(row) {
                @sf.icon_node(row, "spawned", info_icon, By(fn() { @sf.theme().p.muted })) |> ignore
                row.box(fn(w) {
                  @sf.style_node(w, fn() { info_fill }, in_row=true)
                  @sf.words_node(w, fn() { words }, fn() { info_opened_title }) |> ignore
                })
                |> ignore
                @sf.row_chevron_node(row)
              },
              press=fn() {
                match at.val {
                  Some(from) => @sf.menu(@sfpages.opened_items(@signals.untracked(opened), then=close), from=Node(from), title=words)
                  None => ()
                }
              },
            ),
          )
        })
      },
    )
    // what is done in it, a section of its own (sfdesk's: its bar's 查找, its outline, the remote ways of its station),
    // each row there while it may be done
    col.show(tools, fn(p) {
      info_rule_node(p, fn() { agents().length() > 0 || opened_any() })
      info_section_node(p, fn(k) {
        // ⌘F's bar, in the chat's bar (chat_bar_node's)
        k.show(finds, fn(m) {
          info_more_row_node(m, "search", fn() { tr("web-main.keymap.chat.find") }, fn() { "" }, fn() {
            close()
            @sfpages.find_open(@sfpages.chat_key(r))
          })
          |> ignore
        })
        // its outline, at the message the reader is at (read before the sheet closes for it)
        k.show(outlines, fn(m) {
          info_more_row_node(m, "list", fn() { tr("web-main.outline.title") }, fn() { "" }, fn() {
            match (@signals.untracked(view), @signals.untracked(thread_id)) {
              (Some(cv), Some(th)) => {
                let current = @sfpages.outline_reading_at(src, r, cv)
                close()
                @sfpages.open_outline(src, r, th, current, from=Unanchored)
              }
              _ => ()
            }
          })
          |> ignore
        })
        // its station's screens, browser and terminals, as its bar's way to them says (chat_screens.mbt): one screen
        // alone opened at once, else their menu, a level of this sheet
        k.show(remote, fn(m) {
          let at : Ref[@view.View?] = Ref(None)
          at.val = Some(
            info_more_row_node(
              m,
              "monitor",
              fn() {
                match view() {
                  Some(cv) =>
                    if cv.can_browser() || (cv.can_terminal() && (@sfbase.terminals_capable_fn.val)()) {
                      tr("web-pages.remote.title")
                    } else {
                      tr("web-pages.chat.screen")
                    }
                  None => ""
                }
              },
              fn() {
                match view() {
                  Some(cv) if chat_screens_driven(cv.screens) => tr("web-pages.chat.screenAgent")
                  _ => ""
                }
              },
              fn() {
                match (@signals.untracked(view), at.val) {
                  (Some(cv), Some(from)) => {
                    close()
                    chat_remote_open(src, r, cv, from=Node(from))
                  }
                  _ => ()
                }
              },
            ),
          )
        })
      })
    })
    // then what is in it, one section (the user, 2026-10-30: who works in it before what it made, what it holds apart
    // from what is done with it): its pull requests, what else was said, the stations' files, what its agents and other
    // chats' wrote, and its running background jobs (told only as it changes; each of its rows by what it shows: a thing
    // come or gone makes again only the row it changes)
    col.show(fn() { holds.get().any() || bg_count() > 0 }, fn(p) {
      info_rule_node(p, fn() { agents().length() > 0 || opened_any() || tools() })
      info_section_node(p, fn(k) {
        // the pull requests linked in it, the latest 3 (the user, 2026-10-29: most chats have one or two, seen at a
        // look), 全部 N 个 to the rest; tapped, one opens in the browser
        k.each(
          fn() {
            let all = pulls()
            all[:if all.length() < info_pulls_most { all.length() } else { info_pulls_most }].to_owned()
          },
          fn(pull) { text(Some(pull), "url") },
          fn(row, pull) { info_pull_row_node(row, src, r, fn() { Some(pull.get()) }, close) },
        )
        k.show(fn() { pulls().length() > info_pulls_most }, fn(m) {
          info_more_row_node(m, "list", fn() { fill("web-main.things.pullsAll", [("n", pulls().length().to_string())]) }, fn() {
            ""
          }, fn() {
            guard @signals.untracked(fn() { holds.get().thread }) is Some(th) else { return }
            close()
            @sfpages.things_choose(r, "pulls")
            open_things(src, r, th)
          })
          |> ignore
        })
        // what was said in it besides words: a sheet of their own (sfpages things.mbt)
        k.show(fn() { holds.get().said > 0 }, fn(m) {
          info_more_row_node(m, "photo", fn() { tr("web-main.things.title") }, fn() { holds.get().said.to_string() }, fn() {
            guard @signals.untracked(fn() { holds.get().thread }) is Some(th) else { return }
            close()
            open_things(src, r, th)
          })
          |> ignore
        })
        // the files of the workspace's stations: this chat's station's drive where it lends one, else the files'
        // page of them all
        k.show(fn() { holds.get().files }, fn(m) {
          info_more_row_node(m, "folder", fn() { tr("web-pages.chat.files") }, fn() { "" }, fn() {
            let here = @signals.untracked(fn() {
              dv_stations(src, @sfbase.workspace_of(r.station)).0.unwrap_or([]).iter().any(fn(s) { s.station == r.station && s.drive })
            })
            close()
            if here {
              open_page(Drive({ station: r.station, root: None, path: "" }))
            } else {
              open_page(Files)
            }
          })
          |> ignore
        })
        // what its agents and other chats' wrote each other, not in the chat: their own sheet
        k.show(fn() { holds.get().letters > 0 }, fn(m) {
          info_more_row_node(
            m,
            "chats",
            fn() { tr("web-main.letters.title") },
            fn() { fill("web-main.letters.count", [("n", holds.get().letters.to_string())]) },
            fn() {
              guard @signals.untracked(fn() { holds.get().thread }) is Some(th) else { return }
              close()
              open_letters(src, r, th)
            },
          )
          |> ignore
        })
        // current non-service background jobs (including watches and scheduled tasks): their own scoped sheet
        k.show(fn() { bg_count() > 0 }, fn(m) {
          info_more_row_node(m, "boxes", fn() { tr("android-misc.jobs.jobs") }, fn() { bg_count().to_string() }, fn() {
            close()
            open_chat_jobs(src, r, scope=BackgroundOnly)
          })
          |> ignore
        })
      })
    })
    // (its last card at a dialog's foot, as far from it as from its sides)
    col.box(fn(f) { @sf.style_node(f, fn() { @sf.panel_card_last_node(f) }) }) |> ignore
  })
  |> ignore
}

///|
/// What the chat's line of facts says (chat_info_body's): where it is from, who started it and when, how many take part,
/// when it was last written in; what there is of them, `·` between.
fn info_facts_said(chat : Json?, view : ChatView?) -> String {
  let thread = field(chat, "thread")
  let facts : Array[String] = []
  // (where it came from, as every screen's info reads it: sfpages' chat_through)
  let place = text(chat, "place")
  match @sfpages.chat_through(chat) {
    Some(@sfpages.ChatThrough::Comma) => facts.push(if place == "" { "Comma" } else { "Comma · " + place })
    Some(@sfpages.ChatThrough::Feishu) => facts.push(@sf.t("web-pages.connect.feishu.name") + " · " + place)
    Some(@sfpages.ChatThrough::Slack) => facts.push(fill("android-chat.info.from.slack", [("place", place)]))
    None => ()
  }
  // (made by another chat's agent: that chat said over this line, not a person)
  let creator = if view is Some({ opener: Some(_), .. }) { "" } else { @sfpages.chat_creator_said(thread) }
  let created = text(field(field(thread, "time"), "createdAt"), "ago")
  if creator != "" && created != "" {
    facts.push(fill("android-chat.info.startedAt", [("name", creator), ("ago", created)]))
  } else if creator != "" {
    facts.push(creator)
  } else if created != "" {
    facts.push(created)
  }
  let people = match view {
    Some(v) => v.people.length()
    None => 0
  }
  if people > 1 {
    facts.push(fill("android-chat.info.people.count", [("n", people.to_string())]))
  }
  match text(field(field(field(thread, "lastMessage"), "time"), "createdAt"), "ago") {
    "" => ()
    ago => facts.push(fill("android-chat.info.latestAt", [("ago", ago)]))
  }
  facts.join(" · ")
}

///|
/// Flat section container for `chat_info_node`: rows sit directly on the sheet/panel surface at `panel_card_out`
/// (`16pt` from edge) with `px=S1` (`4pt`) inside each row so icons/text align at `20pt` with the title and facts.
fn info_section_node(parent : @view.View, rows : (@view.View) -> Unit) -> Unit {
  parent.box(fn(k) {
    @sf.style_node(k, fn() { title_row_whole.then(@sf.panel_card_out_node(k)) })
    rows(k)
  })
  |> ignore
}

///|
/// Flat section container for the agent rows in `chat_info_node`: extends `4pt` wider (`mx=-S2` on sheets) so the
/// `p=S2` (`8pt`) inset stays concentric with `quiet_row_corner` (`18 - 8 = 10`) while keeping the agent tile at `20pt`.
fn info_agent_section_node(parent : @view.View, rows : (@view.View) -> Unit) -> Unit {
  parent.box(fn(k) {
    @sf.style_node(k, fn() {
      if @sf.in_small_panel_node(k) {
        title_row_whole
      } else {
        title_row_whole.then(@ui.style(mx=@sf.room_of(-@sf.corner_inset)))
      }
    })
    rows(k)
  })
  |> ignore
}

///|
// kept across runs: a value (no field of it changes)
let info_rule_box : @ui.Style = @ui.css("w=Full py=S1_5")

///|
/// Conditional subtle hairline divider between `chat_info_node` sections, shown only when `over` is true:
/// `@sf.rule_line` aligned to the `20pt` content axis.
fn info_rule_node(p : @view.View, over : () -> Bool) -> Unit {
  p.show(over, fn(r) {
    @sf.style_node(r, fn() { info_rule_box })
    r.box(fn(l) { @sf.style_node(l, fn() { @sf.rule_line }) }) |> ignore
  })
}

///|
/// Flat row styles for `chat_info_node` (`px=S1` = `4pt` = `panel_words - panel_card_in`; agent row uses `p=S2` = `8pt`
/// inside `info_agent_section_node` for concentric `18 -> 10` tile corners).
// kept across runs: a value (no field of it changes)
let info_flat_row : @ui.Style = @ui.css("row w=Full min_h=S11 py=S1 px=S1 gap=S3 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let info_flat_agent_row : @ui.Style = @ui.css("row w=Full min_h=S11 p=S2 gap=S3 align=AStart")

///|
/// The room between two of the info's cards in `p`, over the card after it, while one is over it (`over`): a hairline
/// divider aligned to the content text axis inside a floating glass panel, or a 16pt card gap in a bottom sheet.
fn info_gap_node(p : @view.View, over : () -> Bool) -> Unit {
  p.show(over, fn(g) {
    if @sf.in_small_panel_node(g) {
      @sf.style_node(g, fn() { @ui.css("w=Full py=S1_5").then(@ui.style(px=@sf.room_of(@sf.text_in))) })
      g.box(fn(l) { @sf.style_node(l, fn() { @sf.rule_line }) }) |> ignore
    } else {
      @sf.style_node(g, fn() { info_lists_gap })
    }
  })
}

///|
/// A row of a section of the chat's info in `k`: its icon, its words, what there is of it muted (`end`, while it says
/// something: under its words where the line has not the room, their words whole), its chevron, the icon and the
/// chevron on its words' first line; pressed, `press`. Its node.
fn info_more_row_node(
  k : @view.View,
  icon : String,
  words : () -> String,
  end : () -> String,
  press : () -> Unit,
) -> @view.View {
  @sf.quiet_row_node(k, words, look=info_flat_row, press~, fn(row) {
    // (one line on the row's middle; more, the icon and the chevron on the first of them)
    row.box(fn(line) {
      @sf.style_node(line, fn() { info_more_line }, in_row=true)
      line.box(fn(i) {
        @sf.quiet_first_line(i)
        @sf.icon_node(i, icon, info_icon, By(fn() { @sf.theme().p.text })) |> ignore
      })
      |> ignore
      line.box(fn(w) {
        @sf.style_node(w, fn() { info_more_flow }, in_row=true)
        w.wraps(Is(Some(0.0))) |> ignore
        @sf.words_node(w, words, fn() { info_words }) |> ignore
        w.show(at_once=true, fn() { end() != "" }, fn(e) { @sf.words_node(e, end, fn() { info_meta }) |> ignore })
      })
      |> ignore
      line.box(fn(c) {
        @sf.quiet_first_line(c)
        @sf.row_chevron_node(c)
      })
      |> ignore
    })
    |> ignore
  })
}

///|
/// A row of a card of the info, what it holds on its top: its icon and chevron on its words' first line, 12 apart.
// kept across runs: a value (no field of it changes)
let info_more_line : @ui.Style = @ui.css("row w=Full gap=S3 align=AStart")

///|
/// An info row's words and what is at its end: the end at the line's end, under the words where it has not the room.
// kept across runs: a value (no field of it changes)
let info_more_flow : @ui.Style = @ui.style(row=true, w=@sf.grow, gap=S3, align=ACenter, justify=JBetween)

///|
/// A pull request linked in the chat, its row in the card in `k`: its mark, its title cut to the line, its number at
/// the line's end; tapped, it opens in the browser (the panel closed for it); held or right clicked, its menu (在对话中查看,
/// its link copied); pointed at, its card (sfpages things.mbt), at the info's left.
fn info_pull_row_node(k : @view.View, src : Source, r : ChatRef, pull : () -> Json?, close : () -> Unit) -> Unit {
  // (what it says as the chat has it now: a pull request merged, its title told, while the panel shows)
  let title = fn() { @sfpages.pull_title(pull()) }
  let url = fn() { text(pull(), "url") }
  k.box(fn(b) {
    let corner = if @sf.in_small_panel_node(b) { @sf.small_panel_inner(@sf.r_menu) } else { @sf.quiet_row_corner }
    @sf.style_node(b, fn() { info_flat_row })
    b
    .radius(Is(corner))
    .says(By(fn() { Some(@view.said(Link, label=title())) }))
    |> ignore
    @sf.hover_ground_node(b)
    @sf.menu_presses_node(
      b,
      fn() {
        close()
        @sfbase.open_link(@signals.untracked(url))
      },
      fn(x, y, _) {
        let p = @signals.untracked(pull)
        @sfpages.thing_menu_node_at(x, y, number(p, "seq"), text(p, "url"), fn(seq) {
          close()
          go_to(r, seq)
        })
      },
    )
    @sfpages.pull_mark_node(b, pull, info_icon)
    b.box(fn(w) {
      @sf.style_node(w, fn() { info_fill }, in_row=true)
      @sf.words_node(w, title, fn() { info_pull_title }) |> ignore
    })
    |> ignore
    @sf.words_node(b, fn() { "#" + count(pull(), "number").to_string() }, fn() { info_meta }) |> ignore
    @sfpages.web_peek_node(b, src, r.station, url, title, side=Left, peek=fn() { text(pull(), "peek") })
  })
  |> ignore
}

///|
/// An agent of the chat, its row in the card of who works in it (chat_info_body's) in `k`, `a` as the chat says it now:
/// its mark (as tall as its two lines: in the card's corners as far from its top as from its foot), its name, how it is
/// and for how long, and its allowance under them, each a line of its own (beside its name the allowance took the
/// name's room, or left the row where it had not the room: the allowance gone), its chevron. Pressed, `press`.
fn info_agent_row_node(k : @view.View, src : Source, a : () -> Json?, press : () -> Unit, flat? : Bool = false) -> Unit {
  let s = fn() { field(a(), "session") }
  let small = @sf.in_small_panel_node(k)
  let look = if flat {
    info_flat_agent_row
  } else if small {
    @sf.quiet_row_style.then(@ui.css("py=S2 align=AStart"))
  } else {
    @sf.quiet_row_style.then(@sf.quiet_row_tile)
  }
  @sf.quiet_row_node(k, fn() { text(s(), "agentText") }, look~, press~, fn(row) {
    if small && !flat {
      row.box(fn(m) {
        @sf.quiet_first_line(m)
        model_mark_big_node(
          m,
          fn() { text(field(s(), "maker"), "id") },
          fn() { text(s(), "runtime") },
          info_tile,
          fn() { state_of_badge(text(a(), "badge")) },
          around=fn() {
            let t = @sf.theme()
            @sf.over(t.p.bg, @sf.alpha(t.p.card, 0.8))
          },
          plain=true,
        )
      })
      |> ignore
    } else {
      model_mark_big_node(
        row,
        fn() { text(field(s(), "maker"), "id") },
        fn() { text(s(), "runtime") },
        info_tile,
        fn() { state_of_badge(text(a(), "badge")) },
        around=fn() {
          let t = @sf.theme()
          @sf.over(t.p.bg, @sf.alpha(t.p.card, 0.8))
        },
      )
    }
    row.box(fn(w) {
      @sf.style_node(w, fn() { info_fill }, in_row=true)
      @sf.words_node(w, fn() { text(s(), "agentText") }, fn() { info_agent_name }) |> ignore
      let since = @sfpages.agent_since_node(w, src, a)
      @sf.words_node(
        w,
        fn() {
          match since() {
            "" => text(s(), "statusText")
            ago => text(s(), "statusText") + " · " + ago
          }
        },
        fn() { info_agent_line },
      )
      |> ignore
      allowance_node(w, fn() {
        match field(field(a(), "account"), "quota") {
          Some(_) as q => q
          None => field(field(a(), "profile"), "quota")
        }
      })
    })
    |> ignore
    @sf.row_chevron_node(row)
  })
  |> ignore
}

///|
/// An account's allowance (allowance_line's, as a node) in `v`, `quota` as it is now: its chips on a line of its own
/// under what names it, 4 under it; nothing where it says none.
fn allowance_node(v : @view.View, quota : () -> Json?) -> Unit {
  v.show(fn() { @sfbase.has_quota(quota()) }, fn(b) {
    @sf.style_node(b, fn() { allowance_box })
    @sfbase.quota_chips_node(b, quota)
  })
}

///|
/// `value`'s words in `w` with `tag` after them on their line where it says one (an account's tier: the meta's size,
/// subtle, 8 after, as a profile row's title_after), the words cut short before the tag gives way.
fn tagged_words_node(w : @view.View, value : () -> String, look : () -> @ui.TextStyle, tag : () -> String) -> Unit {
  w.box(fn(line) {
    line.row(Is(true)).lines_up(Is(Some(Middle))).min_width(Is(Some(0.0))) |> ignore
    @sf.words_node(line, value, look).cuts(Is(true)).min_width(Is(Some(0.0))).allow_ellipsis(Is(true)) |> ignore
    line.show(fn() { tag() != "" }, fn(a) {
      a.margin(Is((8.0, 0.0, 0.0, 0.0))) |> ignore
      @sf.row_tag_node(a, tag)
    })
  })
  |> ignore
}

///|
/// A chat's name in its sheet's head (info_title_row's, as nodes) in `h`, as `title` says it now, two lines at most, its
/// ✎ right after it where it can be renamed (`open`; the chat's thread `thread`): the first line of what its panel holds
/// (open_info), clear of an untitled dialog's close button.
fn info_title_node(h : @view.View, src : Source, r : ChatRef, title : () -> String, open : () -> Bool, thread : () -> Double?) -> Unit {
  // (its rename right after its name, on the name's first line, not in the corner over the close button: the user,
  // 2026-11-03, 那个改名的图标显然不能放那)
  h.box(fn(line) {
    @sf.style_node(line, fn() { info_title_line })
    // (two lines at most, the last ending in an ellipsis: not a third cut off below them)
    line.box(fn(w) {
      @sf.style_node(w, fn() { info_title_words }, in_row=true)
      @sf.words_node(w, title, fn() { info_title }) |> ignore
    })
    |> ignore
    line.show(at_once=true, open, fn(b) {
      @sf.style_node(b, fn() { info_rename.then(@ui.style(bg=Data(@sf.alpha(@sf.theme().p.text, info_rename_ink)))) })
      @sf.rippled_node(
        b,
        fn() { open_rename(src, r, @signals.untracked(thread), @signals.untracked(title), from=Node(b)) },
        (info_rename_side : Double) / 2.0,
        fn() { tr("android-chat.rename.title") },
      )
      @sf.icon_node(b, "edit", info_icon, By(fn() { @sf.theme().p.text })) |> ignore
    })
  })
  |> ignore
}

///|
/// The chat's own sheet (chat_info_node) from "…": the library's panel, as tall as what it shows, what it holds nodes of
/// the window's tree made once as it opens, its name with ✎ beside it its first line.
fn open_info(src : Source, r : ChatRef) -> Unit {
  // (its name its head, with its ✎ after it: the user, 2026-11-04, 为啥不做成标题; no title of words, where what it
  // holds draws its name itself)
  @sf.panel_nodes("", from=Unanchored, heads_itself=true, grows=true, live=fn() { ("", "", "") }, fn(v, close) { chat_info_node(v, src, r, close) })
}

///|
/// A chat's name in its sheet's head: the title's size, bold, on lines of 24, two at most.
// kept across runs: a value (no field of it changes)
let info_title : @ui.TextStyle = @ui.text_style(size=Title, weight=Bold, color=Fg, leading=L6, max_lines=2)

///|
/// Its ✎: 32 round on the ink at 5%, its icon in the middle.
// kept across runs: a value (no field of it changes)
let info_rename : @ui.Style = @ui.css("w=S8 h=S8 radius=Full align=ACenter justify=JCenter")

///|
let info_rename_side : Double = 32.0

///|
let info_rename_ink : Double = 0.05

///|
/// An info row's icon (16), and the faces before its facts (16, ringed 1.5).
let info_icon : Double = 16.0

///|
let info_face : Double = 16.0

///|
/// Its facts' line: 6 over, 8 under, its faces and words 8 apart on their middle; its words 13, muted.
// kept across runs: a value (no field of it changes)
let info_facts_line : @ui.Style = @ui.css("row w=Full pt=S1_5 pb=S2 gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let info_facts_words : @ui.TextStyle = @ui.text_style(
  size=Meta,
  color=Muted,
  dark=@ui.text_patch(color=Over(Muted, A(Fg, O75))),
)

///|
/// The way back to the chat an agent opened it from: its icon 16, its corner 8.
let info_opener_icon : Double = 16.0

///|
let info_opener_corner : Double = 8.0
///|
/// An agent of the chat in brief (agent_body's, as nodes of the window's tree made once in `v`, open_agent's panel's
/// body), as the chat and the core's `agentCard` say it now: its head (its mark, its name and where it stands, a stop
/// while it works), its latest lines, what is wrong, the figures that say most; then where to go on: the station it runs
/// on, its screens, what it runs on, its account, its history, its context by hand (context.mbt), its jobs. A row that
/// opens something closes the panel (`close`) first.
fn agent_node(v : @view.View, src : Source, r : ChatRef, key : String, close : () -> Unit) -> Unit {
  let chat = fn() { src.topic("chat", chat_params(r)).get().value }
  // (the agent as the chat has it, told only as it changes: what reads it not run again as each message of the chat
  // does)
  let agent = @signals.computed(fn(_) { agent_json(chat(), key) })
  let a = fn() { agent.get() }
  let s = fn() { field(a(), "session") }
  let card = fn() { src.topic("agentCard", { "station": Json::string(r.station), "key": Json::string(key) }).get().value }
  let entry = context_entry_node(v, src, r, key, s, close)
  // (one column, its parts as close as they are laid out: not the panel's own gap between them)
  v.box(fn(col) {
    @sf.style_node(col, fn() { title_row_whole })
    // (its head: Row 1 clears an untitled dialog's close button; Row 2 title and Row 3 status span full width)
    agent_title_node(col, src, r, key, a)
    // (no outer card around them: its latest lines and what is wrong on the panel's ground, at its figures' words,
    // its figures each a block of their own out to the panel's cards' sides, the room of its cards under them; each
    // part opening its room as what it says comes, the card read after the sheet rose: a part there as it is made at
    // once, one that comes later from none to all of its height, the sheet going with it, never a step, 2026-11-09 the
    // user: 「好像还存在高度突变的元素」)
    @sf.reveal_part_node(col, fn() { items(card(), "latest").length() > 0 }, fn(l) { agent_lines_node(l, card) })
    @sf.reveal_part_node(col, fn() { items(card(), "attention").length() > 0 }, fn(n) {
      agent_notes_node(n, card, 0.0, px=agent_words_in, pb=agent_notes_under)
    })
    @sf.reveal_part_node(col, fn() { agent_tiles_known(card()) }, look=fn(b) { @sf.panel_card_out_node(b) }, fn(t) {
      card_tiles_node(t, card, 0.0, entry)
      t.box(fn(g) { g.height(Is(Some(@sf.panel_card_in))) |> ignore }) |> ignore
    })
    let station = fn() { station_marks(src, @sfbase.workspace_of(r.station)).iter().find_first(fn(st) { st.address == r.station }) }
    let chat_cv = fn() { view_of_chat(src, r).0 }
    let offline_note = fn() {
      match chat_cv() {
        Some(cv) => cv.offline_note.unwrap_or("")
        None => ""
      }
    }
    col.show(fn() { offline_note() != "" }, at_once=true, fn(n) {
      n.padding(Is((agent_words_in, 0.0, agent_words_in, agent_notes_under))) |> ignore
      @sf.words_node(n, offline_note, fn() { @sf.meta.then(@sf.full_words) }) |> ignore
    })
    let has_remote = fn() {
      match chat_cv() {
        Some(cv) => chat_has_remote(cv)
        None => false
      }
    }
    let screens = fn() {
      match chat_cv() {
        Some(cv) => cv.screens
        None => []
      }
    }
    let context_row = fn() { entry() is Some(_) && !(field(card(), "context") is Some(Object(_))) }
    let jobs_row = fn() { items(a(), "jobs").length() > 0 || flag(a(), "hasJobs") }
    // (all its rows' labels in a column as wide as the widest of those it shows, in this language and at this size of
    // words, so the values beside them line up as well)
    let label_w = fn() {
      let labels = [tr("android-chat.agent.account"), tr("android-chat.agent.history"), tr("android-chat.new.model")]
      if station() is Some(_) {
        labels.push(tr("android-chat.agent.station"))
      }
      if has_remote() {
        labels.push(tr("android-chat.agent.screen"))
      }
      if context_row() {
        labels.push(tr("android-chat.agent.context"))
      }
      if jobs_row() {
        labels.push(tr("android-chat.agent.jobs"))
      }
      @sf.labels_across(col, labels)
    }
    let account = fn() {
      match field(a(), "account") {
        Some(Object(_)) as acc => acc
        _ => field(a(), "profile")
      }
    }
    let plan = fn() { text(account(), "planText") }
    @sf.quiet_card_node(
      col,
      fn(list) {
        list.pick(fn() { station().map(fn(st) { (st.address, st.name, st.emoji, st.icon) }) }, fn(p, said) {
          guard said is Some((address, name, emoji, icon)) else { return }
          let st : Station = { address, name, emoji, icon, via: "" }
          @sf.quiet_row_node(
            p,
            fn() { tr("android-chat.agent.station") + " " + st.name },
            fn(row) {
              @sf.row_label_node(row, tr("android-chat.agent.station"), label_w)
              row.box(fn(w) {
                @sf.style_node(w, fn() { agent_station_line }, in_row=true)
                @sfbase.station_mark_at_node(w, fn() { st.address }, fn() { st.emoji }, fn() { st.icon }, Row)
                @sf.words_node(w, fn() { st.name }, fn() { agent_row_value }) |> ignore
              })
              |> ignore
              @sf.row_chevron_node(row)
            },
            press=fn() {
              // the station's card in place of this one
              close()
              @settings.open_station_peek(r.station, from=Unanchored, offline_note~)
            },
          )
          |> ignore
        })
        // the screens, browser and workspace terminal of that station a tap away (chat_screens.mbt)
        list.show(has_remote, fn(p) {
          let at : Ref[@view.View?] = Ref(None)
          at.val = Some(
            agent_row_node(
              p,
              tr("android-chat.agent.screen"),
              fn() {
                let sc = screens()
                if chat_screens_driven(sc) {
                  tr("web-pages.chat.screenAgent")
                } else {
                  sc.get(0).map_or(tr("web-main.rail.remote"), fn(x) { x.title })
                }
              },
              label_w,
              fn() {
                match (@signals.untracked(chat_cv), at.val) {
                  (Some(cv), Some(from)) => {
                    close()
                    chat_remote_open(src, r, cv, from=Node(from))
                  }
                  _ => ()
                }
              },
            ),
          )
        })
        // What it runs on under its own name, the model and how hard it thinks said (2026-11-10: the only way to its
        // picker was the row named 账号, and how hard it thinks was said nowhere short of the picker). The same model
        // picker as the chat's history and a new chat: every way to the run offers the same choices.
        let model = fn() {
          match text(s(), "modelName") {
            "" => text(s(), "model")
            n => n
          }
        }
        list.show(fn() { model() != "" }, fn(p) {
          agent_row_node(
            p,
            tr("android-chat.new.model"),
            fn() {
              match text(s(), "effort") {
                "" => model()
                e => model() + " · " + @sfpages.effort_text(e)
              }
            },
            label_w,
            fn() {
              close()
              @sfpages.open_triple_panel(src, r.station, "session:" + key, Unanchored, saved=@sf.t("web-pages.chat.pickSaved"))
            },
          )
          |> ignore
        })
        // (who runs it: the picker with its accounts open over it)
        agent_row_node(
          list,
          tr("android-chat.agent.account"),
          fn() {
            let name = text(account(), "name")
            if name == "" {
              tr("android-chat.agent.account.none")
            } else if flag(s(), "profilePinned") {
              name
            } else {
              fill("android-chat.agent.account.auto", [("name", name)])
            }
          },
          label_w,
          tag=plan,
          under=fn(w) { allowance_node(w, fn() { field(account(), "quota") }) },
          said=fn() { @settings.join([plan(), @sfbase.quota_chips_said(field(account(), "quota"))], " ") },
          fn() {
            close()
            @sfpages.open_triple_panel(src, r.station, "session:" + key, Unanchored, saved=@sf.t("web-pages.chat.pickSaved"), accounts=true)
          },
        )
        |> ignore
        agent_row_node(
          list,
          tr("android-chat.agent.history"),
          fn() {
            match text(card(), "work") {
              "" => tr("android-chat.agent.history.none")
              w => w
            }
          },
          label_w,
          fn() {
            close()
            @sfbase.history_push()
            app.nav.push(History(r, key, None))
          },
        )
        |> ignore
        // what can be done to its context, where no figure of it is known to be its tile (a station from before tells
        // none of an agent at rest)
        list.show(context_row, fn(p) {
          agent_row_node(
            p,
            tr("android-chat.agent.context"),
            fn() { "" },
            label_w,
            trailing=fn(t) {
              @sfpages.doing_mark_node(t, fn() { entry().map_or(false, fn(e) { e.busy }) }, fn() {
                if entry().map_or(false, fn(e) { e.failed }) {
                  Some("")
                } else {
                  None
                }
              })
            },
            fn() {
              match @signals.untracked(entry) {
                Some(e) if !e.busy => (e.open)()
                _ => ()
              }
            },
          )
          |> ignore
        })
        list.show(jobs_row, fn(p) {
          agent_row_node(
            p,
            tr("android-chat.agent.jobs"),
            fn() {
              match text(card(), "jobs") {
                "" => tr("android-chat.agent.jobs.idle")
                j => j
              }
            },
            label_w,
            fn() {
              close()
              open_chat_jobs(src, r)
            },
          )
          |> ignore
        })
      },
      // (its last card at a dialog's foot, as far from it as from its sides)
      last=fn() { true },
    )
  })
  |> ignore
}

///|
/// A row of the agent's card (agent_row's, as a node) in `p`: what it is about (`label`, in its column `label_w` wide),
/// what there is of it (`value` as it is now; `under` it what goes with it: an account's allowance, a line of its own),
/// what is under way at its end (`trailing`), its chevron; pressed, `press`; read out its label, its value and what
/// `said` says of what is under it. Its node.
fn agent_row_node(
  p : @view.View,
  label : String,
  value : () -> String,
  label_w : () -> Double,
  under? : (@view.View) -> Unit,
  said? : () -> String = fn() { "" },
  tag? : () -> String,
  trailing? : (@view.View) -> Unit,
  press : () -> Unit,
) -> @view.View {
  // (read out what it is about, what there is of it and what goes with it: an account's allowance)
  let label_said = fn() {
    match said() {
      "" => label + " " + value()
      more => label + " " + value() + " " + more
    }
  }
  // (one of a line on its middle, as every row of the card; one with a line under its value (an account's allowance)
  // on its top, its label and chevron on its value's first line)
  let look = if under is Some(_) { @sf.quiet_row_top } else { @sf.quiet_row_middle }
  @sf.quiet_row_node(p, label_said, look~, press~, fn(row) {
    @sf.row_label_node(row, label, label_w)
    row.box(fn(w) {
      @sf.style_node(w, fn() { agent_row_body_style }, in_row=true)
      match tag {
        Some(t) => tagged_words_node(w, value, fn() { agent_row_value }, t)
        None => @sf.words_node(w, value, fn() { agent_row_value }) |> ignore
      }
      match under {
        Some(f) => f(w)
        None => ()
      }
    })
    |> ignore
    match trailing {
      Some(f) => f(row)
      None => ()
    }
    // (on its value's first line, as its label is: not on the middle of what is under it)
    row.box(fn(c) {
      @sf.quiet_first_line(c)
      @sf.row_chevron_node(c)
    })
    |> ignore
  })
}

///|
/// A station's mark (a row's: station_mark_at_node) and name in its row: 6 apart on their middle.
// kept across runs: a value (no field of it changes)
let agent_station_line : @ui.Style = @ui.css("row w=Full gap=S1_5 align=ACenter")

///|
/// Under its notes, over its figures.
let agent_notes_under : Double = 12.0

///|
/// How far its lines and notes stand in from the column: as far as its figures' words do (a card out of the panel's
/// sides, panel_card_out, its words 16 in it).
let agent_words_in : Double = 8.0

///|
/// An agent's head in its card (agent_title_row's, as nodes) in `col`, `a` as the chat says it now: three rows aligned
/// on the sheet's 32pt text axis — Row 1 with its maker's mark on the left and its compact stop pill on the right
/// (clearing an untitled dialog's close key), Row 2 with its full-width model title (up to 2 lines), Row 3 with its
/// full-width status line.
fn agent_title_node(col : @view.View, src : Source, r : ChatRef, key : String, a : () -> Json?) -> Unit {
  let s = fn() { field(a(), "session") }
  col.box(fn(head) {
    @sf.style_node(head, fn() { agent_title_head })
    head.box(fn(clear_wrap) {
      @sf.style_node(clear_wrap, fn() { @sf.untitled_clear_node(clear_wrap).then(title_row_whole) })
      clear_wrap.box(fn(row) {
        @sf.style_node(row, fn() { agent_title_row1 })
        model_mark_big_node(
          row,
          fn() { text(field(s(), "maker"), "id") },
          fn() { text(s(), "runtime") },
          agent_title_mark,
          fn() { state_of_badge(text(a(), "badge")) },
          around=fn() {
            let t = @sf.theme()
            @sf.over(t.p.bg, @sf.alpha(t.p.card, 0.8))
          },
          plain=true,
        )
        row.box(fn(sp) { sp.grow(Is(1.0)).basis(Is(Some(0.0))) |> ignore }) |> ignore
        row.show(at_once=true, fn() { text(a(), "status") == "running" || text(a(), "status") == "queued" }, fn(at) {
          stop_button_node(at, src, r.station, key)
        })
      })
      |> ignore
    })
    |> ignore
    head.box(fn(t) {
      @sf.style_node(t, fn() { agent_title_name_box })
      @sf.words_node(t, fn() { text(s(), "agentText") }, fn() { agent_title_name }) |> ignore
    })
    |> ignore
    head.box(fn(st) {
      @sf.style_node(st, fn() { agent_title_status_box })
      @sfpages.agent_status_node(st, src, a)
    })
    |> ignore
  })
  |> ignore
}

///|
/// One part of a card or a sheet in `parent` that shows `first` (what is read meanwhile) till `second()` says so, then
/// `second` (what was read) in its place: there as it is made where `second()` says so then; else, as it comes to,
/// from none to as tall as `second` is, one way (a Move as far as that), what it holds there whole from the first frame;
/// what is under it going with it.
fn swap_part_node(
  parent : @view.View,
  second : () -> Bool,
  first : (@view.View) -> Unit,
  later : (@view.View) -> Unit,
) -> Unit {
  let share = @motion.NodeWay::new(0.0)
  let made = Ref(false)
  parent.by_room(fn(b, room) {
    let one : Ref[@view.View?] = Ref(None)
    let two : Ref[@view.View?] = Ref(None)
    let tall = fn(r : Ref[@view.View?]) {
      match r.val {
        Some(i) => room.tall(i)
        None => 0.0
      }
    }
    // (not cut: what comes is all of it there from the first frame, its room opening under it, as what is under it goes
    // down with it)
    b
    .height(By(fn() {
      let s = share.shown(b)
      Some(tall(one) * (1.0 - s) + tall(two) * s)
    }))
    |> ignore
    // (where it stands said first, before what it holds is made: what is made of `first` only while it shows)
    b.reacts(second, fn(on) {
      if !made.val {
        made.val = true
        share.put(if on { 1.0 } else { 0.0 })
        return
      }
      let far = dmax((@signals.untracked(fn() { tall(two) - tall(one) })).abs(), @sf.reveal_least)
      share.go(b, if on { 1.0 } else { 0.0 }, @motion.moved(points=far))
    })
    one.val = Some(
      b.box(fn(i) {
        i.over(Is(true)).alpha(By(fn() { 1.0 - share.shown(b) })) |> ignore
        i.show(at_once=true, fn() { share.target() < 1.0 || !second() }, first)
      }),
    )
    two.val = Some(
      b.box(fn(i) {
        // (whole as its room opens: cut to it, not faded)
        i.over(Is(true)) |> ignore
        i.show(at_once=true, second, later)
      }),
    )
  })
  |> ignore
}

///|
/// Its mark in its head (46, glyph 25.76 in plain mode, balanced with the 32pt stop capsule).
let agent_title_mark : Double = 46.0

///|
/// Its name: the title's size, bold, full width, wrapping up to two lines.
// kept across runs: a value (no field of it changes)
let agent_title_name : @ui.TextStyle = @ui.text_style(size=Title, weight=Bold, color=Fg, w=Full, max_lines=2)

///|
/// Stopping its turn, while it works (stop_button's, as a node) in `v`: compact red pill on its tint, a spinner while
/// it is asked.
fn stop_button_node(v : @view.View, src : Source, station : String, key : String) -> Unit {
  let skey = "stop/" + station + "/" + key
  v.box(fn(b) {
    @sf.style_node(b, fn() { agent_stop.then(@ui.style(bg=Data(@sf.alpha(@sf.theme().p.red, agent_stop_ink)))) })
    @sf.rippled_node(
      b,
      fn() {
        if !doing(skey) {
          act(
            src,
            tr("android-chat.agent.stop"),
            skey,
            "session.stop",
            { "station": Json::string(station), "key": Json::string(key) },
            done=tr("android-chat.history.stopped"),
          )
        }
      },
      (agent_stop_h : Double) / 2.0,
      fn() { tr("android-chat.agent.stop") },
    )
    b.pick(fn() { doing(skey) }, fn(i, busy) {
      if busy {
        @sf.spinner_node(i, size=agent_stop_spin) |> ignore
      } else {
        @sf.icon_node(i, "stop", agent_stop_icon, By(fn() { @sf.theme().p.red })) |> ignore
      }
    })
    @sf.words_node(b, fn() { tr("android-chat.agent.stop") }, fn() { agent_stop_words }) |> ignore
  })
  |> ignore
}

///|
/// Its stop: a capsule 32 high, 14 in, its mark and words 6 apart on its middle, on red at 14%.
// kept across runs: a value (no field of it changes)
let agent_stop : @ui.Style = @ui.css("row min_h=S8 px=S3_5 py=S1 gap=S1_5 radius=Full align=ACenter")

///|
let agent_stop_h : Double = 32.0

///|
/// Extra right inset inside Row 1 so the 32pt stop capsule sits concentric with the 42pt sheet top-right corner.
let agent_stop_corner_in : Double = @ui.capsule_in(@sf.pane_corner, agent_stop_h) - @sf.panel_words

///|
let agent_stop_ink : Double = 0.14

///|
let agent_stop_spin : Double = 12.0

///|
let agent_stop_icon : Double = 11.0

///|
// kept across runs: a value (no field of it changes)
let agent_stop_words : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=Danger, wrap=false)

///|
/// Its latest lines (agent_lines', as a node) in `v`, the core's card as `card` has it now: the things it did, then
/// what it does now, in the ink; each on one line of 18, cut short where it runs past it (an agent's own words).
fn agent_lines_node(v : @view.View, card : () -> Json?) -> Unit {
  @sf.style_node(v, fn() { agent_lines })
  // (its lines made with it, all at once: the block comes in whole as the card is read, never its room first and its
  // lines a frame after; each by its place, what it says bound: a line said anew makes nothing again)
  v.box(fn(col) {
    col.gap(Is(agent_lines_gap)) |> ignore
    col.each(
      fn() { items(card(), "latest").mapi(fn(i, l) { (i, text(Some(l), "text"), flag(Some(l), "now")) }) },
      fn(l) { l.0 },
      at_once=true,
      fn(row, l) {
        job_runs_node(row, fn() { [@ui.span(l.get().1)] }, fn() { job_words(@sf.theme().t.meta, wrap=false, line=agent_line_h) }, fn() {
          let t = @sf.theme()
          if l.get().2 {
            t.p.text
          } else {
            t.p.muted
          }
        })
      },
    )
  })
  |> ignore
}

///|
/// Its lines: none over, 14 under, 8 in from the column's words (as its figures' words are), 4 apart (on the spacing's
/// scale: 3 was not), on lines of 18.
// kept across runs: a value (no field of it changes)
let agent_lines : @ui.Style = @ui.css("w=Full px=S2 pt=S0 pb=S3_5")

///|
let agent_lines_gap : Double = 4.0

///|
let agent_line_h : Double = 18.0

///|
/// The figures that say most in an agent's card (agent_tiles', as nodes: UsageTiles.kt) in `v`, `top` under what is
/// over them, the core's card as `card` has it now: the library's roomy figures (@sfpages.usage_tiles_node: what it
/// cost, the cache's hit rate, how full its context is, each its share of the row, as large as fits); its context's
/// opens what can be done to it when it can be (`entry`: turning while that is under way, its mark where it failed).
fn card_tiles_node(v : @view.View, card : () -> Json?, top : Double, entry : () -> ContextTile?) -> Unit {
  let tips = @sf.panel_tips_of(v).unwrap_or(@sf.window_tips())
  v.pick(at_once=true, fn() { entry() is Some(_) }, fn(t, opens) {
    if opens {
      @sfpages.usage_tiles_node(
        t,
        card,
        tips,
        roomy=true,
        top~,
        context=fn(_) {
          match @signals.untracked(entry) {
            Some(o) if !o.busy => (o.open)()
            _ => ()
          }
        },
        busy=fn() { entry().map_or(false, fn(o) { o.busy }) },
        failed=fn() { entry().map_or(false, fn(o) { o.failed }) },
        compacts=fn() { entry().map_or(false, fn(o) { o.compacts }) },
      )
    } else {
      @sfpages.usage_tiles_node(t, card, tips, roomy=true, top~)
    }
  })
}

///|
/// The agent's card (agent_node): the library's panel, as tall as what it shows, what it holds nodes of the window's
/// tree made once as it opens, its head its own (its mark, name and where it stands).
fn open_agent(src : Source, r : ChatRef, key : String) -> Unit {
  // (its mark, name and where it stands its head: the user, 2026-11-04, 这个是不是也可以想办法做成标题)
  @sf.panel_nodes("", from=Unanchored, heads_itself=true, live=fn() { ("", "", "") }, fn(v, close) { agent_node(v, src, r, key, close) })
}

///|
/// Bottom sheet listing a station entry and all agents running on it in this chat (opened when tapping a multi-agent
/// merged capsule above the composer on Small screens).
fn open_station_agents(src : Source, r : ChatRef, station_addr : String) -> Unit {
  let addr = if station_addr != "" { station_addr } else { r.station }
  @sf.panel_nodes(tr("android-chat.agent.station"), from=Unanchored, fn(v, close) { station_agents_node(v, src, r, addr, close) })
}

///|
/// Body of `open_station_agents`: a station card leading to `open_station_peek`, followed by a card listing each agent
/// on that station via `info_agent_row_node` leading to `open_agent`.
fn station_agents_node(v : @view.View, src : Source, r : ChatRef, addr : String, close : () -> Unit) -> Unit {
  let chat = fn() { @sfbase.chat_head_json(src, r) }
  let agents = fn() { items(chat(), "agents") }
  let station = fn() { station_marks(src, @sfbase.workspace_of(addr)).iter().find_first(fn(st) { st.address == addr }) }
  let offline_note = fn() {
    match @sfbase.chat_view_now(src, r) {
      Some(cv) => cv.offline_note.unwrap_or("")
      None => ""
    }
  }
  let agent_key = fn(a : Json) { text(field(Some(a), "session"), "key") }
  v.box(fn(col) {
    @sf.style_node(col, fn() { title_row_whole })
    col.pick(fn() { station().map(fn(st) { (st.address, st.name, st.emoji, st.icon) }) }, fn(p, said) {
      guard said is Some((address, name, emoji, icon)) else { return }
      @sf.quiet_card_node(p, fn(k) {
        @sf.quiet_row_node(
          k,
          fn() { name },
          fn(row) {
            @sfbase.station_mark_at_node(row, fn() { address }, fn() { emoji }, fn() { icon }, Row)
            row.box(fn(w) {
              @sf.style_node(w, fn() { info_fill }, in_row=true)
              @sf.words_node(w, fn() { name }, fn() { info_words }) |> ignore
            })
            |> ignore
            @sf.row_chevron_node(row)
          },
          press=fn() {
            close()
            @settings.open_station_peek(address, from=Unanchored, offline_note~)
          },
        )
        |> ignore
      })
    })
    col.show(fn() { agents().length() > 0 }, fn(p) {
      info_gap_node(p, fn() { station() is Some(_) })
      @sf.quiet_card_node(p, fn(k) {
        let by_key = k.keyed_by(agents, agent_key)
        k.each(fn() { by_key.keys() }, fn(key) { key }, fn(row, key) {
          let key = key.untracked()
          info_agent_row_node(row, src, fn() { by_key.get(key) }, fn() {
            close()
            open_agent(src, r, key)
          })
        })
      })
    })
    col.box(fn(f) { @sf.style_node(f, fn() { @sf.panel_card_last_node(f) }) }) |> ignore
  })
  |> ignore
}

// ── jobs ─────────────────────────────────────────

///|
/// A job's dot's colour: a service up or a job alive green, one restarting amber, one that died
/// red; one over the subtle grey (None: the text's own for its word).
fn job_tint(tone : String) -> Int64? {
  let t = @sf.theme()
  match tone {
    "up" | "live" => Some(t.p.green)
    "restart" => Some(0xD9962BFFL)
    "fail" => Some(t.p.red)
    _ => None
  }
}

///|
/// What fills the room a row leaves it (an old view's Fill along a row).
// kept across runs: a value (no field of it changes)
let info_fill : @ui.Style = @ui.css("w=Full")

///|
/// Which subset of `chatJobs` the small-screen jobs sheet displays: all (from an agent card), only web services (from
/// the chat bar's `web` capsule), or only non-service background jobs (from the `ⓘ` chat info sheet).
#derive(Eq)
priv enum JobsScope {
  All
  ServicesOnly
  BackgroundOnly
}

///|
/// One of the rows of the chat's services and jobs (jobs_node's): words saying it has none, a group's label (its
/// services, its jobs), a job of a group by its id.
#derive(Eq, Hash)
priv enum JobsRow {
  JobsNone
  JobsHead(Bool)
  JobsOne(Bool, String)
}

///|
/// The rows of services and jobs `jobs` within `scope`: none, words saying so; services, then background jobs, each
/// group under its label (scoped sheets omit the redundant group title when its note is empty).
fn jobs_rows(jobs : Array[Json], scope : JobsScope, view? : Json? = None) -> Array[JobsRow] {
  let out : Array[JobsRow] = []
  let kinds : Array[Bool] = match scope {
    All => [true, false]
    ServicesOnly => [true]
    BackgroundOnly => [false]
  }
  for service in kinds {
    let group = jobs.filter(fn(j) { flag(Some(j), "service") == service })
    if group.length() > 0 {
      let note = text(view, if service { "servicesNote" } else { "jobsNote" })
      if scope == All || note != "" {
        out.push(JobsHead(service))
      }
      for j in group {
        out.push(JobsOne(service, text(Some(j), "id")))
      }
    }
  }
  if out.length() == 0 {
    out.push(JobsNone)
  }
  out
}

///|
/// The chat's services and jobs (jobs_body's, as nodes of the window's tree made once in `v`, open_chat_jobs' panel's
/// body), as the core's `chatJobs` has them now: those over are not shown (the core leaves them out). Services, then
/// background jobs, each group's head with how many are up or alive; a service up or being started again opens its page
/// (service.mbt), one that did not start (or is over) and any job its sheet (open_job), this panel closed for it. In
/// their bones while they are read, what went wrong over them.
fn jobs_node(v : @view.View, src : Source, r : ChatRef, close : () -> Unit, scope? : JobsScope = All) -> Unit {
  let topic = fn() { src.topic("chatJobs", chat_params(r)).get() }
  let view = fn() {
    match topic().value {
      Some(Object(_)) as j => j
      _ => None
    }
  }
  // (told at last, or a job come or gone: what it holds another height for that cause, the sheet going on from as tall
  // as it is seen then, @sf.panel_reshaped_node; made before what it shows, so it is said before that is made anew)
  v.reacts(
    at_start=false,
    fn() {
      let count = match scope {
        All => items(view(), "jobs").length()
        ServicesOnly => items(view(), "jobs").filter(fn(j) { flag(Some(j), "service") }).length()
        BackgroundOnly => items(view(), "jobs").filter(fn(j) { !flag(Some(j), "service") }).length()
      }
      (view() is Some(_), count)
    },
    fn(_) { @sf.panel_reshaped_node(v) },
  )
  |> ignore
  v.pick(fn() { view() is Some(_) }, fn(p, told) {
    p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
    if !told {
      // (its rows of made-up services and jobs, in their bones, what went wrong over them in red)
      p.box(fn(w) {
        @sf.style_node(w, fn() { jobs_waiting })
        @sf.waiting_node(
          w,
          fn(s) {
            let sample = jobs_sample()
            let rows = jobs_rows(sample, scope)
            s.each_of(fn() { rows }, at_once=true, fn(row_at, row) {
              row_at.box(fn(b) {
                @sf.style_node(b, fn() { info_fill })
                jobs_row_node(b, src, r, row, fn() { Some(Json::object({ "jobs": Json::array(sample) })) }, fn() {  }, scope~)
              })
              |> ignore
            })
          },
          error=fn() {
            match topic().error {
              Some(e) => error_words(e)
              None => ""
            }
          },
        )
      })
      |> ignore
      return
    }
    let rows = @signals.computed(fn(_) { jobs_rows(items(view(), "jobs"), scope, view=view()) })
    // (its rows on the panel's words' line, as tall as they come to up to the panel's share, scrolling in it past that)
    @sf.panel_list_node(p, fn() { rows.get() }, fn(b, row) { jobs_row_node(b, src, r, row, view, close, scope~) }, est=jobs_row_est)
    |> ignore
    // (its last card at a dialog's foot, as far from it as from its sides)
    p.show(at_once=true, fn() { !(rows.get().get(0) is Some(JobsNone)) }, fn(f) {
      @sf.style_node(f, fn() { @sf.panel_card_last_node(f) })
    })
  })
}

///|
/// How tall a row of the chat's jobs is taken to be till it is laid out.
let jobs_row_est : Double = 60.0

///|
/// While its services and jobs are read: their bones 18 in.
// kept across runs: a value (no field of it changes)
let jobs_waiting : @ui.Style = @ui.css("w=Full px=S4_5")

///|
/// Row `row` of the chat's services and jobs (jobs_node's) in `b`, the core's `chatJobs` as `view` has it now; a job's
/// row pressed leads where it does (job_press), `close` closing the panel first.
fn jobs_row_node(
  b : @view.View,
  src : Source,
  r : ChatRef,
  row : JobsRow,
  view : () -> Json?,
  close : () -> Unit,
  scope? : JobsScope = All,
) -> Unit {
  match row {
    JobsNone =>
      b.box(fn(n) {
        @sf.style_node(n, fn() { @sf.panel_words_in_node(n).then(jobs_none) })
        @sf.words_node(n, fn() { tr("android-misc.jobs.none") }, fn() { jobs_none_title }) |> ignore
        @sf.words_node(n, fn() { tr("android-misc.jobs.none.text") }, fn() { jobs_none_words }) |> ignore
      })
      |> ignore
    JobsHead(service) =>
      // (13, muted, 14 above it and 4 under, how many are up or alive after it)
      b.box(fn(h) {
        @sf.style_node(h, fn() { @sf.panel_words_in_node(h).then(jobs_head) })
        @sf.words_node(
          h,
          fn() {
            let (key, note) = if service {
              ("android-misc.jobs.services", text(view(), "servicesNote"))
            } else {
              ("android-misc.jobs.jobs", text(view(), "jobsNote"))
            }
            if scope == All {
              tr(key) + (if note != "" { " · " + note } else { "" })
            } else {
              note
            }
          },
          fn() { jobs_head_words },
        )
        |> ignore
      })
      |> ignore
    JobsOne(service, id) => {
      let group = fn() { items(view(), "jobs").filter(fn(j) { flag(Some(j), "service") == service }) }
      // (its job and its piece told only as they change: what reads them not run again as another job does)
      let job_now = @signals.computed(fn(_) { group().iter().find_first(fn(j) { text(Some(j), "id") == id }) })
      let job = fn() { job_now.get() }
      // (each a piece of its group's card: the card's top, its foot, one between, or the whole of it)
      let piece_now = @signals.computed(fn(_) {
        let g = group()
        match g.search_by(fn(j) { text(Some(j), "id") == id }) {
          Some(i) => @sf.card_piece_of(i, g.length())
          None => @sf.CardWhole
        }
      })
      let piece = fn() { piece_now.get() }
      @sf.card_piece_node(b, piece, fn(k) { job_row_node(k, job, fn() { job_press(src, r, @signals.untracked(job), close) }) })
    }
  }
}

///|
/// Where a job's row leads (job_groups' press): a service up or being started again, its page; else what it said (a
/// job) or its output (a service), its sheet (open_job); the panel closed (`close`) for it.
fn job_press(src : Source, r : ChatRef, j : Json?, close : () -> Unit) -> Unit {
  let id = text(j, "id")
  let tone = text(j, "tone")
  if flag(j, "service") && (tone == "up" || tone == "restart") {
    close()
    @sfbase.history_push()
    app.nav.push(Service(r.station, id))
  } else {
    dui.job_tab = if flag(j, "service") { 1 } else { 0 }
    close()
    open_job(src, r, id)
  }
}

///|
/// A job's row (job_row's, as a node: JobInfoRow) in `k`, the job as `job` has it now: its dot on its name's line, what
/// it is up to under it, its chevron; an over one's name stepped back to the muted grey, not faded (at 55% its words
/// were 2.3 to 1: mbui ui/contrast.mbt). Pressed, `press`.
fn job_row_node(k : @view.View, job : () -> Json?, press : () -> Unit) -> Unit {
  @sf.quiet_row_node(k, fn() { text(job(), "name") }, look=job_row_look, press~, fn(row) {
    // (its dot and its chevron each down the middle of its name's first line, at the system's size of words)
    row.box(fn(d) {
      @sf.quiet_first_line(d)
      @sf.state_dot_node(d, fn() { text(job(), "tone") }, size=job_dot_side, breathes=true)
    })
    |> ignore
    row.box(fn(w) {
      @sf.style_node(w, fn() { job_row_words }, in_row=true)
      @sf.words_node(w, fn() { text(job(), "name") }, fn() {
        if job_tint(text(job(), "tone")) is None {
          job_name_off
        } else {
          job_name
        }
      })
      |> ignore
      job_meta_node(w, job, job_meta_size)
    })
    |> ignore
    row.box(fn(c) {
      @sf.quiet_first_line(c)
      @sf.row_chevron_node(c)
    })
    |> ignore
  })
  |> ignore
}

///|
/// A job's row: its dot and its chevron on its name's first line, its words 1 apart.
// kept across runs: a value (no field of it changes)
let job_row_look : @ui.Style = @sf.quiet_row_style.then(@sf.quiet_row_dot(job_dot_side, job_dot_over)).then(@ui.css("align=AStart"))

///|
// kept across runs: a value (no field of it changes)
let job_row_words : @ui.Style = @ui.css("w=Full gap=SPx")

///|
/// A job's name (15, medium, on a line cut short), muted where it is over.
// kept across runs: a value (no field of it changes)
let job_name : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Fg, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let job_name_off : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Muted, wrap=false, w=Cut)

///|
/// None: 12 over and under, its title and words 4 apart.
// kept across runs: a value (no field of it changes)
let jobs_none : @ui.Style = @ui.css("w=Full py=S3 gap=S1")

///|
// kept across runs: a value (no field of it changes)
let jobs_none_title : @ui.TextStyle = @ui.text_style(size=Ui, weight=Semibold, color=Fg)

///|
// kept across runs: a value (no field of it changes)
let jobs_none_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted)

///|
/// A group's label: 14 above it, 4 under.
// kept across runs: a value (no field of it changes)
let jobs_head : @ui.Style = @ui.css("w=Full pb=S1").then(@ui.style(pt=@sf.room_of(jobs_head_over)))

///|
let jobs_head_over : Double = 14.0

///|
// kept across runs: a value (no field of it changes)
let jobs_head_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
/// The chat's services and jobs (jobs_node): the library's panel, as tall as what it holds up to 62% of the window,
/// dragged between half and nearly all of it, what it holds nodes of the window's tree made once as it opens.
fn open_chat_jobs(src : Source, r : ChatRef, scope? : JobsScope = All) -> Unit {
  let title = match scope {
    All => tr("android-misc.jobs.title")
    ServicesOnly => tr("android-misc.jobs.services")
    BackgroundOnly => tr("android-misc.jobs.jobs")
  }
  @sf.panel_nodes(title, from=Unanchored, tall=0.62, hugs=true, grows=true, fn(v, close) {
    jobs_node(v, src, r, close, scope~)
  })
}

///|
/// One of the rows of the chat's led sub-chats bottom sheet (`subchats_sheet_node`): empty state; a sub-chat on the card
/// it leads with (`0`: subchats_lead's) or on an open folding group's card (`1` done, `2` archived); the press at that
/// card's foot that shows or folds back the finished ones past the latest; or a folding group's head, on a card of its
/// own (subchats_sheet_group_head_node).
#derive(Eq, Hash)
priv enum SubchatSheetRow {
  SubchatsSearch
  SubchatsEmpty
  SubchatsSearchEmpty
  SubchatsSearchHit(String)
  SubchatsOne(Int, String)
  SubchatsMore
  SubchatsDoneHead
  SubchatsArchivedHead
}

///|
fn subchat_sheet_key(o : @sfbase.OpenedChat) -> String {
  o.chat.station + "\u{1}" + o.chat.session
}

///|
fn subchats_sheet_rows(
  subchats : Array[@sfbase.OpenedChat],
  done_open : Bool,
  archived_open : Bool,
  more : Bool,
  filtering : Bool,
  hits : Array[@sfbase.SubchatHit],
) -> Array[SubchatSheetRow] {
  let out : Array[SubchatSheetRow] = []
  if subchats.length() == 0 {
    out.push(SubchatsEmpty)
    return out
  }
  out.push(SubchatsSearch)
  if filtering {
    if hits.is_empty() {
      out.push(SubchatsSearchEmpty)
    } else {
      for h in hits {
        out.push(SubchatsSearchHit(subchat_sheet_key(h.opened)))
      }
    }
    return out
  }
  let kind = @sfpages.subchats_lead_kind(subchats)
  let (lead, past) = @sfpages.subchats_lead(subchats, more)
  for o in lead {
    out.push(SubchatsOne(0, subchat_sheet_key(o)))
  }
  if past > 0 {
    out.push(SubchatsMore)
  }
  let done = subchats.filter(fn(o) { @sfpages.subchat_is_done(o) })
  let done_folds = kind == 0 && done.length() > 0
  if done_folds {
    out.push(SubchatsDoneHead)
    if done_open {
      for o in done {
        out.push(SubchatsOne(1, subchat_sheet_key(o)))
      }
    }
  }
  let archived = subchats.filter(fn(o) { o.archived })
  if kind != 2 && archived.length() > 0 {
    out.push(SubchatsArchivedHead)
    if archived_open {
      for o in archived {
        out.push(SubchatsOne(2, subchat_sheet_key(o)))
      }
    }
  }
  out
}

///|
/// The chat's led sub-chats bottom sheet on Small screens (`open_subchats`): grouped cards in a virtualized
/// `panel_list_node` with live running/waiting counts in `head_end`, pull-down search bar, and collapsible done and
/// archived groups.
fn open_subchats(src : Source, r : ChatRef) -> Unit {
  let opened = fn() {
    match @sfbase.chat_view_now(src, r) {
      Some(cv) => cv.opened
      None => []
    }
  }
  @sf.panel_nodes(
    tr("web-pages.chat.subchats"),
    from=Unanchored,
    tall=0.62,
    hugs=true,
    grows=true,
    head_end=fn(e) { @sfpages.subchats_counts_node(e, opened) },
    fn(v, close) { subchats_sheet_node(v, src, r, opened, close) },
  )
}

///|
fn subchats_sheet_node(v : @view.View, src : Source, r : ChatRef, opened : () -> Array[@sfbase.OpenedChat], close : () -> Unit) -> Unit {
  let subchats = @signals.computed(fn(_) { @sfpages.led_subchats(opened()) })
  // Folded until pressed; the finished ones led with, the latest until pressed (one each for done and archived)
  let done_open : @signals.Signal[Bool] = @signals.signal(false)
  let archived_open : @signals.Signal[Bool] = @signals.signal(false)
  let done_more : @signals.Signal[Bool] = @signals.signal(false)
  let archived_more : @signals.Signal[Bool] = @signals.signal(false)
  let search_field = @ui.Field::new()
  let query : @signals.Signal[String] = @signals.signal("")
  let search_focused : @signals.Signal[Bool] = @signals.signal(false)
  let query_trimmed = fn() { query.get().trim().to_owned() }
  let search_active = fn() { query_trimmed() != "" || search_focused.get() }
  let search_res = @signals.computed(fn(_) {
    @sfpages.subchats_search_results(Some(src), Some(r), fn() { subchats.get() }, false, query_trimmed())
  })
  let lead_kind = @signals.computed(fn(_) { @sfpages.subchats_lead_kind(subchats.get()) })
  let more_now = fn() {
    match lead_kind.get() {
      1 => done_more.get()
      2 => archived_more.get()
      _ => false
    }
  }
  let toggle_more = fn() {
    let m = if lead_kind.untracked() == 2 { archived_more } else { done_more }
    m.set(!m.untracked())
  }
  let done_group = SubchatsGroupOpen::{ open: done_open }
  let archived_group = SubchatsGroupOpen::{ open: archived_open }
  let rows = @signals.computed(fn(_) {
    let filtering = query_trimmed() != ""
    let hits = if filtering { search_res.get().0 } else { [] }
    subchats_sheet_rows(subchats.get(), done_open.get(), archived_open.get(), more_now(), filtering, hits)
  })
  v.reacts(at_start=false, fn() { (rows.get().length(), search_active(), query_trimmed()) }, fn(_) { @sf.panel_reshaped_node(v) }) |> ignore
  // (已完成 folding under those at work, 已归档 under those or the done ones: both folded, they share one card)
  let folds_done = fn() { lead_kind.get() == 0 && subchats.get().iter().any(fn(o) { @sfpages.subchat_is_done(o) }) }
  let folds_archived = fn() { lead_kind.get() != 2 && subchats.get().iter().any(fn(o) { o.archived }) }
  let shared = fn() { folds_done() && !done_open.get() && folds_archived() }
  let sheet = SubchatsSheet::{
    subchats: fn() { subchats.get() },
    hits: fn() { search_res.get().0 },
    reading: fn() { search_res.get().1 },
    search_field,
    query,
    search_focused,
    search_active,
    more_now,
    toggle_more,
    done_group,
    archived_group,
    shared,
    close,
  }
  @sf.panel_list_node(v, fn() { rows.get() }, fn(b, row) { subchats_sheet_row_node(b, row, sheet) }, est=subchats_row_est)
  |> ignore
  // (the last card's foot concentric with the sheet's: every row but the empty state's on a card)
  v.show(
    at_once=true,
    fn() {
      let rs = rows.get()
      !(rs.get(0) is Some(SubchatsEmpty)) && !(rs.get(1) is Some(SubchatsSearchEmpty))
    },
    fn(f) { @sf.style_node(f, fn() { @sf.panel_card_last_node(f) }) },
  )
}

///|
/// A folding group of the sheet: whether it is open (folded until pressed).
priv struct SubchatsGroupOpen {
  open : @signals.Signal[Bool]
}

///|
/// What a row of the sheet reads: its sub-chats, search state/hits, whether the finished ones it leads with show past
/// the latest and the press that turns that, its folding groups, and what closes it.
priv struct SubchatsSheet {
  subchats : () -> Array[@sfbase.OpenedChat]
  hits : () -> Array[@sfbase.SubchatHit]
  reading : () -> Bool
  search_field : @ui.Field
  query : @signals.Signal[String]
  search_focused : @signals.Signal[Bool]
  search_active : () -> Bool
  more_now : () -> Bool
  toggle_more : () -> Unit
  done_group : SubchatsGroupOpen
  archived_group : SubchatsGroupOpen
  // (both folding groups folded: one card for the two heads, 已完成's its top, 已归档's the rest)
  shared : () -> Bool
  close : () -> Unit
}

///|
let subchats_row_est : Double = 56.0

///|
/// A folding group's head in the sheet (已完成, 已归档), under the card it leads with: on a card of its own, 10 under the
/// one above it, unless `on_last` (已归档 under a folded 已完成 on that one's card: no room between); the piece of it
/// `piece()` says, a hairline under it while `line()` (rows of the card under it). Muted, so what folds stays under
/// what is led with: its mark in the rows' 16 wide column and its words (Ui) muted till pointed at or open, its count
/// and a chevron down to open it in place, up to fold it.
fn subchats_sheet_group_head_node(
  b : @view.View,
  label : () -> String,
  icon : String,
  count : () -> Int,
  group : SubchatsGroupOpen,
  on_last : () -> Bool,
  piece : () -> @sf.CardPiece,
  line : () -> Bool,
) -> Unit {
  b.box(fn(slot) {
    @sf.style_node(slot, fn() { info_fill })
    slot.box(fn(gap) {
      gap.height(By(fn() { Some(if on_last() { 0.0 } else { 10.0 }) })).shrink(Is(0.0)) |> ignore
      gap.reacts(on_last, fn(_) { gap.resizes() |> ignore }, at_start=false) |> ignore
    })
    |> ignore
    @sf.card_piece_node(slot, piece, fn(k) {
      @sf.action_box_node(
        k,
        label,
        fn(_) { group.open.set(!group.open.untracked()) },
        expanded=fn() { group.open.get() },
        fn(h) {
          @sf.style_node(h, fn() { @sf.quiet_row_middle })
          h.radius(Is(@sf.quiet_row_corner)) |> ignore
          @sf.hover_ground_node(h)
          let lit = fn() { @sf.lit_node(h) }
          let hot = fn() { lit() || group.open.get() }
          h.box(fn(d) {
            d.width(Is(Some(16.0))).lines_up(Is(Some(Middle))).lies_along(Is(Middle)).shrink(Is(0.0)) |> ignore
            @sf.icon_node(d, icon, 14.0, By(fn() { if hot() { @sf.theme().p.text } else { @sf.theme().p.muted } })) |> ignore
          })
          |> ignore
          @sf.words_node(h, label, fn() { if hot() { job_name } else { subchats_sec_title } })
          .grow(Is(1.0))
          .shrink(Is(1.0))
          .basis(Is(Some(0.0)))
          .min_width(Is(Some(0.0)))
          |> ignore
          h.box(fn(end) {
            @sf.style_node(end, fn() { subchats_fold_left }, in_row=true)
            end.shrink(Is(0.0)) |> ignore
            @sf.words_node(end, fn() { count().to_string() }, fn() { subchats_archived_count_words }) |> ignore
            @sf.icon_node(
              end,
              "",
              14.0,
              By(fn() { if lit() { @sf.theme().p.text } else { @sf.theme().p.subtle } }),
              name_now=fn() { if group.open.get() { "chevron-up" } else { "chevron-down" } },
            )
            |> ignore
          })
          |> ignore
        },
      )
      |> ignore
      k.show(at_once=true, line, fn(l) { @sf.style_node(l, fn() { subchats_head_rule }) })
    })
  })
  |> ignore
}

///|
/// The foot of the card the sheet leads with where finished ones past the latest are (展开其余 N 个 / 收起其余 N 个):
/// a hairline, then a row as the card's (quiet_row_middle) with its chevron in the marks' column and its words where
/// the titles start.
fn subchats_sheet_more_node(b : @view.View, sheet : SubchatsSheet) -> Unit {
  let past = fn() {
    let (_, n) = @sfpages.subchats_lead((sheet.subchats)(), false)
    n
  }
  let words = fn() { @sfpages.subchats_more_words(past(), (sheet.more_now)()) }
  @sf.card_piece_node(b, fn() { @sf.CardFoot }, fn(k) {
    k.box(fn(l) { @sf.style_node(l, fn() { subchats_more_line }) }) |> ignore
    @sf.action_box_node(k, words, fn(_) { (sheet.toggle_more)() }, expanded=sheet.more_now, fn(h) {
      @sf.style_node(h, fn() { @sf.quiet_row_middle })
      h.radius(Is(@sf.quiet_row_corner)) |> ignore
      @sf.hover_ground_node(h)
      h.box(fn(d) {
        d.width(Is(Some(16.0))).lines_up(Is(Some(Middle))).lies_along(Is(Middle)).shrink(Is(0.0)) |> ignore
        @sf.icon_node(
          d,
          "",
          14.0,
          By(fn() { if @sf.lit_node(h) { @sf.theme().p.text } else { @sf.theme().p.subtle } }),
          name_now=fn() { if (sheet.more_now)() { "chevron-up" } else { "chevron-down" } },
        )
        |> ignore
      })
      |> ignore
      @sf.words_node(h, words, fn() { if @sf.lit_node(h) { subchats_fold_hot } else { subchats_fold_words } }) |> ignore
    })
    |> ignore
  })
}

///|
fn subchats_sheet_row_node(b : @view.View, row : SubchatSheetRow, sheet : SubchatsSheet) -> Unit {
  let subchats = sheet.subchats
  match row {
    SubchatsSearch =>
      b.box(fn(sw) {
        @sf.style_node(sw, fn() { subchats_sheet_search_wrap })
        let field_view = @sf.search_input_node(
          sw,
          sheet.search_field,
          fn() { tr("web-pages.chat.subchatsSearch") },
          at=Side,
          edited=fn(s) { sheet.query.set(s) },
          cleared=fn() { sheet.query.set("") },
          escape=fn() {
            if sheet.search_field.text() != "" {
              sheet.search_field.set("")
              sheet.query.set("")
              true
            } else {
              false
            }
          },
        )
        field_view.reacts(fn() { field_view.focused() }, fn(f) { sheet.search_focused.set(f) })
        match b.scroll_holding() {
          Some(sc) => sc.tucks(sw, fn() { 0.0 }, kept=fn() { !(sheet.search_active)() })
          None => ()
        }
      })
      |> ignore
    SubchatsEmpty =>
      b.box(fn(n) {
        @sf.style_node(n, fn() { @sf.panel_words_in_node(n).then(jobs_none) })
        @sf.words_node(n, fn() { tr("web-pages.chat.subchatsNone") }, fn() { jobs_none_words }) |> ignore
      })
      |> ignore
    SubchatsSearchEmpty =>
      b.box(fn(n) {
        @sf.style_node(n, fn() { @sf.panel_words_in_node(n).then(jobs_none) })
        @sf.words_node(
          n,
          fn() {
            if (sheet.reading)() {
              tr("web-pages.chat.subchatsSearching")
            } else {
              tr("web-pages.chat.subchatsNoMatch")
            }
          },
          fn() { jobs_none_words },
        )
        |> ignore
      })
      |> ignore
    SubchatsSearchHit(key) => {
      let hit_now = @signals.computed(fn(_) { (sheet.hits)().iter().find_first(fn(h) { subchat_sheet_key(h.opened) == key }) })
      let piece_now = @signals.computed(fn(_) {
        let hs = (sheet.hits)()
        match hs.search_by(fn(h) { subchat_sheet_key(h.opened) == key }) {
          Some(i) => @sf.card_piece_of(i, hs.length())
          None => @sf.CardWhole
        }
      })
      @sf.card_piece_node(b, fn() { piece_now.get() }, fn(k) {
        subchat_sheet_item_node(
          k,
          fn() {
            match hit_now.get() {
              Some(h) => Some(h.opened)
              None => None
            }
          },
          sheet.close,
          found_text=fn() {
            match hit_now.get() {
              Some(h) => h.found_text
              None => ""
            }
          },
        )
      })
    }
    SubchatsMore => subchats_sheet_more_node(b, sheet)
    SubchatsDoneHead =>
      subchats_sheet_group_head_node(
        b,
        fn() { tr("web-pages.chat.subchatsDone") },
        "check",
        fn() {
          let mut n = 0
          for o in subchats() {
            if @sfpages.subchat_is_done(o) {
              n += 1
            }
          }
          n
        },
        sheet.done_group,
        fn() { false },
        fn() { if sheet.done_group.open.get() || (sheet.shared)() { @sf.CardTop } else { @sf.CardWhole } },
        fn() { sheet.done_group.open.get() || (sheet.shared)() },
      )
    SubchatsArchivedHead =>
      subchats_sheet_group_head_node(
        b,
        fn() { tr("web-pages.chat.subchatsArchived") },
        "archive",
        fn() {
          let mut n = 0
          for o in subchats() {
            if o.archived {
              n += 1
            }
          }
          n
        },
        sheet.archived_group,
        sheet.shared,
        fn() {
          match ((sheet.shared)(), sheet.archived_group.open.get()) {
            (true, true) => @sf.CardBetween
            (true, false) => @sf.CardFoot
            (false, true) => @sf.CardTop
            (false, false) => @sf.CardWhole
          }
        },
        fn() { sheet.archived_group.open.get() },
      )
    SubchatsOne(group_kind, key) => {
      // (the card it is on: what the sheet leads with, the press at its foot one more piece of it where it shows; or
      // an open folding group's)
      let group = fn() -> (Array[@sfbase.OpenedChat], Int) {
        match group_kind {
          0 => {
            let (lead, past) = @sfpages.subchats_lead(subchats(), (sheet.more_now)())
            (lead, if past > 0 { 1 } else { 0 })
          }
          1 => (subchats().filter(fn(o) { @sfpages.subchat_is_done(o) }), 0)
          _ => (subchats().filter(fn(o) { o.archived }), 0)
        }
      }
      // (a folding group's rows the rest of its head's card: that head its top, or, 已归档 sharing 已完成's card, the
      // two heads)
      let headed = fn() {
        match group_kind {
          0 => 0
          1 => 1
          _ => if (sheet.shared)() { 2 } else { 1 }
        }
      }
      let item_now = @signals.computed(fn(_) { group().0.iter().find_first(fn(o) { subchat_sheet_key(o) == key }) })
      let piece_now = @signals.computed(fn(_) {
        let (g, foot) = group()
        let h = headed()
        match g.search_by(fn(o) { subchat_sheet_key(o) == key }) {
          Some(i) => @sf.card_piece_of(i + h, g.length() + foot + h)
          None => @sf.CardWhole
        }
      })
      @sf.card_piece_node(b, fn() { piece_now.get() }, fn(k) {
        subchat_sheet_item_node(k, fn() { item_now.get() }, sheet.close)
      })
    }
  }
}

///|
fn subchat_sheet_item_node(
  k : @view.View,
  item : () -> @sfbase.OpenedChat?,
  close : () -> Unit,
  found_text? : () -> String = fn() { "" },
) -> Unit {
  let title = fn() {
    match item() {
      Some(o) => o.chat.title
      None => ""
    }
  }
  let state_text = fn() {
    let ft = found_text()
    if ft != "" {
      ft
    } else {
      match item() {
        Some(o) => @sfpages.subchat_row_state_text(o)
        None => ""
      }
    }
  }
  let is_archived = fn() {
    match item() {
      Some(o) => o.archived
      None => false
    }
  }
  @sf.quiet_row_node(
    k,
    title,
    look=subchats_sheet_row_look,
    press=fn() {
      match @signals.untracked(item) {
        Some(o) => {
          close()
          @sfbase.open_page(Chat(o.chat))
        }
        None => ()
      }
    },
    fn(row) {
      row.box(fn(line) {
        @sf.style_node(line, fn() { info_more_line }, in_row=true)
        line.box(fn(d) {
          d.width(Is(Some(16.0))).lines_up(Is(Some(Middle))) |> ignore
          @sf.quiet_first_line(d)
          d.pick(at_once=true, fn() { @sfpages.subchat_mark_kind(item()) }, fn(m, kind) {
            match kind {
              0 => @sf.state_dot_node(m, size=8.0, breathes=true, fn() { "live" })
              1 => @sf.state_dot_node(m, size=8.0, breathes=true, fn() { "restart" })
              2 => @sf.state_dot_node(m, size=8.0, breathes=false, fn() { "fail" })
              3 => @sf.icon_node(m, "archive", 14.0, By(fn() { @sf.theme().p.muted })) |> ignore
              4 => @sf.icon_node(m, "check", 14.0, By(fn() { @sf.theme().p.green_ink })) |> ignore
              _ => @sf.icon_node(m, "spawned", 14.0, By(fn() { @sf.theme().p.muted })) |> ignore
            }
          })
        })
        |> ignore
        line.box(fn(w) {
          @sf.style_node(w, fn() { subchats_sheet_words }, in_row=true)
          w.grow(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
          @sf.words_node(w, title, fn() { if is_archived() { job_name_off } else { job_name } }).allow_ellipsis(Is(true)) |> ignore
          w.show(at_once=true, fn() { state_text() != "" }, fn(st) {
            @sf.words_node(st, state_text, fn() { subchats_sheet_state }).allow_ellipsis(Is(true)) |> ignore
          })
        })
        |> ignore
        line.box(fn(c) {
          @sf.quiet_first_line(c)
          @sf.row_chevron_node(c)
        })
        |> ignore
      })
      |> ignore
    },
  )
  |> ignore
}

///|
// kept across runs: a value (no field of it changes)
let subchats_sheet_row_look : @ui.Style = @sf.quiet_row_style.then(@ui.css("py=S2 align=ACenter"))

///|
// kept across runs: a value (no field of it changes)
let subchats_sheet_words : @ui.Style = @ui.css("gap=SPx")

///|
// kept across runs: a value (no field of it changes)
let subchats_sheet_state : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let subchats_more_line : @ui.Style = @sf.rule_line.then(@ui.css("mx=S2_5 mb=S1"))

///|
// kept across runs: a value (no field of it changes)
let subchats_sheet_search_wrap : @ui.Style = @ui.css("w=Full pb=S2").then(@ui.style(px=@sf.room_of(@sf.panel_card_in)))

///|
// kept across runs: a value (no field of it changes)
let subchats_head_rule : @ui.Style = @sf.rule_line.then(@ui.css("mx=S2_5"))

///|
// kept across runs: a value (no field of it changes)
let subchats_sec_title : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Muted, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let subchats_fold_left : @ui.Style = @ui.css("row gap=S1_5 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let subchats_fold_words : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let subchats_fold_hot : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=Fg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let subchats_archived_count_words : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=Muted, tabular=true, wrap=false)

///|
/// The chat's services and jobs to come while they are read (in their bones): made-up ones, two services and a job.
fn jobs_sample() -> Array[Json] {
  let job = fn(i : Int, service : Bool, n : Int) -> Json {
    { "id": Json::string("sample" + i.to_string()), "service": Json::boolean(service), "name": Json::string(@sf.sample_words(n)), "tone": "up" }
  }
  [job(0, true, 6), job(1, true, 8), job(2, false, 7)]
}

///|
/// Words as the job's sheet sets them (an old view's words of a size, a weight and a wrap said alone, as nodes): `size`
/// as the theme has it, on lines of the theme's line to it (or `line` points), the face's own letters.
fn job_words(size : Double, weight? : Int = 400, wrap? : Bool = true, line? : Double = 0.0) -> @view.WordsLook {
  { size, weight, line: if line > 0.0 { line } else { @ui.tree_theme().text_line * size }, wrap, tracking: @view.letters_own, balance: false, max_lines: 0 }
}

///|
/// Words in node `parent`, `words` as they are now, set `look` in `ink`.
fn job_words_node(parent : @view.View, words : () -> String, look : () -> @view.WordsLook, ink : () -> Int64) -> Unit {
  parent.box(fn(w) { w.words(By(words)).words_look(By(look)).ink(By(ink)) |> ignore }) |> ignore
}

///|
/// Pieces of words in node `parent` (an old view's rich words), `runs` as they are now, set `look` in `ink` where a
/// piece says no ink of its own; on one line, cut short where they run past it (a job's words are its agent's).
fn job_runs_node(parent : @view.View, runs : () -> Array[@ui.Run], look : () -> @view.WordsLook, ink : () -> Int64) -> Unit {
  parent.box(fn(w) {
    w.words_runs(By(runs), look=@signals.untracked(look)).words_look(By(look)).ink(By(ink)).allow_ellipsis(By(fn() { !look().wrap })) |> ignore
  })
  |> ignore
}

///|
/// The line under a job's name (job_meta's, as a node) in `parent`: its state's word in its dot's colour's ink, what it
/// said in the ink, the rest muted, `size`, on one line; the job as it is now.
fn job_meta_node(parent : @view.View, job : () -> Json?, size : Double) -> Unit {
  job_runs_node(
    parent,
    fn() {
      let j = job()
      let t = @sf.theme()
      let word = match text(j, "tone") {
        "up" | "live" => t.p.green_ink
        "restart" => t.p.warn_ink
        "fail" => t.p.red
        _ => 0L
      }
      items(j, "meta").map(fn(p) {
        let pv = Some(p)
        match text(pv, "kind") {
          "word" => @ui.span(text(pv, "text"), color=word)
          "notice" => @ui.span(text(pv, "text"), color=t.p.text)
          _ => @ui.span(text(pv, "text"))
        }
      })
    },
    fn() { job_words(size, wrap=false) },
    fn() { @sf.theme().p.muted },
  )
}

///|
/// A job, from the chat's sheet (JobBody), as nodes of the window's tree made once in `v` (open_job's panel's body): its
/// name and how it stands, what it said or its output as it grows (a service has only its output), stopped from here
/// while it runs; while it is read, or once it is gone, words saying so. What it shows follows the core's `chatJobs` as
/// it changes.
fn job_node(v : @view.View, src : Source, r : ChatRef, id : String) -> Unit {
  let topic = fn() { src.topic("chatJobs", chat_params(r)).get().value }
  let job = fn() -> Json? {
    for j in items(topic(), "jobs") {
      if text(Some(j), "id") == id {
        return Some(j)
      }
    }
    None
  }
  v.show(fn() { job() is None }, fn(w) {
    @sf.style_node(w, fn() { @sf.panel_words_in_node(w) })
    job_words_node(
      w,
      fn() { if topic() is Some(_) { tr("android-misc.jobs.gone") } else { tr("common.reading") } },
      fn() { job_words(@sf.theme().t.meta) },
      fn() { @sf.theme().p.muted },
    )
  })
  v.show(fn() { job() is Some(_) }, fn(d) {
    // (the room the sheet leaves it, whatever it holds: from none, never pushed past it by a long output)
    d.grow(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
    job_detail_node(d, src, r, id, job)
  })
}

///|
/// A job, what it is, said and wrote (job_detail's, as nodes), in `v`: its dot, name and line, its command, then what it
/// said or its output (a service's output alone), and stopping it while it runs; `j` the job as it is now. In its
/// panel (open_job), on its words' line (the wide frame's 任务 tab has its own: sfdesk's jobs.mbt).
fn job_detail_node(v : @view.View, src : Source, r : ChatRef, id : String, j : () -> Json?) -> Unit {
  let service = flag(@signals.untracked(j), "service")
  // (what it said (0) or its output (1), as the sheet was opened to show; a service's, its output)
  let tab = @signals.signal(if service { 1 } else { dui.job_tab })
  let running = fn() { text(j(), "state") == "running" }
  // (on its panel's words' line, clear of an untitled dialog's close button)
  v.box(fn(h) {
    @sf.style_node(h, fn() { @sf.panel_words_in_node(h).then(@sf.untitled_clear_node(h)).then(job_head_at) })
    h.box(fn(b) {
      @sf.style_node(b, fn() { job_head_dot })
      @sf.state_dot_node(b, fn() { text(j(), "tone") }, size=job_dot_side, breathes=true)
    })
    |> ignore
    h.box(fn(b) {
      @sf.style_node(b, fn() { job_head_words }, in_row=true)
      job_words_node(b, fn() { text(j(), "name") }, fn() { job_words(@sf.theme().t.title, weight=600) }, fn() {
        @sf.theme().p.text
      })
      job_meta_node(b, j, job_meta_size)
    })
    |> ignore
  })
  |> ignore
  v.box(fn(col) {
    @sf.style_node(col, fn() { @sf.panel_words_in_node(col).then(job_body_at) })
    // (filling what its head leaves (job_body_at's h=Full, an old view's Fill), from none: never pushed past it by a
    // long output)
    col.height(Is(None)).grow(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
    col.show(fn() { text(j(), "command").trim(chars=" \n").to_owned() != "" }, fn(w) {
      job_runs_node(
        w,
        fn() { [@ui.span(text(j(), "command"), mono=true)] },
        fn() { job_words(@sf.theme().t.caption, line=job_code_line) },
        fn() { @sf.theme().p.muted },
      )
    })
    if !service {
      col.box(fn(line) {
        line.row(Is(true)) |> ignore
        line.box(fn(slot) {
          @sf.segmented_node(
            slot,
            fn() { [tr("android-misc.jobs.notices"), tr("android-misc.jobs.output")] },
            fn() { tab.get() },
            fn(i) {
              dui.job_tab = i
              tab.set(i)
            },
          )
        })
        |> ignore
      })
      |> ignore
    }
    col.show(fn() { tab.get() == 0 }, fn(said) { job_said_node(said, src, r, id, j) })
    col.show(fn() { tab.get() == 1 }, fn(out) { job_output_node(out, src, r, id) })
    col.show(running, fn(b) { job_stop_node(b, src, r, id, j) })
  })
  |> ignore
}

///|
/// What a job said (job_detail's notices, as nodes) in `v`: its notices each with its clock, or words saying it said
/// none; then what it wrote last and when (the core's `jobLog`, its last line), as they are now.
fn job_said_node(v : @view.View, src : Source, r : ChatRef, id : String, j : () -> Json?) -> Unit {
  // (in the column of what it shows, 14 apart as that has them: none of its own)
  v.gap(Is(job_body_gap)) |> ignore
  v.box(fn(list) {
    @sf.style_node(list, fn() { job_notices })
    list.show(fn() { items(j(), "notices").length() == 0 }, fn(none) {
      @sf.style_node(none, fn() { job_no_notices })
      job_words_node(none, fn() { tr("android-misc.jobs.noNotices") }, fn() { job_words(@sf.theme().t.meta) }, fn() {
        @sf.theme().p.muted
      })
    })
    list.each(
      fn() { items(j(), "notices").mapi(fn(i, n) { (i, n) }) },
      fn(x) { x.0 },
      fn(row, n) {
        let nv = fn() { Some(n.get().1) }
        @sf.style_node(row, fn() { job_notice })
        row.box(fn(b) {
          b.width(Is(Some(job_clock_w))) |> ignore
          job_words_node(b, fn() { text(nv(), "clock") }, fn() { job_words(@sf.theme().t.meta, wrap=false) }, fn() {
            @sf.theme().p.subtle
          })
        })
        |> ignore
        row.box(fn(b) {
          @sf.style_node(b, fn() { job_notice_words }, in_row=true)
          job_words_node(b, fn() { text(nv(), "text") }, fn() { job_words(@sf.theme().t.ui) }, fn() { @sf.theme().p.text })
        })
        |> ignore
      },
    )
  })
  |> ignore
  let last = @sfbase.hold(src, @sfbase.jobs_scope(r.station), "jobLog", {
    "station": Json::string(r.station),
    "job": Json::string(id),
    "lines": Json::number(1.0),
  })
  let said = fn() {
    let l = last.get().value
    match l {
      Some(Object(_)) => text(l, "said")
      _ => text(j(), "outputSaid")
    }
  }
  v.show(fn() { said() != "" }, fn(b) {
    @sf.style_node(b, fn() { job_last })
    job_words_node(b, said, fn() { job_words(@sf.theme().t.caption) }, fn() { @sf.theme().p.subtle })
    b.show(fn() { text(last.get().value, "last") != "" }, fn(w) {
      job_runs_node(
        w,
        fn() { [@ui.span(text(last.get().value, "last"), mono=true)] },
        fn() { job_words(@sf.theme().t.caption, wrap=false) },
        fn() { @sf.theme().p.muted },
      )
    })
  })
}

///|
/// A job's output (job_detail's, as nodes) in `v`: its last lines (the core's `jobLog`) in a terminal's colours as the
/// core says them, a block a line by its number, on a faint ground, scrolling, from its end and kept there as lines come
/// while it is there (a line more makes its block alone); words saying it wrote nothing where it did not, a spinner
/// while it is read.
fn job_output_node(v : @view.View, src : Source, r : ChatRef, id : String) -> Unit {
  let params : Map[String, Json] = {
    "station": Json::string(r.station),
    "job": Json::string(id),
    "lines": Json::number(job_output_most),
  }
  let log = @sfbase.hold(src, @sfbase.jobs_scope(r.station), "jobLog", params)
  // (its lines as they are now, each by its number, in the theme's ink: job_output_of's, a line's runs worked out as it
  // comes and kept while it is the same)
  let lines : @signals.Computed[@sfbase.TermLines?] = @signals.computed(fn(_) {
    guard log.get().value is Some(Object(_)) else { return None }
    let t = @sf.theme()
    Some(@sfbase.job_output_of(src, params, t.p.text, t.dark))
  })
  @sf.style_node(v, fn() { job_output_box.then(@ui.style(bg=Data(@sf.alpha(@sf.theme().p.text, job_output_ink)))) })
  // (filling what is left of its column (job_output_box's h=Full, an old view's Fill), at least its min_h, from none:
  // as tall whatever it holds, its lines scrolling in it)
  v.height(Is(None)).grow(Is(1.0)).basis(Is(Some(0.0))) |> ignore
  v.show(fn() { lines.get() is None }, fn(w) {
    @sf.style_node(w, fn() { job_output_wait })
    @sf.spinner_node(w, size=job_output_spin) |> ignore
  })
  v.show(fn() { lines.get() is Some(_) }, fn(b) {
    // (the room its box has, whatever it holds: from none, not from how tall all its lines are, an old list's)
    b.grow(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
    let scroll = @view.Scroll::list()
    // (its blocks are its lines by their numbers: a line more one block more, those there before as they were; where
    // it wrote nothing, one saying so, `job_output_none`)
    let keys = fn() {
      match lines.get() {
        Some(l) if l.lines.is_empty() => [job_output_none]
        Some(l) => l.lines.map(fn(x) { x.n })
        None => []
      }
    }
    let first = fn() {
      match lines.get() {
        Some(l) if !l.lines.is_empty() => l.lines[0].n
        _ => job_output_none
      }
    }
    b.scrolls_window(
      scroll,
      keys,
      // (a line more comes in the list's one way, what is over it going up with it as its end is followed)
      fn(row, n) {
        // (its own line's runs, read again only as that line changes: the same while it is the same line)
        let runs = @signals.computed(
          fn(_) {
            if n == job_output_none {
              [@ui.span(tr("android-misc.jobs.noOutput"), mono=true)]
            } else {
              lines.get().bind(fn(l) { l.at(n) }).map_or([], fn(l) { l.runs })
            }
          },
          same=fn(a, b) { physical_equal(a, b) },
        )
        let top = @signals.computed(fn(_) { first() == n }, same=fn(a, b) { a == b })
        @sf.style_node(row, fn() {
          if top.get() { job_output_first } else { job_output_line }
        })
        job_runs_node(row, fn() { runs.get() }, fn() { job_words(@sf.theme().t.caption, line=job_code_line) }, fn() {
          @sf.theme().p.text
        })
      },
      est=job_code_line,
      slop=@ui.touch_slop(),
      bar=@ui.tree_scroll_bar(),
      // (under its last line the room its first has over it: its foot, drawing nothing)
      foot=fn(f) { f.height(Is(Some(job_output_end))) |> ignore },
      // (Ctx::list's stick_end, the old one's: made at its end, kept there as lines come while it is there, not once
      // scrolled off it; followed again once scrolled back to it)
      follows=fn() { true },
      // (what shows held where it is by none of its lines as more come under them: its end followed, an old list's)
      holds=fn(_) { false },
    )
    |> ignore
  })
}

///|
/// The key of the one block of a job's output that wrote nothing: none of its lines' numbers.
let job_output_none : Int = -1

///|
/// How many of a job's last lines its output shows.
let job_output_most : Double = 300.0

///|
/// Stopping a running job (job_detail's 停止, as a node) in `v`: a pale red capsule across, its stop mark (a spinner
/// while it is asked) and its words; pressed, the core asked to stop it, said so (act's).
fn job_stop_node(v : @view.View, src : Source, r : ChatRef, id : String, j : () -> Json?) -> Unit {
  let skey = "job-stop/" + r.station + "/" + id
  let busy = fn() { doing(skey) }
  v.box(fn(b) {
    @sf.style_node(b, fn() { job_stop.then(@ui.style(bg=Data(@sf.alpha(@sf.theme().p.red, job_stop_ink)))) })
    @sf.rippled_node(
      b,
      fn() {
        if !@signals.untracked(busy) {
          @ui.haptic(Confirm)
          act(
            src,
            fill("android-misc.jobs.stopWhat", [("name", text(@signals.untracked(j), "name"))]),
            skey,
            "job.stop",
            { "station": Json::string(r.station), "id": Json::string(id) },
          )
        }
      },
      (job_stop_h : Double) / 2.0,
      fn() { tr("android-misc.jobs.stop") },
    )
    b.show(busy, fn(s) { @sf.spinner_node(s, size=job_stop_spin) |> ignore })
    b.show(fn() { !busy() }, fn(s) { @sf.icon_node(s, "stop", job_stop_icon, By(fn() { @sf.theme().p.red })) |> ignore })
    job_words_node(b, fn() { tr("android-misc.jobs.stop") }, fn() { job_words(@sf.theme().t.ui, weight=500, wrap=false) }, fn() {
      @sf.theme().p.red
    })
  })
  |> ignore
}

///|
/// A job's head: on its words' line, 4 over it, 14 under, its dot (8 down, on its name's line) and its words 12 apart.
// kept across runs: a value (no field of it changes)
let job_head_at : @ui.Style = @ui.css("row w=Full pt=S1 pb=S3_5 gap=S3 align=AStart")

///|
// kept across runs: a value (no field of it changes)
let job_head_dot : @ui.Style = @ui.css("pt=S2")

///|
// kept across runs: a value (no field of it changes)
let job_head_words : @ui.Style = @ui.css("w=Full")

///|
/// How big the line under a job's name is in its sheet.
let job_meta_size : Double = 12.5

///|
/// What it shows under its head: filling the sheet's room, 24 over its foot, its parts 14 apart.
// kept across runs: a value (no field of it changes)
let job_body_at : @ui.Style = @ui.css("w=Full h=Full pb=S6 gap=S3_5")

///|
let job_body_gap : Double = 14.0

///|
/// The lines of code it shows (its command, its output), 17 apart.
let job_code_line : Double = 17.0

///|
/// Its notices, 12 apart; none, words saying so 20 in and 8 over and under.
// kept across runs: a value (no field of it changes)
let job_notices : @ui.Style = @ui.css("w=Full gap=S3")

///|
// kept across runs: a value (no field of it changes)
let job_no_notices : @ui.Style = @ui.css("px=S5 py=S2")

///|
/// A notice: its clock in a column 48 wide, its words 10 after it.
// kept across runs: a value (no field of it changes)
let job_notice : @ui.Style = @ui.css("row w=Full gap=S2_5")

///|
let job_clock_w : Double = 48.0

///|
// kept across runs: a value (no field of it changes)
let job_notice_words : @ui.Style = @ui.css("w=Full")

///|
/// What it wrote last and when, 2 apart.
// kept across runs: a value (no field of it changes)
let job_last : @ui.Style = @ui.css("w=Full gap=S0_5")

///|
let job_output_min_h : Double = 120.0

///|
/// Its output: filling what is left, 120 at least, 16 round, on the ink at 5%, cut at its corners; its lines 14 in, 12
/// over the first and under the last; a spinner 12 across 14 in and 12 down while it is read.
// kept across runs: a value (no field of it changes)
let job_output_box : @ui.Style = @ui.css("w=Full h=Full radius=Xl1_5 clip").then(@ui.style(min_h=Fixed(job_output_min_h)))

///|
let job_output_ink : Double = 0.05

///|
// kept across runs: a value (no field of it changes)
let job_output_line : @ui.Style = @ui.css("w=Full px=S3_5")

///|
let job_output_end : Double = 12.0

///|
// kept across runs: a value (no field of it changes)
let job_output_first : @ui.Style = job_output_line.then(@ui.style(pt=@sf.room_of(job_output_end)))

///|
// kept across runs: a value (no field of it changes)
let job_output_wait : @ui.Style = @ui.css("px=S3_5 py=S3")

///|
let job_output_spin : Double = 12.0

///|
let job_stop_h : Double = 46.0

///|
/// Stopping it: a capsule across, 46 high, its mark and words 6 apart in its middle, on red at 12%.
// kept across runs: a value (no field of it changes)
let job_stop : @ui.Style = @ui.css("row w=Full radius=Full py=S2 gap=S1_5 align=ACenter justify=JCenter").then(@ui.style(min_h=Fixed(job_stop_h)))

///|
let job_stop_ink : Double = 0.12

///|
let job_stop_spin : Double = 14.0

///|
let job_stop_icon : Double = 16.0

///|
/// A job (job_node): the library's panel, most of the window, dragged between half and nearly all of it; titled 任务
/// while it is not there (read, or gone), its own head (its dot and name) once it is.
fn open_job(src : Source, r : ChatRef, id : String) -> Unit {
  let missing = fn() -> Bool {
    for j in items(src.topic("chatJobs", chat_params(r)).get().value, "jobs") {
      if text(Some(j), "id") == id {
        return false
      }
    }
    true
  }
  @sf.panel_nodes(
    "",
    from=Unanchored,
    tall=0.8,
    grows=true,
    live=fn() { (if missing() { tr("android-misc.jobs.job") } else { "" }, "", "") },
    fn(v, _) { job_node(v, src, r, id) },
  )
}

///|
/// An info row's words (14, the ink, on one line).
// kept across runs: a value (no field of it changes)
let info_words : @ui.TextStyle = @ui.text_style(size=Ui, color=Fg, wrap=false)

///|
/// Opens the chat's letters at their list (the library's panel, most of the window tall, dragged between half and nearly
/// all of it, what it holds nodes of the window's tree made once as it opens: letters_node); its letters held (the
/// core's `chatLetters`) until the chat is left.
fn open_letters(src : Source, r : ChatRef, thread : Double) -> Unit {
  @sfdesk.letters_to_list(r)
  dui.letters_held[r.station + "\u{1}" + r.session] = thread
  @sf.panel_nodes(tr("web-main.letters.title"), from=Unanchored, tall=0.8, hugs=true, grows=true, fn(v, _) {
    letters_node(v, src, r, thread)
  })
}

///|
/// What the letters' sheet holds (in `v`): the list of the chats written with, or the one opened and its letters, each
/// drawn as the chat draws a message, as the wide frame's 往来 tab has them (sfdesk's letters_tab_node, the same part on
/// every screen, in the panel's list, on its words' line); the chat as its view says it now.
fn letters_node(v : @view.View, src : Source, r : ChatRef, thread : Double) -> Unit {
  let tips = @sf.panel_tips_of(v).unwrap_or(@sf.window_tips())
  v.pick(fn() { view_of_chat(src, r).0 is Some(_) }, fn(p, shown) {
    guard shown && @signals.untracked(fn() { view_of_chat(src, r).0 }) is Some(first) else { return }
    @sfdesk.letters_tab_node(p, src, r, thread, fn() { view_of_chat(src, r).0.unwrap_or(first) }, tips, panel=true)
  })
}

///|
/// Opens what was said in the chat besides words (the library's panel, as the letters', what it holds nodes:
/// things_node); 在对话里看 closes it and goes to the message in the chat.
fn open_things(src : Source, r : ChatRef, thread : Double) -> Unit {
  @sf.panel_nodes(tr("web-main.things.title"), from=Unanchored, tall=0.8, grows=true, fn(v, close) {
    @sfpages.things_node(v, src, r, thread, fn(seq) {
      close()
      go_to(r, seq)
    })
  })
}

///|
/// How many pull requests the info names itself (the rest: 全部 N 个).
let info_pulls_most : Int = 3

///|
/// What is between the info's lists (its pull requests', its agents'): as far as they stand from its sides (the user,
/// 2026-11-03: 这个间距又是什么意思).
// kept across runs: a value (no field of it changes)
let info_lists_gap : @ui.Style = @ui.style(h=Fixed(@sf.panel_card_in))

///|
// kept across runs: a value (no field of it changes)
let info_pull_title : @ui.TextStyle = @ui.text_style(size=Ui, color=Fg, wrap=false, w=Cut)

///|
/// The params of a chat's letters (the core's `chatLetters` view).
fn letters_params(r : ChatRef, thread : Double) -> Map[String, Json] {
  { "station": Json::string(r.station), "thread": Json::number(thread) }
}

///|
/// The way back to the chat an agent opened it from (chat_info_body): a row a finger presses, its words in the accent.
// kept across runs: a value (no field of it changes)
let info_opener : @ui.Style = @ui.css("row w=Full min_h=S11 gap=S1_5 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let info_opener_words : @ui.TextStyle = @ui.text_style(size=Body, color=AccentText, wrap=false, w=Cut)

///|
/// The row of the chats its agent made, in the chat's sheet (chat_info_body): how many, its words a row's.
// kept across runs: a value (no field of it changes)
let info_opened_title : @ui.TextStyle = @ui.text_style(size=Body, color=Fg, wrap=false, w=Full)

///|
/// What an info row says at its end (how many, a pull request's number): 13, muted, on one line.
// kept across runs: a value (no field of it changes)
let info_meta : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)
