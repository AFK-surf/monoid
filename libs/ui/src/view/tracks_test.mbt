///|
test "View::tracks: each cell measured as its words are (least and whole), once as the cells change, never as the room does, as what they read is told again the same, nor as they are read anew once what read them let go; shared again as either changes" {
  let room = @signals.signal(200.0)
  let words = @signals.signal("ab cdef")
  // (what the cells read besides: told again, the cells the same)
  let tick = @signals.signal(0)
  let got : Ref[@view.Tracks?] = Ref(None)
  let seen : Array[Array[Array[@view.TrackExtent]]] = []
  let t = @view.Tree::new(
    fn(root) {
      got.val = Some(
        root.tracks(
          fn() {
            tick.get() |> ignore
            [[Said([@view.words_run(words.get())], @view.words_plain, @view.runs_plain), Wide(30.0)]]
          },
          fn() { room.get() },
          fn(ex, r) {
            seen.push(ex)
            (ex[0].map(fn(e) { e.whole }), r)
          },
        ),
      )
    },
    time=fn() { 0.0 },
  )
  t.frame(320.0, 200.0) |> ignore
  let widths = got.val.unwrap().widths
  assert_eq(widths(), ([49.0, 30.0], 200.0))
  let measured = t.work().measured
  // (the room changed: shared again, nothing measured again)
  room.set(150.0)
  assert_eq(widths(), ([49.0, 30.0], 150.0))
  let after_room = t.work().measured - measured
  // (what they read told again, the cells the same: nothing measured again, nothing shared again)
  tick.set(1)
  assert_eq(widths(), ([49.0, 30.0], 150.0))
  let after_tick = t.work().measured - measured
  // (read by what lets go of them (a part parked, its watch letting go of a topic it held), then read anew: what they
  // read is let go of too and worked out again, the same: shared again, nothing measured again)
  let stop = @signals.effect(fn() { widths() |> ignore })
  stop()
  assert_eq(widths(), ([49.0, 30.0], 150.0))
  let after_let_go = t.work().measured - measured
  // (its words changed: measured again, once)
  words.set("a bc")
  assert_eq(widths(), ([28.0, 30.0], 150.0))
  let after_words = t.work().measured - measured
  assert_eq((seen.length(), after_room, after_tick, after_let_go, after_words), (4, 0, 0, 0, 1))
  debug_inspect(
    seen[0],
    content=(
      #|[
      #|  [
      #|    { least: 28, whole: 49, wide: false },
      #|    { least: 30, whole: 30, wide: true },
      #|  ],
      #|]
    ),
  )
}
