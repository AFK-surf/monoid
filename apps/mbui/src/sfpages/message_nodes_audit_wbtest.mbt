// What the chat's rows made as nodes draw where they drew nothing or made themselves again for nothing: a vault item's
// request asking for a file to be picked (message_cards_node.mbt, settings' vault_foot_node), what was sent from here
// still going up (message_outbox_node.mbt's outbox_uploads_node), a message's picture and video as the width the list
// is given changes (message_files_node.mbt: bound, never made again).

///|
/// The agent's post asking to keep a file in the vault, its card the request as the core says it (vaultAsk), the
/// file the person's to pick (`typed`).
fn audit_vault_file_post() -> Message {
  card_said_then({
    "id": 9,
    "seq": 9,
    "thread": 7,
    "ts": "ts9",
    "authorKind": "agent",
    "author": "codex",
    "text": "把部署密钥存进 vault",
    "by": { "name": "Codex", "agent": "s-c1" },
    "card": {
      "type": "vault",
      "vault": "r-9",
      "vaultAsk": { "name": "deploy key", "reason": "部署要用", "save": { "kind": "file", "typed": true } },
    },
    "createdAt": 9,
  })
}

///|
test "a vault item's request asking for a file to be picked is drawn in its post's words' place: what is asked, 选择文件, 存入 and 不存; picked, its name and size beside the button; 存入 sends it with its name" {
  let calls : Array[(String, Json)] = []
  let m = audit_vault_file_post()
  assert_eq(agent_card_kind(m), "vault")
  let t = card_new(760.0, card_src("chat", calls~), fn() { m })
  t.run_for(@ui.move_most_ms)
  // (its card, not nothing: the button that picks the file, 存入 (not yet: nothing picked) and 不存)
  assert_true(t.find("选择文件") is Some(_), msg="the file's button")
  assert_true(t.find("存入") is Some(_), msg="存入")
  assert_true(t.find("不存") is Some(_), msg="不存")
  assert_true(t.get(Button, label="存入").disabled, msg="nothing picked yet")
  // (the system's picker gives deploy.pem: its name and size beside the button)
  t.picks([("deploy.pem", b"abc")])
  t.click(Button, label="选择文件")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("deploy.pem · 3 B") is Some(_), msg="what was picked")
  assert_false(t.get(Button, label="存入").disabled, msg="picked: 存入")
  t.click(Button, label="存入")
  t.run_for(@ui.move_most_ms)
  let made = calls.filter(fn(c) { c.0 == "vault.approve" })
  assert_eq(made.length(), 1)
  let p = Some(made[0].1)
  assert_eq(text(p, "request"), "r-9")
  assert_eq(text(field(p, "typed"), "secret"), "YWJj")
  assert_eq(text(field(p, "typed"), "filename"), "deploy.pem")
  card_audit(t, "a file picked", 0)
}

///|
/// What was sent from here still going up (`uploads`), `state` as the core says it, with words `text` ("" none).
fn audit_uploading(state : String, text : String, error? : String = "") -> Outgoing {
  let view = @sfbase.chat_view_made({
    "title": "发布",
    "messages": [],
    "outbox": [
      {
        "id": "o-1",
        "text": Json::string(text),
        "state": Json::string(state),
        "error": Json::string(error),
        "createdAt": 0,
        "uploads": [{ "name": "发布说明.pdf", "size": 2048, "sent": 1024 }, { "name": "日志.zip", "size": 4096, "sent": 0 }],
      },
    ],
  })
  view.outbox[0]
}

