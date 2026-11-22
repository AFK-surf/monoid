// A row of ways of saying one thing (View::one_of): the first that fits its room whole laid out and drawn, the last
// where none does; another as the room changes, in the frame laid out at that room, nothing coming or going.

///|
/// A row as wide as the window (16 down, at its left) of two ways of saying one thing: `wide`, a row of a box 120 wide
/// and one 80 wide (200 in all); `narrow`, the same two one over the other (120 wide). Each box's id by its name
/// (a1, b1 of the first; a2, b2 of the second). Laid out once, `w` wide.
fn one_of_row(ids : Map[String, @view.NodeId], w : Double) -> @view.Tree {
  let t = @view.Tree::new(
    fn(root) {
      root.box(fn(row) {
        row.over(Is(true)).row(Is(true)).one_of(Is(true)).offset(Is((0.0, 16.0))).width(By(fn() { Some(row.window().0) })) |> ignore
        for way in [1, 2] {
          row.box(fn(o) {
            o.row(Is(way == 1)).shrink(Is(0.0)) |> ignore
            for part in [("a", 120.0), ("b", 80.0)] {
              o.box(fn(b) {
                ids["\{part.0}\{way}"] = b.id()
                b.width(Is(Some(part.1))).height(Is(Some(16.0))).shrink(Is(0.0)).ground(Is(0xFF336699L)) |> ignore
              })
              |> ignore
            }
          })
          |> ignore
        }
      })
      |> ignore
    },
    time=fn() { 0.0 },
  )
  t.frame(w, 300.0) |> ignore
  t
}

///|
/// Where box `name` is drawn (x, y), if it is.
fn one_of_at(t : @view.Tree, ids : Map[String, @view.NodeId], name : String) -> (Double, Double)? {
  t.drawn_of(ids[name]).map(fn(d) { (d.x, d.y) })
}

///|
test "one_of: room for the first whole (300): it alone drawn, its two side by side; not (150): the last alone, one over the other" {
  let ids : Map[String, @view.NodeId] = Map([])
  let t = one_of_row(ids, 300.0)
  assert_eq(one_of_at(t, ids, "a1"), Some((0.0, 16.0)), msg="300: the first's a")
  assert_eq(one_of_at(t, ids, "b1"), Some((120.0, 16.0)), msg="300: the first's b, beside it")
  assert_eq(one_of_at(t, ids, "a2"), None, msg="300: the last not drawn")
  assert_eq(one_of_at(t, ids, "b2"), None, msg="300: the last not drawn")
  let n = one_of_row(ids, 150.0)
  assert_eq(one_of_at(n, ids, "a1"), None, msg="150: the first not drawn")
  assert_eq(one_of_at(n, ids, "b1"), None, msg="150: the first not drawn")
  assert_eq(one_of_at(n, ids, "a2"), Some((0.0, 16.0)), msg="150: the last's a")
  assert_eq(one_of_at(n, ids, "b2"), Some((0.0, 32.0)), msg="150: the last's b, under it")
}

///|
test "one_of: the window made narrower, then wider again: the other way in the frame laid out at that width, at once, the same nodes" {
  let ids : Map[String, @view.NodeId] = Map([])
  let t = one_of_row(ids, 300.0)
  let first = ids["a1"]
  t.frame(150.0, 300.0) |> ignore
  assert_eq(one_of_at(t, ids, "a1"), None, msg="150: the first gone at once")
  assert_eq(one_of_at(t, ids, "a2"), Some((0.0, 16.0)), msg="150: the last there at once")
  assert_eq(one_of_at(t, ids, "b2"), Some((0.0, 32.0)), msg="150: one over the other, at once")
  t.frame(300.0, 300.0) |> ignore
  assert_eq(one_of_at(t, ids, "a1"), Some((0.0, 16.0)), msg="300 again: the first back at once")
  assert_eq(one_of_at(t, ids, "b1"), Some((120.0, 16.0)), msg="300 again: side by side")
  assert_eq(one_of_at(t, ids, "a2"), None, msg="300 again: the last gone")
  assert_true(ids["a1"] == first, msg="the same node, not made again")
}

///|
test "one_of: room for neither whole (100): the last, all of it" {
  let ids : Map[String, @view.NodeId] = Map([])
  let t = one_of_row(ids, 100.0)
  assert_eq(one_of_at(t, ids, "a1"), None, msg="100: the first not drawn")
  assert_eq(one_of_at(t, ids, "a2"), Some((0.0, 16.0)), msg="100: the last's a")
  assert_eq(one_of_at(t, ids, "b2"), Some((0.0, 32.0)), msg="100: the last's b")
}

