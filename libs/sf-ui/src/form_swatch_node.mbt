// A form's look picked and its permissions ticked (表单的外观色板与勾选组), and the rows a picker and a connect's head are
// made of, as nodes of the window's tree, made once: an icon's well (its picture, or what to press for one, on the
// colour chosen); a colour's swatch beside its hex field; the avatars to start from, square tiles in a wrapped line;
// groups of permissions folded under a line that counts them, each section's head and its groups three to a line; words
// pressed quietly beside a row (underlined, muted); a place to pick (its mark, its name, what picking it does at its end,
// on the accent's ground picked); where a connect stands on its head's line; a bot's picture filling its tile. What each
// is to the hand, the keyboard and a screen reader is mbui's headless part's (action_box_node's, check_node's); here
// only their look. What they say and do is their page's, given.

///|
/// Words pressed beside a row, quietly (清除、全选、推荐色): `label()` in the meta's 13 underlined, muted, in the words'
/// ink under the pointer; read out a button by them, `press` done as they are pressed. The node.
#callsite(autofill(loc))
pub fn quiet_action_node(parent : @view.View, label : () -> String, press : () -> Unit, loc~ : SourceLoc) -> @view.View {
  action_box_node(loc~, parent, label, fn(_) { press() }, fn(b) {
    b.box(fn(w) {
      w
      .words_runs(By(fn() { [@ui.span(label(), underline=true)] }))
      // (its look by the theme as it is now, followed: worked out as it is made, it read the theme untracked)
      .words_look(By(fn() { @ui.style_words(quiet_action_words) }))
      .ink(By(fn() { @ui.style_ink(if b.pointed() { quiet_action_lit } else { quiet_action_words }) }))
      |> ignore
    })
    |> ignore
  })
}

///|
/// An icon's well (an app's avatar: 128 square, the settings' corner, edged in the line, on `ground()`), pressed to give
/// it a picture (a button named `label`, `press` done as it is pressed): the picture `shown()` (its key, at `px`)
/// covering it, or, while it is "", an upload's mark over `empty()` (a note's words), both in `ink()`. The node (a tip
/// is its caller's).
#callsite(autofill(loc))
pub fn icon_well_node(
  parent : @view.View,
  label : () -> String,
  press : () -> Unit,
  ground : () -> Int64,
  ink : () -> Int64,
  shown : () -> String,
  empty : () -> String,
  px : Int,
  loc~ : SourceLoc,
) -> @view.View {
  action_box_node(loc~, parent, label, fn(_) { press() }, fn(a) {
    style_node(loc~, a, fn() { icon_well }, in_row=true)
    a.ground(By(ground)).clips(Is(true)) |> ignore
    a.pick(shown, fn(s, now) {
      if now != "" {
        s.box(fn(img) {
          img.over(Is(true)).image(Is(Some((now, "", px)))).image_covers(Is(true)).image_fades(Is(false)) |> ignore
        })
        |> ignore
      } else {
        s.box(fn(e) {
          style_node(loc~, e, fn() { icon_well_empty })
          icon_node(e, "image-upload", icon_well_mark, By(ink)) |> ignore
          words_node(loc~, e, empty, fn() { wide_list_note }).ink(By(ink)) |> ignore
        })
        |> ignore
      }
    })
  })
}

///|
/// A colour typed as hex beside its swatch (28 square, a corner of 8, edged in the border, on `ground()`): the field
/// `hex` (96 wide, read out `label`), and what `after` makes after them (a way back to the colour recommended), 8
/// apart on one line.
#callsite(autofill(loc))
pub fn swatch_field_node(
  parent : @view.View,
  hex : @ui.Field,
  ground : () -> Int64,
  label : String,
  after? : (@view.View) -> Unit,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(c) {
    style_node(loc~, c, fn() { swatch_line })
    c.box(fn(w) {
      style_node(loc~, w, fn() { swatch }, in_row=true)
      w.ground(By(ground)) |> ignore
    })
    |> ignore
    c.box(fn(h) {
      style_node(loc~, h, fn() { swatch_hex }, in_row=true)
      input_node(h, hex, label~) |> ignore
    })
    |> ignore
    match after {
      Some(f) => f(c)
      None => ()
    }
  })
}

