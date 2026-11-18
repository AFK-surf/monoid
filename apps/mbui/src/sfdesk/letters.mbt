// What a chat's agents and other chats' agents wrote each other (session_send), in a tab beside the chat on 中屏 and
// 大屏 (still.fail web/src/Letters.tsx, Letters.css.ts; the core's `chatLetters` view), made once as nodes of the
// window's tree as the tab comes in front (panel_node.mbt side_panel_node, tape_view.mbt tape_side_node): first the
// chats it wrote with, a row each, the last written with first; one opened, its letters both ways in the order written,
// each drawn as the chat draws a message out of its list (sfpages' message_static_node), all of it a page's list
// (View::scrolls_window) made again as another is opened or the list is gone back to.

///|
/// The chat opened in each chat's letters (by the chat's key; none: the list), what the tab's nodes read.
let letters_opened : @sf.LiveMap[String, String] = @sf.LiveMap::new()

///|
fn letters_reset() -> Unit {
  letters_opened.clear()
}

///|
/// Chat `r`'s letters' tab at its list.
pub fn letters_to_list(r : ChatRef) -> Unit {
  letters_opened.remove(chat_key(r))
}

///|
/// Chat `r`'s letters at the chat written with by `key` (its row pressed).
pub fn letters_open_at(r : ChatRef, key : String) -> Unit {
  letters_opened.set(chat_key(r), key)
}

///|
/// Chats that wrote each other, made up, for what the tab shows while they are read (its list in its bones).
fn letters_sample() -> Array[Json] {
  [(8, 18), (6, 22), (10, 14), (7, 20)].mapi(fn(i, n) {
    Json::object({
      "key": Json::string("sample" + i.to_string()),
      "title": Json::string(@sf.sample_words(n.0)),
      "last": Json::string(@sf.sample_words(n.1)),
      "time": { "lastActiveAt": { "ago": Json::string(@sf.sample_words(3)) } },
    })
  })
}

///|
/// What chat `r`'s letters' tab shows as the core's `chatLetters` has them (`v`): its bones while they are read (or
/// while it has none and more may come), words saying it has none once all is read, else its chats.
#derive(Eq)
priv enum LettersState {
  LettersWaiting
  LettersNone
  LettersShown
}

///|
fn letters_state(v : Json?) -> LettersState {
  let chats = items(v, "chats")
  if !(v is Some(Object(_))) || (chats.length() == 0 && !flag(v, "whole")) {
    LettersWaiting
  } else if chats.length() == 0 {
    LettersNone
  } else {
    LettersShown
  }
}

///|
/// One of the rows of a chat's letters: a chat it wrote with (by its key), the head of the one opened, one of its
/// letters (by its place among them), more to come.
#derive(Eq, Hash)
priv enum LettersRow {
  LettersChat(String)
  LettersHead
  LettersOne(Int)
  LettersMore
}