///|
test "one_of in fits row: steps full(drop=1) -> short(drop=3) around sibling effort(drop=2), exact width, recovers on widen" {
  let ids : Map[String, @view.NodeId] = Map([])
  let t = @view.Tree::new(
    fn(root) {
      root.box(fn(row) {
        ids["row"] = row.id()
        row.over(Is(true)).row(Is(true)).fits(Is(true)).gap(Is(6.0)).width(By(fn() { Some(row.window().0) })) |> ignore
        row.box(fn(icon) {
          ids["icon"] = icon.id()
          icon.width(Is(Some(16.0))).height(Is(Some(16.0))).shrink(Is(0.0)).ground(Is(0xFF112233L)) |> ignore
        })
        |> ignore
        row.box(fn(name) {
          ids["name"] = name.id()
          name.row(Is(true)).one_of(Is(true)).shrink(Is(0.0)) |> ignore
          name.box(fn(full) {
            ids["full"] = full.id()
            full.width(Is(Some(100.0))).height(Is(Some(16.0))).drops(Is(1)).shrink(Is(0.0)).ground(Is(0xFF336699L))
            |> ignore
          })
          |> ignore
          name.box(fn(short) {
            ids["short"] = short.id()
            short.width(Is(Some(40.0))).height(Is(Some(16.0))).drops(Is(3)).shrink(Is(0.0)).ground(Is(0xFF4477AAL))
            |> ignore
          })
          |> ignore
        })
        |> ignore
        row.box(fn(eff) {
          ids["eff"] = eff.id()
          eff.width(Is(Some(30.0))).height(Is(Some(16.0))).drops(Is(2)).shrink(Is(0.0)).ground(Is(0xFF5588BBL))
          |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    time=fn() { 0.0 },
  )
  // Full: 16 + 6 + 100 + 6 + 30 = 158
  t.frame(180.0, 100.0) |> ignore
  assert_true(one_of_at(t, ids, "full") is Some(_), msg="180: full shown")
  assert_eq(one_of_at(t, ids, "short"), None, msg="180: short hidden")
  assert_eq(one_of_at(t, ids, "eff"), Some((128.0, 0.0)), msg="180: eff after full (16+6+100+6)")
  // Step 1 (drop=1 -> short): 16 + 6 + 40 + 6 + 30 = 98
  t.frame(120.0, 100.0) |> ignore
  assert_eq(one_of_at(t, ids, "full"), None, msg="120: full stepped down")
  assert_eq(one_of_at(t, ids, "short"), Some((22.0, 0.0)), msg="120: short shown at 22")
  assert_eq(one_of_at(t, ids, "eff"), Some((68.0, 0.0)), msg="120: eff tightly after short (16+6+40+6), zero dead space")
  // Step 2 (drop=2 -> effort gone): 16 + 6 + 40 = 62
  t.frame(80.0, 100.0) |> ignore
  assert_eq(one_of_at(t, ids, "full"), None, msg="80: full hidden")
  assert_eq(one_of_at(t, ids, "short"), Some((22.0, 0.0)), msg="80: short kept")
  assert_eq(one_of_at(t, ids, "eff"), None, msg="80: eff dropped")
  // Step 3 (drop=3 -> short gone, icon only): 16
  t.frame(40.0, 100.0) |> ignore
  assert_eq(one_of_at(t, ids, "full"), None, msg="40: full hidden")
  assert_eq(one_of_at(t, ids, "short"), None, msg="40: short dropped")
  assert_eq(one_of_at(t, ids, "eff"), None, msg="40: eff dropped")
  assert_eq(one_of_at(t, ids, "icon"), Some((0.0, 0.0)), msg="40: icon kept")
  // Widen back to 180: instant recovery
  t.frame(180.0, 100.0) |> ignore
  assert_true(one_of_at(t, ids, "full") is Some(_), msg="180 again: full restored")
  assert_eq(one_of_at(t, ids, "short"), None, msg="180 again: short hidden")
  assert_eq(one_of_at(t, ids, "eff"), Some((128.0, 0.0)), msg="180 again: eff restored")
}

///|
test "nested FITS capsule row: steps full -> short -> drop effort -> drop short with tight capsule width and no dead space" {
  let ids : Map[String, @view.NodeId] = Map([])
  let t = @view.Tree::new(
    fn(root) {
      root.box(fn(bar) {
        bar.over(Is(true)).row(Is(true)).gap(Is(6.0)).width(By(fn() { Some(bar.window().0) })) |> ignore
        // Left slot -> capsule -> [agent_half, station_half]
        bar.box(fn(slot) {
          slot.row(Is(true)).fits(Is(true)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
          slot.box(fn(cap) {
            ids["cap"] = cap.id()
            cap.row(Is(true)).fits(Is(true)).shrink(Is(1.0)).min_width(Is(Some(0.0))).ground(Is(0xFFEEEEEEFL)) |> ignore
            cap.box(fn(agent) {
              ids["agent"] = agent.id()
              agent.row(Is(true)).fits(Is(true)).gap(Is(6.0)).padding(Is((10.0, 0.0, 8.0, 0.0))) |> ignore
              agent.box(fn(icon) {
                ids["icon"] = icon.id()
                icon.width(Is(Some(16.0))).height(Is(Some(16.0))).shrink(Is(0.0)).ground(Is(0xFF112233L)) |> ignore
              })
              |> ignore
              agent.box(fn(name) {
                name.row(Is(true)).one_of(Is(true)).shrink(Is(0.0)) |> ignore
                name.box(fn(full) {
                  ids["full"] = full.id()
                  full.width(Is(Some(100.0))).height(Is(Some(16.0))).drops(Is(1)).shrink(Is(0.0)).ground(Is(0xFF336699L))
                  |> ignore
                })
                |> ignore
                name.box(fn(short) {
                  ids["short"] = short.id()
                  short.width(Is(Some(40.0))).height(Is(Some(16.0))).drops(Is(3)).shrink(Is(0.0)).ground(Is(0xFF4477AAL))
                  |> ignore
                })
                |> ignore
              })
              |> ignore
              agent.box(fn(eff) {
                ids["eff"] = eff.id()
                eff.width(Is(Some(30.0))).height(Is(Some(16.0))).drops(Is(2)).shrink(Is(0.0)).ground(Is(0xFF5588BBL))
                |> ignore
              })
              |> ignore
            })
            |> ignore
            cap.box(fn(st) {
              ids["st"] = st.id()
              st.row(Is(true)).fits(Is(true)).padding(Is((8.0, 0.0, 10.0, 0.0))) |> ignore
              st.box(fn(sname) {
                ids["sname"] = sname.id()
                sname.width(Is(Some(60.0))).height(Is(Some(16.0))).shrink(Is(0.0)).ground(Is(0xFF6699CCL)) |> ignore
              })
              |> ignore
            })
            |> ignore
          })
          |> ignore
        })
        |> ignore
        // Right capsule (80pt, fixed)
        bar.box(fn(right) {
          right.row(Is(true)).grow(Is(1.0)).lies_along(Is(End)).shrink(Is(0.0)) |> ignore
          right.box(fn(pill) {
            ids["right"] = pill.id()
            pill.width(Is(Some(80.0))).height(Is(Some(16.0))).shrink(Is(0.0)).ground(Is(0xFF996633L)) |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    time=fn() { 0.0 },
  )
  let cap_w = fn() {
    match t.drawn_of(ids["cap"]) {
      Some(d) => d.w
      None => -1.0
    }
  }
  // agent_half full = 10+8 + 16+6+100+6+30 = 176; st = 8+10+60 = 78; cap full = 254; bar needs 254+6+80 = 340
  t.frame(360.0, 100.0) |> ignore
  assert_true(one_of_at(t, ids, "full") is Some(_), msg="360: full shown")
  assert_true(one_of_at(t, ids, "eff") is Some(_), msg="360: eff shown")
  assert_eq(cap_w(), 254.0, msg="360: capsule tight at 254")
  // Step 1 (short + eff): agent_half = 18 + 16+6+40+6+30 = 116; cap = 194; bar needs 194+6+80 = 280
  t.frame(300.0, 100.0) |> ignore
  assert_eq(one_of_at(t, ids, "full"), None, msg="300: full stepped down")
  assert_true(one_of_at(t, ids, "short") is Some(_), msg="300: short shown")
  assert_true(one_of_at(t, ids, "eff") is Some(_), msg="300: eff still shown")
  assert_eq(cap_w(), 194.0, msg="300: capsule tight at 194, zero dead space")
  // Step 2 (short only): agent_half = 18 + 16+6+40 = 80; cap = 158; bar needs 158+6+80 = 244
  t.frame(260.0, 100.0) |> ignore
  assert_true(one_of_at(t, ids, "short") is Some(_), msg="260: short kept")
  assert_eq(one_of_at(t, ids, "eff"), None, msg="260: eff dropped")
  assert_eq(cap_w(), 158.0, msg="260: capsule tight at 158")
  // Step 3 (icon only): agent_half = 18 + 16 = 34; cap = 112; bar needs 112+6+80 = 198
  t.frame(210.0, 100.0) |> ignore
  assert_eq(one_of_at(t, ids, "short"), None, msg="210: short dropped")
  assert_eq(one_of_at(t, ids, "eff"), None, msg="210: eff dropped")
  assert_true(one_of_at(t, ids, "icon") is Some(_), msg="210: icon kept")
  assert_eq(cap_w(), 112.0, msg="210: capsule tight at 112")
  // Widen back to 360: full restored
  t.frame(360.0, 100.0) |> ignore
  assert_true(one_of_at(t, ids, "full") is Some(_), msg="360 again: full restored")
  assert_eq(cap_w(), 254.0, msg="360 again: capsule back to 254")
}
