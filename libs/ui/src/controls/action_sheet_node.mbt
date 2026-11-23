// Apple iOS 26/27 anchored Liquid Glass ActionSheet (`action_sheet_node`):
// - Reuses `anchored_popover_bridge` + `anchored_popover_shell`:
//   * Anchored inside `bar_pill_group_node`: full 1:1 iOS 26/27 `LiquidMorphPhysics` liquid-droplet expand/recoil.
//   * Anchored to any other button: clean single-layer `liquid_panel_glass` card beside trigger (zero double glass).
//   * Under `MBUI_GLASS=solid`: automatic opaque surface + hairline border fallback.
// - Optional `title` (600 semibold) and `message` (12pt muted, omitted when empty), single 0.5pt hairline divider
//   only when both header and actions are present (zero dangling dividers), 38pt concentric action rows with optional
//   leading icon and red danger emphasis (`theme().p.red`), roving keyboard focus (Up/Down/Home/End/Enter/Space),
//   Escape & click-outside dismissal, and automatic focus restoration on close.

///|
/// A single action entry in `action_sheet_node`.
pub(all) struct SheetAction {
  label : String
  icon : String
  danger : Bool
  on_pick : () -> Unit
}

///|
/// Constructs a `SheetAction` entry for `action_sheet_node`.
pub fn sheet_action(
  label : String,
  on_pick : () -> Unit,
  icon? : String = "",
  danger? : Bool = false,
) -> SheetAction {
  { label, icon, danger, on_pick }
}

///|
let action_sheet_pad : Double = 6.0

///|
let action_sheet_min_w : Double = 248.0

///|
let action_sheet_max_w : Double = 280.0

///|
let action_sheet_row_h : Double = 38.0

///|
let action_sheet_none : SheetAction = {
  label: "",
  icon: "",
  danger: false,
  on_pick: fn() {  },
}

