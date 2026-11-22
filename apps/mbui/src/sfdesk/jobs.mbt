// A chat's web services and background jobs on the desktop: status a small dot
// before the name and a word on the line under it; the chat bar's popover shows what matters now (JobsPopover), the
// 任务 tab beside the chat everything (JobsTab). What a job's dot says, its word, the line under its name and every
// time in words are the core's (its `chatJobs` view, `jobLog`); what is done goes through its calls. The 任务 tab is made
// as nodes (jobs_tab_node.mbt), the popover too (jobs_pop_node.mbt); the old view's parts here are what is left of it.

///|
/// What the jobs keep of their own, each a signal (what the nodes read: jobs_pop_node, jobs_tab_node): the job open in
/// the popover ("" none), the one picked in the 任务 tab ("" the first), whether the tab shows its output (else what it
/// said).
priv struct JobsOwn {
  open : @signals.Signal[String]
  picked : @signals.Signal[String]
  output : @signals.Signal[Bool]
}

///|
let jobs_own : JobsOwn = {
  open: @signals.signal("", same=fn(a, b) { a == b }),
  picked: @signals.signal("", same=fn(a, b) { a == b }),
  output: @signals.signal(false, same=fn(a, b) { a == b }),
}

///|
fn jobs_reset() -> Unit {
  jobs_own.open.set("")
  jobs_own.picked.set("")
  jobs_own.output.set(false)
}

///|
/// The job picked in the 任务 tab (a row of the popover, a search's find).
pub fn pick_job(id : String) -> Unit {
  jobs_own.picked.set(id)
}

///|
/// The job opened in the popover (a screen's fixture).
pub fn open_job_pop(id : String) -> Unit {
  jobs_own.open.set(id)
}

///|
/// Stopping a job from the page (useStopJob, JobStop): its agent is told who did; turning, not pressed again, while
/// it is being stopped wherever that was asked (the core's `doing`), a red mark a few seconds when that failed.
fn job_stopping(src : Source, station : String, job : Json?) -> (Bool, String?) {
  let on = [("station", station), ("id", text(job, "id"))]
  (core_doing(src, ["job.stop"], on), core_failed(src, ["job.stop"], on))
}

///|
fn job_stop(src : Source, station : String, job : Json?) -> Unit {
  act(
    src,
    @sf.t("web-main.jobs.stopWhat", args=[("name", text(job, "name"))]),
    "",
    "job.stop",
    { "station": Json::string(station), "id": Json::string(text(job, "id")) },
  )
}

///|
/// How much of a job's output is read (Output: 400), how tall a line of it is (11.5 on 1.6, about 18), how much of
/// the tab its list may take (jobsTabList: 45%).
let job_output_lines : Double = 400.0

///|
let job_output_line : Double = 18.0

///|
let jobs_list_most : Double = 0.45

///|
/// How tall a job's row stands (its two lines and its padding, 4 apart), a group's head, the list's padding, clearing.
let job_row_h : Double = 54.0

///|
let jobs_head_h : Double = 30.0

///|
let jobs_list_room : Double = 18.0

///|
/// The dot on the name's line (20 high): 6 down.
// kept across runs: a value (no field of it changes)
let job_dot_room : @ui.Style = @ui.css("pt=S1_5")

///|
/// A job's row (jobRow): its dot and words 12 apart, 6 by 8 in (12 at its start); round as an option, the pointer's
/// ground on it, the picked ground while picked; in the popover in by the panel's words (10), round with it.
// kept across runs: a value (no field of it changes)
let job_row_style : @ui.Style = @ui.css((
  #|row w=Full py=S1_5 pl=S3 pr=S2 gap=S3 align=AStart radius=Xl hovered{bg=Hover} selected{bg=Selected}
))

///|
// kept across runs: a value (no field of it changes)
let job_row_inset : @ui.Style = @ui.css((
  #|row w=Full py=S1_5 px=S2_5 gap=S3 align=AStart radius=Inner hovered{bg=Hover} selected{bg=Hover}
))

///|
// kept across runs: a value (no field of it changes)
let job_row_static : @ui.Style = @ui.css("row w=Full py=S1_5 pl=S3 pr=S2 gap=S3 align=AStart radius=Xl")

///|
// kept across runs: a value (no field of it changes)
let job_row_static_inset : @ui.Style = @ui.css("row w=Full py=S1_5 px=S2_5 gap=S3 align=AStart radius=Inner")

///|
/// Its dot and words; over, its name stepped back to the muted grey (data-off), not faded (at 55% its words were 2.3 to
/// 1: mbui ui/contrast.mbt).
// kept across runs: a value (no field of it changes)
let job_row_on : @ui.Style = @ui.style(row=true, w=@sf.grow, gap=S3, align=AStart)

///|
// kept across runs: a value (no field of it changes)
let job_text : @ui.Style = @ui.style(w=@sf.grow, gap=SPx)

