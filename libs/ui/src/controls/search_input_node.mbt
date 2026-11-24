// The field a list is looked through by, at its top (the settings' list, the archive's page and its sidebar, the chats'
// search come up from its list) as one part: a round ground as tall as the theme's band, the search mark, the field,
// and while it holds words the clear key at its end, inside the ground, as round as it, its cross as far in as the mark.

///|
/// A field to look through a list by in `parent`, standing where its list stands (`at`): its round ground (search_ground,
/// a capsule as tall as the theme's band), the search mark and its words as far in from its ends as `at` has them
/// (band_pad_in), and while it holds words the clear key at its end in the ground's end room, a circle as tall as the
/// ground, its cross as far in from the end as the mark from the start: pressed, `field` emptied (`cleared` told) and
/// the focus back in it.
/// `placeholder_by`: what it says while empty (`shorter` ways where it has less room); `edited`: its words as the
/// person changes them; `submitted`: its words at Enter or the keyboard's search key, once (none: Enter as the layer
/// it is in has it); `escape`: Escape pressed in it, true where that was taken (none: Escape left to what holds it);
/// `step`: ↓ (1) and ↑ (-1) in it, as a combobox's keys come from its field (the keymap's actions), taken while
/// `step_can` says so and where `step` says it took them (none: the arrows left to what holds it).
/// `end`: what stands at its end after the clear key (a count, a filter). The field's node (what the focus is given
/// to).
#callsite(autofill(loc))
pub fn search_input_node(
  parent : @view.View,
  field : @ui.Field,
  placeholder_by : () -> String,
  at? : ListAt = Whole,
  shorter? : Array[String] = [],
  edited? : (String) -> Unit,
  submitted? : (String) -> Unit,
  escape? : () -> Bool,
  step? : (Int) -> Bool,
  step_can? : () -> Bool = fn() { true },
  cleared? : () -> Unit = fn() {  },
  end? : (@view.View) -> Unit,
  loc~ : SourceLoc,
) -> @view.View {
  let held = fn() { field.text() != "" }
  let made : Ref[@view.View?] = Ref(None)
  parent.box(made_for=loc, fn(g) {
    // (its end's room the clear key's while it holds words, a circle as tall as the ground in its round end: its cross
    // as far in from the end as the search mark from the start, the circle moved in by what that takes (none where the
    // circle's own room already holds it))
    style_node(g, fn() {
      let l = theme().chat_list
      let pad = band_pad_in(at)
      let end_room = if held() { room_of(dmax(0.0, pad - (l.band_h - l.band_icon) / 2.0)) } else { room_of(pad) }
      search_input_ground.then(@ui.style(h=Fixed(l.band_h), pl=room_of(pad), pr=end_room))
    })
    match escape {
      Some(f) =>
        g.on_key(fn(k) {
          if k.code == @ui.key_escape && k.mods == 0 {
            f()
          } else {
            false
          }
        })
        |> ignore
      None => ()
    }
    match step {
      Some(s) =>
        g
        .key_context(@headless.combobox_context)
        .on_action(@headless.combobox_next, fn(_) { s(1) }, can=step_can)
        .on_action(@headless.combobox_prev, fn(_) { s(-1) }, can=step_can)
        |> ignore
      None => ()
    }
    // (its ground round the field (the search mark, its ends) the field's to a press: a tap there its tap, a long press
    // its 粘贴)
    @ui.field_backdrop(g, field)
    // (its size the native input's, the same all the run: read once)
    icon_node(g, "search", @signals.untracked(fn() { theme().chat_list.band_icon }), By(fn() { theme().p.muted })) |> ignore
    let typed = @ui.field(
      g,
      field,
      placeholder_by~,
      shorter~,
      max_lines=1,
      enter_sends=true,
      ime_action=@hostapi.ime_action_search,
      size_by=fn() { theme().t.ui },
      line=@signals.untracked(fn() { theme().t.ui_line }),
      // (its placeholder subtle, as the lists' own fields had it)
      colors_by=fn() {
        let p = theme().p
        (p.text, p.subtle, p.accent)
      },
      submitted?,
      edited?,
    )
    typed.grow(Is(1.0)).basis(Is(Some(0.0))).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
    made.val = Some(typed)
    g.show(held, fn(k) {
      // (its sizes the native input's, the same all the run (@sf.native_input): read once, as icon_button_node takes
      // them)
      let l = @signals.untracked(fn() { theme().chat_list })
      icon_button_node(
        k,
        "close",
        fn() { t("android-misc.drive.pick.filterClear") },
        fn() {
          field.set("")
          cleared()
          match edited {
            Some(f) => f("")
            None => ()
          }
          typed.ask_focus() |> ignore
        },
        size=l.band_h,
        icon_size=l.band_icon,
      )
      |> ignore
    })
    match end {
      Some(f) => f(g)
      None => ()
    }
  })
  |> ignore
  made.val.unwrap()
}

///|
/// search_input_node's ground: a row across, its parts 8 apart in its middle, round as a capsule, the search's grey.
// kept across runs: a value (no field of it changes)
let search_input_ground : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter radius=Full").then(@ui.style(bg=search_ground))
