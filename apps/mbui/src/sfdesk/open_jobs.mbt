// The services and background jobs left up a long while (an hour), across the chats of the workspace's stations, so
// none is forgotten running: web services, background jobs, simulators and views of screens, each under its heading,
// three of a group and the rest folded under 还有 N 个; nothing at all while there are none. The viewer's own first
// (the core's `groups`, what lights the bell); where others are members, theirs and the shared ones (`otherGroups`)
// folded under 其他运行中 · N at the foot, opened by a press. Each leads where it is (a simulator or a view its screen,
// a service its page or its tab beside its chat, a task its chat; one of none leads nowhere) and stops from here, its
// row gone at once (back if that could not be done). The core puts them together (its `longJobs` view); shown in 待处理
// on every screen (attention.mbt) and in the list the sidebar's foot opens where the rail has no bell (lists.mbt).

///|
/// The groups opened past their first three, by the workspace and the group's key (open_jobs_group_key).
let open_jobs_all : Map[String, Bool] = Map([])

///|
/// Those stopped here, by `<station>/<id>` (open_job_key): left out at once, back where the stop could not be done; let
/// go of as the core no longer lists them.
let open_jobs_gone : @sf.LiveMap[String, Bool] = @sf.LiveMap::new()

///|
/// The workspaces whose others' (其他运行中) are open, by id: folded until pressed.
let open_jobs_others : @sf.LiveMap[String, Bool] = @sf.LiveMap::new()

///|
fn open_jobs_reset() -> Unit {
  open_jobs_all.clear()
  open_jobs_gone.clear()
  open_jobs_others.clear()
}

///|
/// Rows shown before the rest folds under 还有 N 个 (SHOWN).
let open_jobs_shown : Int = 3

///|
/// One left up long by its station and id: what it is kept gone by.
fn open_job_key(job : Json?) -> String {
  text(job, "station") + "/" + text(job, "id")
}

///|
/// A group's key among those opened past their first three (open_jobs_all): its workspace's, the viewer's own or the
/// others' (`of`), its own.
fn open_jobs_group_key(ws : String, of : String, key : String) -> String {
  ws + "/" + of + "/" + key
}

///|
/// The groups under `of` (`groups`, the viewer's own; `otherGroups`, the others') of workspace `w` as they show: those
/// stopped here left out, a group's count (its head's ` · N`) said again of what is left; a group with none left out.
fn open_jobs_groups(src : Source, w : Workspace, of : String) -> Array[Json] {
  let out : Array[Json] = []
  for g in items(src.topic("longJobs", long_jobs_asked(w.id)).get().value, of) {
    let gv = Some(g)
    let all = items(gv, "jobs")
    let left = all.filter(fn(j) { !open_jobs_gone.contains(open_job_key(Some(j))) })
    if left.length() == 0 {
      continue
    }
    if left.length() == all.length() {
      out.push(g)
      continue
    }
    let head = text(gv, "head")
    let was = " · " + all.length().to_string()
    let now = if head.has_suffix(was) {
      head.exact_view(end=head.length() - was.length()).to_owned() + " · " + left.length().to_string()
    } else {
      head
    }
    out.push({ "key": Json::string(text(gv, "key")), "head": Json::string(now), "jobs": Json::array(left) })
  }
  out
}

///|
/// How many those groups hold.
fn open_jobs_count(groups : Array[Json]) -> Int {
  groups.fold(init=0, fn(n, g) { n + items(Some(g), "jobs").length() })
}

///|
/// The others' fold's words, of the `n` of them shown: the core's (`otherText`) while it counts them all, else said
/// again (some stopped here).
fn open_jobs_others_text(src : Source, w : Workspace, n : Int) -> String {
  let value = src.topic("longJobs", long_jobs_asked(w.id)).get().value
  if number(value, "otherCount").to_int() == n && text(value, "otherText") != "" {
    text(value, "otherText")
  } else {
    @sf.t("web-main.jobs.others", args=[("n", n.to_string())])
  }
}

///|
/// Whether any of the workspace's left up long shows (theirs or the others'), those stopped here aside.
fn open_jobs_any(src : Source, w : Workspace) -> Bool {
  open_jobs_groups(src, w, "groups").length() > 0 || open_jobs_groups(src, w, "otherGroups").length() > 0
}

