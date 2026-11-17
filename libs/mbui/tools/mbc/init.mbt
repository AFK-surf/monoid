// moonbit_init in its packages' pieces, and what a unit's functions need defined.

///|
priv struct Run {
  p : Bytes
  sts : Array[Bytes]
  locs : BSet
}

///|
fn subset(a : BSet, b : BSet) -> Bool {
  for k in a.t.keys {
    if !b.has(k) {
      return false
    }
  }
  true
}

///|
/// moonbit_init (moonc's names) in pieces, each a run of it that is one package's: [(package, declarations,
/// statements)], in its order, or None when it is not as this expects. A statement setting a global (moonc's
/// _M0F…, or its object's header) is the global's package's, with what came before it since the one before (its
/// temporaries); the locals moonc declares at the start go to the piece that uses them, and pieces between two that
/// share a local are one.
fn init_pieces(text : Bytes) -> Array[(Bytes, Bytes, Bytes)]? {
  let b = blank(text)
  let start = find_byte(b, b'{', 0)
  let end = rfind_byte(b, b'}')
  if start < 0 || end <= start {
    return None
  }
  let stmts : Array[Bytes] = []
  let mut depth = 0
  let mut paren = 0
  let mut s = start + 1
  let mut i = s
  while i < end {
    let c = b[i]
    if c == b'(' || c == b'[' {
      paren += 1
    } else if c == b')' || c == b']' {
      paren -= 1
    } else if c == b'{' {
      depth += 1
    } else if c == b'}' {
      depth -= 1
      if depth == 0 && paren == 0 {
        // (a block's end ends its statement, unless what follows goes on with it: else, a do's while, the ; of an
        // initialiser)
        let mut j = i + 1
        while j < end && is_space(b[j]) {
          j += 1
        }
        let mut w = j
        while w < imin(j + 8, b.length()) &&
          ((b[w] >= b'a' && b[w] <= b'z') ||
          (b[w] >= b'A' && b[w] <= b'Z') ||
          b[w] == b'_') {
          w += 1
        }
        let nxt = b[j:w]
        let go_on = b[j] == b';' ||
          b[j] == b',' ||
          b[j] == b')' ||
          nxt == b"else" ||
          (nxt == b"while" && starts(lstrip(sub(b, s, i)), b"do"))
        if !go_on {
          stmts.push(sub(text, s, i + 1))
          s = i + 1
        }
      }
    } else if c == b';' && depth == 0 && paren == 0 {
      stmts.push(sub(text, s, i + 1))
      s = i + 1
    }
    i += 1
  }
  if depth != 0 ||
    paren != 0 ||
    strip(sub(text, s, end)).length() > 0 ||
    stmts.length() == 0 {
    return None
  }
  // the locals moonc declares (no initial value), and the statements in runs by the package they set
  // (each by the place it first came in: a merged piece's are written in that order)
  let floating : Map[Bytes, (Int, Bytes)] = Map([])
  let runs : Array[Run] = []
  let mut pending : Array[Bytes] = []
  let mut pending_locals = BSet::new()
  for st in stmts {
    let bst = blank(st)
    match init_decl(bst) {
      Some(m) if is_local(m) && !has_byte(bst, b'=') => {
        floating[m] = match floating.get(m) {
          Some((o, _)) => (o, st)
          None => (floating.length(), st)
        }
        continue
      }
      _ => ()
    }
    let loc = BSet::new()
    for n in idents(bst).items() {
      if is_local(n) {
        loc.add(n)
      }
    }
    let o = init_owner(bst)
    if o is None &&
      pending.length() == 0 &&
      runs.length() > 0 &&
      subset(loc, runs[runs.length() - 1].locs) {
      // (right after a global set, what lets its temporaries go or goes on with it: the global's too)
      runs[runs.length() - 1].sts.push(st)
      continue
    }
    pending.push(st)
    pending_locals.add_all(loc)
    match o {
      Some(name) => {
        let p = package_of(name)
        if runs.length() > 0 && runs[runs.length() - 1].p == p {
          let r = runs[runs.length() - 1]
          for x in pending {
            r.sts.push(x)
          }
          r.locs.add_all(pending_locals)
        } else {
          runs.push({ p, sts: pending, locs: pending_locals })
        }
        pending = []
        pending_locals = BSet::new()
      }
      None => ()
    }
  }
  if pending.length() > 0 {
    if runs.length() == 0 {
      runs.push({ p: b"", sts: [], locs: BSet::new() })
    }
    let r = runs[runs.length() - 1]
    for x in pending {
      r.sts.push(x)
    }
    r.locs.add_all(pending_locals)
  }
  // pieces sharing a local are one, and the pieces between them (the order kept)
  let last : Map[Bytes, Int] = Map([])
  for k, r in runs {
    for n in r.locs.items() {
      last[n] = k
    }
  }
  let merged : Array[Run] = []
  let mut k = 0
  while k < runs.length() {
    let p = runs[k].p
    let sts = runs[k].sts.copy()
    let locs = runs[k].locs.copy()
    let mut reach = k
    for n in locs.items() {
      reach = imax(reach, last[n])
    }
    while k < reach {
      k += 1
      for x in runs[k].sts {
        sts.push(x)
      }
      locs.add_all(runs[k].locs)
      for n in runs[k].locs.items() {
        reach = imax(reach, last[n])
      }
    }
    if merged.length() > 0 && merged[merged.length() - 1].p == p {
      let m = merged[merged.length() - 1]
      for x in sts {
        m.sts.push(x)
      }
      m.locs.add_all(locs)
    } else {
      merged.push({ p, sts, locs })
    }
    k += 1
  }
  let out = []
  for m in merged {
    let decls = Buffer()
    // (the piece's locals that moonc declared, in the order they were declared: each piece looks up its own locals,
    // never every declaration)
    let mine : Array[(Int, Bytes)] = []
    for n in m.locs.t.keys {
      match floating.get(n) {
        Some(x) => mine.push(x)
        None => ()
      }
    }
    for x in stable_sort(mine, fn(a, b) { a.0 - b.0 }) {
      let d = x.1
      // (.strip('\n'))
      let mut a = 0
      let mut e = d.length()
      while a < e && d[a] == b'\n' {
        a += 1
      }
      while e > a && d[e - 1] == b'\n' {
        e -= 1
      }
      decls.write_bytesview(d[a:e])
      decls.write_byte(b'\n')
    }
    out.push((m.p, decls.to_bytes(), cat(m.sts)))
  }
  Some(out)
}

