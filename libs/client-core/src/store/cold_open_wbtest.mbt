// A chat opened first in a run, on an account's database stood in (fake_wbtest.mbt), as the TypeScript core's
// test/cold-open.test.ts holds its own: up to its first view nothing is written, its trees are read in one statement,
// and it runs as many statements with five times the chats; what showing it noted is written after, in one
// transaction. Each account holds chats of every kind: long replies with code, short lines, notices, files.

///|
let station : String = "s1"

///|
/// Ten days in: every tree kept was last noted shown at 0, so showing it notes it shown again.
let now : Int64 = 864_000_000L

///|
/// A long reply of an agent: paragraphs past a hundred characters a line, and a fenced block of code.
fn long_reply(i : Int) -> String {
  let sb = StringBuilder()
  for p in 0..<6 {
    sb.write_string(
      "Paragraph \{p} of reply \{i}: the change reads every tree of the page in one statement and writes what showing noted once the first values went out.\n",
    )
  }
  sb.write_string("```moonbit\nfn main {\n  println(\"reply \{i}\")\n}\n```\nDone.")
  sb.to_string()
}

///|
/// The words a notice of the station's says.
fn notice_words(i : Int) -> String {
  "Agent restarted (\{i})"
}

///|
/// An account of `chats` chats (threads 1 ..= chats) of 40 entries each: thread 7 long replies of an agent between a
/// person's short questions, thread 3 short lines alone, the others each of every kind; every tree of an agent's or
/// a notice's words kept, last noted shown at 0.
fn account(chats : Int) -> FakeDb {
  let db = FakeDb::new()
  for t in 1..=chats {
    for n in 1..=40 {
      let entry : Json = if t == 7 {
        if n % 2 == 0 {
          { "kind": "message", "authorKind": "agent", "author": "a1", "text": long_reply(t * 100 + n) }
        } else {
          { "kind": "message", "authorKind": "person", "author": "p1", "text": "Why is it slow? (\{n})" }
        }
      } else if t == 3 {
        { "kind": "message", "authorKind": if n % 2 == 0 { "agent" } else { "person" }, "author": "x", "text": "ok \{n}" }
      } else {
        match n % 5 {
          0 => { "kind": "message", "authorKind": "agent", "author": "a1", "text": long_reply(t * 100 + n) }
          1 => { "kind": "message", "authorKind": "station", "author": "", "text": "", "notice": { "words": notice_words(n) } }
          2 => { "kind": "edit", "authorKind": "agent", "author": "a1", "text": "x", "target": n - 1 }
          3 =>
            {
              "kind": "message",
              "authorKind": "person",
              "author": "p1",
              "text": "See the file",
              "attachments": [{ "name": "a.png" }],
            }
          _ => { "kind": "message", "authorKind": "agent", "author": "a1", "text": "Short answer \{n}." }
        }
      }
      db.put_entry(station, t, n, entry)
      let e = Entry::of_json(n, entry)
      if e.md_words() is Some(text) {
        db.put_tree(station, md_key(text), "[[\"p\",[[0,\{text.length()}]]]]", 0L)
      }
    }
  }
  db
}

///|
/// Opens `thread` of a new store on `db`: the view and what ran for it (all, writes, reads of md_kept).
fn opened(db : FakeDb, store : MdStore, thread : Int, rows? : Int = 30, at? : Int) -> (ChatOpenView, Int, Int, Int) raise {
  let from = db.ran.length()
  let view = open_chat(store, thread, rows~, at?, now~)
  let (all, w, md, _, _) = db.since(from)
  (view, all, w, md)
}

///|
test "a chat opened first writes nothing up to its view, reads its trees in one statement, and runs as many statements with five times the chats" {
  let totals : Array[Int] = []
  for chats in [20, 100] {
    let db = account(chats)
    let store = MdStore::new(@sql.Sql::open(db.shell, "acct"), station)
    let (view, all, w, md) = opened(db, store, 7)
    assert_eq(w, 0)
    assert_eq(md, 1)
    totals.push(all)
    // long replies: the window comes down from 30 to what a screen of them takes
    assert_true(view.entries.length() >= first_shown_fewest && view.entries.length() <= 10)
    assert_eq(view.entries.last().unwrap().n, 40)
    assert_eq(view.unread, [])
    assert_eq(view.trees.length(), view.entries.filter(e => e.author_kind == "agent").length())
    assert_eq(view.last_opened, None)
    // short lines: the whole 30
    let (short, _, w2, md2) = opened(db, store, 3)
    assert_eq(short.entries.length(), 30)
    assert_eq(short.entries[0].n, 11)
    assert_eq(w2, 0)
    assert_eq(md2, 1)
    // a chat of every kind: edits are in the window, not counted as shown
    let (mixed, _, w3, _) = opened(db, store, 12)
    assert_eq(w3, 0)
    assert_true(mixed.entries.iter().any(e => e.kind == "edit"))
    assert_true(store.pending())
  }
  assert_eq(totals, [3, 3])
}

