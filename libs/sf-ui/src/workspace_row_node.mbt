// The workspaces' list and an account's vendor where it is chosen (the app's workspace.mbt, new_profile.mbt,
// profiles_list.mbt, places_side_node.mbt): a part's label in a panel, a workspace's row (its mark or its letter, its
// name, the account it is of, what it has waiting, the check on the one in use), the card the one in use is on, an
// invitation waiting with 加入 and 忽略; a vendor's mark following what is said of it, and the same on a card's neutral
// ground in its top start corner.

///|
/// A part's label (13, muted) in `parent`, `label` as it is said now: as far in as a panel's words, 6 over it and 2
/// under (the workspaces' 当前, 其他, 邀请).
#callsite(autofill(loc))
pub fn workspace_label_node(parent : @view.View, label : () -> String, loc~ : SourceLoc) -> Unit {
  parent.box(made_for=loc, fn(l) {
    style_node(l, fn() { ws_label_box.then(panel_words_in_node(l)) })
    words_node(l, label, fn() { ws_label_words }) |> ignore
  })
  |> ignore
}

///|
/// A row of the workspaces' list in `parent`: what (`label`), a line under it (`sub`, none where ""), a check on the
/// one in use (`checked`); before it what `lead` makes (a workspace's mark: workspace_mark_node) or an icon; after its
/// words what `after` makes (what a workspace has waiting: as tall as their first line), each on the first line of its
/// words, never across both. `press` done as it is pressed, rippling (clip(Smooth(
/// LIST_ROW_CORNER)).clickable); read out a button named `label`. `on_card`: the one in use's, on its card
/// (workspace_card_node). Its mark and words on a panel's words' line, every row's on one.
#callsite(autofill(loc))
pub fn workspace_row_node(
  parent : @view.View,
  label : () -> String,
  sub : () -> String,
  press : () -> Unit,
  checked? : Bool = false,
  lead? : (@view.View) -> Unit,
  icon? : String = "",
  after? : (@view.View) -> Unit,
  on_card? : Bool = false,
  loc~ : SourceLoc,
) -> Unit {
  // (in a panel: on its card (the one in use), or a row of the panel's own `panel_card_in` from its sides; either way
  // its mark and words on the panel's words' line, every row's on one)
  parent.box(made_for=loc, fn(o) {
    style_node(o, fn() { if on_card { ws_row_on_card } else { ws_row_in.then(panel_card_out_node(o)) } })
    o.box(fn(r) {
      style_node(r, fn() { if on_card { ws_row_card } else { ws_row } })
      // (what stands beside its words on their first line, under a line under it as well: from its top, each on that
      // line (first_line_node); a row of one line in its middle, its least height's)
      r.lines_up(By(fn() { Some(if sub() != "" { Start } else { Middle }) })) |> ignore
      // (its ripple round as the card it is on less how far in it stands (workspace_card_node lends it), concentric with
      // it; alone, a card's corner in a panel)
      let corner = r.concentric_radius(fn() { if on_card { row_corner } else { card_corner } })
      pressed_node(r, press, corner, Button, label)
      // (its mark, or an icon in the same square a mark stands in: the rows' words on one line, a workspace's or an
      // action's)
      let lead_square = fn(make : (@view.View) -> Unit) {
        first_line_node(r, Ui, fn(f) {
          f.box(fn(l) {
            style_node(l, fn() { ws_row_lead })
            l.shrink(Is(0.0)) |> ignore
            make(l)
          })
          |> ignore
        })
        |> ignore
      }
      match lead {
        Some(make) => lead_square(make)
        None => ()
      }
      if icon != "" {
        lead_square(fn(l) { icon_node(l, icon, ws_row_icon, By(fn() { theme().p.text })) |> ignore })
      }
      r.box(fn(words) {
        style_node(words, fn() { full_width }, in_row=true)
        words_node(words, label, fn() { ws_row_label }) |> ignore
        // (as wide as it says, cut short where the row has not the room: ws_row_sub's w=Cut; under the label, down the
        // words' column: making its way in as it comes to say something, closing it as it says nothing)
        words.show(fn() { sub() != "" }, fn(s) {
          s.lines_up(Is(Some(Start))) |> ignore
          words_node(s, sub, fn() { ws_row_sub }) |> ignore
        })
      })
      |> ignore
      match after {
        Some(make) => make(r)
        None => ()
      }
      if checked {
        first_line_node(r, Ui, fn(c) { icon_node(c, "check", ws_row_check, By(fn() { theme().p.accent })) |> ignore })
        |> ignore
      }
    })
    |> ignore
  })
  |> ignore
}

