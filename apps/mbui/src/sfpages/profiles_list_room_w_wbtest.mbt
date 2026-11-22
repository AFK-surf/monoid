// Exact-width verification for profiles_list_node's pl_account_quota_room_w across Wide/Narrow and
// standalone/pane_lent layouts, ensuring quota_worded_node skips per-row View::by_room accurately.

///|
fn profiles_list_room_w_data() -> Json {
  {
    "items": [
      {
        "key": "st1/cc",
        "station": "st1",
        "group": "claude",
        "groupTitle": "Claude",
        "title": "Claude 主账号",
        "usable": true,
        "profile": {
          "id": "cc",
          "name": "Claude 主账号",
          "runtime": "claude",
          "planText": "Max",
          "access": { "kind": "subscription" },
          "quota": {
            "state": "ok",
            "windows": [
              { "label": "5 小时", "mark": "5H", "left": 80.0, "level": "ok" },
              { "label": "每周", "mark": "W", "left": 65.0, "level": "ok" },
            ],
          },
        },
      },
    ],
  }
}

///|
fn find_list_quota_width(boxes : Array[@ui.Laid], chip_text : String) -> (Double, String) {
  let mut text_idx = -1
  for i, b in boxes {
    if b.text == chip_text {
      text_idx = i
      break
    }
  }
  if text_idx < 0 {
    let texts = boxes.filter(fn(b) { b.text != "" }).map(fn(b) { b.text }).join(", ")
    return (-1.0, "text \{chip_text} not found; texts=[\{texts}]")
  }
  // Walk up from chip text to the link_row_node hit target (`r`).
  // Chain: r(link_row, hit=true) -> words -> below -> pl_quota_node(w) -> x(quota_worded_node) -> ... -> chip_text
  let chain : Array[Int] = []
  let mut cur = text_idx
  while cur >= 0 {
    chain.push(cur)
    if boxes[cur].hit {
      break
    }
    cur = boxes[cur].parent
  }
  let desc = chain.map(fn(i) { "(\{boxes[i].w},hit=\{boxes[i].hit})" }).join(" -> ")
  let n = chain.length()
  if n < 5 || !boxes[chain[n - 1]].hit {
    return (-1.0, "hit row not in chain: \{desc}")
  }
  // pl_quota_node(w) is 3 steps below r (r -> words -> below -> w)
  (boxes[chain[n - 4]].w, desc)
}

///|
test "profiles_list_node pl_account_quota_room_w matches laid-out pl_quota_node width across Wide, Narrow, and pane_lent" {
  let cases : Array[(String, Double, Bool, Int)] = [
    ("Wide standalone 1280", 1280.0, false, 0),
    ("Wide standalone 700", 700.0, false, 0),
    ("Wide in pane_lent 700", 700.0, true, 0),
    ("Narrow standalone 390", 390.0, false, 2),
    ("Narrow in pane_lent 390", 390.0, true, 0),
  ]
  for c in cases {
    let (tag, page_w, in_pane, platform) = c
    @sfbase.reset()
    reset()
    @settings.reset()
    @sf.presenters_reset()
    @sf.set_words(@sfbase.fill)
    let ws : Workspace = { id: "ws-list-rw", name: "W", emoji: "", icon: "", email: "" }
    let src = @sfbase.made_source(
      topic=fn(name, _) { if name == "profiles" { Some(profiles_list_room_w_data()) } else { None } },
    )
    let core = @sfbase.settings_core(src, ws)
    let here = fn() { @settings.here_of(core, ws.id, ws.name) }
    let frame = fn() -> PageFrame { { back: None, top: 0.0, foot: 0.0, named: false } }
    let t = @ui.Tester::new(fn(ctx) { @sf.begin(ctx) |> ignore }, w=page_w, h=700.0, platform~)
    @ui.set_view_app(fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      if in_pane {
        root.lends(@sf.pane_lent, true) |> ignore
      }
      root.box(fn(p) {
        p.width(Is(Some(page_w))).height(Is(Some(700.0))) |> ignore
        profiles_list_node(p, core, here, "", on_back=fn() {  }, frame~, width=fn() { page_w })
      })
      |> ignore
    })
    t.draw()
    let (actual, desc) = find_list_quota_width(t.boxes_held(), "80%")
    assert_true(actual > 0.0, msg="\{tag}: quota chip box not found: \{desc}")
    // Compute expected via pl_account_quota_room_w with a synthetic node that has the same look + pane_lent
    let wide = @sf.look_for(page_w) is Wide
    let card_pad = if in_pane { @sf.corner_inset } else { @sf.list_pad }
    let block_w = if wide {
      let lane_side = if in_pane { 0.0 } else { @sf.desk_lane_in }
      let avail = page_w - 2.0 * lane_side
      let col_w = if avail < @sf.desk_lane_most { avail } else { @sf.desk_lane_most }
      col_w - 2.0 * @sf.desk_column_in
    } else {
      let room_side = if in_pane { @sf.panel_card_in } else { 12.0 }
      page_w - 2.0 * room_side
    }
    let expected = block_w - 2.0 * card_pad - @sf.text_in - @sf.corner_inset
    assert_true(
      (expected - actual).abs() <= 0.01,
      msg="\{tag}: expected room_w=\{expected}, actual laid width=\{actual}",
    )
    assert_eq(t.audit(), [], msg="\{tag}: audit failed")
  }
}