///|
/// Its name (13, 500, on 20), what it is up to under it (12, muted), each a line.
// kept across runs: a value (no field of it changes)
let job_name : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Fg, leading=L6, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let job_name_off : @ui.TextStyle = job_name.then(@ui.text_style(color=Muted))

///|
// kept across runs: a value (no field of it changes)
let job_meta_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
/// What is at its end (jobEnd): 24 wide, at the middle of its two lines.
// kept across runs: a value (no field of it changes)
let job_end : @ui.Style = @ui.css("w=S6 pt=S2_5 align=ACenter")

///|
/// Its last output (jobLast): 10 over it, 2 apart; when (11, subtle), the line in mono, cut at its end.
// kept across runs: a value (no field of it changes)
let job_last_box : @ui.Style = @ui.css("w=Full pt=S2_5 gap=S0_5")

///|
// kept across runs: a value (no field of it changes)
let job_last_said : @ui.TextStyle = @ui.text_style(size=Caption, color=Subtle, w=Full)

///|
// kept across runs: a value (no field of it changes)
let job_last_line : @ui.TextStyle = @ui.text_style(size=Caption, color=Muted, wrap=false, max_lines=1)

///|
/// Its actions (jobActions): 2 apart, 6 under what is over them, 8 out at their start; each 26 high, 8 in, its mark and
/// words 5 apart, the pointer's ground on hover (over the row's, lit with it: mbui ui/hand_moves.mbt).
// kept across runs: a value (no field of it changes)
let job_actions : @ui.Style = @ui.css("row pt=S1_5 gap=S0_5").then(@sf.outset_start(8.0))

///|
// kept across runs: a value (no field of it changes)
let job_action_style : @ui.Style = @ui.style(
  row=true,
  h=@sf.job_action_h,
  px=S2,
  gap=S1_25,
  align=ACenter,
  radius=Lg,
  hovered=@ui.patch(bg=Hover),
)

///|
// kept across runs: a value (no field of it changes)
let job_action_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let job_action_hot : @ui.TextStyle = @ui.text_style(size=Meta, color=Fg, wrap=false)

///|
/// A group's head (jobsHead): 8 over, 12 in, 4 under; 12 in 500, muted; its note in 400, subtle, 6 after.
// kept across runs: a value (no field of it changes)
let jobs_head_box : @ui.Style = @ui.css("row w=Full pt=S2 px=S3 pb=S1 gap=S1_5 align=AEnd")

///|
/// In the popover: a small panel's heading, its words as far in as its rows' (a row's padding) and as far under what
/// is over them as a row's words (at the panel's top, where a menu's first item's words are), 4 over its rows.
// kept across runs: a value (no field of it changes)
let jobs_head_inset : @ui.Style = @ui.css("row w=Full pt=S1_5 px=S2_5 pb=S1 gap=S1_5 align=AEnd")

///|
// kept across runs: a value (no field of it changes)
let jobs_head_words : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let jobs_head_note : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, wrap=false)

///|
/// A group's rows, 4 apart; one after another 6 under it (the 任务 tab's).
// kept across runs: a value (no field of it changes)
let jobs_group : @ui.Style = @ui.css("w=Full gap=S1")

///|
/// The popover's groups, and a job opened in it (jobFold): its row and its body under it one piece on the pointer's
/// ground, round as a row, 4 under it; the body 4 by 8 in, its words in the names' column (jobs_names_in).
// kept across runs: a value (no field of it changes)
let jobs_list : @ui.Style = @ui.css("w=Full")

///|
// kept across runs: a value (no field of it changes)
let jobs_fold : @ui.Style = @ui.css("w=Full")

///|
// kept across runs: a value (no field of it changes)
let jobs_fold_open : @ui.Style = @ui.css("w=Full mb=S1 bg=Hover radius=Inner")

///|
// kept across runs: a value (no field of it changes)
let jobs_fold_body : @ui.Style = @ui.style(w=Full, pt=S1, pr=S2, pb=S2, pl=@sf.room_of(jobs_names_in))

///|
/// The names' column in the popover: a row's padding, a job's dot (8) and the 12 after it (job_row_inset, job_row_on).
let jobs_names_in : Double = @sf.text_in + job_dot_w + job_dot_gap

///|
let job_dot_w : Double = 8.0

///|
let job_dot_gap : Double = 12.0

///|
/// The popover's foot (jobsFoot): 6 under its groups, 4 apart; all of them a row 38 high, its words in the names'
/// column (a row's padding, its dot's 8 and the 12 after it: job_row_inset, job_row_on), muted, the words' ink on the
/// pointer's ground.
// kept across runs: a value (no field of it changes)
let jobs_foot : @ui.Style = @ui.css("row w=Full mt=S1_5 gap=S1 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let jobs_all : @ui.Style = @ui.style(
  row=true,
  w=@sf.grow,
  h=@sf.jobs_row_h,
  pl=@sf.room_of(jobs_names_in),
  pr=S2_5,
  align=ACenter,
  // (in the popover's foot corner concentric with it; where it lies in none, as it scrolls under, a row's)
  radius=InnerOr(@sf.row_radius),
  hovered=@ui.patch(bg=Hover),
)