///|
/// A workspace's mark in `parent`, as `emoji`, `icon` and `name` say it now: its mark (station_mark_node's) 22 across
/// in the words' ink, else its name's first letter (15 semibold, muted; part of the mark: at its size whatever the
/// system's size of words, mark_words_node), one in the other's place (a pick: its way from as tall as the other was).
/// What workspace_row_node's `lead` makes, in the 24 square it stands in.
#callsite(autofill(loc))
pub fn workspace_mark_node(
  parent : @view.View,
  emoji : () -> String,
  icon : () -> String,
  name : () -> String,
  loc~ : SourceLoc,
) -> Unit {
  parent.pick(loc~, fn() { has_station_mark(emoji(), icon()) }, fn(m, marked) {
    if marked {
      station_mark_node(m, emoji, icon, ws_row_mark, fn() { theme().p.text }, fn() { 0 })
    } else {
      mark_words_node(m, fn() { initial(name()) }, fn() { ws_row_letter }) |> ignore
    }
  })
}

///|
/// The card the one in use is on in `parent` (the workspaces' list's): 12 in from a panel's sides, 4 under its label
/// and 16 over what follows, its rows `corner_inset` in, the list card's corner, on the chips' grey; what is on it made
/// by `body` (its workspace_row_node, `on_card`).
#callsite(autofill(loc))
pub fn workspace_card_node(parent : @view.View, body : (@view.View) -> Unit, loc~ : SourceLoc) -> Unit {
  parent.box(made_for=loc, fn(out) {
    style_node(out, fn() { ws_current.then(panel_card_out_node(out)) })
    out.box(fn(card) {
      style_node(card, fn() { ws_card.then(@ui.style(bg=Data(theme().p.chip))) })
      // (its rows `corner_inset` in, concentric with its corner)
      corner_card_node(card, fn() { card_corner }, inset=fn() { corner_inset })
      body(card)
    })
    |> ignore
  })
  |> ignore
}

