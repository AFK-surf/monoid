///|
/// What chat_body_rows_again makes of chat view `v`'s entries `read` from what it made of `v0`'s `read0`, against what
/// chat_body_rows makes of them anew: the same keys in the same order, each the same row (its entry, gap and piece).
fn rows_tail_faults(v0 : ChatView, read0 : Array[Entry], v : ChatView, read : Array[Entry], name : String) -> Array[String] {
  let kept : ChatBodyKept = { sent: {}, sent_as: {}, here: {} }
  let first = chat_body_rows(kept, v0, read0, [])
  let was : ChatBodyMade = { view: v0, all: read0, sending: false, rows: { keys: first.keys.copy(), rows: first.rows } }
  let again = chat_body_rows_again(kept, Some(was), v, read, [])
  let whole = chat_body_rows({ sent: {}, sent_as: {}, here: {} }, v, read, [])
  let faults : Array[String] = []
  if again.keys != whole.keys {
    faults.push("\{name}: keys \{Repr(again.keys)} for \{Repr(whole.keys)}")
  }
  for k in whole.keys {
    match (again.rows.get(k), whole.rows.get(k)) {
      (Some(a), Some(b)) =>
        if !chat_body_row_same(a, b) {
          faults.push("\{name}: row \{k} otherwise")
        }
      _ => faults.push("\{name}: row \{k} missing")
    }
  }
  for k, _ in again.rows {
    if !whole.rows.contains(k) {
      faults.push("\{name}: row \{k} kept that is gone")
    }
  }
  faults
}

///|
/// Where what comes at a chat's end goes among `read`'s entries: after its last message (before where it stands, its
/// agents' lines, its foot).
fn rows_tail_end(read : Array[Entry]) -> Int {
  let mut at = read.length()
  for i, e in read {
    if e is Said(_) {
      at = i + 1
    }
  }
  at
}

///|
test "a chat's rows made again from what came at its end are the rows made anew" {
  @sfbase.reset()
  reset()
  let src = @sffixture.fixture("chat-working")
  let (v0, read0) = body_read(src).unwrap()
  let at = rows_tail_end(read0)
  guard at > 0 && read0[at - 1] is Said(last) else { fail("the chat has no message") }
  // (one in pieces, as an agent's long answer is, where the chat has one: made again as such)
  let long = read0.iter().find_first(fn(e) { chat_body_pieces(e).map(fn(ps) { ps.length() > 1 }).unwrap_or(false) })
  let faults : Array[String] = []
  let come = fn(m : Message, k : Int) -> Message {
    { ..m, seq: m.seq + 1000.0 + k.to_double(), ts: m.ts + ".9\{k}" }
  }
  let plus = fn(ms : Array[Message], m : Message) -> Array[Message] {
    let out = ms.copy()
    out.push(m)
    out
  }
  let with_ = fn(read : Array[Entry], i : Int, es : Array[Entry]) -> Array[Entry] {
    let out = read[0:i].to_owned()
    out.append(es)
    out.append(read[i:].to_owned())
    out
  }
  // a message come at its end
  let m1 = come(last, 1)
  faults.append(
    rows_tail_faults(v0, read0, { ..v0, messages: plus(v0.messages, m1) }, with_(read0, at, [Said(m1)]), "come"),
  )
  // one joined to the one before it, that one followed now
  let m2 = { ..come(last, 2), joined: true }
  let read2 = with_(read0, at, [Said(m2)])
  read2[at - 1] = Said({ ..last, followed: true })
  faults.append(rows_tail_faults(v0, read0, { ..v0, messages: plus(v0.messages, m2) }, read2, "joined"))
  // one in pieces
  match long {
    Some(Said(lm)) => {
      let m3 = come(lm, 3)
      faults.append(
        rows_tail_faults(v0, read0, { ..v0, messages: plus(v0.messages, m3) }, with_(read0, at, [Said(m3)]), "pieces"),
      )
    }
    _ => ()
  }
  // what stood under the last message gone (an agent's line, where it stands)
  let gone = read0.filter(fn(e) { !(e is (State(_, _, _) | Working(_))) })
  faults.append(rows_tail_faults(v0, read0, v0, gone, "gone"))
  // two come, then the same made again from that
  let m4 = come(last, 4)
  let m5 = come(last, 5)
  let read4 = with_(read0, at, [Said(m4)])
  let v4 = { ..v0, messages: plus(v0.messages, m4) }
  faults.append(
    rows_tail_faults(v4, read4, { ..v4, messages: plus(v4.messages, m5) }, with_(read4, at + 1, [Said(m5)]), "twice"),
  )
  assert_eq(faults, [])
}
