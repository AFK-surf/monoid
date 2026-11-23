// A page's list whose keys are drawn in slices (View::scrolls_window's `slices`): keys a, b, c and d, b in six slices of
// 100, the rest one, in a list 200 tall. Each slice a block of its own, made as it comes to show (never all of a key's
// at once), said to the page by its key and which slice it is; brought by key and slice, what is in sight told so; a
// band from a key to itself under all its slices; the pointer on any slice of a key told to each of them; a key whose
// first slice is kept holding it while a later one shows, what it holds held at the list's top pushed up by its last
// slice's foot.

///|
priv struct SlicesCase {
  tree : Tree
  place : ListPlace[String]
  made : Array[(String, Int)]
  views : Map[String, View]
  mark : Ref[View?]
}

///|
let sl_band_ink : Int64 = 0xFF4477AAL

///|
fn sl_case(keep_first : Bool) -> SlicesCase {
  let scroll = Scroll::list()
  let place : ListPlace[String] = ListPlace::new()
  let made = []
  let views : Map[String, View] = Map([])
  let mark : Ref[View?] = Ref(None)
  let tree = Tree::new(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(300.0))).height(Is(Some(200.0))) |> ignore
      o.scrolls_window(
        scroll,
        fn() { ["a", "b", "c", "d"] },
        est=100.0,
        place~,
        slices=fn(k) { if k == "b" { 6 } else { 1 } },
        keep_first_slice=fn(k) { keep_first && k == "b" },
        make_slice=fn(v, k, b) {
          made.push((k, b))
          views["\{k}\{b}"] = v
          v.height(Is(Some(100.0))).points(Is(true)) |> ignore
          v.box(fn(w) { w.words(Is("\{k}\{b}")) |> ignore }) |> ignore
          if k == "b" && b == 0 {
            v.box(fn(m) {
              m.width(Is(Some(20.0))).height(Is(Some(20.0))).sticky(Is(Some(0.0))) |> ignore
              mark.val = Some(m)
            })
            |> ignore
          }
        },
        bands=(
          fn() { [{ from: "b", upto: "b", top: 0.0, foot: 0.0 }] },
          fn(v, _) { v.ground(Is(sl_band_ink)) |> ignore },
        ),
        fn(_, _) {  },
      )
      |> ignore
    })
    |> ignore
  })
  tree.frame(390.0, 844.0) |> ignore
  { tree, place, made, views, mark }
}

///|
test "a key in slices: each slice a block of its own made as it shows, told by its key and which slice; brought by both, in sight told so" {
  let c = sl_case(false)
  // (a and b's first two showing or near: no slice of b's far under made, no key of a slice's own)
  assert_true(c.made.contains(("a", 0)) && c.made.contains(("b", 0)), msg="\{Repr(c.made)}")
  assert_true(!c.made.contains(("b", 5)) && !c.made.contains(("c", 0)), msg="\{Repr(c.made)}")
  // (b's fifth brought to the top: in sight its key and that slice)
  c.place.bring("b", slice=4)
  c.tree.frame(390.0, 844.0) |> ignore
  match c.place.sight_now() {
    Some(s) => assert_eq((s.first, s.slice, s.into), ("b", 4, 0.0))
    None => fail("nothing in sight")
  }
  assert_true(c.made.contains(("b", 4)), msg="\{Repr(c.made)}")
  // (how far b's fourth is under its first: three slices of 100)
  assert_eq(c.place.span_between("b", "b", to_slice=3), Some(300.0))
}

///|
test "a band from a key to itself under all its slices, one ground" {
  let c = sl_case(false)
  let bands = c.tree.drawn().filter(fn(d) { d.ground == sl_band_ink })
  // (its ground drawn from b's first slice's top to its last's foot, in the room the band is laid over)
  let grounds = bands.map(fn(d) {
    let g = c.tree.ground_drawn_of(d.id)
    (d.y + g.dy, d.h + g.dh)
  })
  assert_eq(grounds, [(100.0, 600.0)])
}

///|
test "the pointer on any slice of a key told to each slice of it (View::list_item_pointed), not to another key's" {
  let c = sl_case(false)
  let pointed = fn(k : String) { @signals.untracked(fn() { c.views[k].list_item_pointed() }) }
  // (on a, 50 down: a's, not b's)
  c.tree.point_at(150.0, 50.0)
  c.tree.frame(390.0, 844.0) |> ignore
  assert_eq((pointed("a0"), pointed("b0")), (true, false))
  // (b's first two in what shows, the pointer on its second: told to its first too)
  c.place.bring("b")
  c.tree.frame(390.0, 844.0) |> ignore
  c.tree.point_at(150.0, 150.0)
  c.tree.frame(390.0, 844.0) |> ignore
  assert_eq((pointed("b0"), pointed("b1")), (true, true))
}

///|
test "a key whose first slice is kept: held while a later one shows, what it holds held at the list's top, pushed up by the last slice's foot" {
  for keep in [false, true] {
    let c = sl_case(keep)
    c.place.bring("b", slice=4)
    c.tree.frame(390.0, 844.0) |> ignore
    let first = c.views["b0"]
    let kept = first.alive() && !first.shown_nowhere()
    assert_eq(kept, keep, msg="kept \{keep}")
    if keep {
      // (its mark held at the list's top as b's fifth is there)
      let m = c.mark.val.unwrap()
      assert_eq(c.tree.drawn_place(m.id()).map(fn(p) { p.1 }), Some(0.0))
      // (b's last 90 over the top: its foot at 10, the mark pushed up to -10)
      c.place.bring("b", slice=5, offset=90.0)
      c.tree.frame(390.0, 844.0) |> ignore
      assert_eq(c.tree.drawn_place(m.id()).map(fn(p) { p.1 }), Some(-10.0))
    }
  }
}

///|
test "a key whose first slice is kept, that slice just over the top and still among the slots: shown all the while, what it holds held at the list's top" {
  let c = sl_case(true)
  // (b's second 50 over the top: its first from -150 to -50, out of sight, in the slots' margin)
  c.place.bring("b", slice=1, offset=50.0)
  c.tree.frame(390.0, 844.0) |> ignore
  let first = c.views["b0"]
  assert_true(first.alive() && !first.shown_nowhere())
  let m = c.mark.val.unwrap()
  assert_eq(c.tree.drawn_place(m.id()).map(fn(p) { p.1 }), Some(0.0))
  // (and on to b's third: its first further over, the mark held there still)
  c.place.bring("b", slice=2, offset=30.0)
  c.tree.frame(390.0, 844.0) |> ignore
  assert_true(first.alive() && !first.shown_nowhere())
  assert_eq(c.tree.drawn_place(m.id()).map(fn(p) { p.1 }), Some(0.0))
}