///|
/// The avatars to start from in `parent` (`all()` as they are now): 15 to a line in the room `width()` says, fewer
/// where it is less, 6 apart, 16 over them, 10 under; each square on its own colour, edged in the line (the one
/// `picked()` names ringed in the ink, the field's hover edge under the pointer), its maker's mark (55% of it, white
/// where it is one colour) or its picture (1.18 times it); named by its tip in `tips`, `pick` given it as it is pressed.
#callsite(autofill(loc))
pub fn avatar_tiles_node(
  parent : @view.View,
  all : () -> Array[AppAvatar],
  picked : () -> String,
  width : () -> Double,
  pick : (AppAvatar) -> Unit,
  tips : TipLayer,
  loc~ : SourceLoc,
) -> @view.View {
  let side = fn() { (width() - avatar_tile_gap * (avatar_tile_columns - 1).to_double()) / avatar_tile_columns.to_double() }
  parent.box(made_for=loc, fn(p) {
    style_node(loc~, p, fn() { avatar_tiles })
    p.box(fn(r) {
      style_node(loc~, r, fn() { avatar_tiles_row })
      r.wraps(Is(Some(avatar_tile_gap))) |> ignore
      // (the one picked, by member: a change of it tells the two tiles it concerns)
      let picked_is = r.selected(fn() { Some(picked()) })
      // (each tile its own avatar, given it by the list as it is made)
      r.each(all, fn(a) { a.id }, fn(cell, item) {
        let a = item.untracked()
        let label = if a.label.has_prefix("android-") { t(a.label) } else { a.label }
        let on = fn() { picked_is(a.id) }
        let tile = action_box_node(loc~, cell, fn() { label }, selected=on, fn(_) { pick(a) }, fn(b) {
          // (its edge: picked, avatar_tile_on's; under the pointer, avatar_tile_lit's, its hovered{border_color=FieldHover})
          style_node(loc~, b, fn() { if on() { avatar_tile_on } else if b.pointed() { avatar_tile_lit } else { avatar_tile } })
          b
          .width(By(fn() { Some(side()) }))
          .height(By(fn() { Some(side()) }))
          .ground(Is(hex_color(a.bg).unwrap_or(icon_fallback)))
          .clips(Is(true))
          |> ignore
          if a.mark != "" {
            b.pick(side, fn(m, w) {
              drawable_node(m, a.mark, w * avatar_mark_share, tint?=if a.mono { Some(fn() { Some(avatar_white) }) } else { None }) |> ignore
            })
          } else {
            b.box(fn(img) {
              img
              .over(Is(true))
              .scale(Is(avatar_thumb_scale))
              .image(Is(Some((avatars_base() + "/avatars/" + a.id + ".thumb.webp", "", 256))))
              .image_covers(Is(true))
              |> ignore
            })
            |> ignore
          }
        })
        tip_node(tips, tile, fn() { label }) |> ignore
      })
    })
    |> ignore
  })
}

///|
/// A group of permissions to tick (check_groups_node's): its id, its name, what it allows (its tip), whether it is
/// always on (`fixed`: a tick without a box) and whether only admins allow it (`admin`).
#derive(Eq, Debug)
pub(all) struct CheckGroup {
  id : String
  label : String
  tip : String
  fixed : Bool
  admin : Bool
}

///|
/// A section of groups (check_groups_node's): its title and its groups.
#derive(Eq, Debug)
pub(all) struct CheckSection {
  title : String
  groups : Array[CheckGroup]
}

///|
/// What check_groups_node says: its line (`summary(on, all)`), turning all on from it, a section's 全选 and 全不选, and
/// what is beside a group only admins allow.
pub(all) struct CheckGroupsSaid {
  summary : (Int, Int) -> String
  all_on : () -> String
  select_all : () -> String
  select_none : () -> String
  admin : () -> String
}

