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
  // (2026-11-17, the chat's composer made as nodes (sfpages composer_node, in its list's foot) and
  // not hosted as an old view: an old view's nodes are none of what is counted here, so what the composer makes (its
  // foot, box, rows, field, send, ＋ and the structures that come and go in it) is counted now where it was not, its
  // field's words measured with the page's, and its list laid out less; each the most of the default rate and 60, 120,
  // 24 and 7, what fell brought down to it: before it (1015, 29, 673, 79, 941), (326, 17, 239, 27, 319), (2443, 483,
  // 2011, 217, 2447), (886, 130, 882, 123, 1057), (564, 366, 617, 96), (721, 382, 911, 125) scrolling up, its frames
  // (140, 102, 125, 28), (160, 105, 146, 28))
  // (wide's raised, 2026-11-18, once the new chat Home's pane opens on is made as nodes with the page (sfpages
  // new_chat_node, 试用新对话页): opened from it again, the chat's page lets go of that page's nodes (406, 130 before) and
  // makes and binds the chat's where the old view's island counted none; cold more made and bound as its pane's page
  // is made so; the same at the default rate and 60, 120, 24 and 7: before it WIDEBEFORE)
  // (2026-11-18: each wide shell holds what opens over its panels as nodes, closed: a right click's menu, the rail's, its
  // adder and 待处理, sfdesk overlays_node: wide cold 6 more made, 2 laid)
  // (2026-11-18: signin & viz cards pick their decided/open state on View::pick with leave cross-fade instead of instant
  // show swaps, a pick branch node more where one shows; meanwhile chat_rail_node omits empty non-day gap boxes; each the
  // most of the default rate and 60, 120, 24 and 7, what fell brought down to it: 大屏 again lets go 4 more than before
  // it (905, 130, 871, 124, 1083), the rest fell; before it (1035, 31, 667, 80, 969), (346, 19, 233, 28, 347), (2482,
  // 503, 1922, 217, 2471), (552, 359, 601, 87), (726, 372, 915, 114) scrolling up, its frames (139, 100, 124, 28))
  // (2 made and 1 laid more on a phone, 2026-11-18: the chat bar's pick between its title and keys and ⌘F's bar, open
  // from the chat's sheet's 在对话中查找 (chat_bar_node); before it (1028, 31, 660, 80, 968) and (339, 19, 226, 28, 346))
  // (2026-11-18: the new chat made as nodes with its composer (试用新对话页, sfpages new_chat_node), the chat's own composer
  // made as nodes on every page of it (composer_node): 大屏's Home's pane the new chat's nodes, let go as the chat opens
  // from it and made again as it is come back to, where the old view's island counted none; scrolling up on a phone the
  // composer's own nodes laid out with the list; the same at the default rate and 60, 120, 24 and 7: before it (2473,
  // 503, 1914, 217, 2470), (897, 132, 853, 121, 1062), (551, 358, 593, 87))
  // (2026-11-20: a half-open device's fold made only where one is (sfapp tabletop.mbt chat_foot_node's `show`), the
  // composer held behind what is presented over it (composer_node's held_behind) and the chat's list told what is in
  // sight (chat_body_node's sight_ver); the most of the default rate: before it (1027, 31, 659, 80, 967), (4, 3, 62, 0,
  // 182), (2473, 503, 1914, 217, 2472))
  // (+8 made, +7 laid, +11 bindings, 2026-11-22: narrow Home and Chat top bar action groups use floating
  // bar_pill_group_node liquid glass capsules, standalone archive circle, and soft GPU bottom-fade narrow_bar_scrim_node; before it (1029, 31, 659, 80, 970))
  // (+18 bindings, 2026-11-22: interactive liquid glass pill press feedback (.scale on bar_pill_group_node, hover_ground_node on round_key_node, bar_pill_key_press_node on Home workspace switcher, and tucked search_field_node presses(By(...)); before it (1037, 31, 666, 80, 981))
  "phone cold": (1037, 31, 666, 80, 999),
  // (2026-11-18: a chat's page made as nodes kept as it is left (ui's Nav kept_left, sfbase's page_entry_parked) and
  // taken back as it is opened again, holding no chat meanwhile and waiting for none of it as it comes back; the same at
  // 60, 120, 24 and 7: before it (341, 19, 227, 28, 346) and wide again (897, 132, 853, 121, 1062))
  // (5 bindings more on a phone, 2026-11-19: what the chat's list's place watches as it is taken back, waiting for the
  // chat's first answer to set it where it was left (sfpages chat_body_node's reopen_gen); the same at 60, 120, 24 and 7)
  // (2026-11-18: 小屏's bottom bar made as nodes, its old island's build each frame no longer the old view's: as a chat
  // comes over Home the bar's parts that go with it (its holder going down, the notch closing, the ball fading, the
  // places dimming) are bindings worked out again, each part only as its own ways are told: phone again 38 more
  // bindings, the same at 60, 120, 24 and 7; before it 144)
  "phone again": (4, 3, 62, 0, 183),
  // (+4 made, +8 laid, +8 bindings, 2026-11-20: #7607's new chat choreography and #7608's hover grounds on the page
  // made as nodes)
  // (+5 made, +44 laid, +4 bindings, -19 measured, 2026-11-20: #7833's desktop side tab strip (sf.tab_strip_node) holds
  // a persistent Scroll::across viewport so 1<->2 tab transitions keep Handoff and focus, plus overlays_node's closed
  // side_tab_menu_node slot; before it (2444, 501, 1880, 206, 2487))
  // (+6 bindings, 1 let go fewer, 2026-11-21: a hairline ring of its own under each rail workspace shown by its letter
  // (sfdesk rail_workspaces_node), in place of the pointer's ground it rested on; the same at 60, 120, 24 and 7; before
  // it (2449, 501, 1924, 187, 2491))
  "wide cold": (2449, 500, 1924, 187, 2497),
  // (2026-11-18: a chat's list's keys worked out of each message's JSON, its pieces of the core's tree's shape (sfpages
  // chat_said_keys_raw, sf core_pieces), each message read as a Message only as a row of it shows: wide again 2 made, 2
  // let go, 17 laid and 18 bindings fewer, the same at 60, 120, 24 and 7; before it (899, 134, 870, 121, 1080))
  // (2026-11-19: 大屏's side panel taken back with the chat's page kept left (sfdesk tape_side_node's each kept by
  // entry), what it reads held while asked again; the same at 60, 120, 24 and 7: before it (94, 116, 245, 29, 290))
  // (2026-11-19: Home's pane the new chat made as nodes (above), the chat's page kept left let go of it as the chat
  // opens from it again and its nodes made and bound where the old view's island counted none; every bar brought to what
  // is counted now, the most of the default rate and 60, 120, 24 and 7: wide again before it (22, 44, 70, 4, 172))
  "wide again": (174, 325, 184, 23, 332),
  "phone up": (543, 354, 606, 87, 0),
  // (wide up 2 made and 1 laid more, 2026-11-18: a quote's source that leads somewhere is mbui's headless button, read
  // out and pressed as one (sf button_while_node), the pick that makes it a button only then and the button's own box
  // where a bare box was pressed by hand; before it 724 and 914)
  "wide up": (716, 367, 906, 114, 0),
  "phone up frame": (137, 99, 123, 28, 0),
  "wide up frame": (159, 102, 152, 28, 0),
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
fn chat_nodes_reused_picked(t : @ui.Tester, src : @sfbase.Source, r : @sfbase.ChatRef, h : Double) -> Array[String] {
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
  after? : (@ui.Tester, @sfbase.Source, @sfbase.ChatRef) -> Array[String] = fn(_, _, _) { [] },
) -> (
  (Int, Int, Int, Int, Int),
  (Int, Int, Int, Int, Int),
  ((Int, Int, Int, Int, Int), (Int, Int, Int, Int, Int)),
  Array[String],
) raise {
  let (_, w, h, platform) = win
  let src : Ref[@sfbase.Source?] = Ref(None)
  let made = fn() {
    match src.val {
      Some(s) => s
      None => {
        @sfapp.reset()
        // (its composer made as nodes too: what the bars below were raised for)
        let c = @sfrealsize.RealSizeChanging::new()
        // (through the app's own client as a phone's core is, so its messages come by key as a device's do:
        // sfbench's chat-real)
        let s = @sffixture.round_trip_again(c.source(@sffixture.fixture("chat")), 0.0, delta_of=fn(name, params) {
          c.last_ops(name, params)
        })
        @sfapp.open_fixture_over("chat", s)
        src.val = Some(s)
        s
      }
    }
  }
  let t = @ui.Tester::new(
    fn(c) { @sfapp.view(c, made()) },
    tree=fn(root) { @sfapp.app_tree(made())(root) },
    w~,
    h~,
    platform~,
    window_corner=@sfapptest.test_window_corner(platform),
    env=[("MBUI_LOCALE", "zh"), ("MBUI_REDUCE_MOTION", "1")],
  )
  t.run_for(@sfapptest.squeeze_opening)
  t.frame()
  let cold = chat_nodes_heaviest(0)
  guard @sfbase.app.nav.top() is Chat(r) else { fail("not on the chat") }
  // (back to Home, the chat held by the core's client; then the same chat again)
  @sfbase.app.nav.pop() |> ignore
  t.run_for(@sfapptest.squeeze_opening)
  let from = @ui.journal().length()
  @ui.view_tree().unwrap().event(t.time(), fn() { @sfbase.open_page(Chat(r)) })
  t.run_for(@sfapptest.squeeze_opening)
  t.frame()
  assert_true(@sfbase.app.nav.top() is Chat(_), msg="the chat again")
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

///|
/// What message `n` of a window of agents' answers (chat_nodes_window_source) says: three paragraphs, a piece each of
/// its rows, its number first in each.
fn chat_nodes_window_words(n : Int) -> Array[String] {
  ["第\{n}条甲段：检查了构建脚本，签名和上传也过了一遍。", "第\{n}条乙段：列表只读看得见的消息。", "第\{n}条丙段：滚到时再读。"]
}

let budget_long_ref : @sfbase.ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }

