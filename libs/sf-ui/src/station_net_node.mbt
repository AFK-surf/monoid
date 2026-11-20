// A station's machine as a list shows it, as nodes of the window's tree made once: a figure in its level's ink
// (level_figure_node), how this device reaches the station (station_net_line_node: how it goes and packets lost, its
// round trip; ↑ and ↓ beside them, under them where the line has not the room), and a list's card of one machine
// (summary_mark_card_node: its mark, its name, what is said of it, a chevron, pressed open). What they say is the
// core's (`stationNet`'s `{path, loss, rtt, up, down}`, a figure's `{text, level}`), given as it is.

///|
/// How a station's network line is drawn: `Card` (a card of the stations' list: the card's small words, their line of
/// the theme's 5, the figures as heavy as a medium, a long way of going or else what its round trip is called cut short
/// before the figures are); `Peek` (a station's card in brief, over where a chat names it: the meta's size on a line of
/// 18, the figures 500 heavy in the palette's inks, the words before them given way in their own box); `Page` (a
/// station's own page, under its dials: the figures at the ui's size, its round trip said in the words around it, each
/// speed at least 64 wide, 8 between its lines where the speeds go under).
#derive(Eq, Debug)
pub(all) enum NetLook {
  Card
  Peek
  Page
}

///|
/// A figure's words in `base`, by its `level` (`amber`, `red`, anything else fine): in the warning's ink or the
/// danger's where it is off, else as `base` has them.
pub fn level_figure_style(level : String, base : @ui.TextStyle) -> @ui.TextStyle {
  match level {
    "amber" => base.then(@ui.text_style(color=WarnInk))
    "red" => base.then(@ui.text_style(color=Danger))
    _ => base
  }
}

///|
/// A figure (`{text, level}`, as `f` says it now) in `parent`: its words in `style` (a card's figure where none is
/// said), in its level's ink where it is off (level_figure_style's). The words' node.
#callsite(autofill(loc))
pub fn level_figure_node(
  parent : @view.View,
  f : () -> Json?,
  style? : () -> @ui.TextStyle = fn() { net_card_figure },
  loc~ : SourceLoc,
) -> @view.View {
  words_node(loc~, parent, fn() { net_text(f(), "text") }, fn() { level_figure_style(net_text(f(), "level"), style()) })
}

///|
/// A connection made up (its words in Chinese), for what shows in its bones while the real one is read.
pub let station_net_sample : Json = Json::object({
  "path": "直连",
  "rtt": { "text": "0 ms", "level": "ok" },
  "down": "0.0 KB/s",
  "up": "0.0 KB/s",
})

