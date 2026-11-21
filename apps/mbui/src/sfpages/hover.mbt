// A card over what the pointer rests on, as the web's (still.fail web/src/Peeks.tsx Hover, cardTile):
// opened once the pointer has rested on it 320 ms, closed 120 ms after it has left both it and the card; under it and
// at its start, 6 away, kept in the window; a small panel (the popover's: 6 in, what it holds 10 in more), 320 wide
// (`tile`: as wide as what it holds, 220 at least); it grows out of its edge from .96 and clear over 160 ms as it comes,
// and goes to .97 and clear over 90 ms (Hover.css.ts enter, exit: a card the pointer left, not one put away by a
// press, so not at once as a menu goes). And an agent's card
// , the same over its picture beside its messages and over its mark in the chat's bar.

///|
/// Its delays (Radix's HoverCard as Peeks.tsx sets it), how far from what it is over, how small it starts.
pub let hover_open_ms : Double = 320.0

///|
pub let hover_close_ms : Double = 120.0

///|
/// How far a hover card's words stand in from its panel's padding (hover_inner's 10): what reaches out of them to its
/// corners (a pill in a corner: peeks' peek_capsule_in, peek_button_in) reaches out by that.
let hover_words_in : Double = 10.0

///|
fn hover_reset() -> Unit {
  peek_copied_at.clear()
}

///|
/// How long they take to run on, and how (LINES_EASE).
pub let lines_ms : Double = 240.0

///|
/// Its mark's side.
let agent_card_mark : Double = 28.0

///|
/// A tone's colour as a style says it (green, blue, red, amber; else subtle).
fn tone_token(tone : String) -> @ui.Color {
  match tone {
    "accent" => Accent
    "green" => Positive
    "blue" => Link
    "red" => Danger
    "amber" | "warn" => Warn
    _ => Subtle
  }
}

///|
/// The transcript entry of one of its latest lines, by its key (AgentCardLine): none for what it does now.
fn line_entry(key : String) -> Int? {
  if key == "now" {
    return None
  }
  let n = @string.parse_int(key[:]) catch { _ => return None }
  Some(n)
}

///|
/// What is under way of what can be done to a context.
// kept across runs: a value (no element of it changes)
let context_calls : Array[String] = ["session.compact", "session.clear"]

///|
/// What can be done to agent `key`'s context on `station` (useContextActions; `s` its session as its chat's view has
/// it), a menu beside `from`: 压缩上下文 at once, 清空上下文 (in red) asked first; neither while one is under way.
pub fn open_context_actions(src : Source, station : String, key : String, s : Json?, from : @sf.Beside) -> Unit {
  let params : Json = { "station": Json::string(station), "key": Json::string(key) }
  let busy = core_doing(src, context_calls, [("station", station), ("key", key)])
  let items : Array[@sf.MenuItem?] = []
  if flag(s, "canCompact") {
    items.push(
      Some(
        @sf.menu_item_of(
          @sf.t("web-pages.chat.compact"),
          fn() { act(src, @sf.t("web-pages.chat.compact"), "", "session.compact", params) },
          icon="shrink",
          disabled=busy,
        ),
      ),
    )
  }
  if flag(s, "canClear") {
    items.push(
      Some(
        @sf.menu_item_of(
          @sf.t("web-pages.chat.clear"),
          fn() {
            // asked as the web asks it
            @sf.confirm(
              @sf.t("web-pages.chat.clearConfirm"),
              @sf.t("web-pages.chat.clearBody"),
              @sf.t("web-pages.chat.clear"),
              danger=true,
              fn() { act(src, @sf.t("web-pages.chat.clear"), "", "session.clear", params) },
            )
          },
          icon="refresh",
          danger=true,
          disabled=busy,
        ),
      ),
    )
  }
  if items.length() > 0 {
    @sf.menu(items, from~)
  }
}

///|
/// What can be done to an agent's context from its tile:
/// its menu opened, something under way, whether it can be compacted.
pub(all) struct ContextEntry {
  open : () -> Unit
  busy : Bool
  compacts : Bool
}

///|
/// The card (agentCard: 288 wide), its parts 8 apart; its head's mark and name 10 apart.
// kept across runs: a value (no field of it changes)
let agent_card_box : @ui.Style = @ui.style(w=@sf.agent_card_w, gap=S2)

///|
// kept across runs: a value (no field of it changes)
let agent_card_across : @ui.Style = @ui.style(w=Full, min_w=@sf.agent_card_w, gap=S2)