///|
let budget_long_screens : Array[(String, Double, Double, Int)] = [("小屏", 390.0, 844.0, 2), ("大屏", 1280.0, 800.0, 0)]

///|
let budget_long_opened_ms : Double = @ui.move_most_ms * 2.0

///|
/// The fixture's chat on a made-up core that keeps its messages by key as the app's client does (Sub::keyed), its
/// window `n` agents' answers of three paragraphs each (chat_nodes_window_words), the chat open at its end.
fn chat_nodes_window_source(n : Int) -> @sfbase.Source {
  let base = @sffixture.fixture("chat")
  let made : Ref[Json?] = Ref(None)
  let list : Ref[@signals.KeyedList[String, Json]?] = Ref(None)
  let value = fn(v : Json) -> Json {
    match made.val {
      Some(m) => return m
      None => ()
    }
    guard v is Object(chat) else { return v }
    let template = @sfbase.items(Some(v), "messages")
      .iter()
      .find_first(fn(m) { !@sfbase.flag(Some(m), "system") && !@sfbase.flag(Some(m), "mine") })
      .unwrap_or(Json::object({}))
    guard template is Object(t) else { return v }
    let messages : Array[Json] = []
    for i in 1..=n {
      let m = t.copy()
      let paras = chat_nodes_window_words(i)
      let words = paras.join("\n\n")
      m["seq"] = Json::number(i.to_double())
      m["ts"] = Json::string("ts\{i}")
      m["text"] = Json::string(words)
      m["words"] = Json::array([{ "text": Json::string(words) }])
      m["md"] = Json::array(paras.map(fn(p) { ["p", [Json::string(p)]] }))
      m["joined"] = Json::boolean(i % 4 != 1)
      for k in ["said", "attachments", "card", "options", "quotes", "decision", "elsewhere"] {
        m.remove(k)
      }
      messages.push(Json::object(m))
    }
    let c = chat.copy()
    c["messages"] = Json::array(messages)
    for k in ["more", "newer", "unreadLine", "at"] {
      c.remove(k)
    }
    let out = Json::object(c)
    made.val = Some(out)
    out
  }
  {
    ..base,
    topic_read: fn(name, params) {
      let got = base.topic(name, params).get().snapshot()
      guard name == "chat" && got.value is Some(v) else { return got }
      { ..got, value: Some(value(v)) }
    },
    topic_keyed: fn(name, params, field, keys) {
      guard name == "chat" else { return (base.topic_keyed)(name, params, field, keys) }
      match list.val {
        Some(l) => Some(l)
        None => {
          guard @signals.untracked(fn() { base.topic(name, params).get().snapshot().value }) is Some(v) else {
            return None
          }
          let l : @signals.KeyedList[String, Json] = @signals.keyed_list()
          let ks : Array[String] = []
          let vals : Map[String, Json] = Map([])
          for m in @sfbase.items(Some(value(v)), "messages") {
            let k = Json::array([field_or_null(m, "seq"), field_or_null(m, "outgoing")]).stringify()
            ks.push(k)
            vals[k] = m
          }
          l.reset(ks, vals)
          list.val = Some(l)
          Some(l)
        }
      }
    },
  }
}

