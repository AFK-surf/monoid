///|
test "things_kind_read: another kind there at once, read again in the change as it was; a thing come or gone of one kind its way, the last one too" {
  let was : Ref[Set[String]] = Ref(Set([]))
  let other = Ref(false)
  let read = fn(keys : Array[String], kind : String) {
    things_kind_read(was, other, keys, kind) |> ignore
    other.val
  }
  let rows = fn(kind : String, names : Array[String]) {
    let out = ["head"]
    if names.is_empty() {
      out.push("none")
    }
    for n in names {
      out.push("thing/" + kind + "/" + n)
    }
    out.push("foot")
    out
  }
  assert_eq(read(rows("links", ["a", "b"]), "links"), false)
  // (another kind: another list, there at once, however often the change reads its keys)
  assert_eq(read(rows("files", ["x"]), "files"), true)
  assert_eq(read(rows("files", ["x"]), "files"), true)
  // (one thing come of the same kind: its way)
  assert_eq(read(rows("files", ["x", "y"]), "files"), false)
  assert_eq(read(rows("files", ["x", "y"]), "files"), false)
  // (one gone, then the last one: each its way, none found in its place)
  assert_eq(read(rows("files", ["y"]), "files"), false)
  assert_eq(read(rows("files", []), "files"), false)
  // (another kind with nothing in it: another list still)
  assert_eq(read(rows("links", []), "links"), true)
  // (back to a kind with things: another list)
  assert_eq(read(rows("files", ["z"]), "files"), true)
}
