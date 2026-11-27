// Unit tests for `data_table_node`, `toggle_table_sort`, and `page_fixed_node`:
// - 2-state and 3-state sort toggling (`toggle_table_sort`)
// - `Card` surface with `virtual_rows` (including `reused` / `make_reused`), content-hugging on few rows, internal
//   scrolling on overflow with fixed header, steady column-header text position across sort toggles, and empty state
// - `Plain` surface with non-virtualized `rows` (`capped_node`)
// - `page_fixed_node` wide fixed header + `lane_most_lent` (`max_width=920.0`) and narrow fallback

///|
fn dt_test_words(key : String, args? : Array[(String, String)] = []) -> String {
  dt_words(key, args~)
}

///|
test "toggle_table_sort supports 2-state and 3-state cycling" {
  let s2 : @signals.Signal[TableSort?] = @signals.signal(None)
  toggle_table_sort(s2, "name")
  assert_eq(s2.untracked(), Some({ col: "name", dir: Asc }))
  toggle_table_sort(s2, "name")
  assert_eq(s2.untracked(), Some({ col: "name", dir: Desc }))
  toggle_table_sort(s2, "name")
  assert_eq(s2.untracked(), Some({ col: "name", dir: Asc }))
  toggle_table_sort(s2, "mem", default_dir=Desc)
  assert_eq(s2.untracked(), Some({ col: "mem", dir: Desc }))
  toggle_table_sort(s2, "mem", default_dir=Desc)
  assert_eq(s2.untracked(), Some({ col: "mem", dir: Asc }))

  let s3 : @signals.Signal[TableSort?] = @signals.signal(None)
  toggle_table_sort(s3, "status", allow_clear=true)
  assert_eq(s3.untracked(), Some({ col: "status", dir: Asc }))
  toggle_table_sort(s3, "status", allow_clear=true)
  assert_eq(s3.untracked(), Some({ col: "status", dir: Desc }))
  toggle_table_sort(s3, "status", allow_clear=true)
  assert_eq(s3.untracked(), None)
}

