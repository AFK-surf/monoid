// The parts as the hand and a screen reader meet them, and as mbui's audit holds them: a button pressed by Activate and
// by Tab and Enter, never while disabled or at work; a segmented choice chosen by a press and by an arrow key; a
// switch and a checkbox turned; a divided column's lines counted as its parts hide; the numbers the scale and the
// colours are worked out by.

///|
/// A Tester of a `w` × `h` window, `make` making its tree on the canvas, light or dark, drawn.
fn case(make : (@view.View) -> Unit, dark? : Bool = false, w? : Double = 900.0, h? : Double = 600.0) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w~, h~, platform=0)
  set_dark(Some(dark))
  set_type_root()
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme)
    root.box(fn(page) {
      page
      .grow(Is(1.0))
      .padding(Is(pad_all(S20)))
      .gap(Is(S12.pt()))
      .ground(By(fn() { palette().canvas }))
      |> ignore
      make(page)
    })
    |> ignore
  })
  t.draw()
  t
}

///|
/// How long anything a structure makes or lets go takes at most to be there or gone.
let move_most : Double = @ui.move_most_ms

///|
test "whole_rem puts a size of the scale on whole device pixels" {
  assert_eq(whole_rem(13.0, 14.0), 13.0)
  assert_eq(whole_rem(13.0, 16.0), 15.0)
  assert_eq(whole_rem(13.0, 15.0, pixel_scale=2.0), 14.0)
  assert_eq(whole_rem(22.0, 15.0, pixel_scale=3.0), 23.666666666666668)
  assert_eq(whole_rem(12.0, 14.0, pixel_scale=0.0), 12.0)
}

///|
test "a compact screen keeps a phone's 16 for what a control says" {
  set_type_root(compact=true)
  let compact = (Ui.size(), Ui.line_height(), Title.size())
  set_type_root()
  let wide = (Ui.size(), Ui.line_height(), Title.size())
  assert_eq((compact, wide), ((16.0, 22.0, 24.0), (13.0, 18.0, 22.0)))
}

///|
test "concentric corners: what lies in a corner is as round as it less the distance" {
  assert_eq(
    (concentric_radius(12.0, 6.0), concentric_radius(16.0, 8.0), concentric_radius(8.0, 12.0), control_radius),
    (6.0, 8.0, 0.0, 6.0),
  )
  assert_eq((S12.less(), S8.less(), S0.less(), S2.less()), (S8, S6, S0, S0))
}

///|
test "oklch: white, black and sRGB's own red" {
  assert_eq(oklch(1.0, 0.0, 0.0), 0xFFFFFFFFL)
  assert_eq(oklch(0.0, 0.0, 0.0), 0x000000FFL)
  assert_eq(oklch(0.627955, 0.257683, 29.2339), 0xFF0000FFL)
  assert_eq(oklch(1.0, 0.0, 0.0, alpha=0.5) & 0xFFL, 0x80L)
}

///|
test "a button is pressed by Activate and by Tab then Enter; a disabled one and one at work take neither" {
  let (pressed, off, busy) = (Ref(0), Ref(0), Ref(0))
  let t = case(fn(p) {
    p.box(fn(r) {
      r.row(Is(true)).gap(Is(S8.pt())) |> ignore
      button(r, fn() { "Save" }, fn() { pressed.val += 1 }, intent=Primary) |> ignore
      button(r, fn() { "Later" }, fn() { off.val += 1 }, disabled=fn() { true }) |> ignore
      button(r, fn() { "Saving" }, fn() { busy.val += 1 }, busy=fn() { true }) |> ignore
    })
    |> ignore
  })
  t.act(Button, Activate, label="Save")
  t.act(Button, Activate, label="Later")
  t.act(Button, Activate, label="Saving")
  t.tab()
  let focused = t.focused().map(fn(s) { s.label })
  t.enter()
  t.tab()
  let after = t.focused().map(fn(s) { s.label })
  let passed = after != Some("Later") && after != Some("Saving")
  assert_eq((pressed.val, off.val, busy.val, focused, passed), (2, 0, 0, Some("Save"), true))
}

///|
test "a segmented choice is chosen by a press and stepped by the arrow keys" {
  let chosen = @signals.signal(0)
  let t = case(fn(p) {
    segmented(p, fn() { "Period" }, ["Day", "Week", "Month"], fn() { chosen.get() }, fn(i) { chosen.set(i) }) |> ignore
  })
  t.act(Radio, Activate, label="Month")
  t.run_for(move_most)
  let pressed = chosen.get()
  t.tab()
  t.key(3)
  t.run_for(move_most)
  let stepped = chosen.get()
  assert_eq((pressed, stepped, t.get(Radio, label="Week").check), (2, 1, Some(On)))
}

///|
test "a switch and a checkbox turn as they are activated, read out on and off" {
  let (sync, digest) = (@signals.signal(true), @signals.signal(false))
  let t = case(fn(p) {
    switch_(p, fn() { sync.get() }, fn(v) { sync.set(v) }, fn() { "Sync" }) |> ignore
    checkbox(p, fn() { digest.get() }, fn(v) { digest.set(v) }, fn() { "Digest" }) |> ignore
  })
  let was = (t.get(Switch, label="Sync").check, t.get(Checkbox, label="Digest").check)
  t.act(Switch, Activate, label="Sync")
  t.act(Checkbox, Activate, label="Digest")
  t.run_for(move_most)
  let now = (t.get(Switch, label="Sync").check, t.get(Checkbox, label="Digest").check)
  assert_eq((was, now), ((Some(On), Some(Off)), (Some(Off), Some(On))))
}

