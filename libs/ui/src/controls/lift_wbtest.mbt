// A thing held for its menu, lifted over its sheet (lift_over), where it hangs past the window's foot (a tall picture in
// a message under the composer): pushed up before the sheet as it comes up, no further than it has come, from where
// it was, and back down with it as it goes.

///|
let lift_test_ground : Int64 = 0x22AA66FFL

///|
/// A row 66 high lifted over the scrim (View::over_scrim, a chat's row held for its menu) in a list cut to the window,
/// its foot 22 past the window's (a row held at the list's foot), under a 300 high tree sheet up while `open`.
fn lift_tree_hanging(open : @signals.Signal[Bool]) -> @ui.Tester {
  @ui.Tester::new(fn(_c) {  }, w=390.0, h=844.0, platform=2, tree=fn(root) {
    let place = fn() -> (Double, Double)? {
      if open.untracked() {
        Some((844.0 - 300.0, 300.0))
      } else {
        None
      }
    }
    tree_sheet_place.val = Some(place)
    root.owns(fn() {
      if tree_sheet_place.val is Some(f) && physical_equal(f, place) {
        tree_sheet_place.val = None
      }
    })
    |> ignore
    root.box(fn(list) {
      list.height(Is(Some(844.0))).clips(Is(true)) |> ignore
      list.box(fn(s) { s.height(Is(Some(800.0))).shrink(Is(0.0)) |> ignore }) |> ignore
      list.box(fn(row) {
        row.height(Is(Some(66.0))).shrink(Is(0.0)).ground(Is(lift_test_ground)).over_scrim(Is(true)) |> ignore
      })
      |> ignore
    })
    |> ignore
    root.show(fn() { open.get() }, fn(scrim) {
      scrim.over(Is(true)).scrim_under().ground(Is(sheet_scrim)) |> ignore
    })
  })
}

///|
test "a row lifted over the scrim, hanging past the list's foot: whole and clear of the sheet once it is up, back where it was as it goes" {
  let open = @signals.signal(false)
  let t = lift_tree_hanging(open)
  t.draw()
  let row = fn() { t.drawn_cut().filter(fn(d) { d.0 == 0 && d.3 == 390.0 && d.4 == 66.0 }) }
  let rest = row()
  assert_eq(rest.length(), 1)
  assert_eq(rest[0].2, 800.0)
  open.set(true)
  t.draw()
  let up = row()
  assert_eq(up.length(), 1)
  let (_, _, y, _, h, (_, cut_y0, _, cut_y1)) = up[0]
  // (the sheet's top, 300 up from the window's foot: the row 12 over it, nothing of it cut)
  assert_eq(y + h, 844.0 - 300.0 - 12.0)
  assert_true(cut_y0 <= y && cut_y1 >= y + h, msg="cut to \{cut_y0}..\{cut_y1}, drawn \{y}..\{y + h}")
  open.set(false)
  t.draw()
  assert_eq(row()[0].2, 800.0)
}
