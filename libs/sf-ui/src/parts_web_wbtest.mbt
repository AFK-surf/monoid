// The parts as the web's parts.tsx and parts.css.ts make them: their sizes and what they do.

///|
test "a list's row as a node in a side column: what stands at its first line's end in one column with what stands in its foot's end corner" {
  // (a mouse's and a finger's sizes; in the corner last an agent's mark, 16 wide, or a face)
  for platform in [0, 2] {
    for last in [16.0, 0.0] {
      let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=800.0, h=600.0, platform~, corners_held=false)
      @ui.set_view_app(fn(root) {
        @ui.set_tree_theme(ui_theme_now)
        root.box(fn(holder) {
          holder.width(Is(Some(280.0))) |> ignore
          holder.box(fn(row) {
            let square = fn(s : @view.View, color : Int64, side : Double) {
              s.width(Is(Some(side))).height(Is(Some(side))).ground(Is(color)) |> ignore
            }
            list_row_node(
              row,
              Side,
              high=true,
              end_slot=16.0,
              corner=fn(k) { k.box(fn(s) { square(s, 0x00FF00FFL, if last > 0.0 { last } else { theme().chat_list.face_d }) }) |> ignore },
              corner_w=fn() { 16.0 },
              corner_end=fn() { last },
              fn(h) {
                h.box(fn(s) { s.grow(Is(1.0)) |> ignore }) |> ignore
                h.box(fn(s) { square(s, 0xFF0000FFL, 16.0) }) |> ignore
              },
              fn(_) {  },
            )
          })
          |> ignore
        })
        |> ignore
      })
      t.draw()
      let at = fn(color : Int64) {
        match t.drawn_rects().search_by(fn(r) { r.4 == color }) {
          Some(i) => {
            let r = t.drawn_rects()[i]
            r.0 + r.2 / 2.0
          }
          None => -1.0
        }
      }
      let end = at(0xFF0000FFL)
      let corner = at(0x00FF00FFL)
      assert_true(end > 0.0 && corner > 0.0, msg="\{Repr(t.drawn_rects())}")
      assert_true((end - corner).abs() < 0.5, msg="platform \{platform}, last \{last}: the first line's end at \{end}, the corner's at \{corner}")
      assert_true((end - (280.0 - row_corner)).abs() < 0.5, msg="platform \{platform}, last \{last}: the column moved to \{end}")
    }
  }
}

///|
test "a list's row as a node: its lines as high as their words' lines at the system's size of words, nothing over another, its mark across its first line's middle, a chat's row higher by as much as they are" {
  // (a mouse's and a finger's sizes; the default size of words and a phone's set larger; a row as high as what it
  // holds, its mark beside its first line, and a chat's row, as high as the theme says)
  let rows : Map[String, Double] = Map([])
  for platform in [0, 2] {
    for high in [false, true] {
      for scale in [1.0, 1.3] {
        let at = "platform \{platform}, high \{high}, at \{scale}"
        let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=800.0, h=600.0, platform~, corners_held=false)
        if scale != 1.0 {
          t.set_font_scale(scale)
        }
        @ui.set_view_app(fn(root) {
          @ui.set_tree_theme(ui_theme_now)
          root.box(fn(holder) {
            holder.width(Is(Some(280.0))) |> ignore
            holder.box(fn(row) {
              list_row_node(
                row,
                Whole,
                high~,
                ground=fn() { 0x00FF00FFL },
                mark?=if high {
                  None
                } else {
                  Some(fn(k : @view.View) {
                    k.box(fn(s) { s.width(Is(Some(8.0))).height(Is(Some(8.0))).ground(Is(0xFF0000FFL)) |> ignore })
                    |> ignore
                  })
                },
                fn(h) { words_node(h, fn() { "整理发布清单" }, fn() { theme().chat_list.title }) |> ignore },
                fn(u) {
                  list_row_line_node(u, fn(l) { words_node(l, fn() { "正在核对第三项" }, fn() { theme().chat_list.last }) |> ignore })
                },
              )
            })
            |> ignore
          })
          |> ignore
        })
        t.run_for(@ui.move_most_ms)
        assert_eq(t.squeeze_faults(), [], msg="\{at}: \{Repr(t.squeeze_faults())}")
        let word = fn(s : String) {
          match t.words().search_by(fn(w) { w.0 == s }) {
            Some(i) => t.words()[i]
            None => ("", 0.0, 0.0, 0.0, 0.0, 0.0)
          }
        }
        let title = word("整理发布清单")
        let under = word("正在核对第三项")
        assert_true(title.4 > 0.0 && under.4 > 0.0, msg="\{at}: \{Repr(t.words())}")
        // (the line under it starts no higher than where its title's line ends)
        assert_true(under.2 >= title.2 + title.4 - 0.5, msg="\{at}: its title at \{Repr(title)}, the line under it at \{Repr(under)}")
        guard t.drawn_rects().search_by(fn(r) { r.4 == 0x00FF00FFL }) is Some(g) else { fail("\{at}: no row") }
        let ground = t.drawn_rects()[g]
        rows["\{platform} \{high} \{scale}"] = ground.3
        if high {
          // (as high as the theme says at the default size of words)
          if scale == 1.0 {
            assert_eq(ground.3, theme().chat_list.row_h, msg=at)
          }
        } else {
          // (its mark across its title's middle)
          guard t.drawn_rects().search_by(fn(r) { r.4 == 0xFF0000FFL }) is Some(i) else { fail("\{at}: no mark") }
          let mark = t.drawn_rects()[i]
          assert_true(
            (mark.1 + mark.3 / 2.0 - (title.2 + title.4 / 2.0)).abs() < 0.5,
            msg="\{at}: its mark at \{Repr(mark)}, its title at \{Repr(title)}",
          )
        }
      }
      // (higher at 1.3, by as much as its two lines' words are)
      let (lo, hi) = (rows.get("\{platform} \{high} 1").unwrap_or(0.0), rows.get("\{platform} \{high} 1.3").unwrap_or(0.0))
      assert_true(hi > lo + 4.0, msg="platform \{platform}, high \{high}: \{lo} at the default size, \{hi} at 1.3")
    }
  }
}

