// The head of what is opened over the whole window and laid out under it, as nodes (a station's terminal: its screen
// under it): in a wide frame, the bar of a file or a screen opened (viewer_bar_node: back by name, the name and the
// line about it in the middle, 按键 and 控制中心 at its end, round at the window's corner); in a phone's, one compact bar
// (nav_bar_node: back, the name and the line about it under it, 控制中心 at its end). Under either, while it says so, a
// line of what is to be done (who else is at it, and the one thing to do: 接管 or 控制), its button at its end, alone in
// its row. Each as tall as it is, in the flow: what comes after it starts under it.

///|
/// The head in `parent` (`wide`: in a wide frame, its window's; else a phone's): back to where `back` says, `went` as it
/// is pressed; `name`, and `meta` about it (`title`, where it is, its tip on a wide bar); under the system's status bar,
/// `top` high; `keys` (shown on a wide bar while `keys_shown` holds) and 控制中心 at its end that give `keys` and `more`
/// themselves as they are pressed (a panel beside each). Under it while `line` says words: those, then a button `act`
/// names, `acting` as it is pressed.
#callsite(autofill(loc))
pub fn opened_head_node(
  parent : @view.View,
  back : () -> String,
  name : () -> String,
  meta : () -> String,
  title : () -> String,
  top : () -> Double,
  wide : Bool,
  more : (@view.View) -> Unit,
  went : () -> Unit,
  line : () -> String,
  act : () -> String,
  acting : () -> Unit,
  keys_shown? : () -> Bool = fn() { false },
  keys_on? : () -> Bool = fn() { false },
  keys? : (@view.View) -> Unit,
  paste? : () -> Unit,
  loc~ : SourceLoc,
) -> Unit {
  parent.box(made_for=loc, fn(h) {
    if wide {
      // (as tall as the bar, which lies over it: what comes after it starts under it)
      h.box(fn(p) {
        p.height(By(fn() { Some(top() + viewer_bar_h_now()) })) |> ignore
        let tips_at : Ref[@view.View?] = Ref(None)
        let tips = TipLayer::new(fn() { tips_at.val })
        let ink = fn() { page_viewer_ink() }
        viewer_bar_node(
          p,
          back,
          name,
          meta,
          title,
          fn() { false },
          fn(_) { 1.0 },
          top,
          fn() { p.window_w() },
          ink,
          fn(row, corner) {
            match paste {
              Some(do_paste) =>
                row.show(keys_shown, fn(ps) {
                  tool_node(
                    ps,
                    fn() { { icon: "paste", label: t("web-pages.screen.paste"), on: false, disabled: false } },
                    ink,
                    corner,
                    do_paste,
                    tip=tips,
                  )
                  |> ignore
                })
              None => ()
            }
            match keys {
              Some(open_keys) =>
                row.show(keys_shown, fn(k) {
                  let btn : Ref[@view.View?] = Ref(None)
                  btn.val = Some(
                    tool_node(
                      k,
                      fn() { { icon: "keycap", label: t("web-pages.screen.keysPanel"), on: keys_on(), disabled: false } },
                      ink,
                      corner,
                      fn() { match btn.val { Some(m) => open_keys(m); None => () } },
                      tip=tips,
                    ),
                  )
                })
              None => ()
            }
            let dots : Ref[@view.View?] = Ref(None)
            dots.val = Some(
              tool_node(
                row,
                fn() { { icon: "sliders", label: t("web-pages.screen.panel"), on: false, disabled: false } },
                ink,
                corner,
                fn() { match dots.val { Some(m) => more(m); None => () } },
                tip=tips,
              ),
            )
          },
          went,
          tips,
        )
        |> ignore
        tips_at.val = Some(p.box(fn(l) { l.over(Is(true)) |> ignore }))
      })
      |> ignore
    } else {
      nav_bar_node(h, back, name, went, sub=meta, top~, trailing_pad=4.0, trailing=fn(e) {
        icon_button_by(e, "sliders", fn() { t("web-pages.screen.panel") }, more, None, icon_button_side, 16.0, None, fn() { false }) |> ignore
      })
    }
    // what is to be done, while there is: its words, the button at the line's end
    h.show(fn() { line() != "" }, fn(l) {
      l
      .row(Is(true))
      .lines_up(Is(Some(Middle)))
      .gap(Is(12.0))
      .padding(Is((pg_note_x, 8.0, pg_note_x, 8.0)))
      |> ignore
      l.box(fn(w) {
        w.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
        styled_words(w, line, fn() { pg_note }) |> ignore
      })
      |> ignore
      button_node(l, act, acting, tone=Primary) |> ignore
    })
  })
  |> ignore
}
