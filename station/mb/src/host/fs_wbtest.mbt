///|
/// A disk of the test's, answering `fs.*` as client/shell does, each call answered a millisecond on (the shell answers each
/// from its threads, so fibers asking at once go on in between): its files and what was asked.
struct FakeDisk {
  files : Map[String, Bytes]
  asked : Array[String]
  /// The ops that fail, with the shell's words.
  failing : Map[String, String]
}

///|
fn FakeDisk::new() -> FakeDisk {
  { files: {}, asked: [], failing: {} }
}

///|
fn FakeDisk::call(self : FakeDisk) -> async (String, Json, Bytes?) -> Json {
  async fn(op, args, bytes) {
    @effect.sleep(1)
    let at = match args {
      { "path": String(p), .. } => p
      { "from": String(f), .. } => f
      _ => ""
    }
    self.asked.push("\{op} \{at}")
    if self.failing.get(op) is Some(words) {
      fail(words)
    }
    match (op, args) {
      ("fs.mkdir", _) => ()
      ("fs.put", { "path": String(p), .. }) => self.files[p] = bytes.unwrap_or(b"")
      ("fs.rename", { "from": String(from), "to": String(to), .. }) =>
        match self.files.get(from) {
          Some(b) => {
            self.files.remove(from)
            self.files[to] = b
          }
          None => fail("No such file or directory (os error 2)")
        }
      ("fs.remove", { "path": String(p), .. }) => self.files.remove(p)
      _ => fail("no op \{op}")
    }
    Json::null()
  }
}

///|
fn FakeDisk::beside(self : FakeDisk) -> Array[String] {
  self.files.keys().filter(k => k.has_suffix(".tmp")).collect()
}

///|
/// `n` fibers writing `path` at once, each its own bytes, beside it under `tmp`: how many of them failed.
fn write_at_once(disk : FakeDisk, tmp : (String) -> String, path : String, n : Int) -> Array[String] {
  let rt = @effect.Runtime::new()
  let fibers = []
  for i in 0..<n {
    fibers.push(
      rt.fork(async fn() {
        write_atomic_by(disk.call(), tmp, path, @utf8.encode("write \{i}"), 0o600, true, true, "/")
      }),
    )
  }
  rt.advance(100)
  let failed = []
  for f in fibers {
    match f.poll() {
      Some(Succeeded(_)) => ()
      Some(Failed(e)) => failed.push("\{e}")
      Some(Interrupted) => failed.push("interrupted")
      None => failed.push("not done")
    }
  }
  failed
}

///|
test "unique_tmp: every name of one file in one process its own" {
  let names = []
  for _ in 0..<100 {
    names.push(tmp_beside("/d/state.json", 4242))
  }
  let seen : Set[String] = Set([])
  for n in names {
    assert_true(n.has_prefix("/d/state.json.4242."))
    assert_true(n.has_suffix(".tmp"))
    seen.add(n)
  }
  assert_eq(seen.length(), 100)
}

///|
test "L13: ten fibers writing one file at once under the pid's name alone: renames fail ENOENT" {
  let disk = FakeDisk::new()
  let failed = write_at_once(disk, p => "\{p}.4242.tmp", "/d/agy/profile.json", 10)
  // (what the station did before: the first rename took the one file beside it, the others found it gone)
  assert_eq(failed.length(), 9)
  assert_true(failed[0].contains("No such file or directory"))
}

///|
test "L13: ten fibers writing one file at once: none fails, the file is one write whole, nothing left beside it" {
  let disk = FakeDisk::new()
  let failed = write_at_once(disk, p => tmp_beside(p, 4242), "/d/agy/profile.json", 10)
  assert_eq(failed, [])
  let text = @utf8.decode_lossy(disk.files.get("/d/agy/profile.json").unwrap())
  assert_true((0).until(10).any(i => text == "write \{i}"))
  assert_eq(disk.beside(), [])
  assert_eq(disk.files.length(), 1)
}

///|
test "write_atomic: its folder made by its separator, written beside, renamed into place" {
  let disk = FakeDisk::new()
  let rt = @effect.Runtime::new()
  let f = rt.fork(async fn() {
    write_atomic_by(disk.call(), _ => "C:\\d\\a.json.1.1.tmp", "C:\\d\\a.json", b"{}", 0o666, false, true, "\\")
  })
  rt.advance(100)
  assert_true(f.poll() is Some(Succeeded(_)))
  assert_eq(disk.asked, ["fs.mkdir C:\\d", "fs.put C:\\d\\a.json.1.1.tmp", "fs.rename C:\\d\\a.json.1.1.tmp"])
  assert_eq(disk.files.get("C:\\d\\a.json"), Some(b"{}"))
  // (no folder of its own to make)
  let bare = FakeDisk::new()
  let g = rt.fork(async fn() {
    write_atomic_by(bare.call(), p => p + ".t.tmp", "a.json", b"x", 0o666, false, true, "/")
  })
  rt.advance(100)
  assert_true(g.poll() is Some(Succeeded(_)))
  assert_eq(bare.asked, ["fs.put a.json.t.tmp", "fs.rename a.json.t.tmp"])
}

