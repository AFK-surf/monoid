// cmdk.mbt held to cmdk v1.1.1 (github.com/pacocoursey/cmdk, fb4ea04): its scores as its own command-score.ts gives
// them, run under Node on the same words (exact to 1e-12: a power's last place may differ by the platform's), command-
// score's own tests (superhuman/command-score a192b81, test.js), and cmdk's tests (test/*.test.ts, Playwright on its
// pages) as the same choices, the same words written and the same keys. Numbers alone: the same on every target
// (wasm-gc and native run this one file).

///|
fn near(got : Double, want : Double) -> Bool {
  (got - want).abs() < 1.0e-12
}

///|
/// What command-score.ts (cmdk v1.1.1's) says for each, run under Node.
let golden : Array[(String, String, Double)] = [
  ("hello", "hello", 1.0),
  ("Hello", "Hello", 1.0),
  ("Hello", "hello", 0.9999),
  ("hello", "he", 0.99),
  ("help", "he", 0.99),
  ("hello world", "hello", 0.99),
  ("hello world", "hewo", 0.891),
  ("hey world", "hewo", 0.891),
  ("hello kind world", "hewo", 0.890109),
  ("hello", "hl", 0.1681317),
  ("hello", "hllo", 0.16983),
  ("hello", "hlo", 0.16966017000000003),
  ("go to Inbox", "in", 0.8909109000000001),
  ("go to Unversity/Societies/CUE/info@cue.org.uk", "in", 0.792),
  ("hello", "hle", 0.099),
  ("ss", "sss", 0.1),
  ("go to @QuickFix", "fix", 0.16998300000000002),
  ("go to Quick Fix", "fix", 0.89991),
  ("no go \u{2014} Windows", "windows", 0.89991),
  ("talent", "tall", 0.099),
  ("talent", "tadlent", 0.0),
  ("Auto-Advance", "Auto Advance", 0.9999),
  ("Auto Advance", "auto-advance", 0.9997000299990001),
  ("foo.bar112.value", "112", 0.1683),
  ("foo.bar112.value", "bar", 0.792),
  ("removed", "112", 0.0),
  ("Item", "x", 0.0),
  ("xxx", "x", 0.99),
  ("Value", "x", 0.0),
  ("New issue", "ni", 0.8909109000000001),
  ("New issue", "new", 0.989901),
  ("Create new issue", "ni", 0.8019000000000001),
  ("new issue", "ni", 0.891),
  ("New document in Engineering", "ni", 0.8900199891),
  ("Go to Inbox", "gi", 0.88993098710109),
  ("Change status\u{2026}", "cs", 0.8909109000000001),
  ("Settings", "set", 0.989901),
  ("Assign to me", "as", 0.989901),
  ("html", "HM", 0.16809807534131702),
  ("HTML", "HM", 0.1681317),
  ("haml", "HM", 0.16809807534131702),
  ("ouch", "uc", 0.1683),
  ("curtain", "uc", 0.099),
  ("bad", "bd", 0.16983),
  ("bard", "bd", 0.16966017000000003),
  ("html", "html", 1.0),
  ("html5", "html", 0.99),
  ("a\u{a0}b", "a b", 0.9999),
  ("a\u{3000}b", "a b", 0.9999),
  ("path/to_file.txt", "ptf", 0.6336),
  ("Open issues in new tab", "new tab", 0.9),
  ("New tab", "new tab", 0.9999),
  ("Giraffe", "t", 0.0),
  ("Two", "t", 0.989901),
  ("Three", "t", 0.989901),
  ("ant", "eat", 0.0),
  ("anteater", "eat", 0.1683),
  ("Apple", "", 0.99),
  ("", "", 1.0),
  ("", "a", 0.0),
  ("abc", "abcd", 0.0),
  ("aab", "ab", 0.17),
  ("abab", "aab", 0.16983),
]

