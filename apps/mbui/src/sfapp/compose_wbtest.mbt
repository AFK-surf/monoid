// What is written as the core keeps it (sfbase's compose.mbt): over the fixture core's composers
// (compose_fixture.mbt).

///|
test "a draft as the core keeps it: its kept words read back into the field; what is typed told to the core, not taken back from it" {
  fresh_app()
  let src = fixture("chat-compose")
  let w = @sfbase.writing(src, "ws1/st1:s-c1")
  assert_true(w.text.get().has_prefix("把发布清单再过一遍"))
  assert_eq(w.field.text(), w.text.get())
  // typed: the page's at once, the core told; its answer (the same words, no new rev) does not set the field again
  w.field.set("先看第三项")
  @sfbase.writing_text(src, w, "先看第三项")
  let w2 = @sfbase.writing(src, "ws1/st1:s-c1")
  assert_eq(w2.text.get(), "先看第三项")
  assert_eq(text(src.topic("composer", { "key": Json::string("ws1/st1:s-c1") }).get().value, "text"), "先看第三项")
  assert_true(w2.ready.get())
}

///|
test "a draft taken to be sent is empty at once and the core answers what it took; put back, it is there again with why" {
  fresh_app()
  let src = fixture("chat")
  let w = @sfbase.writing(src, "ws1/st1:s-c1")
  @sfbase.writing_text(src, w, "  发一下  ")
  let took : Ref[Json?] = Ref(None)
  @sfbase.writing_take(src, w, fn(a) { took.val = a })
  assert_eq(w.text.get(), "")
  assert_eq(w.field.text(), "")
  assert_eq(text(took.val, "text"), "发一下")
  @sfbase.writing_restore(src, w, "发不出去")
  let w = @sfbase.writing(src, "ws1/st1:s-c1")
  assert_eq(w.text.get(), "  发一下  ")
  assert_eq(w.field.text(), "  发一下  ")
  assert_eq(w.error.get(), "发不出去")
}

///|
test "a draft's quotes: added with the focus on its comment line, said about, let go" {
  fresh_app()
  let src = fixture("chat")
  let w = @sfbase.writing(src, "ws1/st1:s-c1")
  @sfbase.writing_quote(src, w, { "author": "Claude", "text": "其余的行按估计的高度占位", "ts": "ts8" })
  let w = @sfbase.writing(src, "ws1/st1:s-c1")
  assert_eq(w.quotes.get().length(), 1)
  let id = text(Some(w.quotes.get()[0]), "id")
  assert_eq(w.focus.get(), id)
  @sfbase.writing_focused(src, w)
  @sfbase.writing_comment(src, w, id, "这里改成量过再记")
  let w = @sfbase.writing(src, "ws1/st1:s-c1")
  assert_eq(w.focus.get(), "")
  assert_eq(text(Some(w.quotes.get()[0]), "comment"), "这里改成量过再记")
  @sfbase.writing_unquote(src, w, id)
  assert_eq(@sfbase.writing(src, "ws1/st1:s-c1").quotes.get().length(), 0)
}

///|
test "an image of a message quoted is its quote's own picture, not among the files, and goes with it" {
  fresh_app()
  let src = fixture("chat")
  let image : Json = { "name": "shot.png", "path": "/w/uploads/shot.png", "size": 120, "owner": "s-c1" }
  let quote : Json = { "author": "Claude", "text": "shot.png", "ts": "ts8" }
  let w = @sfbase.writing(src, "ws1/st1:s-c1")
  @sfbase.writing_quote(src, w, quote, file=image)
  @sfbase.writing_quote(src, w, quote, file=image)
  let w = @sfbase.writing(src, "ws1/st1:s-c1")
  assert_eq(w.files.get().length(), 0)
  assert_eq(w.quotes.get().map(fn(q) { text(field(Some(q), "own"), "name") }), ["shot.png", "shot.png"])
  @sfbase.writing_unquote(src, w, text(Some(w.quotes.get()[0]), "id"))
  let w = @sfbase.writing(src, "ws1/st1:s-c1")
  assert_eq([w.quotes.get().length(), w.files.get().length()], [1, 0])
  assert_eq(text(field(Some(w.quotes.get()[0]), "own"), "name"), "shot.png")
}

///|
test "what is written in a new chat goes on into the chat it made (composer.carry), the new chat's left empty" {
  fresh_app()
  let src = fixture("chat")
  let w = @sfbase.writing(src, "new:ws1")
  @sfbase.writing_text(src, w, "把发布说明写一下")
  @sfbase.writing_carry(src, "new:ws1", "ws1/st1:s-new")
  assert_eq(@sfbase.writing(src, "ws1/st1:s-new").text.get(), "把发布说明写一下")
  assert_eq(@sfbase.writing(src, "new:ws1").text.get(), "")
}

///|
/// A picture's bytes (a one-pixel PNG), as a file picked here is.
fn compose_png() -> Bytes {
  @pixels.png(1, 1, FixedArray::make(4, b'\xFF'))
}

