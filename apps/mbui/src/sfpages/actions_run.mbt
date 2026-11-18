// The two most relevant jobs come from the station, failures first. The same card is
// shown on links in a message and in the chat's Links list.

///|
fn run_state(state : String) -> (String, String) {
  match state {
    "in_progress" | "running" => ("pending", "web-main.preview.run.running")
    "success" | "passed" => ("passed", "web-main.preview.run.passed")
    "failure" | "failed" | "startup_failure" => ("failed", "web-main.preview.run.failed")
    "timed_out" => ("failed", "web-main.preview.run.timedOut")
    "action_required" => ("failed", "web-main.preview.run.actionRequired")
    "cancelled" => ("", "web-main.preview.run.cancelled")
    "neutral" => ("", "web-main.preview.run.neutral")
    "skipped" => ("", "web-main.preview.run.skipped")
    "completed" => ("", "web-main.preview.run.completed")
    "stale" => ("", "web-main.preview.run.stale")
    _ => ("pending", "web-main.preview.run.queued")
  }
}

///|
fn run_workflow(v : Json?) -> String {
  text(v, "workflow") + " #" + count(v, "number").to_string()
}

///|
fn run_source(v : Json?) -> String {
  [text(v, "repository"), text(v, "branch"), text(v, "commit")].filter(fn(s) { s != "" }).join(" · ")
}

///|
fn run_elapsed(v : Json?) -> String {
  let elapsed = text(v, "elapsed")
  if elapsed == "" { "" } else { @sf.t("web-main.preview.run.elapsed", args=[("time", elapsed)]) }
}

///|
fn run_counts(v : Json?) -> Array[(String, String)] {
  let counts = field(v, "counts")
  ["failed", "passed", "running", "queued", "cancelled", "skipped", "neutral"].filter_map(fn(state) {
    let n = count(counts, state)
    let (tone, key) = run_state(state)
    if n > 0 { Some((tone, n.to_string() + " " + @sf.t(key))) } else { None }
  })
}

///|
fn run_jobs(v : Json?) -> Array[(String, String, String)] {
  items(v, "jobs").map(fn(j) { (text(Some(j), "name"), text(Some(j), "step"), text(Some(j), "url")) })
}

///|
fn run_card_node(parent : @view.View, value : () -> Json?, href : () -> String, copy : (@view.View) -> Unit) -> Unit {
  let state = fn() { run_state(text(value(), "state")) }
  parent.box(fn(meta) {
    @sf.style_node(meta, fn() { peek_change_meta })
    state_pill_node(meta, fn() { state().0 }, fn() { None }, fn() { @sf.t(state().1) }, style=run_pill)
    meta.box(fn(r) {
      @sf.style_node(r, fn() { peek_ref }, in_row=true)
      @sf.words_node(r, fn() { run_workflow(value()) }, fn() { peek_meta_words }) |> ignore
    }) |> ignore
    @sf.words_node(meta, fn() { run_elapsed(value()) }, fn() { peek_meta_words }) |> ignore
  }) |> ignore
  @sf.words_node(parent, fn() { text(value(), "title") }, fn() { peek_tile_title }) |> ignore
  @sf.words_node(parent, fn() { run_source(value()) }, fn() { peek_meta_words }) |> ignore
  parent.box(fn(line) {
    @sf.style_node(line, fn() { peek_meta })
    line.wraps(Is(Some(@ui.Space::S2.px()))) |> ignore
    line.each(fn() { run_counts(value()) }, fn(f) { f }, fn(b, item) {
      state_pill_node(b, fn() { item.get().0 }, fn() { None }, fn() { item.get().1 }, style=run_pill)
    })
  }) |> ignore
  parent.each(fn() { run_jobs(value()) }, fn(j) { j.2 }, fn(row, item) {
    @sf.action_box_node(row, fn() { item.get().0 }, fn(_) { open_link(item.get().2) }, fn(b) {
      @sf.style_node(b, fn() { run_job_row })
      b.box(fn(name) {
        @sf.style_node(name, fn() { run_name_column }, in_row=true)
        @sf.words_node(name, fn() { item.get().0 }, fn() { run_name_words(@sf.lit_node(b)) }) |> ignore
      }) |> ignore
      b.box(fn(detail) {
        @sf.style_node(detail, fn() { peek_ref }, in_row=true)
        @sf.words_node(detail, fn() { item.get().1 }, fn() { run_step_words }) |> ignore
      }) |> ignore
    }) |> ignore
  })
  parent.box(fn(foot) {
    @sf.style_node(foot, fn() { run_foot })
    @sf.panel_button_node(foot, fn() { @sf.t("web-main.preview.run.allJobs") }, fn() { open_link(href()) }, tone=Accent) |> ignore
    foot.box(fn(spacer) { @sf.style_node(spacer, fn() { peek_ref }, in_row=true) }) |> ignore
    copy(foot)
  }) |> ignore
}

///|
fn run_card(c : @ui.Ctx, v : Json?, href : String, copy : () -> Unit) -> Unit {
  let (tone, key) = run_state(text(v, "state"))
  c.box(style=peek_change_meta, fn() {
    state_pill(c, tone, None, @sf.t(key), style=run_pill)
    c.box(style=peek_ref, fn() { c.text(run_workflow(v), style=peek_meta_words) |> ignore }) |> ignore
    c.text(run_elapsed(v), style=peek_meta_words) |> ignore
  }) |> ignore
  c.text(text(v, "title"), style=peek_tile_title) |> ignore
  c.text(run_source(v), style=peek_meta_words) |> ignore
  c.box(style=peek_meta, flow=true, line_gap=@ui.Space::S2.px(), fn() {
    for fact in run_counts(v) { state_pill(c, fact.0, None, fact.1, style=run_pill) }
  }) |> ignore
  for job in run_jobs(v) {
    c.on_press(c.id(job.2), fn() { open_link(job.2) })
    @kit.button(c, job.0, key=job.2, w=Fill(1.0), look=fn(c, state) {
      c.box(style=run_job_row, fn() {
        c.box(style=run_name_column, fn() { c.text(job.0, style=run_name_words(state.hovered || state.focus_shown)) |> ignore }) |> ignore
        c.box(style=peek_ref, fn() { c.text(job.1, style=run_step_words) |> ignore }) |> ignore
      }) |> ignore
    }) |> ignore
  }
  c.box(style=run_foot, fn() {
    @sf.panel_button(c, href + "/all-jobs", @sf.t("web-main.preview.run.allJobs"), tone=Accent, on_press=fn() { open_link(href) }) |> ignore
    c.box(style=peek_ref, fn() {  }) |> ignore
    copy()
  }) |> ignore
}

///|
// kept across runs: both buttons sit in a bottom corner, the same inset as the copy button
let run_foot : @ui.Style = peek_file_foot.then(@ui.style(ml=@sf.room_of(peek_button_in)))

///|
// kept across runs: the current step can take a second line beside the job button
let run_step_words : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, w=Full, max_lines=2)

///|
// kept across runs: both columns start on the same line even when either wraps
let run_job_row : @ui.Style = @ui.css("row w=Full gap=S2 align=AStart")

///|
// kept across runs: job names share a column and wrap inside it
let run_name_column : @ui.Style = @ui.css("w=S24")

///|
fn run_name_words(hot : Bool) -> @ui.TextStyle {
  @ui.text_style(size=Meta, leading=L5, weight=Medium, color=if hot { AccentText } else { Fg }, w=Full, max_lines=2)
}

///|
// kept across runs: a text-only status pill has the same inset on both sides
let run_pill : @ui.Style = peek_state.then(@ui.css("pl=S2"))