///|
test "each score as cmdk's own command-score gives it" {
  for g in golden {
    let (words, query, want) = g
    let got = @headless.command_score(words, query)
    if !near(got, want) {
      fail("command_score(\{words}, \{query}) = \{got}, cmdk's \{want}")
    }
  }
}

///|
test "command-score's own tests: prefixes, word jumps, symbols' word starts, missing letters, transpositions" {
  let s = fn(a : String, b : String) { @headless.command_score(a, b) }
  // should match exact strings exactly
  assert_eq(s("hello", "hello"), 1.0)
  // should prefer case-sensitive matches
  assert_true(s("Hello", "Hello") > s("Hello", "hello"))
  // should mark down prefixes
  assert_true(s("hello", "hello") > s("hello", "he"))
  // should score all prefixes the same
  assert_eq(s("help", "he"), s("hello", "he"))
  // should mark down word jumps
  assert_true(s("hello world", "hello") > s("hello world", "hewo"))
  // should score similar word jumps the same
  assert_eq(s("hello world", "hewo"), s("hey world", "hewo"))
  // should penalize long word jumps
  assert_true(s("hello world", "hewo") > s("hello kind world", "hewo"))
  // should match missing characters
  assert_true(s("hello", "hl") > 0.0)
  // should penalize more for more missing characters
  assert_true(s("hello", "hllo") > s("hello", "hlo"))
  // should penalize more for missing characters than case
  assert_true(s("go to Inbox", "in") > s("go to Unversity/Societies/CUE/info@cue.org.uk", "in"))
  // should match transpotisions
  assert_true(s("hello", "hle") > 0.0)
  // should not match with a trailing letter
  assert_eq(s("ss", "sss"), 0.1)
  // should match long jumps
  assert_true(s("go to @QuickFix", "fix") > 0.0)
  assert_true(s("go to Quick Fix", "fix") > s("go to @QuickFix", "fix"))
  // should work well with the presence of an m-dash
  assert_true(s("no go \u{2014} Windows", "windows") > 0.0)
  // should be robust to duplicated letters
  assert_eq(s("talent", "tall"), 0.099)
  // should not allow letter insertion
  assert_eq(s("talent", "tadlent"), 0.0)
  // should match - with " " characters
  assert_eq(s("Auto-Advance", "Auto Advance"), 0.9999)
  // (a word started after a symbol, 0.8; one after a space, 0.9; one inside a word, 0.17)
  assert_true(near(s("path/to_file", "f"), 0.8 * 0.99))
  assert_true(near(s("path to file", "f"), 0.9 * 0.99))
  assert_true(near(s("pathtofile", "f"), 0.17 * 0.99))
  // should score long strings quickly
  assert_eq(
    s(
      "go to this is a really long label that is really longthis is a really long label that is really longthis is a really long label that is really longthis is a really long label that is really long",
      "this is a",
    ),
    0.891,
  )
}

///|
test "keywords: cmdk's written after the words; a palette's each alone, the best taken, so an abbreviation finds its keyword" {
  // (cmdk's own: `Item` with the keyword `key`, `key` written, as cmdk's commandScore gives it)
  assert_true(near(@headless.command_score("Item", "key", aliases=["key"]), 0.9))
  assert_eq(@headless.command_score("xxx", "key"), 0.0)
  assert_true(near(@headless.command_score("Create new item", "ni", aliases=["new item"]), 0.8019))
  // (a palette's: the keyword's own score, better than the words')
  assert_eq(@headless.cmdk_score("Item", "key", keywords=["key"]), 1.0)
  assert_true(near(@headless.cmdk_score("Create new item", "ni", keywords=["new item"]), 0.891))
  assert_true(near(@headless.cmdk_score("New document in Engineering", "ni"), 0.8900199891))
  assert_true(
    @headless.cmdk_score("Create new item", "ni", keywords=["new item"]) >
    @headless.cmdk_score("New document in Engineering", "ni"),
  )
  // (no words: not shown, as in cmdk)
  assert_eq(@headless.cmdk_score("", "a", keywords=["a"]), 0.0)
}