///|
/// Field `name` of `m`, null where it has none (a key's part as the core keys a message).
fn field_or_null(m : Json, name : String) -> Json {
  match m {
    Object(o) => o.get(name).unwrap_or(Json::null())
    _ => Json::null()
  }
}

///|
/// The chat of chat_nodes_window_source(`n`) opened cold at its end on screen `s`, made as nodes: how many of its
/// messages were read as Messages (chat_messages_read) as it opened; then scrolled up through 10 notches of the wheel,
/// how many more, and whether a message far over its end then shows.
fn chat_nodes_window_read(n : Int, s : (String, Double, Double, Int)) -> (Int, Int, Bool, @ui.Tester, @sfbase.Source) raise {
  let (_, w, h, platform) = s
  @sfapp.new_run()
  let src = chat_nodes_window_source(n)
  let read0 = @sfbase.chat_messages_read.val
  @sfbase.open_chat(budget_long_ref)
  let t = @ui.Tester::new(fn(c) { @sfapp.view(c, src) }, tree=@sfapp.app_tree(src), w~, h~, platform~, begun=fn() {
    @sfbase.window_tall.val = h
  })
  t.run_for(budget_long_opened_ms)
  assert_true(@sfbase.app.nav.top() is Chat(_), msg="\{n}: on the chat")
  assert_true(t.find(chat_nodes_window_words(n)[2]) is Some(_), msg="\{n}: its last message shown")
  let opened = @sfbase.chat_messages_read.val - read0
  let read1 = @sfbase.chat_messages_read.val
  let _ = chat_nodes_scrolled(t, w, h)
  let up = @sfbase.chat_messages_read.val - read1
  // (one far over the end it opened at: its words drawn in sight)
  let far = t
    .words()
    .iter()
    .any(fn(x) { x.2 + x.4 > 0.0 && x.2 < h && x.5 > 0.0 && x.0.has_prefix("第") && x.0.contains("条") && !x.0.has_prefix("第\{n}条") && !x.0.has_prefix("第\{n - 1}条") && !x.0.has_prefix("第\{n - 2}条") })
  (opened, up, far, t, src)
}

