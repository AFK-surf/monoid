// A run's first frame measures the words of the window's tree once, in what they are drawn in: the faces given from
// outside (MBUI_FACES, faces_from_env) and the host's glyphs as they are (text_arrive) taken before the tree is brought
// and laid out (on_frame), and what the tree tells as its window is first given (a face, lines set as a browser's:
// View::reacts on View::window, as an app's tree does) told before anything of it is laid out, never all of it measured
// in what was there before and then again.

///|
/// A tree of words and a table's columns (View::tracks) made as its window is first given, its window's width read
/// before that by a react that, given one, gives the code's face and sets lines as a browser does, when `told`; the
/// Tester made with `env`, `begun` said before its first frame. How many times its first frame measured something.
fn first_frame_measured(told : Bool, env : Array[(String, String)], begun : () -> Unit) -> Int {
  let t = Tester::new(fn(_c) {  }, w=320.0, h=240.0, env~, begun~, tree=fn(root) {
    if told {
      root.reacts(fn() { root.window().0 }, fn(w) {
        if w > 0.0 {
          ignore(face_add_bytes(@hostapi.face_code, b"\x00\x01\x00\x00"))
          set_web_lines(true)
        }
      })
    }
    // (what shows made as the window is first given, as an app's state's nodes are: after what that tells, told first)
    root.pick(fn() { root.window().0 > 0.0 }, fn(p, given) {
      if given {
        let tracks = p.tracks(
          fn() {
            [
              [Said([@view.words_run("name")], @view.words_plain, @view.runs_plain), Wide(30.0)],
              [Said([@view.words_run("a longer cell")], @view.words_plain, @view.runs_plain), Wide(30.0)],
            ]
          },
          fn() { 200.0 },
          fn(ex, room) { (ex.map(fn(row) { row[0].whole }), room) },
        )
        p.box(fn(col) {
          col.box(fn(b) { b.words(Is("one line of words")) |> ignore }) |> ignore
          col.box(fn(b) { b.words(Is("another, longer line of words that wraps in the room")) |> ignore }) |> ignore
          col.box(fn(b) { b.words(Is("three")) |> ignore }) |> ignore
          col.box(fn(b) { b.width(By(fn() { Some((tracks.widths)().0[1]) })).height(Is(Some(10.0))) |> ignore })
          |> ignore
        })
        |> ignore
      }
    })
  })
  ignore(t)
  let measured = view_app.val.unwrap().work().measured
  set_web_lines(false)
  measured
}

///|
test "a run's first frame: what its words are drawn in given from outside and as its window is first given, each measured once" {
  // (all of it given before the tree is made: what one measuring of it is)
  let once = first_frame_measured(false, [], fn() {
    ignore(face_add(@hostapi.face_ui, "/fonts/ui.ttf"))
    ignore(face_add_bytes(@hostapi.face_code, b"\x00\x01\x00\x00"))
    set_web_lines(true)
  })
  // (the same given as a run is: the face from outside as the first frame begins, the rest as the window is given)
  let first = first_frame_measured(true, [("MBUI_FACES", "1:/fonts/ui.ttf")], fn() {  })
  assert_true(once > 0)
  assert_eq(first, once, msg="measured in what was there before, then again: \{first} against \{once}")
}