///|
test "what was sent from here with files still going up: each a card, how far it has gone up, with words and without; not sent, why on each" {
  for text in ["这两个文件给你", ""] {
    let t = out_new(760.0, dec_src(@signals.signal(None), []), fn() { audit_uploading("sending", text) })
    t.run_for(sending_shows_ms)
    assert_true(t.find("正在上传 50% · 2 KB") is Some(_), msg="how far the first has gone up, words \"\{text}\"")
    assert_true(t.find("正在上传 0% · 4 KB") is Some(_), msg="how far the second has gone up, words \"\{text}\"")
    assert_true(t.query(Group, label="发布说明.pdf") is Some(_), msg="the first's card, words \"\{text}\"")
    assert_true(t.query(Group, label="日志.zip") is Some(_), msg="the second's card, words \"\{text}\"")
    dec_audit(t, "going up, words \"\{text}\"")
  }
  let t = out_new(390.0, dec_src(@signals.signal(None), []), fn() {
    audit_uploading("failed", "", error="连不上 Willow")
  })
  t.run_for(sending_shows_ms)
  assert_true(t.query(Group, label="发布说明.pdf") is Some(_), msg="not sent: its card")
  assert_true(t.find("连不上 Willow") is Some(_), msg="not sent: why")
  dec_audit(t, "not sent")
}

///|
/// A picture and a video of a message's (`files_place`'s), in a column as wide as `width` says as it changes: files its
/// station has none of (no picture decoded: what is looked at is their boxes).
fn audit_media_by_width(width : @signals.Signal[Double]) -> @ui.Tester {
  let list = [
    attachment_of({ "name": "here.png", "path": "/tmp/audit-none.png", "size": 24680, "width": 800, "height": 600 }),
    attachment_of({
      "name": "clip.mp4",
      "path": "/tmp/audit-none.mp4",
      "size": 246800,
      "width": 1280,
      "height": 720,
      "duration": 12,
    }),
  ]
  let t = @ui.Tester::new(
    fn(c) {
      @sf.begin(c) |> ignore
      c.with_theme(@sf.ui_theme(), fn() { @ui.old_views_here(c) })
    },
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      let col = root.box(fn(v) { v.width(By(fn() { Some(width.get()) })) |> ignore })
      let popup = root.box(fn(v) { v.over(Is(true)) |> ignore })
      let tips = @sf.TipLayer::new(fn() { Some(popup) })
      message_files_node(col, files_src(), tips, files_place(), fn() { list }, fn() { false }, fn() {
        None
      }, fn() { "" })
    },
    w=940.0,
    h=900.0,
    platform=0,
  )
  t.draw()
  t
}

///|
/// What is pressed at (`x`, `y`) of the window now: the node that takes it.
fn audit_pressed_at(x : Double, y : Double) -> @view.NodeId? {
  match @ui.view_tree().unwrap().target_at(x, y) {
    Pressed(id) | Dragged(id) => Some(id)
    _ => None
  }
}

///|
test "a message's picture and video as the width given goes from 900 down to 160: the same nodes all the way, only their size following it" {
  let width = @signals.signal(900.0)
  let t = audit_media_by_width(width)
  t.run_for(@ui.move_most_ms)
  let tree = @ui.view_tree().unwrap()
  // (where the picture is: its box, read out 查看 here.png, pressed there)
  let (px, py, _, _) = t.query(Button, has="here.png").unwrap().rect
  let (x, y) = (px + 6.0, py + 6.0)
  let picture = audit_pressed_at(x, y)
  assert_true(picture is Some(_), msg="the picture takes a press")
  let alive = tree.alive()
  let mut w = 900.0
  while w > 160.0 {
    w = w - 20.0
    width.set(w)
    t.run_for(@ui.move_most_ms)
    assert_true(audit_pressed_at(x, y) == picture, msg="the picture's node at \{w}")
    assert_eq(tree.alive(), alive, msg="nothing made again at \{w}")
  }
  t.run_for(@ui.move_most_ms)
  // (narrower than it is at its largest: as wide as what holds it now, still pressed where it is)
  let (_, _, now_w, _) = t.query(Button, has="here.png").unwrap().rect
  assert_true(now_w <= 160.5, msg="the picture no wider than what holds it at 160: \{now_w}")
  assert_eq(t.audit(), [])
}