///|
test "write_atomic: a rename that fails lets go of what was written beside, and says why" {
  let disk = FakeDisk::new()
  disk.failing["fs.rename"] = "Permission denied (os error 13)"
  let rt = @effect.Runtime::new()
  let f = rt.fork(async fn() {
    write_atomic_by(disk.call(), p => tmp_beside(p, 7), "/d/a.json", b"x", 0o600, true, false, "/")
  })
  rt.advance(500)
  match f.poll() {
    Some(Failed(e)) => assert_true("\{e}".contains("Permission denied"))
    _ => fail("the write did not fail")
  }
  assert_eq(disk.beside(), [])
  assert_eq(disk.files.length(), 0)
  assert_eq(disk.asked.last().map(a => a.has_prefix("fs.remove /d/a.json.7.")), Some(true))
}

///|
test "write_atomic: a put that fails is let go of too, and a failing let-go hides nothing" {
  let disk = FakeDisk::new()
  disk.failing["fs.put"] = "No space left on device (os error 28)"
  disk.failing["fs.remove"] = "Input/output error (os error 5)"
  let rt = @effect.Runtime::new()
  let f = rt.fork(async fn() {
    write_atomic_by(disk.call(), p => tmp_beside(p, 7), "/d/a.json", b"x", 0o600, true, false, "/")
  })
  rt.advance(100)
  match f.poll() {
    Some(Failed(e)) => assert_true("\{e}".contains("No space left"))
    _ => fail("the write did not fail")
  }
  assert_eq(disk.asked.map(a => "\{a.split(" ").next().unwrap()}"), ["fs.put", "fs.remove"])
}

///|
test "read_bytes: hex as bytes, none where the file did not open, a failure for what is not hex" {
  assert_eq(bytes_answered("/a", Json::string("68690a")), Some(b"hi\n"))
  assert_eq(bytes_answered("/a", Json::string("")), Some(b""))
  assert_eq(bytes_answered("/a", Json::null()), None)
  let bad = try { Ok(bytes_answered("/a", Json::string("zz"))) } catch { e => Err(e) }
  assert_true(bad is Err(_))
}

///|
test "write_atomic: a write given up halfway still lets go of what it wrote beside" {
  let disk = FakeDisk::new()
  let rt = @effect.Runtime::new()
  let f = rt.fork(async fn() {
    write_atomic_by(disk.call(), p => p + ".1.1.tmp", "/d/a.json", b"x", 0o600, true, true, "/")
  })
  // (its folder made, its bytes being put beside it: the shell may have written some)
  rt.advance(1)
  assert_eq(disk.asked, ["fs.mkdir /d"])
  f.interrupt()
  rt.advance(100)
  assert_true(f.poll() is Some(Interrupted))
  assert_eq(disk.asked, ["fs.mkdir /d", "fs.remove /d/a.json.1.1.tmp"])
}

///|
test "rename_retrying_by retries EPERM/EBUSY/EACCES until success, throws when exhausted, and fails ENOENT at once" {
  let rt = @effect.Runtime::new()
  // Transient EPERM, EBUSY, EACCES succeed after retries with recorded backoff delays.
  for err_msg in [
    "Operation not permitted (os error 1)",
    "Device or resource busy (os error 16)",
    "Permission denied (os error 13)",
    "Access is denied. (os error 5)",
    "The process cannot access the file because it is being used by another process. (os error 32)",
  ] {
    let attempts = Ref::new(0)
    let waited : Array[Int] = []
    let f = rt.fork(async fn() {
      rename_retrying_by(
        async fn(_a, _b) {
          attempts.val += 1
          if attempts.val <= 2 {
            fail(err_msg)
          }
        },
        "/a",
        "/b",
        wait=async fn(ms) { waited.push(ms) },
      )
    })
    rt.advance(1)
    assert_true(f.poll() is Some(Succeeded(_)))
    assert_eq(attempts.val, 3)
    assert_eq(waited, [20, 40])
  }
  // Exhausted backoff raises the last error after all waits.
  let exhausted_attempts = Ref::new(0)
  let exhausted_waits : Array[Int] = []
  let f2 = rt.fork(async fn() {
    rename_retrying_by(
      async fn(_a, _b) {
        exhausted_attempts.val += 1
        fail("EPERM: operation not permitted")
      },
      "/a",
      "/b",
      wait=async fn(ms) { exhausted_waits.push(ms) },
    )
  })
  rt.advance(1)
  match f2.poll() {
    Some(Failed(e)) => assert_true("\{e}".contains("EPERM"))
    _ => fail("expected failure when backoff exhausted")
  }
  assert_eq(exhausted_attempts.val, 5)
  assert_eq(exhausted_waits, [20, 40, 80, 160])
  // Non-transient ENOENT fails immediately without retrying.
  let enoent_attempts = Ref::new(0)
  let enoent_waits : Array[Int] = []
  let f3 = rt.fork(async fn() {
    rename_retrying_by(
      async fn(_a, _b) {
        enoent_attempts.val += 1
        fail("No such file or directory (os error 2)")
      },
      "/a",
      "/b",
      wait=async fn(ms) { enoent_waits.push(ms) },
    )
  })
  rt.advance(1)
  match f3.poll() {
    Some(Failed(e)) => assert_true("\{e}".contains("No such file"))
    _ => fail("expected ENOENT failure")
  }
  assert_eq(enoent_attempts.val, 1)
  assert_eq(enoent_waits, [])
}