///|
/// Its head: a small panel's row (presenters' small_panel_row_in), its ground under the hand, concentric with the
/// card's corners.
// kept across runs: a value (no field of it changes)
let agent_card_head : @ui.Style = @ui.css("row w=Full gap=S2_5 align=AStart radius=Inner hovered{bg=Hover}")
  .then(
    @ui.style(p=@sf.room_of(agent_card_head_pad), mt=@sf.room_of(-agent_card_head_out), mx=@sf.room_of(-agent_card_head_out)),
  )

///|
/// How far its head reaches out past the card's words (hover_inner's 10) to be a small panel's row, its ground under
/// the hand at the panel's padding (6 from its edges): as far as the card's words are in (hover_inner's 10).
let agent_card_head_out : Double = hover_words_in

///|
/// Its head's padding: the ladder's inset, its mark that far in from its ground's corner, round by the ladder's next
/// step there (18 less 8: 10).
let agent_card_head_pad : Double = @sf.corner_inset

///|
/// Its label and its account's line under it: what its mark leaves of the head.
// kept across runs: a value (no field of it changes)
let agent_card_who : @ui.Style = @ui.style(w=@sf.grow)

///|
/// Its label on its mark's line, 28 (L7: its mark's side; the mark in the card's corner, by its first line as a
/// two-line item's).
// kept across runs: a value (no field of it changes)
let agent_card_label : @ui.TextStyle = agent_card_name.then(@ui.text_style(leading=L7))

///|
/// Its name and its account's room: what is left of the row.
// kept across runs: a value (no field of it changes)
let agent_card_name_room : @ui.Style = @ui.style(w=@sf.grow)

///|
/// Its name: the card's words (13), 500, cut at its end.
// kept across runs: a value (no field of it changes)
let agent_card_name : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Fg, wrap=false)

///|
/// Where it stands and its stop, side by side: its words what the stop leaves, the stop by their first line.
// kept across runs: a value (no field of it changes)
let agent_card_stands : @ui.Style = @ui.css("row w=Full gap=S2 align=AStart")

///|
/// Where it stands: 14 in, its dot (6, in its tone) at the first line's middle; that line's middle (its words 20 high)
/// the stop's (24), 2 down.
// kept across runs: a value (no field of it changes)
let agent_card_status : @ui.Style = @ui.style(row=true, w=@sf.grow, gap=S1_5, align=AStart, pl=S0_5, pt=S0_5)

///|
// kept across runs: a value (no field of it changes)
let agent_card_dot_room : @ui.Style = @ui.css("pt=S1_5")

///|
// kept across runs: a value (no field of it changes)
let agent_card_dot : @ui.Style = @ui.css("w=S1_5 h=S1_5 radius=Full")

///|
// kept across runs: a value (no field of it changes)
let agent_card_words : @ui.TextStyle = @ui.text_style(size=Ui, color=Fg, w=Full, max_lines=3)

///|
/// Its latest lines: 14 in, 2 apart, 12, muted; what it does now in the words' colour; each one line.
// kept across runs: a value (no field of it changes)
let agent_card_lines : @ui.Style = @ui.style(w=Full, pl=S3_5, gap=agent_card_lines_gap, clip=true)

///|
// kept across runs: a value (no field of it changes)
let agent_card_lines_gap : @ui.Space = S0_5

///|
/// A line: as wide as the list, cut at its end; a gone one's copy over the list, at its padding.
// kept across runs: a value (no field of it changes)
let agent_card_line_box : @ui.Style = @ui.css("w=Full")

