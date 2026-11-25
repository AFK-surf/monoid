// The applier against core-ts's own (vectors_test.mbt, made by core/delta-vectors.ts), and a few by hand.

///|
fn check_vector(text : String) -> Unit raise {
  guard @json.parse(text) is Object(v) else { fail("not a vector") }
  guard v.get("ops") is Some(Array(ops)) else { fail("no ops") }
  let old = v.get("old").unwrap()
  let before = old.stringify()
  let got = @core.apply_delta(old, ops)
  assert_eq(got.stringify(), v.get("want").unwrap().stringify())
  // The old value is not changed: a view may still hold it.
  assert_eq(old.stringify(), before)
}

///|
test "set, append and remove at a path, copying only along it" {
  let old : Json = { "a": { "b": [1, 2] }, "c": { "d": true } }
  let ops : Array[Json] = [
    { "path": ["a", "b"], "append": [3] },
    { "path": ["a", "b", 0], "set": "one" },
    { "path": ["c", "d"], "remove": true },
  ]
  let got = @core.apply_delta(old, ops)
  assert_eq(got.stringify(), "{\"a\":{\"b\":[\"one\",2,3]},\"c\":{}}")
  assert_eq(old.stringify(), "{\"a\":{\"b\":[1,2]},\"c\":{\"d\":true}}")
}

///|
test "keyed ops find items by their key" {
  let old : Json = {
    "items": [{ "id": "a", "n": 1 }, { "id": "b", "n": 2 }, { "id": "c", "n": 3 }],
  }
  let ops : Array[Json] = [
    { "path": ["items"], "key": ["id"], "drop": "b" },
    { "path": ["items"], "key": ["id"], "move": "c", "before": "a" },
    { "path": ["items"], "key": ["id"], "put": { "id": "d", "n": 4 }, "before": null },
    {
      "path": ["items"],
      "key": ["id"],
      "patch": "a",
      "ops": [{ "path": ["n"], "set": 10 }],
    },
  ]
  assert_eq(
    @core.apply_delta(old, ops).stringify(),
    "{\"items\":[{\"id\":\"c\",\"n\":3},{\"id\":\"a\",\"n\":10},{\"id\":\"d\",\"n\":4}]}",
  )
}

///|
test "a run of patches on one list is as each applied alone" {
  let old : Json = {
    "days": [
      {
        "daysAgo": 0,
        "items": [
          { "station": "s", "id": "a", "n": 1 },
          { "station": "s", "id": "b", "n": 2 },
          { "station": "s", "id": "b", "n": 3 },
          { "station": "t", "id": "a", "n": 4 },
        ],
      },
    ],
  }
  let key : Json = ["station", "id"]
  let patch = fn(k : Json, ops : Json) -> Json {
    { "path": ["items"], "key": key, "patch": k, "ops": ops }
  }
  let inner : Array[Json] = [
    patch(["s", "b"], [{ "path": ["n"], "set": 20 }]),
    patch(["t", "a"], [{ "path": ["id"], "set": "b" }]),
    patch(["s", "missing"], [{ "path": ["n"], "set": 0 }]),
    patch(["t", "b"], [{ "path": ["n"], "set": 40 }]),
    patch(["s", "a"], [{ "path": ["gone"], "set": true }, { "path": ["n"], "remove": true }]),
  ]
  let ops : Array[Json] = [{ "path": ["days"], "key": ["daysAgo"], "patch": 0, "ops": Json::array(inner) }]
  let one_by_one = inner.fold(init=old, fn(v, op) {
    @core.apply_delta(v, [{ "path": ["days"], "key": ["daysAgo"], "patch": 0, "ops": [op] }])
  })
  let before = old.stringify()
  assert_eq(@core.apply_delta(old, ops).stringify(), one_by_one.stringify())
  assert_eq(
    one_by_one.stringify(),
    "{\"days\":[{\"daysAgo\":0,\"items\":[{\"station\":\"s\",\"id\":\"a\",\"gone\":true},{\"station\":\"s\",\"id\":\"b\",\"n\":20},{\"station\":\"s\",\"id\":\"b\",\"n\":3},{\"station\":\"t\",\"id\":\"b\",\"n\":40}]}]}",
  )
  assert_eq(old.stringify(), before)
}

