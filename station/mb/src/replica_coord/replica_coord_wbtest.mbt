// What of the package needs no host: names, the rendezvous order, a stream's hash, the merging of presets, heads,
// errors, and what a moved chat is told.

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

///|
test "as_head validates version, gen, batches, file hashes, and integer to" {
  let hash = "a".repeat(64)
  let batch = "0000000001-0000000004-00000000.ndjson.zst"
  let valid = parse(
    "{\"v\":1,\"origin\":\"s1\",\"workspace\":\"W1\",\"gen\":\"lz5x0-0123abcd\",\"to\":4,\"made\":100,\"batches\":[\"" +
    batch +
    "\"],\"files\":{\"" +
    hash +
    "\":12},\"runs\":[{\"run\":\"r1\",\"from\":1}]}",
  )
  let h = as_head(valid).unwrap()
  assert_eq(head_gen(h), "lz5x0-0123abcd")
  assert_eq(head_to(h), 4.0)
  assert_eq(head_made(h), 100.0)
  assert_eq(head_batches(h), [batch])
  assert_eq(head_files(h), [hash])
  assert_eq(head_runs(h), [("r1", 1.0)])

  assert_true(as_head(set(valid, "v", jn(2.0))) is None)
  assert_true(as_head(set(valid, "gen", js("BAD"))) is None)
  assert_true(as_head(set(valid, "to", jn(1.5))) is None)
  assert_true(as_head(set(valid, "batches", ja([js("bad.zst")]))) is None)
  assert_true(as_head(set(valid, "files", jo([("not-a-hash", jn(1.0))]))) is None)
}

///|
test "Thrown error helpers classify Refused, Said, and system codes" {
  let r : Error = refused("no space")
  assert_true(is_refused(r))
  assert_eq(kind_of(r), "Refused")
  assert_eq(message_of(r), "no space")
  assert_eq(code_of(r), "")

  let s : Error = said("done moving")
  assert_false(is_refused(s))
  assert_eq(kind_of(s), "Said")
  assert_eq(message_of(s), "done moving")

  let io : Error = Thrown("Error", jo([("message", js("missing")), ("code", js("ENOENT"))]))
  assert_eq(code_of(io), "ENOENT")
  assert_eq(message_of(io), "missing")
}

///|
test "fixed1 and string_map / pair_get helpers" {
  assert_eq(fixed1(0.0), "0.0")
  assert_eq(fixed1(2.25), "2.3")
  assert_eq(fixed1(9.99), "10.0")
  let m = string_map(Some(parse("{\"a\":\"1\",\"b\":2,\"c\":\"three\"}")))
  assert_eq(m, [("a", "1"), ("c", "three")])
  assert_eq(pair_get(m, "c"), Some("three"))
  assert_eq(pair_get(m, "b"), None)
  assert_eq(stringify(pairs_json(m)), "{\"a\":\"1\",\"c\":\"three\"}")
}

///|
test "tell tracks sessions, removals, and ignores unrelated events" {
  let t = Told::nothing()
  assert_true(tell(t, parse("{\"type\":\"session\",\"key\":\"s1\"}")))
  assert_true(tell(t, parse("{\"type\":\"sessionRemoved\",\"key\":\"s2\",\"ws\":\"W1\"}")))
  assert_true(tell(t, parse("{\"type\":\"threadRemoved\",\"id\":9}")))
  inspect(
    stringify(t.to_json()),
    content="{\"sessions\":[\"s1\"],\"threads\":[],\"removedSessions\":[{\"key\":\"s2\",\"ws\":\"W1\"}],\"removedThreads\":[{\"id\":9,\"ws\":null}],\"marks\":[]}",
  )
}
