// A file opened beside a chat (sfbase's viewer_tab.mbt): a text file pressed, a press with the command key held (over
// the whole window as its tab: sfbase's tab_full.mbt), a file's menu's 在侧边打开 and the whole window's 移到侧边 put it
// in a tab of the chat's side panel on 大屏; the tab shows what the whole window would (a film or a song its own
// player, embedded), the panel's 全屏 puts that tab over the whole window and back, closing it lets go of what it read;
// on 小屏 the same press opens the whole window, and nothing offers beside.

///|
/// The first row's chat of the made-up core (MBUI_FIXTURE `mode`), in a window `w` by `h` of `platform`'s (its buttons
/// in its top row where `inset` says, its corner `corner`), at rest.
fn beside_tester(
  mode? : String = "chat",
  w? : Double = 1280.0,
  h? : Double = 800.0,
  platform? : Int = 0,
  inset? : Bool = false,
  corner? : Double = 0.0,
) -> @ui.Tester {
  new_run()
  let src = fixture(mode)
  beside_src.val = Some(src)
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform~, window_inset=inset, window_corner=corner)
  nav_rested(t)
  t.run_for(@ui.move_most_ms)
  t
}

///|
/// What the tester is over (beside_tester's).
let beside_src : Ref[Source?] = Ref(None)

///|
/// The chat's tabs' key (the core's `chatTabs`) of the first row's chat.
let beside_chat : String = "ws1/st1:s-c1"

///|
/// Where the chat's own compare.png is (the message's, not a tab's picture of it: the leftmost), scrolled up to it.
fn chat_picture(t : @ui.Tester) -> (Double, Double) raise {
  let mut tries = 0
  while t.locate("img:compare.png").length() == 0 && tries < 12 {
    let (first, _) = t.visible()
    t.scroll_to(if first > 0 { first - 1 } else { 0 })
    t.draw()
    tries += 1
  }
  let at = t.locate("img:compare.png")
  if at.length() == 0 {
    fail("the chat's picture never on the screen")
  }
  let mut most = at[0]
  for p in at {
    if p.0 < most.0 {
      most = p
    }
  }
  most
}

///|
/// A press on (x, y) with the command key held (`mods`), let go of after.
fn press_held(t : @ui.Tester, x : Double, y : Double, mods : Int) -> Unit {
  t.hold_mods(mods)
  t.tap(x, y)
  t.hold_mods(0)
  t.run_for(@ui.move_most_ms)
}

///|
/// The tabs of files beside the chat (their keys: `view:[…]`), as its view has them.
fn view_tabs(t : @ui.Tester) -> Array[String] {
  ignore(t)
  match beside_src.val {
    Some(src) =>
      match @sfbase.view_of_chat(src, { station: "ws1/st1", session: "s-c1", title: "", station_name: "" }).0 {
        Some(v) => v.tabs.open.filter(fn(k) { k.has_prefix("view:") })
        None => []
      }
    None => []
  }
}

///|
/// Where the tab's stage begins across (its tools' row's left), the file named `name` in front.
fn tab_left(t : @ui.Tester, name : String) -> Double raise {
  t.get(Toolbar, label=name).rect.0
}

///|
/// Whether `words` are drawn in the tab (right of its left edge), the file named `name` in front.
fn shown_beside(t : @ui.Tester, name : String, words : String) -> Bool raise {
  let left = tab_left(t, name)
  match t.find(words) {
    Some((x, _)) => x >= left
    None => false
  }
}

///|
/// The audit's faults of something of a file's tab drawn over another's room to be pressed (`apart:`, a node made in
/// viewer_tab.mbt).
fn tab_apart(t : @ui.Tester) -> Array[String] {
  t.audit().filter(fn(f) { f.has_prefix("apart:") && f.contains("viewer_tab.mbt") })
}

///|
/// The picture drawn in the tab (its middle in its stage, right of `left`, `wide` across), larger than a thumbnail: x,
/// y, w, h.
fn tab_drawn(t : @ui.Tester, left : Double, wide : Double) -> (Double, Double, Double, Double) raise {
  let drawn = t.drawn_images().filter(fn(i) { i[0] + i[2] / 2.0 >= left && i[0] + i[2] / 2.0 <= left + wide && i[2] > 100.0 })
  if drawn.length() == 0 {
    fail("no picture drawn in the tab: \{t.drawn_images().length()} drawn")
  }
  let i = drawn[drawn.length() - 1]
  (i[0], i[1], i[2], i[3])
}

///|
/// The size the picture of the file tab in front is its own (as decoded here: the Tester's, not the file's).
fn tab_natural(t : @ui.Tester) -> (Double, Double) raise {
  let tabs = view_tabs(t)
  guard tabs.length() > 0 && beside_src.val is Some(src) else { fail("no file's tab") }
  match @sfbase.tab_viewer(beside_chat, tabs[tabs.length() - 1]) {
    Some(vw) => vw.natural_size(src)
    None => fail("no viewer of the tab")
  }
}

///|
/// Whether a file's tab is over the whole window now (sfbase's tab_full), its name `name`.
fn full_now(name : String) -> Bool {
  match @sfbase.tab_full.get() {
    Some(f) =>
      match @sfbase.view_tab_file(f.tab) {
        Some(v) => v.file.name == name
        None => false
      }
    None => false
  }
}

///|
/// A made-up file of the chat's (sffixture's preview_files), by its name.
fn made_file(name : String) -> Attachment raise {
  for f in @sffixture.preview_files() {
    if f.0.name == name {
      return f.0
    }
  }
  fail("no made-up file \{name}")
}

///|
test "大屏: a press with ⌘ held on a message's picture opens its tab over the whole window, in front in the panel under it, nothing of the whole window's viewer; Escape puts it back; again, that tab, never a second; a plain press opens the whole window" {
  let t = beside_tester()
  let (x, y) = chat_picture(t)
  press_held(t, x, y, @ui.mod_cmd)
  assert_true(@sfbase.viewer.get() is None, msg="nothing of the whole window's viewer")
  assert_eq(view_tabs(t).length(), 1)
  assert_true(full_now("compare.png"), msg="its tab over the whole window")
  for f in t.audit() {
    println("audit: \{f}")
  }
  t.key(@ui.key_escape)
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.tab_full.get() is None, msg="back in the panel")
  assert_eq(view_tabs(t).length(), 1, msg="the tab stays")
  assert_eq(t.all(Tab, label="compare.png", selected=true).length(), 1, msg="its tab, in front")
  // another file beside it, in front; the picture pressed so again: its tab to the front, still one
  @sfbase.open_preview("ws1/st1", "s-c1", made_file("说明.md"), beside=true)
  t.run_for(@ui.move_most_ms)
  assert_eq(t.all(Tab, label="说明.md", selected=true).length(), 1)
  let (x, y) = chat_picture(t)
  press_held(t, x, y, @ui.mod_cmd)
  assert_true(full_now("compare.png"))
  assert_eq(view_tabs(t).length(), 2)
  assert_true(@sfbase.viewer.get() is None)
  t.back()
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.tab_full.get() is None, msg="back puts it back in the panel")
  assert_eq(t.all(Tab, label="compare.png").length(), 1, msg="never a second")
  assert_eq(t.all(Tab, label="compare.png", selected=true).length(), 1, msg="brought to the front")
  // a plain press: the whole window, as before
  let (x, y) = chat_picture(t)
  t.tap(x, y)
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.viewer.get() is Some(_), msg="the whole window's preview")
  assert_eq(view_tabs(t).length(), 2, msg="no tab more")
}

///|
test "大屏: each kind in a tab shows what the whole window would: Markdown's words, code, a table's cells, a picture drawn, a file of no kind told of with its download" {
  let t = beside_tester()
  @sfbase.open_preview("ws1/st1", "s-c1", made_file("说明.md"), beside=true)
  t.run_for(@ui.move_most_ms)
  assert_true(shown_beside(t, "说明.md", "发布前要做的"), msg="Markdown's words")
  // (the reader's tools in the tab's row)
  assert_eq(t.all(Button, label=@sf.t("web-pages.drive.reader.contents")).length(), 1)
  for f in t.audit() {
    println("audit md: \{f}")
  }
  @sfbase.open_preview("ws1/st1", "s-c1", made_file("list.ts"), beside=true)
  t.run_for(@ui.move_most_ms)
  assert_true(shown_beside(t, "list.ts", "export const estimate"), msg="code")
  @sfbase.open_preview("ws1/st1", "s-c1", made_file("数据.csv"), beside=true)
  t.run_for(@ui.move_most_ms)
  assert_true(shown_beside(t, "数据.csv", "帧时间（毫秒）"), msg="a table's head")
  assert_true(shown_beside(t, "数据.csv", "0.57"), msg="a table's cell")
  // (预览 / 源码, as the whole window's bar has them)
  assert_true(t.find(@sf.t("web-main.preview.source")) is Some(_))
  @sfbase.open_preview("ws1/st1", "s-c1", made_file("界面草图.png"), beside=true)
  t.run_for(@ui.move_most_ms)
  let (px, py, pw, ph) = t.get(Image, label="界面草图.png").rect
  let drawn = t.drawn_images().filter(fn(i) { i[0] >= px - 1.0 && i[1] >= py - 1.0 && i[0] + i[2] <= px + pw + 1.0 && i[1] + i[3] <= py + ph + 1.0 && i[2] > 100.0 })
  assert_true(drawn.length() > 0, msg="the picture drawn in its stage: \{t.drawn_images().length()} drawn")
  for f in t.audit() {
    println("audit image: \{f}")
  }
  assert_eq(tab_apart(t), [], msg="nothing of the tab's picture drawn over another's room to be pressed")
  @sfbase.open_preview("ws1/st1", "s-c1", made_file("备份.bin"), beside=true)
  t.run_for(@ui.move_most_ms)
  assert_true(shown_beside(t, "备份.bin", @sf.t("web-main.preview.unsupported")), msg="told of")
  assert_true(t.all(Button, label=@sf.t("web-main.preview.download")).length() >= 1, msg="its download")
  // (its note takes no press: nothing of the tab's under the panel's edge)
  assert_eq(tab_apart(t), [], msg="nothing of the tab's drawn over another's room to be pressed")
  assert_eq(view_tabs(t).length(), 5)
  assert_true(@sfbase.viewer.get() is None)
}