///|
test "a chat opened cold reads as Messages only the messages round what shows: the same of a window of 30 as of 120, and those scrolled to as they come" {
  let wrong : Array[String] = []
  for s in budget_long_screens {
    let (open30, up30, far30, _, _) = chat_nodes_window_read(30, s)
    let (open120, up120, far120, t, src) = chat_nodes_window_read(120, s)
    println("chat window read \{s.0}: opened 30 \{open30} 120 \{open120}, scrolled up 30 \{up30} 120 \{up120}")
    if open120 != open30 {
      wrong.push("\{s.0}: opened 120 read \{open120}, 30 \{open30}")
    }
    if open120 > chat_nodes_window_read_most {
      wrong.push("\{s.0}: opened read \{open120} over \{chat_nodes_window_read_most}")
    }
    if up120 <= 0 || !far120 || !far30 {
      wrong.push("\{s.0}: scrolled up read \{up120} more, older shown \{far120} \{far30}")
    }
    // (大屏, a mouse's: what is picked of the messages read as they were scrolled to their own)
    if s.3 == 0 {
      wrong.append(chat_nodes_reused_picked(t, src, budget_long_ref, s.2).map(fn(x) { "\{s.0}: \{x}" }))
    }
  }
  assert_true(wrong.is_empty(), msg=wrong.join(" | "))
}

///|
/// The most of a chat's messages its cold opening reads as Messages (chat_nodes_window_read): those round what shows
/// (a page's list's slots, a screen over and under it), whatever its window holds.
let chat_nodes_window_read_most : Int = 10

