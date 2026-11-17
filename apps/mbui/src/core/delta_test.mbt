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
