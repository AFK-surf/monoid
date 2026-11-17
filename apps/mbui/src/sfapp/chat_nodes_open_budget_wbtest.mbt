// A chat of real size on the chat's page made as nodes (实验性功能's 试用新对话页), as a phone's core sends it (its messages
// read as Markdown, `md`, each long one a block a piece; src/sfrealsize): what the heaviest frame does as it opens cold,
// and as it is opened again from Home with the chat held (back, then the same chat: its messages there already, the
// page made whole in one frame) — nodes made, let go, laid out, words measured, bindings run — held to its bar, which
// only falls. Most of a chat's paragraphs have no link and a list's items no task: what would be made for those (their
// presses, their cards) is none of it. The real-size sweep (real_size_wbtest.mbt) opens the old page's chat; this is
// the new page's alone, never set beside the old.

///|
/// Each window's bars, "<window> cold" and "<window> again": made, let go, laid out, measured, bindings run, in the
/// heaviest frame (the most made); "<window> up frame": the most any one frame did of each (made, let go, laid out,
/// measured, each its own frame's) as the chat is scrolled up through its older messages, at every rate of frames;
/// "<window> up": all of them in every frame as the chat is scrolled up through its
/// older messages (chat_nodes_scrolled), each row made as it comes into view (its bindings run not held: as many as the
/// frames a rate draws: 1052 to 1072 wide at 7 to 120 a second, 2026-11-16). Counted 2026-11-16, once a paragraph's
/// links are made only as it has one (sf words_links_node: till then the room for their cards alone), a long message's
/// piece of one block its box alone and a row's sides its padding: before them 804, 365, 2591, 920 made and 810, 1185
/// made scrolling up. Again once a row's flash and its menu's band are its own ground, its line and middle one node, an
/// agent's own picture holds no place's corner and a chooser's menu is held in its layer only once it opens: before
/// that 797, 358, 2584, 913 and 750, 1094. Again once a table's cells are made with fewer nodes (its rules no structure,
/// no pick where it is not shown smaller), the same at 60, 120, 24 and 7: before that 688 and 783, 1003 and 816 made and
/// let go scrolling up. "phone cold" again once Home's bar, kept under the chat, held its 看板 key beside 筛选 (one
/// node, its icon turning with the mode, and the filter's and the stations' releases' keys no box of their own): before
/// it (782, 38, 885, 150, 778). Again once a paragraph with no link holds no room for its links' cards either (sf
/// words_links_node: nothing made for them till a link comes), the same at 60, 120, 24 and 7: before it 784, 343, 2569
/// and 898 made, 683 and 998 made scrolling up. Wide cold made 2 more (2568 before) once the sidebar's band and foot are
/// made as nodes (lists_band_node beside the system's bars too, lists_foot_node) and not hosted as old views: laid out
/// 11 fewer (3693) and bindings 2 (2752). "phone cold" made 5 more (783) and "phone again" 2 bindings more (299) once
/// Home's transfers key is made as nodes (sfdesk transfers_key_node), not hosted as an old view, at rest while a chat
/// covers Home: laid out 38 fewer (894), the same at 60, 120, 24 and 7.
let chat_nodes_open_budget : Map[String, (Int, Int, Int, Int, Int)] = {
  // (2026-11-17: the shells' two layers for the chat shared as a picture and a visualization over the whole screen made as
  // nodes, sfpages publish_layer_node and sfbase viz_full_layer_node: phone cold 788 made and 856 laid before it, wide
  // cold 2570 made and 2750 bindings)
  // (made 2 more, 795, and wide cold 1 more, 2573, 2026-11-17: each shell holds ⌘K's panel, and a phone's the search
  // over its page, as a closed `show` made as the shell is, sfdesk switcher_node and sfpages search_page_node)
  // (2026-11-17: the blocks of the messages read before the chat showed them put by as they leave what shows and taken
  // for the next of their make to come into it (sfpages chat_body_shape, View::scrolls_window's `reused`): before it
  // phone cold 791 and 38 let go, again 339 and 26, wide cold 2570, again 895 made; scrolling up phone 667 made, 760
  // let go, 644 laid, 90 measured, wide 973, 793, 966, 126; the most one frame of it did phone 146, 150, 126, 17 and
  // wide 150, 149, 134, 23, the same at 60, 120, 24 and 7. What one frame still makes scrolling up is the first of
  // each make to come before one of it has left, a long message's pieces most)
  // (again once Home's list's faces are fewer boxes, sfpages row_aside_node: the ground round them and who started it
  // ringed rings of the face's own; phone cold 779 made and 852 laid before, wide cold 2557 and 3674)
  // (2026-11-17: a table's cells measured by the tree's own measurer as they are drawn, mbui View::tracks, each counted
  // as a measure: before, @ui.text_advance measured them outside the tree, counted nowhere, the same work (instrbench's
  // chatreal: 3,328.9K a frame weighted before, 3,329.3K after). Scrolling up before it phone 84 measured, a frame 17,
  // wide 113 and 17. And a table in a block taken for another message's row made again for it, scrolled across as
  // that one's (sf md_block_node's pick: its node), phone up 565 made and a frame 141, wide up 698 before it; a Scroll
  // following that one's as it changes instead, its every read looked up, ran more (instrbench's table 1,743.3K a
  // frame weighted before, 1,762.0K with it, 1,744.0K with the node))
  // (2026-11-17: the first frame lays out and measures its words once, in the faces and lines they are drawn in, mbui
  // ui's on_frame and app_tree's app_looks_told, not in the system's and then all again: before it phone cold 830 laid,
  // 146 measured, 776 bindings, wide cold 3531, 557 and 2634, the same made)
  // (2026-11-17: a table in a block taken for another message's row the same nodes, scrolled across as that message has
  // it, what a code block or a formula keeps the same, mbui reused_state.mbt, sf md_block_node made again for none:
  // before it phone up 566 made, 618 laid and a frame 142, 126, wide up 699 and 910, the same at 60, 120, 24 and 7)
  // (2026-11-17: 小屏 Home's list no longer opens under what is left up long, moved into 待处理, so the rows of a screen
  // more are shown in its place: made with the chat's in its cold first frame, their bindings run again as the chat
  // opens again over Home; phone cold 750 made, 527 laid, 72 measured, 751 bindings before it, again 301 bindings, the
  // chat's own the same, at 60, 120, 24 and 7 too; again's others brought down to what is done now)
  // (bindings 1 more in each, 2026-11-17, once a message's picture is again the end that stays of its viewer's flight
  // (View::shared) in place of #6722's hand-made bridge (note_thumb_node): how the flight draws it there, covering its
  // box from where or contained, one binding (message_image_node); before it 942, 320, 2446, 1049)
  // (2026-11-17: a code block's keys over its top right with a mouse, no bar of their own over its code (the user:
  // 「hover 才显示，不占空间」): each block 38 lower, so scrolling up brings more of the chat into what shows; wide up 697,
  // 382, 909, 125 and a frame 137, 105, 130, 28 before it; with a spacer as tall as the bar in the keys' place a block
  // makes fewer nodes than it did)
  // (1 made more in each on a phone, 2026-11-17: the chat bar's 远程 key, made while it is closed)
  // (a node more made in each, 2026-11-17, its bindings 2 fewer: what lights a message whole the list's band, drawn
  // under all the rows of it once (View::scrolls_window's `bands`, its each's slot), no more each row's own ground; before
  // it 1014 and 943, 325 and 321)
  // (5 made, 4 laid, 1 measured and 9 bindings more in 大屏's again, 2026-11-17: the agent at work's 停止 chip before
  // 只看收发 in its history's head beside the chat; before it 881, 878, 122, 1048)
  // (2026-11-17, the chat's composer made as nodes (sfpages composer_node, in its list's foot: 试用新输入框, on here) and
  // not hosted as an old view: an old view's nodes are none of what is counted here, so what the composer makes (its
  // foot, box, rows, field, send, ＋ and the structures that come and go in it) is counted now where it was not, its
  // field's words measured with the page's, and its list laid out less; each the most of the default rate and 60, 120,
  // 24 and 7, what fell brought down to it: before it (1015, 29, 673, 79, 941), (326, 17, 239, 27, 319), (2443, 483,
  // 2011, 217, 2447), (886, 130, 882, 123, 1057), (564, 366, 617, 96), (721, 382, 911, 125) scrolling up, its frames
  // (140, 102, 125, 28), (160, 105, 146, 28))
  "phone cold": (1035, 31, 667, 80, 969),
  "phone again": (346, 19, 233, 28, 347),
  "wide cold": (2476, 503, 1920, 220, 2475),
  "wide again": (905, 130, 871, 124, 1083),
  "phone up": (552, 359, 601, 87, 0),
  // (wide up 2 made and 1 laid more, 2026-11-18: a quote's source that leads somewhere is mbui's headless button, read
  // out and pressed as one (sf button_while_node), the pick that makes it a button only then and the button's own box
  // where a bare box was pressed by hand; before it 724 and 914)
  "wide up": (726, 372, 915, 114, 0),
  "phone up frame": (139, 100, 124, 28, 0),
  "wide up frame": (160, 103, 152, 28, 0),
}