///|
/// Chat `r`'s letters (its thread `thread`) in `v` (as large as the panel leaves it under its bar), the chat as its view
/// says it now (`view`): its list, or the chat opened in it, its letters each drawn as the chat draws a message, their
/// files kept by the chat's sessions; a chat's title pressed opened as a link in it is. Its tips in `tips`. The same in
/// the letters' sheet over the chat (sfapp's letters_node), `panel`: in a panel's body, its rows reaching across it and
/// their words on its words' line, its list the panel's (@sf.panel_list_node).
pub fn letters_tab_node(
  v : @view.View,
  src : Source,
  r : ChatRef,
  thread : Double,
  view : () -> ChatView,
  tips : @sf.TipLayer,
  panel? : Bool = false,
) -> Unit {
  let key = chat_key(r)
  let value = fn() { src.topic("chatLetters", { "station": Json::string(r.station), "thread": Json::number(thread) }).get().value }
  v.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
  // (in a panel: told at last, a chat come or gone, one opened or back to the list: what it holds another height for
  // that cause, the sheet going on from as tall as it is seen then, @sf.panel_reshaped_node; made before what it shows,
  // so it is said before that is made anew)
  if panel {
    v.reacts(at_start=false, fn() { (letters_state(value()), items(value(), "chats").length(), letters_opened.get(key)) }, fn(_) {
      @sf.panel_reshaped_node(v)
    })
    |> ignore
  }
  v.pick(fn() { letters_state(value()) }, fn(p, state) {
    p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
    match state {
      LettersWaiting =>
        @sf.waiting_node(
          p,
          fn(w) {
            w.box(fn(l) {
              @sf.style_node(l, fn() { if panel { letters_list_panel } else { letters_list } })
              l.each(letters_sample, fn(ch) { text(Some(ch), "key") }, at_once=true, fn(row, ch) {
                letters_chat_node(row, fn() { Some(ch.get()) }, fn() {  }, panel~)
              })
            })
            |> ignore
            // (room under the last of them in a dialog in the middle of the window, as under the chats' list there)
            if panel {
              w.box(fn(f) { f.height(By(fn() { Some(if @sf.in_dialog_node(f) { letters_foot_h } else { 0.0 }) })) |> ignore })
              |> ignore
            }
          },
          fill=true,
        )
      LettersNone =>
        @sf.empty_node(p, fn(e) { @sf.words_node(e, fn() { @sf.t("web-main.letters.none") }, fn() { letters_none }) |> ignore })
      LettersShown => {
        let chats = fn() { items(value(), "chats") }
        let chat_of = fn(k : String) { chats().iter().find_first(fn(ch) { text(Some(ch), "key") == k }) }
        // (the chat opened, where it is one of them: "" the list)
        let opened = @signals.computed(
          fn(_) {
            match letters_opened.get(key) {
              Some(k) if chat_of(k) is Some(_) => k
              _ => ""
            }
          },
          same=fn(a, b) { a == b },
        )
        // (another opened, or back to the list: a list of its own, from its top)
        p.pick(fn() { opened.get() }, fn(q, at) {
          q.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
          letters_list_node(q, src, r, view, tips, value, chats, chat_of, at, panel)
        })
      }
    }
  })
}

