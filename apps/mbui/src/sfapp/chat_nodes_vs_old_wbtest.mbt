// A chat of real size opened again from Home (or the sidebar) with the chat held, on the chat's page made as nodes
// (实验性功能's 试用新对话页) and on the old page it replaces, the same press in the same window: what the heaviest frame
// does on each, counted alike. The old page builds its list as an old view (a Ctx, built whole as a frame builds it)
// and the new one makes it as nodes (the window's tree), so each is counted as both: nodes made in the tree and the
// old view's nodes built over what the shell's old islands build at rest (`Δctx`), and laid out the same way.

///|
/// What one frame did, counted for both pages alike: the tree's nodes made, let go, laid out, words measured,
/// bindings run and layout passes; the old view's nodes built and laid out.
#derive(Debug)
struct VsFrame {
  made : Int
  let_go : Int
  laid : Int
  measured : Int
  bindings : Int
  passes : Int
  old_nodes : Int
  old_laid : Int
}

///|
/// A window to open the chat in: name, width, height, platform (2 a phone's touch, 0 a Mac's pointer).
let chat_vs_windows : Array[(String, Double, Double, Int)] = [
  ("phone", 360.0, 740.0, 2),
  ("plp_narrow", 412.0, 915.0, 2),
  ("tape", 720.0, 840.0, 2),
  ("wide", 1280.0, 800.0, 0),
]

///|
/// The chat as the real size has it (`card`: its last two messages and the token's ask over them) or as it stood just
/// before them (`md`): its foot a run of people's words and the agent's Markdown (a heading, a list, code).
fn chat_vs_cut(v : Json, card : Bool) -> Json {
  guard !card && v is Object(o) && o.get("messages") is Some(Array(ms)) && o.contains("asks") else { return v }
  let kept = ms.filter(fn(m) {
    match m {
      Object(mo) =>
        match mo.get("seq") {
          Some(Number(s, ..)) => s < 299.0
          _ => true
        }
      _ => true
    }
  })
  let out = o.copy()
  out["messages"] = Json::array(kept)
  out["asks"] = Json::array([])
  out["decision"] = Json::null()
  Json::object(out)
}

///|
/// `src` with each chat's value cut as `chat_vs_cut` says, the same value as long as its version is (so what reads it
/// takes it as no change).
fn chat_vs_source(src : Source, card : Bool) -> Source {
  if card {
    return src
  }
  let cut : Map[String, (Int, Json)] = Map([])
  {
    ..src,
    topic_read: fn(name, params) {
      let t = (src.topic_read)(name, params)
      match t.value {
        Some(v) => {
          let key = name + "\u{1}" + Json::object(params).stringify()
          match cut.get(key) {
            Some((ver, cv)) if ver == t.version => { ..t, value: Some(cv) }
            _ => {
              let cv = chat_vs_cut(v, false)
              cut[key] = (t.version, cv)
              { ..t, value: Some(cv) }
            }
          }
        }
        None => t
      }
    },
  }
}

