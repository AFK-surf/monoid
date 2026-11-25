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
  let told = fn() { (core.topic)("settings", { "scope": str(here().workspace) }).get().value }
  // (a core from before says neither: as the station goes by then)
  // (each told as it changes itself, not as the rest of what the settings say does)
  let minutes_of = @signals.computed(fn(_) {
    match number(told(), "progressMinutes") {
      0.0 => 10.0
      n => n
    }
  })
  let strength_of = @signals.computed(fn(_) { if text(told(), "progressStrength") == "remind" { "remind" } else { "require" } })
  let minutes_now = fn() { minutes_of.get() }
  let strength_now = fn() { strength_of.get() }
  // (one set elsewhere that is not offered here: offered as well, chosen)
  let minutes = fn() {
    let offered = [5.0, 10.0, 20.0, 30.0, 60.0]
    if !offered.contains(minutes_now()) {
      offered.push(minutes_now())
      offered.sort()
    }
    offered
  }
  let strengths = ["require", "remind"]
  let set = fn(of : (String, Json)) {
    let ws = @signals.untracked(fn() { here().workspace })
    @settings.act(core, @sf.t("web-pages.progress.saveAction"), "progress.set", obj([("workspace", str(ws)), of]))
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
                let (all, now) = @signals.untracked(fn() { (minutes(), minutes_now()) })
                if i >= 0 && i < all.length() && all[i] != now {
                  set(("minutes", Json::number(all[i])))
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
                if i >= 0 && i < strengths.length() && strengths[i] != @signals.untracked(strength_now) {
                  set(("strength", str(strengths[i])))
                }
              },
            )
            @sf.page_note_node(sec, fn() { @sf.t("web-pages.progress." + strength_now() + "Note") })
          })
      }
    },
  )
}
