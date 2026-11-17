// 实验性功能 (ExperimentalPage): per-device switches for features still being completed or explored, off by default on
// both channels; hidden from the settings list when no item is visible on this channel.

///|
pub fn experimental_node(
  v : @view.View,
  core : Core,
  on_back~ : () -> Unit,
  frame~ : () -> PageFrame,
  said? : (@sf.PageSaid) -> Unit,
  width? : () -> Double,
) -> Unit {
  let keys = fn() { @settings.experimental_items(core).map(fn(e) { e.0 }) }
  @sf.page_node(
    v,
    fn() { @sf.t("web-pages.experimental.title") },
    on_back~,
    frame~,
    said?,
    width?,
    lead=fn() { @sf.t("web-pages.experimental.lead") },
    // (a list card of its switches on a wide page, a section each on a narrow one; none while the channel shows none,
    // the settings' list leaving its row out then)
    fn() { @sf.settings_keys(width, keys()) },
    fn(b, key) { @sf.settings_block(b, key, keys, fn(r, k) { experimental_switch(r, core, k) }) },
  )
}

///|
fn experimental_switch(v : @view.View, core : Core, id : String) -> Unit {
  @sf.setting_switch_node(
    v,
    fn() { @sf.t("web-pages.experimental." + id + ".title") },
    fn() { @settings.experimental_on(core, id) },
    fn(on) { @settings.set_experimental(core, id, on) },
    note=fn() { @sf.t("web-pages.experimental." + id + ".description") },
  )
}
