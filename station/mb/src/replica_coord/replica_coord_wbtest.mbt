// What of the package needs no host: names, the rendezvous order, a stream's hash, the merging of presets, what a
// moved chat is told. The rest is held to the TypeScript through the program (station/test/mb-replica-coord.test.ts).

///|
test "a copy's names" {
  inspect(is_station("a".repeat(64)), content="true")
  inspect(is_station("A".repeat(64)), content="false")
  inspect(is_gen("lz5x0-0123abcd"), content="true")
  inspect(is_gen("LZ-0123abcd"), content="false")
  inspect(is_batch("0000000001-0000000004-00000000.ndjson.zst"), content="true")
  inspect(is_batch("0000000001-0000000004-0000000.ndjson.zst"), content="false")
  inspect(is_workspace("W_1-x"), content="true")
  inspect(is_workspace(""), content="false")
  inspect(is_handover_id("lz5x0-7331-aaaaaaaa-01234567"), content="true")
  inspect(gen_made("lz5x0-0123abcd"), content="36912564")
}

///|
test "the stations that keep a copy are the same whatever their order" {
  let a = "a".repeat(64)
  let b = "b".repeat(64)
  let c = "c".repeat(64)
  let d = "d".repeat(64)
  let one = keepers("W1", a, [a, b, c, d])
  let two = keepers("W1", a, [d, c, b, a, b])
  assert_eq(one, two)
  assert_eq(one.length(), 2)
  assert_true(!one.contains(a))
  assert_eq(keepers("W1", a, [a, b]), [b])
}

///|
test "a hash taken a piece at a time is the whole's" {
  let data = @utf8.encode("the quick brown fox jumps over the lazy dog".repeat(37))
  let h = @hash.Sha256::new()
  h.update(data[0:5])
  h.update(data[5:64])
  h.update(data[64:])
  assert_eq(h.hex(), @memory.sha256_hex(data))
  inspect(@hash.Sha256::new().hex(), content="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
}

///|
test "presets merged: the newer of each, ours first" {
  let ours = parse("{\"presets\":[{\"id\":\"p1\",\"rev\":2,\"name\":\"ours\"}],\"other\":1}")
  let theirs = parse("{\"presets\":[{\"id\":\"p1\",\"rev\":3,\"name\":\"theirs\"},{\"id\":\"p2\",\"name\":\"new\"}],\"gone\":[{\"id\":\"p3\",\"gone\":true}]}")
  let (file, taken) = merge_presets(ours, theirs)
  inspect(taken, content="3")
  inspect(
    stringify(file),
    content="{\"presets\":[{\"id\":\"p1\",\"rev\":3,\"name\":\"theirs\"},{\"id\":\"p2\",\"name\":\"new\"}],\"other\":1,\"gone\":[{\"id\":\"p3\",\"gone\":true}]}",
  )
}

///|
test "numbers said as the TypeScript says them" {
  inspect(base36(1800000000000.0), content="mywpiww0")
  inspect(gb(1073741824.0 * 2.25), content="2.3 GB")
  inspect(backoff(5000.0, 3, 600000.0), content="40000")
  inspect(backoff(5000.0, 30, 600000.0), content="600000")
  inspect(floor_of(Some(500.0 * 1073741824.0)), content="53687091200")
  inspect(floor_of(None), content="21474836480")
  inspect(unanswered("the connection was reset"), content="true")
  inspect(unanswered("refused"), content="false")
}

///|
test "what a store's change tells the export" {
  let t = Told::nothing()
  assert_true(tell(t, parse("{\"type\":\"thread\",\"id\":3,\"entries\":[]}")))
  assert_true(!tell(t, parse("{\"type\":\"nothing\"}")))
  assert_true(tell(t, parse("{\"type\":\"read\",\"viewer\":\"v\",\"thread\":1}")))
  inspect(
    stringify(t.to_json()),
    content="{\"sessions\":[],\"threads\":[3],\"removedSessions\":[],\"removedThreads\":[],\"marks\":[{\"table\":\"reads\",\"key\":{\"viewer\":\"v\",\"thread\":1}}]}",
  )
}

///|
test "connects as they go on the other station" {
  let a = "a".repeat(64)
  let b = "b".repeat(64)
  let out = connects_there(["slack1"], ["ember", "slack1", "x@" + b], a, b)
  assert_eq(out, [("slack1", "slack1@" + a), ("x@" + b, "x")])
}