///|
/// A keyed list `n` long, item `i` keyed "k<i>" but item 30's keyed as item 5 is ("k5" twice: the first is the one found).
fn long_keyed(n : Int) -> Json {
  Json::object({
    "items": Json::array(Array::makei(n, fn(i) {
      let k = if i == 30 { 5 } else { i }
      Json::object({ "id": Json::string("k\{k}"), "n": Json::number(i.to_double()) })
    })),
  })
}

///|
/// What keyed ops `ops` make of `old`, one delta each, as a subscription takes them one after another.
fn each_delta(old : Json, ops : Array[Json]) -> Json {
  let mut v = old
  for op in ops {
    v = @core.apply_delta(v, [op])
  }
  v
}

///|
test "a long keyed list's ops, each its own delta, find their items as the short list's do" {
  let ops : Array[Json] = [
    { "path": ["items"], "key": ["id"], "patch": "k5", "ops": [{ "path": ["n"], "set": 500 }] },
    { "path": ["items"], "key": ["id"], "put": { "id": "k99", "n": 99 } },
    { "path": ["items"], "key": ["id"], "patch": "k99", "ops": [{ "path": ["n"], "set": 990 }] },
    { "path": ["items"], "key": ["id"], "patch": "k39", "ops": [{ "path": ["n"], "set": 390 }] },
    { "path": ["items"], "key": ["id"], "drop": "k2" },
    { "path": ["items"], "key": ["id"], "patch": "k39", "ops": [{ "path": ["n"], "set": 391 }] },
    { "path": ["items"], "key": ["id"], "put": { "id": "k7", "n": 70 } },
    { "path": ["items"], "key": ["id"], "move": "k99", "before": "k0" },
    { "path": ["items"], "key": ["id"], "patch": "k99", "ops": [{ "path": ["n"], "set": 991 }] },
  ]
  let got = each_delta(long_keyed(40), ops)
  // (the same ops on the list walked from its start, a short one's way: its items one at a time)
  let want = long_keyed(40)
  guard want is Object(w) && w.get("items") is Some(Array(items)) else { fail("no items") }
  let list = items.copy()
  let at = fn(k : String) { list.search_by(fn(x) { x is Object(o) && o.get("id") == Some(Json::string(k)) }).unwrap() }
  let set_n = fn(k : String, n : Double) {
    let i = at(k)
    guard list[i] is Object(o) else { return }
    let c = o.copy()
    c["n"] = Json::number(n)
    list[i] = Json::object(c)
  }
  set_n("k5", 500.0)
  list.push({ "id": "k99", "n": 99 })
  set_n("k99", 990.0)
  set_n("k39", 390.0)
  list.remove(at("k2")) |> ignore
  set_n("k39", 391.0)
  list[at("k7")] = { "id": "k7", "n": 70 }
  let moved = list.remove(at("k99"))
  list.insert(at("k0"), moved)
  set_n("k99", 991.0)
  assert_eq(got.stringify(), Json::object({ "items": Json::array(list) }).stringify())
}

///|
test "cow multi-op set/remove/append/overwrite matches one-by-one and keeps input, ops and untouched subtrees intact" {
  let untouched : Json = { "keep": [1, 2, 3], "nested": { "ok": true } }
  let old : Json = {
    "untouched": untouched,
    "lists": [
      {
        "key": "chats",
        "items": [
          { "key": "c0", "share": 0.5, "costText": "$10" },
          { "key": "c1", "share": 0.3, "costText": "$6" },
          { "key": "c2", "share": 0.2, "costText": "$4" },
        ],
      },
    ],
    "meta": { "a": 1, "b": { "x": 10, "y": 20 } },
    "arr": [{ "v": 1 }],
  }
  let ops : Array[Json] = [
    { "path": ["lists", 0, "items", 0, "share"], "set": 0.45 },
    { "path": ["lists", 0, "items", 1, "share"], "set": 0.35 },
    { "path": ["lists", 0, "items", 1, "costText"], "set": "$7" },
    { "path": ["lists", 0, "items", 99, "share"], "set": 0.99 }, // invalid index: skipped
    { "path": ["meta", "b", "x"], "set": 11 },
    { "path": ["meta", "b"], "set": { "z": 30 } }, // overwrites previously dirty child
    { "path": ["meta", "b", "z"], "set": 31 }, // mutates copy, must not mutate ops[5]
    { "path": ["meta", "a"], "remove": true },
    { "path": ["meta", "missing"], "remove": true }, // no-op remove
    { "path": ["arr"], "append": [{ "v": 2 }] },
    { "path": ["arr", 1, "v"], "set": 20 }, // modifies appended item without mutating ops[9]
    { "path": ["nope", "deep"], "set": 1 }, // missing parent: skipped
  ]
  let old_before = old.stringify()
  let ops_before = Json::array(ops).stringify()
  let batch = @core.apply_delta(old, ops)
  let seq = each_delta(old, ops)
  assert_eq(batch.stringify(), seq.stringify())
  assert_eq(old.stringify(), old_before)
  assert_eq(Json::array(ops).stringify(), ops_before)
  // Untouched subtree retains exact reference identity
  guard batch is Object(bm) && bm.get("untouched") is Some(kept) else { fail("missing untouched") }
  assert_true(physical_equal(kept, untouched))
}