///|
test "letters made small by ASCII's rule alone, every character in its place; every Unicode space a space" {
  assert_eq(@headless.command_score("\u{C7}a va", "\u{E7}a"), 0.0)
  // (cmdk's 0.168233: its `İ` made two characters, what it compares no longer lined up with the words)
  assert_true(near(@headless.command_score("\u{130}stanbul", "stan"), 0.17 * 0.99))
  assert_true(near(@headless.command_score("NEW", "new"), 0.9999 * 0.9999 * 0.9999))
  assert_true(near(@headless.command_score("a\u{2003}b", "a b"), 0.9999))
  // (a character past the Basic Multilingual Plane is one, as a `Char` is)
  assert_true(near(@headless.command_score("\u{1F600} smile", "s"), 0.9 * 0.99))
}

// ── the list ──

///|
/// What `rows` shows, a row a string: `# ` a heading, `--` a rule, an item by its key.
fn rows(rows : Array[@headless.CmdkEntry[String]]) -> Array[String] {
  rows.map(fn(r) {
    match r {
      Heading(h) => "# " + h
      Separator(_) => "--"
      Item(it, _) => it.key
    }
  })
}

///|
/// An item keyed and called `key`.
fn it(
  key : String,
  label? : String,
  keywords? : Array[String] = [],
  group? : String = "",
  disabled? : Bool = false,
) -> @headless.CmdkItem[String] {
  @headless.cmdk_item(key, label.unwrap_or(key), keywords~, group~, disabled~)
}

///|
test "cmdk basic: the first selected, filtered as words are written, by keywords, none shown" {
  let items = [it("Item", keywords=["key"]), it("xxx")]
  let all = @headless.cmdk_filter(items, "")
  assert_eq(@headless.cmdk_keys(all), ["Item", "xxx"])
  // first item is selected by default
  assert_eq(@headless.cmdk_first(all), Some("Item"))
  // items filter when searching; first item is selected when search changes
  let x = @headless.cmdk_filter(items, "x")
  assert_eq(rows(x), ["xxx"])
  assert_eq(@headless.cmdk_first(x), Some("xxx"))
  // items filter when searching by keywords
  assert_eq(rows(@headless.cmdk_filter(items, "key")), ["Item"])
  // empty component renders when there are no results
  let z = @headless.cmdk_filter(items, "z")
  assert_eq(rows(z), [])
  assert_eq(@headless.cmdk_first(z), None)
  // (spaces alone are nothing written)
  assert_eq(rows(@headless.cmdk_filter(items, "  ")), ["Item", "xxx"])
}

///|
test "cmdk group: shown and hidden by their items, a heading over each group's first, a rule only between two" {
  let all = [
    it("Giraffe", group="Animals"),
    it("Chicken", group="Animals"),
    it("A", group="Letters"),
    it("B", group="Letters"),
    it("Z", group="Letters"),
  ]
  assert_eq(rows(@headless.cmdk_filter(all, "")), ["# Animals", "Giraffe", "Chicken", "--", "# Letters", "A", "B", "Z"])
  // groups are shown/hidden based on item matches: no rule first or last, never two
  assert_eq(rows(@headless.cmdk_filter(all, "z")), ["# Letters", "Z"])
  assert_eq(rows(@headless.cmdk_filter(all, "Giraffe")), ["# Animals", "Giraffe"])
  // (each rule keyed by the group it comes before)
  assert_eq(@headless.cmdk_filter(all, "")[3], Separator("Letters"))
  // group can be progressively rendered
  let more = all.copy()
  more.append([it("One", group="Numbers"), it("Two", group="Numbers"), it("Three", group="Numbers")])
  assert_eq(rows(@headless.cmdk_filter(more, "t")), ["# Numbers", "Two", "Three"])
}

