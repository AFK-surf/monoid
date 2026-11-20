// What a take of mbui's lets be (receive_ahead): a topic's value, or what changed of it, that a whole value of its
// topic later in the same take undoes, never read; what reads it seeing what it would have, as one change.

///|
/// A subscription of the app's client to a topic of `items` kept by `k`, its first value come: its id.
fn voided_sub(topic : String) -> (Sub, Int) raise {
  let s = client.subscribe(topic)
  let id = s.id
  assert_true(receive_said("{\"id\":\{id},\"value\":{\"n\":0,\"items\":[{\"k\":1,\"t\":\"a\"},{\"k\":2,\"t\":\"b\"}]}}", None))
  (s, id)
}

///|
/// What changed of subscription `id`: item `k` 1's words set to `t`.
fn voided_delta(id : Int, t : String) -> String {
  "{\"id\":\{id},\"delta\":[{\"path\":[\"n\"],\"set\":1},{\"path\":[\"items\"],\"key\":[\"k\"],\"patch\":1,\"ops\":[{\"path\":[\"t\"],\"set\":\"\{t}\"}]}]}"
}

///|
/// What changed of subscription `id`, its head the core's and its body none JSON reads: read, it is no message.
fn voided_unreadable(id : Int) -> String {
  "{\"id\":\{id},\"delta\":[{\"path\":"
}

///|
/// A whole value of subscription `id`.
fn voided_whole(id : Int) -> String {
  "{\"id\":\{id},\"value\":{\"n\":9,\"items\":[{\"k\":2,\"t\":\"b\"},{\"k\":3,\"t\":\"c\"}]}}"
}

///|
/// One take: `texts` shown ahead, then each offered as it comes, in one batch of signals (mbui's view_event): what each
/// answered.
fn voided_take(texts : Array[String]) -> Array[Bool] {
  @signals.start_batch()
  receive_ahead(texts.map(fn(t) { Some((t, None)) }))
  let out = texts.map(fn(t) { receive_said(t, None) })
  @signals.end_batch()
  out
}

///|
fn voided_items(s : Sub) -> Array[String] {
  let l = s.keyed("items", ["k"])
  l.peek_keys().map(fn(k) { k + "=" + l.peek(k).map(fn(j) { j.stringify() }).unwrap_or("-") })
}

///|
test "what a whole value later in the take undoes is never read, what reads it sees the whole value" {
  serve(fn(_) {  }) |> ignore
  let (s, id) = voided_sub("chats")
  let l = s.keyed("items", ["k"])
  let w = @signals.watch(fn() {  })
  w.read(fn() { l.get("1") }) |> ignore
  let changes = @signals.watch(fn() {  })
  changes.read(fn() { s.changes.get() }) |> ignore
  // (two none could read: let be unread all the same, the whole value after them taken)
  assert_eq(voided_take([voided_unreadable(id), voided_unreadable(id), voided_whole(id)]), [true, true, true])
  assert_eq(voided.length(), 0)
  assert_eq(s.value.map(fn(v) { v.stringify() }), Some("{\"n\":9,\"items\":[{\"k\":2,\"t\":\"b\"},{\"k\":3,\"t\":\"c\"}]}"))
  assert_eq(voided_items(s), ["2={\"k\":2,\"t\":\"b\"}", "3={\"k\":3,\"t\":\"c\"}"])
  assert_true(w.is_stale())
  assert_true(changes.is_stale())
  serve_end()
}

///|
test "what a take lets be leaves its topic and its keyed list as read one by one would" {
  serve(fn(_) {  }) |> ignore
  let (one, a) = voided_sub("chats")
  let (all, b) = voided_sub("stations")
  voided_items(one) |> ignore
  voided_items(all) |> ignore
  // (the same messages, one subscription's taken one by one, the other's in a take)
  for t in [voided_delta(a, "x"), voided_delta(a, "y"), voided_whole(a)] {
    assert_true(receive_said(t, None))
  }
  assert_eq(voided_take([voided_delta(b, "x"), voided_delta(b, "y"), voided_whole(b)]), [true, true, true])
  assert_eq(all.value.map(fn(v) { v.stringify() }), one.value.map(fn(v) { v.stringify() }))
  assert_eq(voided_items(all), voided_items(one))
  serve_end()
}

///|
test "what lies between a message let be and its whole value is taken as it comes, in its place" {
  serve(fn(_) {  }) |> ignore
  let (s, a) = voided_sub("chats")
  let (o, b) = voided_sub("stations")
  assert_eq(voided_take([voided_unreadable(a), voided_delta(b, "z"), voided_whole(a)]), [true, true, true])
  assert_eq(s.value.map(fn(v) { v.stringify() }), Some("{\"n\":9,\"items\":[{\"k\":2,\"t\":\"b\"},{\"k\":3,\"t\":\"c\"}]}"))
  assert_eq(o.value.map(fn(v) { v.stringify() }), Some("{\"n\":1,\"items\":[{\"k\":1,\"t\":\"z\"},{\"k\":2,\"t\":\"b\"}]}"))
  serve_end()
}

///|
test "nothing is let be across what is not a topic's value, nor before its first, nor outside one change" {
  serve(fn(_) {  }) |> ignore
  let (_, a) = voided_sub("chats")
  // (an error between: read, the delta before it fails to read and is left for the frame)
  let err = "{\"id\":\{a},\"error\":{\"code\":\"x\"}}"
  assert_eq(voided_take([voided_unreadable(a), err, voided_whole(a)]), [false, true, true])
  // (another channel's message between: none let be)
  let u = voided_unreadable(a)
  let w = voided_whole(a)
  @signals.start_batch()
  receive_ahead([Some((u, None)), None, Some((w, None))])
  assert_false(receive_said(u, None))
  @signals.end_batch()
  // (outside a batch of signals: what reads it would see each)
  receive_ahead([Some((u, None)), Some((w, None))])
  assert_false(receive_said(u, None))
  // (its first message: what reads the kept value and ends its wait, read)
  let s = client.subscribe("usage")
  let first = "{\"id\":\{s.id},\"value\":{\"n\":0,\"items\":[]}}"
  assert_eq(voided_take([first, voided_whole(s.id)]), [true, true])
  assert_eq(s.version, 2)
  // (while a conversation is recorded: each read, as its trace says it)
  tracer.val = Some(fn(_) {  })
  assert_eq(voided_take([voided_unreadable(a), voided_whole(a)]), [false, true])
  tracer.val = None
  serve_end()
}

///|
test "what was let be and is not undone after all is taken first, in the order it came" {
  serve(fn(_) {  }) |> ignore
  let (s, a) = voided_sub("chats")
  let x = voided_delta(a, "x")
  @signals.start_batch()
  receive_ahead([Some((x, None)), Some((voided_whole(a), None))])
  assert_true(receive_said(x, None))
  assert_eq(voided.length(), 1)
  // (another message for it than the take said: the one let be taken before it)
  assert_true(receive_said(voided_delta(a, "y"), None))
  @signals.end_batch()
  assert_eq(voided.length(), 0)
  assert_eq(s.value.map(fn(v) { v.stringify() }), Some("{\"n\":1,\"items\":[{\"k\":1,\"t\":\"y\"},{\"k\":2,\"t\":\"b\"}]}"))
  assert_eq(s.version, 3)
  serve_end()
}
