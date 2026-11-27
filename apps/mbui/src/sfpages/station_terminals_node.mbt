// A station's terminals on its page, among its screens and its browser (the overview's 屏幕、浏览器与终端; the user,
// 2026-11-15: 「这东西跟远程桌面和 browser 有什么区别，它凭什么一个功能占一个 tab」): the terminals open on it (the core's
// `terminals` topic), a row each saying where it is, who types and who looks, pressed its page (terminal_view_node.mbt,
// whose ⋯ has 复制工作目录 and 结束会话); then 打开终端, as 打开浏览器 is, for one who may type (the topic's `open`: every
// member but a read-only one) while the station is up and has terminals at all.

///|
/// What the terminals' rows read (station_block_asks'): the station's terminals.
fn terminals_ask(address : String) -> (String, Map[String, Json]) {
  ("terminals", { "station": str(address) })
}

///|
/// A terminal's row's note: who types, how many more look (or nobody), the folder it opened in; its end once it ended.
fn terminal_note(t : Json?) -> String {
  if flag(t, "ended") {
    return @sf.t("web-pages.terminal.ended")
  }
  let looking = items(t, "looking").length()
  let who = match field(t, "typing") {
    Some(String(name)) => {
      let typing = @sf.t("web-pages.terminal.typing", args=[("name", name)])
      if looking > 0 { typing + " · " + @sf.t("web-pages.terminal.looking", args=[("count", looking.to_string())]) } else { typing }
    }
    _ => if looking > 0 { @sf.t("web-pages.terminal.looking", args=[("count", looking.to_string())]) } else { @sf.t("web-pages.terminal.nobody") }
  }
  who + " · " + text(t, "cwd")
}

///|
/// Its title: the last part of the folder it opened in (the folder whole in its note), else the folder.
fn terminal_title(t : Json?) -> String {
  let cwd = text(t, "cwd")
  let parts = cwd.split("/").collect().filter(fn(p) { p.length() > 0 })
  match parts.last() {
    Some(last) => last.to_owned()
    None => cwd
  }
}

///|
// kept across runs: whether this device's host keeps terminals (libghostty-vt linked in), asked once
let terminals_here_kept : Ref[Bool?] = Ref(None)

///|
fn init {
  @sfbase.terminals_capable_fn.val = terminals_here
}

///|
/// Whether this device's host keeps terminals (libghostty-vt linked in: @hostapi.Terminal), asked once by opening one
/// and letting it go: a host with none shows no terminal's row, which would open on nothing.
pub fn terminals_here() -> Bool {
  match terminals_here_kept.val {
    Some(ok) => ok
    None => {
      let ok = match @hostapi.Terminal::open(20, 6) {
        Some(t) => {
          t.close()
          true
        }
        None => false
      }
      terminals_here_kept.val = Some(ok)
      ok
    }
  }
}

///|
/// Whether station `s` offers its terminals here: asked for (not in a replay of a run from before: the source's
/// `asks_terminals`), and a `beta` feature of the station's that it runs (its overview's `features`: its own channel's).
fn terminals_offered(core : Core, s : Json?) -> Bool {
  (core.terminals_on)() && @settings.station_feature(s, "terminal")
}

///|
/// Whether station `s` (whole) shows its terminals' rows: up, one from after terminals (`v`, the topic's value), and
/// this device's host keeps them.
fn terminals_shown(s : Json?, v : Json?) -> Bool {
  flag(s, "online") && flag(v, "known") && !flag(v, "outdated") && terminals_here()
}

///|
/// Whether station `address`'s overview has its terminals to show (station_overview_keys'): asked for (not in a replay
/// of a run from before), this device's host keeping them, and the station saying it has terminals, some open or one
/// to open here.
fn terminals_to_show(core : Core, address : String, s : Json?) -> Bool {
  // (an away station's not asked: its page asks what it shows, station_part_asks')
  guard terminals_offered(core, s) && flag(s, "online") && terminals_here() else { return false }
  let v = (core.topic)("terminals", { "station": str(address) }).get().value
  flag(v, "known") && !flag(v, "outdated") && (flag(v, "open") || items(v, "terminals").length() > 0)
}

///|
/// Station `address`'s terminals in group `g` (station_all_screens_node's), `s` the station whole: a row each, then
/// 打开终端.
fn station_terminal_rows_node(g : @view.View, core : Core, address : String, s : () -> Json?) -> Unit {
  // (not in a replay of a run from before the app asked for them: @sfcore's MBUI_TERMINALS)
  guard (core.terminals_on)() else { return }
  let tr = fn() { (core.topic)("terminals", { "station": str(address) }).get() }
  let v = fn() { tr().value }
  let shown = fn() { terminals_offered(core, s()) && flag(s(), "online") && terminals_shown(s(), v()) }
  let terminals = fn() { if shown() { items(v(), "terminals") } else { [] } }
  g.each(terminals, fn(t) { text(Some(t), "id") }, fn(row, t) {
    let tv = fn() { Some(t.get()) }
    let id = text(@signals.untracked(tv), "id")
    @sf.link_row_node(
      row,
      fn() { terminal_title(tv()) },
      fn() {
        let cur = @signals.untracked(tr)
        if cur.is_confirmed_known() &&
          items(cur.value, "terminals").iter().any(fn(x) { text(Some(x), "id") == id && !flag(Some(x), "ended") }) {
          @sfbase.open_page(Terminal({ station: address, terminal: id, watch: !flag(cur.value, "open"), cwd: text(@signals.untracked(tv), "cwd") }))
        }
      },
      note=fn() { terminal_note(tv()) },
      goes=!flag(@signals.untracked(tv), "ended"),
      lead=LeadLine(fn(l) { st_mark_node(l, fn() { "terminal" }) }),
    )
  })
  g.show(fn() { shown() && flag(v(), "open") }, fn(n) {
    @sf.link_row_node(
      n,
      fn() { @sf.t("web-pages.terminal.openRow") },
      fn() {
        let cur = @signals.untracked(tr)
        if cur.is_confirmed_known() && flag(cur.value, "open") {
          @sfbase.open_page(Terminal({ station: address, terminal: "new", watch: false, cwd: "" }))
        }
      },
      lead=LeadLine(fn(l) { st_mark_node(l, fn() { "terminal" }) }),
    )
  })
}