///|
/// Chat `r`'s letters' list in `q` (letters_tab_node's), `at` the chat opened ("" none): the chats it wrote with, or
/// that one's head and its letters; more to come at its foot while not all of it is read. Laid out by the room it is
/// given (its letters' width).
fn letters_list_node(
  q : @view.View,
  src : Source,
  r : ChatRef,
  view : () -> ChatView,
  tips : @sf.TipLayer,
  value : () -> Json?,
  chats : () -> Array[Json],
  chat_of : (String) -> Json?,
  at : String,
  panel : Bool,
) -> Unit {
  let key = chat_key(r)
  let letters = fn() { items(chat_of(at), "letters") }
  // (what its notices keep while it shows: which are open, when each said 已复制)
  let opened : @sf.LiveMap[String, Bool] = @sf.LiveMap::new()
  let copied : @sf.LiveMap[String, Double] = @sf.LiveMap::new()
  let keys = fn() {
    let out : Array[LettersRow] = []
    if at == "" {
      for ch in chats() {
        out.push(LettersChat(text(Some(ch), "key")))
      }
    } else {
      out.push(LettersHead)
      for i in 0..<letters().length() {
        out.push(LettersOne(i))
      }
    }
    // not all of the chat is here yet: more may come, older ones
    if !flag(value(), "whole") {
      out.push(LettersMore)
    }
    out
  }
  if panel {
    // (in a panel's body: its list the panel's, its rows' words on the panel's words' line)
    q.by_room(fn(b, given) {
      let side = @sf.panel_words_at_node(b)
      let here : @sfpages.MessageNodeHere = {
        station: r.station,
        session: r.session,
        view,
        width: fn() { dmax(0.0, given.width() - 2.0 * side) },
        tips,
        stint: fn() { 0 },
        jump: None,
        picture: None,
      }
      @sf.panel_list_node(
        b,
        keys,
        fn(row, k) {
          match k {
            LettersChat(ck) => letters_chat_node(row, fn() { chat_of(ck) }, fn() { letters_opened.set(key, ck) }, panel=true)
            LettersHead => letters_head_node(row, fn() { chat_of(at) }, tips, fn() { letters_opened.remove(key) }, panel=true)
            LettersOne(i) =>
              match @signals.untracked(letters).get(i) {
                Some(m) =>
                  row.box(fn(s) {
                    @sf.style_node(s, fn() { letters_message_panel.then(@sf.panel_words_in_node(s)) })
                    @sfpages.message_static_node(s, src, here, "letters/" + at + "/" + i.to_string(), message_of(m), opened, copied)
                  })
                  |> ignore
                None => ()
              }
            LettersMore => {
              @sf.style_node(row, fn() { letters_more })
              @sf.spinner_node(row, size=letters_more_spin) |> ignore
            }
          }
        },
        est=letters_row_est,
      )
      |> ignore
      // (room under the last of the chats in a dialog in the middle of the window: their grounds out of the corners of
      // its foot; none at a sheet's, whose foot goes on past the window's)
      if at == "" {
        b.box(fn(f) { f.height(By(fn() { Some(if @sf.in_dialog_node(f) { letters_foot_h } else { 0.0 }) })) |> ignore }) |> ignore
      }
    })
    |> ignore
    return
  }
  q.by_room(fn(b, given) {
    b.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
    let here : @sfpages.MessageNodeHere = {
      station: r.station,
      session: r.session,
      view,
      width: fn() { dmax(0.0, given.width() - 2.0 * letters_message_side) },
      tips,
      stint: fn() { 0 },
      jump: None,
      picture: None,
    }
    // (a chat's row taken by the next chat to show as it no more does, its key that one's; the head, a letter (made
    // with what it says once) and the spinner made each for its key)
    b.scrolls_reused(
      @view.Scroll::list(),
      keys,
      reuses=fn(k) { k is LettersChat(_) },
      fn(row, key_now) {
        // (its make, which never changes for a block: a chat's row alone is taken for another key, `reuses`')
        match @signals.untracked(key_now) {
          LettersChat(_) => {
            let ck = fn() {
              match key_now() {
                LettersChat(ck) => ck
                _ => ""
              }
            }
            // (the list's sides: 8 (lettersList's); 6 over its first, 2 apart)
            @sf.style_node(row, fn() { letters_row_room })
            letters_chat_node(row, fn() { chat_of(ck()) }, fn() { letters_opened.set(key, ck()) })
          }
          LettersHead => letters_head_node(row, fn() { chat_of(at) }, tips, fn() { letters_opened.remove(key) })
          LettersOne(i) =>
            match @signals.untracked(letters).get(i) {
              Some(m) =>
                row.box(fn(s) {
                  @sf.style_node(s, fn() { letters_message })
                  @sfpages.message_static_node(s, src, here, "letters/" + at + "/" + i.to_string(), message_of(m), opened, copied)
                })
                |> ignore
              None => ()
            }
          LettersMore => {
            @sf.style_node(row, fn() { letters_more })
            @sf.spinner_node(row, size=letters_more_spin) |> ignore
          }
        }
      },
      est=letters_row_est,
      slop=@ui.touch_slop(),
      bar=@ui.tree_scroll_bar(),
      // (the list of chats 6 over its first, 16 under its last (lettersList); one opened, 24 under its last letter)
      head=fn(h) { h.height(Is(Some(if at == "" { letters_list_over } else { 0.0 }))) |> ignore },
      foot=fn(f) { f.height(Is(Some(if at == "" { letters_list_under } else { letters_foot_h }))) |> ignore },
    )
    |> ignore
  })
  .grow(Is(1.0))
  .min_height(Is(Some(0.0)))
  |> ignore
}

