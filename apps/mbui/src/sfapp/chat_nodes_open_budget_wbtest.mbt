// A chat of real size on the chat's page made as nodes (实验性功能's 试用新对话页), as a phone's core sends it (its messages
// read as Markdown, `md`, each long one a block a piece; src/sfrealsize): what the heaviest frame does as it opens cold,
// and as it is opened again from Home with the chat held (back, then the same chat: its messages there already, the
// page made whole in one frame) — nodes made, let go, laid out, words measured, bindings run — held to its bar, which
// only falls. Most of a chat's paragraphs have no link and a list's items no task: what would be made for those (their
// presses, their cards) is none of it. The real-size sweep (real_size_wbtest.mbt) opens the old page's chat; this is
// the new page's alone, never set beside the old.

///|
/// Each window's bars, "<window> cold" and "<window> again": made, let go, laid out, measured, bindings run, in the
/// heaviest frame (the most made); "<window> up": all of them in every frame as the chat is scrolled up through its
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
/// and 898 made, 683 and 998 made scrolling up.
let chat_nodes_open_budget : Map[String, (Int, Int, Int, Int, Int)] = {
  "phone cold": (783, 38, 894, 148, 784),
  "phone again": (342, 26, 245, 29, 299),
  "wide cold": (2568, 483, 3693, 560, 2752),
  "wide again": (897, 130, 882, 124, 1202),
  "phone up": (667, 762, 644, 92, 0),
  "wide up": (973, 795, 966, 129, 0),
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
/// How long after one notch of the wheel the next comes, scrolling a chat up (chat_nodes_scrolled): a hand turning it.
let chat_nodes_notch_ms : Double = 100.0

///|
/// The chat open in `t`, a window `w` by `h`, scrolled up through its older messages by the wheel over its middle: 10
/// notches of 300, each a tenth of a second after the one before; all its frames did.
fn chat_nodes_scrolled(t : @ui.Tester, w : Double, h : Double) -> (Int, Int, Int, Int, Int) {
  let from = @ui.journal().length()
  for _ in 0..<10 {
    t.wheel(w * 0.7, h / 2.0, -300.0)
    t.run_for(chat_nodes_notch_ms)
  }
  t.run_for(@ui.move_most_ms)
  chat_nodes_all(from)
}

///|
/// The fixture's chat (s-c1) on the workspace of real size, made as nodes, in window `win` (name, width, height,
/// platform): the heaviest frame of its opening, of its opening again from Home, and all of scrolling it up then.
fn chat_nodes_open_measured(
  win : (String, Double, Double, Int),
) -> ((Int, Int, Int, Int, Int), (Int, Int, Int, Int, Int), (Int, Int, Int, Int, Int)) raise {
  let (_, w, h, platform) = win
  let src : Ref[Source?] = Ref(None)
  let made = fn() {
    match src.val {
      Some(s) => s
      None => {
        reset()
        @sfbase.chat_page_nodes.set(true)
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
  (cold, again, chat_nodes_scrolled(t, w, h))
}

///|
test "a real chat as nodes, opened cold and again from Home and scrolled up: what its frames do within its bar" {
  let wrong : Array[String] = []
  for win in [("phone", 360.0, 740.0, 2), ("wide", 1280.0, 800.0, 0)] {
    let (cold, again, up) = chat_nodes_open_measured(win)
    for k in [("cold", cold), ("again", again), ("up", up)] {
      let key = "\{win.0} \{k.0}"
      let n = k.1
      println("chat nodes \{key}: made \{n.0} let_go \{n.1} laid \{n.2} measured \{n.3} bindings \{n.4}")
      let bar = chat_nodes_open_budget.get(key).unwrap_or((0, 0, 0, 0, 0))
      // (bindings run scrolling up not held: they run again in each frame drawn, as many as the rate draws)
      let bindings_over = k.0 != "up" && n.4 > bar.4
      if n.0 > bar.0 || n.1 > bar.1 || n.2 > bar.2 || n.3 > bar.3 || bindings_over {
        wrong.push("\{key}: \{Repr(n)} over \{Repr(bar)}")
      }
    }
  }
  assert_true(wrong.is_empty(), msg=wrong.join(" | "))
}
