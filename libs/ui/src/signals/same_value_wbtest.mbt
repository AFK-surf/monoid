// What a signal and a computed take as "the same" by default is the value (same_value: `==`), so a value made anew but
// equal (a string built again, a tuple, an array) runs nothing that follows it; the object (physical_equal) only where
// asked by name (signal_ref, computed_ref). And an effect made as a computed's getter runs is told
// (effect_in_computed), but for one a computed holds while it is read (held_while_read).

///|
/// A string with these words, made anew (never the literal's object).
fn words_anew(s : String) -> String {
  let b = StringBuilder()
  b.write_string(s)
  b.to_string()
}

///|
test "a signal set to an equal string, tuple or array made anew runs nothing that follows it" {
  let s = signal(words_anew("ab"))
  let pair = signal((1, words_anew("x")))
  let list = signal([1, 2, 3])
  let runs = Ref(0)
  effect(fn() {
    s.get() |> ignore
    pair.get() |> ignore
    list.get() |> ignore
    runs.val += 1
  })
  |> ignore
  assert_eq(runs.val, 1)
  s.set(words_anew("ab"))
  pair.set((1, words_anew("x")))
  list.set([1, 2, 3])
  assert_eq(runs.val, 1)
  // (another value is a change)
  list.set([1, 2, 4])
  assert_eq(runs.val, 2)
}

///|
test "a computed that makes an equal string, tuple or array anew tells nothing to what follows it" {
  let n = signal(0)
  let words = computed(fn(_) {
    n.get() |> ignore
    words_anew("ab")
  })
  let pair = computed(fn(_) {
    n.get() |> ignore
    (1, words_anew("x"))
  })
  let list = computed(fn(_) {
    n.get() |> ignore
    [1, 2, 3]
  })
  let runs = Ref(0)
  let w = watch(fn() {  })
  effect(fn() {
    words.get() |> ignore
    pair.get() |> ignore
    list.get() |> ignore
    runs.val += 1
  })
  |> ignore
  w.read(fn() { (words.get(), pair.get(), list.get()) }) |> ignore
  assert_eq(runs.val, 1)
  n.set(1)
  assert_eq(runs.val, 1)
  assert_false(w.is_stale())
  w.stop()
}

///|
test "signal_ref and computed_ref follow the object: one made anew is a change" {
  let s = signal_ref([1, 2])
  let n = signal(0)
  let c = computed_ref(fn(_) {
    n.get() |> ignore
    [1, 2]
  })
  let runs = Ref(0)
  effect(fn() {
    s.get() |> ignore
    c.get() |> ignore
    runs.val += 1
  })
  |> ignore
  s.set([1, 2])
  assert_eq(runs.val, 2)
  n.set(1)
  assert_eq(runs.val, 3)
}

///|
test "an effect made as a computed's getter runs is told where it was made" {
  let told : Array[String] = []
  let was = effect_in_computed.val
  effect_in_computed.val = Some(fn(loc) { told.push(loc.to_string()) })
  let n = signal(0)
  let c = computed(fn(_) {
    effect(fn() { n.get() |> ignore }) |> ignore
    n.get()
  })
  let stop = effect(fn() { c.get() |> ignore })
  effect_in_computed.val = was
  stop()
  assert_eq(told.length(), 1)
  assert_true(told[0].contains("same_value_wbtest.mbt"), msg=told[0])
}

///|
test "held_while_read: its effects made as its first reader comes, untold, and stopped as its last leaves" {
  let told : Array[String] = []
  let was = effect_in_computed.val
  effect_in_computed.val = Some(fn(loc) { told.push(loc.to_string()) })
  let n = signal(0)
  let seen : Array[Int] = []
  let held = held_while_read(fn() { effect(fn() { seen.push(n.get()) }) |> ignore })
  let value = computed_following(fn(_) { 1 }, held)
  assert_eq(seen, [])
  let stop = effect(fn() { value.get() |> ignore })
  n.set(1)
  assert_eq(seen, [0, 1])
  stop()
  n.set(2)
  effect_in_computed.val = was
  assert_eq(seen, [0, 1])
  assert_eq(told, [])
}
