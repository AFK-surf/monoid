// 进度汇报, one page in every frame: how the person's agents are asked for progress as they wait on their own work, the
// same on all their devices and for every chat they start (the core's views/progress.ts, read in the `settings` view).

///|
/// 进度汇报 made once as nodes in node `v`, laid out by the `width` its frame gives it: how long they may post nothing,
/// and whether they are told to report or reminded to; each followed as the core says it.
pub fn progress_node(
  v : @view.View,
  core : Core,
  here : () -> Here,
  on_back~ : () -> Unit,
  frame~ : () -> PageFrame,
  said? : (@sf.PageSaid) -> Unit,
  width? : () -> Double,
) -> Unit {
  let scope = fn() { here().workspace }
  let params_of = fn(ws : String) -> Map[String, Json] { { "scope": str(ws) } }
  let read_minutes = fn(v : Json?) -> Double {
    match number(v, "progressMinutes") {
      0.0 => 10.0
      n => n
    }
  }
  let read_strength = fn(v : Json?) -> String {
    if text(v, "progressStrength") == "remind" { "remind" } else { "require" }
  }
  let read_seq = fn(v : Json?) -> Int64? { opt_seq(v, "progressSeq") }
  let minutes_opt = OptimisticChoice::new(v, core, scope, "settings", params_of, read_minutes, read_seq)
  let strength_opt = OptimisticChoice::new(v, core, scope, "settings", params_of, read_strength, read_seq)
  let minutes_now = fn() { minutes_opt.get() }
  let strength_now = fn() { strength_opt.get() }
  // (one set elsewhere that is not offered here: offered as well, chosen)
  let minutes = fn() {
    let offered = [5.0, 10.0, 20.0, 30.0, 60.0]
    let cur = minutes_now()
    if !offered.contains(cur) {
      offered.push(cur)
      offered.sort()
    }
    offered
  }
  let strengths = ["require", "remind"]
  let send_progress = fn(ws : String, of : (String, Json), finish : (Bool, Int64?) -> Unit) {
    @settings.act(
      core,
      @sf.t("web-pages.progress.saveAction"),
      "progress.set",
      obj([("workspace", str(ws)), of]),
      then=fn(ans) { finish(true, opt_seq(Some(ans), "seq")) },
      failed=fn() { finish(false, None) },
    )
  }
  @sf.page_node(
    v,
    fn() { @sf.t("web-pages.progress.title") },
    on_back~,
    frame~,
    said?,
    width?,
    lead=fn() { @sf.t("web-pages.progress.lead") },
    fn() { ["interval", "strength"] },
    fn(b, key) {
      match key {
        "interval" =>
          @sf.section_node(b, fn() { @sf.t("web-pages.progress.interval") }, fn(sec) {
            @sf.page_choice_node(
              sec,
              fn() { minutes().map(fn(n) { n.to_int().to_string() }) },
              fn() { minutes().search(minutes_now()).unwrap_or(0) },
              fn(i) {
                let all = @signals.untracked(minutes)
                if i >= 0 && i < all.length() {
                  let want = all[i]
                  minutes_opt.submit(want, fn(ws, finish) { send_progress(ws, ("minutes", Json::number(want)), finish) })
                }
              },
            )
            @sf.page_note_node(sec, fn() { @sf.t("web-pages.progress.intervalNote") })
          })
        _ =>
          @sf.section_node(b, fn() { @sf.t("web-pages.progress.strength") }, fn(sec) {
            @sf.page_choice_node(
              sec,
              fn() { strengths.map(fn(s) { @sf.t("web-pages.progress." + s) }) },
              fn() { strengths.search(strength_now()).unwrap_or(0) },
              fn(i) {
                if i >= 0 && i < strengths.length() {
                  let want = strengths[i]
                  strength_opt.submit(want, fn(ws, finish) { send_progress(ws, ("strength", str(want)), finish) })
                }
              },
            )
            @sf.page_note_node(sec, fn() { @sf.t("web-pages.progress." + strength_now() + "Note") })
          })
      }
    },
  )
}
