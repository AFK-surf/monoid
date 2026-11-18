// The 任务 tab beside a chat on 中屏 and 大屏 (JobsTab; jobs.mbt's jobs_tab till 2026-11-15) as nodes of the window's
// tree, made once as the tab comes in front (panel_node.mbt side_panel_node, tape_view.mbt tape_side_node), each part
// bound to the core's `chatJobs` as it changes: its services and jobs a page's list (View::scrolls_window) at most
// 45% of the tab tall; a service up or restarting pressed opens its own tab; a job picked (jobs_own's `picked`, the
// first while none is) a card across the tab's foot, its dot, name, state, what it said or its output (jobs_own's
// `output`, the choice kept across jobs), its stop while it runs, its command; what it said with the time of day and
// its last output, or its output as it grows (the core's `jobLog`), each a list of its own. Laid out by the old view's
// styles (jobs.mbt), its dots and rows' parts the popover's (jobs_pop_node.mbt).

///|
/// One of the rows of the 任务 tab's list: a group's head (services, jobs), a service, a job.
#derive(Eq, Hash)
priv enum JobsTabRow {
  JobsHead(Bool)
  JobsService(String)
  JobsJob(String)
}

///|
/// Chat `r`'s 任务 tab in `v` (as large as the panel leaves it under its bar): none, words saying so; else its list and
/// the job picked under it, a card laid across its foot as `foot_card` says (in the panel's corners). A service pressed
/// opens its own tab (`service`, by its job's id). Its tips in `tips`.
fn jobs_tab_node(
  v : @view.View,
  src : Source,
  r : ChatRef,
  tips : @sf.TipLayer,
  foot_card : () -> @ui.Style,
  service : (String) -> Unit,
) -> Unit {
  let station = r.station
  let view = fn() { src.topic("chatJobs", chat_params(r)).get().value }
  let jobs = fn() { items(view(), "jobs") }
  let job_of = fn(id : String) { jobs().iter().find_first(fn(j) { text(Some(j), "id") == id }) }
  let of_kind = fn(services : Bool) {
    jobs().filter(fn(j) { flag(Some(j), "service") == services }).map(fn(j) { text(Some(j), "id") })
  }
  // (the job picked: the one jobs_own says where it is one of the jobs, else the first)
  let picked = @signals.computed(
    fn(_) {
      let plain = of_kind(false)
      let p = jobs_own.picked.get()
      if plain.contains(p) {
        p
      } else {
        plain.get(0).unwrap_or("")
      }
    },
    same=fn(a, b) { a == b },
  )
  v.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
  v.pick(fn() { jobs().length() == 0 }, fn(p, none) {
    p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
    if none {
      @sf.empty_node(p, fn(e) { @sf.words_node(e, fn() { @sf.t("web-main.jobs.noneInChat") }, fn() { jobs_empty_words }) |> ignore })
      return
    }
    p.box(fn(tab) {
      @sf.style_node(tab, fn() { jobs_tab_box })
      tab.height(Is(None)).grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
      let keys = fn() {
        let out : Array[JobsTabRow] = []
        for services in [true, false] {
          let ids = of_kind(services)
          if ids.length() > 0 {
            out.push(JobsHead(services))
            for id in ids {
              out.push(if services { JobsService(id) } else { JobsJob(id) })
            }
          }
        }
        out
      }
      // (as tall as its rows and heads are, its padding with them, 45% of the tab at most, scrolling past that: as it
      // gives way to the job picked under it, which is never less than the rest of the tab)
      let tall = fn() {
        let ks = keys()
        let heads = ks.filter(fn(k) { k is JobsHead(_) }).length()
        (ks.length() - heads).to_double() * job_row_h + heads.to_double() * jobs_head_h + jobs_list_room
      }
      tab.box(fn(room) {
        @sf.style_node(room, fn() { jobs_tab_list_room })
        room.height(By(fn() { Some(tall()) })).shrink(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        // (a row's block taken by the next of its kind (a group's head, a service, a job) to show as it no more does,
        // its key that one's)
        room.scrolls_reused(
          @view.Scroll::list(),
          keys,
          shape=jobs_tab_row_shape,
          fn(row, k) {
            // (its sides the list's, 8 in (jobs_tab_list); 4 under what is over it in its group, its head 6 under the
            // group over it (jobs_group, jobs_group_after))
            let over = fn() {
              match k() {
                JobsHead(false) => if of_kind(true).length() > 0 { jobs_group_gap } else { 0.0 }
                JobsHead(true) => 0.0
                _ => jobs_row_gap
              }
            }
            @sf.style_node(row, fn() { jobs_tab_row_room.then(@ui.style(pt=@sf.room_of(over()))) })
            let id = fn() {
              match k() {
                JobsService(id) | JobsJob(id) => id
                JobsHead(_) => ""
              }
            }
            let job = fn() { job_of(id()) }
            // (its kind, which never changes for a block: jobs_tab_row_shape's)
            match @signals.untracked(k) {
              JobsHead(_) =>
                row.box(fn(h) {
                  @sf.style_node(h, fn() { jobs_head_box })
                  @sf.words_node(h, fn() { @sf.t(if k() is JobsHead(true) { "web-main.jobs.services" } else { "web-main.jobs.jobs" }) }, fn() {
                    jobs_head_words
                  })
                  |> ignore
                })
                |> ignore
              JobsService(_) => {
                // (one up or restarting opens its tab; else it does nothing)
                let opens = fn() { text(job(), "tone") == "up" || text(job(), "tone") == "restart" }
                jobs_tab_row(row, job, fn() { if opens() { "arrow-right" } else { "" } }, fn() { false }, opens, fn() {
                  // (its tab opens on the job as this row has it: job_now)
                  let id = id()
                  job_handed(station, id, job())
                  service(id)
                })
              }
              JobsJob(_) =>
                jobs_tab_row(row, job, fn() { "" }, fn() { picked.get() == id() }, fn() { true }, fn() {
                  jobs_own.picked.set(id())
                })
            }
          },
          est=job_row_h,
          slop=@ui.touch_slop(),
          bar=@ui.tree_scroll_bar(),
          head=fn(h) { h.height(Is(Some(jobs_list_over))) |> ignore },
          foot=fn(f) { f.height(Is(Some(jobs_list_under))) |> ignore },
        )
        |> ignore
      })
      |> ignore
      // the job picked, a card of its own each (what it shows scrolled from its top)
      tab.pick(fn() { picked.get() }, fn(d, id) {
        d.grow(Is(1.0)).shrink(Is(0.0)).min_height_share(Is(Some(1.0 - jobs_list_most))) |> ignore
        if id != "" {
          job_detail_node(d, src, station, id, fn() { job_of(id) }, tips, foot_card)
        }
      })
    })
    .grow(Is(1.0))
    .min_height(Is(Some(0.0)))
    |> ignore
  })
}

///|
/// Which block of the 任务 tab's list a row takes as it comes to show (View::scrolls_reused's `shape`): a group's head,
/// a service, a job, each its own make.
fn jobs_tab_row_shape(k : JobsTabRow) -> Int {
  match k {
    JobsHead(_) => 0
    JobsService(_) => 1
    JobsJob(_) => 2
  }
}

///|
/// A job's row in the 任务 tab (job_row's, not inset) in `row`: its dot, its name, what it is up to, `end`'s icon at its
/// end where it says one; picked while `selected` (the picked ground); while `press` says so, the pointer's ground on it
/// and `on_press` as it is pressed, else nothing to the hand (a service that opens nothing).
fn jobs_tab_row(
  row : @view.View,
  job : () -> Json?,
  end : () -> String,
  selected : () -> Bool,
  press : () -> Bool,
  on_press : () -> Unit,
) -> Unit {
  row.box(fn(b) {
    @sf.style_node(b, fn() { if press() { job_row_style } else { job_row_static } })
    b
    .ground(By(fn() { if selected() { @ui.tree_theme().color(Selected) } else { 0L } }))
    .says(By(fn() { Some(@view.said(Button, label=text(job(), "name"), selected=selected())) }))
    |> ignore
    @sf.hover_ground_node(b, on=press)
    @sf.presses_node(b, on_press, on=press)
    b.box(fn(on) {
      @sf.style_node(on, fn() { job_row_on }, in_row=true)
      on.box(fn(d) {
        @sf.style_node(d, fn() { job_dot_room }, in_row=true)
        jobs_pop_dot(d, fn() { text(job(), "tone") })
      })
      |> ignore
      on.box(fn(w) {
        @sf.style_node(w, fn() { job_text }, in_row=true)
        @sf.words_node(w, fn() { text(job(), "name") }, fn() { if text(job(), "tone") == "off" { job_name_off } else { job_name } })
        .allow_ellipsis(Is(true))
        |> ignore
        jobs_pop_meta(w, job)
      })
      |> ignore
    })
    |> ignore
    b.show(fn() { end() != "" }, fn(e) {
      @sf.style_node(e, fn() { job_end }, in_row=true)
      @sf.icon_node(e, "", 16.0, By(fn() { if press() && @sf.lit_node(b) { @sf.theme().p.text } else { @sf.theme().p.subtle } }), name_now=end)
      |> ignore
    })
  })
  |> ignore
}

///|
/// A job picked in the 任务 tab (job_detail's) in `v`, job `id` of `station` as `job` says it now: on the paper across
/// the tab's foot (in its corners), its dot, name and state, the choice of what it said and its output, its stop while it
/// runs (round, in its corner, concentric with it); its command under them, whole in its tip; then what it said with the
/// time of day and its last output, or its output as it grows.
fn job_detail_node(
  v : @view.View,
  src : Source,
  station : String,
  id : String,
  job : () -> Json?,
  tips : @sf.TipLayer,
  foot_card : () -> @ui.Style,
) -> Unit {
  let running = fn() { text(job(), "state") == "running" }
  v.box(fn(card) {
    @sf.style_node(card, fn() { job_detail_box.then(foot_card()).then(job_detail_at(running())) })
    card.height(Is(None)).grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
    card.box(fn(h) {
      @sf.style_node(h, fn() { job_detail_head })
      h.box(fn(d) { jobs_pop_dot(d, fn() { text(job(), "tone") }) }) |> ignore
      @sf.words_node(h, fn() { text(job(), "name") }, fn() { job_detail_name }).allow_ellipsis(Is(true)) |> ignore
      @sf.words_node(h, fn() { text(job(), "detail") }, fn() { job_detail_state }).allow_ellipsis(Is(true)) |> ignore
      h.box(fn(g) { @sf.style_node(g, fn() { job_detail_grow }, in_row=true) }) |> ignore
      // (as wide as its options where the head has the room, the name and the state cut short first; where even then it
      // has not, it gives way too, its options fitted to what is left: seg_node's)
      h.box(fn(choice) {
        @sf.style_node(choice, fn() { job_detail_choice }, in_row=true)
        choice.min_width(Is(Some(0.0))) |> ignore
        choice.box(fn(slot) {
          // (the web's Segmented, as wide as its options, whatever the panel's width: as the old view's)
          @sf.seg_node(
            slot,
            fn() { [@sf.t("web-main.jobs.notices"), @sf.t("web-main.jobs.output")] },
            fn() { if jobs_own.output.get() { 1 } else { 0 } },
            fn(i) { jobs_own.output.set(i == 1) },
          )
          |> ignore
        })
        |> ignore
      })
      |> ignore
      h.show(running, fn(s) {
        s.shrink(Is(0.0)) |> ignore
        let doing = fn() { job_stopping(src, station, job()) }
        s.box(fn(b) {
          @sf.style_node(b, fn() { job_detail_stop }, in_row=true)
          @sf.hover_ground_node(b)
          b.says(Is(Some(@view.said(Button, label=@sf.t("web-main.jobs.stop"))))) |> ignore
          @sf.presses_node(b, fn() {
            if !@signals.untracked(doing).0 {
              job_stop(src, station, @signals.untracked(job))
            }
          })
          @sf.tip_node(tips, b, fn() { @sf.t("web-main.jobs.stop") }) |> ignore
          b.pick(fn() { doing().0 || doing().1 is Some(_) }, fn(k, busy) {
            if busy {
              @sfpages.doing_mark_node(k, fn() { doing().0 }, fn() { doing().1 }, tips~, size=job_stop_mark)
            } else {
              @sf.icon_node(k, "stop", 16.0, By(fn() { if @sf.lit_node(b) { @sf.theme().p.text } else { @sf.theme().p.muted } }))
              |> ignore
            }
          })
        })
        |> ignore
      })
    })
    |> ignore
    card.show(fn() { text(job(), "command") != "" }, fn(c) {
      @sf.style_node(c, fn() { job_detail_command })
      // (its words in the room its padding leaves, 4 under the head: what is drawn apart from the choice over it)
      c.box(fn(w) {
        w
        .words_runs(By(fn() { [@ui.span(text(job(), "command"), mono=true)] }))
        .words_look(By(fn() { @ui.style_words(job_command_words) }))
        .ink(By(fn() { @ui.style_ink(job_command_words) }))
        .allow_ellipsis(Is(true))
        |> ignore
      })
      |> ignore
      @sf.tip_node(tips, c, fn() { text(job(), "command") }, within=true, repeats=true) |> ignore
    })
    card.pick(fn() { jobs_own.output.get() }, fn(p, output) {
      p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
      if output {
        job_output_node(p, src, station, id)
      } else {
        p.box(fn(n) {
          @sf.style_node(n, fn() { job_detail_notices })
          n.height(Is(None)).grow(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
          job_notices_node(n, job)
        })
        |> ignore
        p.box(fn(l) {
          @sf.style_node(l, fn() { job_detail_last })
          l.shrink(Is(0.0)) |> ignore
          jobs_pop_last(l, src, station, job)
        })
        |> ignore
      }
    })
  })
  |> ignore
}

///|
/// What a job said, newest first, each with the time of day in the row's words (job_notices' `clock`), in `v`: a list
/// of its own, a notice a block; none said, how a job says something.
fn job_notices_node(v : @view.View, job : () -> Json?) -> Unit {
  let notices = fn() { items(job(), "notices") }
  // (a notice's block taken by the next to show as it no more does, its number that one's: words for none made once)
  v.scrolls_reused(
    @view.Scroll::list(),
    fn() {
      let n = notices().length()
      if n == 0 {
        [-1]
      } else {
        Array::makei(n, fn(i) { i })
      }
    },
    reuses=fn(i) { i >= 0 },
    fn(row, i) {
      // (words for none: never taken, so its number is the one it was made for)
      if @signals.untracked(i) < 0 {
        row
        .words_runs(Is([
          @ui.span(@sf.t("web-main.jobs.noNotices.before")),
          @ui.span("stillfail-job notify", mono=true),
          @ui.span(@sf.t("web-main.jobs.noNotices.after")),
        ]))
        .words_look(By(fn() { @ui.style_words(job_quiet_words) }))
        .ink(By(fn() { @ui.style_ink(job_quiet_words) }))
        |> ignore
        return
      }
      let nv = fn() { notices().get(i()) }
      @sf.style_node(row, fn() { if i() > 0 { job_notice_after } else { job_notice } })
      row.box(fn(a) {
        @sf.style_node(a, fn() { job_notice_clock }, in_row=true)
        a.shrink(Is(0.0)) |> ignore
        @sf.words_node(a, fn() { text(nv(), "clock") }, fn() { job_notice_time_ui }) |> ignore
      })
      |> ignore
      @sf.words_node(row, fn() { text(nv(), "text") }, fn() { job_notice_words_ui })
      .grow(Is(1.0))
      .basis(Is(Some(0.0)))
      .min_width(Is(Some(0.0)))
      |> ignore
    },
    est=job_notice_est,
    slop=@ui.touch_slop(),
    bar=@ui.tree_scroll_bar(),
  )
  |> ignore
}

///|
/// A job's output (Output: its last 400 lines, the core's `jobLog`) in `v`, in a terminal's colours as the core says
/// them, a block a line by its number, following its end while it is scrolled there; words saying it wrote nothing
/// where it did not, its line of bones while it is read.
fn job_output_node(v : @view.View, src : Source, station : String, id : String) -> Unit {
  let params : Map[String, Json] = {
    "station": Json::string(station),
    "job": Json::string(id),
    "lines": Json::number(job_output_lines),
  }
  let log = @sfbase.hold(src, @sfbase.jobs_scope(station), "jobLog", params)
  // (its lines as they are now, each by its number, in the theme's ink, a line's runs worked out as it comes and kept
  // while it is the same: job_output_of's)
  let lines : @signals.Computed[@sfbase.TermLines?] = @signals.computed(fn(_) {
    guard log.get().value is Some(Object(_)) else { return None }
    let t = @sf.theme()
    Some(@sfbase.job_output_of(src, params, t.p.text, t.dark))
  })
  v.box(fn(b) {
    @sf.style_node(b, fn() { job_output_box })
    b.height(Is(None)).grow(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
    b.pick(
      fn() {
        match lines.get() {
          None => 0
          Some(l) if l.lines.is_empty() => 1
          Some(_) => 2
        }
      },
      fn(p, what) {
        p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        match what {
          0 => @sf.wait_line_node(p, fn() { "" }) |> ignore
          1 => @sf.words_node(p, fn() { @sf.t("web-main.jobs.noOutput") }, fn() { job_output_none }) |> ignore
          _ =>
            // (a line's block taken by the next line to show as it no more does, its number that one's: hundreds of
            // lines scrolled through a screen's few blocks)
            p.scrolls_reused(
              @view.Scroll::list(),
              fn() { lines.get().map_or([], fn(l) { l.lines.map(fn(x) { x.n }) }) },
              fn(row, n) {
                // (its own line's runs, read again only as that line changes or the block is taken for another)
                let runs = @signals.computed(fn(_) { lines.get().bind(fn(l) { l.at(n()) }).map_or([], fn(l) { l.runs }) }, same=fn(
                  a,
                  b,
                ) {
                  physical_equal(a, b)
                })
                row
                .words_runs(By(fn() { runs.get() }))
                .words_look(By(fn() { @ui.style_words(job_output_words) }))
                .ink(By(fn() { @ui.style_ink(job_output_words) }))
                |> ignore
              },
              est=job_output_line,
              slop=@ui.touch_slop(),
              bar=@ui.tree_scroll_bar(),
              // (made at its end, kept there as lines come while it is there, not once scrolled off it: an old list's
              // stick_end)
              follows=fn() { true },
              holds=fn(_) { false },
            )
            |> ignore
        }
      },
    )
  })
  |> ignore
}

///|
/// The 任务 tab's list: a row's sides (jobs_tab_list's 8), 4 over its first (jobs_list_over) and 8 under its last
/// (jobs_list_under), a row 4 under what is over it in its group (jobs_group's gap), a group's head 6 under the group
/// over it (jobs_group_after).
// kept across runs: a value (no field of it changes)
let jobs_tab_row_room : @ui.Style = @ui.css("w=Full px=S2")

///|
let jobs_list_over : Double = 4.0

///|
let jobs_list_under : Double = 8.0

///|
let jobs_row_gap : Double = 4.0

///|
let jobs_group_gap : Double = 6.0

///|
/// What a job said after its newest, 12 under the one over it (job_notices_clock's gap); how tall each is taken to be
/// till it is laid out.
// kept across runs: a value (no field of it changes)
let job_notice_after : @ui.Style = job_notice.then(@ui.css("pt=S3"))

///|
let job_notice_est : Double = 32.0

///|
/// The stop's mark while it is asked or failed (doing_mark's, not inline: 14).
let job_stop_mark : Double = 14.0