///|
/// The heaviest frame (the most made) the journal holds from its `from`th entry on: made, let go, laid, measured,
/// bindings.
fn chat_nodes_heaviest(from : Int) -> (Int, Int, Int, Int, Int) {
  let mut most = (0, 0, 0, 0, 0)
  for i, e in @ui.journal() {
    guard i >= from else { continue }
    match e {
      Work({ what: Frame(f), .. }) if f.made > most.0 => most = (f.made, f.let_go, f.laid, f.measured, f.bindings)
      _ => ()
    }
  }
  most
}

///|
/// All of what the frames the journal holds from its `from`th entry on did: made, let go, laid, measured, bindings.
fn chat_nodes_all(from : Int) -> (Int, Int, Int, Int, Int) {
  let mut all = (0, 0, 0, 0, 0)
  for i, e in @ui.journal() {
    guard i >= from else { continue }
    match e {
      Work({ what: Frame(f), .. }) =>
        all = (all.0 + f.made, all.1 + f.let_go, all.2 + f.laid, all.3 + f.measured, all.4 + f.bindings)
      _ => ()
    }
  }
  all
}

///|
/// The most any one frame the journal holds from its `from`th entry on did of each, apart: made, let go, laid, measured
/// (each its own frame's most; bindings not held: as many as the rate draws).
fn chat_nodes_frame_most(from : Int) -> (Int, Int, Int, Int, Int) {
  let mut most = (0, 0, 0, 0, 0)
  for i, e in @ui.journal() {
    guard i >= from else { continue }
    match e {
      Work({ what: Frame(f), .. }) =>
        most = (
          @cmp.maximum(most.0, f.made),
          @cmp.maximum(most.1, f.let_go),
          @cmp.maximum(most.2, f.laid),
          @cmp.maximum(most.3, f.measured),
          0,
        )
      _ => ()
    }
  }
  most
}

