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
/// files kept by the chat's sessions; a chat's title pressed opened as a link in it is. Its tips in `tips`.
fn letters_tab_node(v : @view.View, src : Source, r : ChatRef, thread : Double, view : () -> ChatView, tips : @sf.TipLayer) -> Unit {
  let key = chat_key(r)
  let value = fn() { src.topic("chatLetters", { "station": Json::string(r.station), "thread": Json::number(thread) }).get().value }
  v.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
  v.pick(fn() { letters_state(value()) }, fn(p, state) {
    p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
    match state {
      LettersWaiting =>
        @sf.waiting_node(
          p,
          fn(w) {
            w.box(fn(l) {
              @sf.style_node(l, fn() { letters_list })
              for ch in letters_sample() {
                letters_chat_node(l, fn() { Some(ch) }, fn() {  })
              }
            })
            |> ignore
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
          letters_list_node(q, src, r, view, tips, value, chats, chat_of, at)
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
) -> Unit {
  let key = chat_key(r)
  let letters = fn() { items(chat_of(at), "letters") }
  // (what its notices keep while it shows: which are open, when each said 已复制)
  let opened : @sf.LiveMap[String, Bool] = @sf.LiveMap::new()
  let copied : @sf.LiveMap[String, Double] = @sf.LiveMap::new()
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
    }
    b.scrolls_window(
      @view.Scroll::list(),
      fn() {
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
      },
      fn(row, k) {
        match k {
          LettersChat(ck) => {
            // (the list's sides: 8 (lettersList's); 6 over its first, 2 apart)
            @sf.style_node(row, fn() { letters_row_room })
            letters_chat_node(row, fn() { chat_of(ck) }, fn() { letters_opened.set(key, ck) })
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
/// last letter in brief under them; the pointer's ground on it; pressed, `press` (opened in the tab).
fn letters_chat_node(row : @view.View, chat : () -> Json?, press : () -> Unit) -> Unit {
  row.box(fn(b) {
    @sf.style_node(b, fn() { letters_row })
    b
    .ground(By(fn() { if @sf.lit_node(b) { @ui.tree_theme().color(Hover) } else { 0L } }))
    .says(By(fn() { Some(@view.said(Button, label=text(chat(), "title"))) }))
    |> ignore
    @sf.presses_node(b, press)
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
/// opens that chat as a link where it is one (underlined under the hand).
fn letters_head_node(row : @view.View, chat : () -> Json?, tips : @sf.TipLayer, back : () -> Unit) -> Unit {
  @sf.style_node(row, fn() { letters_head })
  @sf.icon_button_node(row, "arrow-left", fn() { @sf.t("web-main.letters.back") }, back, tips~) |> ignore
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
