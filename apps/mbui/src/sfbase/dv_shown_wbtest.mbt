///|
fn dv_named(name : String) -> DvEntry {
  {
    name,
    dir: false,
    size: 1.0,
    mtime: 0.0,
    mime: "",
    kind: "other",
    size_text: "",
    time_text: "",
  }
}

///|
test "a folder's entries stay as shown while its place is said before its order: never none between" {
  dv_orders_reset()
  let key = "s|/root|"
  let entries = [dv_named("b.txt"), dv_named("a"), dv_named("c.md")]
  let names = fn(out : Array[DvEntry]?) { out.unwrap_or([]).map(fn(e) { e.name }) }
  // (the place not said yet: as the station lists them)
  assert_eq(names(dv_shown_of(key, None, entries)), ["b.txt", "a", "c.md"])
  // (the place said, naming no order of this folder yet: as it was last shown, not none)
  assert_eq(names(dv_shown_of(key, Some(None), entries)), ["b.txt", "a", "c.md"])
  // (its order said: in it)
  assert_eq(names(dv_shown_of(key, Some(Some(["a", "b.txt", "c.md"])), entries)), ["a", "b.txt", "c.md"])
  // (said again without it: as last shown, in that order)
  assert_eq(names(dv_shown_of(key, Some(None), entries)), ["a", "b.txt", "c.md"])
  // (a folder never shown, its place said without its order: its entries as the station lists them)
  assert_eq(names(dv_shown_of("s|/root|other", Some(None), [dv_named("x")])), ["x"])
  dv_orders_reset()
}