///|
test "大屏: a picture's menu opens it beside; the whole window's 移到侧边 closes it for its tab; the panel's 全屏 puts the tab over the whole window, the tab staying" {
  let t = beside_tester()
  let (x, y) = chat_picture(t)
  t.right_click(x, y)
  t.draw()
  t.click(MenuItem, label=@sf.t("web-main.preview.openBeside"))
  t.run_for(@ui.move_most_ms)
  assert_eq(view_tabs(t).length(), 1)
  assert_true(@sfbase.viewer.get() is None)
  // closed; opened over the whole window; 移到侧边
  t.click(Button, label=@sf.t("web-pages.chat.close", args=[("name", "compare.png")]))
  t.run_for(@ui.move_most_ms)
  assert_eq(view_tabs(t).length(), 0)
  let (x, y) = chat_picture(t)
  t.tap(x, y)
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.viewer.get() is Some(_))
  t.click(Button, label=@sf.t("web-main.preview.moveBeside"))
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.viewer.get() is None, msg="the whole window closed")
  assert_eq(view_tabs(t).length(), 1, msg="its tab")
  // 全屏: the tab over the whole window, its picture drawn there; its 移到侧边 back
  t.click(Button, label=@sf.t("web-main.preview.fullWindow"))
  t.run_for(@ui.move_most_ms)
  assert_true(full_now("compare.png"), msg="over the whole window")
  assert_true(@sfbase.viewer.get() is None, msg="not the whole window's viewer")
  // (its keys in the bar across the top, as a file opened over the whole window has them: no row of its own)
  assert_eq(t.all(Toolbar, label="compare.png").length(), 0, msg="no tools' row over the whole window")
  assert_eq(t.all(Button, label=@sf.t("web-main.preview.download")).length(), 1, msg="下载 in the bar")
  t.click(Button, label=@sf.t("web-main.preview.moveBeside"))
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.tab_full.get() is None)
  assert_eq(view_tabs(t).length(), 1, msg="the tab stays")
  let (_, _, pw, _) = t.get(Toolbar, label="compare.png").rect
  assert_true(pw < 800.0, msg="in the panel again: \{pw}")
}

///|
test "大屏: a tab closed lets go of its viewer; a chat opened with a file's tab kept shows it with nothing pressed; Escape with it in front closes nothing" {
  let t = beside_tester(mode="chat-view-side")
  let tab = @sffixture.fixture_view_tab("chat-view-side")
  assert_true(shown_beside(t, "说明.md", "发布前要做的"), msg="shown as the chat opens")
  assert_true(@sfbase.tab_viewer_held(beside_chat, tab))
  for f in t.audit() {
    println("audit kept: \{f}")
  }
  t.key(@ui.key_escape)
  t.run_for(@ui.move_most_ms)
  assert_eq(view_tabs(t), [tab], msg="Escape closed nothing")
  assert_true(shown_beside(t, "说明.md", "发布前要做的"))
  t.click(Button, label=@sf.t("web-pages.chat.close", args=[("name", "说明.md")]))
  t.run_for(@ui.move_most_ms)
  assert_eq(view_tabs(t).length(), 0)
  assert_true(!@sfbase.tab_viewer_held(beside_chat, tab), msg="its viewer let go")
}

///|
test "大屏: a picture kept beside is drawn as the chat opens" {
  let t = beside_tester(mode="chat-view-side-image")
  let (px, py, pw, ph) = t.get(Image, label="界面草图.png").rect
  let drawn = t.drawn_images().filter(fn(i) { i[0] >= px - 1.0 && i[1] >= py - 1.0 && i[0] + i[2] <= px + pw + 1.0 && i[1] + i[3] <= py + ph + 1.0 && i[2] > 100.0 })
  assert_true(drawn.length() > 0, msg="the picture drawn: \{t.drawn_images().length()} drawn")
}

///|
test "小屏: a press with Ctrl held opens the whole window, and a picture's menu offers nothing beside" {
  let t = beside_tester(w=390.0, h=844.0, platform=2)
  let (x, y) = chat_picture(t)
  t.right_click(x, y)
  t.draw()
  assert_eq(t.all(MenuItem, label=@sf.t("web-main.preview.openBeside")).length(), 0, msg="no 在侧边打开")
  t.key(@ui.key_escape)
  t.run_for(@ui.move_most_ms)
  let (x, y) = chat_picture(t)
  press_held(t, x, y, @ui.mod_ctrl)
  assert_true(@sfbase.viewer.get() is Some(_), msg="the whole window")
  assert_eq(view_tabs(t).length(), 0)
}

///|
test "大屏: Markdown in a tab 360 wide reads in one column there, its 目录 and 排版 opened from the tab's tools over its stage, closed again by them" {
  let t = beside_tester(mode="chat-view-side", w=1100.0)
  let (left, _, wide, _) = t.get(Toolbar, label="说明.md").rect
  assert_true(wide >= 359.0 && wide <= 361.0, msg="the tab \{wide} wide")
  assert_true(shown_beside(t, "说明.md", "发布前要做的"), msg="its words")
  // (no bar of the reader's own in the tab: its tools are the tab's, once)
  assert_eq(t.all(Button, label=@sf.t("web-pages.drive.reader.contents")).length(), 1)
  t.click(Button, label=@sf.t("web-pages.drive.reader.contents"))
  t.run_for(@ui.move_most_ms)
  match t.find(@sf.t("web-pages.drive.reader.findPlaceholder")) {
    Some((x, _)) => assert_true(x >= left && x <= left + wide, msg="目录 over the tab's stage: \{x}")
    None => fail("目录 not open")
  }
  t.click(Button, label=@sf.t("web-pages.drive.reader.contents"))
  t.run_for(@ui.move_most_ms)
  assert_true(t.find(@sf.t("web-pages.drive.reader.findPlaceholder")) is None, msg="closed by its tool")
  t.click(Button, label=@sf.t("web-pages.drive.reader.layout"))
  t.run_for(@ui.move_most_ms)
  match t.find(@sf.t("web-pages.drive.reader.layout")) {
    Some((x, _)) => assert_true(x >= left && x <= left + wide, msg="排版 over the tab's stage: \{x}")
    None => fail("排版 not open")
  }
  for f in t.audit() {
    println("audit 360: \{f}")
  }
  t.click(Button, label=@sf.t("web-pages.drive.reader.layout"))
  t.run_for(@ui.move_most_ms)
  let key = @sfbase.tab_viewer(beside_chat, @sffixture.fixture_view_tab("chat-view-side")).unwrap().read_key()
  assert_true(@sf.reader_panel_of(key) == @sf.ReaderPanel::NoPanel, msg="排版 closed by its tool")
}

///|
test "大屏: a tab's 排版 is the tab's: another tab brought to the front takes it off the screen" {
  let t = beside_tester(mode="chat-view-side")
  let margin = @sf.t("web-pages.drive.reader.margin")
  t.click(Button, label=@sf.t("web-pages.drive.reader.layout"))
  t.run_for(@ui.move_most_ms)
  assert_true(t.find(margin) is Some(_), msg="排版 open")
  // 任务 beside the chat, in front
  @sfdesk.side_change(beside_src.val.unwrap(), { station: "ws1/st1", session: "s-c1", title: "", station_name: "" }, "open", Some("jobs"))
  t.run_for(@ui.move_most_ms)
  assert_eq(t.all(Tab, label="说明.md", selected=true).length(), 0, msg="another tab in front")
  assert_true(t.find(margin) is None, msg="排版 gone with its tab")
  assert_eq(t.all(Slider, label=@sf.t("web-pages.drive.reader.lines")).length(), 0, msg="its controls gone with its tab")
  // the file's tab to the front again: its 排版 there again, within its stage
  let within = fn(what : String) raise {
    let (left, _, wide, _) = t.get(Toolbar, label="说明.md").rect
    let (x, _, w, _) = t.get(Slider, label=@sf.t("web-pages.drive.reader.lines")).rect
    assert_true(x >= left && x + w <= left + wide + 0.5, msg="\{what}: its controls \{x}..\{x + w} within the tab's \{left}..\{left + wide}")
  }
  t.click(Tab, label="说明.md")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find(margin) is Some(_), msg="排版 there again")
  within("back in front")
  // the window made larger: it follows the stage
  t.resize(1440.0, 900.0)
  t.run_for(@ui.move_most_ms)
  within("the window larger")
  // closed by its own ×
  t.click(Button, label=@sf.t("common.close"))
  t.run_for(@ui.move_most_ms)
  assert_true(t.find(margin) is None, msg="closed by its ×")
}

