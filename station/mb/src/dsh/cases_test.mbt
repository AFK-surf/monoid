// The program's reading of DeepSeek Harness' lines held to what the TypeScript station made of them
// (as_typescript_said_test.mbt, written by station/test/runtime-cases.ts).

///|
/// runtime-cases.ts `long`.
fn long(n : Int) -> String {
  let out = StringBuilder()
  for i in 0..<n {
    if i % 7 == 3 {
      out.write_char((0xd83d : Int).unsafe_to_char())
      out.write_char((0xde00 : Int).unsafe_to_char())
    } else {
      out.write_char((0x61 + i % 26).unsafe_to_char())
    }
  }
  out.to_string()
}

///|
/// runtime-cases.ts `expand`: `<<long:N>>` as N characters.
fn expand(v : @jsjson.JValue) -> @jsjson.JValue {
  match v {
    Str(s) => {
      let t = s
      if t.has_prefix("<<long:") && t.has_suffix(">>") {
        let mut n = 0
        for i in 7..<(t.length() - 2) {
          n = n * 10 + (t.unsafe_charcode_at(i) - 0x30)
        }
        Str(long(n))
      } else {
        v
      }
    }
    Arr(items) => Arr(items.map(expand))
    Obj(fields) => Obj(fields.map(f => (f.0, expand(f.1))))
    v => v
  }
}

///|
/// runtime-cases.ts `folded`: a string past 512 code units as its length and their FNV-1a hash.
fn folded(v : @jsjson.JValue) -> @jsjson.JValue {
  match v {
    Str(s) if s.length() > 512 => {
      let mut h : UInt = 0x811c9dc5U
      for i in 0..<s.length() {
        h = (h ^ s.unsafe_get(i).to_int().reinterpret_as_uint()) * 0x01000193U
      }
      Str("<<\{s.length()}:\{h.to_string(radix=16)}>>")
    }
    Arr(items) => Arr(items.map(folded))
    Obj(fields) => Obj(fields.map(f => (f.0, folded(f.1))))
    v => v
  }
}

///|
fn parsed(s : String) -> @jsjson.JValue raise {
  @jsjson.parse(s) catch {
    _ => fail("not JSON: \{s}")
  }
}

///|
/// Whether what was said is what node said, compared as JSON.stringify writes each.
fn same(what : String, at : Int, got : @jsjson.JValue, said : String) -> Unit raise {
  let a = @jsjson.stringify(folded(got))
  let b = @jsjson.stringify(parsed(said))
  if a != b {
    fail("\{what} of step \{at}:\n got  \{a}\n said \{b}")
  }
}

///|
test "each line as the TypeScript read it" {
  let mut s = @dsh.Session::new(@dsh.Turn::of_json(Null), @dsh.Live::new())
  for at, step in steps_said {
    let (line, events, node, turn, state) = step
    let v = expand(parsed(line))
    let mut got : Array[@jsjson.JValue] = []
    let mut read = false
    if v.get("$new") is Some(_) {
      s = @dsh.Session::new(@dsh.Turn::of_json(Null), @dsh.Live::new())
    } else if v.get("$prompt") is Some(_) {
      got = s.prompted()
    } else if v.get("$aborting") is Some(_) {
      s.turn.aborting = true
    } else if v.get("$cut") is Some(_) {
      got = s.cut_short()
    } else {
      let said = s.line(v)
      got = said.events
      read = said.node
    }
    same("events", at, Arr(got), events)
    if read.to_string() != node {
      fail("whether Node reads step \{at}: \{read}, node said \{node}")
    }
    same("turn", at, s.turn.json(), turn)
    same("state", at, s.live.state(), state)
  }
}

///|
test "what a crash reads again as the TypeScript read it" {
  for at, r in replays_said {
    let (lines, result) = r
    let replay = @dsh.Replay::new()
    guard expand(parsed(lines)) is Arr(all) else { fail("not lines") }
    for v in all {
      replay.line(v)
    }
    let got = @jsjson.JValue::Obj([
      ("session", match replay.session { Some(s) => Str(s); None => Null }),
      ("turn", replay.turn.json()),
      ("live", replay.live.state()),
    ])
    same("replay", at, got, result)
  }
}