///|
/// The fixture's chat on the app's own client (an in-memory one, `client`, as page_scope_client_wbtest's): chat
/// `s-c1`'s topic and the prefs subscribed through it, so what holds that chat is the client's to say.
fn chat_kept_left_source(client : @core.Client, called : Array[String]) -> @sfbase.Source {
  let base = @sffixture.fixture("chat")
  let which = fn(name : String, p : Map[String, Json]) {
    name == "prefs" || (name == "chat" && p.get("session") == Some(Json::string("s-c1")))
  }
  {
    ..base,
    // (what the core is called with, kept to be read: where a chat is left told it)
    call: fn(name, args, done) {
      called.push(name + " " + args.stringify())
      (base.call)(name, args, done)
    },
    topic_read: fn(name, p) {
      if !which(name, p) {
        return (base.topic_read)(name, p)
      }
      let sub = client.follow_topic(name, params=@sfbase.core_topic_params(name, p))
      { value: sub.value, error: sub.error, version: sub.version }
    },
    waits: fn(name, p) {
      if which(name, p) {
        client.follow_topic(name, params=@sfbase.core_topic_params(name, p)).waiting
      } else {
        (base.waits)(name, p)
      }
    },
    leave: fn(name, p, reason) {
      if reason is @sfbase.TopicLeave::Owned(stop) {
        stop()
        return
      }
      if which(name, p) {
        client.leave_topic(name, params=@sfbase.core_topic_params(name, p))
      } else {
        (base.leave)(name, p, reason)
      }
    },
    release: fn(name, p) {
      if which(name, p) {
        client.release_topic(name, params=@sfbase.core_topic_params(name, p))
      } else {
        (base.release)(name, p)
      }
    },
    // (its messages by key as the client keeps them, once its subscription has a value: @core.keyed_of's)
    topic_keyed: fn(name, p, field, keys) {
      if !which(name, p) {
        return (base.topic_keyed)(name, p, field, keys)
      }
      client
      .peek_topic(name, params=@sfbase.core_topic_params(name, p))
      .bind(fn(sub) { if sub.value is Some(_) { Some(sub.keyed(field, keys)) } else { None } })
    },
  }
}

///|
/// The core's answer to what `client` asks of the prefs and of chat `params` (core_topic_params'), from the fixture's:
/// each subscription that waits answered with the fixture's value, as a core answers.
fn chat_kept_left_answer(client : @core.Client, params : Map[String, Json]) -> Unit {
  let base = @sffixture.fixture("chat")
  for q in [("prefs", Map([]), Map([])), ("chat", @sfbase.core_topic_params("chat", params), params)] {
    match (client.peek_topic(q.0, params=q.1), (base.topic_read)(q.0, q.2).value) {
      (Some(sub), Some(v)) if sub.value is None =>
        client.receive_json({ "id": Json::number(sub.id.to_double()), "value": v })
      _ => ()
    }
  }
}