///|
test "大屏: a long Markdown beside a chat keeps 目录 in the toolbar and floats 滚动到底部 at bottom-right without blocking wheel or text selection; pressing ↓ scrolls to the end and hides ↓; wheeling up brings ↓ back; panels cover or shift ↓" {
  let t = beside_tester(mode="chat-view-side-md-long")
  let contents = @sf.t("web-pages.drive.reader.contents")
  let to_end = @sf.t("web-pages.drive.reader.toEnd")
  let (bx, by, bw, bh) = t.get(Toolbar, label="长说明.md").rect
  let in_bar = t
    .all(Button)
    .filter(fn(n) {
      let (nx, ny, nw, nh) = n.rect
      nx >= bx - 1.0 && ny >= by - 1.0 && nx + nw <= bx + bw + 1.0 && ny + nh <= by + bh + 1.0
    })
    .map(fn(n) { n.label })
  let want_bar = [
    contents,
    @sf.t("web-pages.drive.reader.find"),
    @sf.t("web-pages.drive.reader.layout"),
    @sf.t("web-main.preview.download"),
    @sf.t("web-main.preview.fullWindow"),
  ]
  assert_eq(in_bar, want_bar, msg="toolbar buttons: \{Repr(in_bar)}")
  assert_eq(t.all(Button, label=contents).length(), 1, msg="exactly one 目录 button (in toolbar)")
  assert_eq(t.all(Button, label=to_end).length(), 1, msg="滚动到底部 float shown for long Markdown")
  let tab_right = bx + bw
  let tab_bottom = 800.0
  let reach = @sf.float_button_reach
  let (ex, ey, ew, eh) = t.get(Button, label=to_end).rect
  // float is outside toolbar, press box >= 44×44, drawn 32×32 circle 16±1 from right and bottom
  assert_true(ey > by + bh, msg="滚动到底部 floats below toolbar")
  assert_true(ew >= 44.0 && eh >= 44.0, msg="滚动到底部 press box >= 44×44: \{ew}×\{eh}")
  assert_true((tab_right - (ex + ew - reach) - 16.0).abs() <= 1.0, msg="↓ right margin \{tab_right - (ex + ew - reach)}")
  assert_true((tab_bottom - (ey + eh - reach) - 16.0).abs() <= 1.0, msg="↓ bottom margin \{tab_bottom - (ey + eh - reach)}")
  // narrow tab: opening contents panel covers the floating ↓ button
  t.click(Button, label=contents)
  t.run_for(@ui.move_most_ms)
  let landed = t.press_lands_at(ex + ew / 2.0, ey + eh / 2.0)
  assert_true(!landed.contains(to_end), msg="floating ↓ covered by narrow contents panel, got \{landed}")
  t.click(Button, label=contents)
  t.run_for(@ui.move_most_ms)
  // over container has no ground: wheel and text drag-selection to the left of ↓ reach the reader body
  let has = fn(words : String) { t.words().iter().any(fn(w) { w.0.contains(words) }) }
  assert_true(has("发布前长说明"), msg="start words shown at top")
  assert_true(!has("所有检查项已核对完毕"), msg="end words not shown at top")
  let top_y_before = match t.words().iter().find_first(fn(w) { w.0.contains("发布前长说明") }) {
    Some((_, _, y, _, _, _)) => y
    None => fail("no top heading")
  }
  t.wheel(bx + 60.0, ey + eh / 2.0, 200.0)
  t.run_for(@ui.move_most_ms)
  let top_moved = match t.words().iter().find_first(fn(w) { w.0.contains("发布前长说明") }) {
    Some((_, _, y, _, _, _)) => y < top_y_before - 10.0
    None => true
  }
  assert_true(top_moved, msg="wheel to the left of ↓ scrolls the reader body")
  // drag-select text on a line beside ↓ (a paragraph block overlapping ↓'s vertical band)
  match t.words().iter().find_first(fn(w) { w.1 >= bx && w.1 + 40.0 < ex && w.2 < ey + eh && w.2 + w.4 > ey && w.3 >= 40.0 }) {
    Some((_, wx, wy, ww, wh, _)) => {
      let sy = if wy + 8.0 > ey + 8.0 { wy + 8.0 } else if ey + 8.0 < wy + wh - 4.0 { ey + 8.0 } else { wy + wh / 2.0 }
      let x1 = if wx + ww - 4.0 < ex - 8.0 { wx + ww - 4.0 } else { ex - 8.0 }
      let x1 = if x1 < wx + 80.0 { x1 } else { wx + 80.0 }
      t.drag(wx + 4.0, sy, x1, sy)
      t.run_for(@ui.move_most_ms)
      let picked = t.picking().map(fn(p) { p.text }).unwrap_or("")
      assert_true(picked != "", msg="text beside ↓ can be drag-selected")
      t.key(@ui.key_code_copy, mods=@ui.mod_cmd)
      t.run_for(@ui.move_most_ms)
      assert_eq(t.clipboard(), picked, msg="selected text beside ↓ copied")
    }
    None => fail("no reader line beside ↓ to drag-select")
  }
  // pressing ↓ scrolls to the end and hides ↓
  t.click(Button, label=to_end)
  t.run_for(@ui.move_most_ms)
  assert_true(has("所有检查项已核对完毕"), msg="end words shown after pressing 滚动到底部")
  assert_true(!has("发布前长说明"), msg="start words scrolled out after pressing 滚动到底部")
  assert_eq(t.all(Button, label=to_end).length(), 0, msg="滚动到底部 hides at the end")
  // wheeling up past reader_end_away (120) brings ↓ back
  t.wheel(bx + bw / 2.0, 400.0, -240.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(t.all(Button, label=to_end).length(), 1, msg="滚动到底部 returns after wheeling up > 120")
  let faults = t.audit().filter(fn(f) { !f.contains("edge_node.mbt:37") })
  assert_eq(faults, [], msg="audit faults: \{Repr(faults)}")
  // wide tab: opening contents panel shifts ↓ left of the 320 docked panel
  let tw = beside_tester(mode="chat-view-side-md-long", w=2400.0, h=600.0)
  let (wtx, _, wtw, _) = tw.get(Toolbar, label="长说明.md").rect
  tw.click(Button, label=contents)
  tw.run_for(@ui.move_most_ms)
  let (ex2, _, ew2, _) = tw.get(Button, label=to_end).rect
  let right_gap = wtx + wtw - (ex2 + ew2 - reach)
  assert_true((right_gap - (320.0 + 16.0)).abs() <= 1.0, msg="↓ right gap with docked panel: \{right_gap}, want 336 ±1")
}

///|
test "大屏: a short Markdown beside a chat does not show 滚动到底部, keeping all five reader keys in the toolbar" {
  let t = beside_tester(mode="chat-view-side")
  assert_eq(t.all(Button, label=@sf.t("web-pages.drive.reader.toEnd")).length(), 0, msg="no 滚动到底部 for short Markdown")
  let (bx, by, bw, bh) = t.get(Toolbar, label="说明.md").rect
  let in_bar = t
    .all(Button)
    .filter(fn(n) {
      let (nx, ny, nw, nh) = n.rect
      nx >= bx - 1.0 && ny >= by - 1.0 && nx + nw <= bx + bw + 1.0 && ny + nh <= by + bh + 1.0
    })
    .map(fn(n) { n.label })
  let want_bar = [
    @sf.t("web-pages.drive.reader.contents"),
    @sf.t("web-pages.drive.reader.find"),
    @sf.t("web-pages.drive.reader.layout"),
    @sf.t("web-main.preview.download"),
    @sf.t("web-main.preview.fullWindow"),
  ]
  assert_eq(in_bar, want_bar, msg="toolbar buttons: \{Repr(in_bar)}")
}

///|
test "大屏: a reader tab in the chat's panel widens its column to 48em (768) when the panel is wide, stays panel_w - 44 when narrower than 812, and returns to 34em (544) over the whole window" {
  // wide window so the side panel is >= 1000 wide
  let t = beside_tester(mode="chat-view-side", w=3000.0, h=900.0)
  let (_, _, panel_w, _) = t.get(Toolbar, label="说明.md").rect
  assert_true(panel_w >= 1000.0, msg="panel wide enough: \{panel_w}")
  let col_w = fn(label : String) -> Double raise {
    match t.words().iter().find_first(fn(w) { w.0.contains(label) }) {
      Some((_, _, _, w, _, _)) => w
      None => fail("no words containing \{label}")
    }
  }
  let wide_w = col_w("发布前要做的")
  assert_true((wide_w - 768.0).abs() <= 1.0, msg="panel tab column text width \{wide_w}, want 768 ±1")
  let faults = t.audit().filter(fn(f) { !f.contains("edge_node.mbt:37") })
  assert_eq(faults, [], msg="audit faults in wide panel: \{Repr(faults)}")
  // fullscreen over the whole window: returns to 34em (544)
  t.click(Button, label=@sf.t("web-main.preview.fullWindow"))
  t.run_for(@ui.move_most_ms)
  assert_true(full_now("说明.md"), msg="tab over the whole window")
  let full_w = col_w("发布前要做的")
  assert_true((full_w - 544.0).abs() <= 1.0, msg="fullscreen tab column text width \{full_w}, want 544 ±1")
  // back in a panel narrower than 812: text width = panel_w - 44
  t.click(Button, label=@sf.t("web-main.preview.moveBeside"))
  t.run_for(@ui.move_most_ms)
  t.resize(1280.0, 800.0)
  t.run_for(@ui.move_most_ms)
  let (_, _, narrow_panel_w, _) = t.get(Toolbar, label="说明.md").rect
  assert_true(narrow_panel_w < 812.0, msg="narrow panel width: \{narrow_panel_w}")
  let narrow_w = col_w("发布前要做的")
  assert_true(
    (narrow_w - (narrow_panel_w - 44.0)).abs() <= 1.0,
    msg="narrow panel text width \{narrow_w}, want \{narrow_panel_w - 44.0} ±1",
  )
}

///|
test "大屏: a file kept only while the app runs (a draft's: a Mermaid picture, an attachment waiting) asked beside opens the whole window, no tab, and its bar offers no 移到侧边" {
  let t = beside_tester()
  let svg = b"<svg xmlns='http://www.w3.org/2000/svg' width='40' height='30'><rect width='40' height='30' fill='red'/></svg>"
  let file = fn(path : String) -> Attachment {
    {
      name: "Mermaid.svg",
      path,
      size: svg.length().to_double(),
      width: 40.0,
      height: 30.0,
      thumbhash: "",
      owner: "",
      upload: "",
      duration: 0.0,
      frames: 0,
      held: false,
    }
  }
  @sfbase.keep_read("ws1/st1//draft:mermaid/0123456789abcdef", svg)
  @sfbase.open_preview("ws1/st1", "", file("draft:mermaid/0123456789abcdef"), beside=true)
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.viewer.get() is Some(_), msg="the whole window's preview")
  assert_eq(view_tabs(t).length(), 0, msg="no tab")
  assert_eq(t.all(Button, label=@sf.t("web-main.preview.moveBeside")).length(), 0, msg="no 移到侧边")
  // (one read again from where it lies: 移到侧边 on its bar)
  @sfbase.keep_read("ws1/st1//uploads/fx/Mermaid.svg", svg)
  @sfbase.open_preview("ws1/st1", "", file("uploads/fx/Mermaid.svg"), beside=false)
  t.run_for(@ui.move_most_ms)
  assert_eq(t.all(Button, label=@sf.t("web-main.preview.moveBeside")).length(), 1, msg="移到侧边 for a file kept")
}