///|
/// Words dragged over with the mouse in what shows of the chat `r` open in `t` (a window `h` tall), scrolled up through
/// its history far enough that the blocks of the messages read before are put by and taken for others (sfpages
/// chat_body_shape): what is picked of each message's words is of the message that shows them, not of one its block
/// showed before it was taken for another; what is not so, said.
fn chat_nodes_reused_picked(t : @ui.Tester, src : Source, r : ChatRef, h : Double) -> Array[String] {
  // (the chat's messages as the page holds them, by their keys)
  let said : Array[(String, String)] = @signals.untracked(fn() {
    match @sfbase.chat_messages(src, r) {
      Some(ms) => ms.peek_keys().filter_map(fn(k) { ms.peek(k) }).map(fn(m) { ("m:" + m.ts, m.text) })
      None => []
    }
  })
  guard said.length() > 0 else { return ["the chat's messages by key: none"] }
  // (the start of each paragraph of each message's words, where it shows wholly in sight under the bar and over the
  // composer (a message's words in pieces, Tester::run_rects), top to bottom: a real chat says the same words in many
  // messages, so which message each is is told by where it shows as well, the keys going down the list in their order)
  let lines : Array[(String, Double, Double, Double, Double, Double)] = []
  let tried : Map[String, Bool] = Map([])
  for m in said {
    // (each paragraph's start: a long message's pieces each one)
    for para in m.1.split("\n\n") {
      let start = para.to_owned().clamped_view(end=6).to_owned()
      guard start.length() >= 4 && !start.contains("\n") && !start.contains("#") && !start.contains("`") &&
        !start.contains("*") && !start.contains("|") && !start.has_prefix("-") && !start.has_prefix("[") &&
        !tried.contains(start) else {
        continue
      }
      tried[start] = true
      for r in t.run_rects(start) {
        if r.1 > 120.0 && r.1 + r.3 < h - 160.0 && r.2 > 30.0 {
          lines.push((start, r.0, r.1, r.2, r.3, 1.0))
        }
      }
    }
  }
  lines.sort_by(fn(a, b) { a.2.compare(b.2) })
  let wrong : Array[String] = []
  let mut last = ""
  let mut checked = 0
  for s in lines {
    t.run_for(@ui.double_click_ms)
    let y = s.2 + s.4 / 2.0
    t.drag(s.1 + 1.0, y, s.1 + s.3 - 1.0, y)
    t.frame()
    match @ui.picked_now() {
      Some({ of: [key], text, .. }) => {
        // (what is picked one message's words: that message's, and none over it in the list after one under it)
        if said.iter().any(fn(m) { m.1.contains(text) }) {
          checked = checked + 1
          if !said.iter().any(fn(m) { m.0 == key && m.1.contains(text) }) || key < last {
            wrong.push("「\{text}」 at \{y}: picked of \{key}, the one before \{last}")
          }
          last = key
        }
      }
      Some(p) => wrong.push("「\{s.0}」 at \{y}: picked of \{@ui.list_text(p.of)}")
      None => ()
    }
    @ui.picked_let_go()
  }
  if checked < 3 {
    wrong.push("words picked in the messages that show: \{checked} of \{lines.length()} lines")
  }
  wrong
}