///|
/// The struct types that functions' `texts` need defined, not only declared: by value (a local, a parameter, a
/// compound literal), sizeof, a member or an element through a variable declared as one or a pointer to one; None
/// when that cannot be told (a member through anything else). `globals`: {name: (type, pointers)} of the externs.
fn defined_needed(
  texts : Array[BytesView],
  globals : BTab[(Bytes, Int)],
  fields : Map[Bytes, BTab[(Bytes, Int)]],
) -> BSet? {
  let need = BSet::new()
  for t in texts {
    let b = drop_header_of(blank(t))
    // (a member through a cast: ((struct X*)v)->$0, an enum's case's)
    let (casts, rest) = cast_accesses(b)
    for c in casts {
      need.add(c)
    }
    if member_after_bracket(rest) {
      return None
    }
    let sizes = []
    let by_value = []
    let vars = []
    struct_mentions(b, sizes, by_value, vars)
    for n in sizes {
      need.add(n)
    }
    for n in by_value {
      if !(starts(n, b"enum") && boundary(n, 4)) {
        need.add(n)
      }
    }
    let locals : BTab[(Bytes, Int)] = BTab::new()
    for v in vars {
      locals.set(v.0, (v.1, v.2))
    }
    // (a name's type and pointers: a local's, else a global's; looked up where it is in the text)
    let type_at = fn(s : Int, e : Int) -> (Bytes, Int)? {
      let h = hash_range(b, s, e)
      let i = locals.find_hashed(b, s, e, h)
      if i >= 0 {
        return Some(locals.vals[i])
      }
      let g = globals.find_hashed(b, s, e, h)
      if g >= 0 {
        Some(globals.vals[g])
      } else {
        None
      }
    }
    member_uses(
      b,
      fn(s, e, op) {
        match type_at(s, e) {
          Some(v) =>
            if v.1 == 0 || (v.1 == 1 && op != 2) {
              need.add(v.0)
            }
          None => ()
        }
      },
      // (a member's member: through the struct's definition, the member's type)
      fn(s, e, steps) {
        let mut v = type_at(s, e)
        let mut i = 0
        while i < steps.length() {
          let op = steps[i]
          let fs = steps[i + 1]
          let fe = steps[i + 2]
          i += 3
          match v {
            None => break
            Some(tv) => {
              if (op == 0) != (tv.1 == 1) {
                break
              }
              need.add(tv.0)
              v = match fields.get(tv.0) {
                Some(f) => {
                  let at = f.find_range(b, fs, fe)
                  if at >= 0 {
                    Some(f.vals[at])
                  } else {
                    None
                  }
                }
                None => None
              }
            }
          }
        }
      },
    )
  }
  Some(need)
}