///|
/// Apple iOS 26/27 anchored Liquid Glass ActionSheet in `parent` while `open()` holds.
/// Anchors to `anchor(layer)` (automatically activating `LiquidMorphPhysics` when the anchor lives inside
/// `bar_pill_group_node`), renders optional `title` and `message`, a 0.5pt divider when non-empty, and
/// `actions()` rows. Picking an action runs `cancel()` first and then `(act.on_pick)()`.
#callsite(autofill(loc))
pub fn action_sheet_node(
  parent : @view.View,
  open : () -> Bool,
  anchor : (@view.View) -> @view.View,
  title : () -> String,
  message : () -> String,
  actions : () -> Array[SheetAction],
  cancel : () -> Unit,
  along? : @ui.Along = Start,
  loc~ : SourceLoc,
) -> Unit {
  parent.show(
    open,
    fn(layer) {
      let way = @motion.NodeWay::new(0.0)
      layer.reacts(fn() { layer.leaving() }, fn(going) {
        if going {
          way.go_ms(layer, 0.0, @motion.pop_out_ms, ease=@signals.untracked(fn() { pop_out_ease_for(layer) }))
        } else {
          way.go_ms(layer, 1.0, @motion.pop_ms)
        }
      })
      let look = fn() {
        let p = way.shown(layer)
        if layer.leaving() {
          pop_out_for(layer).at(p, p)
        } else {
          pop_in_for(layer).at(p, p)
        }
      }
      let live = fn() { !layer.leaving() }
      let picked = Ref(false)
      let run_pick = fn(i : Int) {
        if picked.val || !@signals.untracked(live) {
          return
        }
        let list = @signals.untracked(actions)
        if i >= 0 && i < list.length() {
          picked.val = true
          let act = list[i]
          cancel()
          (act.on_pick)()
        }
      }
      layer.over(Is(true)) |> ignore
      let at = anchor(layer)
      anchored_popover_bridge(loc~, layer, at, look, side=Bottom, along~, offset=panel_offset)
      layer.box(made_for=loc, fn(p) {
        anchored_popover_shell(
          p,
          at.id(),
          look,
          side=Bottom,
          along~,
          offset=panel_offset,
          holds_side=false,
          concentric_inset=action_sheet_pad,
        )
        .min_width(By(fn() { Some(dmin(action_sheet_min_w, dmax(0.0, over_room(layer).0 - 16.0))) }))
        .max_width(By(fn() { Some(dmin(action_sheet_max_w, dmax(0.0, over_room(layer).0 - 16.0))) }))
        .max_height(By(fn() { Some(dmax(0.0, over_room(layer).1 - 16.0)) }))
        .padding(Is((action_sheet_pad, action_sheet_pad, action_sheet_pad, action_sheet_pad)))
        |> ignore
        let inner_r = dmax(8.0, r_menu - action_sheet_pad)
        p.box(fn(body) {
          @headless.menu(
            made_for=loc,
            body,
            label=fn() {
              let s = title()
              if s != "" { s } else { "Actions" }
            },
            wraps=true,
            disabled=fn() { !live() },
            takes_focus=false,
            roving=true,
            captures_unfocused=true,
            in_node=true,
            fn(body, menu) {
              popover_content_motion(p, body, fn() { look().words })
              let has_head = fn() { title() != "" || message() != "" }
              body.show(has_head, at_once=true, fn(hdr) {
                hdr.padding(Is((12.0, 8.0, 12.0, 8.0))).gap(Is(4.0)) |> ignore
                hdr.show(fn() { title() != "" }, at_once=true, fn(tbox) {
                  tbox
                  .words(
                    By(title),
                    look={
                      size: 13.0,
                      weight: 600,
                      line: 18.0,
                      wrap: true,
                      tracking: @view.letters_own,
                      balance: false,
                      max_lines: 0,
                    },
                  )
                  .ink(By(fn() { theme().p.text }))
                  |> ignore
                })
                hdr.show(fn() { message() != "" }, at_once=true, fn(mbox) {
                  mbox
                  .words(
                    By(message),
                    look={
                      size: 12.0,
                      weight: 400,
                      line: 16.0,
                      wrap: true,
                      tracking: @view.letters_own,
                      balance: false,
                      max_lines: 0,
                    },
                  )
                  .ink(By(fn() { theme().p.muted }))
                  |> ignore
                })
              })
              body.show(fn() { has_head() && actions().length() > 0 }, at_once=true, fn(sep) {
                sep.padding(Is((6.0, 0.0, 6.0, 4.0))) |> ignore
                sep.box(fn(ln) {
                  style_node(ln, fn() { rule_line })
                })
                |> ignore
              })
              body.each(
                fn() {
                  let n = actions().length()
                  Array::makei(n, fn(i) { i })
                },
                fn(i) { i },
                at_once=true,
                fn(cell, idx) {
                  let i = idx.untracked()
                  let act = fn() {
                    match actions().get(i) {
                      Some(a) => a
                      None => action_sheet_none
                    }
                  }
                  let ink = fn() {
                    if act().danger {
                      theme().p.red
                    } else {
                      theme().p.text
                    }
                  }
                  menu.item(
                    made_for=loc,
                    cell,
                    fn() { act().label },
                    fn(_) { run_pick(i) },
                    fn(r, _mi) {
                      r
                      .row(Is(true))
                      .min_height(Is(Some(action_sheet_row_h)))
                      .padding(Is((12.0, 6.0, 12.0, 6.0)))
                      .gap(Is(8.0))
                      .lines_up(Is(Some(Middle)))
                      .radius(Is(inner_r))
                      |> ignore
                      hover_ground_node(
                        r,
                        lit=Some(fn() { r.focused() && (r.focus_shown() || r.pointed()) }),
                      )
                      r.on_pointer_moved(fn() { r.ask_focus() |> ignore }) |> ignore
                      r.show(fn() { act().icon != "" }, at_once=true, fn(ic) {
                        icon_node(ic, act().icon, 16.0, By(ink), name_now=fn() { act().icon }) |> ignore
                      })
                      r.box(fn(w) {
                        w
                        .shrink(Is(1.0))
                        .min_width(Is(Some(0.0)))
                        .words(
                          By(fn() { act().label }),
                          look={
                            size: 14.0,
                            weight: 500,
                            line: 20.0,
                            wrap: true,
                            tracking: @view.letters_own,
                            balance: false,
                            max_lines: 0,
                          },
                        )
                        .ink(By(ink))
                        |> ignore
                      })
                      |> ignore
                    },
                  )
                  |> ignore
                },
              )
            },
          )
          |> ignore
        })
        |> ignore
        @headless.overlay(
          made_for=loc,
          p,
          fn(_) { cancel() },
          modal=true,
          held_back_goes_on=true,
          dismiss_on_escape=true,
          dismiss_on_outside=true,
          inert=fn() { layer.leaving() },
          auto_focus=true,
          initial_focus=p,
          in_node=true,
          fn(_, _) {  },
        )
        |> ignore
      })
      |> ignore
    },
    leave=@motion.pop_out_ms,
  )
}