///|
/// A chat it wrote with (lettersRow) in `row`, `chat` as it is now: its title, how many letters and when on a line, the
/// last letter in brief under them; the pointer's ground on it; pressed, `press` (opened in the tab). `panel`: in a
/// panel's body, its words on its words' line, its ground a panel's row's (panel_row_in_node: round where it stands in
/// from the panel's sides, square across a sheet).
fn letters_chat_node(row : @view.View, chat : () -> Json?, press : () -> Unit, panel? : Bool = false) -> Unit {
  @sf.action_box_node(row, fn() { text(chat(), "title") }, fn(_) { press() }, fn(b) {
    @sf.style_node(b, fn() { if panel { letters_row_panel.then(@sf.panel_row_in_node(b)) } else { letters_row } })
    @sf.hover_ground_node(b)
    b.box(fn(h) {
      @sf.style_node(h, fn() { letters_row_head })
      h.box(fn(g) {
        @sf.style_node(g, fn() { letters_grow }, in_row=true)
        @sf.words_node(g, fn() { text(chat(), "title") }, fn() { letters_row_title }).allow_ellipsis(Is(true)) |> ignore
      })
      |> ignore
      @sf.words_node(h, fn() {
        let cv = chat()
        let n = @sf.t("web-main.letters.count", args=[("n", items(cv, "letters").length().to_string())])
        let ago = text(field(field(cv, "time"), "lastActiveAt"), "ago")
        if ago == "" {
          n
        } else {
          n + " · " + ago
        }
      }, fn() { letters_row_meta })
      .shrink(Is(0.0))
      |> ignore
    })
    |> ignore
    @sf.words_node(b, fn() { text(chat(), "last") }, fn() { letters_row_last }).allow_ellipsis(Is(true)) |> ignore
  })
  |> ignore
}