///|
test "what showing noted is written after, in one transaction, and the next open reads when it was opened" {
  let db = account(20)
  let later = Ref(0)
  let store = MdStore::new(@sql.Sql::open(db.shell, "acct"), station, later=() => later.val += 1)
  let (view, _, _, _) = opened(db, store, 7)
  ignore(opened(db, store, 3))
  // told once that something is pending, however much came to be
  assert_eq(later.val, 1)
  let from = db.ran.length()
  assert_true(store.flush_turn())
  let (_, w, _, begun, committed) = db.since(from)
  assert_eq(begun, 1)
  assert_eq(committed, 1)
  // two logs opened, every tree shown noted shown again (the agents' in both windows), and the transaction's two
  let touched = view.trees.length() + 15
  assert_eq(w, 2 + touched + 2)
  assert_eq(db.log_use.get("entry s1 7"), Some(now))
  for key, _ in view.trees {
    assert_eq(db.md.get("s1 \{key}").map(r => r.used), Some(now))
  }
  // nothing left: a turn after writes nothing
  let again = db.ran.length()
  assert_false(store.flush_turn())
  assert_eq(db.ran.length(), again)
  // a store of a run after reads when it was opened, and notes no tree shown again within a day
  let next = MdStore::new(@sql.Sql::open(db.shell, "acct"), station)
  let (view2, _, w2, _) = opened(db, next, 7)
  assert_eq(w2, 0)
  assert_eq(view2.last_opened, Some(now))
  let from2 = db.ran.length()
  assert_true(next.flush_turn())
  let (_, w3, _, _, _) = db.since(from2)
  // the log opened alone, in its transaction
  assert_eq(w3, 3)
}

///|
test "a chat opened at a place reads a screen's context each side of it" {
  let db = account(20)
  let store = MdStore::new(@sql.Sql::open(db.shell, "acct"), station)
  let (view, all, w, _) = opened(db, store, 3, rows=10, at=20)
  assert_eq(view.entries.map(e => e.n), [10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29])
  assert_eq(all, 3)
  assert_eq(w, 0)
}

///|
test "a tree not kept is drawn from an older reading's in one more statement, or read and then kept" {
  let db = account(20)
  // thread 3's last reply kept under an older reading's key alone; its one before not at all
  let last = "ok 40"
  let before = "ok 38"
  let key_last = md_key(last)
  let key_before = md_key(before)
  db.md.remove("s1 \{key_last}")
  db.md.remove("s1 \{key_before}")
  let old_key = older_md_keys(key_last)[0]
  assert_true(old_key.has_prefix("10."))
  db.put_tree(station, old_key, "[\"old\"]", now)
  let store = MdStore::new(@sql.Sql::open(db.shell, "acct"), station)
  let (view, all, w, md) = opened(db, store, 3)
  assert_eq(w, 0)
  assert_eq(md, 2)
  assert_eq(all, 4)
  assert_eq(view.trees.get(key_last), Some("[\"old\"]"))
  assert_eq(view.unread, [key_before])
  // read here: kept pending, read back at once, written with the rest
  store.put_prepared(key_before, "[\"new\"]", of_="t:3", at=now)
  assert_eq(store.get(key_before, now), Some("[\"new\"]"))
  assert_true(store.has(key_before))
  ignore(store.flush_turn())
  assert_eq(db.md.get("s1 \{key_before}").map(r => r.json), Some("[\"new\"]"))
  // in place of the one it replaces
  store.put_prepared(key_last, "[\"now\"]", of_="t:3", at=now, replaces=old_key)
  ignore(store.flush_turn())
  assert_true(db.md.contains("s1 \{key_last}"))
  assert_false(db.md.contains("s1 \{old_key}"))
  assert_false(store.has(old_key))
}

