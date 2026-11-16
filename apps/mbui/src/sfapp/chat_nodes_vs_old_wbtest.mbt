// A chat of real size opened again from Home (or the sidebar) with the chat held, on the chat's page made as nodes
// (外观's 试用新对话页) and on the old page it replaces, the same press in the same window: what the heaviest frame
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
/// nodes (`nodes`) or the old one, its foot as `card` says: each frame of the opening again, the shell's old view
/// counted at rest before it (nodes, laid) as the last frame at Home that built it had them.
fn chat_vs_again(
  win : (String, Double, Double, Int),
  nodes : Bool,
  card : Bool,
) -> (Array[VsFrame], (Int, Int)) raise {
  let (_, w, h, platform) = win
  let src : Ref[Source?] = Ref(None)
  let made = fn() {
    match src.val {
      Some(s) => s
      None => {
        reset()
        @sfbase.chat_page_nodes.set(nodes)
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
    env=[("MBUI_LOCALE", "zh"), ("MBUI_REDUCE_MOTION", "1")],
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
/// The heaviest frame (the most nodes, counted alike) of `frames`, and its count.
fn chat_vs_heaviest(frames : Array[VsFrame], idle : (Int, Int)) -> (VsFrame?, (Int, Int)) {
  let mut most : VsFrame? = None
  let mut work = (0, 0)
  for f in frames {
    let w = chat_vs_work(f, idle)
    if most is None || w.0 > work.0 {
      most = Some(f)
      work = w
    }
  }
  (most, work)
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
/// 913/916, 1097/1057), over all of these.
let chat_vs_bars : Map[String, (Int, Int)] = {
  "phone card": (2744, 1230),
  "phone md": (1828, 998),
  "plp_narrow card": (2808, 1305),
  "plp_narrow md": (2272, 1233),
  "tape card": (1352, 1194),
  "tape md": (1420, 1180),
  "wide card": (1282, 1117),
  "wide md": (1285, 1079),
}

///|
test "a real chat opened again from Home: the page made as nodes does no more against the old one, counted alike, than its bar" {
  let wrong : Array[String] = []
  for win in chat_vs_windows {
    for card in [true, false] {
      let foot = if card { "card" } else { "md" }
      let key = "\{win.0} \{foot}"
      let (old_frames, old_idle) = chat_vs_again(win, false, card)
      let (_, old) = chat_vs_heaviest(old_frames, old_idle)
      let (new_frames, new_idle) = chat_vs_again(win, true, card)
      let (f, new) = chat_vs_heaviest(new_frames, new_idle)
      let tree = match f {
        Some(f) => "made \{f.made} let_go \{f.let_go} laid \{f.laid} measured \{f.measured} bindings \{f.bindings} passes \{f.passes}"
        None => "none"
      }
      println("chat vs \{key}: old \{Repr(old)} new \{Repr(new)} (new's tree: \{tree})")
      let bar = chat_vs_bars.get(key).unwrap_or((0, 0))
      if new.0 * 1000 > bar.0 * old.0 || new.1 * 1000 > bar.1 * old.1 {
        wrong.push("\{key}: new \{Repr(new)} over \{Repr(bar)} thousandths of old \{Repr(old)}")
      }
    }
  }
  assert_true(wrong.is_empty(), msg=wrong.join(" | "))
}
