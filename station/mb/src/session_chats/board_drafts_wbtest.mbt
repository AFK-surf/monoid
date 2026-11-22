// Native MoonBit whitebox tests for BoardDrafts (board_drafts.mbt).

///|
fn[X] board_ran(f : async () -> X) -> Result[X, Error] {
  let rt = @effect.Runtime::new()
  let fiber = rt.fork(f)
  ignore(rt.run_ready())
  match fiber.poll() {
    Some(Succeeded(v)) => Ok(v)
    Some(Failed(e)) => Err(e)
    _ => abort("board_ran did not finish")
  }
}

///|
fn board_ok_ran(f : async () -> J) -> J {
  match board_ran(f) {
    Ok(v) => v
    Err(e) => abort("unexpected error: \{e}")
  }
}

///|
fn live_draft_j(
  id : String,
  owner : String,
  rev : Int,
  at_ms : Int,
  updated_at : Int,
  title : String,
  files? : Array[J] = [],
) -> J {
  jo([
    ("id", js(id)),
    ("owner", js(owner)),
    ("rev", ji(rev)),
    ("at", ji(at_ms)),
    ("updatedAt", ji(updated_at)),
    ("title", js(title)),
    ("station", js("w1/st1")),
    ("stationName", js("Studio")),
    ("files", ja(files)),
  ])
}

///|
fn gone_draft_j(id : String, owner : String, rev : Int, updated_at : Int) -> J {
  jo([
    ("id", js(id)),
    ("owner", js(owner)),
    ("rev", ji(rev)),
    ("gone", jb(true)),
    ("updatedAt", ji(updated_at)),
  ])
}

///|
priv struct MemFile {
  bytes : Bytes
  mut mtime_ms : Double
}

///|
priv struct MemBoardEnv {
  store : Map[String, String]
  mut writes : Int
  files : Map[String, MemFile]
  dirs : Set[String]
  mut now_ms : Double
  warnings : Array[String]
}

///|
fn MemBoardEnv::new(now_ms : Double) -> MemBoardEnv {
  let dirs : Set[String] = Set::new()
  dirs.add("/data/uploads")
  dirs.add("/data/board-files")
  { store: Map::new(), writes: 0, files: Map::new(), dirs, now_ms, warnings: [] }
}

///|
fn MemBoardEnv::put_file(self : MemBoardEnv, path : String, bytes : Bytes) -> Unit {
  self.files[path] = { bytes, mtime_ms: self.now_ms }
  self.dirs.add(@nodepath.dirname("/", path))
}

///|
fn MemBoardEnv::board(self : MemBoardEnv) -> BoardDrafts {
  BoardDrafts::new({
    read_store: (ws, sub) => self.store.get("\{ws}\u{0}\{sub}"),
    write_store: (ws, sub, text) => {
      self.writes += 1
      self.store["\{ws}\u{0}\{sub}"] = text
    },
    dir: () => "/data/board-files",
    uploads: () => "/data/uploads",
    now: () => self.now_ms,
    sep: "/",
    resolve: p => if starts(p, "/") { @nodepath.join("/", [p]) } else { @nodepath.join("/", ["/cwd", p]) },
    stat: async fn(p) {
      match self.files.get(p) {
        Some(f) => Some({ is_file: true, size: f.bytes.length().to_double(), mtime_ms: f.mtime_ms })
        None => if self.dirs.contains(p) { Some({ is_file: false, size: 0.0, mtime_ms: self.now_ms }) } else { None }
      }
    },
    mkdir: async fn(p) { self.dirs.add(p) },
    rename: async fn(from, to) {
      match self.files.get(from) {
        Some(f) => {
          self.files.remove(from)
          self.files[to] = f
          self.dirs.add(@nodepath.dirname("/", to))
        }
        None => raise fail_("ENOENT")
      }
    },
    rm: async fn(p, recursive) {
      self.files.remove(p)
      if recursive {
        let prefix = p + "/"
        let drop_f : Array[String] = []
        for k, _ in self.files {
          if starts(k, prefix) {
            drop_f.push(k)
          }
        }
        for k in drop_f {
          self.files.remove(k)
        }
        let drop_d : Array[String] = []
        for d in self.dirs {
          if d == p || starts(d, prefix) {
            drop_d.push(d)
          }
        }
        for d in drop_d {
          self.dirs.remove(d)
        }
      }
    },
    readdir: async fn(p) {
      let prefix = p + "/"
      let names : Set[String] = Set::new()
      let mut any_dir = self.dirs.contains(p)
      for k, _ in self.files {
        if starts(k, prefix) {
          any_dir = true
          let rest = slice(k, prefix.length())
          let idx = index_of(rest, "/")
          names.add(if idx < 0 { rest } else { slice(rest, 0, b=idx) })
        }
      }
      for d in self.dirs {
        if starts(d, prefix) {
          any_dir = true
          let rest = slice(d, prefix.length())
          let idx = index_of(rest, "/")
          names.add(if idx < 0 { rest } else { slice(rest, 0, b=idx) })
        }
      }
      if !any_dir {
        None
      } else {
        Some(names.iter().collect())
      }
    },
    utimes: async fn(p, ms) {
      match self.files.get(p) {
        Some(f) => f.mtime_ms = ms
        None => ()
      }
    },
    read_bytes: async fn(p) {
      match self.files.get(p) {
        Some(f) => f.bytes
        None => raise fail_("ENOENT")
      }
    },
    copy_file: async fn(from, to) {
      match self.files.get(from) {
        Some(f) => {
          self.files[to] = { bytes: f.bytes, mtime_ms: self.now_ms }
          self.dirs.add(@nodepath.dirname("/", to))
        }
        None => raise fail_("ENOENT")
      }
    },
    random_hex6: () => "a1b2c3",
    log_warn: (msg, _err) => self.warnings.push(msg),
  })
}

