///|
test "the log goes on from what it keeps" {
  let log = EventLog::new("ab")
  let first = log.append("e", "{}", Null, 0)
  inspect(first.text, content="id: ab.1\nevent: e\ndata: {}\n\n")
  inspect(log.has("ab.0"), content="true")
  inspect(log.has("ab.2"), content="true")
  inspect(log.has("ba.1"), content="false")
  inspect(
    @readops.model_key("anthropic/claude-opus-5-5[1m]"),
    content="claude-opus-5-5[1m]",
  )
}
