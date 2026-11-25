// 网络与同步, one page in every frame: how this device follows and finds the stations, each a pref of the core's set
// here. 同步: whether the stations of the workspaces not in view are linked too (`otherWorkspaces`, on unless turned
// off: off where one too big to follow from afar costs battery and data each time the app comes back). 后台下载:
// whether files opened and let go go on coming, and up to how big (`fillOff`, `fillMax`; what comes now is 本机缓存's).
// 网络: whether
// stations are looked up in the Mainline DHT (`dht`, on unless turned off: off where a company's filter marks the DHT
// as risky, the LAN's lookup kept), not on the web, whose iroh goes through relays alone and looks nothing up.

///|
/// 网络与同步 (Route::Network) made once as nodes (page_node, laid out by the `width` its frame gives it, narrow where
/// none is given) in node `v`: 同步's switch, 后台下载's (@settings.fill_group_node), then 网络's where the device
/// looks stations up itself.
pub fn network_node(
  v : @view.View,
  core : Core,
  on_back~ : () -> Unit,
  frame~ : () -> PageFrame,
  said? : (@sf.PageSaid) -> Unit,
  width? : () -> Double,
) -> Unit {
  let blocks = fn() {
    let out = ["sync", "fill"]
    if @ui.platform() != 4 {
      out.push("dht")
    }
    out
  }
  @sf.page_node(v, fn() { @sf.t("web-pages.settings.nav.network") }, on_back~, frame~, said?, width?, blocks, fn(b, key) {
    // (each a section of its own, its title shown on a wide page alone: heads=false)
    let section = fn(title : String, body : (@view.View) -> Unit) {
      @sf.section_node(b, fn() { @sf.t(title) }, heads=false, body)
    }
    let turned = fn(s : @view.View, name : String, title : String, note : String) {
      // (a group as 后台下载's beside it, whose pressed row's corner follows it: every card of the page alike)
      @sf.group_node(s, fn(g) {
        @sf.switch_row_node(
          g,
          fn() { @sf.t(title) },
          fn() { @settings.pref(core, name) != "off" },
          fn(on) { @settings.set_pref(core, name, if on { "" } else { "off" }) },
          note=fn() { @sf.t(note) },
        )
      })
    }
    match key {
      "sync" =>
        section("web-pages.network.sync", fn(s) {
          turned(s, "otherWorkspaces", "web-pages.network.otherWorkspaces.title", "web-pages.network.otherWorkspaces.note")
        })
      // (what was opened and let go goes on coming, and up to how big: what it brings now is 本机缓存's)
      "fill" => section("android-settings.files.fill.title", fn(s) { @settings.fill_group_node(s, core) })
      _ =>
        section("web-pages.about.network", fn(s) {
          turned(s, "dht", "web-pages.about.dht.title", "web-pages.about.dht.note")
        })
    }
  })
}
