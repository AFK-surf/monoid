// A job's parts every list of them shares (中屏 and 大屏's 服务和后台任务 popover, the 任务 tab beside a chat, 待处理's
// and the sidebar foot's 运行中): the tone its dot is drawn in (@sf.state_dot_node, breathing), and what it said, each
// notice its time then its words, the newest first; none said, how a job says something. Laid out by the old view's
// styles (sfdesk's jobs.mbt).

///|
/// The tone a job's dot is drawn in (@sf.state_dot_node's job tones: alive breathing slowly round it, restarting
/// breathing to .35 and back, failed red), of the core's `tone`: one it does not know the strong line's grey (off).
pub fn job_dot_tone(tone : String) -> String {
  match tone {
    "up" | "live" | "restart" | "fail" => tone
    _ => "off"
  }
}

///|
/// A job's dot (jobDot): 8 across.
pub let job_dot_across : Double = 8.0

///|
/// What a job said, newest first, each with how long ago (job_notices', the popover's), `most` at most, in `body`: none
/// said, how a job says something.
pub fn job_notices_node(body : @view.View, job : () -> Json?, most? : Int = 3) -> Unit {
  let notices = fn() {
    let all = items(job(), "notices")
    if all.length() > most {
      all[:most].to_owned()
    } else {
      all
    }
  }
  body.pick(fn() { notices().length() == 0 }, fn(p, none) {
    if none {
      p.box(fn(w) { job_notices_none_node(w) }) |> ignore
      return
    }
    p.box(fn(list) {
      @sf.style_node(list, fn() { job_notices_list })
      list.each(fn() { Array::makei(notices().length(), fn(i) { i }) }, fn(i) { i }, fn(n, at) {
        let i = at.untracked()
        let nv = fn() { notices().get(i) }
        n.box(fn(line) {
          @sf.style_node(line, fn() { job_notice_row })
          job_notice_node(line, fn() { text(nv(), "ago") }, fn() { text(nv(), "text") }, false)
        })
        |> ignore
      })
    })
    |> ignore
  })
}

///|
/// What a job said, newest first, each with the time of day in the row's words (job_notices' `clock`, the 任务 tab's),
/// in `v`: a list of its own, a notice a block; none said, how a job says something.
pub fn job_notices_list_node(v : @view.View, job : () -> Json?) -> Unit {
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
        job_notices_none_node(row)
        return
      }
      let nv = fn() { notices().get(i()) }
      @sf.style_node(row, fn() { if i() > 0 { job_notice_after } else { job_notice_row } })
      job_notice_node(row, fn() { text(nv(), "clock") }, fn() { text(nv(), "text") }, true)
    },
    est=job_notice_est,
    slop=@ui.touch_slop(),
    bar=@ui.tree_scroll_bar(),
  )
  |> ignore
}

///|
/// Words in `w` saying a job has said nothing yet, and how it says something (`stillfail-job notify`, in mono).
fn job_notices_none_node(w : @view.View) -> Unit {
  w
  .words_runs(Is([
    @ui.span(@sf.t("web-main.jobs.noNotices.before")),
    @ui.span("stillfail-job notify", mono=true),
    @ui.span(@sf.t("web-main.jobs.noNotices.after")),
  ]))
  .words_look(By(fn() { @ui.style_words(job_quiet_words) }))
  .ink(By(fn() { @ui.style_ink(job_quiet_words) }))
  |> ignore
}

///|
/// A notice in `line` (a row, its own style its list's): its `time` in a column of its own, then its `words`, taking
/// what the line leaves them, wrapped. By the time of day (`clock`, the 任务 tab's: a 44 column, its words the ui's
/// size), else by how long ago (64 at least, as wide as its words where they are wider: at the system's words set to
/// 1.3 「10 分钟前」 is 70, cut in the old view's 64 column; at the default size the same 64).
fn job_notice_node(line : @view.View, time : () -> String, words : () -> String, clock : Bool) -> Unit {
  line.box(fn(a) {
    if clock {
      @sf.style_node(a, fn() { job_notice_clock_col }, in_row=true)
    } else {
      a.width(Is(None)).min_width(Is(Some(job_notice_ago_w))) |> ignore
    }
    a.shrink(Is(0.0)) |> ignore
    @sf.words_node(a, time, fn() { job_notice_time_words }) |> ignore
  })
  |> ignore
  @sf.words_node(line, words, fn() { if clock { job_notice_ui_words } else { job_notice_meta_words } })
  .grow(Is(1.0))
  .basis(Is(Some(0.0)))
  .min_width(Is(Some(0.0)))
  |> ignore
}

///|
/// What a job said (jobNotices): 6 apart; a notice its time and its words 8 apart, from their tops.
// kept across runs: a value (no field of it changes)
let job_notices_list : @ui.Style = @ui.css("w=Full gap=S1_5")

///|
// kept across runs: a value (no field of it changes)
let job_notice_row : @ui.Style = @ui.css("row w=Full gap=S2 align=AStart")

///|
/// What a job said after its newest in the 任务 tab, 12 under the one over it (job_notices_clock's gap); how tall each
/// is taken to be till it is laid out.
// kept across runs: a value (no field of it changes)
let job_notice_after : @ui.Style = job_notice_row.then(@ui.css("pt=S3"))

///|
let job_notice_est : Double = 32.0

///|
/// How wide a notice's time is at least (job_notice_ago's S16); by the time of day its column (3.4em of 13, about 44).
// kept across runs: a value
let job_notice_ago_w : Double = 64.0

///|
// kept across runs: a value (no field of it changes)
let job_notice_clock_col : @ui.Style = @ui.css("w=S11")

///|
/// Its time (12, subtle), its words (12 in the popover, 13 in the tab), words for none (12, muted).
// kept across runs: a value (no field of it changes)
let job_notice_time_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let job_notice_meta_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Fg, w=@sf.grow)

///|
// kept across runs: a value (no field of it changes)
let job_notice_ui_words : @ui.TextStyle = @ui.text_style(size=Ui, color=Fg, w=@sf.grow)

///|
// kept across runs: a value (no field of it changes)
let job_quiet_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, w=Full)
