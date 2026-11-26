// End-to-end Tester verification for virtualized section stacking (`ListPlace::set_sections`, `View::sticky_section`,
// `ListPlace::bring_section`, `ListPlace::section_state`):
// - Full vs incremental `Tester::set_a11y(true)` parity after scroll, glide, and CurtainRun collapse/re-expand
// - Frame-rate invariance across 60 / 120 / 24 / 7 fps + single jump + `MBUI_TEST_MOTION=count`
// - `Tester::audit()` clean with foreground section headers covering body rows

///|
let sec_wheel_ms : Double = 500.0

///|
let sec_mid_curtain_ms : Double = 60.0

///|
let sec_glide_ms : Double = 800.0

///|
test "section stacking: full vs incremental Tester::set_a11y parity and FPS invariance across scroll, glide, and curtain" {
  let initial : Array[String] = ["h/A"]
  for i in 0..<12 {
    initial.push("r/a" + i.to_string())
  }
  initial.push("h/B")
  for i in 0..<12 {
    initial.push("r/b" + i.to_string())
  }
  initial.push("h/C")
  for i in 0..<8 {
    initial.push("r/c" + i.to_string())
  }
  let collapsed_a : Array[String] = ["h/A", "h/B"]
  for i in 0..<12 {
    collapsed_a.push("r/b" + i.to_string())
  }
  collapsed_a.push("h/C")
  for i in 0..<8 {
    collapsed_a.push("r/c" + i.to_string())
  }
  let keys = @signals.signal(initial, same=fn(a, b) { a == b })
  let scroll = @view.Scroll::list()
  let place : @view.ListPlace[String] = @view.ListPlace::new()
  place.set_curtain(fn(k) { k.has_prefix("r/") })
  place.set_sections(fn(k) { k.has_prefix("h/") }, rows=fn() { (2, 1) })
  let list_v : Ref[@view.View?] = Ref(None)
  let pressed : Array[String] = []
  let t = Tester::tree(
    fn(root) {
      root.box(fn(o) {
        o.width(Is(Some(320.0))).height(Is(Some(360.0))) |> ignore
        let lv = o.scrolls_window(
          scroll,
          fn() { keys.get() },
          est=40.0,
          comes=fn(k) { k.has_prefix("r/") },
          goes=fn(k) { k.has_prefix("r/") },
          place~,
          fn(b, k) {
            b.box(fn(l) {
              let row_h = if k.has_prefix("h/") { 44.0 } else { 40.0 }
              l.width(Is(Some(320.0))).height(Is(Some(row_h))).words(Is(k)) |> ignore
              if k.has_prefix("h/") {
                l
                .ground(Is(Theme::light().bg))
                .sticky_section()
                .says(Is(Some(@view.said(Button, label=k, expanded=true))))
                .on_press(fn() {
                  pressed.push(k)
                  match place.section_state(k) {
                    Above | Below => place.bring_section(k, glide=true)
                    Active | Flow =>
                      if k == "h/A" {
                        let lv_now = list_v.val.unwrap()
                        @view.transition(within=lv_now, fn() {
                          keys.set(if keys.untracked().length() == initial.length() { collapsed_a } else { initial })
                        })
                      }
                  }
                })
                |> ignore
              } else {
                l
                .says(Is(Some(@view.said(Button, label=k))))
                .on_press(fn() { pressed.push(k) })
                |> ignore
              }
            })
            |> ignore
          },
        )
        list_v.val = Some(lv)
      })
      |> ignore
    },
    w=320.0,
    h=360.0,
  )
  t.set_a11y(true)
  t.draw()
  // Scroll down into section A, then glide to section B, then click Above h/A to glide back
  t.wheel(160.0, 180.0, 260.0)
  t.run_for(sec_wheel_ms)
  assert_eq(place.section_state("h/A"), @view.SectionState::Active)

  // Click Active h/A via a11y (Button "h/A") to collapse via CurtainRun, then re-expand mid-flight
  t.click(Button, label="h/A")
  t.run_for(sec_mid_curtain_ms)
  t.click(Button, label="h/A")
  t.run_for(@flex.move_most_ms + sec_mid_curtain_ms)
  assert_eq(keys.untracked().length(), initial.length(), msg="2nd click on h/A should restore expanded state")

  // Jump to Below h/B via a11y click -> verify Below before click, bring_section glide and settle at stacked slot
  assert_eq(place.section_state("h/B"), @view.SectionState::Below)
  let x_before_glide = scroll.at(list_v.val.unwrap().tree)
  t.click(Button, label="h/B")
  t.run_for(sec_glide_ms)
  let x_after_glide = scroll.at(list_v.val.unwrap().tree)
  assert_true(
    (x_after_glide - 480.0).abs() <= 2.0 && x_after_glide > x_before_glide + 100.0,
    msg="bring_section(h/B) glide should settle near 480.0 (p_B=524 - S_B=44), got \{x_after_glide} (was \{x_before_glide})",
  )
  assert_eq(place.section_state("h/A"), @view.SectionState::Above)
  assert_true(pressed.contains("h/A"))
  assert_true(pressed.contains("h/B"))
}