///|
/// Groups of permissions, folded, in `parent` (`sections()` as they are now; nothing while they have none): a line
/// saying how many are on of all (`on(id)` each), pressed to open them (`open()`, `toggle` done as it is pressed: a
/// disclosure), all turned on from its end while some are off; open, each section its title and 全选 / 全不选 (its
/// fixed groups staying on), its groups three to a line where the room has it, two or one where it has less (each
/// column 152 at least, 192 where some group says only admins allow it, at the system's size of words), each a box to tick (`set(id, on)` told as it is ticked) and
/// its name (what only admins allow said after it), the pointer's ground on it, what it allows over it on hover (its tip
/// in `tips`); a fixed one a tick without a box.
#callsite(autofill(loc))
pub fn check_groups_node(
  parent : @view.View,
  sections : () -> Array[CheckSection],
  on : (String) -> Bool,
  set : (String, Bool) -> Unit,
  open : () -> Bool,
  toggle : () -> Unit,
  said : CheckGroupsSaid,
  tips : TipLayer,
  loc~ : SourceLoc,
) -> Unit {
  let every = fn() {
    let out : Array[String] = []
    for s in sections() {
      for g in s.groups {
        out.push(g.id)
      }
    }
    out
  }
  let count = fn() { every().filter(fn(g) { on(g) }).length() }
  let admin_any = fn() { sections().iter().any(fn(s) { s.groups.iter().any(fn(g) { g.admin }) }) }
  parent.show(fn() { every().length() > 0 }, fn(p) {
    p.box(made_for=loc, fn(b) {
      style_node(loc~, b, fn() { check_groups })
      b.box(fn(l) {
        style_node(loc~, l, fn() { check_groups_line })
        let summary = fn() { (said.summary)(count(), every().length()) }
        action_box_node(loc~, l, summary, expanded=open, fn(_) { toggle() }, fn(s) {
          style_node(loc~, s, fn() { check_groups_summary }, in_row=true)
          icon_node(s, "chevron-right", check_groups_chevron, By(fn() { theme().p.muted }), name_now=fn() {
            if open() {
              "chevron-down"
            } else {
              "chevron-right"
            }
          })
          |> ignore
          words_node(loc~, s, summary, fn() { check_groups_said }) |> ignore
        })
        |> ignore
        l.show(fn() { count() < every().length() }, fn(a) {
          quiet_action_node(loc~, a, said.all_on, fn() {
            for g in @signals.untracked(every) {
              set(g, true)
            }
          })
          |> ignore
        })
      })
      |> ignore
      b.show(open, fn(o) {
        o.box(fn(ss) {
          style_node(loc~, ss, fn() { check_sections })
          ss.each(fn() { sections().mapi(fn(i, s) { (i, s) }) }, fn(x) { x.1.title + "\u{1}" + x.0.to_string() }, fn(sec, x) {
            let section = @signals.untracked(fn() { x.get().1 })
            let groups = section.groups
            let all = fn() { groups.iter().all(fn(g) { on(g.id) }) }
            sec.box(fn(s) {
              style_node(loc~, s, fn() { check_section })
              s.box(fn(h) {
                style_node(loc~, h, fn() { check_section_head })
                words_node(loc~, h, fn() { section.title }, fn() { check_section_title }) |> ignore
                quiet_action_node(loc~, h, fn() { if all() { (said.select_none)() } else { (said.select_all)() } }, fn() {
                  let was = @signals.untracked(all)
                  for g in groups {
                    set(g.id, g.fixed || !was)
                  }
                })
                |> ignore
              })
              |> ignore
              // (as many to a line as the room has for each, three at most, a line's last ones as wide as the others
              // and where they would be under them: a width each, bound to the room, never a structure by it)
              s.by_room(fn(grid, room) {
                style_node(loc~, grid, fn() { check_grid })
                grid.wraps(Is(Some(check_grid_lines))) |> ignore
                let each_w = fn() {
                  let w = room.width()
                  if w <= 0.0 {
                    None
                  } else {
                    let least = (if admin_any() { check_col_admin } else { check_col }) * grid.words_scale()
                    let n = check_columns(w, least)
                    // (in 64ths of a point: n of them and their gaps never more than the line, which would wrap)
                    Some(((w - check_grid_gap * (n - 1).to_double()) / n.to_double() * 64.0).floor() / 64.0)
                  }
                }
                for g in groups {
                  check_group_node(loc~, grid, g, on, set, said, tips, each_w)
                }
              })
              |> ignore
            })
            |> ignore
          })
        })
        |> ignore
      })
    })
    |> ignore
  })
}

