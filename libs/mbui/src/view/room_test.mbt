// What is made by the room it is given (View::by_room): made by the width what holds it gives it as the layout comes
// to it, laid out in that same layout, what is under it placed by what it came to, nothing laid out again after.

///|
/// A tree whose column holds a box made by its room (`tiles` tiles of 100 a line, 10 tall each line, as many lines as
/// `lines` says) and a box under it; the ids of the box under it and of each tile made, as they are made.
fn room_tree(lines : @signals.Signal[Int]) -> (@view.Tree, Ref[@view.NodeId?], Array[@view.NodeId], Ref[Int]) {
  let under : Ref[@view.NodeId?] = Ref(None)
  let tiles : Array[@view.NodeId] = []
  let makes = Ref(0)
  let t = @view.Tree::new(
    fn(root) {
      root.box(fn(col) {
        col.padding(Is((10.0, 0.0, 10.0, 0.0))) |> ignore
        col.by_room(fn(held, room) {
          makes.val = makes.val + 1
          held.pick(at_once=true, fn() { ((room.width() / 100.0).to_int(), lines.get()) }, fn(v, k) {
            tiles.clear()
            for _ in 0..<k.1 {
              v.box(fn(line) {
                line.row(Is(true)) |> ignore
                for _ in 0..<k.0 {
                  line.box(fn(tile) {
                    tiles.push(tile.id())
                    tile.width(Is(Some(100.0))).height(Is(Some(10.0))).ground(Is(0xFF0000FFL)) |> ignore
                  })
                  |> ignore
                }
              })
              |> ignore
            }
          })
        })
        |> ignore
        col.box(fn(u) {
          under.val = Some(u.id())
          u.height(Is(Some(5.0))).ground(Is(0x00FF00FFL)) |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    time=fn() { 0.0 },
  )
  (t, under, tiles, makes)
}

///|
test "by_room: made by the width it is given as it is first laid out, what is under it placed by that in the same layout" {
  let lines = @signals.signal(2)
  let (t, under, tiles, makes) = room_tree(lines)
  assert_eq(makes.val, 0, msg="made as it is first laid out, not before: its room is not known before")
  let computes = t.work().computes
  t.frame(470.0, 300.0) |> ignore
  assert_eq(t.work().computes - computes, 1, msg="one layout")
  assert_eq(makes.val, 1)
  // (450 across: four of 100 a line)
  assert_eq(tiles.length(), 8)
  assert_eq(t.drawn_of(tiles[3]).map(fn(d) { d.x }), Some(310.0))
  assert_eq(t.drawn_of(under.val.unwrap()).map(fn(d) { d.y }), Some(20.0), msg="under its two lines")
}

///|
test "by_room: given another width, made again by it and laid out in that one layout; what it reads otherwise as ever" {
  let lines = @signals.signal(2)
  let (t, under, tiles, makes) = room_tree(lines)
  t.frame(470.0, 300.0) |> ignore
  let computes = t.work().computes
  t.frame(270.0, 300.0) |> ignore
  assert_eq(t.work().computes - computes, 1, msg="one layout for the window made narrower")
  assert_eq(tiles.length(), 4, msg="two a line")
  assert_eq(makes.val, 1, msg="made once: what read the room made again by it")
  assert_eq(t.drawn_of(tiles[1]).map(fn(d) { d.x }), Some(110.0))
  lines.set(3)
  let computes = t.work().computes
  t.frame(270.0, 300.0) |> ignore
  assert_eq(t.work().computes - computes, 1)
  assert_eq(tiles.length(), 6)
  assert_eq(t.drawn_of(under.val.unwrap()).map(fn(d) { d.y }), Some(30.0))
}

///|
test "by_room: as wide as it is still, nothing made again as the window grows taller" {
  let lines = @signals.signal(1)
  let (t, _, tiles, _) = room_tree(lines)
  t.frame(470.0, 300.0) |> ignore
  let first = tiles.copy()
  t.frame(470.0, 500.0) |> ignore
  assert_eq(tiles, first, msg="the same tiles")
}

///|
test "Room::tall: how tall what it holds comes to at its width, read in the same layout by what shows beside it" {
  // (words of 30 points a line, three lines at 100 across, one at 300: a toggle under them where they pass two lines)
  let wide = @signals.signal(100.0)
  let toggle : Ref[@view.NodeId?] = Ref(None)
  let t = @view.Tree::new(
    fn(root) {
      root.box(fn(col) {
        col.width(By(fn() { Some(wide.get()) })) |> ignore
        col.by_room(fn(held, room) {
          let body = held.box(fn(b) {
            b.measured(Is(0), fn(_, w) {
              let w = w.unwrap_or(300.0)
              (w, if w < 300.0 { 90.0 } else { 30.0 })
            })
            |> ignore
          })
          held.show(at_once=true, fn() { room.tall(body) > 60.0 }, fn(m) {
            toggle.val = Some(m.id())
            m.height(Is(Some(20.0))).ground(Is(0x0000FFFFL)) |> ignore
          })
        })
        |> ignore
      })
      |> ignore
    },
    time=fn() { 0.0 },
  )
  let computes = t.work().computes
  t.frame(400.0, 300.0) |> ignore
  assert_eq(t.work().computes - computes, 1, msg="one layout")
  assert_eq(t.drawn_of(toggle.val.unwrap()).map(fn(d) { d.y }), Some(90.0), msg="under its three lines")
  wide.set(300.0)
  let computes = t.work().computes
  t.frame(400.0, 300.0) |> ignore
  assert_eq(t.work().computes - computes, 1, msg="one layout")
  assert_eq(t.drawn_of(toggle.val.unwrap()), None, msg="one line: no toggle")
}

///|
test "by_room: what it makes saying its own box by its room is a fault, told, the layout ended whole" {
  // (told, not stopped (boundary_test's faults_kept): a test stopped in the middle of a layout leaves what the process
  // runs next to begin from there)
  let told = faults_kept(fn() {
    let t = @view.Tree::new(
      fn(root) {
        root.box(fn(col) {
          col.by_room(fn(held, room) {
            match held.parent() {
              Some(own) => own.height(By(fn() { Some(room.width() / 2.0) })) |> ignore
              None => ()
            }
          })
          |> ignore
        })
        |> ignore
      },
      time=fn() { 0.0 },
    )
    t.frame(400.0, 300.0) |> ignore
  })
  assert_eq(told, [
    "View::by_room: its own box said by the room it is given, as it is laid out by it: say it of what it holds",
  ])
  assert_eq(@signals.batch_depth(), 0)
}

///|
test "by_room: every word measured again as its room is laid out, its own box marked once all of it is laid out" {
  let tree : Ref[@view.Tree?] = Ref(None)
  let again = @signals.signal(false)
  let t = @view.Tree::new(
    fn(root) {
      root.box(fn(col) {
        col.by_room(fn(held, room) {
          // (as the system's size of words is asked of the host there, it changed: Tree::words_again)
          held.pick(at_once=true, fn() { room.width() > 0.0 && again.get() }, fn(_, now) {
            if now {
              tree.val.unwrap().words_again()
            }
          })
        })
        |> ignore
      })
      |> ignore
    },
    time=fn() { 0.0 },
  )
  tree.val = Some(t)
  t.frame(400.0, 300.0) |> ignore
  let redone = t.root().words_redone()
  again.set(true)
  t.frame(400.0, 300.0) |> ignore
  assert_eq(t.root().words_redone(), redone + 1, msg="told once, after its layout, not a fault in it")
}

///|
// A room grown down a column under a bar of its own height (a tab under a shell's bar): how tall it is given to be is
// told it as its width is, what it makes by that laid out in the same layout, and told again as the window is made
// taller, in that window's one layout.
test "Room::height: how tall it is given to be under what is over it, as the window's height changes, in one layout" {
  let given : Ref[Double?] = Ref(None)
  let fill : Ref[@view.NodeId?] = Ref(None)
  let t = @view.Tree::new(
    fn(root) {
      root.box(fn(col) {
        col.grow(Is(1.0)) |> ignore
        col.box(fn(bar) { bar.height(Is(Some(40.0))) |> ignore }) |> ignore
        col.by_room(fn(held, room) {
          held.box(fn(f) {
            fill.val = Some(f.id())
            f
            .height(By(fn() {
              given.val = room.height()
              room.height()
            }))
            .ground(Is(0xFF0000FFL))
            |> ignore
          })
          |> ignore
        })
        .grow(Is(1.0))
        .min_height(Is(Some(0.0)))
        |> ignore
      })
      |> ignore
    },
    time=fn() { 0.0 },
  )
  t.frame(300.0, 500.0) |> ignore
  assert_eq(given.val, Some(460.0), msg="the window's 500 less the bar's 40")
  assert_eq(t.drawn_of(fill.val.unwrap()).map(fn(d) { (d.y, d.h) }), Some((40.0, 460.0)), msg="laid out by it in that layout")
  let computes = t.work().computes
  t.frame(300.0, 700.0) |> ignore
  assert_eq(t.work().computes - computes, 1, msg="one layout for the taller window")
  assert_eq(given.val, Some(660.0))
  assert_eq(t.drawn_of(fill.val.unwrap()).map(fn(d) { d.h }), Some(660.0))
}

///|
/// A row of two boxes made by their room, sharing it evenly: the first holding one as tall as `left` says, the second
/// 30 tall with its ground on what it holds (`held`), `right` saying more of that `held` as it is made; the id of that
/// `held`.
fn room_row_tree(
  right : (@view.View) -> Unit,
  left? : @signals.Signal[Double] = @signals.signal(80.0, same=fn(a, b) { a == b }),
) -> (@view.Tree, Ref[@view.NodeId?]) {
  let held_right : Ref[@view.NodeId?] = Ref(None)
  let t = @view.Tree::new(
    fn(root) {
      root.box(fn(r) {
        r.row(Is(true)) |> ignore
        r.by_room(fn(held, _) {
          held.box(fn(b) { b.height(By(fn() { Some(left.get()) })) |> ignore }) |> ignore
        })
        .grow(Is(1.0))
        .basis(Is(Some(0.0)))
        |> ignore
        r.by_room(fn(held, _) {
          held_right.val = Some(held.id())
          held.ground(Is(0x0000FFFFL)) |> ignore
          right(held)
          held.box(fn(b) { b.height(Is(Some(30.0))) |> ignore }) |> ignore
        })
        .grow(Is(1.0))
        .basis(Is(Some(0.0)))
        |> ignore
      })
      |> ignore
    },
    time=fn() { 0.0 },
  )
  (t, held_right)
}

///|
test "by_room: what it holds fills its box stretched taller across a row, beside one taller, in the first layout" {
  let (t, held) = room_row_tree(fn(_) {  })
  t.frame(300.0, 200.0) |> ignore
  let d = t.drawn_of(held.val.unwrap())
  assert_eq(d.map(fn(d) { d.h }), Some(80.0), msg="as tall as the one beside it")
  assert_eq(d.map(fn(d) { d.w }), Some(150.0))
}

///|
test "by_room: what it holds filling its box across a row follows the one beside it down, never kept as tall as it was" {
  let left = @signals.signal(80.0, same=fn(a, b) { a == b })
  let (t, held) = room_row_tree(fn(_) {  }, left~)
  t.frame(300.0, 200.0) |> ignore
  assert_eq(t.drawn_of(held.val.unwrap()).map(fn(d) { d.h }), Some(80.0))
  left.set(50.0)
  t.frame(300.0, 200.0) |> ignore
  assert_eq(t.drawn_of(held.val.unwrap()).map(fn(d) { d.h }), Some(50.0))
  left.set(10.0)
  t.frame(300.0, 200.0) |> ignore
  assert_eq(t.drawn_of(held.val.unwrap()).map(fn(d) { d.h }), Some(30.0), msg="as tall as what it holds, the taller")
}

///|
test "by_room: what it holds kept as tall as what it holds where it says it grows no more" {
  let (t, held) = room_row_tree(fn(h) { h.grow(Is(0.0)) |> ignore })
  t.frame(300.0, 200.0) |> ignore
  assert_eq(t.drawn_of(held.val.unwrap()).map(fn(d) { d.h }), Some(30.0))
}

///|
test "by_room: how much what it holds grows still taken by sets_together the first time it sets it, later" {
  let tight = @signals.signal(false, same=fn(a, b) { a == b })
  let (t, held) = room_row_tree(fn(h) {
    h.sets_together(fn() { tight.get() }, fn(k) {
      h.ground(Is(0x00FF00FFL)) |> ignore
      if k {
        h.grow(Is(0.0)) |> ignore
      }
    })
    |> ignore
  })
  t.frame(300.0, 200.0) |> ignore
  assert_eq(t.drawn_of(held.val.unwrap()).map(fn(d) { d.h }), Some(80.0))
  tight.set(true)
  t.frame(300.0, 200.0) |> ignore
  assert_eq(t.drawn_of(held.val.unwrap()).map(fn(d) { d.h }), Some(30.0), msg="set by it, nothing else binding it")
}

///|
test "by_room: as tall as what it holds down a column, what it holds makes its way there to another height (View::resizes), no fault" {
  let h = @signals.signal(40.0, same=fn(a, b) { a == b })
  let held : Ref[@view.View?] = Ref(None)
  let unders : Array[Double] = []
  let told = resizes_faults(fn() {
    let t = @view.Tree::new(sources=true, fn(root) {
      root.box(fn(col) {
        col.by_room(fn(f, _) {
          held.val = Some(f)
          f.box(fn(b) { b.height(By(fn() { Some(h.get()) })).shrink(Is(0.0)) |> ignore }) |> ignore
        })
        |> ignore
        col.box(fn(b) { b.height(Is(Some(20.0))).shrink(Is(0.0)).words(Is("下")) |> ignore }) |> ignore
      })
      |> ignore
    })
    t.frame(390.0, 844.0) |> ignore
    unders.push(rc_y(t, "下"))
    t.event(100.0, fn() {
      held.val.unwrap().resizes() |> ignore
      h.set(90.0)
    })
    for at in [100.0, 200.0, 2000.0] {
      t.at(at)
      t.frame(390.0, 844.0) |> ignore
      unders.push(rc_y(t, "下"))
    }
  })
  assert_eq(told, [], msg="\{Repr(told)}")
  assert_eq(unders[0], 40.0)
  assert_true(unders[2] > 40.0 && unders[2] < 90.0, msg="on its way: \{Repr(unders)}")
  assert_eq(unders[3], 90.0)
}

///|
test "by_room: what it holds stretched across a row grows there even where it is the tallest: View::resizes on it a fault" {
  let left : Ref[@view.View?] = Ref(None)
  let told = resizes_faults(fn() {
    let t = @view.Tree::new(sources=true, fn(root) {
      root.box(fn(r) {
        r.row(Is(true)) |> ignore
        r.by_room(fn(held, _) {
          left.val = Some(held)
          held.box(fn(b) { b.height(Is(Some(80.0))) |> ignore }) |> ignore
        })
        .grow(Is(1.0))
        .basis(Is(Some(0.0)))
        |> ignore
        r.by_room(fn(held, _) { held.box(fn(b) { b.height(Is(Some(30.0))) |> ignore }) |> ignore })
        .grow(Is(1.0))
        .basis(Is(Some(0.0)))
        |> ignore
      })
      |> ignore
    })
    t.frame(300.0, 200.0) |> ignore
    t.event(100.0, fn() { left.val.unwrap().resizes() |> ignore })
    t.at(100.0)
    t.frame(300.0, 200.0) |> ignore
  })
  assert_eq(told.length(), 1, msg="\{Repr(told)}")
  assert_true(told[0].contains("it is grown (grow 1)"), msg=told[0])
}