///|
/// Where a row leads: a simulator or a view of a screen to that screen; a terminal to it; a web service to its page, or beside its chat in
/// its own tab where the page has a side panel; a task to its chat (its 任务 tab beside it where there is one); one in
/// no chat nowhere (its row presses nothing, only its stop).
priv enum OpenJobGoes {
  ToScreen(String, String, String)
  ToTerminal(String, String)
  ToService(String, String, ChatRef?)
  ToChat(ChatRef, String)
  Nowhere
}

///|
fn open_job_goes(job : Json?) -> OpenJobGoes {
  let station = text(job, "station")
  let screen = text(field(job, "stop"), "screen")
  let terminal = text(field(job, "stop"), "terminal")
  if screen != "" {
    ToScreen(station, screen, text(job, "name"))
  } else if terminal != "" {
    ToTerminal(station, terminal)
  } else if flag(job, "service") {
    ToService(station, text(job, "id"), @sfbase.job_chat(job))
  } else {
    match @sfbase.job_chat(job) {
      Some(r) => ToChat(r, text(job, "id"))
      None => Nowhere
    }
  }
}

///|
/// A row pressed: the list closed (`close`), then where it leads (open_job_goes). Beside a chat where the page has a
/// side panel (the shell's `beside_room`), else the page itself, over Home: back comes to Home.
fn open_job_go(src : Source, job : Json?, close : () -> Unit) -> Unit {
  let beside = @signals.untracked(@sfbase.shell.val.beside_room)
  match open_job_goes(job) {
    ToScreen(station, screen, name) => {
      close()
      @sfbase.open_screen(station, screen, Some(name))
    }
    ToTerminal(station, terminal) => {
      close()
      @sfbase.open_terminal(station, terminal, "", "")
    }
    ToService(station, id, chat) => {
      close()
      match chat {
        Some(r) if beside => {
          open_chat_ref(r)
          side_tab_open(src, r, "service:" + id)
        }
        _ => @sfbase.open_page(Service(station, id))
      }
    }
    ToChat(r, id) => {
      close()
      if beside {
        open_chat_ref(r)
        pick_job(id)
        side_tab_open(src, r, "jobs")
      } else {
        @sfbase.open_page(Chat(r))
      }
    }
    Nowhere => ()
  }
}

///|
/// One left up long stopped from its row: gone from the list at once, the core asked; back, said failed, where that
/// could not be done.
fn open_job_stop_now(src : Source, job : Json?) -> Unit {
  let gone = open_job_key(job)
  let (call, params, _) = long_stop(text(job, "station"), job)
  open_jobs_gone[gone] = true
  act(src, @sf.t("web-main.jobs.stopWhat", args=[("name", text(job, "name"))]), "", call, params, failed=fn() {
    open_jobs_gone.remove(gone)
  })
}

///|
/// Its stop's word: the core's (关闭 a simulator, 断开 a view), else 停止.
fn open_job_stop_word(job : Json?) -> String {
  match text(field(job, "stop"), "word") {
    "" => @sf.t("web-main.jobs.stop")
    word => word
  }
}

///|
/// What its stop is read out as: the word and what it stops.
fn open_job_stop_label(job : Json?) -> String {
  match text(field(job, "stop"), "word") {
    "" => @sf.t("web-main.jobs.stopNamed", args=[("name", text(job, "name"))])
    word => word + " " + text(job, "name")
  }
}

///|
/// Its second line: where it is, then how long it has been up.
fn open_job_where_age(job : Json?) -> String {
  let where_ = text(job, "whereText")
  let age = text(job, "age")
  if where_ != "" && age != "" {
    where_ + " · " + age
  } else if where_ != "" {
    where_
  } else {
    age
  }
}

///|
/// A chat gone to from beside the list (a job's row): its page the one open, the chats' place under it; on the tape
/// shown in the page (show_page), the chat already open too.
fn open_chat_ref(r : ChatRef) -> Unit {
  @sfbase.show_chosen()
  match app.nav.top() {
    Chat(open) if open.station == r.station && open.session == r.session => return
    _ => ()
  }
  @sfbase.history_push()
  @sfbase.nav_over_home([Chat(r)])
}

///|
/// The list the sidebar's foot opens (openJobsPop): 280 wide, at most 420 high.
let open_jobs_pop_w : Double = 280.0

///|
let open_jobs_pop_most : Double = 420.0

///|
/// The groups (openJobs), each a small panel's group (@sf.panel_group: its heading's room over it).
// kept across runs: a value (no field of it changes)
let open_jobs_box : @ui.Style = @ui.css("w=Full")