///|
test "cow keyed drop runs, mixed ops, duplicate keys and key-changing patches match one-by-one" {
  let old = long_keyed(50)
  let ops : Array[Json] = [
    // consecutive drops including duplicate key "k5" (at 5 and 30) and missing key
    { "path": ["items"], "key": ["id"], "drop": "k5" },
    { "path": ["items"], "key": ["id"], "drop": "k49" },
    { "path": ["items"], "key": ["id"], "drop": "missing" },
    { "path": ["items"], "key": ["id"], "drop": "k5" },
    { "path": ["items"], "key": ["id"], "drop": "k0" },
    // puts, moves, and patches including key change
    { "path": ["items"], "key": ["id"], "put": { "id": "k100", "n": 100 }, "before": "k1" },
    { "path": ["items"], "key": ["id"], "move": "k48", "before": "k100" },
    { "path": ["items"], "key": ["id"], "patch": "k10", "ops": [{ "path": ["n"], "set": 1010 }] },
    { "path": ["items"], "key": ["id"], "patch": "k10", "ops": [{ "path": ["id"], "set": "k10_new" }] },
    { "path": ["items"], "key": ["id"], "patch": "k10_new", "ops": [{ "path": ["n"], "set": 2020 }] },
    { "path": ["items"], "key": ["id"], "put": { "id": "k200", "n": 200 }, "before": null },
    { "path": ["items"], "key": ["id"], "patch": "k200", "ops": [{ "path": ["n"], "set": 2001 }] },
    // indexed edit interleaved with keyed op on the same array
    { "path": ["items", 0, "n"], "set": 777 },
    { "path": ["items"], "key": ["id"], "patch": "k48", "ops": [{ "path": ["extra"], "set": true }] },
  ]
  let old_before = old.stringify()
  let batch = @core.apply_delta(old, ops)
  let seq = each_delta(old, ops)
  assert_eq(batch.stringify(), seq.stringify())
  assert_eq(old.stringify(), old_before)
}

///|
test "cow keyed move with duplicate keys after shifted index stays exact" {
  let items : Array[Json] = Array::makei(40, fn(i) {
    let id = if i == 10 || i == 11 { "dup" } else { "k\{i}" }
    Json::object({ "id": Json::string(id), "tag": Json::number(i.to_double()) })
  })
  let old : Json = { "items": Json::array(items) }
  // Prime keyed_ats cache on `old` via a patch
  let warmed = @core.apply_delta(old, [
    { "path": ["items"], "key": ["id"], "patch": "k39", "ops": [{ "path": ["tag"], "set": 390 }] },
  ])
  // Move item 0 before "dup": must land before index 10 (tag 10), not index 11 (tag 11)
  let moved = @core.apply_delta(warmed, [
    { "path": ["items"], "key": ["id"], "move": "k0", "before": "dup" },
  ])
  guard moved is Object(m) && m.get("items") is Some(Array(arr)) else { fail("no items") }
  assert_eq(arr[9].stringify(), "{\"id\":\"k0\",\"tag\":0}")
  assert_eq(arr[10].stringify(), "{\"id\":\"dup\",\"tag\":10}")
  assert_eq(arr[11].stringify(), "{\"id\":\"dup\",\"tag\":11}")
}