///|
test "data_table_node Card virtual_rows: hugs few rows, scrolls internally on many rows, sort keeps header text steady" {
  let sort : @signals.Signal[TableSort?] = @signals.signal(None)
  let keys : @signals.Signal[Array[String]] = @signals.signal(["a", "b"])
  let t = @ui.Tester::new(fn(_) {  }, w=700.0, h=300.0, platform=0)
  @ui.set_view_app(fn(root) {
    root.box(fn(col) {
      col.width(Is(Some(640.0))).height(Is(Some(260.0))).padding(Is((12.0, 12.0, 12.0, 12.0))) |> ignore
      data_table_node(col, fn(dt) {
        dt.head(fn(h) {
          h.col(
            fn() { "Name" },
            sort_key="name",
            sort=fn() { sort.get() },
            on_sort=fn(c) { toggle_table_sort(sort, c, allow_clear=true) },
          )
          h.col(
            fn() { "Score" },
            width=fn() { Some(100.0) },
            align=End,
            sort_key="score",
            sort=fn() { sort.get() },
            on_sort=fn(c) { toggle_table_sort(sort, c, allow_clear=true) },
          )
        })
        dt.empty(fn(em) {
          words_node(em, fn() { "Empty table" }, fn() { desk_muted }) |> ignore
        })
        dt.virtual_rows(
          fn() { keys.get() },
          fn(r, k) {
            r.cell(fn(c) { words_node(c, fn() { "row-" + k }, fn() { theme().rows.title }) |> ignore })
            r.cell(
              fn(c) { words_node(c, fn() { k }, fn() { desk_muted }) |> ignore },
              width=fn() { Some(100.0) },
              align=End,
            )
          },
          est=44.0,
          reused=fn(_) { Some(0) },
          make_reused=fn(r, _, k_fn) {
            r.cell(fn(c) { words_node(c, fn() { "row-" + k_fn() }, fn() { theme().rows.title }) |> ignore })
            r.cell(
              fn(c) { words_node(c, k_fn, fn() { desk_muted }) |> ignore },
              width=fn() { Some(100.0) },
              align=End,
            )
          },
        )
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  // Few rows: table hugs content (< container height 236)
  let tbl_few = t.get(Table).rect
  assert_true(tbl_few.3 < 200.0, msg="few rows must hug content, got h=\{tbl_few.3}")
  // Header text x position stays steady when toggling sort on End-aligned column;
  // both Button action semantics and ColumnHeader direction semantics remain intact and localized.
  let score_before = t.find("Score").unwrap()
  let sort_btn_label = dt_test_words("web-main.resources.by", args=[("column", "Score")])
  assert_true(t.query(Button, label=sort_btn_label) is Some(_))
  t.click(Button, label=sort_btn_label)
  t.draw()
  assert_eq(sort.untracked(), Some({ col: "score", dir: Asc }))
  let asc_hdr = "Score, " + dt_test_words("common.sort.asc")
  assert_true(t.query(ColumnHeader, label=asc_hdr) is Some(_), msg="expected ColumnHeader \{asc_hdr}")
  assert_true(t.query(Button, label=sort_btn_label) is Some(_), msg="Button semantics must not be overwritten")
  let score_after = t.find("Score").unwrap()
  assert_true((score_before.0 - score_after.0).abs() < 0.5, msg="Score header shifted: \{score_before.0} -> \{score_after.0}")
  // Only the single hairline divider under the fixed header is drawn (no row-between dividers, matching station picker).
  let rule_divs = t.boxes_held().filter(fn(b) { (b.h - rule_w).abs() < 0.1 && b.bg == rule_color() })
  assert_eq(rule_divs.length(), 1, msg="expected only the single header divider, got \{rule_divs.length()}")
  // Theme toggle must not clobber Card header/row padding via style_node
  let name_x_light = t.find("Name").unwrap().0
  let row_x_light = t.find("row-a").unwrap().0
  set_dark(Some(true))
  t.draw()
  let name_x_dark = t.find("Name").unwrap().0
  let row_x_dark = t.find("row-a").unwrap().0
  set_dark(None)
  t.draw()
  assert_true((name_x_light - name_x_dark).abs() < 0.5, msg="Card header padding shifted on theme toggle: \{name_x_light} -> \{name_x_dark}")
  assert_true((row_x_light - row_x_dark).abs() < 0.5, msg="Card row padding shifted on theme toggle: \{row_x_light} -> \{row_x_dark}")
  // Many rows: table shrinks to fit container and scrolls internally while header stays fixed
  let many = Array::makei(30, fn(i) { "k" + i.to_string() })
  keys.set(many)
  t.run_for(@ui.move_most_ms)
  let tbl_many = t.get(Table).rect
  assert_true(tbl_many.3 <= 240.0, msg="many rows must fit container, got h=\{tbl_many.3}")
  let hdr_before = t.find("Name").unwrap().1
  t.wheel(tbl_many.0 + 100.0, tbl_many.1 + 120.0, 200.0)
  t.run_for(@ui.move_most_ms)
  let hdr_after = t.find("Name").unwrap().1
  assert_true((hdr_before - hdr_after).abs() < 0.5, msg="header must stay fixed while body scrolls")
  // Empty state renders when keys become empty
  keys.set([])
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("Empty table") is Some(_))
}

///|
test "data_table_node Plain rows renders non-virtualized rows and empty state" {
  let keys : @signals.Signal[Array[String]] = @signals.signal(["alpha", "beta"])
  let t = @ui.Tester::new(fn(_) {  }, w=500.0, h=400.0, platform=0)
  @ui.set_view_app(fn(root) {
    root.box(fn(col) {
      col.width(Is(Some(460.0))).padding(Is((12.0, 12.0, 12.0, 12.0))) |> ignore
      data_table_node(
        col,
        surface=Plain,
        max_height=fn() { 200.0 },
        fn(dt) {
          dt.head(fn(h) { h.col(fn() { "Item" }) })
          dt.empty(fn(em) { words_node(em, fn() { "No items" }, fn() { desk_muted }) |> ignore })
          dt.rows(fn() { keys.get() }, fn(r, k) {
            r.cell(fn(c) { words_node(c, fn() { k }, fn() { theme().rows.title }) |> ignore })
          })
        },
      )
      |> ignore
    })
    |> ignore
  })
  t.draw()
  assert_true(t.find("alpha") is Some(_) && t.find("beta") is Some(_))
  keys.set([])
  t.draw()
  assert_true(t.find("No items") is Some(_))
}

///|
test "page_fixed_node lends max_width on Wide and delegates to narrow_page_node on Narrow" {
  let w_sig = @signals.signal(1100.0)
  let t = @ui.Tester::new(fn(_) {  }, w=1100.0, h=500.0, platform=0)
  @ui.set_view_app(fn(root) {
    page_fixed_node(
      root,
      fn() { "Fixed Demo" },
      fn(s) {
        s.wide_body(fn(body) {
          data_table_node(body, fn(dt) {
            dt.head(fn(h) { h.col(fn() { "Column A" }) })
            dt.virtual_rows(
              fn() { Array::makei(20, fn(i) { "item-" + i.to_string() }) },
              fn(r, k) { r.cell(fn(c) { words_node(c, fn() { k }, fn() { theme().rows.title }) |> ignore }) },
            )
          })
          |> ignore
        })
        s.narrow_blocks(
          fn() { ["b1"] },
          fn(b, _) { words_node(b, fn() { "Narrow Body" }, fn() { theme().rows.title }) |> ignore },
        )
      },
      on_back=fn() {  },
      width=fn() { w_sig.get() },
      max_width=920.0,
    )
  })
  t.draw()
  let tbl_rect = t.get(Table).rect
  // 920 lane - 2*16 column_in = 888pt wide (wider than default 792 - 32 = 760pt)
  assert_true(tbl_rect.2 > 800.0, msg="expected max_width=920 lane, got table width=\{tbl_rect.2}")
  assert_true(t.find("Fixed Demo") is Some(_))
  // Narrow fallback
  w_sig.set(390.0)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("Narrow Body") is Some(_))
}

///|
test "data_table_node group_header renders non-hoverable section headers alongside reused data rows" {
  let keys : @signals.Signal[Array[String]] = @signals.signal(["g/a", "r/1", "g/b", "r/2"])
  let seen_kinds : Array[Int] = []
  let t = @ui.Tester::new(fn(_) {  }, w=700.0, h=400.0, platform=0)
  @ui.set_view_app(fn(root) {
    root.box(fn(col) {
      col.width(Is(Some(640.0))).height(Is(Some(360.0))).padding(Is((12.0, 12.0, 12.0, 12.0))) |> ignore
      data_table_node(col, fn(dt) {
        dt.head(fn(h) { h.col(fn() { "Account" }) })
        dt.group_header(
          fn(k) { k.has_prefix("g/") },
          fn(g, k_fn) {
            words_node(
              g,
              fn() { if k_fn() == "g/a" { "Group Alpha" } else { "Group Beta" } },
              fn() { theme().chat_list.heading_words },
            )
            |> ignore
          },
        )
        dt.virtual_rows(
          fn() { keys.get() },
          fn(r, k) { r.cell(fn(c) { words_node(c, fn() { "item-" + k }, fn() { theme().rows.title }) |> ignore }) },
          est=44.0,
          // Intentionally returns Some(0) for every key to verify `data_table_node` isolates group slots automatically.
          reused=fn(_) { Some(0) },
          make_reused=fn(r, kind, k_fn) {
            seen_kinds.push(kind)
            r.cell(fn(c) { words_node(c, fn() { "item-" + k_fn() }, fn() { theme().rows.title }) |> ignore })
          },
        )
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  assert_true(seen_kinds.length() > 0 && seen_kinds.iter().all(fn(k) { k == 0 }), msg="caller kind must be preserved as 0")
  let ga = t.find("Group Alpha").unwrap()
  let r1 = t.find("item-r/1").unwrap()
  let gb = t.find("Group Beta").unwrap()
  let r2 = t.find("item-r/2").unwrap()
  assert_true(ga.1 < r1.1 && r1.1 < gb.1 && gb.1 < r2.1, msg="groups and rows must render in order")
  // Single header divider only (no extra dividers between groups or rows)
  let rule_divs = t.boxes_held().filter(fn(b) { (b.h - rule_w).abs() < 0.1 && b.bg == rule_color() })
  assert_eq(rule_divs.length(), 1, msg="expected only the single header divider, got \{rule_divs.length()}")
}