///|
test "draft_of validates, trims, dedups files, and refuses invalid records" {
  let ok = draft_of(
    jo([
      ("id", js("new:board-1")),
      ("owner", js("u1")),
      ("rev", ji(1)),
      ("at", ji(100)),
      ("updatedAt", ji(100)),
      ("title", js("  hello  ")),
      ("station", js("w1/s1")),
      (
        "files",
        ja([
          jo([("id", js("f1")), ("name", js("a.png")), ("size", ji(10))]),
          jo([("id", js("f1")), ("name", js("dup.png")), ("size", ji(20))]),
        ]),
      ),
    ]),
  )
  assert_eq(str_of(at(Some(ok), "title")), Some("hello"))
  assert_eq(arr_of(at(Some(ok), "files")).unwrap().length(), 1)
  assert_eq(str_of(at(Some(ok), "stationName")), Some(""))

  // Gone draft strips extra fields
  let g = draft_of(
    jo([
      ("id", js("new:board-2")),
      ("owner", js("u1")),
      ("rev", ji(2)),
      ("gone", jb(true)),
      ("updatedAt", ji(200)),
      ("title", js("ignored")),
    ]),
  )
  assert_true(is_gone_draft(g))
  assert_true(at(Some(g), "title") is None)

  // Refusals carry DraftRefusal kind
  let expect_refusal = (raw : J, want : String) => {
    let got = try {
      ignore(draft_of(raw))
      None
    } catch {
      Thrown(kind, msg) => Some((kind, msg))
    }
    assert_eq(got, Some(("DraftRefusal", want)))
  }
  expect_refusal(js("nope"), "a draft is an object")
  expect_refusal(jo([("id", js("bad id!"))]), "id: 1 to 120 letters, digits, :, ., - or _")
  expect_refusal(
    jo([("id", js("d1")), ("owner", js("u1")), ("rev", ji(0)), ("updatedAt", ji(1))]),
    "rev: how many times it was changed, from 1",
  )
  expect_refusal(
    jo([("id", js("d1")), ("owner", js("u1")), ("rev", ji(1)), ("at", ji(1)), ("updatedAt", ji(1)), ("title", js("   ")), ("station", js("w/s"))]),
    "a draft needs words or a file",
  )
}