///|
/// This device's connection to a station in `parent`, as `net` says it now (none: the made-up one,
/// station_net_sample, to be drawn in its bones), as `look` draws it: on the left how it goes and packets lost, then
/// `·` and its round trip; on the right ↑ and ↓, the speed each way, 10 apart; the right under the left where the line
/// has not the room (2 between the lines), ↓ under ↑ where even that has not. Short of room, one thing is cut short, never two: how it is reached where
/// that is long (net_path_long: a relay of the workspace's own, named by its address), else what its round trip is
/// called; the figures, the speeds and a short way of going (直连, 中继) never are.
#callsite(autofill(loc))
pub fn station_net_line_node(parent : @view.View, net : () -> Json?, look? : NetLook = Card, loc~ : SourceLoc) -> Unit {
  if look is Page {
    return net_page_line(parent, net, loc~)
  }
  let n = fn() {
    match net() {
      Some(_) as x => x
      None => Some(station_net_sample)
    }
  }
  let has = fn(key : String) { net_field(n(), key) is Some(Object(_)) }
  // (each look's words: plain, cut short where the line is, a figure by its level, a speed)
  let words = fn(p : @view.View, said : () -> String) {
    match look {
      Peek => net_peek_words(p, said, fn() { theme().p.muted })
      _ => words_node(p, said, fn() { net_card_words }) |> ignore
    }
  }
  // (how it is reached long: it is what is cut short, its round trip's words kept; else those words, it kept. Worked
  // out once of it, told only as it comes out otherwise: its figures and speeds changing run nothing of how it is cut)
  let long_now = @signals.computed(fn(_) { net_path_long(net_text(n(), "path")) })
  let long_path = fn() { long_now.get() }
  let short_path = fn() { !long_path() }
  let words_cut = fn(p : @view.View, said : () -> String, cut : () -> Bool) {
    match look {
      Peek => net_peek_words(p, said, fn() { theme().p.muted }, cut~)
      _ => net_words_cut_by(p, said, fn() { net_card_words }, cut)
    }
  }
  let figure = fn(p : @view.View, key : String) {
    match look {
      Peek =>
        net_peek_words(
          p,
          fn() { net_text(net_field(n(), key), "text") },
          fn() {
            let t = theme()
            match net_text(net_field(n(), key), "level") {
              "red" => t.p.red
              "amber" => t.p.warn_ink
              _ => t.p.text
            }
          },
          weight=500,
        )
      _ => level_figure_node(p, fn() { net_field(n(), key) }) |> ignore
    }
  }
  let speed = fn(p : @view.View, key : String) {
    match look {
      Peek => net_peek_words(p, fn() { net_text(n(), key) }, fn() { theme().p.text }, weight=500)
      _ => words_node(p, fn() { net_text(n(), key) }, fn() { net_card_figure }) |> ignore
    }
  }
  parent.box(made_for=loc, fn(row) {
    style_node(row, fn() { net_row })
    row.wraps(Is(Some(net_lines))) |> ignore
    row.box(fn(left) {
      style_node(left, fn() { net_left }, in_row=true)
      left.box(fn(l) {
        style_node(l, fn() { if long_path() { net_path_cut } else { net_path } }, in_row=true)
        words_cut(l, fn() { net_text(n(), "path") }, long_path)
        l.show(fn() { has("loss") }, fn(x) { figure(x, "loss") })
      })
      |> ignore
      left.show(fn() { has("rtt") }, fn(x) {
        style_node(x, fn() { if long_path() { net_way } else { net_rtt } }, in_row=true)
        words(x, fn() { "·" })
        words_cut(x, fn() { t("android-settings.stations.rtt") }, short_path)
        figure(x, "rtt")
      })
    })
    |> ignore
    row.box(fn(right) {
      style_node(right, fn() { net_right }, in_row=true)
      right.wraps(Is(Some(net_lines))) |> ignore
      for way in [("↑", "up"), ("↓", "down")] {
        right.box(fn(l) {
          style_node(l, fn() { net_way }, in_row=true)
          words(l, fn() { way.0 })
          speed(l, way.1)
        })
        |> ignore
      }
    })
    |> ignore
  })
  |> ignore
}