///|
test "wire-key semantics stay consistent across single, batched drop, and object key order" {
  // 1) Object key order: {"a":1,"b":2} != {"b":2,"a":1} (matching TS JSON.stringify)
  let obj_old = @json.parse("{\"items\":[{\"id\":{\"a\":1,\"b\":2}}]}")
  let obj_ops : Array[Json] = [
    @json.parse("{\"path\":[\"items\"],\"key\":[\"id\"],\"patch\":{\"b\":2,\"a\":1},\"ops\":[{\"path\":[\"seen\"],\"set\":1}]}"),
    @json.parse("{\"path\":[\"items\"],\"key\":[\"id\"],\"patch\":{\"b\":2,\"a\":1},\"ops\":[{\"path\":[\"seen\"],\"set\":2}]}"),
  ]
  assert_eq(@core.apply_delta(obj_old, obj_ops).stringify(), obj_old.stringify())
  assert_eq(each_delta(obj_old, obj_ops).stringify(), obj_old.stringify())

  // 2) 32+ items with object-key-order change invalidates cached key index
  let items32 : Array[Json] = Array::makei(34, fn(i) {
    if i == 0 {
      Json::object({ "id": Json::object({ "a": 1, "b": 2 }), "tag": 0 })
    } else if i == 1 {
      Json::object({ "id": Json::object({ "b": 2, "a": 1 }), "tag": 1 })
    } else {
      Json::object({ "id": Json::string("k\{i}"), "tag": Json::number(i.to_double()) })
    }
  })
  let old32 : Json = { "items": Json::array(items32) }
  let step1 = @core.apply_delta(old32, [
    @json.parse("{\"path\":[\"items\"],\"key\":[\"id\"],\"patch\":{\"a\":1,\"b\":2},\"ops\":[{\"path\":[\"id\"],\"set\":{\"b\":2,\"a\":1}}]}"),
  ])
  let step2 = @core.apply_delta(step1, [
    @json.parse("{\"path\":[\"items\"],\"key\":[\"id\"],\"patch\":{\"b\":2,\"a\":1},\"ops\":[{\"path\":[\"hit\"],\"set\":true}]}"),
  ])
  guard step2 is Object(m32) && m32.get("items") is Some(Array(a32)) else { fail("no items") }
  assert_eq(a32[0].stringify(), "{\"id\":{\"b\":2,\"a\":1},\"tag\":0,\"hit\":true}")
  assert_eq(a32[1].stringify(), "{\"id\":{\"b\":2,\"a\":1},\"tag\":1}")

  // 3) Large integer / float repr / -0.0 normalization matches Double & JS JSON.stringify
  let big_old = @json.parse("[{\"id\":9007199254740993}]")
  let big_ops : Array[Json] = [
    @json.parse("{\"path\":[],\"key\":[\"id\"],\"drop\":9007199254740992}"),
    @json.parse("{\"path\":[],\"key\":[\"id\"],\"drop\":0}"),
  ]
  assert_eq(@core.apply_delta(big_old, big_ops).stringify(), "[]")
  assert_eq(each_delta(big_old, big_ops).stringify(), "[]")

  let repr_old = @json.parse("[{\"id\":1},{\"id\":2},{\"id\":0}]")
  let repr_ops : Array[Json] = [
    @json.parse("{\"path\":[],\"key\":[\"id\"],\"drop\":1.0}"),
    @json.parse("{\"path\":[],\"key\":[\"id\"],\"drop\":-0.0}"),
  ]
  assert_eq(@core.apply_delta(repr_old, repr_ops).stringify(), "[{\"id\":2}]")
  assert_eq(each_delta(repr_old, repr_ops).stringify(), "[{\"id\":2}]")

  // 4) ES2015 OrdinaryOwnPropertyKeys ordering on Object keys (numeric array indices < 2^32-1 sorted first)
  let js_ord_old = @json.parse("[{\"id\":{\"10\":10}}]")
  let js_ord_ops : Array[Json] = [
    @json.parse("{\"path\":[0,\"id\",\"2\"],\"set\":2}"),
    @json.parse("{\"path\":[],\"key\":[\"id\"],\"patch\":{\"2\":2,\"10\":10},\"ops\":[{\"path\":[\"seen\"],\"set\":true}]}"),
  ]
  assert_eq(@core.apply_delta(js_ord_old, js_ord_ops).stringify(), "[{\"id\":{\"10\":10,\"2\":2},\"seen\":true}]")
  assert_eq(each_delta(js_ord_old, js_ord_ops).stringify(), "[{\"id\":{\"10\":10,\"2\":2},\"seen\":true}]")

  // Edge array-index boundaries: 0..4294967294 ascending numerically, then non-indices ("01", "4294967295", "a") in insertion order
  let edge_old = @json.parse("[{\"id\":{\"4294967295\":1,\"a\":2,\"4294967294\":3,\"01\":4,\"10\":6,\"2\":5,\"0\":7}}]")
  let edge_hit : Array[Json] = [
    @json.parse("{\"path\":[],\"key\":[\"id\"],\"patch\":{\"0\":7,\"2\":5,\"10\":6,\"4294967294\":3,\"4294967295\":1,\"a\":2,\"01\":4},\"ops\":[{\"path\":[\"hit\"],\"set\":1}]}"),
  ]
  let edge_miss : Array[Json] = [
    @json.parse("{\"path\":[],\"key\":[\"id\"],\"patch\":{\"0\":7,\"2\":5,\"10\":6,\"4294967294\":3,\"a\":2,\"4294967295\":1,\"01\":4},\"ops\":[{\"path\":[\"hit\"],\"set\":2}]}"),
  ]
  assert_eq(
    @core.apply_delta(edge_old, edge_hit).stringify(),
    "[{\"id\":{\"4294967295\":1,\"a\":2,\"4294967294\":3,\"01\":4,\"10\":6,\"2\":5,\"0\":7},\"hit\":1}]",
  )
  assert_eq(@core.apply_delta(edge_old, edge_miss).stringify(), edge_old.stringify())

  // Same ES2015 object-key ordering on a 32+ indexed list
  let idx_ord_items : Array[Json] = Array::makei(34, fn(i) {
    if i == 0 {
      Json::object({ "id": Json::object({ "10": 10 }) })
    } else {
      Json::object({ "id": Json::string("k\{i}") })
    }
  })
  let idx_ord_old : Json = { "items": Json::array(idx_ord_items) }
  let idx_ord_ops : Array[Json] = [
    @json.parse("{\"path\":[\"items\",0,\"id\",\"2\"],\"set\":2}"),
    @json.parse("{\"path\":[\"items\"],\"key\":[\"id\"],\"patch\":{\"2\":2,\"10\":10},\"ops\":[{\"path\":[\"seen\"],\"set\":true}]}"),
    @json.parse("{\"path\":[\"items\"],\"key\":[\"id\"],\"patch\":{\"2\":2,\"10\":10},\"ops\":[{\"path\":[\"seen2\"],\"set\":true}]}"),
  ]
  let idx_ord_out = @core.apply_delta(idx_ord_old, idx_ord_ops)
  assert_eq(idx_ord_out.stringify(), each_delta(idx_ord_old, idx_ord_ops).stringify())
  guard idx_ord_out is Object(iom) && iom.get("items") is Some(Array(ioa)) else { fail("no items") }
  assert_eq(ioa[0].stringify(), "{\"id\":{\"10\":10,\"2\":2},\"seen\":true,\"seen2\":true}")

  // 5) Non-finite numbers (Infinity / NaN) normalize to JSON null wire key in both linear scan and indexed lookup
  let inf_old : Json = [
    Json::object({ "id": Json::number(1.0 / 0.0), "tag": "inf" }),
    Json::object({ "id": Json::number(0.0 / 0.0), "tag": "nan" }),
    Json::object({ "id": 1, "tag": "one" }),
  ]
  let inf_ops : Array[Json] = [
    { "path": [], "key": ["id"], "drop": Json::null() },
    { "path": [], "key": ["id"], "drop": Json::number(1.0 / 0.0) },
  ]
  assert_eq(@core.apply_delta(inf_old, inf_ops).stringify(), "[{\"id\":1,\"tag\":\"one\"}]")
  assert_eq(each_delta(inf_old, inf_ops).stringify(), "[{\"id\":1,\"tag\":\"one\"}]")

  let inf34_items : Array[Json] = Array::makei(34, fn(i) {
    if i == 0 {
      Json::object({ "id": Json::number(0.0 / 0.0), "n": 0 })
    } else {
      Json::object({ "id": Json::number(i.to_double()), "n": Json::number(i.to_double()) })
    }
  })
  let inf34_old : Json = { "items": Json::array(inf34_items) }
  let inf34_ops : Array[Json] = [
    { "path": ["items"], "key": ["id"], "patch": Json::null(), "ops": [{ "path": ["n"], "set": 77 }] },
    { "path": ["items"], "key": ["id"], "patch": Json::number(0.0 / 0.0), "ops": [{ "path": ["n"], "set": 88 }] },
  ]
  let inf34_out = @core.apply_delta(inf34_old, inf34_ops)
  guard inf34_out is Object(i34m) && i34m.get("items") is Some(Array(i34a)) else { fail("no items") }
  guard i34a[0] is Object(i34o) && i34o.get("n") is Some(Number(i34n, ..)) else { fail("no n") }
  assert_eq(i34n, 88.0)
}

