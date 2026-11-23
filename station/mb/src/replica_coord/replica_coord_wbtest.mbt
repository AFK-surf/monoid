// What of the package needs no host: names, the rendezvous order, a stream's hash, the merging of presets, heads,
// errors, and what a moved chat is told.

///|
test "a copy's names" {
  inspect(is_station("a".repeat(64)), content="true")
  inspect(is_station("A".repeat(64)), content="false")
  inspect(is_gen("lz5x0-0123abcd"), content="true")
  inspect(is_gen("LZ-0123abcd"), content="false")
  inspect(is_batch("0000000001-0000000004-00000000.ndjson.zst"), content="true")
  inspect(is_batch("0000000001-0000000004-0000000.ndjson.zst"), content="false")
  inspect(is_workspace("W_1-x"), content="true")
  inspect(is_workspace(""), content="false")
  inspect(is_handover_id("lz5x0-7331-aaaaaaaa-01234567"), content="true")
  inspect(gen_made("lz5x0-0123abcd"), content="36912564")
}

///|
test "the stations that keep a copy are the same whatever their order" {
  let a = "a".repeat(64)
  let b = "b".repeat(64)
  let c = "c".repeat(64)
  let d = "d".repeat(64)
  let one = keepers("W1", a, [a, b, c, d])
  let two = keepers("W1", a, [d, c, b, a, b])
  assert_eq(one, two)
  assert_eq(one.length(), 2)
  assert_true(!one.contains(a))
  assert_eq(keepers("W1", a, [a, b]), [b])
}