///|
test "a chat's page made as nodes left kept at rest, holding no chat meanwhile, and taken back as it is opened again: 小屏 back to Home and the same chat, 大屏 another chat beside the list and back" {
  let wrong : Array[String] = []
  for win in [("phone", 360.0, 740.0, 2), ("wide", 1280.0, 800.0, 0)] {
    let (name, w, h, platform) = win
    @sfapp.new_run()
    let client = @core.Client::new(fn(_) {  })
    let called : Array[String] = []
    let src = chat_kept_left_source(client, called)
    let a : @sfbase.ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }
    let b = @sfbase.chat_ref("ws1/st1", "s-c2")
    let a_params = @sfbase.core_topic_params("chat", @sfbase.chat_params(a))
    @sfbase.open_chat(a)
    let t = @ui.Tester::new(fn(c) { @sfapp.view(c, src) }, tree=@sfapp.app_tree(src), w~, h~, platform~, env=[("MBUI_LOCALE", "zh")])
    t.frame()
    chat_kept_left_answer(client, @sfbase.chat_params(a))
    t.run_for(@sfapptest.squeeze_opening)
    t.frame()
    if !(@sfbase.app.nav.top() is Chat(_)) || client.peek_topic("chat", params=a_params) is None {
      wrong.push("\{name}: the chat not open, or not held, at first")
      continue
    }
    let (serial, _) = @signals.untracked(fn() { @sfbase.app.nav.top_stay() })
    // (小屏 back to Home; 大屏 another chat beside the list in its place)
    if platform == 2 {
      @sfbase.app.nav.pop() |> ignore
    } else {
      @ui.view_tree().unwrap().event(t.time(), fn() { @sfbase.open_page(Chat(b)) })
    }
    t.run_for(@sfapptest.squeeze_opening)
    t.frame()
    if !@sfbase.app.nav.is_kept_left(serial) {
      wrong.push("\{name}: the chat's page not kept as it left")
    }
    if client.peek_topic("chat", params=a_params) is Some(_) {
      wrong.push("\{name}: the chat still subscribed while its page is kept")
    }
    let from = @ui.journal().length()
    @ui.view_tree().unwrap().event(t.time(), fn() { @sfbase.open_page(Chat(a)) })
    t.frame()
    // (the core answering it again, its subscription made anew)
    chat_kept_left_answer(client, @sfbase.chat_params(a))
    t.run_for(@sfapptest.squeeze_opening)
    t.frame()
    let again = chat_nodes_all(from)
    // (each frame's, for what was made and let go as it came back)
    for i, e in @ui.journal() {
      guard i >= from else { continue }
      match e {
        Work({ what: Frame(f), .. }) if f.made > 0 || f.let_go > 0 =>
          println("chat kept left \{name} frame: made \{f.made} let_go \{f.let_go} laid \{f.laid}")
        _ => ()
      }
    }
    println("chat kept left \{name} again: made \{again.0} let_go \{again.1} laid \{again.2} measured \{again.3} bindings \{again.4}")
    if @signals.untracked(fn() { @sfbase.app.nav.top_stay() }).0 != serial {
      wrong.push("\{name}: opened again not the page kept")
    }
    if again.0 > chat_kept_left_made_most {
      wrong.push("\{name}: opened again made \{again.0}, over \{chat_kept_left_made_most}")
    }
    // (大屏's taken back laid out where it was left: its list and what is beside it, nothing of the page anew)
    if platform == 0 && again.2 > 15 {
      wrong.push("\{name}: opened again laid \{again.2}, over 15")
    }
    if client.peek_topic("chat", params=a_params) is None {
      wrong.push("\{name}: the chat not subscribed again as its page is opened again")
    }
    if t.find("整理发布清单") is None {
      wrong.push("\{name}: the chat's title not shown again")
    }
    // (left again and then let go for good, as the workspace in view changes: holding the chat no more either; left
    // again from the page taken back, told so and where it was left as the first time, kept again holding nothing)
    let a_key = a.station + "\u{1}" + a.session
    @sfbase.kept_places.remove(a_key)
    let called_from = called.length()
    if platform == 2 {
      @sfbase.app.nav.pop() |> ignore
    } else {
      @ui.view_tree().unwrap().event(t.time(), fn() { @sfbase.open_page(Chat(b)) })
    }
    t.run_for(@sfapptest.squeeze_opening)
    t.frame()
    let told_left = called[called_from:].iter().any(fn(c) { c.has_prefix("client.focus ") && c.contains("\"left\"") })
    if !told_left || !@sfbase.kept_places.contains(a_key) {
      wrong.push("\{name}: left again from the page taken back, not told where it was left (told left \{told_left})")
    }
    if !@sfbase.app.nav.is_kept_left(serial) || client.peek_topic("chat", params=a_params) is Some(_) {
      wrong.push("\{name}: left again, not kept or still subscribed")
    }
    @ui.view_tree().unwrap().event(t.time(), fn() { @sfbase.app.nav.shelf_empty() })
    t.run_for(@sfapptest.squeeze_opening)
    t.frame()
    if @sfbase.app.nav.is_kept_left(serial) || client.peek_topic("chat", params=a_params) is Some(_) {
      wrong.push("\{name}: the chat still subscribed once its page is let go for good")
    }
  }
  assert_true(wrong.is_empty(), msg=wrong.join(" | "))
}

///|
/// The most a chat's page kept (chat_page_left_key) makes as it is opened again, all its frames together.
let chat_kept_left_made_most : Int = 5
