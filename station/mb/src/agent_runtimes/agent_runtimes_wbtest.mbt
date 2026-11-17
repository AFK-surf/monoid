///|
test "numbers and times as JavaScript says them" {
  inspect(to_fixed(1794883188.9025, 6), content="1794883188.902500")
  inspect(to_fixed(0.5, 0), content="1")
  inspect(to_fixed(-1.005, 2), content="-1.00")
  inspect(to_fixed(1.0e21, 2), content="1e+21")
  inspect(iso_date(0.0), content="1970-01-01T00:00:00.000Z")
  inspect(iso_date(1794883188902.9), content="2026-11-17T02:39:48.902Z")
  inspect(iso_date(-1.0), content="1969-12-31T23:59:59.999Z")
  inspect(iso_date(8.64e15), content="+275760-09-13T00:00:00.000Z")
  inspect(utf8_length("a中😀"), content="8")
  inspect(js_less("B", "a"), content="true")
  inspect(js_less("ab", "a"), content="false")
}

///|
test "a session's steps: what is written, and a turn not started twice" {
  let s = Bridged::new("dsh", "s-1", idle_turn("dsh"), Null, "r")
  s.own.uuids.push("u1")
  inspect(s.prompt("hi"), content="None")
  inspect(s.prompt("again"), content="Some(a turn is already running)")
  inspect(
    stringify(Arr(s.own.trace)),
    content=(
      #|[{"tell":"begin"},{"write":"{\"id\":\"prompt:u1\",\"op\":\"prompt\",\"text\":\"hi\"}"}]
    ),
  )
}

///|
test "the agents' home: a change while a round runs makes one more after it" {
  let h = AgentHome::new()
  h.changed()
  h.changed()
  h.flush()
  inspect(h.rounds, content="1")
  h.ended()
  inspect(h.rounds, content="2")
  h.close()
  h.changed()
  h.ended()
  inspect(h.rounds, content="2")
}