///|
/// A group of permissions in `r` (check_groups_node's), as wide as `width()` says: its box ticked (a fixed one, always
/// on: a tick without a box), its name (cut short where it has not the room), what only admins allow said beside it, the pointer's ground on it; what it allows over it while it is
/// pointed at.
#callsite(autofill(loc))
fn check_group_node(
  r : @view.View,
  g : CheckGroup,
  on : (String) -> Bool,
  set : (String, Bool) -> Unit,
  said : CheckGroupsSaid,
  tips : TipLayer,
  width : () -> Double?,
  loc~ : SourceLoc,
) -> Unit {
  let item = r.box(made_for=loc, fn(b) {
    style_node(loc~, b, fn() { check_group }, in_row=true)
    b.width(By(width)) |> ignore
    hover_ground_node(b)
    if g.fixed {
      icon_node(b, "check", check_group_tick, By(fn() { theme().p.accent })) |> ignore
    } else {
      check_node(b, fn() { on(g.id) }, fn(now) { set(g.id, now) }, fn() { g.label })
    }
    b.box(fn(l) {
      style_node(loc~, l, fn() { check_group_label }, in_row=true)
      l.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
      words_node(loc~, l, fn() { g.label }, fn() { check_group_words }) |> ignore
    })
    |> ignore
    if g.admin {
      words_node(loc~, b, said.admin, fn() { wide_list_note }) |> ignore
    }
  })
  tip_node(tips, item, fn() { g.tip }) |> ignore
}

///|
/// A place to pick in `parent` (a channel, a group, a bot to reply through): `mark` making its mark first, its name
/// (cut short; the accent's text while `on()`, faint while it cannot be picked: `can()`), what `end` makes at its end
/// after the room left; 34 high at least, 6 by 10 in, its parts 8 apart, an option's corner, on the accent's ground
/// while `on()`, the hover grey pointed at while it can be pressed. `press`: pressed, a button named by it (one of
/// several, read out selected while `selected()` says, where that is given); none: what it shows, nothing to press.
#callsite(autofill(loc))
pub fn place_row_node(
  parent : @view.View,
  name : () -> String,
  mark : (@view.View) -> Unit,
  on : () -> Bool,
  end? : (@view.View) -> Unit,
  press? : () -> Unit,
  can? : () -> Bool = fn() { true },
  selected? : () -> Bool,
  loc~ : SourceLoc,
) -> Unit {
  let look = fn(b : @view.View) {
    style_node(loc~, b, fn() { place_row })
    b.ground(By(fn() { if on() { @ui.tree_theme().color(AccentBg) } else { 0L } })) |> ignore
    hover_ground_node(b, on=fn() { !on() && press is Some(_) && can() })
    mark(b)
    words_node(loc~, b, name, fn() { if on() { place_name_on } else if can() { place_name } else { place_name_out } }) |> ignore
    b.box(fn(g) { style_node(loc~, g, fn() { place_grow }, in_row=true) }) |> ignore
    match end {
      Some(f) => f(b)
      None => ()
    }
  }
  match (press, selected) {
    (Some(f), Some(sel)) => action_box_node(loc~, parent, name, selected=sel, fn(_) { f() }, look) |> ignore
    (Some(f), None) => action_box_node(loc~, parent, name, fn(_) { f() }, look) |> ignore
    (None, _) => parent.box(made_for=loc, look) |> ignore
  }
}

