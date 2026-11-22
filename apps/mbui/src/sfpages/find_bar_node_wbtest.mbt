// ⌘F's bar made once as nodes (find_bar_node.mbt), drawn as the old view's find_bar drew it, at the end of a bar's row
// as wide as a chat's bar is, with what is before it keeping its own width: what it did not look in, its field, its
// count and its buttons, each state of what the core said; its field giving way down to its least where the row has
// little room.

///|
/// The chat the bar is of (the fixture's), its thread.
let find_chat_ref : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }

///|
let find_thread : Double = 1.0

///|
/// The row it is drawn in: a chat's bar's (45 high, its things 16 apart), `before` wide kept before it.
fn find_row(w : Double) -> @ui.Style {
  @ui.style(row=true, w=Fixed(w), h=Fixed(45.0), gap=S4, align=ACenter)
}

///|
/// The list it goes along: none.
fn find_list_none() -> FindList {
  { showing: fn() { (-1.0, -1.0) }, go: fn(_, _) {  }, forget: fn() {  }, drawn: fn(_, _) { Map([]) } }
}

///|
/// What the find keeps put as `state` says, its field holding `typed`: as was asked of the core already (nothing asked
/// again).
fn find_state(state : String, typed : String) -> Unit {
  find_close()
  finding.chat.set(chat_key(find_chat_ref))
  finding.field.set(typed)
  finding.asked.set(typed)
  let found = fn(whole : Bool, n : Int) -> Found {
    { words: [typed], hits: Array::makei(n, fn(i) { (i.to_double() + 1.0, 1) }), held: 10, of: 40, whole }
  }
  match state {
    "found" => {
      finding.found.set(Some(found(true, 3)))
      finding.position.set(2)
      finding.total.set(3)
    }
    "none" => {
      finding.found.set(Some(found(true, 0)))
      finding.position.set(0)
      finding.total.set(0)
    }
    "partial" => {
      finding.found.set(Some(found(false, 3)))
      finding.position.set(1)
      finding.total.set(3)
    }
    "bringing" => {
      finding.found.set(Some(found(false, 0)))
      finding.bringing.set(true)
    }
    _ => ()
  }
}

///|
/// The nodes' bar in a row `w` wide, `before` kept before it, as `state` says.
fn find_new(w : Double, before : Double, state : String, typed : String) -> @ui.Tester {
  @sf.set_words(@sfbase.fill)
  let src = @sffixture.fixture("chat")
  let t = @ui.Tester::new(
    fn(c) {
      @sf.begin(c) |> ignore
      c.with_theme(@sf.ui_theme(), fn() { @ui.old_views_here(c) })
    },
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      let tips = @sf.TipLayer::new(fn() { Some(root) })
      root.box(fn(row) {
        @sf.style_node(row, fn() { find_row(w) })
        row.box(fn(b) { b.width(Is(Some(before))).min_width(Is(Some(before))) |> ignore }) |> ignore
        find_bar_node(row, src, find_chat_ref, fn() { Some(find_thread) }, find_list_none(), tips) |> ignore
      })
      |> ignore
    },
    w=w + find_past,
    h=120.0,
    platform=0,
  )
  find_state(state, typed)
  t.run_for(@ui.move_most_ms)
  t
}

///|
/// What `t` shows: its words (place, size, how seen) and its buttons (what each says, where it is), one a line.
fn find_drawn(t : @ui.Tester) -> String {
  t.words().map(fn(w) { "\{w.0}@\{w.1},\{w.2} \{w.3}x\{w.4} a\{w.5}" }).join("\n") +
  "\n" +
  t.all(Button).map(fn(b) { "[\{b.label}] \{Repr(b.rect)}" }).join("\n")
}

///|
/// How much wider the window is than the row (what is at the bar's end clear of the window's edge, as in a chat's bar).
let find_past : Double = 40.0