///|
// kept across runs: a value (no field of it changes)
let jobs_all_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let jobs_all_hot : @ui.TextStyle = jobs_all_words.then(@ui.text_style(color=Fg))

///|
/// None at all (jobsEmpty): 26 by 20 in, in the middle, 4 apart; its title 13 in 500.
// kept across runs: a value (no field of it changes)
let jobs_empty : @ui.Style = @ui.css("w=Full py=S6 px=S5 gap=S1 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let jobs_empty_title : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Fg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let jobs_empty_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted)

///|
/// The 任务 tab (jobsTab): its list (4 over, 8 at the sides and under), the job picked under it.
// kept across runs: a value (no field of it changes)
let jobs_tab_box : @ui.Style = @ui.css("w=Full h=Full")

///|
// kept across runs: a value (no field of it changes)
let jobs_tab_list_room : @ui.Style = @ui.css("w=Full")

///|
/// The job picked (jobDetail): a card across the tab's foot (in a panel's foot corners, concentric with them:
/// @sf.pane_foot_card), 14 at its start, on the paper; over and at its end as its head stands (job_detail_at).
// kept across runs: a value (no field of it changes)
let job_detail_box : @ui.Style = @ui.style(w=Full, h=@sf.grow, pl=S3_5, bg=Card)

///|
/// Where its head stands in it: its stop while it runs (round) in its top end corner as far in as makes it concentric
/// with it (capsule_in), the head's middle on the stop's (the choice beside it the head's tallest); else 10 over, 6 at
/// its end.
fn job_detail_at(running : Bool) -> @ui.Style {
  if !running {
    return job_detail_alone
  }
  let d = @ui.capsule_in(@sf.card_corner, job_stop_side)
  // (the head's middle the stop's: as much less over it as the choice is taller)
  let over = d - (dmax(@sf.segmented_height(), job_stop_side) - job_stop_side) / 2.0
  @ui.style(pt=@sf.room_of(over), pr=@sf.room_of(d))
}

///|
// kept across runs: a value (no field of it changes)
let job_detail_alone : @ui.Style = @ui.css("pt=S2_5 pr=S1_5")

///|
/// Its stop's side (job_detail_stop's S7).
let job_stop_side : Double = 28.0

///|
/// Its head (jobDetailHead): 8 apart, its name 13 in 600, its state 12 muted; the choice 120 wide; the stop 28.
// kept across runs: a value (no field of it changes)
let job_detail_head : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let job_detail_name : @ui.TextStyle = @ui.text_style(size=Ui, weight=Semibold, color=Fg, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let job_detail_state : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let job_detail_grow : @ui.Style = @ui.style(w=@sf.grow)

///|
// kept across runs: a value (no field of it changes)
let job_detail_choice : @ui.Style = @ui.css("row")


///|
// kept across runs: a value (no field of it changes)
let job_detail_stop : @ui.Style = @ui.css("w=S7 h=S7 radius=Full align=ACenter justify=JCenter hovered{bg=Hover}")

///|
/// Its command (jobDetailCommand): 4 over, 6 under, 11.5 mono on 1.5, subtle, a line.
// kept across runs: a value (no field of it changes)
let job_detail_command : @ui.Style = @ui.css("w=Full pt=S1 pb=S1_5")

///|
// kept across runs: a value (no field of it changes)
let job_command_words : @ui.TextStyle = @ui.text_style(size=Caption, color=Subtle, wrap=false, max_lines=1)

///|
/// What it said (jobDetailNotices): the rest of it, 8 over, 10 at its end; its last output 8 over, 12 under.
// kept across runs: a value (no field of it changes)
let job_detail_notices : @ui.Style = @ui.style(w=Full, h=@sf.grow, pt=S2, pr=S2_5)

///|
// kept across runs: a value (no field of it changes)
let job_detail_last : @ui.Style = @ui.css("w=Full pb=S3")

///|
/// Its output (jobOutput): the rest of it, 4 over, 8 under and at its end; 11.5 mono on 1.6, the words' ink.
// kept across runs: a value (no field of it changes)
let job_output_box : @ui.Style = @ui.style(w=Full, h=@sf.grow, mt=S1, mb=S2)

///|
// kept across runs: a value (no field of it changes)
let job_output_words : @ui.TextStyle = @ui.text_style(size=Caption, color=Fg, w=Full)

///|
// kept across runs: a value (no field of it changes)
let job_output_none : @ui.TextStyle = @ui.text_style(size=Caption, color=Muted)
