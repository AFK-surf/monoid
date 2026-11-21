// Exact-width verification for profiles_side_node's quota room_w across Side, Tape, and touch themes,
// ensuring nav_quota_chips_node skips per-row View::by_room without rebuilding rows on width changes.

///|
fn profiles_side_room_w_data() -> Json {
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
fn test_side_at(laid_w : Double, tape : Bool) -> SideAt {
  {
    box: (0.0, 0.0, laid_w, 600.0),
    laid_w,
    block: (0.0, 0.0, laid_w, 600.0),
    ground: 0L,
    shadow: (0.0, 0.0, 0L),
    links: None,
    round: 0.0,
    edge: (0.0, 0L),
    shown: true,
    brand: 0.0,
    band: 0.0,
    list_brand: 0.0,
    list_band: 0.0,
    bar: false,
    tape,
  }
}

///|
fn find_side_quota_width(boxes : Array[@ui.Laid], chip_text : String) -> (Double, String) {
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
  // Walk up from chip text to the nav_item_node hit target (`r`).
  // Chain: button(r, hit=true) -> t -> fb -> x(nav_quota_chips_node) -> ... -> chip_text
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
  if n < 4 || !boxes[chain[n - 1]].hit {
    return (-1.0, "hit row not in chain: \{desc}")
  }
  // x is 3 steps below button (button -> t -> fb -> x)
  (boxes[chain[n - 4]].w, desc)
}

///|
test "profiles_side_node quota room_w matches laid-out nav_quota_chips_node width across Side, Tape, and touch" {
  let cases : Array[(String, Int, Bool, Array[Double])] = [
    ("desktop Side", 0, false, [260.0, 320.0]),
    ("desktop Tape", 0, true, [300.0]),
    ("touch Side", 2, false, [300.0]),
  ]
  for c in cases {
    let (tag, platform, tape, widths) = c
    @sfbase.reset()
    @sf.set_words(@sfbase.fill)
    let src = @sfbase.made_source(
      topic=fn(name, _) {
        match name {
          "workspaces" =>
            Some(
              Json::array([
                Json::object({
                  "loaded": true,
                  "account": { "email": "a@b.c" },
                  "workspaces": [{ "id": "ws-side-rw", "name": "W" }],
                }),
              ]),
            )
          "prefs" => Some(Json::object({ "workspace": "ws-side-rw" }))
          "profiles" => Some(profiles_side_room_w_data())
          _ => None
        }
      },
    )
    let laid_w = @signals.signal(widths[0])
    let list_at : @sf.ListAt = if tape { Tape } else { Side }
    let t = @ui.Tester::new(fn(ctx) { @sf.begin(ctx) |> ignore }, w=400.0, h=600.0, platform~)
    @ui.set_view_app(fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      let popup = root.box(fn(v) { v.over(Is(true)) |> ignore })
      let tips = @sf.TipLayer::new(fn() { Some(popup) })
      root.box(fn(s) {
        s.width(By(fn() { Some(laid_w.get()) })).height(Is(Some(600.0))) |> ignore
        profiles_side_node(s, src, tips, fn() { test_side_at(laid_w.get(), tape) })
      })
      |> ignore
    })
    t.draw()
    for i, w in widths {
      if i > 0 {
        laid_w.set(w)
        t.frame()
      }
      let (actual, desc) = find_side_quota_width(t.boxes_held(), "80%")
      assert_true(actual > 0.0, msg="\{tag} w=\{w}: quota chip box not found: \{desc}")
      let expected = profiles_side_quota_room_w(fn() { laid_w.get() }, list_at)()
      assert_true(
        (expected - actual).abs() <= 0.01,
        msg="\{tag} w=\{w}: expected room_w=\{expected}, actual laid width=\{actual}, chain=\{desc}",
      )
      assert_eq(t.audit(), [], msg="\{tag} w=\{w}: audit failed")
    }
  }
}