///|
test "大屏: a picture in a tab is fitted as over the whole window: one larger than its stage 12 in from its nearer edges, one smaller at its own size in its middle" {
  // larger: wider than a stage 373 wide (its own size the Tester's decode's)
  let t = beside_tester()
  @sfbase.open_preview("ws1/st1", "s-c1", made_file("界面草图.png"), beside=true)
  t.run_for(@ui.move_most_ms)
  let (left, _, wide, _) = t.get(Toolbar, label="界面草图.png").rect
  // (the stage's middle: the middle of the room the hand takes it in, as far in from each of its edges)
  let middle = fn() raise {
    let (ax, ay, aw, ah) = t.get(Image, label="界面草图.png").rect
    (ax + aw / 2.0, ay + ah / 2.0)
  }
  let (nw, nh) = tab_natural(t)
  assert_true(nw > wide, msg="its own \{nw} × \{nh}, wider than the stage \{wide}")
  let (x, y, w, h) = tab_drawn(t, left, wide)
  assert_true((x - (left + 12.0)).abs() <= 1.0 && (x + w - (left + wide - 12.0)).abs() <= 1.0, msg="12 in from its sides: \{x}..\{x + w} in \{left}..\{left + wide}")
  assert_true((h / w - nh / nw).abs() < 0.01, msg="as tall for as wide: \{w} × \{h}, its own \{nw} × \{nh}")
  assert_true((y + h / 2.0 - middle().1).abs() <= 1.0, msg="in its middle: \{y + h / 2.0}, the stage's \{middle().1}")
  assert_eq(tab_apart(t), [])
  // smaller: the same in a window wide enough for a stage wider than it and its margins
  let t = beside_tester(w=2400.0, h=1000.0)
  @sfbase.open_preview("ws1/st1", "s-c1", made_file("界面草图.png"), beside=true)
  t.run_for(@ui.move_most_ms)
  let (left, _, wide, _) = t.get(Toolbar, label="界面草图.png").rect
  let (nw, nh) = tab_natural(t)
  assert_true(wide > nw + 24.0, msg="the stage \{wide} wide, the picture \{nw}")
  let (x, y, w, h) = tab_drawn(t, left, wide)
  assert_true((w - nw).abs() <= 1.0 && (h - nh).abs() <= 1.0, msg="at its own size: \{w} × \{h}, its own \{nw} × \{nh}")
  assert_true((x + w / 2.0 - (left + wide / 2.0)).abs() <= 1.0, msg="in its middle across: \{x + w / 2.0}")
  let (ax, ay, aw, ah) = t.get(Image, label="界面草图.png").rect
  assert_true((x + w / 2.0 - (ax + aw / 2.0)).abs() <= 1.0 && (y + h / 2.0 - (ay + ah / 2.0)).abs() <= 1.0, msg="in its middle: \{x + w / 2.0}, \{y + h / 2.0}")
  // a double press on its middle: zoomed in round it (its middle staying), and back
  let (cx, cy) = (x + w / 2.0, y + h / 2.0)
  t.tap(cx, cy)
  t.advance(@ui.double_tap_ms / 2.0)
  t.tap(cx, cy)
  t.run_for(@ui.move_most_ms)
  let (x2, y2, w2, h2) = tab_drawn(t, left, wide)
  assert_true(w2 > w * 1.5, msg="zoomed in: \{w2} wide")
  assert_true((x2 + w2 / 2.0 - cx).abs() <= 1.0 && (y2 + h2 / 2.0 - cy).abs() <= 1.0, msg="round where it was pressed: \{x2 + w2 / 2.0}, \{y2 + h2 / 2.0}")
}