///|
test "a hash taken a piece at a time is the whole's" {
  let data = @utf8.encode("the quick brown fox jumps over the lazy dog".repeat(37))
  let h = @hash.Sha256::new()
  h.update(data[0:5])
  h.update(data[5:64])
  h.update(data[64:])
  assert_eq(h.hex(), @memory.sha256_hex(data))
  inspect(@hash.Sha256::new().hex(), content="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
}

///|
test "presets merged: the newer of each, ours first" {
  let ours = parse("{\"presets\":[{\"id\":\"p1\",\"rev\":2,\"name\":\"ours\"}],\"other\":1}")
  let theirs = parse("{\"presets\":[{\"id\":\"p1\",\"rev\":3,\"name\":\"theirs\"},{\"id\":\"p2\",\"name\":\"new\"}],\"gone\":[{\"id\":\"p3\",\"gone\":true}]}")
  let (file, taken) = merge_presets(ours, theirs)
  inspect(taken, content="3")
  inspect(
    stringify(file),
    content="{\"presets\":[{\"id\":\"p1\",\"rev\":3,\"name\":\"theirs\"},{\"id\":\"p2\",\"name\":\"new\"}],\"other\":1,\"gone\":[{\"id\":\"p3\",\"gone\":true}]}",
  )
}

///|
test "numbers said as the TypeScript says them" {
  inspect(base36(1800000000000.0), content="mywpiww0")
  inspect(gb(1073741824.0 * 2.25), content="2.3 GB")
  inspect(backoff(5000.0, 3, 600000.0), content="40000")
  inspect(backoff(5000.0, 30, 600000.0), content="600000")
  inspect(floor_of(Some(500.0 * 1073741824.0)), content="53687091200")
  inspect(floor_of(None), content="21474836480")
  inspect(unanswered("the connection was reset"), content="true")
  inspect(unanswered("refused"), content="false")
}

///|
test "what a store's change tells the export" {
  let t = Told::nothing()
  assert_true(tell(t, parse("{\"type\":\"thread\",\"id\":3,\"entries\":[]}")))
  assert_true(!tell(t, parse("{\"type\":\"nothing\"}")))
  assert_true(tell(t, parse("{\"type\":\"read\",\"viewer\":\"v\",\"thread\":1}")))
  inspect(
    stringify(t.to_json()),
    content="{\"sessions\":[],\"threads\":[3],\"removedSessions\":[],\"removedThreads\":[],\"marks\":[{\"table\":\"reads\",\"key\":{\"viewer\":\"v\",\"thread\":1}}]}",
  )
}

///|
test "connects as they go on the other station" {
  let a = "a".repeat(64)
  let b = "b".repeat(64)
  let out = connects_there(["slack1"], ["ember", "slack1", "x@" + b], a, b)
  assert_eq(out, [("slack1", "slack1@" + a), ("x@" + b, "x")])
}

///|
test "as_head validates version, gen, batches, file hashes, and integer to" {
  let hash = "a".repeat(64)
  let batch = "0000000001-0000000004-00000000.ndjson.zst"
  let valid = parse(
    "{\"v\":1,\"origin\":\"s1\",\"workspace\":\"W1\",\"gen\":\"lz5x0-0123abcd\",\"to\":4,\"made\":100,\"batches\":[\"" +
    batch +
    "\"],\"files\":{\"" +
    hash +
    "\":12},\"runs\":[{\"run\":\"r1\",\"from\":1}]}",
  )
  let h = as_head(valid).unwrap()
  assert_eq(head_gen(h), "lz5x0-0123abcd")
  assert_eq(head_to(h), 4.0)
  assert_eq(head_made(h), 100.0)
  assert_eq(head_batches(h), [batch])
  assert_eq(head_files(h), [hash])
  assert_eq(head_runs(h), [("r1", 1.0)])

  assert_true(as_head(set(valid, "v", jn(2.0))) is None)
  assert_true(as_head(set(valid, "gen", js("BAD"))) is None)
  assert_true(as_head(set(valid, "to", jn(1.5))) is None)
  assert_true(as_head(set(valid, "batches", ja([js("bad.zst")]))) is None)
  assert_true(as_head(set(valid, "files", jo([("not-a-hash", jn(1.0))]))) is None)
}

///|
test "Thrown error helpers classify Refused, Said, and system codes" {
  let r : Error = refused("no space")
  assert_true(is_refused(r))
  assert_eq(kind_of(r), "Refused")
  assert_eq(message_of(r), "no space")
  assert_eq(code_of(r), "")

  let s : Error = said("done moving")
  assert_false(is_refused(s))
  assert_eq(kind_of(s), "Said")
  assert_eq(message_of(s), "done moving")

  let io : Error = Thrown("Error", jo([("message", js("missing")), ("code", js("ENOENT"))]))
  assert_eq(code_of(io), "ENOENT")
  assert_eq(message_of(io), "missing")
}

///|
test "fixed1 and string_map / pair_get helpers" {
  assert_eq(fixed1(0.0), "0.0")
  assert_eq(fixed1(2.25), "2.3")
  assert_eq(fixed1(9.99), "10.0")
  let m = string_map(Some(parse("{\"a\":\"1\",\"b\":2,\"c\":\"three\"}")))
  assert_eq(m, [("a", "1"), ("c", "three")])
  assert_eq(pair_get(m, "c"), Some("three"))
  assert_eq(pair_get(m, "b"), None)
  assert_eq(stringify(pairs_json(m)), "{\"a\":\"1\",\"c\":\"three\"}")
}

///|
test "tell tracks sessions, removals, and ignores unrelated events" {
  let t = Told::nothing()
  assert_true(tell(t, parse("{\"type\":\"session\",\"key\":\"s1\"}")))
  assert_true(tell(t, parse("{\"type\":\"sessionRemoved\",\"key\":\"s2\",\"ws\":\"W1\"}")))
  assert_true(tell(t, parse("{\"type\":\"threadRemoved\",\"id\":9}")))
  inspect(
    stringify(t.to_json()),
    content="{\"sessions\":[\"s1\"],\"threads\":[],\"removedSessions\":[{\"key\":\"s2\",\"ws\":\"W1\"}],\"removedThreads\":[{\"id\":9,\"ws\":null}],\"marks\":[]}",
  )
}

///|
/// An export's process of the test's own: the lines it was written, an answer given each ask as `answer` says (none:
/// it waits), its end once its stdin is closed (unless `end_on_eof` is false, simulating a stuck pass).
fn fake_export(
  written : Array[String],
  answer : (J) -> String?,
  started : Ref[Int],
  signals? : Array[String] = [],
  end_on_eof? : Bool = true,
  ignore_sigterm? : Bool = false,
) -> () -> ExportProcess raise {
  () => {
    started.val += 1
    let out : @effect.Queue[ExportSaid] = @effect.Queue::unbounded()
    let open = Ref(true)
    let dead = Ref(false)
    {
      write: b => {
        guard open.val else { return false }
        let line = @utf8.decode_lossy(b)
        written.push(line.trim_end(chars="\n").to_string())
        if (try Some(parse(line)) catch { _ => None }) is Some(asked) && answer(asked) is Some(said) {
          ignore(out.try_offer(Other))
          ignore(out.try_offer(Said(@utf8.encode(said + "\n"))))
        }
        true
      },
      end_input: () => {
        open.val = false
        if end_on_eof && !dead.val {
          dead.val = true
          ignore(out.try_offer(Ended(Some(0), None)))
        }
      },
      kill: sig => {
        signals.push(sig)
        open.val = false
        if !dead.val && (!ignore_sigterm || sig == "SIGKILL") {
          dead.val = true
          ignore(out.try_offer(Ended(None, Some(sig))))
        }
      },
      next: async fn() { out.take() },
    }
  }
}

///|
test "the export's process: an ask answered by its id, a process started told the workspaces first, started once" {
  let rt = @effect.Runtime::new()
  let written = []
  let started = Ref(0)
  let answer = (asked : J) => match str_at(asked, "type") {
    Some("pass") => Some("{\"id\":\{num_at(asked, "id").unwrap_or(0.0).to_int()},\"answer\":{\"empty\":true}}")
    Some("places") => Some("{\"id\":\{num_at(asked, "id").unwrap_or(0.0).to_int()},\"answer\":null}")
    _ => None
  }
  let runner = process_runner(fake_export(written, answer, started), () => 7.0)
  let got = Ref("")
  ignore(
    rt.fork(async fn() {
      try {
        (runner.places)(jo([("w1", js("/p"))]))
        got.val = stringify((runner.pass)(jo([])))
        (runner.close)()
      } catch {
        e => got.val = "failed: " + message_of(e)
      }
    }),
  )
  rt.advance(1)
  assert_eq(got.val, "{\"empty\":true}")
  assert_eq(started.val, 1)
  // (a process started told the workspaces first, then asked)
  assert_eq(written, [
    "{\"id\":1,\"type\":\"places\",\"now\":7,\"places\":{\"w1\":\"/p\"}}", "{\"id\":2,\"type\":\"places\",\"now\":7,\"places\":{\"w1\":\"/p\"}}",
    "{\"id\":3,\"type\":\"pass\",\"now\":7,\"told\":{}}", "{\"id\":0,\"type\":\"close\"}",
  ])
}

///|
test "the export closed while an ask waits on it: the ask answered by its end, the close by that end too, never stuck" {
  let rt = @effect.Runtime::new()
  let written = []
  let started = Ref(0)
  // (it answers nothing: the pass waits until the export ends)
  let runner = process_runner(fake_export(written, _ => None, started), () => 7.0)
  let passed = Ref("")
  let closed = Ref(false)
  ignore(
    rt.fork(async fn() {
      ignore((runner.pass)(jo([]))) catch {
        e => passed.val = message_of(e)
      }
    }),
  )
  rt.advance(1)
  assert_eq(written, ["{\"id\":1,\"type\":\"pass\",\"now\":7,\"told\":{}}"])
  ignore(
    rt.fork(async fn() {
      (runner.close)()
      closed.val = true
    }),
  )
  rt.advance(1)
  assert_eq(passed.val, "the copies' export ended (0, null)")
  assert_true(closed.val)
  assert_eq(written[1], "{\"id\":0,\"type\":\"close\"}")
  // (closed: no ask starts it again)
  let after = Ref("")
  ignore(rt.fork(async fn() { ignore((runner.pass)(jo([]))) catch { e => after.val = message_of(e) } }))
  rt.advance(1)
  assert_eq(after.val, "the copies' thread is closed")
  assert_eq(started.val, 1)
}

///|
test "the export closed with no ask on it waits for its end itself" {
  let rt = @effect.Runtime::new()
  let written = []
  let started = Ref(0)
  let answer = (asked : J) => Some("{\"id\":\{num_at(asked, "id").unwrap_or(0.0).to_int()},\"answer\":1}")
  let runner = process_runner(fake_export(written, answer, started), () => 7.0)
  let closed = Ref(false)
  ignore(
    rt.fork(async fn() {
      ignore((runner.sources)(["h"]))
      (runner.close)()
      closed.val = true
    }),
  )
  rt.advance(1)
  assert_true(closed.val)
  assert_eq(started.val, 1)
}

///|
/// A head of this station's generation `lz5x0-0123abcd` up to `to`, of `batches`.
fn head_at(to : Int, batches : Array[String]) -> J raise {
  parse(
    "{\"v\":1,\"origin\":\"s1\",\"workspace\":\"W1\",\"gen\":\"lz5x0-0123abcd\",\"to\":\{to},\"made\":\{to * 10},\"batches\":[" +
    batches.map(b => "\"\{b}\"").join(",") +
    "],\"files\":{},\"runs\":[{\"run\":\"r1\",\"from\":1}]}",
  )
}

///|
/// Brings a place of the test's own (it holds nothing; what it is put, `put`) level by `level_newest`, its batches read
/// as `batch` says, the newest head `newest`'s: the head it went with, how far, how many times it went, or the error.
fn level_by_newest(
  head : J,
  newest : () -> J?,
  batch : (String) -> Bytes raise,
  put : Array[String],
) -> (String, Int) {
  let rt = @effect.Runtime::new()
  let place : Place = {
    held: fn(_, _) { Held::nothing() },
    put: fn(_, _, _, kind, name, _) { put.push("\{kind}:\{name}") },
    put_file: fn(_, _, _, _) { () },
    drop: fn(_, _, _, _, _) { () },
  }
  let went = Ref(0)
  let got = Ref("")
  ignore(
    rt.fork(async fn() {
      try {
        let (h, done) = level_newest(head, async fn(_) { newest() }, async fn(h) {
          went.val += 1
          level(place, "W1", { head: h, batch: b => batch(b), sources: _ => [] })
        })
        got.val = match done {
          Level(to, _, _) => "\{head_said(h)} level to \{num_text(to)}"
          Behind => "behind"
        }
      } catch {
        e => got.val = "failed: \{code_of(e)} \{message_of(e)}"
      }
    }),
  )
  rt.advance(1)
  (got.val, went.val)
}

///|
/// A batch read from the folder of `gone`'s batches: ENOENT for those, bytes for the rest.
fn batches_but(gone : Array[String]) -> (String) -> Bytes raise {
  name => {
    if gone.contains(name) {
      raise Thrown("Error", jo([("message", js("ENOENT: no such file or directory, open '\{name}'")), ("code", js("ENOENT"))]))
    }
    @utf8.encode(name)
  }
}

///|
test "a batch compacted away while a place is brought level: level with the newer head at once, no failure" {
  let old_batch = "0000000001-0000000004-00000000.ndjson.zst"
  let merged = "0000000001-0000000009-00000000.ndjson.zst"
  let old = head_at(4, [old_batch])
  let next = head_at(9, [merged])
  let put = []
  // (the export merged the old batch into a new one and took it away; `passed` says the new head)
  let (got, went) = level_by_newest(old, () => Some(next), batches_but([old_batch]), put)
  assert_eq(got, "lz5x0-0123abcd:9:90 level to 9")
  assert_eq(went, 2)
  assert_eq(put, ["batch:" + merged, "head:head.json"])
}

///|
test "a batch gone with no newer head, another error, or gone again and again: the place's failure as before" {
  let b1 = "0000000001-0000000004-00000000.ndjson.zst"
  let b2 = "0000000001-0000000006-00000000.ndjson.zst"
  let b3 = "0000000001-0000000008-00000000.ndjson.zst"
  let b4 = "0000000001-0000000009-00000000.ndjson.zst"
  let old = head_at(4, [b1])
  // (no head newer than the one it went with)
  let (got, went) = level_by_newest(old, () => Some(old), batches_but([b1]), [])
  assert_eq(got, "failed: ENOENT ENOENT: no such file or directory, open '\{b1}'")
  assert_eq(went, 1)
  let (got, went) = level_by_newest(old, () => None, batches_but([b1]), [])
  assert_true(got.has_prefix("failed: ENOENT"))
  assert_eq(went, 1)
  // (a newer head of no batches is no copy to bring a place level with)
  let empty = head_at(5, [])
  let (got, went) = level_by_newest(old, () => Some(empty), batches_but([b1]), [])
  assert_true(got.has_prefix("failed: ENOENT"))
  assert_eq(went, 1)
  // (not a file gone: not tried again)
  let newer = head_at(9, [b4])
  let (got, went) = level_by_newest(old, () => Some(newer), _ => raise failed("the place said no"), [])
  assert_eq(got, "failed:  the place said no")
  assert_eq(went, 1)
  // (each newer head's batch gone too: tried with `stale_heads_most` newer ones, then the failure)
  let heads = [head_at(6, [b2]), head_at(8, [b3]), head_at(9, [b4])]
  let at = Ref(0)
  let newest = () => {
    let h = heads[at.val]
    at.val = (at.val + 1).min(heads.length() - 1)
    Some(h)
  }
  let (got, went) = level_by_newest(old, newest, batches_but([b1, b2, b3, b4]), [])
  assert_eq(got, "failed: ENOENT ENOENT: no such file or directory, open '\{b3}'")
  assert_eq(went, 1 + stale_heads_most)
}

///|
test "process_runner close force-kills a stuck export after close_grace_ms (SIGTERM and SIGKILL escalation)" {
  // Case 1: stuck in pass, ignores close/EOF, exits on SIGTERM after close_grace_ms.
  let rt = @effect.Runtime::new()
  let written = []
  let signals = []
  let started = Ref(0)
  let runner = process_runner(
    fake_export(written, _ => None, started, signals~, end_on_eof=false),
    () => 7.0,
    close_grace_ms=20.0,
  )
  let passed = Ref("")
  let closed = Ref(false)
  ignore(
    rt.fork(async fn() {
      ignore((runner.pass)(jo([]))) catch {
        e => passed.val = message_of(e)
      }
    }),
  )
  rt.advance(1)
  ignore(
    rt.fork(async fn() {
      (runner.close)()
      closed.val = true
    }),
  )
  rt.advance(10)
  assert_false(closed.val)
  assert_eq(signals, [])
  rt.advance(15)
  assert_true(closed.val)
  assert_eq(signals, ["SIGTERM"])
  assert_eq(passed.val, "the copies' export ended (null, SIGTERM)")

  // Case 2: ignores SIGTERM too -> escalates to SIGKILL after min(close_grace_ms, 500).
  let rt2 = @effect.Runtime::new()
  let written2 = []
  let signals2 = []
  let started2 = Ref(0)
  let runner2 = process_runner(
    fake_export(written2, _ => None, started2, signals=signals2, end_on_eof=false, ignore_sigterm=true),
    () => 7.0,
    close_grace_ms=20.0,
  )
  let passed2 = Ref("")
  let closed2 = Ref(false)
  ignore(
    rt2.fork(async fn() {
      ignore((runner2.pass)(jo([]))) catch {
        e => passed2.val = message_of(e)
      }
    }),
  )
  rt2.advance(1)
  ignore(
    rt2.fork(async fn() {
      (runner2.close)()
      closed2.val = true
    }),
  )
  rt2.advance(25)
  assert_false(closed2.val)
  assert_eq(signals2, ["SIGTERM"])
  rt2.advance(25)
  assert_true(closed2.val)
  assert_eq(signals2, ["SIGTERM", "SIGKILL"])
  assert_eq(passed2.val, "the copies' export ended (null, SIGKILL)")
}

///|
test "Copies pass failure strictly respects backoff even when told arrives during retry window" {
  let rt = @effect.Runtime::new()
  let after = (ms : Double, f : () -> Unit) => {
    let cancelled = Ref(false)
    let fiber = rt.fork_quiet(async fn() {
      @effect.sleep(ms.to_int())
      if !cancelled.val {
        f()
      }
    })
    () => {
      cancelled.val = true
      fiber.interrupt()
    }
  }
  let should_fail = Ref(true)
  let pass_calls = Ref(0)
  let seen_sessions : Array[String] = []
  let eloop = ExportLoop::new(
    after,
    f => ignore(rt.fork_quiet(f)),
    async fn(told) {
      pass_calls.val += 1
      if should_fail.val {
        raise failed("database is locked")
      }
      for s in strings_of(at(told, "sessions")) {
        seen_sessions.push(s)
      }
      jo([("heads", jo([])), ("more", jb(false)), ("wrote", ji(1)), ("empty", jb(false))])
    },
    _ => (),
    _ => (),
    (_, _, _) => (),
  )

  // Trigger first change -> gather fires at 1000ms -> pass #1 fails -> 5000ms backoff armed.
  eloop.told(parse("{\"type\":\"session\",\"key\":\"s1\"}"))
  rt.advance(1000)
  assert_eq(pass_calls.val, 1)
  assert_eq(eloop.export_error, Some("database is locked"))
  assert_eq(eloop.export_tries, 1)

  // New changes arrive during the 5000ms backoff window -> must NOT re-enter pass within 1s!
  eloop.told(parse("{\"type\":\"session\",\"key\":\"s2\"}"))
  rt.advance(1000)
  assert_eq(pass_calls.val, 1)
  eloop.told(parse("{\"type\":\"session\",\"key\":\"s3\"}"))
  rt.advance(3000)
  assert_eq(pass_calls.val, 1)

  // Advance past 5000ms -> retry fires and recovers, exporting all accumulated sessions together!
  should_fail.val = false
  rt.advance(1500)
  assert_eq(pass_calls.val, 2)
  assert_eq(eloop.export_error, None)
  assert_eq(eloop.export_tries, 0)
  assert_true(seen_sessions.contains("s1"))
  assert_true(seen_sessions.contains("s2"))
  assert_true(seen_sessions.contains("s3"))

  ignore(rt.fork(async fn() { eloop.close(async fn() { () }) }))
  rt.advance(1)
}

///|
test "ExportLoop close invokes close_runner before waiting on an in-flight stuck pass" {
  let rt = @effect.Runtime::new()
  let written = []
  let signals = []
  let started = Ref(0)
  let runner = process_runner(
    fake_export(written, _ => None, started, signals~, end_on_eof=false),
    () => 7.0,
    close_grace_ms=20.0,
  )
  let eloop = ExportLoop::new(
    (ms, f) => {
      let cancelled = Ref(false)
      let fiber = rt.fork_quiet(async fn() {
        @effect.sleep(ms.to_int())
        if !cancelled.val {
          f()
        }
      })
      () => {
        cancelled.val = true
        fiber.interrupt()
      }
    },
    f => ignore(rt.fork_quiet(f)),
    told => (runner.pass)(told),
    _ => (),
    _ => (),
    (_, _, _) => (),
  )
  // Start a pass that hangs on the stuck child process.
  ignore(rt.fork(async fn() { eloop.pass() }))
  rt.advance(1)
  assert_true(eloop.passing is Some(_))

  let closed = Ref(false)
  ignore(
    rt.fork(async fn() {
      eloop.close(runner.close)
      closed.val = true
    }),
  )
  rt.advance(10)
  assert_false(closed.val)
  // After close_grace_ms (20ms), runner.close sends SIGTERM, unblocking the hung pass and letting close() return.
  rt.advance(20)
  assert_true(closed.val)
  assert_eq(signals, ["SIGTERM"])
  assert_true(eloop.passing is None)
}

///|
/// A head of generation `gen` naming `files` and `transcripts` (each an object keyed by hash, as heads have them).
fn head_naming(gen : String, to : Int, batches : Array[String], files : Array[String], transcripts : Array[String]) -> J {
  jo([
    ("v", ji(1)),
    ("origin", js("s1")),
    ("workspace", js("W1")),
    ("gen", js(gen)),
    ("to", ji(to)),
    ("made", ji(to * 10)),
    ("batches", jstrs(batches)),
    ("files", jo(files.map(f => (f, ji(1))))),
    ("transcriptFiles", jo(transcripts.map(f => (f, ji(1))))),
    ("runs", ja([jo([("run", js("r1")), ("from", ji(1))])])),
  ])
}

///|
test "level with a hundred-thousand-scale head: lacking files sent from their first source, old ones dropped, others kept" {
  let n = 20_000
  let gen = "lz5x0-0123abcd"
  let b1 = "0000000001-0000000004-00000000.ndjson.zst"
  let b2 = "0000000005-0000000009-00000000.ndjson.zst"
  let transcripts = Array::makei(n, i => "t\{i}")
  let files = Array::makei(10, i => "f\{i}")
  // (the place holds every transcript but the last 100, and a file only an older generation names)
  let held_files = transcripts[0:n - 100].to_array()
  held_files.push("other")
  let older = head_naming("lz5w0-0123abcd", 3, [], ["other"], [])
  let place_held : Held = { gens: [{ gen: "lz5w0-0123abcd", head: Some(older), batches: [] }], files: held_files }
  let sent : Array[(String, String)] = []
  let dropped : Array[(Array[String], Array[String])] = []
  let put = []
  let place : Place = {
    held: fn(_, _) { place_held },
    put: fn(_, _, _, kind, name, _) { put.push("\{kind}:\{name}") },
    put_file: fn(_, _, hash, source) { sent.push((hash, source)) },
    drop: fn(_, _, _, batches, files) { dropped.push((batches, files)) },
  }
  // (three of the lacking have no source; one is named twice, the first taken)
  let no_source = ["t\{n - 1}", "t\{n - 2}", "f9"]
  let sources = (hashes : Array[String]) => {
    let out = []
    for h in hashes {
      if !no_source.contains(h) {
        out.push((h, "/src/\{h}"))
      }
    }
    out.push(("f0", "/second/f0"))
    out
  }
  let asked = Ref(0)
  let rt = @effect.Runtime::new()
  let got : Ref[Levelled?] = Ref(None)
  let head1 = head_naming(gen, 4, [b1], files, transcripts)
  ignore(
    rt.fork(async fn() {
      got.val = Some(
        level(place, "W1", {
          head: head1,
          batch: b => @utf8.encode(b),
          sources: async fn(hs) {
            asked.val += 1
            sources(hs)
          },
        }),
      )
    }),
  )
  rt.advance(1)
  guard got.val is Some(Level(to, missing, k)) else { fail("not level") }
  assert_eq(to, 4.0)
  assert_eq(missing, 3)
  assert_eq(asked.val, 1)
  assert_eq(sent.length(), 107)
  assert_true(sent.contains(("f0", "/src/f0")))
  assert_false(sent.contains(("f0", "/second/f0")))
  // (a partial head once the chats' files are in, the whole one after the transcripts)
  assert_eq(put, ["batch:" + b1, "head:head.json", "head:head.json"])
  // (nothing named by an older generation goes)
  assert_eq(dropped.length(), 0)
  assert_true(k.files.contains("other"))
  // Two transcripts let go and the batch compacted: both go, the older generation's file stays.
  let fewer = transcripts[2:].to_array()
  let head2 = head_naming(gen, 9, [b2], files, fewer)
  put.clear()
  ignore(
    rt.fork(async fn() {
      got.val = Some(level(place, "W1", { head: head2, batch: b => @utf8.encode(b), sources: async fn(hs) { sources(hs) } }, known=Some(k)))
    }),
  )
  rt.advance(1)
  guard got.val is Some(Level(to, missing, k)) else { fail("not level") }
  assert_eq(to, 9.0)
  assert_eq(missing, 3)
  assert_eq(put, ["batch:" + b2, "head:head.json"])
  assert_eq(dropped.length(), 1)
  let (old_batches, old_files) = dropped[0]
  assert_eq(old_batches, [b1])
  old_files.sort()
  assert_eq(old_files, ["t0", "t1"])
  assert_eq(k.batches, [b2])
  assert_false(k.files.contains("t0"))
  assert_true(k.files.contains("other"))
  assert_true(k.files.contains("t2"))
}

///|
test "level puts the chats' head before the transcripts it lacks, partial, and the whole head after them" {
  let gen = "lz5x0-0123abcd"
  let b1 = "0000000001-0000000004-00000000.ndjson.zst"
  let transcripts = ["t0", "t1", "t2", "t3"]
  let held_files = ["t0"]
  let heads : Array[J] = []
  let put = []
  let sent = []
  let fail_at : Ref[String?] = Ref(Some("t2"))
  let place_held : Ref[Held] = Ref({ gens: [], files: held_files })
  let place : Place = {
    held: fn(_, _) { place_held.val },
    put: fn(_, _, _, kind, name, bytes) {
      put.push("\{kind}:\{name}")
      if kind == "head" {
        heads.push(@jsjson.parse(@utf8.decode_lossy(bytes)))
      }
    },
    put_file: fn(_, _, hash, _) {
      if fail_at.val == Some(hash) {
        fail("connection lost")
      }
      sent.push(hash)
    },
    drop: fn(_, _, _, _, _) { () },
  }
  let own = {
    head: head_naming(gen, 4, [b1], ["f0"], transcripts),
    batch: fn(b) { @utf8.encode(b) },
    sources: async fn(hs : Array[String]) { hs.map(h => (h, "/src/\{h}")) },
  }
  let rt = @effect.Runtime::new()
  let failed = Ref(false)
  ignore(
    rt.fork(async fn() {
      try ignore(level(place, "W1", own)) catch {
        _ => failed.val = true
      }
    }),
  )
  rt.advance(1)
  // The chat's file and batch went, then a head naming only the transcripts held, then the sending failed.
  assert_true(failed.val)
  assert_eq(put, ["batch:" + b1, "head:head.json"])
  assert_eq(sent, ["f0", "t1"])
  assert_eq(head_transcript_files(heads[0]), ["t0"])
  assert_eq(head_files(heads[0]), ["f0"])
  assert_eq(head_to(heads[0]), 4.0)
  assert_true(at(heads[0], "partial") is Some(Bool(true)))
  // Asked again: the place holds the partial head at the same `to`, so the whole head still goes once all is sent.
  place_held.val = { gens: [{ gen, head: Some(heads[0]), batches: [b1] }], files: ["t0", "f0", "t1"] }
  fail_at.val = None
  put.clear()
  let got : Ref[Levelled?] = Ref(None)
  ignore(rt.fork(async fn() { got.val = Some(level(place, "W1", own)) }))
  rt.advance(1)
  guard got.val is Some(Level(to, 0, _)) else { fail("not level") }
  assert_eq(to, 4.0)
  assert_eq(put, ["head:head.json"])
  assert_eq(head_transcript_files(heads[1]), transcripts)
  assert_true(at(heads[1], "partial") is None)
}

///|
test "holds_all and hand_over over twenty thousand files: all held, one lacking, only the lacking sent" {
  let n = 20_000
  let gen = "lz5x0-0123abcd"
  let b1 = "0000000001-0000000004-00000000.ndjson.zst"
  let all = Array::makei(n, i => "h\{i}")
  let head = head_naming(gen, 4, [b1], all, [])
  let mine : Held = { gens: [{ gen, head: Some(head), batches: [b1] }], files: all }
  assert_true(holds_all(mine, mine))
  let short = all[1:].to_array()
  assert_false(holds_all(mine, { gens: mine.gens, files: short }))
  assert_false(holds_all(mine, { gens: [], files: all }))
  // A place of mine on disk; the other lacks the first file and the generation.
  let rt = @effect.Runtime::new()
  let theirs : Ref[Held] = Ref({ gens: [], files: short.copy() })
  let sent = []
  let put = []
  let to : Place = {
    held: fn(_, _) { theirs.val },
    put: fn(_, _, g, kind, name, _) {
      put.push("\{kind}:\{name}")
      if kind == "head" {
        theirs.val = { gens: [{ gen: g, head: Some(head), batches: [b1] }], files: theirs.val.files }
      }
    },
    put_file: fn(_, _, hash, _) {
      sent.push(hash)
      theirs.val.files.push(hash)
    },
    drop: fn(_, _, _, _, _) { () },
  }
  let got = Ref(false)
  let read = []
  ignore(
    rt.fork(async fn() {
      got.val = hand_over_from(
        mine,
        async fn(hash) { Some("/files/\{hash}") },
        async fn(g, b) {
          read.push("\{g}/\{b}")
          Some(b"b")
        },
        to,
        "W1",
        "s1",
      )
    }),
  )
  rt.advance(1)
  assert_eq(sent, [all[0]])
  assert_eq(put, ["batch:" + b1, "head:head.json"])
  assert_eq(read, [gen + "/" + b1])
  assert_true(got.val)
  // (all held there now: nothing sent again)
  sent.clear()
  put.clear()
  ignore(rt.fork(async fn() { got.val = hand_over_from(mine, async fn(_) { None }, async fn(_, _) { None }, to, "W1", "s1") }))
  rt.advance(1)
  assert_eq(sent.length(), 0)
  assert_eq(put.length(), 0)
  assert_true(got.val)
}

///|
test "restore_file_names: the head's files, then the held transcripts, each once, in order" {
  let head = head_naming("lz5x0-0123abcd", 4, [], ["a", "b", "c"], ["c", "d", "e", "a", "f", "d"])
  assert_eq(restore_file_names(head, ["a", "c", "d", "f", "z"]), ["a", "b", "c", "d", "f"])
  assert_eq(restore_file_names(head, []), ["a", "b", "c"])
  let n = 20_000
  let files = Array::makei(100, i => "f\{i}")
  let transcripts = Array::makei(n, i => "t\{i}")
  // (the first ten files again among the transcripts; every other transcript held)
  let named = files[0:10].to_array()
  named.append(transcripts)
  let held = transcripts.filter(t => t.length() % 2 == 0)
  held.append(files)
  let got = restore_file_names(head_naming("lz5x0-0123abcd", 4, [], files, named), held)
  let want = files.copy()
  want.append(transcripts.filter(t => t.length() % 2 == 0))
  assert_eq(got, want)
}

///|
test "the export's process: a long line in many pieces, several lines in one piece, newlines at a piece's edges" {
  let rt = @effect.Runtime::new()
  let out : @effect.Queue[ExportSaid] = @effect.Queue::unbounded()
  let written = []
  let said = (s : String) => ignore(out.try_offer(Said(@utf8.encode(s))))
  let big = "a".repeat(256 * 16 * 1024 - 20)
  let start = fn() -> ExportProcess raise {
    {
      write: b => {
        written.push(@utf8.decode_lossy(b))
        match written.length() {
          1 => {
            // (an answer of 4 MB in 256 pieces of 16 KB, no newline but the last, something else between)
            let line = @utf8.encode("{\"id\":1,\"answer\":\"\{big}\"}\n")
            let piece = 16 * 1024
            let mut at = 0
            while at < line.length() {
              let end = (at + piece).min(line.length())
              ignore(out.try_offer(Said(line[at:end].to_owned())))
              ignore(out.try_offer(Other))
              at = end
            }
          }
          // (noise and an empty line before it, the next ask's answer after it, its newline not yet come)
          2 => said("noise\n\n{\"id\":2,\"answer\":2}\n{\"id\":3,\"answer\":3}")
          // (the newline first in a piece)
          3 => said("\n")
          // (the newline last in a piece, an empty piece and something else between)
          4 => {
            said("{\"id\":4,")
            ignore(out.try_offer(Other))
            said("")
            said("\"answer\":4}\n")
          }
          // (a piece's newline ends one answer and the next is whole after it)
          5 => {
            said("{\"id\":5,\"answer\":5}")
            said("\n{\"id\":6,\"answer\":6}\n")
          }
          _ => ()
        }
        true
      },
      end_input: () => ignore(out.try_offer(Ended(Some(0), None))),
      kill: _ => (),
      next: async fn() { out.take() },
    }
  }
  let runner = process_runner(start, () => 7.0)
  let got = []
  ignore(
    rt.fork(async fn() {
      try {
        match (runner.pass)(jo([])) {
          Str(s) => got.push("1:\{s.length()}:\{s == big}")
          other => got.push("1:" + stringify(other))
        }
        for _ in 2..=6 {
          got.push(stringify((runner.pass)(jo([]))))
        }
        (runner.close)()
      } catch {
        e => got.push("failed: " + message_of(e))
      }
    }),
  )
  rt.advance(1)
  assert_eq(got, ["1:\{big.length()}:true", "2", "3", "4", "5", "6"])
}

///|
test "level_newest awaits an in-flight passing export on ENOENT and retries with the new head" {
  let rt = @effect.Runtime::new()
  let b1 = "0000000001-0000000004-00000000.ndjson.zst"
  let b2 = "0000000001-0000000009-00000000.ndjson.zst"
  let old = head_at(4, [b1])
  let next = head_at(9, [b2])
  let cur_head = Ref(old)
  let passing_done : @effect.Deferred[Unit] = @effect.Deferred::new()
  let passing : Ref[@effect.Deferred[Unit]?] = Ref(Some(passing_done))
  let put = []
  let place : Place = {
    held: fn(_, _) { Held::nothing() },
    put: fn(_, _, _, kind, name, _) { put.push("\{kind}:\{name}") },
    put_file: fn(_, _, _, _) { () },
    drop: fn(_, _, _, _, _) { () },
  }
  let went = Ref(0)
  let got = Ref("")
  let newest = async fn(cur : J) -> J? {
    let mut h = Some(cur_head.val)
    if h is Some(x) && head_said(x) == head_said(cur) {
      match passing.val {
        Some(d) => {
          d.wait()
          h = Some(cur_head.val)
        }
        None => ()
      }
    }
    h
  }
  ignore(
    rt.fork(async fn() {
      try {
        let (h, done) = level_newest(old, newest, async fn(h) {
          went.val += 1
          level(place, "W1", { head: h, batch: b => batches_but([b1])(b), sources: _ => [] })
        })
        got.val = match done {
          Level(to, _, _) => "\{head_said(h)} level to \{num_text(to)}"
          Behind => "behind"
        }
      } catch {
        e => got.val = "failed: \{code_of(e)} \{message_of(e)}"
      }
    }),
  )
  // First attempt hits ENOENT on b1 and suspends waiting on the in-flight passing Deferred.
  rt.advance(1)
  assert_eq(went.val, 1)
  assert_eq(got.val, "")
  // In-flight pass finishes with the new head -> level_newest wakes up and retries with next.
  cur_head.val = next
  passing.val = None
  ignore(passing_done.succeed(()))
  rt.advance(1)
  assert_eq(went.val, 2)
  assert_eq(got.val, "lz5x0-0123abcd:9:90 level to 9")
  assert_eq(put, ["batch:" + b2, "head:head.json"])
}

///|
test "level treats put_file ENOENT for non-transcript files as missing, while re-raising ENOENT for transcriptFiles chunks" {
  let rt = @effect.Runtime::new()
  let gen = "lz5x0-0123abcd"
  let b1 = "0000000001-0000000004-00000000.ndjson.zst"
  let sent = []
  let put = []
  let place : Place = {
    held: fn(_, _) { Held::nothing() },
    put: fn(_, _, _, kind, name, _) { put.push("\{kind}:\{name}") },
    put_file: fn(_, _, hash, source) {
      if hash == "f1" || hash == "t1" {
        raise Thrown("Error", jo([("message", js("ENOENT: no such file or directory, open '\{source}'")), ("code", js("ENOENT"))]))
      }
      sent.push(hash)
    },
    drop: fn(_, _, _, _, _) { () },
  }
  // Case 1: ordinary attachment f1 vanishes before put_file -> missing += 1, f2 and head still succeed.
  let head1 = head_naming(gen, 4, [b1], ["f1", "f2"], [])
  let got1 : Ref[Levelled?] = Ref(None)
  ignore(
    rt.fork(async fn() {
      got1.val = Some(
        level(place, "W1", {
          head: head1,
          batch: b => @utf8.encode(b),
          sources: async fn(hs) { hs.map(h => (h, "/src/\{h}")) },
        }),
      )
    }),
  )
  rt.advance(1)
  guard got1.val is Some(Level(to, missing, k)) else { fail("expected Level") }
  assert_eq(to, 4.0)
  assert_eq(missing, 1)
  assert_eq(sent, ["f2"])
  assert_eq(put, ["batch:" + b1, "head:head.json"])
  assert_false(k.files.contains("f1"))
  assert_true(k.files.contains("f2"))

  // Case 2: transcriptFiles chunk t1 hits ENOENT -> still raises ENOENT for outer level_newest retry.
  let head2 = head_naming(gen, 4, [b1], [], ["t1"])
  let err2 = Ref("")
  ignore(
    rt.fork(async fn() {
      try {
        ignore(
          level(place, "W1", {
            head: head2,
            batch: b => @utf8.encode(b),
            sources: async fn(hs) { hs.map(h => (h, "/src/\{h}")) },
          }),
        )
      } catch {
        e => err2.val = code_of(e)
      }
    }),
  )
  rt.advance(1)
  assert_eq(err2.val, "ENOENT")
}

///|
test "WriteGuard coordinates concurrent replica.put and hand_over: quiet window, write_seq abort, and atomic rename gate" {
  let rt = @effect.Runtime::new()
  let now = Ref(1000.0)
  let g = WriteGuard::new()
  let ws = "W1"
  let origin = "a".repeat(64)

  // 1. Active write blocks handover start.
  let put_gate : @effect.Deferred[Unit] = @effect.Deferred::new()
  let put_done = Ref(false)
  ignore(
    rt.fork(async fn() {
      g.guard_write(() => now.val, ws, origin, async fn() {
        put_gate.wait()
        put_done.val = true
      })
    }),
  )
  rt.advance(1)
  assert_true(g.begin_handover(now.val, true, ws, origin) is None)
  assert_true(g.begin_handover(now.val, false, ws, origin) is None)

  // Finish the write at t=1000 -> quiet window blocks handover when accept_others=true, but allows when accept_others=false.
  ignore(put_gate.succeed(()))
  rt.advance(1)
  assert_true(put_done.val)
  assert_true(g.begin_handover(now.val + 5000.0, true, ws, origin) is None)
  assert_eq(g.begin_handover(now.val + 5000.0, false, ws, origin), Some(1))

  // 2. After handover_quiet_ms, begin_handover succeeds with seq_before=1.
  //    If a new replica.put arrives before atomic_remove, write_seq advances -> atomic_remove aborts without renaming/removing!
  now.val = 1000.0 + handover_quiet_ms
  guard g.begin_handover(now.val, true, ws, origin) is Some(seq_before) else { fail("expected handover allowed") }
  assert_eq(seq_before, 1)

  ignore(rt.fork(async fn() { g.guard_write(() => now.val, ws, origin, async fn() { () }) }))
  rt.advance(1)

  let events : Array[String] = []
  let aborted = Ref(true)
  ignore(
    rt.fork(async fn() {
      aborted.val = !g.atomic_remove(
        ws,
        origin,
        seq_before,
        ".dropping-test-0001",
        async fn(name) { events.push("rename:" + name) },
        async fn(name) { events.push("rm:" + name) },
      )
    }),
  )
  rt.advance(1)
  assert_true(aborted.val)
  assert_eq(events, [])

  // 3. Advance past quiet window again -> atomic_remove renames under removing gate, blocking a concurrent put until rename finishes,
  //    then releases the gate BEFORE slow rm_dropping runs so the put proceeds without waiting on rm -rf.
  now.val = now.val + handover_quiet_ms
  guard g.begin_handover(now.val, true, ws, origin) is Some(seq2) else { fail("expected handover allowed after quiet") }
  assert_eq(seq2, 2)

  let rename_gate : @effect.Deferred[Unit] = @effect.Deferred::new()
  let rm_gate : @effect.Deferred[Unit] = @effect.Deferred::new()
  let removed = Ref(false)
  ignore(
    rt.fork(async fn() {
      removed.val = g.atomic_remove(
        ws,
        origin,
        seq2,
        ".dropping-test-0002",
        async fn(name) {
          events.push("rename-start:" + name)
          rename_gate.wait()
          events.push("rename-end:" + name)
        },
        async fn(name) {
          events.push("rm-start:" + name)
          rm_gate.wait()
          events.push("rm-end:" + name)
        },
      )
    }),
  )
  rt.advance(1)
  assert_eq(events, ["rename-start:.dropping-test-0002"])

  // A concurrent put arrives during rename -> must wait on removing gate!
  ignore(
    rt.fork(async fn() {
      g.guard_write(() => now.val, ws, origin, async fn() { events.push("put-after-rename") })
    }),
  )
  rt.advance(1)
  assert_eq(events, ["rename-start:.dropping-test-0002"])

  // Finish rename while rm is still pending -> removing gate releases and put runs immediately without waiting on rm!
  ignore(rename_gate.succeed(()))
  rt.advance(1)
  assert_true(events.contains("rename-end:.dropping-test-0002"))
  assert_true(events.contains("rm-start:.dropping-test-0002"))
  assert_true(events.contains("put-after-rename"))
  assert_false(events.contains("rm-end:.dropping-test-0002"))

  ignore(rm_gate.succeed(()))
  rt.advance(1)
  assert_true(removed.val)
  assert_true(events.contains("rm-end:.dropping-test-0002"))

  // 4. Clean atomic_remove with no concurrent write clears last_write_at while preserving monotonic write_seq.
  let key = "\{ws}\n\{origin}"
  assert_eq(g.write_seq.get(key), Some(3))
  assert_true(g.last_write_at.get(key) is Some(_))
  now.val = now.val + handover_quiet_ms
  guard g.begin_handover(now.val, true, ws, origin) is Some(seq3) else { fail("expected handover allowed") }
  assert_eq(seq3, 3)
  let removed4 = Ref(false)
  ignore(
    rt.fork(async fn() {
      removed4.val = g.atomic_remove(
        ws,
        origin,
        seq3,
        ".dropping-test-0003",
        async fn(_) { () },
        async fn(_) { () },
      )
    }),
  )
  rt.advance(1)
  assert_true(removed4.val)
  assert_true(g.last_write_at.get(key) is None)
  assert_eq(g.write_seq.get(key), Some(3))
}

///|
test "serve_place invokes guard_write for replica.put (file/batch/head) and replica.drop, not for replica.held or replica.list" {
  let rt = @effect.Runtime::new()
  let ws = "W1"
  let origin = "a".repeat(64)
  let hash = "1".repeat(64)
  let gen = "lz5x0-0123abcd"
  let batch = "0000000001-0000000004-00000000.ndjson.zst"
  let guarded : Array[String] = []
  let ops : Array[String] = []
  let place : ServePlace = {
    origins: async fn(_) {
      ops.push("origins")
      []
    },
    held: async fn(_, _) {
      ops.push("held")
      Held::nothing()
    },
    path_of: async fn(_, _, _, _) { None },
    stat_size: async fn(_) { 0.0 },
    put_file: async fn(_, _, name, _) { ops.push("put_file:" + name) },
    put: async fn(_, _, _, kind, name, _) { ops.push("put:" + kind + ":" + name) },
    drop: async fn(_, _, _, _, _) { ops.push("drop") },
  }
  let guard_fn : async (String, String, async () -> Unit) -> Unit = async fn(w, o, f) {
    guarded.push("\{w}:\{o}")
    f()
  }
  let call = async fn(req : J, body : Body?) {
    ignore(
      serve_place(
        place,
        (_, _) => true,
        (_, _, _, _) => [],
        Some(() => true),
        Some(guard_fn),
        origin,
        req,
        body,
        Some(ws),
      ),
    )
  }
  let err = Ref("")
  ignore(
    rt.fork(async fn() {
      try {
        call(jo([("method", js("replica.list")), ("workspace", js(ws))]), None)
        call(jo([("method", js("replica.held")), ("workspace", js(ws)), ("origin", js(origin))]), None)
        call(
          jo([("method", js("replica.put")), ("workspace", js(ws)), ("origin", js(origin)), ("kind", js("file")), ("name", js(hash))]),
          Some(Whole(b"filedata")),
        )
        call(
          jo([("method", js("replica.put")), ("workspace", js(ws)), ("origin", js(origin)), ("gen", js(gen)), ("kind", js("batch")), ("name", js(batch))]),
          Some(Whole(b"batchdata")),
        )
        call(
          jo([("method", js("replica.put")), ("workspace", js(ws)), ("origin", js(origin)), ("gen", js(gen)), ("kind", js("head")), ("name", js("head.json"))]),
          Some(Whole(b"{}")),
        )
        call(
          jo([("method", js("replica.drop")), ("workspace", js(ws)), ("origin", js(origin)), ("gen", js(gen)), ("batches", ja([])), ("files", ja([]))]),
          None,
        )
      } catch {
        e => err.val = message_of(e)
      }
    }),
  )
  rt.advance(1)
  assert_eq(err.val, "")
  assert_eq(ops, ["origins", "held", "put_file:" + hash, "put:batch:" + batch, "put:head:head.json", "drop"])
  // Exactly 4 guarded writes: put(file), put(batch), put(head), drop; 0 for list/held.
  assert_eq(guarded.length(), 4)
  assert_eq(guarded, ["\{ws}:\{origin}", "\{ws}:\{origin}", "\{ws}:\{origin}", "\{ws}:\{origin}"])
}

///|
test "prune_non_targets_map cancels overflow keeper retry timer and asked flag while preserving active, s3, and other workspaces" {
  let make_keeping = (busy : Bool, asked : Bool, cancelled : Ref[Int]) => {
    let k : Keeping = {
      to: 0.0,
      at: None,
      error: Some("offline"),
      reason: Some("offline"),
      missing: 0,
      busy,
      again: Some(() => { cancelled.val += 1 }),
      tries: 2,
      asked,
      known: None,
      head: None,
      partial: false,
      lacking: 0,
    }
    k
  }
  let c_first = Ref(0)
  let c_third_idle = Ref(0)
  let c_fourth_busy = Ref(0)
  let c_s3 = Ref(0)
  let c_other_ws = Ref(0)

  let keeping : Map[String, Keeping] = {}
  keeping["W1\nfirst"] = make_keeping(false, true, c_first)
  keeping["W1\nthird"] = make_keeping(false, true, c_third_idle)
  keeping["W1\nfourth"] = make_keeping(true, true, c_fourth_busy)
  keeping["W1\ns3:bucket1"] = make_keeping(false, true, c_s3)
  keeping["W2\nthird"] = make_keeping(false, true, c_other_ws)

  prune_non_targets_map(keeping, "W1", ["first", "second"])

  // Active target untouched.
  assert_eq(c_first.val, 0)
  assert_true(keeping.contains("W1\nfirst"))
  assert_true(keeping.get("W1\nfirst").unwrap().again is Some(_))
  assert_true(keeping.get("W1\nfirst").unwrap().asked)

  // Idle non-target overflow keeper: timer cancelled, entry removed.
  assert_eq(c_third_idle.val, 1)
  assert_false(keeping.contains("W1\nthird"))

  // Busy non-target overflow keeper: timer cancelled, asked cleared, entry kept until busy finishes.
  assert_eq(c_fourth_busy.val, 1)
  assert_true(keeping.contains("W1\nfourth"))
  let fourth = keeping.get("W1\nfourth").unwrap()
  assert_true(fourth.again is None)
  assert_false(fourth.asked)

  // S3 target and other workspace untouched.
  assert_eq(c_s3.val, 0)
  assert_true(keeping.contains("W1\ns3:bucket1"))
  assert_eq(c_other_ws.val, 0)
  assert_true(keeping.contains("W2\nthird"))
}