///|
test "drop_run excludes ops also carrying remove or set so object rules stay exact" {
  let old : Json = { "a": [{ "id": 1 }] }
  let ops1 : Array[Json] = [
    { "path": ["a"], "key": ["id"], "drop": 1, "remove": true },
    { "path": ["a"], "key": ["id"], "drop": 2 },
  ]
  assert_eq(@core.apply_delta(old, ops1).stringify(), "{}")
  assert_eq(each_delta(old, ops1).stringify(), "{}")

  let ops2 : Array[Json] = [
    { "path": ["a"], "key": ["id"], "drop": 2 },
    { "path": ["a"], "key": ["id"], "drop": 1, "remove": true },
  ]
  assert_eq(@core.apply_delta(old, ops2).stringify(), "{}")
  assert_eq(each_delta(old, ops2).stringify(), "{}")

  let missing_old : Json = Json::empty_object()
  let ops3 : Array[Json] = [
    { "path": ["a"], "key": ["id"], "drop": 1, "set": 1 },
    { "path": ["a"], "key": ["id"], "drop": 2 },
  ]
  assert_eq(@core.apply_delta(missing_old, ops3).stringify(), "{\"a\":null}")
  assert_eq(each_delta(missing_old, ops3).stringify(), "{\"a\":null}")
}

