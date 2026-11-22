// What a chat's card holds as nodes (peeks_chat_node.mbt's chat_card_node) set beside the old view's (peeks.mbt
// chat_card) in the same room, as the same core reads the link and the list: the words where they were and the
// rectangles drawn the same, in each state it shows (a chat alone, where it stands; the one message its link names,
// said, read, gone; its agent's execution history; another station's; one archived; one gone; its bones while the link
// is read; its bones while its whole row is read); and a chat the workspace's list does not show (one another chat
// leads, one hidden, one far down) found by its whole row alone, the list never asked.

///|
/// The source the card reads: the fixture's, the message its link names as `said` says it (its value, its error), the
/// core's reading of links never answered where `parsed` is false, a chat's whole row (`chatRow`) never answered where
/// `whole` is false.
fn pc_src(said : (Json?, Json?), parsed : Bool, whole~ : Bool = true) -> Source {
  @sfbase.reset()
  @sf.set_words(@sfbase.fill)
  // (what the core said of each link, asked again in each: chats_named is kept across runs)
  chats_named.clear()
  pc_asked.clear()
  let made = @sffixture.fixture("rich-chat")
  {
    ..made,
    topic_read: fn(name, params) {
      pc_asked.push(name)
      if name == "messagePeek" {
        let (value, error) = said
        { value, error, version: if value is None && error is None { 0 } else { 1 } }
      } else if name == "chatRow" && !whole {
        { value: None, error: None, version: 0 }
      } else if name == "chatRow" && @settings.text(Some(Json::object(params)), "session") == pc_unlisted {
        // (a chat the list does not show: s-c2's row as another, as the core gives one it reads by its key)
        let of = params.copy()
        of["session"] = Json::string("s-c2")
        let row = match made.topic(name, of).get().value {
          Some(Object(m)) => {
            let r = m.copy()
            r["id"] = Json::string(pc_unlisted)
            r["session"] = Json::string(pc_unlisted)
            r["title"] = Json::string(pc_unlisted_title)
            Some(Json::object(r))
          }
          v => v
        }
        { value: row, error: None, version: if row is None { 0 } else { 1 } }
      } else {
        made.topic(name, params).get().snapshot()
      }
    },
    call: fn(name, params, done) {
      if name == "link.parse" && !parsed {
        ()
      } else {
        (made.call)(name, params, done)
      }
    },
  }
}

///|
/// The topics the card's source was asked, by name, in the order asked.
// kept across runs: cleared as each source is made (pc_src)
let pc_asked : Array[String] = []

///|
/// A chat the workspace's list does not show (its session, its title): one another chat leads (`chat_create`'s
/// `for: me`), one hidden, one far down the list; its whole row the core reads by its key.
let pc_unlisted : String = "s-led"

///|
let pc_unlisted_title : String = "子对话：整理构建日志"

///|
/// The nodes' card (chat_card_node) of `href` read in a chat of `here`, as its message says it (`linked`).
fn pc_new(
  here : String,
  href : String,
  linked : LinkedChat?,
  said : (Json?, Json?),
  parsed : Bool,
  whole : Bool,
) -> @ui.Tester {
  let src = pc_src(said, parsed, whole~)
  let t = @ui.Tester::new(
    fn(c) {
      @sf.begin(c) |> ignore
      c.with_theme(@sf.ui_theme(), fn() { @ui.old_views_here(c) })
    },
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      root.box(fn(f) {
        @sf.style_node(f, fn() { pf_frame })
        f.box(fn(inner) {
          @sf.style_node(inner, fn() { pf_inner })
          chat_card_node(inner, src, "pc-node", here, fn() { href }, fn() { linked })
        })
        |> ignore
      })
      |> ignore
    },
    w=400.0,
    h=720.0,
    native=Mouse,
    pointing=Mouse,
  )
  t.run_for(@ui.move_most_ms)
  t
}