///|
/// A job (openJob): its row's room in its group.
// kept across runs: a value (no field of it changes)
let open_job_box : @ui.Style = @ui.css("w=Full")

///|
/// Its row (openJobRow) in 待处理: 5 over and under, 10 at either side, as 待处理's own rows (attention.mbt att_item):
/// its dot in the 16 column theirs are in, its words where their titles start; its parts 10 apart, from its first line
/// down (what is beside its two lines on the first), concentric with the panel; on the hover grey where it leads
/// somewhere and the pointer is on it.
// kept across runs: a value (no field of it changes)
let open_job_row : @ui.Style = @ui.css("row w=Full px=S2_5 py=S1_25 gap=S2_5 radius=Inner align=AStart")

///|
/// Its row in a list of them alone (the sidebar foot's 运行中): its dot's column 6 in, so the dot stands where its
/// group's heading's words start.
// kept across runs: a value (no field of it changes)
let open_job_row_alone : @ui.Style = @ui.css("row w=Full pl=S1_5 pr=S2_5 py=S1_25 gap=S2_5 radius=Inner align=AStart")

///|
/// The dot, in the 16 column the icons of the rows under it take (openJobMark), across its name's line's middle (the
/// line's height given where it is made): in a list of them alone in its middle (open_job_row_alone: where its group's
/// heading's words start); in 待处理 at its start, where its groups' headings' words start, as 待处理's own rows' dots
/// (att_mark).
// kept across runs: a value (no field of it changes)
let open_job_mark : @ui.Style = @ui.css("w=S4 align=ACenter justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
let open_job_mark_start : @ui.Style = @ui.css("w=S4 align=AStart justify=JCenter")

///|
/// Its name over where it is (openJobText).
// kept across runs: a value (no field of it changes)
let open_job_text : @ui.Style = @ui.style(w=@sf.grow)

///|
/// Its name's line: the name and its stop's room, across its middle.
// kept across runs: a value (no field of it changes)
let open_job_line : @ui.Style = @ui.css("row w=Full align=ACenter")

///|
/// Its name (openJobName: the ui's size, cut short).
// kept across runs: a value (no field of it changes)
let open_job_name : @ui.TextStyle = @ui.text_style(size=Ui, color=Fg, wrap=false, max_lines=1, w=Cut)

///|
/// Where it is and how long it has been up (openJobWhere: the meta's size, muted, cut short).
// kept across runs: a value (no field of it changes)
let open_job_where : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false, max_lines=1, w=Cut)

