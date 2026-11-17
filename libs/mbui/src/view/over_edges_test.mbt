// What is put where it says over what holds it (View::over's `edges`): so far in from the edges it says, its size its
// own where it says none of two facing, as wide as they leave it where it says both.

///|
test "over by its edges: by its top left, by its foot right, and between its left and right" {
  let ids : Map[String, @view.NodeId] = Map([])
  let t = @view.Tree::new(
    fn(root) {
      root.box(fn(p) {
        p.width(Is(Some(200.0))).height(Is(Some(100.0))) |> ignore
        p.box(fn(a) {
          ids["a"] = a.id()
          a.over(Is(true), edges=(Some(10.0), Some(5.0), None, None)).width(Is(Some(20.0))).height(Is(Some(10.0)))
          |> ignore
        })
        |> ignore
        p.box(fn(b) {
          ids["b"] = b.id()
          b.over(Is(true), edges=(None, None, Some(10.0), Some(5.0))).width(Is(Some(20.0))).height(Is(Some(10.0)))
          |> ignore
        })
        |> ignore
        p.box(fn(c) {
          ids["c"] = c.id()
          c.over(Is(true), edges=(Some(10.0), Some(-4.0), Some(30.0), None)).height(Is(Some(10.0))) |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    time=fn() { 0.0 },
  )
  t.frame(400.0, 300.0) |> ignore
  let at = fn(k : String) {
    let d = t.drawn_of(ids[k]).unwrap()
    (d.x, d.y, d.w, d.h)
  }
  assert_eq(at("a"), (10.0, 5.0, 20.0, 10.0))
  assert_eq(at("b"), (170.0, 85.0, 20.0, 10.0))
  assert_eq(at("c"), (10.0, -4.0, 160.0, 10.0))
}

///|
test "over where its edges say as they change: laid out there again, nothing made again" {
  let top = @signals.signal(5.0)
  let id : Ref[@view.NodeId?] = Ref(None)
  let t = @view.Tree::new(
    fn(root) {
      root.box(fn(p) {
        p.width(Is(Some(200.0))).height(Is(Some(100.0))) |> ignore
        p.box(fn(a) {
          id.val = Some(a.id())
          a.over_at(By(fn() { (Some(10.0), Some(top.get()), None, None) })).width(Is(Some(20.0))).height(Is(Some(10.0)))
          |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    time=fn() { 0.0 },
  )
  t.frame(400.0, 300.0) |> ignore
  let at = fn() {
    let d = t.drawn_of(id.val.unwrap()).unwrap()
    (d.x, d.y, d.w, d.h)
  }
  assert_eq(at(), (10.0, 5.0, 20.0, 10.0))
  let made = t.work().made
  top.set(42.0)
  t.frame(400.0, 300.0) |> ignore
  assert_eq(at(), (10.0, 42.0, 20.0, 10.0))
  assert_eq(t.work().made, made)
}