///|
test "大屏: the whole window's picture offers 移到侧边 with nothing pressed; the window made 小屏-wide it goes, wide again it is back" {
  let t = beside_tester(mode="chat-preview-image")
  let moves = fn() { t.all(Button, label=@sf.t("web-main.preview.moveBeside")).length() }
  assert_true(@sfbase.viewer.get() is Some(_), msg="the whole window's preview")
  assert_eq(moves(), 1, msg="移到侧边 offered")
  t.resize(390.0, 844.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(moves(), 0, msg="not on 小屏")
  t.resize(1280.0, 800.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(moves(), 1, msg="offered again")
}

// A film or a song beside the chat: the one player embedded in its tab's stage (sfbase's viewer_tab.mbt), its own
// player and native view. The fake host says nothing of playing by itself: what the app told a view (Tester::views,
// "control <view> 1 0" played, "… 2 0" paused) is what is asserted.

///|
/// The film of the chat's message, as its tab and the whole window name it.
let beside_film : String = "演示录屏.mp4"

///|
/// The song of the made-up files (chat-view-side-audio's).
let beside_song : String = "会议录音.m4a"

///|
/// The viewer of the file named `name` open beside the chat.
fn tab_viewer_named(t : @ui.Tester, name : String) -> @sfbase.Viewer raise {
  for tab in view_tabs(t) {
    match @sfbase.tab_viewer(beside_chat, tab) {
      Some(vw) if vw.file.name == name => return vw
      _ => ()
    }
  }
  fail("no tab of \{name}")
}

///|
/// The native view the player of the tab of `name` plays in (its host's number).
fn tab_player_view(t : @ui.Tester, name : String) -> Int raise {
  match tab_viewer_named(t, name).media {
    Some(m) =>
      match m.native() {
        Some(n) => n.id()
        None => fail("the tab's player has no view")
      }
    None => fail("the tab of \{name} has no player")
  }
}

///|
/// Whether native view `id` was last told to play (its last play or pause, as the app told its host).
fn told_playing(t : @ui.Tester, id : Int) -> Bool {
  let mut on = false
  for l in t.views() {
    if l == "control \{id} 1 0" {
      on = true
    } else if l == "control \{id} 2 0" {
      on = false
    }
  }
  on
}

///|
/// Whether native view `id` was ever told to play.
fn ever_played(t : @ui.Tester, id : Int) -> Bool {
  t.views().contains("control \{id} 1 0")
}

///|
/// The holes native views show through right of `left` (a tab's stage).
fn holes_beside(t : @ui.Tester, left : Double) -> Array[(Double, Double, Double, Double)] {
  t.holes().filter(fn(h) { h.0 >= left - 0.5 })
}

///|
/// The audit's faults of a press's room or of presses over each other (`room:`, `apart:`) naming something of a file's
/// tab or of its player (made in viewer_tab.mbt, player_node.mbt, player_list_node.mbt, kit's media.mbt; a tab's
/// player's keys under its own key,
/// `preview-media/…`).
fn tab_player_faults(t : @ui.Tester) -> Array[String] {
  t
  .audit()
  .filter(fn(f) {
    (f.has_prefix("room:") || f.has_prefix("apart:")) &&
    (f.contains("viewer_tab.mbt") || f.contains("player_node.mbt") || f.contains("player_list_node.mbt") || f.contains("media.mbt") || f.contains("preview-media/"))
  })
}

///|
/// The film the chat-download chat's last message sends: its thumbnail's middle (at the chat's end).
fn chat_film(t : @ui.Tester) -> (Double, Double) raise {
  let (x, y, w, h) = t.get(Button, label=@sf.t("web-main.file.play", args=[("name", beside_film)])).rect
  (x + w / 2.0, y + h / 2.0)
}

///|
/// The film's tab kept beside the chat as it opens (chat-view-side-video), played from its play key: its view.
fn kept_film_played(t : @ui.Tester) -> Int raise {
  let id = tab_player_view(t, beside_film)
  t.click(Button, label=@sf.t("android-chat.video.play"))
  t.run_for(@ui.move_most_ms)
  assert_true(told_playing(t, id), msg="played by its key")
  id
}

///|
test "大屏: a film pressed with ⌘ held opens its tab over the whole window, playing; Escape puts it in the panel, its player in the tab's stage, playing on; nothing of the whole window's viewer; its menu's 在侧边打开 too" {
  let t = beside_tester(mode="chat-download")
  let (x, y) = chat_film(t)
  press_held(t, x, y, @ui.mod_cmd)
  assert_true(@sfbase.viewer.get() is None, msg="nothing of the whole window's viewer")
  assert_eq(view_tabs(t).length(), 1)
  assert_true(full_now(beside_film), msg="its tab over the whole window")
  let id = tab_player_view(t, beside_film)
  assert_true(told_playing(t, id), msg="played at once: \{Repr(t.views())}")
  t.key(@ui.key_escape)
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.tab_full.get() is None)
  assert_eq(t.all(Tab, label=beside_film, selected=true).length(), 1, msg="its tab, in front")
  assert_eq(tab_player_view(t, beside_film), id, msg="the same player")
  assert_true(told_playing(t, id), msg="playing on in the panel: \{Repr(t.views())}")
  // its picture in the stage under the tab's tools, its controls there (a phone's: the stage 373 wide)
  let (left, top, wide, tall) = t.get(Toolbar, label=beside_film).rect
  let holes = holes_beside(t, left)
  assert_eq(holes.length(), 1, msg="its picture beside: \{Repr(t.holes())}")
  let (hx, hy, hw, _) = holes[0]
  assert_true(hx >= left - 0.5 && hx + hw <= left + wide + 0.5 && hy >= top + tall - 0.5, msg="in the stage: \{Repr(holes[0])}")
  assert_eq(t.all(Button, label=@sf.t("android-chat.video.play")).length(), 1, msg="its play key")
  // closed, and opened again by its menu
  t.click(Button, label=@sf.t("web-pages.chat.close", args=[("name", beside_film)]))
  t.run_for(@ui.move_most_ms)
  assert_eq(view_tabs(t).length(), 0)
  let (x, y) = chat_film(t)
  t.right_click(x, y)
  t.draw()
  t.click(MenuItem, label=@sf.t("web-main.preview.openBeside"))
  t.run_for(@ui.move_most_ms)
  assert_eq(view_tabs(t).length(), 1)
  assert_true(@sfbase.viewer.get() is None)
  assert_true(told_playing(t, tab_player_view(t, beside_film)), msg="played at once")
}

///|
test "大屏: a chat opened with a film's tab kept shows its player in the tab's stage, not playing, none of the whole window's keys" {
  let t = beside_tester(mode="chat-view-side-video")
  let id = tab_player_view(t, beside_film)
  assert_true(!ever_played(t, id), msg="never played: \{Repr(t.views())}")
  let (left, top, wide, tall) = t.get(Toolbar, label=beside_film).rect
  let holes = holes_beside(t, left)
  assert_eq(holes.length(), 1, msg="its picture: \{Repr(t.holes())}")
  let (hx, hy, hw, _) = holes[0]
  assert_true(hx >= left - 0.5 && hx + hw <= left + wide + 0.5 && hy >= top + tall - 0.5, msg="in the stage: \{Repr(holes[0])}")
  assert_eq(t.all(Button, label=@sf.t("android-chat.video.play")).length(), 1, msg="its play key")
  // (paused: a frame back and on in the place of 15 s back and on)
  assert_eq(t.all(Button, label=@sf.t("android-chat.video.prev")).length(), 1, msg="a frame back")
  // none of the whole window's: one 全屏 (the tab's: nothing turns it sideways), one 下载 (the tab's), no 返回
  assert_eq(t.all(Button, label=@sf.t("web-main.preview.fullWindow")).length(), 1, msg="the tab's 全屏 alone")
  assert_eq(t.all(Button, label=@sf.t("web-main.preview.download")).length(), 1, msg="the tab's 下载 alone")
  assert_eq(t.all(Button, label=@sf.t("common.back")).length(), 0, msg="no 返回")
  assert_true(@sfbase.viewer.get() is None)
}

///|
test "大屏: a film's tab paused as another tab comes to the front, still paused where it was as it is back in front" {
  let t = beside_tester(mode="chat-view-side-video")
  let id = kept_film_played(t)
  t.set_player(id, position=4000.0, playing=true)
  t.run_for(@ui.move_most_ms)
  // 任务 beside the chat, in front
  @sfdesk.side_change(beside_src.val.unwrap(), { station: "ws1/st1", session: "s-c1", title: "", station_name: "" }, "open", Some("jobs"))
  t.run_for(@ui.move_most_ms)
  assert_eq(t.all(Tab, label=beside_film, selected=true).length(), 0, msg="another tab in front")
  assert_true(!told_playing(t, id), msg="paused with its tab behind")
  t.set_player(id, playing=false)
  let seeks = t.views().filter(fn(l) { l.has_prefix("control \{id} 3 ") }).length()
  // its tab back: the same view, paused, not sent anywhere
  t.click(Tab, label=beside_film)
  t.run_for(@ui.move_most_ms)
  assert_eq(tab_player_view(t, beside_film), id, msg="the same player")
  assert_true(!told_playing(t, id), msg="still paused")
  assert_eq(t.views().filter(fn(l) { l.has_prefix("control \{id} 3 ") }).length(), seeks, msg="where it was")
  assert_true(!t.views().contains("close \{id}"))
  assert_eq(holes_beside(t, tab_left(t, beside_film)).length(), 1, msg="its picture shown again")
}

///|
test "大屏: a film's tab paused as the window is 小屏 (no panel), not played again as it is wide" {
  let t = beside_tester(mode="chat-view-side-video")
  let id = kept_film_played(t)
  t.resize(390.0, 844.0)
  t.run_for(@ui.move_most_ms)
  assert_true(!told_playing(t, id), msg="paused on 小屏")
  t.resize(1280.0, 800.0)
  t.run_for(@ui.move_most_ms)
  assert_true(!told_playing(t, id), msg="not played again by itself")
  assert_eq(tab_player_view(t, beside_film), id, msg="the same player")
}

///|
test "大屏: a film's tab paused as another page is opened over its chat's, not played again as the chat is back" {
  let t = beside_tester(mode="chat-view-side-video")
  let id = kept_film_played(t)
  // 外观 over the chat's page (a link's way: back comes to the chat again)
  @sfbase.open_page_over(Setting(@settings.Route::Appearance))
  t.run_for(@ui.move_most_ms)
  assert_true(!(app.nav.top() is Chat(_)), msg="another page on top")
  assert_true(!told_playing(t, id), msg="paused under another page")
  // back to the chat: its tab there, not played again by itself
  app.nav.pop() |> ignore
  t.run_for(@ui.move_most_ms)
  assert_true(app.nav.top() is Chat(_), msg="the chat again")
  assert_eq(t.all(Tab, label=beside_film, selected=true).length(), 1, msg="its tab, in front")
  assert_true(!told_playing(t, id), msg="not played again by itself")
  assert_true(!t.views().contains("close \{tab_player_view(t, beside_film)}"), msg="its player kept")
}

///|
test "大屏: a film's tab's 全屏 puts the tab over the whole window, its own player playing on where it was, and back the same" {
  let t = beside_tester(mode="chat-view-side-video")
  let id = kept_film_played(t)
  t.set_player(id, position=4000.0, playing=true)
  t.run_for(@ui.move_most_ms)
  let seeks = t.views().filter(fn(l) { l.has_prefix("control \{id} 3 ") }).length()
  t.click(Button, label=@sf.t("web-main.preview.fullWindow"))
  t.run_for(@ui.move_most_ms)
  assert_true(full_now(beside_film), msg="over the whole window")
  assert_true(@sfbase.viewer.get() is None, msg="not the whole window's viewer")
  assert_eq(tab_player_view(t, beside_film), id, msg="the tab's own player")
  assert_true(told_playing(t, id), msg="playing on")
  assert_eq(t.views().filter(fn(l) { l.has_prefix("control \{id} 3 ") }).length(), seeks, msg="not sent anywhere")
  let holes = t.holes()
  assert_true(holes.iter().any(fn(h) { h.2 > 1000.0 }), msg="its picture across the window: \{Repr(holes)}")
  assert_eq(view_tabs(t).length(), 1, msg="the tab stays")
  // back: in the panel, still playing, its player as it was
  t.back()
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.tab_full.get() is None)
  assert_true(told_playing(t, id), msg="playing on in the panel")
  assert_true(!t.views().contains("close \{id}"))
  assert_eq(holes_beside(t, tab_left(t, beside_film)).length(), 1, msg="its picture in the panel again")
}

///|
test "大屏: the whole window's 移到侧边 puts a film back in its tab from where it was, playing: the tab's own player sent there" {
  // its tab kept, played over the whole window in the viewer of its own further on
  let t = beside_tester(mode="chat-view-side-video")
  let id = kept_film_played(t)
  let vw = tab_viewer_named(t, beside_film)
  @sfbase.open_preview(vw.station, vw.key, vw.file, beside=false)
  t.run_for(@ui.move_most_ms)
  let wid = @sfbase.viewer.get().unwrap().media.unwrap().native().unwrap().id()
  t.set_player(wid, position=7000.0, playing=true)
  t.run_for(@ui.move_most_ms)
  t.click(Button, label=@sf.t("web-main.preview.moveBeside"))
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.viewer.get() is None, msg="the whole window closed")
  assert_true(t.views().contains("close \{wid}"), msg="its player let go")
  assert_eq(tab_player_view(t, beside_film), id, msg="the tab's own player still")
  assert_true(t.views().contains("control \{id} 3 7000"), msg="sent where the whole window was")
  assert_true(told_playing(t, id), msg="playing")
}