///|
/// The chat opened's head (lettersHead) in `row`, `chat` as it is now: back to the list (`back`), and its title, which
/// opens that chat as a link where it is one (underlined under the hand); `panel`: in a panel's body, on its words'
/// line.
fn letters_head_node(row : @view.View, chat : () -> Json?, tips : @sf.TipLayer, back : () -> Unit, panel? : Bool = false) -> Unit {
  @sf.style_node(row, fn() {
    if panel {
      // (in a panel's body: under its title as the sheet's had it, its back's mark on the panel's words' line, its
      // title's end on it too)
      let w = @sf.panel_words_at_node(row)
      let start = dmax(0.0, w - letters_back_in)
      letters_head_panel.then(@ui.style(pl=@sf.room_of(start), pr=@sf.room_of(w)))
    } else {
      letters_head
    }
  })
  // (in a panel's body the sheet's back, a chevron: a step back in it; beside the chat, an arrow)
  @sf.icon_button_node(row, if panel { "chevron-left" } else { "arrow-left" }, fn() { @sf.t("web-main.letters.back") }, back, tips~)
  |> ignore
  row.pick(fn() { text(chat(), "link") != "" }, fn(p, links) {
    p.row(Is(true)).grow(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
    if links {
      p.box(fn(n) {
        @sf.style_node(n, fn() { letters_name_box }, in_row=true)
        n.says(By(fn() { Some(@view.said(Link, label=text(chat(), "title"))) })) |> ignore
        @sf.presses_node(n, fn() { open_link(text(@signals.untracked(chat), "link")) })
        n.box(fn(w) {
          w
          .words_runs(By(fn() { [@ui.span(text(chat(), "title"), underline=@sf.lit_node(n))] }))
          .words_look(By(fn() { @ui.style_words(letters_name) }))
          .ink(By(fn() { @ui.style_ink(letters_name) }))
          .allow_ellipsis(Is(true))
          |> ignore
        })
        |> ignore
      })
      |> ignore
    } else {
      @sf.words_node(p, fn() { text(chat(), "title") }, fn() { letters_name }).allow_ellipsis(Is(true)) |> ignore
    }
  })
}

///|
/// The chats it wrote with (lettersList): 6 over, 8 at the sides, 16 under, 2 apart (its rows' room: letters_row_room,
/// letters_list_over, letters_list_under).
// kept across runs: a value (no field of it changes)
let letters_list : @ui.Style = @ui.css("w=Full pt=S1_5 px=S2 pb=S4 gap=S0_5")

///|
// kept across runs: a value (no field of it changes)
let letters_row_room : @ui.Style = @ui.css("w=Full px=S2 pb=S0_5")

///|
let letters_list_over : Double = 6.0

///|
let letters_list_under : Double = 14.0

///|
/// A chat it wrote with (lettersRow): 8 by 12 in, round as an option, the pointer's ground on it; its title (13 in
/// 500 on 20) and how many and when (12, muted) on a line, the last letter in brief under them (12, muted).
// kept across runs: a value (no field of it changes)
let letters_row : @ui.Style = @ui.css("w=Full py=S2 px=S3 gap=S0_5 radius=Xl")

///|
/// The same in a panel's body: across it, 10 over and under (the letters' sheet's), its words on its words' line.
// kept across runs: a value (no field of it changes)
let letters_row_panel : @ui.Style = @ui.css("w=Full py=S2_5 gap=S0_5")

///|
/// Its bones in a panel's body: 6 over, 16 under, its rows across it.
// kept across runs: a value (no field of it changes)
let letters_list_panel : @ui.Style = @ui.css("w=Full pt=S1_5 pb=S4")

///|
/// In a panel's body, one opened's head: 10 under it, back and its title 4 apart, on their middle; a letter 4 over, 16
/// under (the letters' sheet's).
// kept across runs: a value (no field of it changes)
let letters_head_panel : @ui.Style = @ui.css("row w=Full pb=S2_5 gap=S1 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let letters_message_panel : @ui.Style = @ui.css("w=Full pt=S1 pb=S4")

///|
/// How far its back's mark is in from its round ground's start: on the panel's words' line in a panel's body.
let letters_back_in : Double = 10.0

///|
// kept across runs: a value (no field of it changes)
let letters_row_head : @ui.Style = @ui.css("row w=Full gap=S2 align=AEnd")

///|
// kept across runs: a value (no field of it changes)
let letters_grow : @ui.Style = @ui.style(w=@sf.grow)

///|
// kept across runs: a value (no field of it changes)
let letters_row_title : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Fg, leading=L6, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let letters_row_meta : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let letters_row_last : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false, w=Full)

///|
/// One opened (lettersHead): back and its title 4 apart, 6 over and under, 6 in at its start, 12 at its end; its title
/// 13 in 500, underlined on hover where it opens that chat.
// kept across runs: a value (no field of it changes)
let letters_head : @ui.Style = @ui.css("row w=Full py=S1_5 pl=S1_5 pr=S3 gap=S1 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let letters_name_box : @ui.Style = @ui.style(row=true, w=@sf.grow, clip=true)

///|
// kept across runs: a value (no field of it changes)
let letters_name : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Fg, wrap=false)

///|
/// Its letters (lettersMessages): 20 apart, 10 over, 16 at the sides (letters_message_side), 24 under the last
/// (letters_foot_h).
// kept across runs: a value (no field of it changes)
let letters_message : @ui.Style = @ui.css("w=Full pt=S2_5 px=S4 pb=S2_5")

///|
let letters_message_side : Double = 16.0

///|
let letters_foot_h : Double = 24.0

///|
/// More to come (lettersMore): a spinner in the middle, 4 over and under.
// kept across runs: a value (no field of it changes)
let letters_more : @ui.Style = @ui.css("row w=Full py=S1 justify=JCenter")

///|
let letters_more_spin : Double = 14.0

///|
/// How tall a row of the list is taken to be till it is laid out.
let letters_row_est : Double = 60.0

///|
// kept across runs: a value (no field of it changes)
let letters_none : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted)