///|
/// The network line as a station's own page draws it (station_net_line_node's `Page`), as `net` says it now: how it
/// goes and packets lost, then `·` and its round trip said in the words around it (`当前延迟 {latency}`), the speeds
/// beside them, under them where the line has not the room; cut short as the other looks are (how it goes where that is
/// long, else the words around its round trip). Shown only once `net` says one (no made-up one).
fn net_page_line(parent : @view.View, net : () -> Json?, loc~ : SourceLoc) -> Unit {
  let has = fn(key : String) { net_field(net(), key) is Some(Object(_)) }
  // (worked out once of how it goes, told only as it comes out otherwise, as station_net_line_node's)
  let long_now = @signals.computed(fn(_) { net_path_long(net_text(net(), "path")) })
  let long_path = fn() { long_now.get() }
  let short_path = fn() { !long_path() }
  parent.box(made_for=loc, fn(r) {
    style_node(r, fn() { net_page_row })
    r.wraps(Is(Some(net_page_lines))) |> ignore
    r.box(fn(part) {
      style_node(part, fn() { net_left }, in_row=true)
      part.box(fn(l) {
        style_node(l, fn() { if long_path() { net_page_cut_box } else { net_page_line_box } }, in_row=true)
        net_words_cut_by(l, fn() { net_text(net(), "path") }, fn() { net_page_words }, long_path)
        l.show(fn() { has("loss") }, fn(f) {
          level_figure_node(f, fn() { net_field(net(), "loss") }, style=fn() { net_page_figure }) |> ignore
        })
      })
      |> ignore
      part.show(fn() { has("rtt") }, fn(x) {
        style_node(x, fn() { if long_path() { net_page_line_box } else { net_page_cut_box } }, in_row=true)
        words_node(x, fn() { "·" }, fn() { net_page_words }) |> ignore
        let parts = fn() {
          let words = t("web-pages.stations.latency", args=[("latency", "\u{0}")])
          words.split("\u{0}").map(fn(p) { p.to_owned() }).collect()
        }
        net_words_cut_by(x, fn() { parts().get(0).unwrap_or("") }, fn() { net_page_words }, short_path)
        level_figure_node(x, fn() { net_field(net(), "rtt") }, style=fn() { net_page_figure }) |> ignore
        net_words_cut_by(x, fn() { parts().get(1).unwrap_or("") }, fn() { net_page_words }, short_path)
      })
    })
    |> ignore
    r.box(fn(rates) {
      style_node(rates, fn() { net_right }, in_row=true)
      rates.wraps(Is(Some(net_page_lines))) |> ignore
      for way in [("↑", "up"), ("↓", "down")] {
        rates.box(fn(l) {
          style_node(l, fn() { net_page_rate }, in_row=true)
          words_node(l, fn() { way.0 }, fn() { net_page_words }) |> ignore
          words_node(l, fn() { net_text(net(), way.1) }, fn() { net_page_figure }) |> ignore
        })
        |> ignore
      }
    })
    |> ignore
  })
  |> ignore
}

///|
/// Words of a peek's line in `p`: the meta's size on a line of 18, `weight`, in `ink`; while `cut` says so, cut short
/// where the line has not the room for them (net_cut_by's).
#callsite(autofill(loc))
fn net_peek_words(
  p : @view.View,
  words : () -> String,
  ink : () -> Int64,
  weight? : Int = 400,
  cut? : () -> Bool = fn() { false },
  loc~ : SourceLoc,
) -> Unit {
  p.box(made_for=loc, fn(w) {
    net_cut_by(w, cut)
    w
    .words(By(words))
    .words_look(By(fn() { { size: theme().t.meta, weight, line: net_peek_line, wrap: false, tracking: @view.letters_own, balance: false, max_lines: 0 } }))
    .ink(By(ink))
    |> ignore
  })
  |> ignore
}

///|
/// Words of `style` (not cut short itself) in a node of `p`'s, cut short where the line has not the room while `cut`
/// says so (net_cut_by's).
#callsite(autofill(loc))
fn net_words_cut_by(
  p : @view.View,
  words : () -> String,
  style : () -> @ui.TextStyle,
  cut : () -> Bool,
  loc~ : SourceLoc,
) -> Unit {
  p.box(made_for=loc, fn(w) {
    styled_words(w, words, style) |> ignore
    net_cut_by(w, cut)
  })
  |> ignore
}

///|
/// Words' node `w` cut short along its row where it has not the room, saying they may end in an ellipsis, while `cut`
/// says so (styled_words' `w=Cut`, as it changes); kept whole else.
fn net_cut_by(w : @view.View, cut : () -> Bool) -> Unit {
  w
  .cuts(By(cut))
  .min_width(By(fn() { if cut() { Some(0.0) } else { None } }))
  .allow_ellipsis(By(cut))
  |> ignore
}

///|
/// Whether how a station is reached is long (more than net_path_kept letters: a relay of the workspace's own, named by
/// its address), so cut short where the line has not the room, rather than what its round trip is called.
fn net_path_long(path : String) -> Bool {
  path.length() > net_path_kept
}

///|
/// The most letters of a way of going kept whole on a line short of room (直连, 中继, 深圳中继, Direct, Relay).
let net_path_kept : Int = 6

