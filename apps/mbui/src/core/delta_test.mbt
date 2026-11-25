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
test "json_same matches Json equality and short-circuits shared subtrees" {
  let shared_block : Json = { "kind": "code", "lines": ["a", "b", "c"] }
  let a : Json = { "id": 1, "blocks": [shared_block, { "text": "hi" }] }
  let b : Json = { "id": 1.0, "blocks": [shared_block, { "text": "hi" }] }
  let c : Json = { "id": 1, "blocks": [shared_block, { "text": "bye" }] }
  assert_true(@core.json_same(a, a))
  assert_true(@core.json_same(a, b))
  assert_false(@core.json_same(a, c))
  let parsed_num = @json.parse("{\"n\":1}")
  let made_num : Json = { "n": 1.0 }
  assert_true(@core.json_same(parsed_num, made_num))
  assert_false(@core.json_same({ "a": 1 }, { "a": 1, "b": 2 }))
  assert_false(@core.json_same([1, 2], [1, 2, 3]))
}