///|
test "untouched siblings stay physical_equal across drop_run and nested array paths, and cache isolates branches" {
  let sibling : Json = { "keep": [1, 2, 3] }
  let list40 : Array[Json] = Array::makei(40, fn(i) {
    Json::object({ "id": Json::string("k\{i}"), "n": Json::number(i.to_double()) })
  })
  let old : Json = { "arr": [{ "items": Json::array(list40), "sib": sibling }, sibling] }
  // drop_run through an intermediate array preserves sibling identity
  let dropped = @core.apply_delta(old, [
    { "path": ["arr", 0, "items"], "key": ["id"], "drop": "k1" },
    { "path": ["arr", 0, "items"], "key": ["id"], "drop": "k2" },
  ])
  guard dropped is Object(dm) && dm.get("arr") is Some(Array(darr)) else { fail("no arr") }
  assert_true(physical_equal(darr[1], sibling))
  guard darr[0] is Object(d0) && d0.get("sib") is Some(dsib) else { fail("no sib") }
  assert_true(physical_equal(dsib, sibling))

  // Two independent put-append branches from the same warmed parent must not corrupt each other's cached index
  let base : Json = { "items": Json::array(list40) }
  let warmed = @core.apply_delta(base, [
    { "path": ["items"], "key": ["id"], "patch": "k0", "ops": [{ "path": ["n"], "set": 100 }] },
    { "path": ["items"], "key": ["id"], "patch": "k1", "ops": [{ "path": ["n"], "set": 101 }] },
  ])
  let branch_a = @core.apply_delta(warmed, [
    { "path": ["items"], "key": ["id"], "put": { "id": "extra_a", "n": 1 }, "before": null },
  ])
  let branch_b = @core.apply_delta(warmed, [
    { "path": ["items"], "key": ["id"], "put": { "id": "extra_b", "n": 2 }, "before": null },
  ])
  let branch_b2 = @core.apply_delta(branch_b, [
    { "path": ["items"], "key": ["id"], "patch": "extra_a", "ops": [{ "path": ["n"], "set": 999 }] },
    { "path": ["items"], "key": ["id"], "patch": "extra_b", "ops": [{ "path": ["n"], "set": 200 }] },
  ])
  guard branch_a is Object(ma) && ma.get("items") is Some(Array(aa)) else { fail("no a") }
  guard branch_b2 is Object(mb) && mb.get("items") is Some(Array(ab)) else { fail("no b") }
  assert_eq(aa.length(), 41)
  assert_eq(ab.length(), 41)
  assert_eq(aa[40].stringify(), "{\"id\":\"extra_a\",\"n\":1}")
  assert_eq(ab[40].stringify(), "{\"id\":\"extra_b\",\"n\":200}")
}