///|
test "nothing written: those of no group first, then each group where its first was given, each in the order given" {
  let items = [it("a1", group="A"), it("x"), it("b1", group="B"), it("a2", group="A"), it("y")]
  assert_eq(rows(@headless.cmdk_filter(items, "")), ["x", "y", "--", "# A", "a1", "a2", "--", "# B", "b1"])
}

///|
test "cmdk item: items come and go, the one selected kept while it is shown and can be chosen" {
  let a = it("A")
  let b = it("B")
  // mounted item matches search
  assert_eq(rows(@headless.cmdk_filter([b], "b")), ["B"])
  // mounted item does not match search
  assert_eq(rows(@headless.cmdk_filter([a, b], "z")), [])
  // unmount item that is selected: the first selected
  assert_eq(@headless.cmdk_keep(@headless.cmdk_filter([b], ""), Some("A")), Some("B"))
  // unmount item that is the only result
  assert_eq(@headless.cmdk_keep(@headless.cmdk_filter([], ""), Some("A")), None)
  // selected does not change when mounting new items
  let many = [a, it("1"), it("2"), it("3"), b]
  assert_eq(@headless.cmdk_keep(@headless.cmdk_filter(many, ""), Some("B")), Some("B"))
  // (the one selected disabled: the first that can be)
  let off = [a, it("B", disabled=true)]
  assert_eq(@headless.cmdk_keep(@headless.cmdk_filter(off, ""), Some("B")), Some("A"))
  // (none selected: the first)
  assert_eq(@headless.cmdk_keep(@headless.cmdk_filter(many, ""), None), Some("A"))
}

///|
test "cmdk numeric and a filter of one's own" {
  let items = [it("removed"), it("foo.bar112.value")]
  // items filter correctly on numeric inputs
  assert_eq(rows(@headless.cmdk_filter(items, "112")), ["foo.bar112.value"])
  // items filter correctly on non-numeric inputs
  assert_eq(rows(@headless.cmdk_filter(items, "bar")), ["foo.bar112.value"])
  // results match against custom filter
  let ants = [it("ant"), it("anteater")]
  let ends = @headless.cmdk_filter(ants, "ant", score=fn(w, q, _) { if w.has_suffix(q) { 1.0 } else { 0.0 } })
  assert_eq(rows(ends), ["ant"])
  assert_eq(@headless.cmdk_first(@headless.cmdk_filter(ants, "eat")), Some("anteater"))
}

///|
/// cmdk's test/pages/keybinds.tsx: one that cannot be chosen, First, Letters, Fruits (one that cannot be chosen among
/// them), Last, and another that cannot be chosen.
fn keybind_items() -> Array[@headless.CmdkItem[String]] {
  [
    it("disabled", label="Disabled", disabled=true),
    it("first", label="First"),
    it("A", group="Letters"),
    it("B", group="Letters"),
    it("Z", group="Letters"),
    it("Apple", group="Fruits"),
    it("Banana", group="Fruits"),
    it("Orange", group="Fruits"),
    it("Dragon Fruit", group="Fruits", disabled=true),
    it("Pear", group="Fruits"),
    it("last", label="Last"),
    it("disabled-3", label="Disabled 3", disabled=true),
  ]
}