///|
test "merge_drafts resolves conflicts, never resurrects deletions, and enforces caps" {
  let d1_v1 = live_draft_j("d1", "u1", 1, 100, 100, "v1")
  let d1_v2 = live_draft_j("d1", "u1", 2, 100, 150, "v2")
  let d1_gone_v2 = gone_draft_j("d1", "u1", 2, 120)
  // Higher rev wins; at same rev, gone beats live even with earlier updatedAt
  assert_true(jeq(newer_draft(d1_v1, d1_v2), d1_v2))
  assert_true(jeq(newer_draft(d1_v2, d1_gone_v2), d1_gone_v2))
  assert_true(jeq(newer_draft(d1_gone_v2, d1_v2), d1_gone_v2))

  let kept : Map[String, J] = Map::new()
  kept["d1"] = d1_gone_v2
  let (after, changed) = merge_drafts(kept, [d1_v1, d1_v2])
  assert_true(!changed)
  assert_true(is_gone_draft(after["d1"]))

  // Live cap (200): oldest by `at` turns into gone with rev + 1
  let many : Array[J] = []
  for i in 0..<(drafts_most + 3) {
    many.push(live_draft_j("d-\{i}", "u1", 1, i * 10, i * 10, "t-\{i}"))
  }
  let (capped, c2) = merge_drafts(Map::new(), many)
  assert_true(c2)
  let mut live_n = 0
  let mut gone_n = 0
  for _, r in capped {
    if is_gone_draft(r) {
      gone_n += 1
    } else {
      live_n += 1
    }
  }
  assert_eq(live_n, drafts_most)
  assert_eq(gone_n, 3)
  assert_true(is_gone_draft(capped["d-0"]))
  assert_eq(num_of(at(Some(capped["d-0"]), "rev")), Some(2.0))

  // Gone cap (200): oldest gone records are evicted
  let many_gone : Array[J] = []
  for i in 0..<(gone_drafts_most + 5) {
    many_gone.push(gone_draft_j("g-\{i}", "u1", 1, i * 10))
  }
  let (capped_gone, _) = merge_drafts(Map::new(), many_gone)
  assert_eq(capped_gone.length(), gone_drafts_most)
  assert_true(!capped_gone.contains("g-0"))
  assert_true(capped_gone.contains("g-\{gone_drafts_most + 4}"))
}