///|
test "after a flush the same store reads back what it wrote: no statement for a tree it put, no tree noted shown again" {
  let db = account(20)
  let store = MdStore::new(@sql.Sql::open(db.shell, "acct"), station)
  // a tree put and written: asked again, read of no statement
  store.put_prepared("11.1.a.b", "[\"put\"]", of_="t:3", at=now)
  assert_true(store.flush_turn())
  let from = db.ran.length()
  assert_eq(store.get("11.1.a.b", now), Some("[\"put\"]"))
  assert_true(store.has("11.1.a.b"))
  assert_eq(db.ran.length(), from)
  assert_false(store.pending())
  // a tree kept long ago, shown: noted shown and written; shown again by the same store, nothing pending
  let (view, _, _, _) = opened(db, store, 7)
  assert_true(store.flush_turn())
  for key, _ in view.trees {
    assert_eq(store.get(key, now + 1L), view.trees.get(key))
  }
  assert_false(store.pending())
  let from2 = db.ran.length()
  assert_false(store.flush_turn())
  assert_eq(db.ran.length(), from2)
}

///|
test "a text's key is the TypeScript core's (markdown.ts mdKey)" {
  // (each printed by markdown.ts's mdKey in Node, 2026-11-18)
  assert_eq(md_key(""), "11.0.ztntfp.9zloz")
  assert_eq(md_key("hello"), "11.5.m3bicr.1nhy8oo")
  assert_eq(md_key("中文 **粗体**\n```js\nx\n```"), "11.21.1g3pc5c.13brcon")
  assert_eq(md_key("😀 emoji"), "11.8.vhhzna.4gxozi")
  assert_eq(older_md_keys("11.5.a.b"), [
    "10.5.a.b", "9.5.a.b", "8.5.a.b", "7.5.a.b", "6.5.a.b", "5.5.a.b", "4.5.a.b", "3.5.a.b",
    "2.5.a.b", "1.5.a.b",
  ])
}

///|
/// A message of `text`, for what it takes at least.
fn msg(text : String, files? : Int = 0, author_kind? : String = "agent", notice? : String) -> Entry {
  { n: 1, kind: "message", author_kind, author: "", text, notice, files, letter: false }
}

///|
test "what a message takes at least is the TypeScript core's (topics.ts entryMinRows)" {
  assert_eq(entry_min_rows(msg("one line")), 1)
  // 3 lines: 1 + floor(2 × 0.55)
  assert_eq(entry_min_rows(msg("a\nb\nc")), 2)
  // blank lines and white space alone are not counted
  assert_eq(entry_min_rows(msg("a\n\n   \nb")), 1)
  // a line of 250 characters wraps twice: 3 lines
  assert_eq(entry_min_rows(msg("x".repeat(250))), 2)
  // files: 2 more
  assert_eq(entry_min_rows(msg("a", files=1)), 3)
  // 6 at most
  assert_eq(entry_min_rows(msg(long_reply(1))), 6)
  // a notice, and the station's words: folded to a line
  assert_eq(entry_min_rows(msg(long_reply(1), notice="x")), 1)
  assert_eq(entry_min_rows(msg(long_reply(1), author_kind="station")), 1)
  // 5 lines, the last of them empty: 1 + floor(4 × 0.55)
  assert_eq(entry_min_rows(msg("a\n".repeat(5))), 1 + 4 * 55 / 100)
}

///|
test "a window at a chat's end holds the fewest a screen of long replies needs, but never more than rows" {
  let long = (n : Int) => Entry::{
    n,
    kind: "message",
    author_kind: "agent",
    author: "",
    text: long_reply(n),
    notice: None,
    files: 0,
    letter: false,
  }
  let entries = Array::makei(40, i => long(i + 1))
  // 6 of 6 rows each fill 30 rows: 6
  assert_eq(first_shown_window(entries, 30), (34, 40))
  // fewer rows than the fewest: as many as rows
  assert_eq(first_shown_window(entries, 4), (36, 40))
  // nothing held
  assert_eq(first_shown_window([], 30), (0, 0))
  // a letter between agents is in the window, not counted
  entries[39] = { ..entries[39], letter: true }
  assert_eq(first_shown_window(entries, 30), (33, 40))
}