///|
/// A card of a list of machines in `parent` (a station, one that only runs tasks, a device), pressed open (`press`):
/// `mark` in a square of summary_mark_side before its name on its first line (the line as high as the square), a tag
/// after the name where `tag` says one (the tag keeps its words, the name gives way), what stands at its `end` and a
/// chevron at that line's end, each across that line's middle; what is said of it (`said`) under the name from where
/// the name starts; `body` under it all, on the card, 10 apart.
#callsite(autofill(loc))
pub fn summary_mark_card_node(
  parent : @view.View,
  mark : (@view.View) -> Unit,
  name : () -> String,
  said : () -> String,
  press : () -> Unit,
  end? : (@view.View) -> Unit,
  body? : (@view.View) -> Unit,
  tag? : () -> String = fn() { "" },
  loc~ : SourceLoc,
) -> Unit {
  // (a page's card, laid out by the page's arrangement, pressed whole: what it holds in one column of its own)
  page_card_node(loc~, parent, fn(card) {
    rippled_node(card, press, card_corner, name)
    card.box(fn(col) {
      // (its head, then what is under it, 10 apart)
      style_node(col, fn() { summary_col })
      // (its head: its mark, its name, what stands at its end and its chevron on its first line, each across that
      // line's middle, never across the lines under it; what is said of it under the name from where the name starts:
      // after a room as wide as the mark's square, whatever size that is drawn at)
      col.box(fn(top) {
        // (its lines 2 apart: a tag's ground after its name does not meet the line under it)
        style_node(top, fn() { summary_top })
        top.box(fn(head) {
          style_node(head, fn() { summary_head })
          head.box(fn(m) {
            style_node(m, fn() { summary_mark_box }, in_row=true)
            mark(m)
          })
          |> ignore
          head.box(fn(n) {
            style_node(n, fn() { summary_name_row })
            n.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
            n.box(fn(w) {
              w.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
              words_node(w, name, fn() { summary_name }) |> ignore
            })
            |> ignore
            n.show(fn() { tag() != "" }, fn(x) { pill_node(x, tag) |> ignore })
          })
          |> ignore
          match end {
            Some(e) => e(head)
            None => ()
          }
          icon_node(head, "chevron-right", summary_chevron, By(fn() { theme().p.subtle })) |> ignore
        })
        |> ignore
        top.show(fn() { said() != "" }, fn(s) {
          style_node(s, fn() { summary_said_line })
          s.box(fn(m) { style_node(m, fn() { summary_mark_room }, in_row=true) }) |> ignore
          words_node(s, said, fn() { summary_said }).grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
        })
      })
      |> ignore
      match body {
        Some(f) => f(col)
        None => ()
      }
    })
    |> ignore
  })
}

///|
/// The text of `key` in `v` ("" where it is none or not a string).
fn net_text(v : Json?, key : String) -> String {
  match net_field(v, key) {
    Some(String(s)) => s
    _ => ""
  }
}

///|
/// What `v` holds at `key`, where it is an object holding one.
fn net_field(v : Json?, key : String) -> Json? {
  match v {
    Some(Object(o)) => o.get(key)
    _ => None
  }
}

// ── styles ─────────────────────────────────────────

///|
/// A mark's side on a machine's card (summary_mark_card_node's square holds it).
pub let summary_mark_side : Double = 28.0

///|
let summary_chevron : Double = 14.0

///|
/// The network line: the left and the speeds, 10 apart, in their middle; 2 between its lines where it takes two.
// kept across runs: a value (no field of it changes)
let net_row : @ui.Style = @ui.css("row w=Full gap=S2_5 align=ACenter justify=JBetween")

///|
let net_lines : Double = 2.0

///|
/// How it goes and its round trip, 6 apart, cut short as a whole where the line is.
// kept across runs: a value (no field of it changes)
let net_left : @ui.Style = @ui.css("row w=Cut gap=S1_5 align=ACenter")

///|
/// How it goes and packets lost, 6 apart.
// kept across runs: a value (no field of it changes)
let net_path : @ui.Style = @ui.css("row gap=S1_5 align=ACenter")

///|
/// How it goes long and packets lost, 6 apart, cut short where the line is.
// kept across runs: a value (no field of it changes)
let net_path_cut : @ui.Style = @ui.css("row w=Cut gap=S1_5 align=ACenter")