///|
test "大屏: the whole window's 移到侧边 with no tab of the film before: the tab's player made from where the whole window's was, playing" {
  let t = beside_tester(mode="chat-download")
  let (x, y) = chat_film(t)
  t.tap(x, y)
  t.run_for(@ui.move_most_ms)
  let wid = @sfbase.viewer.get().unwrap().media.unwrap().native().unwrap().id()
  t.set_player(wid, position=5000.0, playing=true)
  t.run_for(@ui.move_most_ms)
  t.click(Button, label=@sf.t("web-main.preview.moveBeside"))
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.viewer.get() is None)
  assert_eq(view_tabs(t).length(), 1)
  let id = tab_player_view(t, beside_film)
  assert_true(id != wid)
  assert_true(t.views().contains("control \{id} 3 5000"), msg="from where it was: \{Repr(t.views())}")
  assert_true(told_playing(t, id))
}

///|
test "大屏: a film's tab in front takes no keys: Space typed in the composer is a space, the player as it was; Escape closes nothing" {
  let t = beside_tester(mode="chat-view-side-video")
  let id = tab_player_view(t, beside_film)
  let told = t.views().length()
  t.click(TextField, label="发消息")
  t.run_for(@ui.move_most_ms)
  t.key(@ui.key_space)
  t.type_text(" ")
  t.run_for(@ui.move_most_ms)
  assert_eq(t.field_words(), " ", msg="a space in the composer")
  assert_true(!told_playing(t, id), msg="not played")
  let after = t.views()
  for i in told..<after.length() {
    assert_true(!after[i].has_prefix("control \{id} "), msg="nothing told the player: \{after[i]}")
  }
  t.key(@ui.key_escape)
  t.run_for(@ui.move_most_ms)
  assert_eq(view_tabs(t), [@sffixture.fixture_view_tab("chat-view-side-video")], msg="Escape closed nothing")
  assert_true(!t.views().contains("close \{id}"))
}

///|
test "大屏: a film's tab closed lets go of its player: its view closed, nothing of it drawn" {
  let t = beside_tester(mode="chat-view-side-video")
  let tab = @sffixture.fixture_view_tab("chat-view-side-video")
  let id = tab_player_view(t, beside_film)
  t.click(Button, label=@sf.t("web-pages.chat.close", args=[("name", beside_film)]))
  t.run_for(@ui.move_most_ms)
  assert_eq(view_tabs(t).length(), 0)
  assert_true(!@sfbase.tab_viewer_held(beside_chat, tab), msg="its viewer let go")
  assert_true(t.views().contains("close \{id}"), msg="its view closed")
  t.draw()
  assert_eq(t.holes().length(), 0, msg="nothing of it drawn: \{Repr(t.holes())}")
}

///|
test "大屏: a song kept beside shows its cover and its controls in the tab, not playing" {
  let t = beside_tester(mode="chat-view-side-audio")
  let id = tab_player_view(t, beside_song)
  assert_true(!ever_played(t, id))
  let (left, top, _, tall) = t.get(Toolbar, label=beside_song).rect
  let cover = t.locate(beside_song).filter(fn(p) { p.0 >= left && p.1 > top + tall })
  assert_eq(cover.length(), 1, msg="its name under its cover in the stage: \{Repr(t.locate(beside_song))}")
  assert_eq(t.all(Button, label=@sf.t("android-chat.video.play")).length(), 1, msg="its play key")
  assert_true(t.find("0:31") is Some(_), msg="where it stands")
  // (no picture: nothing to turn sideways, no frame to step)
  assert_eq(t.all(Button, label=@sf.t("android-chat.video.prev")).length(), 0)
}

///|
test "大屏: a film's and a song's player in a tab 373 wide and in a wide one: everything that always shows pressed in its room, none over another" {
  for mode in ["chat-view-side-video", "chat-view-side-audio"] {
    for (w, h) in [(1280.0, 800.0), (2400.0, 1000.0)] {
      let t = beside_tester(mode~, w~, h~)
      let name = if mode == "chat-view-side-video" { beside_film } else { beside_song }
      let (_, _, wide, _) = t.get(Toolbar, label=name).rect
      for f in t.audit() {
        println("audit \{mode} \{wide}: \{f}")
      }
      assert_eq(tab_player_faults(t), [], msg="\{mode} in a stage \{wide} wide")
      // (the desktop's controls where the stage is wider than Small, the phone's where it is not)
      let desk = t.all(Button, label=@sf.t("web-pages.drive.player.mute")).length() == 1
      assert_eq(desk, wide >= @sf.medium_from, msg="\{mode} \{wide} wide: the desktop's controls \{desk}")
    }
  }
}

///|
test "中屏 and 大屏: a film's and a song's player in a tab keeps the corner rule, in a tape's panel (its corners 42) and by a Mac window's corner (16)" {
  for mode in ["chat-view-side-video", "chat-view-side-audio"] {
    let name = if mode == "chat-view-side-video" { beside_film } else { beside_song }
    for win in corner_windows.filter(fn(w) { w.0 == "touch" || w.0 == "desk" || w.0 == "desk-win" || w.0 == "wide" }) {
      let t = screen_in(mode, win, "zh")
      let faults = t.corner_faults().filter(fn(f) { f.contains("「" + name) })
      assert_eq(faults, [], msg="\{win.0} \{mode}")
    }
  }
}

// A film or a song in a tab is part of the pane (sf/player_node.mbt's `embedded`): no ground of its own, its picture in the
// room over its controls, the controls always there under it in the pane's colours.

///|
/// The film's picture where the tab's player draws it (the hole its native view shows through), the tab of `name` in
/// front.
fn film_hole(t : @ui.Tester, name : String) -> (Double, Double, Double, Double) raise {
  let holes = holes_beside(t, tab_left(t, name))
  if holes.length() != 1 {
    fail("one picture beside: \{Repr(t.holes())}")
  }
  holes[0]
}

///|
/// Where the controls of the tab's player begin from the top: where their time is said (10 s long: the fake host's).
fn controls_top(t : @ui.Tester) -> Double raise {
  match t.rect_of("0:10") {
    Some((_, y, _, _)) => y
    None => fail("no time said in the controls")
  }
}