///|
// kept across runs: a value (no field of it changes)
let agent_card_line : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let agent_card_now : @ui.TextStyle = @ui.text_style(size=Meta, color=Fg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let agent_card_action : @ui.TextStyle = agent_card_line.then(@sf.link)

///|
// kept across runs: a value (no field of it changes)
let agent_card_red : @ui.TextStyle = @ui.text_style(size=Meta, color=Danger, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let agent_card_amber : @ui.TextStyle = @ui.text_style(size=Meta, color=WarnInk, wrap=false)

///|
/// The figures, side by side, 6 apart; each 7 by 9 in, 8 round, on the hover's ground: the figure 16 in 600 over its
/// name (11, muted).
// kept across runs: a value (no field of it changes)
let agent_card_tiles_row : @ui.Style = @ui.css("row w=Full gap=S1_5")

///|
// kept across runs: a value (no field of it changes)
let agent_card_tile : @ui.Style = @ui.style(w=@sf.grow, py=@sf.files_row_end, px=S2, gap=SPx, radius=Lg, bg=Hover)

///|
/// The context's tile when something can be done to it: the pointer's ground over its own on hover, its name ending
/// in › 2 after.
// kept across runs: a value (no field of it changes)
let agent_card_tile_button : @ui.Style = agent_card_tile.then(@ui.css("hovered{bg=Hover}"))

///|
// kept across runs: a value (no field of it changes)
let agent_card_tile_more : @ui.Style = @ui.css("row gap=SPx align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let agent_card_figure : @ui.TextStyle = @ui.text_style(size=Title, weight=Semibold, color=Fg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let agent_card_figure_red : @ui.TextStyle = @ui.text_style(size=Title, weight=Semibold, color=Danger, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let agent_card_figure_amber : @ui.TextStyle = @ui.text_style(size=Title, weight=Semibold, color=WarnInk, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let agent_card_tile_name : @ui.TextStyle = @ui.text_style(size=Caption, color=Muted, wrap=false)

///|
/// What is left of its account, its windows 4 apart.
// kept across runs: a value (no field of it changes)
let agent_card_chips_gap : @ui.Space = S1

///|
/// Its account (12) under its label, what is left of it at that line's end, 8 apart: the head's last line, what is
/// left (capsules) in its ground's bottom right corner as far from both its edges as makes them concentric with it
/// (@sf.capsule_in), out past the head's padding (agent_card_head_pad) to there, its words on their foot.
// kept across runs: a value (no field of it changes)
let agent_card_account : @ui.Style = @ui.css("row w=Full gap=S2 align=AEnd").then(
  @ui.style(mb=@sf.room_of(agent_card_chips_in), mr=@sf.room_of(agent_card_chips_in)),
)

///|
let agent_card_chips_in : Double = @ui.capsule_in(@sf.row_corner, @sf.fill_chip_small_h) - agent_card_head_pad

///|
/// The ways its account's line is said: across the head.
// kept across runs: a value (no field of it changes)
let agent_card_account_ways : @ui.Style = @ui.css("row w=Full")

///|
/// Its account's name a line and what is left of it under it, at the line's end, where one line has not the room for
/// both: the capsules in the ground's corner as agent_card_account has them.
// kept across runs: a value (no field of it changes)
let agent_card_account_under : @ui.Style = @ui.css("w=Full gap=S1 align=AEnd").then(
  @ui.style(mb=@sf.room_of(agent_card_chips_in), mr=@sf.room_of(agent_card_chips_in)),
)

///|
/// Its account's name on a line of its own: cut at its end only where the card itself is narrower than it.
// kept across runs: a value (no field of it changes)
let agent_card_line_cut : @ui.TextStyle = agent_card_line.then(@ui.text_style(w=Cut))

///|
/// Words that lead somewhere: their whole line.
// kept across runs: a value (no field of it changes)
let agent_card_link_box : @ui.Style = @ui.css("row w=Full align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let agent_card_quiet : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, w=Full)

///|
// kept across runs: a value (no field of it changes)
let agent_card_notes : @ui.Style = @ui.css("w=Full gap=S0_5")

///|
/// Its stop: a circle 24 on the red's ground (as its pill with words was), its icon 12.
// kept across runs: a value (no field of it changes)
let agent_card_stop_box : @ui.Style = @ui.css((
  #|w=S6 h=S6 radius=Full align=ACenter justify=JCenter bg=DangerBg hovered{bg=Hover}
))

///|
let agent_card_stop_icon : Double = 12.0

///|
/// usage_tiles' figures as nodes in `parent`, as `card` says them now: what it cost, the cache's hit rate, how full its
/// context is (how much of how much over it while it is pointed at, in `tips`), each its share of the row. With
/// `context`, its context's tile opens what can be done to it beside itself (`busy`: a spinner, not pressed; `failed`:
/// the failure's mark; `compacts`: that it can be compacted said once it is filling up). None before it has made a
/// call. `roomy`: the figures of an agent's card in a sheet or its history (usage_tile_roomy: 9 over, 8 under, 16 in
/// at either side, a row's corner, the ink at 5%; each figure as large as fits its tile's room, 20 down, 16 down where
/// it is longer than six characters, its name on one line; the tiles of a row as tall as each other), `top` over them;
/// else a hover card's (agent_card_tile).
pub fn usage_tiles_node(
  parent : @view.View,
  card : () -> Json?,
  tips : @sf.TipLayer,
  context? : (@sf.Beside) -> Unit,
  busy? : () -> Bool = fn() { false },
  failed? : () -> Bool = fn() { false },
  compacts? : () -> Bool = fn() { false },
  roomy? : Bool = false,
  top? : Double = 0.0,
) -> Unit {
  let cost = fn() { text(card(), "cost") }
  let cache = fn() { field(card(), "cache") }
  let ctx = fn() { field(card(), "context") }
  let unknown = fn() { flag(ctx(), "unknown") }
  let level = fn() { if unknown() { "" } else { text(ctx(), "level") } }
  let ink = fn(level : String) {
    let p = @sf.theme().p
    match level {
      "red" => p.red
      "amber" => p.warn_ink
      _ => p.text
    }
  }
  // (a figure in `b`, in its level's ink: a hover card's at the title's size; a roomy one's as large as fits the
  // tile's room as it is laid out, on a line as tall as its largest's at the system's size of words, the tiles of a
  // row as high as each other, their names level)
  let figure_node = fn(b : @view.View, figure : () -> String, level : () -> String, room : () -> Double) {
    if roomy {
      b.box(fn(f) {
        f.min_height(By(fn() { Some(@sf.node_sp(f, usage_roomy_line)) })).lies_along(Is(Middle)) |> ignore
        f.box(fn(w) {
          w
          .words(By(figure))
          .words_look(By(fn() {
            let size = usage_figure_fit(w, figure(), room())
            { size, weight: 600, line: (size * usage_roomy_leading).round(), wrap: false, tracking: @view.letters_own, balance: false, max_lines: 0 }
          }))
          .ink(By(fn() { ink(level()) }))
          |> ignore
        })
        |> ignore
      })
      |> ignore
    } else {
      @sf.words_node(b, figure, fn() {
        match level() {
          "red" => agent_card_figure_red
          "amber" => agent_card_figure_amber
          _ => agent_card_figure
        }
      })
      |> ignore
    }
  }
  let name_look = fn() { if roomy { usage_roomy_name } else { agent_card_tile_name } }
  // (a tile in `t`: its ground, its figure over its name (a roomy one read out 「name figure」); `more` what stands after
  // its name)
  let tile = fn(
    t : @view.View,
    figure : () -> String,
    name : () -> String,
    level : () -> String,
    press : ((@view.View) -> Unit)?,
    more : ((@view.View) -> Unit)?,
  ) -> @view.View {
    let made = fn(b : @view.View, room : () -> Double) {
      @sf.style_node(b, fn() {
        match (roomy, press) {
          (true, _) => usage_tile_roomy.then(@ui.style(bg=Data(@sf.alpha(@sf.theme().p.text, usage_roomy_ground))))
          (false, Some(_)) => agent_card_tile_button
          (false, None) => agent_card_tile
        }
      })
      if roomy {
        // (a row's corner: concentric with the card's it stands in; read out 「name figure」)
        b.radius(Is(@sf.row_corner)) |> ignore
        let role : @view.Role = if press is Some(_) { Button } else { Text }
        b.says(By(fn() { Some(@view.said(role, label=name() + " " + figure())) })) |> ignore
        match press {
          Some(f) => @sf.presses_node(b, fn() { f(b) })
          None => ()
        }
      }
      figure_node(b, figure, level, room)
      match more {
        Some(m) =>
          b.box(fn(r) {
            @sf.style_node(r, fn() { agent_card_tile_more })
            @sf.words_node(r, name, name_look) |> ignore
            m(r)
          })
          |> ignore
        // (a roomy one's name wraps cleanly at word boundaries when large words outgrow a narrow tile)
        None if roomy => @sf.words_node(b, name, fn() { usage_roomy_name_wrap }) |> ignore
        None => @sf.words_node(b, name, name_look) |> ignore
      }
    }
    // (a roomy figure is as large as its tile's room: the tile made by the room it is given; a hover card's at its
    // size, the tile a box)
    if roomy {
      // (as tall as the row's tallest: the tiles of a row level at their feet)
      t.by_room(fn(b, given) {
        b.grow(Is(1.0)) |> ignore
        made(b, fn() { dmax(0.0, given.width() - 2.0 * @sf.text_in) })
      })
      .grow(Is(1.0))
      .basis(Is(Some(0.0)))
    } else {
      match press {
        // (a hover card's: what its press opens)
        Some(f) => @sf.action_box_node(t, fn() { @sf.t("web-pages.chat.contextActions") }, f, fn(b) { made(b, fn() { 0.0 }) })
        None => t.box(fn(b) { made(b, fn() { 0.0 }) })
      }
    }
  }
  // (each tile's share of the row: what shows it takes it)
  let across = fn(t : @view.View) { t.grow(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore }
  parent.show(at_once=true, fn() { cost() != "" || cache() is Some(Object(_)) || ctx() is Some(Object(_)) }, fn(o) {
    o.box(fn(r) {
      @sf.style_node(r, fn() { if roomy { usage_tiles_roomy.then(@ui.style(pt=@sf.room_of(top))) } else { agent_card_tiles_row } })
      r.show(at_once=true, fn() { cost() != "" }, fn(t) {
        across(t)
        tile(t, cost, fn() { @sf.t("web-main.chat.agentCard.cost") }, fn() { "" }, None, None) |> ignore
      })
      r.show(at_once=true, fn() { cache() is Some(Object(_)) }, fn(t) {
        across(t)
        tile(t, fn() { text(cache(), "text") }, fn() { @sf.t("web-main.chat.agentCard.cache") }, fn() { "" }, None, None)
        |> ignore
      })
      let figure = fn() {
        if unknown() {
          text(ctx(), "text")
        } else {
          number(ctx(), "percent").round().to_int().to_string() + "%"
        }
      }
      r.show(at_once=true, fn() { ctx() is Some(Object(_)) }, fn(t) {
        across(t)
        match context {
          Some(open) =>
            tile(
              t,
              figure,
              fn() {
                if compacts() && (level() == "amber" || level() == "red") {
                  @sf.t("web-mobile.agent.contextCompactable")
                } else {
                  @sf.t("web-main.chat.agentCard.context")
                }
              },
              level,
              Some(fn(b) {
                if !@signals.untracked(busy) {
                  let (x, y, w, h) = b.placed_window_now()
                  open(At(x, y, w, h))
                }
              }),
              Some(fn(m) {
                // (what can be done to it: ›; under way, turning; failed lately, its mark)
                m.pick(at_once=true, fn() { if busy() { 1 } else if failed() { 2 } else { 0 } }, fn(i, now) {
                  match now {
                    1 => @sf.spinner_node(i, size=usage_more_icon) |> ignore
                    2 => doing_mark_node(i, fn() { false }, fn() { Some("") })
                    _ => @sf.icon_node(i, "chevron-right", usage_more_icon, By(fn() { @sf.theme().p.muted })) |> ignore
                  }
                })
              }),
            )
            |> ignore
          None =>
            t.pick(at_once=true, unknown, fn(k, unknown_now) {
              if roomy {
                k.grow(Is(1.0)) |> ignore
              }
              let shown = tile(k, figure, fn() { @sf.t("web-main.chat.agentCard.context") }, level, None, None)
              if !unknown_now {
                @sf.tip_node(tips, shown, fn() { text(ctx(), "text") }) |> ignore
              }
            })
        }
      })
    })
    |> ignore
  })
}

///|
/// The size a figure is drawn at in node `v` (agent_tiles_fit_size's): the largest of its steps (16 down for one longer
/// than 6, else 20 down) whose figure is narrower than `room` at the system's size of words; 10 at the least.
fn usage_figure_fit(v : @view.View, figure : String, room : Double) -> Double {
  let sizes : Array[Double] = if figure.length() > 6 {
    [16.0, 15.0, 14.0, 13.0, 12.0, 11.0, 10.0]
  } else {
    [20.0, 17.0, 16.0, 15.0, 14.0, 13.0, 12.0, 11.0, 10.0]
  }
  for sz in sizes {
    if @sf.node_words_w(figure, @sf.node_sp(v, sz), weight=600) <= room - 1.0 {
      return sz
    }
  }
  10.0
}

///|
/// The roomy figures' row: 8 apart; each tile 9 over, 8 under, 16 in at either side, a row's corner, on the ink at 5%;
/// its figure on a line as tall as the largest's (26), each figure's own 1.3 its size; its name 12 on 16, muted,
/// wrapping cleanly when narrow (usage_roomy_name_wrap).
// kept across runs: a value (no field of it changes)
let usage_tiles_roomy : @ui.Style = @ui.css("row w=Full gap=S2 align=AStretch")

///|
// kept across runs: a value (no field of it changes)
let usage_tile_roomy : @ui.Style = @ui.css("pb=S2").then(
  @ui.style(pl=@sf.room_of(@sf.text_in), pr=@sf.room_of(@sf.text_in), pt=@sf.room_of(usage_roomy_over)),
)

///|
// kept across runs: a value (no field of it changes)
let usage_roomy_name_wrap : @ui.TextStyle = @ui.text_style(size=Caption, leading=L4, color=Muted, wrap=true)

///|
let usage_roomy_over : Double = 9.0

///|
let usage_roomy_ground : Double = 0.05

///|
let usage_roomy_line : Double = 26.0

///|
let usage_roomy_leading : Double = 1.3

///|
// kept across runs: a value (no field of it changes)
let usage_roomy_name : @ui.TextStyle = @ui.text_style(size=Caption, leading=L4, color=Muted, wrap=false)

///|
/// The › (or what turns, or the failure's mark) after the context's name: 11.
let usage_more_icon : Double = 11.0