///|
/// How long after one notch of the wheel the next comes, scrolling a chat up (chat_nodes_scrolled): a hand turning it.
let chat_nodes_notch_ms : Double = 100.0

///|
/// The chat open in `t`, a window `w` by `h`, scrolled up through its older messages by the wheel over its middle: 10
/// notches of 300, each a tenth of a second after the one before; all its frames did, and the most one of them did.
fn chat_nodes_scrolled(
  t : @ui.Tester,
  w : Double,
  h : Double,
) -> ((Int, Int, Int, Int, Int), (Int, Int, Int, Int, Int)) {
  let from = @ui.journal().length()
  for _ in 0..<10 {
    t.wheel(w * 0.7, h / 2.0, -300.0)
    t.run_for(chat_nodes_notch_ms)
  }
  t.run_for(@ui.move_most_ms)
  (chat_nodes_all(from), chat_nodes_frame_most(from))
}

///|
/// The fixture's chat (s-c1) on the workspace of real size, made as nodes, in window `win` (name, width, height,
/// platform): the heaviest frame of its opening, of its opening again from Home, and all of scrolling it up then;
/// `after` told the Tester, its source and the chat once it is scrolled up, what it says is wrong said with them.
fn chat_nodes_open_measured(
  win : (String, Double, Double, Int),
  after? : (@ui.Tester, Source, ChatRef) -> Array[String] = fn(_, _, _) { [] },
) -> (
  (Int, Int, Int, Int, Int),
  (Int, Int, Int, Int, Int),
  ((Int, Int, Int, Int, Int), (Int, Int, Int, Int, Int)),
  Array[String],
) raise {
  let (_, w, h, platform) = win
  let src : Ref[Source?] = Ref(None)
  let made = fn() {
    match src.val {
      Some(s) => s
      None => {
        reset()
        // (its composer made as nodes too, 试用新输入框: what the bars below were raised for)
        @sfbase.chat_page_nodes.set(true)
        @sfbase.composer_nodes.set(true)
        let c = @sfrealsize.RealSizeChanging::new()
        // (through the app's own client as a phone's core is, so its messages come by key as a device's do:
        // sfbench's chat-real)
        let s = @sffixture.round_trip_again(c.source(@sffixture.fixture("chat")), 0.0, delta_of=fn(name, params) {
          c.last_ops(name, params)
        })
        open_fixture_over("chat", s)
        src.val = Some(s)
        s
      }
    }
  }
  let t = @ui.Tester::new(
    fn(c) { view(c, made()) },
    tree=fn(root) { app_tree(made())(root) },
    w~,
    h~,
    platform~,
    window_corner=test_window_corner(platform),
    env=[("MBUI_LOCALE", "zh"), ("MBUI_REDUCE_MOTION", "1")],
  )
  t.run_for(squeeze_opening)
  t.frame()
  let cold = chat_nodes_heaviest(0)
  guard app.nav.top() is Chat(r) else { fail("not on the chat") }
  // (back to Home, the chat held by the core's client; then the same chat again)
  app.nav.pop() |> ignore
  t.run_for(squeeze_opening)
  let from = @ui.journal().length()
  @ui.view_tree().unwrap().event(t.time(), fn() { open_page(Chat(r)) })
  t.run_for(squeeze_opening)
  t.frame()
  assert_true(app.nav.top() is Chat(_), msg="the chat again")
  let again = chat_nodes_heaviest(from)
  let up = chat_nodes_scrolled(t, w, h)
  (cold, again, up, after(t, made(), r))
}