///|
test "a chat's rows as nodes: as high as each other whatever their second lines say, following the system's size of words as it changes" {
  // (a mouse's and a finger's sizes; a row whose second line says something and one whose says nothing, at the default
  // size, then the system's set to 1.3, then back)
  for platform in [0, 2] {
    let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=800.0, h=600.0, platform~, corners_held=false)
    @ui.set_view_app(fn(root) {
      @ui.set_tree_theme(ui_theme_now)
      root.box(fn(holder) {
        holder.width(Is(Some(280.0))) |> ignore
        for said in [("正在核对第三项", 0x00FF00FFL), ("", 0x0000FFFFL)] {
          holder.box(fn(row) {
            list_row_node(
              row,
              Whole,
              high=true,
              ground=fn() { said.1 },
              fn(h) { words_node(h, fn() { "整理发布清单" }, fn() { theme().chat_list.title }) |> ignore },
              fn(u) {
                list_row_line_node(u, fn(l) { words_node(l, fn() { said.0 }, fn() { theme().chat_list.last }) |> ignore })
              },
            )
          })
          |> ignore
        }
      })
      |> ignore
    })
    let heights = fn(at : String) -> (Double, Double) raise {
      t.run_for(@ui.move_most_ms)
      assert_eq(t.squeeze_faults(), [], msg="\{at}: \{Repr(t.squeeze_faults())}")
      let high = fn(color : Int64) -> Double raise {
        match t.drawn_rects().search_by(fn(r) { r.4 == color }) {
          Some(i) => t.drawn_rects()[i].3
          None => fail("\{at}: no row of \{color}")
        }
      }
      (high(0x00FF00FFL), high(0x0000FFFFL))
    }
    let row_h = theme().chat_list.row_h
    let at = "platform \{platform}"
    let (said, none) = heights("\{at} at the default size")
    assert_eq(said, row_h, msg=at)
    assert_eq(none, row_h, msg=at)
    t.set_font_scale(1.3)
    let (said, none) = heights("\{at} at 1.3")
    assert_true(said > row_h + 4.0, msg="\{at} at 1.3: \{said}, the theme's \{row_h}")
    assert_eq(none, said, msg="\{at} at 1.3: what says nothing under its title as high as what says something")
    t.set_font_scale(1.0)
    let (said, none) = heights("\{at} back at the default size")
    assert_eq(said, row_h, msg=at)
    assert_eq(none, row_h, msg=at)
  }
}