///|
test "BoardDrafts carry, keep, bytes, stage, .gone retention and 24h sweep" {
  let env = MemBoardEnv::new(1700000000000.0)
  let bd = env.board()
  let f1 = jo([("id", js("f1")), ("name", js("shot.png")), ("size", ji(4))])
  let f2 = jo([("id", js("f2")), ("name", js("note.txt")), ("size", ji(3))])
  let d1 = live_draft_j("new:board-1", "u1", 1, 1000, 1000, "hello", files=[f1, f2])

  // Carry rejects non-array, invalid draft, wrong owner
  match board_ran(async fn() { bd.carry("w1", "u1", js("bad")) }) {
    Err(Thrown("DraftRefusal", "drafts: a list of drafts")) => ()
    _ => fail("expected DraftRefusal for non-array")
  }
  match board_ran(async fn() { bd.carry("w1", "u1", ja([live_draft_j("new:board-1", "u2", 1, 1000, 1000, "hi")])) }) {
    Err(Thrown("DraftRefusal", "a draft is its person's own")) => ()
    _ => fail("expected DraftRefusal for wrong owner")
  }

  // First carry persists and reports changed: true
  let r1 = board_ok_ran(async fn() { bd.carry("w1", "u1", ja([d1])) })
  assert_eq(bool_of(at(Some(r1), "changed")), Some(true))
  assert_eq(env.writes, 1)

  // Identical carry does not rewrite store
  let r2 = board_ok_ran(async fn() { bd.carry("w1", "u1", ja([d1])) })
  assert_eq(bool_of(at(Some(r2), "changed")), Some(false))
  assert_eq(env.writes, 1)

  // keep rejects paths outside uploads, dotfiles, unknown draft/file
  env.put_file("/data/uploads/a.png", b"png!")
  env.put_file("/data/uploads/.secret", b"no")
  env.put_file("/data/other/x.png", b"no")
  match board_ran(async fn() { bd.keep("w1", "u1", "new:board-1", "f1", "/data/other/x.png") }) {
    Err(Thrown("DraftRefusal", "not an upload")) => ()
    _ => fail("expected not an upload for outside dir")
  }
  match board_ran(async fn() { bd.keep("w1", "u1", "new:board-1", "f1", "/data/uploads/../other/x.png") }) {
    Err(Thrown("DraftRefusal", "not an upload")) => ()
    _ => fail("expected not an upload for traversal")
  }
  match board_ran(async fn() { bd.keep("w1", "u1", "new:board-1", "f1", "/data/uploads/.secret") }) {
    Err(Thrown("DraftRefusal", "not an upload")) => ()
    _ => fail("expected not an upload for dotfile")
  }
  match board_ran(async fn() { bd.keep("w1", "u1", "new:board-1", "missing", "/data/uploads/a.png") }) {
    Err(Thrown("DraftRefusal", "no such draft or file")) => ()
    _ => fail("expected no such draft or file")
  }

  // Valid keep moves both files out of uploads
  let k1 = board_ok_ran(async fn() { bd.keep("w1", "u1", "new:board-1", "f1", "/data/uploads/a.png") })
  assert_eq(arr_of(at(Some(k1), "files")).unwrap().map(x => str_of(Some(x)).unwrap()), ["f1"])
  assert_true(!env.files.contains("/data/uploads/a.png"))
  env.put_file("/data/uploads/b.txt", b"hey")
  let k2 = board_ok_ran(async fn() { bd.keep("w1", "u1", "new:board-1", "f2", "/data/uploads/b.txt") })
  assert_eq(arr_of(at(Some(k2), "files")).unwrap().map(x => str_of(Some(x)).unwrap()), ["f1", "f2"])

  // bytes returns MIME type + raw bytes
  match board_ran(async fn() { bd.bytes("w1", "u1", "new:board-1", "f1") }) {
    Ok(Some((mime, bytes))) => {
      assert_eq(mime, "image/png")
      assert_eq(bytes, b"png!")
    }
    _ => fail("expected bytes for f1")
  }

  // Updating live draft to drop f2 removes f2 immediately
  let d1_drop_f2 = live_draft_j("new:board-1", "u1", 2, 1000, 1100, "hello", files=[f1])
  let r3 = board_ok_ran(async fn() { bd.carry("w1", "u1", ja([d1_drop_f2])) })
  assert_eq(arr_of(at(Some(r3), "files")).unwrap().map(x => str_of(Some(x)).unwrap()), ["f1"])
  match board_ran(async fn() { bd.bytes("w1", "u1", "new:board-1", "f2") }) {
    Ok(None) => ()
    _ => fail("expected f2 removed")
  }

  // Marking draft gone moves f1 into .gone, still readable and stageable within 24h
  env.now_ms = 1700000010000.0
  let d1_gone = gone_draft_j("new:board-1", "u1", 3, 1200)
  let r4 = board_ok_ran(async fn() { bd.carry("w1", "u1", ja([d1_gone])) })
  assert_eq(arr_of(at(Some(r4), "files")).unwrap().length(), 0)
  match board_ran(async fn() { bd.bytes("w1", "u1", "new:board-1", "f1") }) {
    Ok(Some((_, bytes))) => assert_eq(bytes, b"png!")
    _ => fail("expected f1 readable from .gone")
  }

  // stage sanitizes name and copies from .gone into uploads
  match board_ran(async fn() { bd.stage("w1", "u1", "new:board-1", "f1", "dir/..bad\u{01}name.png") }) {
    Ok(Some(staged)) => {
      assert_eq(str_of(at(Some(staged), "name")), Some("bad_name.png"))
      assert_eq(num_of(at(Some(staged), "size")), Some(4.0))
      let p = str_of(at(Some(staged), "path")).unwrap()
      assert_true(starts(p, "/data/uploads/2023-11-14T22-13-30-a1b2c3-bad_name.png"))
      assert_eq(env.files[p].bytes, b"png!")
    }
    _ => fail("expected stage from .gone to succeed")
  }

  // After > 24h, next carry sweeps .gone file
  env.now_ms = 1700000010000.0 + gone_files_ms + 1.0
  ignore(board_ok_ran(async fn() { bd.carry("w1", "u1", ja([])) }))
  match board_ran(async fn() { bd.bytes("w1", "u1", "new:board-1", "f1") }) {
    Ok(None) => ()
    _ => fail("expected .gone file swept after 24h")
  }
}