///|
/// The chat of real size opened, then Home (back), then the same chat again, in window `win`, on the page made as
/// nodes (`nodes`) or the old one, its foot as `card` says, with motion as a device has it by default (`motion`: the
/// pages going and coming over each other) or reduced: each frame of the opening again, the shell's old view counted at
/// rest before it (nodes, laid) as the last frame at Home that built it had them.
fn chat_vs_again(
  win : (String, Double, Double, Int),
  nodes : Bool,
  card : Bool,
  motion? : Bool = false,
) -> (Array[VsFrame], (Int, Int)) raise {
  let (_, w, h, platform) = win
  let src : Ref[Source?] = Ref(None)
  let made = fn() {
    match src.val {
      Some(s) => s
      None => {
        reset()
        @sfbase.chat_page_nodes.set(nodes)
        // (its composer made as nodes too, 试用新输入框: what the bars below were raised for)
        @sfbase.composer_nodes.set(nodes)
        // (Home as these bars were counted on it, its 看板 key on: 实验性功能's 对话列表看板视图, off by default since, takes
        // the key off Home under both pages alike)
        @sfbase.board_feature.set(true)
        let c = @sfrealsize.RealSizeChanging::new()
        let s = @sffixture.round_trip_again(
          chat_vs_source(c.source(@sffixture.fixture("chat")), card),
          0.0,
          delta_of=fn(name, params) { c.last_ops(name, params) },
        )
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
    env=if motion { [("MBUI_LOCALE", "zh")] } else { [("MBUI_LOCALE", "zh"), ("MBUI_REDUCE_MOTION", "1")] },
  )
  t.run_for(squeeze_opening)
  t.frame()
  guard app.nav.top() is Chat(r) else { fail("not on the chat") }
  let frames : Array[VsFrame] = []
  let last_tree = fn() {
    let j = @ui.journal()
    let mut i = j.length() - 1
    while i >= 0 {
      match j[i] {
        Work({ what: Frame(f), .. }) => return Some(f)
        _ => ()
      }
      i -= 1
    }
    None
  }
  t.each_frame(
    Some(fn() {
      let p = t.frame_perf()
      match last_tree() {
        Some(f) =>
          frames.push({
            made: f.made,
            let_go: f.let_go,
            laid: f.laid,
            measured: f.measured,
            bindings: f.bindings,
            passes: f.passes,
            old_nodes: p.nodes,
            old_laid: p.laid,
          })
        None => ()
      }
    }),
  )
  // (back to Home, the chat held by the core's client)
  app.nav.pop() |> ignore
  t.run_for(squeeze_opening)
  // (the shell's old view at rest: as the last frame at Home that built it had it)
  let mut idle = (0, 0)
  for f in frames {
    if f.old_nodes > 0 {
      idle = (f.old_nodes, f.old_laid)
    }
  }
  frames.clear()
  @ui.view_tree().unwrap().event(t.time(), fn() { open_page(Chat(r)) })
  t.run_for(squeeze_opening)
  t.each_frame(None)
  assert_true(app.nav.top() is Chat(_), msg="the chat again")
  (frames, idle)
}

///|
/// A frame's work counted alike on both pages: (nodes, laid) = the tree's and the old view's over its rest.
fn chat_vs_work(f : VsFrame, idle : (Int, Int)) -> (Int, Int) {
  let old_n = if f.old_nodes > idle.0 { f.old_nodes - idle.0 } else { 0 }
  let old_l = if f.old_laid > idle.1 { f.old_laid - idle.1 } else { 0 }
  (f.made + old_n, f.laid + old_l)
}

///|
/// The most of each count of `frames`, each on its own (counted alike: nodes, laid out), and the frame each is of: the
/// frame that made the most may not be the one that laid out the most (one after a page has come, making nothing and
/// laying out all of it again).
fn chat_vs_heaviest(frames : Array[VsFrame], idle : (Int, Int)) -> ((VsFrame?, VsFrame?), (Int, Int)) {
  let mut most_nodes : VsFrame? = None
  let mut most_laid : VsFrame? = None
  let mut work = (0, 0)
  for f in frames {
    let w = chat_vs_work(f, idle)
    if most_nodes is None || w.0 > work.0 {
      most_nodes = Some(f)
      work = (w.0, work.1)
    }
    if most_laid is None || w.1 > work.1 {
      most_laid = Some(f)
      work = (work.0, w.1)
    }
  }
  ((most_nodes, most_laid), work)
}

///|
/// What frame `f` of the tree did, for a log.
fn chat_vs_tree(f : VsFrame?) -> String {
  match f {
    Some(f) => "made \{f.made} let_go \{f.let_go} laid \{f.laid} measured \{f.measured} bindings \{f.bindings} passes \{f.passes} old \{f.old_nodes}/\{f.old_laid}"
    None => "none"
  }
}

///|
/// Each window's and foot's opening again (chat_vs_again) on both pages, with motion as `motion` says, against `bars`:
/// what is over its bar.
fn chat_vs_over(bars : Map[String, (Int, Int)], motion : Bool) -> Array[String] raise {
  let wrong : Array[String] = []
  let how = if motion { "moving" } else { "reduced" }
  for win in chat_vs_windows {
    for card in [true, false] {
      let foot = if card { "card" } else { "md" }
      let key = "\{win.0} \{foot}"
      let (old_frames, old_idle) = chat_vs_again(win, false, card, motion~)
      let (_, old) = chat_vs_heaviest(old_frames, old_idle)
      let (new_frames, new_idle) = chat_vs_again(win, true, card, motion~)
      let ((most_nodes, most_laid), new) = chat_vs_heaviest(new_frames, new_idle)
      println(
        "chat vs \{how} \{key}: old \{Repr(old)} new \{Repr(new)} (new's most nodes: \{chat_vs_tree(most_nodes)}; most laid: \{chat_vs_tree(most_laid)}) thousandths \{if old.0 > 0 { new.0 * 1000 / old.0 } else { 0 }}/\{if old.1 > 0 { new.1 * 1000 / old.1 } else { 0 }}",
      )
      let bar = bars.get(key).unwrap_or((0, 0))
      if new.0 * 1000 > bar.0 * old.0 || new.1 * 1000 > bar.1 * old.1 {
        wrong.push("\{how} \{key}: new \{Repr(new)} over \{Repr(bar)} thousandths of old \{Repr(old)}")
      }
    }
  }
  wrong
}

///|
/// How much more the page made as nodes may do than the old one, opening a chat again (chat_vs_again), in thousandths
/// of the old one's (nodes, laid out), by window and foot: a bar that only falls. Why a bar of each and not one share
/// for all: the old page keeps the rows its list built the last time (an old list's kept rows, built again for
/// nothing), so how far the new is from it is what each window shows of the chat, not one number; each is held where
/// it is now so that what makes the new page do more is found where it is written, and what makes it do less brings
/// its bar down. Counted 2026-11-16 once a row's flash and its menu's band are its own ground, its line and middle one
/// node, an agent's own picture holds no place's corner and a chooser's menu is held in its layer only once it opens;
/// before that the new page did 15 to 34 nodes and 12 to 31 laid out more in each
/// (on main f8bd4d0728: phone card 358/258, md 482/361; plp_narrow 366/273, 602/450; tape 799/617, 1035/794; wide
/// 913/916, 1097/1057), over all of these. Again once a table's cells are made with fewer nodes (its rules no
/// structure, no pick where it is not shown smaller): before that md's 1828, 2272, 1420 and 1285 of the old one's
/// nodes; the same at every rate of frames (60, 120, 24, 7), each bar the least that holds it, rounded up. Again once a
/// paragraph with no link holds no room for its links' cards (sf words_links_node): before that phone card's 2744 and
/// md's 1808 of the old one's nodes, its laid out bars loose (1230, 998) and brought to what is laid out now. Wide's laid
/// out more (card 1115, md 1073 before) once the sidebar's foot is made as nodes (lists_foot_node): the new page laid
/// out as before, the old one's old views a node less, its foot no old view of the shell's any more. Phone's and
/// plp_narrow's laid out more (895, 939, 928, 885 before) once Home's transfers key is made as nodes (sfdesk
/// transfers_key_node), not an old view of Home's: the new page laid out as before, the old one's opening, Home's old
/// views a node less, laying out 4 fewer; the same at 60, 120, 24 and 7.
/// Again 2026-11-16 for phone's and plp_narrow's laid out, nothing laid out more: the chat's page made as nodes kept off the
/// screen at Home after it (its agent's line stepping on, 350 ms after Home came to rest) now draws a frame there as the old
/// page always did, so both are counted over the same rest (the shell's old view laying out 2, where the last frame of the
/// nodes' had been the slide's end, laying out 70): the same laid out of the page and the shell's old view now counted as
/// the old page's are (before: 903, 952, 934, 890); plp_narrow md's nodes 2217 (2216 before) where the old page builds one
/// node less, the page as nodes making 552 for 554.
/// Phone md's and plp_narrow md's laid out more (1038, 934 before) once Home's list's faces are fewer boxes (sfpages
/// row_aside_node: the ground round them and who started it ringed, rings of the face's own): nothing of the new page
/// changed, the old one's opening, Home's list going under it, laying out fewer; phone card's and plp_narrow card's
/// brought down to what is laid out now.
/// Each brought down, 2026-11-17, to the most of the five rates, once a message's time is its words' own node and an
/// avatar over a row one node with its layer (measured again after main's).
/// Phone's and plp_narrow's laid out raised, 2026-11-17 (card 968, 978; md 931 before), phone md's brought down (1054
/// before), once 小屏 Home's list no longer opens under what is left up long (moved into 待处理): a screen's more of its
/// rows laid out under both pages alike (146 more of each, the same at the five rates), nothing of either page changed;
/// each rounded up.
/// Wide md's up (1245, 1062 before) once a code block's keys float over its top right with a mouse, no bar of their own
/// over the code (the user, 2026-11-17: 「hover 才显示，不占空间」): each block 38 lower, what shows holds more of the
/// chat, the page as nodes making and laying out more of it (with a spacer as tall as the bar in the keys' place, a
/// block makes fewer nodes than it did), the old page fewer.
/// Each card's nodes raised, 2026-11-17 (phone 2613, plp_narrow 2646, tape 1318, wide 1254; moving phone 1639,
/// plp_narrow 1658 before; wide md's 1305 in both), once what lights a message whole is the list's band, drawn under all its rows once
/// (View::scrolls_window's `bands`): its each's slot one node more of the page, its rows' grounds bound no more.
/// Again 2026-11-17 once the chat's composer is made as nodes on the new page (sfpages composer_node, in its list's
/// foot; 试用新输入框, on here), the old page's still an old view: on the old page it is built as the shell's old islands
/// are at rest at Home (none of it over `idle`), on the new one its nodes at rest are made, so the new page counts what
/// it made where it counted none (phone card's, plp_narrow card's, tape card's and wide card's nodes up: 2621, 2654,
/// 1319 and 1256 before), and lays out less; every bar brought to what is counted now, rounded up, the most of the
/// default rate and 60, 120, 24 and 7: before it (2621, 979), (1707, 930), (2654, 983), (2125, 943), (1319, 1184),
/// (1368, 1150), (1256, 1110), (1306, 1097).
let chat_vs_bars : Map[String, (Int, Int)] = {
  "phone card": (2768, 930),
  "phone md": (1408, 884),
  "plp_narrow card": (2792, 944),
  "plp_narrow md": (1856, 905),
  "tape card": (1347, 1126),
  "tape md": (1272, 1014),
  "wide card": (1281, 1071),
  "wide md": (1218, 996),
}

///|
test "a real chat opened again from Home: the page made as nodes does no more against the old one, counted alike, than its bar" {
  let wrong = chat_vs_over(chat_vs_bars, false)
  assert_true(wrong.is_empty(), msg=wrong.join(" | "))
}

///|
/// chat_vs_bars' with motion as a device has it by default (`MBUI_REDUCE_MOTION` not said): the page going and the one
/// coming drawn over each other as it comes, the old shell's islands with them. A bar that only falls. Counted
/// 2026-11-16 at the default rate and at 60, 120, 24 and 7 frames a second, the most of those (only what is laid out
/// differs: phone's 1128 and 1077, plp_narrow md's 1071 at the default rate, 967, 903 and 1006 at the others), once a
/// table's cells are made with fewer nodes: before that md's 1419, 1750, 1419 and 1284 of the old one's nodes. Again
/// once a paragraph with no link holds no room for its links' cards: before that 1721, 1405, 1759, 1736 of phone's and
/// plp_narrow's (the most of the five rates, each rounded up). Wide's laid out more (1115, 1073 before) once the
/// sidebar's foot is made as nodes, as chat_vs_bars' are. Phone card's and plp_narrow md's laid out more (1121, 1051
/// before) once Home's transfers key is made as nodes, as chat_vs_bars' are: the most of the five rates, the default's.
/// Phone card's and plp_narrow md's laid out more again (1135, 1060 before) once Home's list's faces are fewer boxes, as
/// chat_vs_bars' phone md, nothing of the new page changed; the most of the five rates, the default's, rounded up.
/// Each brought down, 2026-11-17, as chat_vs_bars' are. Then plp_narrow card's laid out raised (978 before) and the
/// others' brought down (1182, 1045, 1132 before), as chat_vs_bars' are once 小屏 Home's list no longer opens under what
/// is left up long: the most of the five rates, the default's, each rounded up.
/// Each brought down, 2026-11-17, as chat_vs_bars' are. Wide md's up as chat_vs_bars' (1245, 1062 before): a code
/// block's keys over its code with a mouse, more of the chat shown.
/// Each brought down, 2026-11-17, as chat_vs_bars' are.
/// Again 2026-11-17 once the chat's composer is made as nodes, as chat_vs_bars' are (phone card's, tape card's and wide
/// card's nodes up: 1643, 1319 and 1256 before); every bar brought to what is counted now, rounded up, the most of the
/// five rates: before it (1643, 979), (1329, 936), (1662, 983), (1639, 943), (1319, 1184), (1368, 1150), (1256, 1110),
/// (1306, 1097).
let chat_vs_motion_bars : Map[String, (Int, Int)] = {
  "phone card": (1645, 930),
  "phone md": (1051, 884),
  "plp_narrow card": (1659, 944),
  "plp_narrow md": (1384, 905),
  "tape card": (1347, 1126),
  "tape md": (1272, 1014),
  "wide card": (1281, 1071),
  "wide md": (1218, 996),
}

///|
test "a real chat opened again from Home with motion: the page made as nodes does no more against the old one, counted alike, than its bar" {
  let wrong = chat_vs_over(chat_vs_motion_bars, true)
  assert_true(wrong.is_empty(), msg=wrong.join(" | "))
}