///|
test "consecutive missed patches on a large keyed list preserve exact input identity" {
  let list200 : Array[Json] = Array::makei(200, fn(i) {
    Json::object({ "id": Json::number(i.to_double()), "v": Json::number(i.to_double()) })
  })
  let old : Json = { "items": Json::array(list200) }
  let ops : Array[Json] = Array::makei(64, fn(i) {
    Json::object({
      "path": ["items"],
      "key": ["id"],
      "patch": Json::number((200 + i).to_double()),
      "ops": [{ "path": ["v"], "set": 999 }],
    })
  })
  let out = @core.apply_delta(old, ops)
  assert_true(physical_equal(out, old))
}

///|
/// Independent naive reference applier mirroring `client/core-ts/src/collections.ts:applyKeyed`
/// (one op at a time, no Cow overlay, no keyed_ats cache, no drop_run batching).
fn ref_js_array_index(s : String) -> Int64? {
  let len = s.length()
  if len == 0 || len > 10 {
    return None
  }
  if len == 1 {
    let c = s.code_unit_at(0).to_int()
    return if c >= 48 && c <= 57 { Some((c - 48).to_int64()) } else { None }
  }
  let c0 = s.code_unit_at(0).to_int()
  if c0 < 49 || c0 > 57 {
    return None
  }
  let mut v : Int64 = (c0 - 48).to_int64()
  for i = 1; i < len; i = i + 1 {
    let c = s.code_unit_at(i).to_int()
    if c < 48 || c > 57 {
      return None
    }
    v = v * 10L + (c - 48).to_int64()
  }
  if v <= 4294967294L { Some(v) } else { None }
}

///|
fn ref_wire_text(j : Json) -> String {
  match j {
    Null => "null"
    True => "true"
    False => "false"
    Number(d, ..) =>
      if !(d - d == 0.0) {
        "null"
      } else {
        Json::number(if d == 0.0 { 0.0 } else { d }).stringify()
      }
    String(_) => j.stringify()
    Array(xs) => "[" + xs.map(ref_wire_text).join(",") + "]"
    Object(m) => {
      let idxs : Array[(Int64, String, Json)] = []
      let rest : Array[(String, Json)] = []
      for k, v in m {
        match ref_js_array_index(k) {
          Some(n) => idxs.push((n, k, v))
          None => rest.push((k, v))
        }
      }
      idxs.sort_by(fn(a, b) { a.0.compare(b.0) })
      let parts : Array[String] = []
      for e in idxs {
        parts.push(Json::string(e.1).stringify() + ":" + ref_wire_text(e.2))
      }
      for e in rest {
        parts.push(Json::string(e.0).stringify() + ":" + ref_wire_text(e.1))
      }
      "{" + parts.join(",") + "}"
    }
  }
}

///|
fn ref_key_of(item : Json, fields : Array[Json]) -> Json {
  let get_f = fn(f : Json) {
    match (item, f) {
      (Object(m), String(name)) => m.get(name).unwrap_or(Json::null())
      _ => Json::null()
    }
  }
  if fields.length() == 1 {
    get_f(fields[0])
  } else {
    Json::array(fields.map(get_f))
  }
}