///|
/// Its stop (openJobStop): its word, quiet, 6 at either side, no ground of its own (on its name's line, 10 from the
/// row's end, in its top end corner a ground could not be concentric with the row's); red under the hand.
// kept across runs: a value (no field of it changes)
let open_job_stop : @ui.Style = @ui.css("row px=S1_5 align=ACenter justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
let open_job_stop_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let open_job_stop_lit : @ui.TextStyle = @ui.text_style(size=Meta, color=Danger, wrap=false)

///|
/// 还有 N 个 (openJobsMore: the meta's size, muted, the text's pointed at), its words where a row's are.
// kept across runs: a value (no field of it changes)
let open_jobs_more : @ui.Style = @ui.style(px=S2_5, py=@sf.room_of(@sf.menu_row_over))

///|
// kept across runs: a value (no field of it changes)
let open_jobs_more_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let open_jobs_more_lit : @ui.TextStyle = open_jobs_more_words.then(@ui.text_style(color=Fg))

///|
/// 其他运行中 · N (the others' fold): on its own line under the viewer's own, its words where a group's heading's are
/// (10 in), its chevron after them on that line, 6 over and under; concentric with the panel, the hover grey under the
/// pointer.
// kept across runs: a value (no field of it changes)
let open_jobs_fold : @ui.Style = @ui.css("row w=Full px=S2_5 py=S1_5 gap=S1 align=ACenter radius=Inner")

///|
// kept across runs: a value (no field of it changes)
let open_jobs_fold_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
/// Its chevron's box: as tall as its words' line, the chevron across its middle.
// kept across runs: a value (no field of it changes)
let open_jobs_fold_mark : @ui.Style = @ui.css("align=ACenter justify=JCenter")

///|
/// The chevron (12, muted): right while folded, down while open.
let open_jobs_chevron : Double = 12.0

///|
/// What is stopped here let go of once the core no longer lists it (what it lists again, a simulator booted anew under
/// its id, shows).
fn open_jobs_prune(src : Source, w : Workspace) -> Unit {
  if open_jobs_gone.is_empty() {
    return
  }
  let listed : Map[String, Bool] = Map([])
  let value = src.topic("longJobs", long_jobs_asked(w.id)).get().value
  for of in ["groups", "otherGroups"] {
    for g in items(value, of) {
      for j in items(Some(g), "jobs") {
        listed[open_job_key(Some(j))] = true
      }
    }
  }
  if open_jobs_gone.keys().any(fn(k) { !listed.contains(k) }) {
    open_jobs_gone.retain(fn(k, _) { listed.contains(k) })
  }
}

///|
/// The workspace's long jobs (OpenJobs, open_jobs') as nodes in `v`, in 待处理 on every screen but beside the rail's
/// bell and in the list the sidebar's foot opens: the viewer's own, each group under its heading, three of it and the
/// rest under 还有 N 个 (pressed: all of it); then the others' folded under 其他运行中 · N; nothing while there are
/// none. A row pressed closes what it is in (`close`). Its rows as 待处理's own are, or `alone` (open_job_row_alone).
fn open_jobs_node(v : @view.View, src : Source, w : Workspace, close : () -> Unit, alone? : Bool = false) -> Unit {
  let others = fn() { open_jobs_groups(src, w, "otherGroups") }
  // (what was stopped here let go of as the core no longer lists it)
  v.reacts(fn() { src.topic("longJobs", long_jobs_asked(w.id)).get().value }, fn(_) { open_jobs_prune(src, w) })
  @sf.style_node(v, fn() { open_jobs_box })
  open_jobs_groups_node(v, src, w, "groups", close, alone)
  v.show(fn() { others().length() > 0 }, fn(o) {
    let open = fn() { open_jobs_others.contains(w.id) }
    let label = fn() { open_jobs_others_text(src, w, open_jobs_count(others())) }
    @sf.action_box_node(
      o,
      label,
      fn(_) {
        if open_jobs_others.contains(w.id) {
          open_jobs_others.remove(w.id)
        } else {
          open_jobs_others[w.id] = true
        }
      },
      expanded=open,
      fn(k) {
        @sf.style_node(k, fn() { open_jobs_fold.then(jobs_pop_round) })
        @sf.hover_ground_node(k)
        @sf.words_node(k, label, fn() { open_jobs_fold_words }) |> ignore
        // (its chevron on its words' one line, across its middle)
        k.box(fn(m) {
          @sf.style_node(m, fn() { open_jobs_fold_mark }, in_row=true)
          m.height(By(fn() { Some(@sf.node_sp(m, @ui.tree_theme().text_size(Meta).1)) })) |> ignore
          @sf.icon_node(m, "chevron-right", open_jobs_chevron, By(fn() { @sf.theme().p.muted }), name_now=fn() {
            if open() {
              "chevron-down"
            } else {
              "chevron-right"
            }
          })
          |> ignore
        })
        |> ignore
      },
    )
    |> ignore
    o.show(open, fn(g) { open_jobs_groups_node(g, src, w, "otherGroups", close, alone) })
  })
}

///|
/// The groups under `of` (open_jobs_groups') in `v`, each under its heading, three of it and the rest under 还有 N 个.
fn open_jobs_groups_node(
  v : @view.View,
  src : Source,
  w : Workspace,
  of : String,
  close : () -> Unit,
  alone : Bool,
) -> Unit {
  // (the groups opened past their first three, as open_jobs_all keeps them for the old view's)
  let opened : @signals.Signal[Array[String]] = @signals.signal(open_jobs_all.keys().collect())
  v.each(fn() { open_jobs_groups(src, w, of) }, fn(g) { text(Some(g), "key") }, fn(gb, g) {
    let gv = fn() { Some(g.get()) }
    let key = fn() { open_jobs_group_key(w.id, of, text(gv(), "key")) }
    let list = fn() { items(gv(), "jobs") }
    let shown = fn() {
      let l = list()
      if opened.get().contains(key()) || l.length() <= open_jobs_shown + 1 {
        l
      } else {
        l[:open_jobs_shown].to_owned()
      }
    }
    @sf.panel_group_node(gb, fn() { text(gv(), "head") }, fn(rows) {
      rows.each(shown, fn(j) { open_job_key(Some(j)) }, fn(row, j) { open_job_node(row, src, fn() { Some(j.get()) }, close, alone) })
      rows.show(fn() { shown().length() < list().length() }, fn(m) {
        let label = fn() { @sf.t("web-main.jobs.more", args=[("n", (list().length() - shown().length()).to_string())]) }
        @sf.action_box_node(m, label, fn(_) {
          let k = @signals.untracked(key)
          open_jobs_all[k] = true
          opened.set(opened.untracked() + [k])
        }, fn(b) {
          @sf.style_node(b, fn() { open_jobs_more })
          @sf.words_node(b, label, fn() { if @sf.lit_node(b) { open_jobs_more_lit } else { open_jobs_more_words } }) |> ignore
        })
        |> ignore
      })
    })
  })
}

///|
/// A job (open_job's) as nodes in `parent`, `job` as it is now: its dot in the icons' 16 column on its name's line, its
/// name over where it is and how long it has been up, its stop's word at the end of its name's line, always there on
/// every input. The row leads where it is (open_job_go: pressed, the hover grey under the pointer); one that leads
/// nowhere presses nothing but its stop.
fn open_job_node(parent : @view.View, src : Source, job : () -> Json?, close : () -> Unit, alone : Bool) -> Unit {
  let stop_of = fn() { long_stop(text(job(), "station"), job()) }
  let stopping = fn() {
    let (call, _, on) = stop_of()
    core_doing(src, [call], on)
  }
  let failed = fn() {
    let (call, _, on) = stop_of()
    core_failed(src, [call], on)
  }
  let leads = fn() { !(open_job_goes(job()) is Nowhere) }
  let word = fn() { open_job_stop_word(job()) }
  parent.box(fn(o) {
    @sf.style_node(o, fn() { open_job_box })
    o.box(fn(b) {
      // (pressed where it leads somewhere: a link, its stop in it a button of its own)
      @sf.presses_node(b, fn() { open_job_go(src, @signals.untracked(job), close) }, on=leads)
      @sf.style_node(b, fn() { (if alone { open_job_row_alone } else { open_job_row }).then(jobs_pop_round) })
      b.says(By(fn() { if leads() { Some(@view.said(Link, label=text(job(), "name"))) } else { None } })) |> ignore
      // (the hover grey while the pointer is on it, its stop too, where it leads somewhere)
      @sf.hover_ground_node(b, lit=Some(fn() { leads() && @sf.lit_in_node(o) }))
      // (its dot and its stop on its name's line, as tall as that line is drawn, never across the middle of its two)
      let name_line = fn() { @sf.node_sp(b, @ui.tree_theme().text_size(Ui).1) }
      b.box(fn(m) {
        @sf.style_node(m, fn() { if alone { open_job_mark } else { open_job_mark_start } }, in_row=true)
        m.height(By(fn() { Some(name_line()) })) |> ignore
        @sf.state_dot_node(m, size=@sfpages.job_dot_across, breathes=true, fn() { @sfpages.job_dot_tone(text(job(), "tone")) })
      })
      |> ignore
      b.box(fn(words) {
        @sf.style_node(words, fn() { open_job_text }, in_row=true)
        // (its name's line: the name, cut short where it has not the room, and its stop at its end; where it is under
        // them across the whole of it)
        words.box(fn(line) {
          @sf.style_node(line, fn() { open_job_line })
          @sf.words_node(line, fn() { text(job(), "name") }, fn() { open_job_name })
          .grow(Is(1.0))
          .min_width(Is(Some(0.0)))
          .allow_ellipsis(Is(true))
          |> ignore
          // (its stop at its end, a press of its own in the row's, on that line's middle as the dot is)
          @sf.action_box_node(line, fn() { open_job_stop_label(job()) }, fn(_) {
            if !@signals.untracked(stopping) {
              open_job_stop_now(src, @signals.untracked(job))
            }
          }, fn(k) {
            @sf.style_node(k, fn() { open_job_stop }, in_row=true)
            k.height(By(fn() { Some(name_line()) })) |> ignore
            k.pick(fn() { if stopping() || failed() is Some(_) { 1 } else { 0 } }, fn(p, which) {
              if which == 1 {
                @sfpages.doing_mark_node(p, stopping, failed)
              } else {
                @sf.words_node(p, word, fn() { if @sf.lit_node(k) { open_job_stop_lit } else { open_job_stop_words } }) |> ignore
              }
            })
          })
          |> ignore
        })
        |> ignore
        @sf.words_node(words, fn() { open_job_where_age(job()) }, fn() { open_job_where }).allow_ellipsis(Is(true)) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}