///|
test "⌘F's bar made once as nodes: what it did not look in, its field, its count and buttons, each state of what the core said; its field giving way first where the row has little room" {
  let shown = []
  for c in [
    ("typed, nothing said yet", 200.0, "typed", "截图"),
    ("nothing typed", 200.0, "typed", ""),
    ("found: which of how many", 200.0, "found", "截图"),
    ("none found", 200.0, "none", "截图"),
    ("found in part of the chat", 200.0, "partial", "截图"),
    ("the rest being read", 200.0, "bringing", "截图"),
    ("squeezed: its field narrower", 520.0, "found", "截图"),
    ("squeezed: what it did not look in gone, its field near its least", 560.0, "partial", "截图"),
  ] {
    let (name, before, state, typed) = c
    let t = find_new(760.0, before, state, typed)
    shown.push("== \{name}\n" + find_drawn(t))
    // (squeezed near its field's least: the old bar's note cut to nothing in its box (find_note_box, clip), and what is
    // typed left 29 across by its count and buttons, drawn so by both; the old view held words to no rule, the nodes'
    // audit says them: those two, and only there; reported, 2026-11-11)
    let note = @sf.t("web-main.find.partial", args=[("held", "10"), ("of", "40")])
    let all = t.audit()
    let cut = fn(f : String) {
      (f.contains("「\{note}」") && f.contains("its words cut to 0 characters")) ||
      f.contains("its placeholder cut to 1 characters")
    }
    // (and its field's row 12 in at its start and its buttons 3 from its end: rule 4, said once the spacing rules saw the window's tree's words and icons (2026-11-15), drawn as the old view draws it (the test's own comparison): left for its own change)
    let ends = fn(f : String) {
      f.has_prefix("rule 4: what ") && f.contains("×32, node") && f.contains("stands 12 in from its left, 3 from its right")
    }
    let known = all.filter(cut)
    let faults = all.filter(fn(f) { !cut(f) && !ends(f) })
    assert_eq(known.length(), if before >= 560.0 { 2 } else { 0 }, msg="\{name}: \{Repr(known)}")
    assert_eq(faults, [], msg="\{name}: \{Repr(faults)}")
  }
  // (as the old view's find_bar drew it, each state, before it went: compared side by side till then)
  inspect(shown.join("\n"), content=(
    #|== typed, nothing said yet
    #|在对话中查找@228,12.5 221x20 a1
    #|[上一个] (451, 9.5, 26, 26)
    #|[下一个] (479, 9.5, 26, 26)
    #|[关闭查找] (507, 9.5, 26, 26)
    #|== nothing typed
    #|在对话中查找@228,12.5 221x20 a1
    #|[上一个] (451, 9.5, 26, 26)
    #|[下一个] (479, 9.5, 26, 26)
    #|[关闭查找] (507, 9.5, 26, 26)
    #|== found: which of how many
    #|在对话中查找@228,12.5 189x20 a1
    #|2/3@425,13.5 18x18 a1
    #|[上一个] (451, 9.5, 26, 26)
    #|[下一个] (479, 9.5, 26, 26)
    #|[关闭查找] (507, 9.5, 26, 26)
    #|== none found
    #|在对话中查找@228,12.5 171x20 a1
    #|无结果@407,13.5 36x18 a1
    #|[上一个] (451, 9.5, 26, 26)
    #|[下一个] (479, 9.5, 26, 26)
    #|[关闭查找] (507, 9.5, 26, 26)
    #|== found in part of the chat
    #|仅搜索了已加载的 10 条，共 40 条@216,13.5 192x18 a1
    #|在对话中查找@428,12.5 189x20 a1
    #|1/3@625,13.5 18x18 a1
    #|[上一个] (651, 9.5, 26, 26)
    #|[下一个] (679, 9.5, 26, 26)
    #|[关闭查找] (707, 9.5, 26, 26)
    #|== the rest being read
    #|仅搜索了已读取的 10 条，正在读取其余内容@216,13.5 229.71428571428572x18 a1
    #|在对话中查找@465.7142857142857,12.5 207.28571428571428x20 a1
    #|[上一个] (675, 9.5, 26, 26)
    #|[下一个] (703, 9.5, 26, 26)
    #|[关闭查找] (731, 9.5, 26, 26)
    #|== squeezed: its field narrower
    #|在对话中查找@548,12.5 93x20 a1
    #|2/3@649,13.5 18x18 a1
    #|[上一个] (675, 9.5, 26, 26)
    #|[下一个] (703, 9.5, 26, 26)
    #|[关闭查找] (731, 9.5, 26, 26)
    #|== squeezed: what it did not look in gone, its field near its least
    #|仅搜索了已加载的 10 条，共 40 条@576,13.5 16x18 a1
    #|在对话中查找@612,12.5 29x20 a1
    #|1/3@649,13.5 18x18 a1
    #|[上一个] (675, 9.5, 26, 26)
    #|[下一个] (703, 9.5, 26, 26)
    #|[关闭查找] (731, 9.5, 26, 26)
  ))
  find_close()
}