///|
fn ref_apply_list(list : Array[Json], op : Map[String, Json]) -> Array[Json] {
  let fields = match op.get("key") {
    Some(Array(f)) => f
    _ => return list
  }
  let out = list.copy()
  let find = fn(k : Json) -> Int {
    let want = ref_wire_text(k)
    for i, item in out {
      if ref_wire_text(ref_key_of(item, fields)) == want {
        return i
      }
    }
    -1
  }
  let place = fn(item : Json, before : Json?) {
    let pos = match before {
      None | Some(Null) => -1
      Some(b) => find(b)
    }
    if pos < 0 { out.push(item) } else { out.insert(pos, item) }
  }
  match (op.get("drop"), op.get("patch"), op.get("move")) {
    (Some(k), _, _) => {
      let i = find(k)
      if i >= 0 { out.remove(i) |> ignore }
    }
    (None, Some(k), _) => {
      let i = find(k)
      match op.get("ops") {
        Some(Array(inner)) if i >= 0 => out[i] = ref_apply_delta(out[i], inner)
        _ => ()
      }
    }
    (None, None, Some(k)) => {
      let i = find(k)
      if i < 0 { return list }
      let item = out.remove(i)
      place(item, op.get("before"))
    }
    (None, None, None) => {
      let put = match op.get("put") {
        Some(p) => p
        None => return list
      }
      let i = find(ref_key_of(put, fields))
      if i >= 0 && !op.contains("before") {
        out[i] = put
      } else {
        if i >= 0 { out.remove(i) |> ignore }
        place(put, op.get("before"))
      }
    }
  }
  out
}

///|
fn ref_apply_one(node : Json, op : Map[String, Json], path : Array[Json], depth : Int) -> Json {
  if depth == path.length() {
    if op.contains("key") {
      return match node {
        Array(list) => Json::array(ref_apply_list(list, op))
        _ => node
      }
    }
    match op.get("set") {
      Some(v) => return v
      None => ()
    }
    return match (node, op.get("append")) {
      (Array(a), Some(Array(more))) => {
        let c = a.copy()
        for x in more { c.push(x) }
        Json::array(c)
      }
      _ => node
    }
  }
  let last = depth == path.length() - 1
  match node {
    Array(a) =>
      match path[depth] {
        Number(d, ..) if d >= 0.0 && d < 2147483647.0 && d == d.floor() && d.to_int() < a.length() => {
          let i = d.to_int()
          let c = a.copy()
          c[i] = ref_apply_one(a[i], op, path, depth + 1)
          Json::array(c)
        }
        _ => node
      }
    Object(m) =>
      match path[depth] {
        String(k) =>
          if op.contains("remove") && last {
            let c = m.copy()
            c.remove(k)
            Json::object(c)
          } else if !m.contains(k) && !(op.contains("set") && last) {
            node
          } else {
            let c = m.copy()
            c[k] = ref_apply_one(m.get(k).unwrap_or(Json::null()), op, path, depth + 1)
            Json::object(c)
          }
        _ => node
      }
    _ => node
  }
}

///|
fn ref_apply_delta(value : Json, ops : Array[Json]) -> Json {
  let mut v = value
  for op in ops {
    match op {
      Object(o) =>
        match o.get("path") {
          Some(Array(path)) => v = ref_apply_one(v, o, path, 0)
          _ => ()
        }
      _ => ()
    }
  }
  v
}

///|
test "apply_delta matches independent naive reference across mixed keyed/unkeyed/interleaved ops" {
  let old = long_keyed(45)
  let ops : Array[Json] = [
    { "path": ["items"], "key": ["id"], "patch": "k5", "ops": [{ "path": ["n"], "set": 500 }] },
    { "path": ["other"], "set": 1 },
    { "path": ["items"], "key": ["id"], "patch": "k39", "ops": [{ "path": ["n"], "set": 390 }] },
    { "path": ["items"], "key": ["id"], "drop": "k5" },
    { "path": ["items"], "key": ["id"], "drop": "k2" },
    { "path": ["items"], "key": ["id"], "put": { "id": "k5", "n": 555 }, "before": null },
    { "path": ["items"], "key": ["id"], "move": "k44", "before": "k0" },
    { "path": ["items"], "append": [{ "id": "k90", "n": 90 }] },
    { "path": ["items"], "key": ["id"], "patch": "k90", "ops": [{ "path": ["n"], "set": 900 }] },
    { "path": ["items", 0, "n"], "set": 444 },
    { "path": ["items"], "key": ["id"], "patch": "k5", "ops": [{ "path": ["n"], "set": 556 }] },
  ]
  assert_eq(@core.apply_delta(old, ops).stringify(), ref_apply_delta(old, ops).stringify())
}