///|
test "大屏: a film playing in a narrow tab keeps its controls after a single press on its picture: its play key drawn and pressed" {
  let t = beside_tester(mode="chat-view-side-video")
  let id = kept_film_played(t)
  t.set_player(id, playing=true)
  t.run_for(@ui.move_most_ms)
  let (x, y, w, h) = film_hole(t, beside_film)
  t.tap(x + w / 2.0, y + h / 2.0)
  t.run_for(@ui.double_tap_ms + @player.media_sleep_ms + @ui.move_most_ms)
  let pause = t.get(Button, label=@sf.t("android-chat.video.pause"), disabled=false)
  let (kx, ky, kw, kh) = pause.rect
  t.tap(kx + kw / 2.0, ky + kh / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_true(!told_playing(t, id), msg="paused by its key")
}

///|
test "大屏: a film playing in a wide tab keeps its controls with the pointer nowhere near them, after a single click on its picture" {
  let t = beside_tester(mode="chat-view-side-video", w=2400.0, h=1000.0)
  let id = kept_film_played(t)
  t.set_player(id, playing=true)
  t.run_for(@ui.move_most_ms)
  // (untouched while it plays: there all along)
  t.run_for(@player.media_rest_ms + @ui.move_most_ms)
  assert_eq(t.all(Button, label=@sf.t("android-chat.video.pause"), disabled=false).length(), 1, msg="drawn while it plays")
  let (x, y, w, h) = film_hole(t, beside_film)
  t.tap(x + w / 2.0, y + h / 2.0)
  // the pointer far from them, in the chat
  t.move_to(600.0, 300.0)
  t.run_for(@ui.double_tap_ms + @player.media_sleep_ms + @ui.move_most_ms)
  let pause = t.get(Button, label=@sf.t("android-chat.video.pause"), disabled=false)
  let (kx, ky, kw, kh) = pause.rect
  t.tap(kx + kw / 2.0, ky + kh / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_true(!told_playing(t, id), msg="paused by its key")
}

///|
test "大屏: a film's picture in a tab ends over its controls, narrow and wide; zoomed in, nothing of it is placed outside its room" {
  for (w, h) in [(1280.0, 800.0), (2400.0, 1000.0)] {
    let t = beside_tester(mode="chat-view-side-video", w~, h~)
    let (_, hy, _, hh) = film_hole(t, beside_film)
    let top = controls_top(t)
    assert_true(hy + hh <= top + 0.5, msg="\{w} wide: the picture to \{hy + hh}, the controls from \{top}")
    // narrow, in the middle of the room between the tools and the controls (not of the stage, the controls over its
    // foot): a phone's controls begin with where it is. Not wide: a desktop's say it inside their bar, further below
    // the room's foot, so halfway from the tools to it is not the room's middle (483 against 506.5 was this test's own
    // idea of the room being wrong); that foot is player_room's, up from the stage's, which nothing drawn marks
    if w < 2000.0 {
      let (_, bar_y, _, bar_h) = t.get(Toolbar, label=beside_film).rect
      let middle = (bar_y + bar_h + top) / 2.0
      assert_true((hy + hh / 2.0 - middle).abs() <= 16.0, msg="\{w} wide: the picture's middle at \{hy + hh / 2.0}, the room's \{middle}")
    }
  }
  // zoomed in round its middle by the wheel with ⌘ (a wide tab's, the desktop's controls)
  let t = beside_tester(mode="chat-view-side-video", w=2400.0, h=1000.0)
  let (x, y, w, h) = film_hole(t, beside_film)
  let top = controls_top(t)
  t.wheel_with(x + w / 2.0, y + h / 2.0, 0.0, -wheel_notch * 3.0, @ui.wheel_mod_cmd)
  t.run_for(@ui.move_most_ms)
  let key = tab_viewer_named(t, beside_film).media.unwrap().key()
  match @sf.player_picture_at(key) {
    Some((_, _, pw, _)) => assert_true(pw > w * 1.5, msg="zoomed in: \{pw} wide, \{w} fitted")
    None => fail("no picture placed")
  }
  let (_, zy, _, zh) = film_hole(t, beside_film)
  let (_, stage_top, _, tall) = t.get(Toolbar, label=beside_film).rect
  assert_true(zy >= stage_top + tall - 0.5, msg="not over the tools: from \{zy}")
  assert_true(zy + zh <= top + 0.5, msg="not over the controls: to \{zy + zh}, the controls from \{top}")
}

///|
test "大屏: nothing in a tab's stage is drawn with a ground of the player's own (a film's black, a song's canvas), narrow and wide" {
  for mode in ["chat-view-side-video", "chat-view-side-audio"] {
    let name = if mode == "chat-view-side-video" { beside_film } else { beside_song }
    for (w, h) in [(1280.0, 800.0), (2400.0, 1000.0)] {
      let t = beside_tester(mode~, w~, h~)
      let (left, top, wide, tall) = t.get(Toolbar, label=name).rect
      let grounds = [@sf.media_dark_stage, @sf.theme().p.canvas]
      let drawn = t
        .drawn_rects()
        .filter(fn(r) { r.0 >= left - 0.5 && r.0 + r.2 <= left + wide + 0.5 && r.1 >= top + tall - 0.5 && grounds.contains(r.4) })
      assert_eq(drawn, [], msg="\{mode} \{w} wide")
    }
  }
}

///|
test "大屏: a song playing in a tab cuts no hole in it (its player placed out of sight), narrow and wide; a film's tab one" {
  for (w, h) in [(1280.0, 800.0), (2400.0, 1000.0)] {
    let t = beside_tester(mode="chat-view-side-audio", w~, h~)
    let id = tab_player_view(t, beside_song)
    t.click(Button, label=@sf.t("android-chat.video.play"))
    t.run_for(@player.media_rest_ms + @ui.move_most_ms)
    assert_true(told_playing(t, id), msg="\{w} wide: it plays")
    assert_eq(holes_beside(t, tab_left(t, beside_song)), [], msg="\{w} wide: no hole for a song")
    let f = beside_tester(mode="chat-view-side-video", w~, h~)
    assert_eq(holes_beside(f, tab_left(f, beside_film)).length(), 1, msg="\{w} wide: a film's picture")
  }
}

///|
test "大屏: a film opened beside keeps what its message knew of it: its size, its length and its frames, from the tab's first frame" {
  let t = beside_tester(mode="chat-download")
  let (x, y) = chat_film(t)
  press_held(t, x, y, @ui.mod_cmd)
  let f = tab_viewer_named(t, beside_film).file
  assert_eq((f.width, f.height, f.duration, f.frames), (1280.0, 720.0, 12500.0, 375), msg="the tab's film as its message has it: \{Repr((f.width, f.height, f.duration, f.frames))}, tabs \{Repr(view_tabs(t))}")
}

///|
test "text files default beside the chat; the panel's 全屏 puts their tab over the whole window" {
  let t = beside_tester()
  for name in ["说明.md", "list.ts", "数据.csv", "报告.html"] {
    @sfbase.open_preview("ws1/st1", "s-c1", made_file(name))
    t.run_for(@ui.move_most_ms)
    assert_true(@sfbase.viewer.get() is None, msg=name + " opens beside")
    assert_eq(t.all(Tab, label=name, selected=true).length(), 1)
    assert_true(t.all(Toolbar, label=name).length() > 0)
  }
  assert_eq(view_tabs(t).length(), 4)
  t.click(Button, label=@sf.t("web-main.preview.fullWindow"))
  t.run_for(@ui.move_most_ms)
  assert_true(full_now("报告.html"), msg="its tab over the whole window")
  assert_true(@sfbase.viewer.get() is None)
  assert_eq(view_tabs(t).length(), 4)
}

///|
test "text files without a side panel fall back to the whole-window preview" {
  let t = beside_tester(w=390.0, h=844.0, platform=2)
  @sfbase.open_preview("ws1/st1", "s-c1", made_file("说明.md"))
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.viewer.get() is Some(_))
  assert_eq(view_tabs(t).length(), 0)
}

///|
test "a plain press on a message's text attachment opens its side tab" {
  let t = beside_tester(mode="chat-files-sent")
  t.click(Group, label="list.ts")
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.viewer.get() is None)
  assert_eq(t.all(Tab, label="list.ts", selected=true).length(), 1)
  assert_true(shown_beside(t, "list.ts", "export const estimate"))
}

///|
/// beside_tester's, its windows opening in the run (a Mac's), each beside the first `w` by `h`: window 1 the first
/// opened.
fn beside_windows(t : @ui.Tester, w? : Double = 960.0, h? : Double = 720.0) -> Unit {
  t.set_window_opens(true)
  t.set_windows_in_process(true)
  t.set_window_beside_size(1, w, h)
  t.run_for(@ui.move_most_ms)
}

///|
/// The words window `wid` of the run draws now (0 the first).
fn beside_window_words(t : @ui.Tester, wid : Int) -> Array[String] {
  let out = Ref([])
  t.in_window(wid, fn() { out.val = t.words().map(fn(w) { w.0 }) })
  out.val
}

///|
/// The audit's faults of window `wid` of the run, as it is drawn now.
fn beside_window_audit(t : @ui.Tester, wid : Int) -> Array[String] {
  let out = Ref([])
  t.in_window(wid, fn() { out.val = t.audit() })
  out.val
}

///|
/// The button named `label` in window `wid` of the run pressed (its middle tapped there): whether there was one.
fn beside_window_press(t : @ui.Tester, wid : Int, label : String) -> Bool {
  let found = Ref(false)
  t.in_window(wid, fn() {
    match t.query(Button, label~) {
      Some(b) => {
        found.val = true
        t.tap(b.rect.0 + b.rect.2 / 2.0, b.rect.1 + b.rect.3 / 2.0)
      }
      None => ()
    }
  })
  found.val
}

///|
/// The file named `name` beside the chat, in front, sent to a window of its own by the panel's 在新窗口打开.
fn file_to_window(t : @ui.Tester, name : String) -> Unit raise {
  @sfbase.open_preview("ws1/st1", "s-c1", made_file(name), beside=true)
  t.run_for(@ui.move_most_ms)
  t.click(Button, label=@sf.t("web-pages.screen.window"))
  t.run_for(@ui.move_most_ms)
}

///|
test "大屏: a file's tab sent to a window of its own by the panel's 在新窗口打开: the window made as a tab's (WindowSpec), the reader there, none of it in the panel; asked again, that window to the front; its 移到侧边 puts it back in the panel and closes the window" {
  let t = beside_tester()
  // (no size said for the window here: it opens at the size its WindowSpec says, as a host makes it)
  t.set_window_opens(true)
  t.set_windows_in_process(true)
  t.run_for(@ui.move_most_ms)
  file_to_window(t, "说明.md")
  assert_eq(t.windows_beside().length(), 1, msg="one window of this run")
  assert_eq(t.windows_opened(), [], msg="no run of its own")
  let (wid, what) = t.windows_beside()[0]
  for field in ["\"role\":\"tab\"", "\"title\":\"说明.md\"", "\"w\":960", "\"h\":720", "\"minW\":420", "\"minH\":320", "\"sideTab\":"] {
    assert_true(what.contains(field), msg="\{field} in \{what}")
  }
  let size = Ref((0.0, 0.0))
  t.in_window(wid, fn() { size.val = t.size() })
  assert_eq(size.val, (960.0, 720.0), msg="made at its WindowSpec's size")
  assert_eq((t.window_title(wid~), t.window_role(wid)), ("说明.md", "tab"))
  // its reader there, its tools in its bar; none of it in the panel (the tab left it, its viewer that window's)
  let words = beside_window_words(t, wid)
  assert_true(words.iter().any(fn(w) { w.contains("发布前要做的") }), msg="the reader in the window: \{Repr(words)}")
  assert_true(words.contains("说明.md"), msg="its name in its bar: \{Repr(words)}")
  assert_eq(view_tabs(t), [], msg="off the panel")
  assert_true(t.find("发布前要做的") is None, msg="not drawn in the first window")
  assert_true(@sfbase.tab_viewer_held(beside_chat, @sfbase.window_here_page(wid).map(fn(p) { match p { SideTab(f) => f.tab; _ => "" } }).unwrap_or("")))
  assert_eq(beside_window_audit(t, wid), [], msg="the window at 960 × 720: \{Repr(beside_window_audit(t, wid))}")
  // the same file asked beside again (a message's card): that window to the front, never a second, the panel not
  // opened on it here
  @sfbase.open_preview("ws1/st1", "s-c1", made_file("说明.md"), beside=true)
  t.run_for(@ui.move_most_ms)
  assert_eq(t.windows_beside().length(), 1, msg="never a second window")
  assert_eq(t.window_ids_fronted(), [wid])
  assert_eq(view_tabs(t), [], msg="the panel not opened on it")
  assert_true(t.find("发布前要做的") is None, msg="not drawn in the first window")
  // 移到侧边 there: back in the panel, in front, the window closed, the reader as it was
  assert_true(beside_window_press(t, wid, @sf.t("web-main.preview.moveBeside")), msg="移到侧边 in the window's bar")
  t.run_for(@ui.move_most_ms)
  assert_eq(t.windows_beside().length(), 0, msg="the window closed")
  assert_eq(view_tabs(t).length(), 1, msg="back in the panel")
  assert_eq(t.all(Tab, label="说明.md", selected=true).length(), 1, msg="in front")
  assert_true(shown_beside(t, "说明.md", "发布前要做的"), msg="drawn beside the chat again")
}