///|
/// An invitation waiting in `parent` (the workspaces' list's, under 邀请): who invited the viewer where (`words`), the
/// account it is for under it (`account`), then 加入 (`join`, the primary; waiting while `joining`) and 忽略 (`decline`;
/// waiting while `ignoring`), each as it is now. 20 in, 8 over and under, 8 apart; its buttons by its words' first line,
/// or under its words where the two have not the room side by side (its words 160 at the least).
#callsite(autofill(loc))
pub fn invitation_line_node(
  parent : @view.View,
  words : () -> String,
  account : () -> String,
  join : () -> Unit,
  decline : () -> Unit,
  joining~ : () -> Bool,
  ignoring~ : () -> Bool,
  loc~ : SourceLoc,
) -> Unit {
  parent.box(made_for=loc, fn(line) {
    style_node(line, fn() { invite_line })
    // (where its words and its buttons have not the room side by side, the buttons go on under its words, never
    // pressing them into a narrow column: only where its words at their least and the buttons whole have not the room)
    line.wraps(Is(Some(invite_lines))).wraps_at_least(Is(true)) |> ignore
    // (its words' first line and its buttons across one middle, never the buttons across the middle of its words'
    // lines: the shorter of the two put down by half of what it lacks of the other, from the line's top)
    let first = fn() {
      let th = @ui.tree_theme()
      node_sp(line, th.text_size(Body).1)
    }
    line.box(fn(w) {
      w
      .grow(Is(1.0))
      .basis(Is(Some(0.0)))
      .min_width(Is(Some(invite_words_least)), within=true)
      .padding(By(fn() {
        let d = dmax(0.0, (button_height() - first()) / 2.0)
        (0.0, d, 0.0, 0.0)
      }))
      |> ignore
      words_node(w, words, fn() { invite_line_words }) |> ignore
      words_node(w, account, fn() { invite_line_email }) |> ignore
    })
    |> ignore
    line.box(fn(b) {
      b
      .row(Is(true))
      .gap(Is(@ui.Space::S2.px()))
      .lines_up(Is(Some(Middle)))
      .shrink(Is(0.0))
      .padding(By(fn() {
        let d = dmax(0.0, (first() - button_height()) / 2.0)
        (0.0, d, 0.0, 0.0)
      }))
      |> ignore
      button_node(b, fn() { t("android-misc.invite.join") }, join, tone=Primary, busy=joining) |> ignore
      button_node(b, fn() { t("android-misc.invite.ignore") }, decline, busy=ignoring) |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// A vendor's mark (provider_logo_node's) in `parent`, `size` across, by its runtime, its kind and its own mark as `of`
/// says them now: made again only as one of them changes (an account's row, a provider's tile, a way to connect it).
#callsite(autofill(loc))
pub fn provider_mark_node(
  parent : @view.View,
  of : () -> (String, String, String),
  size : Double,
  loc~ : SourceLoc,
) -> Unit {
  parent.pick(loc~, of, fn(l, k) { provider_logo_node(l, k.0, k.1, size, k.2) |> ignore })
}

///|
/// A vendor's mark (provider_logo_node's, `size` across: `runtime`, `kind`, `mark`) on a card's neutral ground in
/// `parent`, 32 across in the card's top start corner, where the ladder's small block's corner (10) is concentric with
/// the card's (card_mark_out): a machine's own login offered.
#callsite(autofill(loc))
pub fn provider_badge_node(
  parent : @view.View,
  runtime : String,
  kind : String,
  size : Double,
  mark? : String = "",
  loc~ : SourceLoc,
) -> Unit {
  parent.box(made_for=loc, fn(m) {
    style_node(m, fn() { provider_badge })
    provider_logo_node(m, runtime, kind, size, mark) |> ignore
  })
  |> ignore
}

// ── styles ─────────────────────────────────────────

///|
// kept across runs: a value (no field of it changes)
let ws_label_box : @ui.Style = @ui.css("pt=S1_5 pb=S0_5")

///|
// kept across runs: a value (no field of it changes)
let ws_label_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false, leading=Font)

///|
/// The one in use: on a card 12 in from the sides, 4 under its label, 16 over what follows.
// kept across runs: a value (no field of it changes)
let ws_current : @ui.Style = @ui.css("w=Full pt=S1 pb=S4")

///|
/// A list card: its rows corner_inset in, the list card's corner, on the chips' grey.
// kept across runs: a value (no field of it changes)
let ws_card : @ui.Style = @ui.style(w=Full, p=room_of(corner_inset), radius=card_radius, clip=true)

///|
/// On a sheet: 12 in from its sides; the row 8 more in, 12 over and under, 12 apart.
// kept across runs: a value (no field of it changes)
let ws_row_in : @ui.Style = @ui.css("w=Full")

///|
// kept across runs: a value (no field of it changes)
let ws_row_on_card : @ui.Style = @ui.css("w=Full")

///|
/// A row: 12 over and under its words, 48 at least (a row of one line as tall as one beside its mark), its mark, words,
/// marks and check 12 apart, each by its words' first line (workspace_row_node).
// kept across runs: a value (no field of it changes)
let ws_row : @ui.Style = @ui.css("row w=Full min_h=S12 py=S3 gap=S3").then(@ui.style(px=room_of(panel_words - panel_card_in)))

///|
/// On the card (the one in use, among the rows of the others): its mark and words where the other rows' are, on the
/// panel's words' line; the card `panel_card_in` from the panel's sides and `corner_inset` in already, as far as the
/// rows' grounds reach, the rest of the way here (2026-11-07: a row's room more put its mark 16 past the others').
// kept across runs: a value (no field of it changes)
let ws_row_card : @ui.Style = @ui.css("row w=Full min_h=S12 py=S3 gap=S3").then(@ui.style(px=room_of(panel_words - panel_card_in - corner_inset)))

///|
/// A workspace's mark or its letter in a square 24 across: the mark 22, the letter 15 semibold, muted; an icon 20 in
/// the same square (an action's: 登录其他账号, 新建 workspace), the check 14.
// kept across runs: a value (no field of it changes)
let ws_row_lead : @ui.Style = @ui.css("w=S6 h=S6 align=ACenter justify=JCenter")

///|
let ws_row_mark : Double = 22.0

///|
let ws_row_icon : Double = 20.0

///|
let ws_row_check : Double = 14.0

///|
// kept across runs: a value (no field of it changes)
let ws_row_letter : @ui.TextStyle = @ui.text_style(size=Ui, weight=Semibold, color=Muted, wrap=false, leading=Font)

///|
/// What, 15 on 21; the line under it 12 on 17, muted.
// kept across runs: a value (no field of it changes)
let ws_row_label : @ui.TextStyle = @ui.text_style(size=Ui, color=Fg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let ws_row_sub : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false, w=Cut, leading=pick_sub_line)

///|
/// An invitation: 20 in, 8 over and under, 8 apart; its words the body's, the account under them small and muted.
// kept across runs: a value (no field of it changes)
let invite_line : @ui.Style = @ui.css("row w=Full px=S5 py=S2 gap=S2 align=AStart")

///|
/// Its buttons gone on under its words: 8 under them.
let invite_lines : Double = 8.0

///|
/// Its words' column at the least beside its buttons (narrower, the buttons go on under them).
let invite_words_least : Double = 160.0

///|
// kept across runs: a value (no field of it changes)
let invite_line_words : @ui.TextStyle = @ui.text_style(size=Body, color=Fg, w=Full)

///|
// kept across runs: a value (no field of it changes)
let invite_line_email : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, w=Full)

///|
/// A vendor's mark on a card: 32 on the neutral ground in the card's corner, the ladder's small corner.
// kept across runs: a value (no field of it changes)
let provider_badge : @ui.Style = @ui.css("w=S8 h=S8 bg=Neutral align=ACenter justify=JCenter").then(
  @ui.style(radius=small_radius),
).then(card_mark_out)