///|
/// The attachment a message sent from here names its upload `id` by (Attachment.upload).
fn compose_upload(id : String) -> @sfbase.Attachment {
  {
    name: "a.png",
    path: "",
    size: 1.0,
    width: 1.0,
    height: 1.0,
    thumbhash: "",
    owner: "",
    upload: id,
    duration: 0.0,
    frames: 0,
    held: false,
  }
}

///|
test "a picture sent and not taken in is put back whole, its bytes and its picture; taken in, its bytes let go of, its picture kept for its message" {
  fresh_app()
  let src = fixture("chat")
  let key = "ws1/st1:s-c1"
  @sfbase.writing_add(src, @sfbase.writing(src, key), "ws1/st1", "a.png", compose_png())
  let w = @sfbase.writing(src, key)
  let id = text(Some(w.files.get()[0]), "id")
  let picture = "mem:writing/" + id
  assert_eq(@sfbase.writing_picture_told(id), Some(picture))
  // taken, then not taken in (refused): put back whole, the bytes it goes up with again and its picture
  @sfbase.writing_take(src, w, fn(_) {  })
  assert_eq(w.files.get().length(), 0)
  assert_true(@sfbase.writing_went_to(id) is Some(_), msg="kept while it may yet come back")
  @sfbase.writing_restore(src, w, "发不出去")
  let w = @sfbase.writing(src, key)
  assert_eq(w.files.get().map(fn(f) { text(Some(f), "id") }), [id])
  assert_true(@sfbase.writing_went_to(id) is Some((_, "a.png", _)))
  assert_eq(@sfbase.writing_picture_told(id), Some(picture))
  assert_true(@ui.has_image(picture))
  // taken again, and taken in: its bytes let go of, its picture kept for its message
  @sfbase.writing_take(src, w, fn(_) {  })
  @sfbase.writing_committed(w)
  assert_true(w.taken is None)
  assert_true(@sfbase.writing_went_to(id) is None, msg="its bytes let go of")
  assert_true(@sfbase.writing_picture_told(id) is None)
  assert_false(@sfbase.writing_put_here(id))
  assert_true(@ui.has_image(picture), msg="its message is drawn by it")
  assert_eq(@sfbase.sent_picture("ws1/st1", compose_upload(id)), Some(picture))
}

///|
test "pictures of what was sent beyond 64: the least lately kept let go of, a sent draft's picture with them once nothing shows it" {
  fresh_app()
  let src = fixture("chat")
  let key = "ws1/st1:s-c1"
  @sfbase.writing_add(src, @sfbase.writing(src, key), "ws1/st1", "a.png", compose_png())
  let w = @sfbase.writing(src, key)
  let id = text(Some(w.files.get()[0]), "id")
  let picture = "mem:writing/" + id
  @sfbase.writing_take(src, w, fn(_) {  })
  @sfbase.writing_committed(w)
  for i in 0..<64 {
    @sfbase.sent_picture_kept("upload\u{1}other\{i}", "mem:other/\{i}")
  }
  assert_true(@sfbase.sent_picture("ws1/st1", compose_upload(id)) is None, msg="the least lately kept let go of")
  assert_eq(@sfbase.sent_picture("ws1/st1", compose_upload("other63")), Some("mem:other/63"))
  assert_false(@ui.has_image(picture), msg="nothing drawn by it: let go of")
}

///|
test "a picture of a draft still being written is kept, however many pictures of what was sent are let go of" {
  fresh_app()
  let src = fixture("chat")
  let key = "ws1/st1:s-c1"
  @sfbase.writing_add(src, @sfbase.writing(src, key), "ws1/st1", "a.png", compose_png())
  let id = text(Some(@sfbase.writing(src, key).files.get()[0]), "id")
  for i in 0..<70 {
    @sfbase.sent_picture_kept("upload\u{1}other\{i}", "mem:other/\{i}")
  }
  assert_true(@ui.has_image("mem:writing/" + id), msg="its draft's tile shows it")
  assert_true(@sfbase.writing_went_to(id) is Some(_))
}

///|
test "drafts kept beyond 32 let go of, the least lately asked for first, never one taken to be sent and not yet answered" {
  fresh_app()
  let src = fixture("chat")
  @sfbase.writing_text(src, @sfbase.writing(src, "ws1/st1:s-k0"), "第一份")
  let taken = @sfbase.writing(src, "ws1/st1:s-k1")
  @sfbase.writing_text(src, taken, "发出去了")
  @sfbase.writing_take(src, taken, fn(_) {  })
  for i in 2..<40 {
    @sfbase.writing(src, "ws1/st1:s-k\{i}") |> ignore
  }
  assert_true(@sfbase.writings.length() <= 32)
  assert_false(@sfbase.writings.contains("ws1/st1:s-k0"), msg="the least lately asked for let go of")
  assert_true(@sfbase.writings.get("ws1/st1:s-k1") is Some(w) && physical_equal(w, taken), msg="taken: kept")
  assert_true(@sfbase.writings.contains("ws1/st1:s-k39"))
  // (asked for again: made anew from what the core keeps)
  let again = @sfbase.writing(src, "ws1/st1:s-k0")
  assert_eq(again.text.get(), "第一份")
  assert_eq(again.field.text(), "第一份")
}