///|
/// Each state, by name: where it is read, its link, its message's saying, what the core says of the message it names,
/// whether the core reads the link, whether it says the chat's whole row.
fn pc_cases() -> Array[(String, String, String, LinkedChat?, (Json?, Json?), Bool, Bool)] {
  let said = (Some(@sffixture.fixture_message_peek()), None)
  let archived : LinkedChat = { href: "", title: "归档的对话", archived: true, note: "已归档", thread: Some(7.0) }
  let base = "https://app.still.fail/o/ws1/st1/"
  [
    ("a chat alone", "ws1/st1", base + "s-c2", None, said, true, true),
    ("one message, said", "ws1/st1", base + "s-c2?message=2", None, said, true, true),
    ("one message, read", "ws1/st1", base + "s-c2?message=2", None, (None, None), true, true),
    ("one message, gone", "ws1/st1", base + "s-c2?message=999", None, (Some(Json::null()), None), true, true),
    ("its agent's execution history", "ws1/st1", base + "s-c2?history=1", None, said, true, true),
    ("another station's", "ws1/st9", base + "s-c2", None, said, true, true),
    ("archived", "ws1/st1", base + "s-old?message=3", Some(archived), said, true, true),
    ("archived, no note", "ws1/st1", base + "s-old", Some({ ..archived, note: "" }), said, true, true),
    ("gone", "ws1/st1", base + "s-nope", None, said, true, true),
    ("the link read", "ws1/st1", base + "s-c2", None, said, false, true),
    ("its whole row read", "ws1/st1", base + "s-c2", None, said, true, false),
  ]
}

///|
test "a chat's card made once as nodes: alone, one message said, read and gone, its history, elsewhere, archived, gone, its bones" {
  for c in pc_cases() {
    let (name, here, href, linked, said, parsed, whole) = c
    let t = pc_new(here, href, linked, said, parsed, whole)
    assert_true(pf_drawn(t).length() > 0, msg=name)
    assert_eq(t.audit(), [], msg=name)
  }
}

///|
test "a chat's card made once as nodes cuts long words: the message its link names on six lines at most, an archived chat's note on three" {
  let long = "这一条消息说得很长很长：列表按天分组已经做好了，今天和昨天之外的日子都写日期；滚动的时候每一帧的耗时都量过了，" +
    "最慢的一帧是在分组的标题刚进来的时候；接下来想把图片的解码挪到后台去，再看看能不能把分组标题做成固定在顶上的样子，" +
    "这样往回翻的时候也知道自己在哪一天；另外搜索结果里的高亮颜色也要改一下，现在在暗色主题里看不太清楚，最后再补几个测试。"
  let message = fixture_message_obj()
  message["text"] = Json::string(long)
  let said = (Some(Json::object(message)), None)
  let archived : LinkedChat = { href: "", title: "归档的对话", archived: true, note: long, thread: None }
  let base = "https://app.still.fail/o/ws1/st1/"
  for c in [
    ("one message, said at length", base + "s-c2?message=2", None),
    ("archived, its note at length", base + "s-old", Some(archived)),
  ] {
    let (name, href, linked) = c
    let t = pc_new("ws1/st1", href, linked, said, true, true)
    let lines = t.lines_of("这一条消息")
    assert_true(lines.length() == (if linked is None { 6 } else { 3 }) && lines[lines.length() - 1].has_suffix("…"), msg="\{name}: \{Repr(lines)}")
  }
}

///|
/// The made-up message its link names (fixture_message_peek's), its fields to be changed.
fn fixture_message_obj() -> Map[String, Json] {
  match @sffixture.fixture_message_peek() {
    Object(m) => m.copy()
    _ => {}
  }
}

///|
test "a chat's card says the chat the workspace's list does not show (one another chat leads, one hidden) by its whole row, never the list" {
  let href = "https://app.still.fail/o/ws1/st1/" + pc_unlisted
  let t = pc_new("ws1/st1", href, None, (None, None), true, true)
  assert_true(pc_says(t, pc_unlisted_title), msg="new: \{Repr(pc_words(t))}")
  assert_false(pc_says(t, @sf.t("web-main.chatRef.previewGone")), msg="new")
  assert_false(pc_asked.contains("chats"), msg="new: \{Repr(pc_asked)}")
  assert_eq(t.audit(), [])
}

///|
test "a chat's card of another workspace's chat says only that it is not in the list, asking nothing of its row" {
  let href = "https://app.still.fail/o/ws2/st1/s-c2"
  let t = pc_new("ws1/st1", href, None, (None, None), true, true)
  assert_true(pc_says(t, @sf.t("web-main.chatRef.previewGone")), msg="\{Repr(pc_words(t))}")
  assert_false(pc_asked.contains("chatRow") || pc_asked.contains("chats"), msg="\{Repr(pc_asked)}")
}

///|
/// The words `t` draws, each run of them as drawn.
fn pc_words(t : @ui.Tester) -> Array[String] {
  t.words().map(fn(w) { w.0 })
}

///|
/// Whether `t` draws `words` (in a run of its words).
fn pc_says(t : @ui.Tester, words : String) -> Bool {
  pc_words(t).iter().any(fn(w) { w.contains(words) })
}