///|
/// What picking a place does, at its row's end (place_row_node's `end`), in `parent`: `note()` in the meta's size, muted
/// (the accent's text while `on()`), `change()` after it in 500 where that is given (更换 on the place picked).
#callsite(autofill(loc))
pub fn place_note_node(
  parent : @view.View,
  note : () -> String,
  on : () -> Bool,
  change? : () -> String,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(w) {
    w
    .words_runs(By(fn() {
      match change {
        Some(c) => [@ui.span(note() + " · "), @ui.span(c(), weight=place_change_weight)]
        None => [@ui.span(note())]
      }
    }))
    .words_look(By(fn() { @ui.style_words(place_note_look(on())) }))
    .ink(By(fn() { @ui.style_ink(place_note_look(on())) }))
    |> ignore
  })
}

///|
/// What picking a place does (place_note_node's words): the meta's size, muted; the accent's text `on`.
pub fn place_note_look(on : Bool) -> @ui.TextStyle {
  if on {
    place_note_on
  } else {
    place_note
  }
}

///|
/// Where a connect stands, on its head's line in `st`, 8 apart, as one: while `doing()` says something (being
/// reconnected, switched or saved), a ring and it; else while `failing()` does (failed a moment ago), what `failed`
/// makes (its red mark) and it; else its dot (`presence()`) and `status()`. In the meta's words, muted.
#callsite(autofill(loc))
pub fn head_state_node(
  st : @view.View,
  doing : () -> String,
  failing : () -> String,
  presence : () -> String,
  status : () -> String,
  failed : (@view.View) -> Unit,
  loc~ : SourceLoc,
) -> Unit {
  st.pick(fn() { if doing() != "" { 1 } else if failing() != "" { 2 } else { 0 } }, fn(p, k) {
    p.row(Is(true)).gap(Is(head_state_gap)).lines_up(Is(Some(Middle))) |> ignore
    match k {
      1 => {
        spinner_node(p, size=head_state_icon) |> ignore
        words_node(loc~, p, doing, fn() { head_state_words }) |> ignore
      }
      2 => {
        failed(p)
        words_node(loc~, p, failing, fn() { head_state_words }) |> ignore
      }
      _ => {
        state_dot_node(p, presence)
        words_node(loc~, p, status, fn() { head_state_words }) |> ignore
      }
    }
  })
}

///|
/// A bot's picture filling its tile in `m`, `side` across (an app's icon: a square with the theme's Lg corner, as
/// Slack shows it), once `key()` (its picture's key, "" none) is decoded: its decode asked here, nothing drawn of it
/// before; till then and where it has none, its kind's mark on the paper (what `mark` makes in the tile, given its
/// size, three fifths of it).
#callsite(autofill(loc))
pub fn bot_tile_node(
  m : @view.View,
  key : () -> String,
  side : Double,
  mark : (@view.View, Double) -> Unit,
  loc~ : SourceLoc,
) -> @view.View {
  m.box(made_for=loc, fn(d) {
    d.width(Is(Some(side))).height(Is(Some(side))) |> ignore
    // (its picture's node made only once it is decoded: its decode asked here, nothing drawn of it asking it before)
    let ready = fn() {
      let k = key()
      if k == "" {
        return false
      }
      d.image_ask(k, side * d.pixel_scale())
      d.image_ready(k, side * d.pixel_scale())
    }
    d.show(ready, fn(p) {
      p
      .width(Is(Some(side)))
      .height(Is(Some(side)))
      .radius(By(fn() { @ui.tree_theme().corner(Lg) }))
      .image(By(fn() { Some((key(), "", 8192)) }))
      .image_covers(Is(true))
      |> ignore
    })
    // (its kind's mark three fifths of it, on a tile of its side: no larger than the room its head gives it)
    d.show(fn() { !ready() }, fn(t) {
      style_node(loc~, t, fn() { bot_tile_box })
      t.width(Is(Some(side))).height(Is(Some(side))).ground(By(fn() { theme().p.paper })) |> ignore
      mark(t, (side * bot_tile_mark).round())
    })
  })
}