///|
test "a real chat as nodes, opened cold and again from Home and scrolled up: what its frames do within its bar, and 大屏 words picked in what shows then the message's that shows them" {
  let wrong : Array[String] = []
  for win in [("phone", 360.0, 740.0, 2), ("wide", 1280.0, 800.0, 0)] {
    // (大屏, a mouse's: what is picked in a block taken for another message, once scrolled up)
    let after = if win.3 == 0 { Some(fn(t, src, r) { chat_nodes_reused_picked(t, src, r, win.2) }) } else { None }
    let (cold, again, (up, up_frame), said) = chat_nodes_open_measured(win, after?)
    wrong.append(said.map(fn(s) { "\{win.0}: \{s}" }))
    for k in [("cold", cold), ("again", again), ("up", up), ("up frame", up_frame)] {
      let key = "\{win.0} \{k.0}"
      let n = k.1
      println("chat nodes \{key}: made \{n.0} let_go \{n.1} laid \{n.2} measured \{n.3} bindings \{n.4}")
      let bar = chat_nodes_open_budget.get(key).unwrap_or((0, 0, 0, 0, 0))
      // (bindings run scrolling up not held: they run again in each frame drawn, as many as the rate draws)
      let bindings_over = !k.0.has_prefix("up") && n.4 > bar.4
      if n.0 > bar.0 || n.1 > bar.1 || n.2 > bar.2 || n.3 > bar.3 || bindings_over {
        wrong.push("\{key}: \{Repr(n)} over \{Repr(bar)}")
      }
    }
  }
  assert_true(wrong.is_empty(), msg=wrong.join(" | "))
}
