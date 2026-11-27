// ⌘/: every shortcut, by where it works, the way to
// change them (快捷键, sfpages shortcuts.mbt) at its foot, a panel of the presenters' made as nodes.

///|
/// ⌘/: every shortcut, by where it works (the core's keymap, then those of one place, not changed here), quiet words
/// beside each; the way to change them at its foot (the desktop app's). A panel of the presenters' opened by nothing
/// (in the middle of the window; on 小屏 a sheet from its foot), made as nodes, presented from host `v` as `open` (the
/// shell's) comes to say so, said closed as it closes for anything else (its close button, Escape, back, a press outside,
/// 更改), closed with `v` let go.
pub fn keys_dialog_node(v : @view.View, src : Source, open : @signals.Signal[Bool]) -> Unit {
  let mine = Ref(0)
  v.reacts(fn() { open.get() }, fn(on) {
    if !on {
      if mine.val != 0 {
        @sf.close_presented_of(mine.val)
        mine.val = 0
      }
      return
    }
    guard !@sf.presented_open_of(mine.val) else { return }
    let prefs = fn() { src.topic("prefs", {}).get().value }
    @sf.panel_nodes(
      @sf.t("web-main.shortcuts.title"),
      fn(b, _) { keys_sheet_node(b, prefs) },
      from=Unanchored,
      grows=true,
      // (the shortcuts' own page in its place: where this app can change them)
      foot?=if @settings.keys_changeable(@signals.untracked(prefs)) {
        Some(fn(f : @view.View, close : () -> Unit) {
          @sf.button_node(f, fn() { @sf.t("web-main.shortcuts.change") }, tone=Ghost, fn() {
            close()
            open_settings_at(@settings.Route::Shortcuts)
          })
          |> ignore
        })
      } else {
        None
      },
      gone=fn() { open.set(false) },
    )
    mine.val = @sf.last_presented()
  })
  // (closed by anything else (all that is presented closed): said closed then)
  v.reacts(
    fn() { @sf.presented_open_now(mine.val) },
    fn(shown) {
      if !shown && mine.val != 0 {
        mine.val = 0
        open.set(false)
      }
    },
    at_start=false,
  )
  v.owns(fn() {
    if mine.val != 0 && @sf.presented_open_of(mine.val) {
      @sf.close_presented_of(mine.val)
    }
  })
  |> ignore
}

///|
/// What ⌘/ shows in node `parent`: each place's shortcuts (key_lines, as `prefs` says them), its title over its lines,
/// each what it does and its keys at the line's two ends, their feet together, the keys on a line of their own under it
/// where the line has not the room for both.
fn keys_sheet_node(parent : @view.View, prefs : () -> Json?) -> Unit {
  parent.box(fn(sheet) {
    @sf.style_node(sheet, fn() { keys_sheet })
    // (by place, each line by its place in it: what is said in two places is two lines)
    sheet.each(fn() { key_lines(prefs()).mapi(fn(i, g) { (i, g) }) }, fn(g) { g.0 }, at_once=true, fn(gv, g) {
      @sf.style_node(gv, fn() { keys_group })
      gv.box(fn(h) {
        @sf.style_node(h, fn() { keys_group_head })
        @sf.words_node(h, fn() { g.get().1.0 }, fn() { keys_group_title }) |> ignore
      })
      |> ignore
      gv.each(fn() { g.get().1.1.mapi(fn(i, k) { (i, k) }) }, fn(k) { k.0 }, at_once=true, fn(line, k) {
        @sf.style_node(line, fn() { keys_line })
        line.wraps(Is(Some(keys_line_gap))) |> ignore
        @sf.words_node(line, fn() { k.get().1.0 }, fn() { keys_line_words }) |> ignore
        @sf.words_node(line, fn() { k.get().1.1 }, fn() { keys_line_keys }) |> ignore
      })
    })
  })
  |> ignore
}

///|
/// How far apart a line's two lines are where its keys go under what it does (S1).
let keys_line_gap : Double = 4.0

///|
/// What ⌘/ lists, each place's shortcuts with their keys in words: worked out as it is drawn, not while it is closed.
fn key_lines(prefs : Json?) -> Array[(String, Array[(String, String)])] {
  let (first_ws, last_ws) = @settings.workspace_keys(prefs)
  let (send, newline) = @settings.send_lines(prefs)
  let groups = @settings.key_groups(prefs)
  groups.push((@sf.t("web-main.shortcuts.group.workspace"), [(@sf.t("web-main.shortcuts.switchWorkspace"), first_ws + " … " + last_ws)]))
  groups.push(
    (
      @sf.t("web-main.shortcuts.group.composer"),
      [
        (@sf.t("web-main.shortcuts.send"), send),
        (@sf.t("web-main.shortcuts.newline"), newline),
        (@sf.t("web-main.shortcuts.prevNextChat"), "↑ / ↓"),
      ],
    ),
  )
  groups.push(
    (
      @sf.t("web-main.shortcuts.group.preview"),
      [
        (@sf.t("web-main.shortcuts.prevNextImage"), "← / →"),
        (@sf.t("web-main.shortcuts.zoom"), "+ / -"),
        (@sf.t("web-main.shortcuts.fitActual"), "0 / 1"),
        (@sf.t("common.close"), "Esc"),
      ],
    ),
  )
  groups
}

///|
/// (group: its lines 2 apart, its title 4 over them)
// kept across runs: a value (no field of it changes)
let keys_sheet : @ui.Style = @ui.css("w=Full gap=S4_5")

///|
// kept across runs: a value (no field of it changes)
let keys_group : @ui.Style = @ui.css("w=Full gap=S0_5")

///|
// kept across runs: a value (no field of it changes)
let keys_group_head : @ui.Style = @ui.css("w=Full pb=S1")

///|
/// (groupTitle: 12, 500, muted)
// kept across runs: a value (no field of it changes)
let keys_group_title : @ui.TextStyle = @ui.text_style(size=Meta, leading=L4_75, weight=Medium, color=Muted, wrap=false)

///|
/// (line: what it does and its keys at the two ends, 16 apart, 4 over and under, the list's words)
// kept across runs: a value (no field of it changes)
let keys_line : @ui.Style = @ui.css("row w=Full py=S1 gap=S4 align=AEnd justify=JBetween")

///|
// kept across runs: a value (no field of it changes)
let keys_line_words : @ui.TextStyle = @ui.text_style(size=Ui, leading=L5, color=Fg)

///|
/// (keys: muted, their digits as wide as each other)
// kept across runs: a value (no field of it changes)
let keys_line_keys : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted)