///|
/// Its round trip: 4 apart, cut short where the line is.
// kept across runs: a value (no field of it changes)
let net_rtt : @ui.Style = @ui.css("row w=Cut gap=S1 align=ACenter")

///|
/// ↑ and ↓ side by side, 10 apart.
// kept across runs: a value (no field of it changes)
let net_right : @ui.Style = @ui.css("row gap=S2_5 align=ACenter")

///|
/// Each way's speed (and the round trip beside a long way of going): 4 apart.
// kept across runs: a value (no field of it changes)
let net_way : @ui.Style = @ui.css("row gap=S1 align=ACenter")

///|
/// A peek's lines' height (18).
let net_peek_line : Double = 18.0

///|
// kept across runs: a value (no field of it changes)
let net_card_words : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, wrap=false)

///|
/// A card's figure: in the words' ink, as heavy as a medium.
// kept across runs: a value (no field of it changes)
let net_card_figure : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, weight=Medium, color=Fg, wrap=false)

///|
/// A page's line: the left and the speeds, 8 apart, in their middle; 8 between its lines where it takes two.
// kept across runs: a value (no field of it changes)
let net_page_row : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter justify=JBetween")

///|
let net_page_lines : Double = 8.0

///|
/// A page's how it goes and packets lost, and its round trip, each 4 apart.
// kept across runs: a value (no field of it changes)
let net_page_line_box : @ui.Style = @ui.css("row gap=S1 align=ACenter")

///|
/// A page's how it goes long and packets lost, or its round trip: 4 apart, cut short where the line is.
// kept across runs: a value (no field of it changes)
let net_page_cut_box : @ui.Style = @ui.css("row w=Cut gap=S1 align=ACenter")

///|
/// A page's each way's speed: at least 64 wide, 4 apart.
// kept across runs: a value (no field of it changes)
let net_page_rate : @ui.Style = @ui.css("row min_w=S16 gap=S1 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let net_page_words : @ui.TextStyle = @ui.text_style(size=Meta, leading=L6, color=Muted, wrap=false)


///|
/// A page's figure: the ui's size, as heavy as a medium, in the words' ink.
// kept across runs: a value (no field of it changes)
let net_page_figure : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, weight=Medium, color=Fg, wrap=false)

///|
/// A card's first line: its mark, its name, what stands at its end, 12 apart across the line's middle, as high as its
/// mark (the name's line in its middle with it).
// kept across runs: a value (no field of it changes)
let summary_head : @ui.Style = @ui.css("row w=Full gap=S3 align=ACenter min_h=S7")

///|
/// A card's head and what is said under it, 2 apart.
// kept across runs: a value (no field of it changes)
let summary_top : @ui.Style = @ui.css("w=Full gap=S0_5")

///|
/// A card's name and the tag after it, on its one line, 8 apart.
// kept across runs: a value (no field of it changes)
let summary_name_row : @ui.Style = @ui.css("row gap=S2 align=ACenter")

///|
/// What is said of it under its name: after a room as wide as the mark's square and the 12 after it, from where the
/// name starts.
// kept across runs: a value (no field of it changes)
let summary_said_line : @ui.Style = @ui.css("row w=Full gap=S3")

///|
/// The mark's square's width alone (summary_mark_box's), the room before what is said under the name.
// kept across runs: a value (no field of it changes)
let summary_mark_room : @ui.Style = @ui.css("w=S7")

///|
/// The mark's square: as large whatever it is (an emoji is drawn wider than an icon), the names lined up.
// kept across runs: a value (no field of it changes)
let summary_mark_box : @ui.Style = @ui.css("w=S7 h=S7 align=ACenter justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
let summary_name : @ui.TextStyle = @ui.text_style(size=Title, weight=Bold, color=Fg, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let summary_said : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, w=Full)

///|
/// What a card holds: its head, what the page puts under it, its body, 10 apart.
// kept across runs: a value (no field of it changes)
let summary_col : @ui.Style = @ui.css("w=Full gap=S2_5")