///|
/// The lines a frame draws between parts (`divider_name`).
fn lines_drawn(t : @ui.Tester) -> Int {
  t.locate("icon:divider").length()
}

///|
test "a divided column draws a line only between two parts that show, whichever hide" {
  let shows = [@signals.signal(true), @signals.signal(true), @signals.signal(true), @signals.signal(true)]
  let t = case(fn(p) {
    card(p, fn(c) {
      divided_column(
        c,
        shows.mapi(fn(i, s) {
          (fn() { s.get() }, fn(v : @view.View) { list_row(v, fn() { "Part \{i}" }) |> ignore })
        }),
      )
      |> ignore
    })
    |> ignore
  })
  let all = lines_drawn(t)
  // (one between: three left, two lines, none doubled)
  shows[1].set(false)
  t.run_for(move_most)
  let middle = lines_drawn(t)
  // (the first too: none hanging over the second, now the first that shows)
  shows[0].set(false)
  t.run_for(move_most)
  let first = lines_drawn(t)
  // (the last too: none hanging under the one left before it)
  shows[3].set(false)
  t.run_for(move_most)
  let last = lines_drawn(t)
  shows[0].set(true)
  shows[1].set(true)
  t.run_for(move_most)
  let back = lines_drawn(t)
  assert_eq((all, middle, first, last, back), (3, 2, 1, 0, 2))
}

///|
test "every part at rest, light and dark, wide and narrow, holds to mbui's audit" {
  let faults = []
  for dark in [false, true] {
    for w in [900.0, 360.0] {
      let t = case(dark~, w~, h=900.0, fn(p) {
        p.box(fn(r) {
          r.row(Is(true)).gap(Is(S8.pt())).wraps(Is(Some(S8.pt()))).lines_up(Is(Some(Middle))) |> ignore
          for i in [Primary, Secondary, Ghost, Destructive] {
            button(r, fn() { "Button" }, fn() {  }, intent=i) |> ignore
          }
          button(r, fn() { "New" }, fn() {  }, intent=Primary, leading=Plus) |> ignore
          button(r, fn() { "Open" }, fn() {  }, trailing=Arrow) |> ignore
          button(r, fn() { "Find" }, fn() {  }, intent=Ghost, leading=Search, icon_only=true) |> ignore
        })
        |> ignore
        segmented(p, fn() { "Period" }, ["Day", "Week", "Month"], fn() { 1 }, fn(_) {  }) |> ignore
        card(p, fn(c) {
          card_head(c, fn() { "Inbox" }, note=fn() { "Three things need you today." }) |> ignore
          list_row(
            c,
            fn() { "A row whose words take more than one line where the window is narrow enough to wrap them" },
            note=fn() { "Its note under it, wrapping too, starting where the title starts." },
            leading=Inbox,
            trailing=fn(e) { meta(e, fn() { "2h" }, icon=Calendar) |> ignore },
            press=fn() {  },
          )
          |> ignore
          list_row(c, fn() { "Sync" }, trailing=fn(e) {
            switch_(e, fn() { true }, fn(_) {  }, fn() { "Sync" }) |> ignore
          })
          |> ignore
          list_row(c, fn() { "Digest" }, leading=Bell, trailing=fn(e) { tag(e, fn() { "New" }) |> ignore }, press=fn() {  })
          |> ignore
        })
        |> ignore
        card(p, gap=S6, fn(c) {
          card_head(c, fn() { "Archive 3 projects?" }, note=fn() { "They leave every list." }) |> ignore
          card_footer(c, fn(f) {
            button(f, fn() { "Archive projects" }, fn() {  }, intent=Primary) |> ignore
            button(f, fn() { "Keep them" }, fn() {  }) |> ignore
            button(f, fn() { "Remind me later" }, fn() {  }, intent=Ghost) |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      t.run_for(move_most)
      for f in t.audit() {
        faults.push((dark, w, f))
      }
    }
  }
  debug_inspect(faults, content="[]")
}

///|
test "a card's footer too narrow for its actions wraps the other way: the main one stays at its foot, on its left" {
  let t = case(w=300.0, fn(p) {
    card(p, fn(c) {
      card_footer(c, fn(f) {
        button(f, fn() { "Archive projects" }, fn() {  }, intent=Primary) |> ignore
        button(f, fn() { "Keep them" }, fn() {  }) |> ignore
        button(f, fn() { "Remind me later" }, fn() {  }, intent=Ghost) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  let main = t.get(Button, label="Archive projects").rect
  let other = t.get(Button, label="Remind me later").rect
  let card_left = 20.0
  // (the main one 6 in from the card's left, on the lowest line; the last over it)
  assert_eq((main.0 - card_left - 1.0 <= 6.0 && main.0 - card_left >= 6.0 - 0.5, other.1 < main.1), (true, true))
  debug_inspect(t.audit(), content="[]")
}