///|
test "大屏: a file's tab over the whole window sent to a window of its own by its bar's 在新窗口打开: the whole window put away at once; that window closed by the person lets the tab go" {
  let t = beside_tester()
  beside_windows(t, w=420.0, h=320.0)
  @sfbase.open_preview("ws1/st1", "s-c1", made_file("说明.md"), beside=true)
  t.run_for(@ui.move_most_ms)
  let tab = view_tabs(t)[0]
  t.click(Button, label=@sf.t("web-main.preview.fullWindow"))
  t.run_for(@ui.move_most_ms)
  assert_true(full_now("说明.md"), msg="over the whole window")
  let keys = t.all(Button, label=@sf.t("web-pages.screen.window"))
  assert_true(keys.length() > 0, msg="在新窗口打开 in its bar")
  let k = keys[keys.length() - 1]
  t.tap(k.rect.0 + k.rect.2 / 2.0, k.rect.1 + k.rect.3 / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.tab_full.get() is None, msg="the whole window put away")
  assert_true(app.nav.top() is Chat(_), msg="back on the chat")
  assert_eq(t.windows_beside().length(), 1)
  let wid = t.windows_beside()[0].0
  assert_true(beside_window_words(t, wid).iter().any(fn(w) { w.contains("发布前要做的") }), msg="the reader there")
  assert_eq(beside_window_audit(t, wid), [], msg="the window at its least, 420 × 320: \{Repr(beside_window_audit(t, wid))}")
  // closed by its own close button: the tab let go of, as its tab closed beside the chat would be
  t.close_window_beside(wid)
  t.run_for(@ui.move_most_ms)
  assert_eq(t.windows_beside().length(), 0)
  assert_eq(view_tabs(t), [], msg="not back in the panel")
  assert_true(!@sfbase.tab_viewer_held(beside_chat, tab), msg="its viewer let go of")
  assert_true(@sfbase.tab_full.get() is None)
}

///|
/// Where the node read out `label` (its role `role`) is in window `wid` of the run: its rectangle, if there is one.
fn beside_window_rect(t : @ui.Tester, wid : Int, role : @ui.Role, label : String) -> (Double, Double, Double, Double)? {
  let out = Ref(None)
  t.in_window(wid, fn() { out.val = t.query(role, label~).map(fn(n) { n.rect }) })
  out.val
}

///|
test "大屏: a file's tab in a window of its own on a Mac and on Windows, its buttons in its top row, at 960 × 720 and at its least 420 × 320: nothing the audit finds; its name in its middle; Windows' own buttons on its bar's line after 移到侧边; at its least its keys in its ⋯; its own close button and Ctrl+W close it, the tab let go" {
  for platform in [0, 3] {
    let corner = if platform == 3 { 8.0 } else { 16.0 }
    let at = "platform \{platform}"
    let t = beside_tester(platform~, inset=true, corner~)
    t.set_window_opens(true)
    t.set_windows_in_process(true)
    t.run_for(@ui.move_most_ms)
    file_to_window(t, "说明.md")
    assert_eq(t.windows_beside().length(), 1, msg=at)
    let wid = t.windows_beside()[0].0
    t.run_for(@ui.move_most_ms)
    assert_eq(beside_window_audit(t, wid), [], msg="\{at}, 960 × 720: \{Repr(beside_window_audit(t, wid))}")
    // its name in the window's middle, whichever side the window's buttons are on
    let name = Ref(None)
    t.in_window(wid, fn() { name.val = t.words().iter().find_first(fn(w) { w.0 == "说明.md" }) })
    match name.val {
      Some((_, x, _, w, _, _)) => assert_true(((x + w / 2.0) - 480.0).abs() < 2.0, msg="\{at}: its name at \{x}, \{w} wide")
      None => fail("\{at}: no name in its bar")
    }
    let beside = beside_window_rect(t, wid, Button, @sf.t("web-main.preview.moveBeside"))
    assert_true(beside is Some(_), msg="\{at}: 移到侧边")
    if platform == 3 {
      // Windows' own buttons the app's, on the line of its bar, after its last key
      let (bx, by, bw, bh) = beside.unwrap()
      for key in ["desktop.menu.minimize", "desktop.window.maximize", "desktop.menu.close"] {
        match beside_window_rect(t, wid, Button, @sf.t(key)) {
          Some((kx, ky, _, kh)) => {
            assert_true(((ky + kh / 2.0) - (by + bh / 2.0)).abs() < 1.0, msg="\{at}: \{key} on 移到侧边's line: \{ky}, \{by}")
            assert_true(kx >= bx + bw, msg="\{at}: \{key} after 移到侧边: \{kx}, \{bx + bw}")
          }
          None => fail("\{at}: no \{key} in the window")
        }
      }
    }
    // at its least: the audit still finds nothing; what has not the room in its ⋯
    t.set_window_beside_size(wid, 420.0, 320.0)
    t.run_for(@ui.move_most_ms)
    assert_eq(beside_window_audit(t, wid), [], msg="\{at}, 420 × 320: \{Repr(beside_window_audit(t, wid))}")
    // its name and what it is whole, the room given for the other side's buttons given back first
    let said = beside_window_words(t, wid)
    assert_true(said.contains("说明.md") && said.contains("500 B · Markdown"), msg="\{at}: its name whole at its least: \{Repr(said)}")
    if platform == 3 {
      assert_true(beside_window_press(t, wid, @sf.t("web-main.menu.more")), msg="\{at}: its ⋯ at its least")
      t.run_for(@ui.move_most_ms)
      let words = beside_window_words(t, wid)
      let reader = [
        @sf.t("web-pages.drive.reader.contents"),
        @sf.t("web-pages.drive.reader.find"),
        @sf.t("web-pages.drive.reader.layout"),
        @sf.t("web-main.preview.download"),
      ]
      assert_true(reader.iter().any(fn(k) { words.contains(k) }), msg="\{at}: what left its bar in its ⋯: \{Repr(words)}")
      t.in_window(wid, fn() { t.key(@ui.key_escape) })
      t.run_for(@ui.move_most_ms)
    }
    // closed by its own close button (the app's on Windows: @hostapi.window_act; the system's on a Mac: the person's)
    if platform == 3 {
      assert_true(beside_window_press(t, wid, @sf.t("desktop.menu.close")), msg="\{at}: its close button")
      t.run_for(@ui.move_most_ms)
      assert_eq(t.window_acts_of(wid~), [3], msg=at)
    } else {
      t.close_window_beside(wid)
      t.run_for(@ui.move_most_ms)
    }
    assert_eq(t.windows_beside(), [], msg="\{at}: closed")
    assert_eq(view_tabs(t), [], msg="\{at}: not back beside the chat")
    // again, closed by Ctrl+W (⌘W on a Mac)
    file_to_window(t, "说明.md")
    assert_eq(t.windows_beside().length(), 1, msg=at)
    let again = t.windows_beside()[0].0
    t.in_window(again, fn() { t.key(@ui.key_of_char('w'), mods=if platform == 3 { @ui.mod_ctrl } else { @ui.mod_cmd }) })
    t.run_for(@ui.move_most_ms)
    assert_eq(t.windows_beside(), [], msg="\{at}: closed by its keys")
    assert_eq(view_tabs(t), [], msg="\{at}: let go")
  }
}

///|
test "a terminal and a station's screen each alone in a window of its own, on a Mac and on Windows, its buttons in its top row, at 960 × 720 and at its least 420 × 320: its one bar its top row, nothing the audit finds" {
  let pages : Array[(String, @sfbase.Page)] = [
    ("terminal", Terminal({ station: "ws1/st1", terminal: "term-2", watch: false, cwd: "~/still.fail" })),
    ("screen-live", Screen({ station: "ws-1/st-1", screen: "browser:tab-1", title: "Chrome", until_gone: false })),
  ]
  for kind in pages {
    let (mode, page) = kind
    for platform in [0, 3] {
      for size in [(960.0, 720.0), (420.0, 320.0)] {
        let (w, h) = size
        let at = "\{mode}, platform \{platform}, \{w} × \{h}"
        let calls : Array[Made] = []
        let t = wide_tester(
          calls,
          mode~,
          w~,
          h~,
          platform~,
          window_corner=if platform == 3 { 8.0 } else { 16.0 },
          window_inset=true,
          before=fn(_) {
            if mode == "screen-live" {
              @sfpages.open_screen_fixture("screen-live")
            }
            @sfbase.lone_page.val = Some(page)
          },
        )
        t.run_for(@ui.move_most_ms)
        assert_eq(t.audit(), [], msg="\{at}: \{Repr(t.audit())}")
        @sfbase.lone_page.val = None
      }
    }
  }
}