///|
// kept across runs: a value (no field of it changes)
let quiet_action_words : @ui.TextStyle = @ui.text_style(size=Meta, leading=L6, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let quiet_action_lit : @ui.TextStyle = quiet_action_words.then(@ui.text_style(color=Fg))

///|
/// The well (appAvatar: 136 as the web had it, S32 here; the settings' corner), its upload mark 20.
// kept across runs: a value (no field of it changes)
let icon_well : @ui.Style = @ui.css("w=S32 h=S32 radius=Xl3 clip border=B1 border_color=Line align=ACenter justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
let icon_well_empty : @ui.Style = @ui.css("gap=S1 align=ACenter justify=JCenter")

///|
let icon_well_mark : Double = 20.0

///|
/// The swatch's line (appColour: 8 apart, the swatch 28, the hex field 96).
// kept across runs: a value (no field of it changes)
let swatch_line : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let swatch : @ui.Style = @ui.css("w=S7 h=S7 radius=Lg border=B1 border_color=Border")

///|
// kept across runs: a value (no field of it changes)
let swatch_hex : @ui.Style = @ui.css("w=S24")

///|
/// The avatars: 15 to a line, 6 apart (a mark 55% of its tile, a picture 1.18 times it).
let avatar_tile_columns : Int = 15

///|
let avatar_tile_gap : Double = 6.0

///|
let avatar_mark_share : Double = 0.55

///|
let avatar_thumb_scale : Double = 1.18

///|
let avatar_white : Int64 = 0xFFFFFFFFL

///|
// kept across runs: a value (no field of it changes)
let avatar_tiles : @ui.Style = @ui.css("w=Full pt=S4 pb=S2_5 gap=S1_5")

///|
// kept across runs: a value (no field of it changes)
let avatar_tiles_row : @ui.Style = @ui.css("row w=Full gap=S1_5")

///|
// kept across runs: a value (no field of it changes)
let avatar_tile : @ui.Style = @ui.css("radius=Lg clip border=B1 border_color=Line align=ACenter justify=JCenter hovered{border_color=FieldHover}")

///|
/// A tile under the pointer (avatar_tile's hovered, as a node takes it).
// kept across runs: a value (no field of it changes)
let avatar_tile_lit : @ui.Style = avatar_tile.then(@ui.css("border_color=FieldHover"))

///|
// kept across runs: a value (no field of it changes)
let avatar_tile_on : @ui.Style = avatar_tile.then(@ui.css("border=B2 border_color=Fg"))

///|
/// The permissions (appPerms: the ui's 13; its line muted, 6 down; the sections 4 apart, 8 under it; a section's head
/// its title (h4) and its toggle; three to a line, 8 apart), the chevron 14, a fixed group's tick 13.
// kept across runs: a value (no field of it changes)
let check_groups : @ui.Style = @ui.css("w=Full")

///|
// kept across runs: a value (no field of it changes)
let check_groups_line : @ui.Style = @ui.css("row w=Full py=S1_5 gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let check_groups_summary : @ui.Style = @ui.css("row gap=S1 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let check_groups_said : @ui.TextStyle = @ui.text_style(size=Meta, leading=L6, color=Muted, wrap=false)

///|
let check_groups_chevron : Double = 14.0

///|
let check_group_tick : Double = 13.0

///|
// kept across runs: a value (no field of it changes)
let check_sections : @ui.Style = @ui.css("w=Full pt=S2 gap=S1")

///|
// kept across runs: a value (no field of it changes)
let check_section : @ui.Style = @ui.css("w=Full gap=S1")

///|
// kept across runs: a value (no field of it changes)
let check_section_head : @ui.Style = @ui.css("row w=Full pt=S2 gap=S2 align=ACenter justify=JBetween")

///|
// kept across runs: a value (no field of it changes)
let check_section_title : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, weight=Semibold, color=Muted, wrap=false)

///|
/// The groups of a section, wrapping (8 along a line, 4 between lines: the section's gap, as its lines were).
// kept across runs: a value (no field of it changes)
let check_grid : @ui.Style = @ui.css("row gap=S2")

///|
let check_grid_gap : Double = 8.0

///|
let check_grid_lines : Double = 4.0

///|
/// How wide a column is at least for a group's box, its name and their room (152), and with 需管理员 beside it (192), at
/// words as said.
let check_col : Double = 152.0

///|
let check_col_admin : Double = 192.0

///|
/// How many columns of groups `w` holds, each `least` wide at least and check_grid_gap apart: three at most, one at
/// least (and three before it is laid out).
fn check_columns(w : Double, least : Double) -> Int {
  if w <= 0.0 || w >= least * 3.0 + check_grid_gap * 2.0 {
    3
  } else if w >= least * 2.0 + check_grid_gap {
    2
  } else {
    1
  }
}

///|
/// A group (modelPoolItem: a column of the line, 32 high, 8 by 6 in, 8 apart, the pointer's ground on it).
// kept across runs: a value (no field of it changes)
let check_group : @ui.Style = @ui.css("row h=S8 px=S2 gap=S2 radius=Lg align=ACenter hovered{bg=Hover}")

///|
// kept across runs: a value (no field of it changes)
let check_group_label : @ui.Style = @ui.style(w=grow)

///|
// kept across runs: a value (no field of it changes)
let check_group_words : @ui.TextStyle = @ui.text_style(size=Ui, leading=L5, color=Fg, wrap=false, w=Cut)

///|
/// A place's least height (34), 更换's weight (500).
let place_row_h : Double = 34.0

///|
let place_change_weight : Int = 500

///|
/// A place (6 by 10 in, its parts 8 apart, an option's corner; the hover grey pointed at).
// kept across runs: a value (no field of it changes)
let place_row : @ui.Style = @ui.css("row w=Full px=S2_5 py=S1_5 gap=S2 radius=Xl align=ACenter hovered{bg=Hover}").then(
  @ui.style(min_h=Fixed(place_row_h)),
)

///|
// kept across runs: a value (no field of it changes)
let place_grow : @ui.Style = @ui.style(w=grow)

///|
/// Its name (the ui's size, cut short), the accent's text picked, muted where it cannot be.
// kept across runs: a value (no field of it changes)
let place_name : @ui.TextStyle = @ui.text_style(size=Ui, color=Fg, wrap=false, max_lines=1)

///|
// kept across runs: a value (no field of it changes)
let place_name_on : @ui.TextStyle = place_name.then(@ui.text_style(color=AccentText))

///|
// kept across runs: a value (no field of it changes)
let place_name_out : @ui.TextStyle = place_name.then(@ui.text_style(color=Muted))

///|
// kept across runs: a value (no field of it changes)
let place_note : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let place_note_on : @ui.TextStyle = place_note.then(@ui.text_style(color=AccentText))

///|
/// Where a connect stands on its head's line (head_state's gap=S2, its ring 14, the meta's words muted).
let head_state_gap : Double = 8.0

///|
let head_state_icon : Double = 14.0

///|
/// The words of a connect's head's lines under its name (the meta's, muted, one line).
// kept across runs: a value (no field of it changes)
pub let head_state_words : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, wrap=false)

///|
/// A bot's tile while it has no picture (its kind's mark three fifths of it, in its middle, the theme's Xl corner).
let bot_tile_mark : Double = 0.6

///|
// kept across runs: a value (no field of it changes)
let bot_tile_box : @ui.Style = @ui.css("align=ACenter justify=JCenter radius=Xl")