///|
test "cmdk keybinds: one by one, first and last, group by group, those that cannot be chosen passed over" {
  let shown = @headless.cmdk_filter(keybind_items(), "")
  let go = fn(from : String?, by : @headless.CmdkMove) { @headless.cmdk_move(shown, from, by) }
  assert_eq(@headless.cmdk_first(shown), Some("first"))
  // arrow up/down changes selected item
  assert_eq(go(Some("first"), NextItem), Some("last"))
  assert_eq(go(Some("A"), PrevItem), Some("last"))
  // meta arrow up/down goes to first and last item
  assert_eq(go(Some("first"), LastItem), Some("Pear"))
  assert_eq(go(Some("Pear"), FirstItem), Some("first"))
  // alt arrow up/down goes to next and prev group
  assert_eq(go(Some("A"), NextGroup), Some("Apple"))
  assert_eq(go(Some("Apple"), PrevGroup), Some("A"))
  // (one that cannot be chosen passed over)
  assert_eq(go(Some("Orange"), NextItem), Some("Pear"))
  assert_eq(go(Some("Pear"), PrevItem), Some("Orange"))
  // (no loop: at the ends it stays)
  assert_eq(go(Some("Pear"), NextItem), Some("Pear"))
  assert_eq(go(Some("first"), PrevItem), Some("first"))
  // (loop: past the last to the first, before the first to the last)
  assert_eq(@headless.cmdk_move(shown, Some("Pear"), NextItem, wraps=true), Some("first"))
  assert_eq(@headless.cmdk_move(shown, Some("first"), PrevItem, wraps=true), Some("Pear"))
  // (none selected: down to the first, up to the last)
  assert_eq(go(None, NextItem), Some("first"))
  assert_eq(go(None, PrevItem), Some("Pear"))
  // (from a choice of no group, by group is by one; past the last group, as by one)
  assert_eq(go(Some("first"), NextGroup), Some("last"))
  assert_eq(go(Some("Pear"), NextGroup), Some("Pear"))
  // (nothing to choose: where it was)
  assert_eq(@headless.cmdk_move(@headless.cmdk_filter([it("x", disabled=true)], ""), Some("x"), NextItem), Some("x"))
}

///|
test "sorted by score: within a group, the groups by their best, those of no group first, ties as given" {
  let items = [
    it("Set due date\u{2026}", group="Item"),
    it("Items I created", group="Item"),
    it("Show as list", group="Window"),
    it("Text size\u{2026}", group="Window"),
    it("Change status\u{2026}", group="Window"),
    it("Go to Inbox", group="Go"),
    it("Open settings"),
  ]
  // (`st`: Open settings, of no group, first; the window's (Change status… 0.891, Show as list 0.17; Text size… none,
  // hidden) before the item's (Set due date… 0.168, …), though given after them; Go to Inbox none, its group hidden
  // whole)
  let st = @headless.cmdk_filter(items, "st")
  assert_eq(rows(st), [
    "Open settings", "--", "# Window", "Change status\u{2026}", "Show as list", "--", "# Item", "Set due date\u{2026}", "Items I created",
  ])
  // (each item's score with it)
  match st[3] {
    Item(i, score) => assert_eq((i.key, near(score, 0.891)), ("Change status\u{2026}", true))
    _ => fail("no item")
  }
  // (two that score the same keep the order given)
  let same = [it("b theme"), it("a theme")]
  assert_eq(rows(@headless.cmdk_filter(same, "theme")), ["b theme", "a theme"])
  // (groups of the same best score keep the order their first was given)
  let tied = [it("theme b", group="B"), it("theme a", group="A")]
  assert_eq(rows(@headless.cmdk_filter(tied, "theme")), ["# B", "theme b", "--", "# A", "theme a"])
}

///|
test "a palette's commands: ni a new item by its keyword, cs a change of status, keys of any type" {
  let items : Array[@headless.CmdkItem[Int]] = [
    @headless.cmdk_item(1, "New document in Engineering"),
    @headless.cmdk_item(2, "Create new item", keywords=["new item"]),
    @headless.cmdk_item(3, "Change status\u{2026}"),
    @headless.cmdk_item(4, "Copy link"),
  ]
  // (Copy link: `ni` as `in` written the other way round, 0.1 of what is left)
  assert_eq(@headless.cmdk_keys(@headless.cmdk_filter(items, "ni")), [2, 1, 4])
  assert_eq(@headless.cmdk_first(@headless.cmdk_filter(items, "cs")), Some(3))
  assert_eq(@headless.cmdk_keep(@headless.cmdk_filter(items, "c"), Some(4)), Some(4))
}
