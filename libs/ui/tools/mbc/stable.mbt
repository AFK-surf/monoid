// The stable split: units are packages (a big one in pieces by source file, small
// ones together by a hash of the package's name), each with only the declarations it uses, moonc's made-up names
// made stable. A function unchanged is then the same text in the same unit, whatever else changed.

///|
/// a package's pieces of moonbit_init under this many bytes: with the other small ones in a unit
let init_small : Ref[Int] = { val: 16 * 1024 }

///|
let unit_head : Bytes = b"/* mbc (tools/mbc): one unit of the program moonc generated */\n"

///|
/// A declaration renamed: its text, what it declares, what it uses, whether every unit has it (a directive's
/// group that defines nothing)
priv struct DItem {
  t : Bytes
  declares : BSet
  uses : BSet
  always : Bool
}

///|
priv struct EItem {
  t : Bytes
  declares : BSet
  uses : BSet
}

///|
fn env_int(name : String, default : Int) -> Int {
  match getenv(name) {
    Some(v) => {
      let s = strip(v)
      let neg = s.length() > 0 && s[0] == b'-'
      let d = parse_int(s[if neg { 1 } else { 0 }:])
      if neg {
        -d
      } else {
        d
      }
    }
    None => default
  }
}

///|
fn env_is(name : String, default : String) -> Bytes {
  match getenv(name) {
    Some(v) => v
    None => utf8(default)
  }
}

///|
fn ints(m : Map[Int, Unit]) -> Array[Int] {
  let out = []
  for k, _ in m {
    out.push(k)
  }
  sorted_ints(out)
}

///|
fn split_stable(
  prelude : Bytes,
  decls : Array[Bytes],
  decl_kinds : Array[(Int, Bytes)],
  externs : Array[Bytes],
  data : Array[Bytes],
  data_names : Array[Bytes],
  funcs : Array[Func],
  init : Func,
  rest : Array[Func],
  static_names : BSet,
  stats : Array[(String, Int)],
  nitems : Int,
  unit_bytes : Int,
  outdir : Bytes,
) -> Split raise SplitError {
  let _ = c_mkdir(outdir)
  // a unit's functions (MBC_UNIT_KB): a package under half of it is with the other small ones
  let target = if unit_bytes > 0 {
    unit_bytes
  } else {
    imax(1, env_int("MBC_UNIT_KB", 768)) * 1024
  }
  // moonc's names that are the program's own: its types and typedefs (no linkage), and what it made static (no one
  // outside calls them; what is not static keeps its name: an export, main)
  let prelude_ids = idents(prelude)
  let statics = static_names.minus(BSet::of([b"", b"main", b"moonbit_init"]))
  let own : Array[Bytes] = []
  let seen_own = BSet::new()
  let add = fn(n : Bytes) {
    if !seen_own.has(n) && !prelude_ids.has(n) {
      seen_own.add(n)
      own.push(n)
    }
  }
  let data_text : Map[Bytes, Bytes] = Map([])
  for k, n in data_names {
    data_text[n] = data[k]
  }
  // Each declaration blanked once (without holding a 200k-element decls_b array), and data items without `_M0`
  // (most string literals) skipped before blanking.
  let fn_defs : Map[Bytes, Bytes] = Map([])
  for d in decls {
    let b = blank(d)
    if !starts(d[lskip(d, 0):], b"#") {
      for tag in tag_findall(b) {
        if starts(tag, b"_M0") {
          add(tag)
        }
      }
      if word_at(d, lskip(d, 0), b"typedef") >= 0 {
        match ident_before_semi(b, 0) {
          Some(m) if starts(m, b"_M0") => add(m)
          _ => ()
        }
      }
    }
    match fn_type_def(b) {
      Some(n) => fn_defs[n] = d
      None => ()
    }
  }
  for d in data {
    if !contains(d, b"_M0") {
      continue
    }
    for tag in tag_findall(blank(d)) {
      if starts(tag, b"_M0") {
        add(tag)
      }
    }
  }
  for f in funcs {
    if statics.has(f.name) {
      add(f.name)
    }
  }
  for n, _ in data_text {
    if statics.has(n) {
      add(n)
    }
  }
  let names = stable_names(own, data_text, fn_defs)
  let names_t = Renames::new(names)
  stats.push(("renamed", names.length()))

  tick("names")
  // the declarations (and the externs) renamed, each with what it declares and what it uses
  let file_ids = prelude_ids.copy()
  let ditems : Array[DItem] = []
  // (each type's declaration as renamed blanked, for what follows: the others' are not looked at so)
  let ditems_b : Array[Bytes] = []
  // (a declaration renamed as one before it is that one: function types the same are one type, names.mbt)
  let decl_seen = BSet::new()
  for k, d in decls {
    let (kind, info) = decl_kinds[k]
    let (t, used) = rename(d, names_t)
    if kind == 1 {
      if decl_seen.has(t) {
        // (kept in its place, declaring nothing: the items are found by their place in decls)
        ditems.push({ t: b"", declares: BSet::new(), uses: BSet::new(), always: false })
        ditems_b.push(b"")
        continue
      }
      decl_seen.add(t)
    }
    file_ids.add_all(used)
    if kind == 0 {
      ditems.push({ t, declares: BSet::new(), uses: used, always: true })
      ditems_b.push(b"")
      continue
    }
    let declares = BSet::new()
    if kind == 2 {
      declares.add(names.get_or_default(info, info))
      ditems_b.push(b"")
    } else {
      let b = blank(t)
      ditems_b.push(b)
      let m = if starts(lstrip(b), b"typedef") {
        typedef_name(b)
      } else {
        tag_name(b)
      }
      match m {
        Some(n) => declares.add(n)
        None => ()
      }
    }
    // a struct's definition uses what is in its braces; its declaration alone (struct X;) only declares X
    ditems.push({ t, declares, uses: used.minus(declares), always: false })
  }
  let typedef_names = BSet::new()
  for di in ditems {
    if !di.always && starts(lstrip(di.t), b"typedef") {
      typedef_names.add_all(di.declares)
    }
  }
  let eitems : Array[EItem] = []
  for k, e in externs {
    let (t, used) = rename(e, names_t)
    file_ids.add_all(used)
    let n = names.get_or_default(data_names[k], data_names[k])
    let ds = BSet::of([n])
    eitems.push({ t, declares: ds, uses: used.minus(ds) })
  }
  tick("decls, externs renamed")
  let data_r : Array[Bytes] = []
  let data_ids : Array[BSet] = [] // (the identifiers in each, for its unit's declarations)
  for d in data {
    // (what rename saw is what is in what it made: each identifier, or the name it became; never scanned again)
    let (t, ids) = rename(d, names_t)
    file_ids.add_all(ids)
    data_r.push(t)
    data_ids.push(ids)
  }
  // by_name: what the declarations, the externs and the directives' groups declare or define: (0 a declaration,
  // 1 an extern, its index)
  let by_name : Map[Bytes, Array[(Int, Int)]] = Map([])
  let put = fn(n : Bytes, x : (Int, Int)) {
    match by_name.get(n) {
      Some(a) => a.push(x)
      None => by_name[n] = [x]
    }
  }
  for k, di in ditems {
    for n in di.declares.items() {
      put(n, (0, k))
    }
  }
  // moonc's directives in groups (an #ifndef X … #define X Y … #endif, or a #define alone), a unit taking a group
  // when it uses a name the group defines; a group defining nothing, in every unit
  let always_pp : Map[Int, Unit] = Map([])
  let mut group : Array[Int] = []
  let mut depth = 0
  for k, dk in decl_kinds {
    if dk.0 != 0 {
      continue
    }
    let d = strip(ditems[k].t)
    group.push(k)
    if directive_is(d, [b"if", b"ifdef", b"ifndef"]) {
      depth += 1
    } else if directive_is(d, [b"endif"]) {
      depth -= 1
    }
    if depth == 0 {
      let defined = BSet::new()
      for j in group {
        match define_name(strip(ditems[j].t)) {
          Some(n) => defined.add(n)
          None => ()
        }
      }
      if defined.size() > 0 {
        for n in defined.items() {
          for j in group {
            put(n, (0, j))
          }
        }
      } else {
        for j in group {
          always_pp[j] = ()
        }
      }
      group = []
    }
  }
  for j in group {
    always_pp[j] = ()
  }
  for k, ei in eitems {
    for n in ei.declares.items() {
      put(n, (1, k))
    }
  }

  tick("data renamed, by_name")
  // an object's layout is an offset into moonc's table of them (moonbit_layout_table_data), numbered across the
  // program as the names are: a function's header for one names the layout instead, by its content, a constant
  // data.c defines
  let mut table : Array[Bytes]? = None
  match data_names.search(b"moonbit_layout_table_data") {
    Some(ti) => {
      let body = data_r[ti]
      let b = blank(body)
      let eq = find_byte(b, b'=', 0)
      let start = find_byte(b, b'{', if eq < 0 { b.length() - 1 } else { eq })
      if start >= 0 {
        let tb = []
        let mut depth = 0
        let mut k = start + 1
        for i in (start + 1)..<b.length() {
          let c = b[i]
          if c == b'(' || c == b'[' || c == b'{' {
            depth += 1
          } else if c == b')' || c == b']' || c == b'}' {
            if depth == 0 {
              tb.push(strip(sub(body, k, i)))
              break
            }
            depth -= 1
          } else if c == b',' && depth == 0 {
            tb.push(strip(sub(body, k, i)))
            k = i + 1
          }
        }
        if tb.length() > 0 && tb[tb.length() - 1].length() == 0 {
          let _ = tb.pop()
        }
        table = Some(tb)
      }
    }
    None => ()
  }
  let layout_words = fn(off : Int) -> Bytes? {
    // an entry is [size; child count; tagged child…]: by its words, two the same are the same layout
    match table {
      Some(tb) =>
        if off + 1 < tb.length() {
          let w = tb[off + 1]
          let mut d = 0
          while d < w.length() && is_digit(w[d]) {
            d += 1
          }
          let ok = d > 0 &&
            (d == w.length() ||
            (d + 1 == w.length() && (w[d] == b'u' || w[d] == b'U')))
          if ok {
            let end = off + 2 + parse_int(w[0:d])
            if end <= tb.length() {
              let buf = Buffer()
              for i in off..<end {
                if i > off {
                  buf.write_byte(b'\x00')
                }
                buf.write_bytes(collapse_space(tb[i]))
              }
              return Some(buf.to_bytes())
            }
          }
        }
      None => ()
    }
    None
  }
  let offset_set : Map[Int, Unit] = Map([])
  for f in rest {
    for m in layout_matches(f.text) {
      offset_set[parse_int(f.text[m.0:m.1])] = ()
    }
  }
  for m in layout_matches(init.text) {
    offset_set[parse_int(init.text[m.0:m.1])] = ()
  }
  for t in data_r {
    for m in layout_matches(t) {
      offset_set[parse_int(t[m.0:m.1])] = ()
    }
  }
  let first : Map[Bytes, Int] = Map([]) // a layout's words: its first offset
  let key_of : Map[Int, Bytes] = Map([])
  for off in ints(offset_set) {
    let k = match layout_words(off) {
      Some(w) => w
      None => utf8("(at \{off})")
    }
    key_of[off] = k
    if !first.contains(k) {
      first[k] = off
    }
  }
  let first_keys = []
  for k, _ in first {
    first_keys.push(k)
  }
  let layout_named = by_content(first_keys, b"csplit_layout_")
  let layouts : Map[Bytes, Int] = Map([]) // name: offset
  for k, off in first {
    layouts[layout_named[k]] = off
  }
  let name_layouts = fn(text : Bytes) -> (Bytes, BSet) {
    let used = BSet::new()
    let ms = layout_matches(text)
    if ms.length() == 0 {
      return (text, used)
    }
    let buf = Buffer(capacity=text.length())
    let mut last = 0
    for m in ms {
      let n = layout_named[key_of[parse_int(text[m.0:m.1])]]
      used.add(n)
      buf.write_bytesview(text[last:m.0])
      buf.write_bytes(n)
      last = m.1
    }
    buf.write_bytesview(text[last:])
    (buf.to_bytes(), used)
  }

  tick("layouts")
  // (a function's scan looks only at what may be renamed or declared for it: moonc's names (_…), what ends in a
  // number (a string literal, a local), and what the declarations declare otherwise)
  let plain = BSet::new()
  let plain_ok = fn(n : Bytes) {
    if n.length() > 0 && n[0] != b'_' && !is_digit(n[n.length() - 1]) {
      plain.add(n)
    }
  }
  for n, _ in by_name {
    plain_ok(n)
  }
  for n, _ in names {
    plain_ok(n)
  }

  // the functions renamed (their locals by their own order), each in its package's unit
  let pk = rest.map(fn(f) { package_of(f.name) })
  // (each function's length in characters and its source file's name, worked out once)
  let fclen = rest.map(fn(f) { clen(f.text) })
  let ffile : Array[Bytes?] = rest.map(fn(f) {
    match line_file(f.text) {
      Some(path) => {
        let mut s = path.length()
        while s > 0 && path[s - 1] != b'/' && path[s - 1] != b'\\' {
          s -= 1
        }
        Some(sub(path, s, path.length()))
      }
      None => None
    }
  })
  let sizes : Map[Bytes, Int] = Map([])
  for k, _ in rest {
    sizes[pk[k]] = sizes.get_or_default(pk[k], 0) + fclen[k]
  }
  let mut small = 0
  for _, v in sizes {
    if v < target / 2 {
      small += v
    }
  }
  let mut nsmall = 1
  while nsmall * target < small {
    nsmall *= 2
  }
  let pieces_of = fn(v : Int) {
    let mut k = 1
    while k * target < v {
      k *= 2
    }
    k
  }
  // a big package in pieces by source file (its #line's), as C is compiled: an edit moves the lines of the functions
  // after it in its file, and only that file's piece changes. A file bigger than a unit (a generic one's instances:
  // core's Map for each of the program's types) in pieces of its own by the types its functions are instances for
  // (type_args): by their names, a branch's one new type's instances (a Map's keys, get, set, iter...) were spread
  // over 20 of core's 32 pieces of that file and 21 of view's, each compiled again (with mbui's view and signals, some
  // 60 of the 280 units a branch's 360 lines of sfpages had to compile, mbui-chat-nodes-outline, 2026-11-14)
  let file_key = rest.mapi(fn(k, f) {
    match ffile[k] {
      Some(file) => file
      None => names.get_or_default(f.name, f.name)
    }
  })
  let file_sizes : Map[Bytes, Int] = Map([])
  for k, _ in rest {
    let fk = cat([pk[k], b"\x1f", file_key[k]])
    file_sizes[fk] = file_sizes.get_or_default(fk, 0) + fclen[k]
  }
  // each function's unit: unit: [(its name as renamed, its index in rest)] (renamed in its unit's job, below).
  // A test's function (its #line's file a *_test.mbt or *_wbtest.mbt) in test.<unit>, the unit it would have been in
  // otherwise: the same pieces by the same sizes, so a unit of tests alone is the C it was, under its new name, and a
  // piece of a program's own code is no longer compiled again for a test of its piece changed (sfapp's 526 test files,
  // 92% of its source, beside its 43). mbc compiles these at MBC_TEST_OPT (is_test_unit); a program built for people
  // has none
  let units : Map[Bytes, Array[(Bytes, Int)]] = Map([])
  for k, f in rest {
    let p = pk[k]
    let new = names.get_or_default(f.name, f.name)
    let in_test = match ffile[k] {
      Some(file) => ends(file, b"_test.mbt") || ends(file, b"_wbtest.mbt")
      None => false
    }
    let unit = if sizes[p] < target / 2 {
      cat([b"s", utf8((crc32(p) % nsmall.reinterpret_as_uint()).to_string())])
    } else {
      let pieces = pieces_of(sizes[p])
      let key = file_key[k]
      let base = if pieces > 1 {
        cat([
          unit_label(p),
          b"_",
          utf8((crc32(key) % pieces.reinterpret_as_uint()).to_string()),
        ])
      } else {
        unit_label(p)
      }
      let fsize = file_sizes.get_or_default(cat([p, b"\x1f", key]), 0)
      if fsize > target {
        let sub = pieces_of(fsize)
        cat([
          base,
          b"_",
          utf8((crc32(type_args(new)) % sub.reinterpret_as_uint()).to_string()),
        ])
      } else {
        base
      }
    }
    let unit = if in_test { cat([b"test.", unit]) } else { unit }
    match units.get(unit) {
      Some(u) => u.push((new, k))
      None => units[unit] = [(new, k)]
    }
  }
  let init_part = fn(text : Bytes) -> (Bytes, BSet) {
    // (moonbit_init too: what it makes, the layouts its objects have, then the same each time it is; and without
    // its #line's: every global's initialiser says where it is in its file)
    let (t0, used) = rename(text, names_t, local_ok=Some(file_ids), plain=Some(plain))
    let (t1, lused) = name_layouts(t0)
    used.add_all(lused)
    (flatten(drop_line_directives(t1)).to_owned(), used)
  }
  // moonbit_init in its packages' pieces (init_pieces), each a function in its package's init unit
  // (init.<package>.c; those under init_small together, init.s<k>.c): a package changed compiles its own again;
  // moonbit_init itself calls them in order. MBC_INIT_SPLIT=0: one unit, as it was
  let pieces = if env_is("MBC_INIT_SPLIT", "1") != b"0" {
    match init_pieces(init.text.to_owned()) {
      Some(ps) if ps.length() > 0 => Some(ps)
      _ => None
    }
  } else {
    None
  }
  // (init unit: [(its function's name, the piece's index)])
  let init_units : Map[Bytes, Array[(Bytes, Int)]] = Map([])
  let init_calls : Array[Bytes] = []
  let mut whole_init = false
  match pieces {
    Some(ps) => {
      let psize : Map[Bytes, Int] = Map([])
      for x in ps {
        psize[x.0] = psize.get_or_default(x.0, 0) + clen(x.1) + clen(x.2)
      }
      let smalls = BSet::new()
      let mut small_total = 0
      for p, v in psize {
        if v < init_small.val {
          smalls.add(p)
          small_total += v
        }
      }
      let mut nsmall_i = 1
      while nsmall_i * init_small.val * 4 < small_total {
        nsmall_i *= 2
      }
      let counts : Map[Bytes, Int] = Map([])
      for pi, x in ps {
        let p = x.0
        let label = unit_label(p)
        let k = counts.get_or_default(label, -1) + 1
        counts[label] = k
        let fname = cat([b"csplit_init_", label, b"_", bint(k), b"x"])
        let unit = if smalls.has(p) {
          cat([
            b"init.s",
            utf8((crc32(p) % nsmall_i.reinterpret_as_uint()).to_string()),
          ])
        } else {
          cat([b"init.", label])
        }
        match init_units.get(unit) {
          Some(u) => u.push((fname, pi))
          None => init_units[unit] = [(fname, pi)]
        }
        init_calls.push(fname)
      }
      stats.push(("init_pieces", ps.length()))
    }
    None => whole_init = true
  }

  tick("functions, init renamed")
  // what the prelude's own macros name of moonc's, and what the directives in every unit name
  let pp_uses = BSet::new()
  for n in prelude_ids.items() {
    if by_name.contains(n) {
      pp_uses.add(n)
    }
  }
  for k in ints(always_pp) {
    pp_uses.add_all(ditems[k].uses)
  }

  // a unit's declarations in an order of their own, not moonc's: the directives (in moonc's order), the structs
  // declared, the types (each after those it holds by value, else by name), the prototypes by name
  // (kinds: 0 pp, 1 proto, 2 fwd, 3 type)
  let kinds = []
  for k, di in ditems {
    kinds.push(
      if di.always {
        0
      } else if decl_kinds[k].0 == 2 {
        1
      } else if is_fwd(ditems_b[k]) {
        2
      } else {
        3
      },
    )
  }
  let type_of : Map[Bytes, Array[Int]] = Map([])
  for k, kind in kinds {
    if kind == 3 {
      for n in ditems[k].declares.items() {
        match type_of.get(n) {
          Some(a) => a.push(k)
          None => type_of[n] = [k]
        }
      }
    }
  }
  let needs : Map[Int, Array[Int]] = Map([])
  for k, kind in kinds {
    if kind != 3 {
      continue
    }
    let b = ditems_b[k]
    if starts(lstrip(b), b"typedef") && !has_byte(b, b'{') {
      needs[k] = [] // (a name for a type: complete or not, as it may be)
      continue
    }
    let held = BSet::of(by_value_all(b))
    for n in ditems[k].uses.inter(typedef_names).items() {
      if named_not_ptr(b, n) {
        held.add(n)
      }
    }
    let js : Map[Int, Unit] = Map([])
    for n in held.items() {
      match type_of.get(n) {
        Some(a) =>
          for j in a {
            if j != k {
              js[j] = ()
            }
          }
        None => ()
      }
    }
    needs[k] = ints(js)
  }
  // (struct and union definitions, which a unit may have as a declaration alone; what a typedef names)
  let struct_defs : Map[Int, Unit] = Map([])
  for k, kind in kinds {
    if kind == 3 && has_byte(ditems[k].t, b'{') {
      let b = ditems_b[k]
      let i = lskip(b, 0)
      if word_at(b, i, b"struct") >= 0 || word_at(b, i, b"union") >= 0 {
        struct_defs[k] = ()
      }
    }
  }
  let struct_tags = BSet::new()
  for k in ints(struct_defs) {
    struct_tags.add_all(ditems[k].declares)
  }
  let typedef_of : Map[Bytes, BSet] = Map([])
  for k, kind in kinds {
    if kind == 3 && starts(lstrip(ditems_b[k]), b"typedef") {
      for n in ditems[k].declares.items() {
        typedef_of[n] = ditems[k].uses.inter(struct_tags)
      }
    }
  }
  let fields : Map[Bytes, BTab[(Bytes, Int)]] = Map([])
  for k in ints(struct_defs) {
    let b = ditems_b[k]
    let inner = pyslice(b, find_byte(b, b'{', 0) + 1, rfind_byte(b, b'}'))
    let f : BTab[(Bytes, Int)] = BTab::new()
    for v in decl_vars(inner) {
      f.set(v.0, (v.1, v.2))
    }
    for n in ditems[k].declares.items() {
      fields[n] = f
    }
  }
  let empty_bytes : Array[Bytes] = []
  let extern_by_value : Array[Array[Bytes]] = Array::make(eitems.length(), empty_bytes)
  let globals : BTab[(Bytes, Int)] = BTab::new()
  for k, e in eitems {
    let b = blank(e.t)
    let mut bv : BSet? = None
    for tag in by_value_all(b) {
      if struct_tags.has(tag) {
        match bv {
          Some(s) => s.add(tag)
          None => bv = Some(BSet::of([tag]))
        }
      }
    }
    match bv {
      Some(s) => extern_by_value[k] = s.t.keys
      None => ()
    }
    for v in decl_vars(b) {
      globals.set(v.0, (v.1, v.2))
    }
  }
  // (the declarations' texts in one, the externs' and the globals' too, and the declarations' order keys: what a
  // job's process reads of them it reads there, as BTab's keys, not from objects of its parent's)
  let in_one = fn(ts : Array[Bytes]) -> (Bytes, FixedArray[Int]) {
    let at = FixedArray::make(ts.length() + 1, 0)
    for i, t in ts {
      at[i + 1] = at[i] + t.length()
    }
    (concat(ts.map(fn(t) { t[:] })), at)
  }
  let (d_text, d_at) = in_one(ditems.map(fn(di) { di.t }))
  let decl_text = fn(k : Int) -> BytesView { d_text[d_at[k]:d_at[k + 1]] }
  // The closure's graph by number: each name a declaration, an extern or a directive's group declares (by_name's
  // keys) is a number, and what each item uses, declares and holds by value are those numbers, each in one array
  // (Csr). Names that are not keys of by_name lead nowhere in it and are left out. A unit's closure is then marks on
  // arrays, set anew by a stamp, not sets of names made for each unit.
  let syms : BTab[Int] = BTab::new()
  let sym_names : Array[Bytes] = []
  for n, _ in by_name {
    syms.set(n, sym_names.length())
    sym_names.push(n)
  }
  let nsym = sym_names.length()
  let sym_of = fn(n : BytesView) -> Int {
    let at = syms.find(n)
    if at < 0 {
      -1
    } else {
      syms.vals[at]
    }
  }
  let ids_of = fn(names : Array[Bytes]) -> Array[Int] {
    let out = []
    for n in names {
      let s = sym_of(n)
      if s >= 0 {
        out.push(s)
      }
    }
    out
  }
  let ids_of_set = fn(set : BSet) -> Array[Int] {
    let out = []
    for i, n in set.t.keys {
      let at = syms.find_hashed(n, 0, n.length(), set.t.hashes[i])
      if at >= 0 {
        out.push(syms.vals[at])
      }
    }
    out
  }
  // (by_name's entries of each name: (kind, k) as k * 2 + kind)
  let by_sym = Csr::of(
    sym_names.map(fn(n) { by_name[n].map(fn(x) { x.1 * 2 + x.0 }) }),
  )
  let d_uses = Csr::of(ditems.map(fn(di) { ids_of_set(di.uses) }))
  let d_declares = Csr::of(ditems.map(fn(di) { ids_of_set(di.declares) }))
  let e_uses = Csr::of(eitems.map(fn(ei) { ids_of_set(ei.uses) }))
  let pp_ids = ids_of_set(pp_uses)
  let is_typedef = FixedArray::make(nsym, false)
  for n in typedef_names.t.keys {
    let s = sym_of(n)
    if s >= 0 {
      is_typedef[s] = true
    }
  }
  let typedef_lists : Array[Array[Int]] = Array::make(nsym, [])
  for n, ts in typedef_of {
    let s = sym_of(n)
    if s >= 0 {
      typedef_lists[s] = ids_of_set(ts)
    }
  }
  let typedef_ids = Csr::of(typedef_lists)
  let type_lists : Array[Array[Int]] = Array::make(nsym, [])
  for n, ks in type_of {
    let s = sym_of(n)
    if s >= 0 {
      type_lists[s] = ks
    }
  }
  let type_ids = Csr::of(type_lists)
  let needs_lists : Array[Array[Int]] = Array::make(ditems.length(), [])
  for k, js in needs {
    needs_lists[k] = js
  }
  let needs_of = Csr::of(needs_lists)
  let is_struct_def = FixedArray::make(ditems.length(), false)
  for k, _ in struct_defs {
    is_struct_def[k] = true
  }
  let empty_ints : Array[Int] = []
  let e_by_value = Csr::of(
    extern_by_value.map(fn(a) { if a.length() == 0 { empty_ints } else { ids_of(a) } }),
  )
  // (a name declared alone as a struct of moonc's, `struct X;`: written by the unit only where no such declaration
  // is among moonc's (as by_name's entries are looked up, an extern's index among the declarations' too))
  let has_fwd = FixedArray::make(nsym, false)
  for s in 0..<nsym {
    for q in by_sym.at[s]..<by_sym.at[s + 1] {
      let k = by_sym.v[q] / 2
      if k < kinds.length() && kinds[k] == 2 {
        has_fwd[s] = true
      }
    }
  }
  // (a prototype's types held by value, of the structs: the closure's)
  let proto_by_value : Array[Array[Int]?] = Array::make(ditems.length(), None)
  let proto_held = fn(k : Int) -> Array[Int] {
    match proto_by_value[k] {
      Some(a) => a
      None => {
        let a = ids_of(
          by_value_all(blank(decl_text(k))).filter(fn(t) { struct_tags.has(t) }),
        )
        proto_by_value[k] = Some(a)
        a
      }
    }
  }
  // (the marks: a name, a declaration or an extern is marked when its mark is the stamp of the closure being made)
  let need_mark = FixedArray::make(nsym, 0)
  let seen_mark = FixedArray::make(nsym, 0)
  let declared_mark = FixedArray::make(nsym, 0)
  let d_mark = FixedArray::make(ditems.length(), 0)
  let e_mark = FixedArray::make(eitems.length(), 0)
  let stamp : Ref[Int] = { val: 0 }
  let always_list = ints(always_pp)
  let closure = fn(used : Array[Int], need0 : Array[Int]?) -> (Array[Int], Array[Int], Array[Bytes]) {
    // (need: the struct types to define, by defined_needed; None: every one used. With it, what they hold by value
    // too, and the others declared only: struct X;)
    let expand = fn(n0 : Array[Int]) -> Array[Int] {
      stamp.val += 1
      let st = stamp.val
      let need : Array[Int] = []
      let add = fn(t : Int) {
        if need_mark[t] != st {
          need_mark[t] = st
          need.push(t)
        }
      }
      for t in n0 {
        add(t)
      }
      for n in used {
        for q in by_sym.at[n]..<by_sym.at[n + 1] {
          let x = by_sym.v[q]
          if x % 2 == 0 && kinds[x / 2] == 1 {
            for t in proto_held(x / 2) {
              add(t)
            }
          }
        }
        if is_typedef[n] {
          for q in typedef_ids.at[n]..<typedef_ids.at[n + 1] {
            add(typedef_ids.v[q])
          }
        }
      }
      let mut i = 0
      while i < need.length() {
        let t = need[i]
        i += 1
        for q in type_ids.at[t]..<type_ids.at[t + 1] {
          let k = type_ids.v[q]
          for r in needs_of.at[k]..<needs_of.at[k + 1] {
            let j = needs_of.v[r]
            for u in d_declares.at[j]..<d_declares.at[j + 1] {
              add(d_declares.v[u])
            }
          }
        }
      }
      need
    }
    let mut need = match need0 {
      Some(n0) => Some(expand(n0))
      None => None
    }
    while true {
      // (the need's marks are the stamp expand left; this pass's are one past it)
      let nst = stamp.val
      stamp.val += 1
      let st = stamp.val
      let want_d : Array[Int] = []
      let want_e : Array[Int] = []
      let declared : Array[Int] = []
      let todo : Array[Int] = []
      for n in used {
        todo.push(n)
      }
      for n in pp_ids {
        todo.push(n)
      }
      while todo.length() > 0 {
        let n = todo.pop().unwrap()
        if seen_mark[n] == st {
          continue
        }
        seen_mark[n] = st
        for q in by_sym.at[n]..<by_sym.at[n + 1] {
          let kind = by_sym.v[q] % 2
          let k = by_sym.v[q] / 2
          if kind == 0 && d_mark[k] != st {
            if need is Some(_) && is_struct_def[k] {
              let mut any = false
              for u in d_declares.at[k]..<d_declares.at[k + 1] {
                if need_mark[d_declares.v[u]] == nst {
                  any = true
                  break
                }
              }
              if !any {
                for u in d_declares.at[k]..<d_declares.at[k + 1] {
                  let d = d_declares.v[u]
                  if declared_mark[d] != st {
                    declared_mark[d] = st
                    declared.push(d)
                  }
                }
                continue
              }
            }
            d_mark[k] = st
            want_d.push(k)
            for u in d_uses.at[k]..<d_uses.at[k + 1] {
              todo.push(d_uses.v[u])
            }
          } else if kind == 1 && e_mark[k] != st {
            e_mark[k] = st
            want_e.push(k)
            for u in e_uses.at[k]..<e_uses.at[k + 1] {
              todo.push(e_uses.v[u])
            }
          }
        }
      }
      for k in always_list {
        if d_mark[k] != st {
          d_mark[k] = st
          want_d.push(k)
        }
      }
      match need {
        Some(nd) => {
          // (a type defined holds by value what it holds by value, defined too: again with those; and an extern's
          // type, a struct written out (a closure's object), what it holds by value)
          let more : Array[Int] = []
          let more_st = st + 1
          stamp.val = more_st
          let held = fn(t : Int) {
            if need_mark[t] != nst && seen_mark[t] != more_st {
              // (seen_mark is this pass's no more: what is held and not needed, once)
              seen_mark[t] = more_st
              more.push(t)
            }
          }
          for k in want_d {
            for r in needs_of.at[k]..<needs_of.at[k + 1] {
              let j = needs_of.v[r]
              for u in d_declares.at[j]..<d_declares.at[j + 1] {
                held(d_declares.v[u])
              }
            }
          }
          for k in want_e {
            for q in e_by_value.at[k]..<e_by_value.at[k + 1] {
              held(e_by_value.v[q])
            }
          }
          if more.length() > 0 {
            let n2 = nd.copy()
            for t in more {
              n2.push(t)
            }
            need = Some(expand(n2))
            continue
          }
        }
        None => ()
      }
      let fwd_made = []
      for n in sort_bytes(declared.map(fn(d) { sym_names[d] })) {
        if !has_fwd[sym_of(n)] {
          fwd_made.push(n)
        }
      }
      return (sorted_ints(want_d), sorted_ints(want_e), fwd_made)
    }
    abort("unreachable")
  }
  // a declaration's order key: (the least name it declares, its text), then its index
  let key_name = ditems.map(fn(di) {
    let ns = di.declares.sorted()
    if ns.length() > 0 {
      ns[0]
    } else {
      b""
    }
  })
  let (k_text, k_at) = in_one(key_name)
  let (e_text, e_at) = in_one(eitems.map(fn(ei) { ei.t }))
  let key_cmp = fn(a : Int, b : Int) {
    let c = bcmp(k_text[k_at[a]:k_at[a + 1]], k_text[k_at[b]:k_at[b + 1]])
    if c != 0 {
      return c
    }
    let c = bcmp(decl_text(a), decl_text(b))
    if c != 0 {
      return c
    }
    a - b
  }
  let in_types = FixedArray::make(ditems.length(), 0)
  let types_done = FixedArray::make(ditems.length(), 0)
  let left = FixedArray::make(ditems.length(), 0)
  let canonical = fn(all : Array[Int]) -> Array[BytesView] {
    // (all: the declarations wanted, in their order)
    let pp = all.filter(fn(k) { kinds[k] == 0 })
    let fwd = stable_sort(all.filter(fn(k) { kinds[k] == 2 }), key_cmp)
    let protos = stable_sort(all.filter(fn(k) { kinds[k] == 1 }), key_cmp)
    let types = all.filter(fn(k) { kinds[k] == 3 })
    stamp.val += 1
    let st = stamp.val
    for k in types {
      in_types[k] = st
    }
    let users : Map[Int, Array[Int]] = Map([])
    let heap = Heap::new(key_cmp)
    for k in types {
      let mut nd = 0
      for r in needs_of.at[k]..<needs_of.at[k + 1] {
        let j = needs_of.v[r]
        if in_types[j] == st {
          nd += 1
          match users.get(j) {
            Some(a) => a.push(k)
            None => users[j] = [k]
          }
        }
      }
      left[k] = nd
      if nd == 0 {
        heap.push(k)
      }
    }
    let out = []
    while heap.size() > 0 {
      let k = heap.pop()
      out.push(k)
      types_done[k] = st
      match users.get(k) {
        Some(us) =>
          for u in us {
            left[u] = left[u] - 1
            if left[u] == 0 {
              heap.push(u)
            }
          }
        None => ()
      }
    }
    if out.length() < types.length() {
      // (a cycle: never by value; moonc's order for what is left)
      for k in types {
        if types_done[k] != st {
          out.push(k)
        }
      }
    }
    let texts = []
    for k in pp {
      texts.push(decl_text(k))
    }
    for k in fwd {
      texts.push(decl_text(k))
    }
    for k in out {
      texts.push(decl_text(k))
    }
    for k in protos {
      texts.push(decl_text(k))
    }
    texts
  }
  let layout_names = BSet::new()
  for n, _ in layouts {
    layout_names.add(n)
  }
  let layout_defs = {
    let buf = Buffer()
    let lns = layout_names.sorted()
    for n in lns {
      buf.write_bytes(b"CSPLIT_INTERNAL const uint32_t ")
      buf.write_bytes(n)
      buf.write_bytes(b" = ")
      buf.write_bytes(bint(layouts[n]))
      buf.write_bytes(b";\n")
    }
    buf.to_bytes()
  }
  stats.push(("layouts_named", layouts.length()))
  let lines_of = fn(ts : Array[Bytes]) {
    let buf = Buffer()
    for t in ts {
      buf.write_bytes(t)
      if !ends(t, b"\n") {
        buf.write_byte(b'\n')
      }
    }
    buf.to_bytes()
  }
  let decls_all = lines_of(ditems.map(fn(d) { d.t }))
  // (texts with a line break between each two, as parts of a unit's text)
  let lines_between = fn(ts : Array[BytesView]) -> Array[BytesView] {
    let parts = []
    for i, t in ts {
      if i > 0 {
        parts.push(b"\n"[:])
      }
      parts.push(t)
    }
    parts
  }
  let declare_only = env_is("MBC_DECLARE_ONLY", "1") != b"0"
  let unit_text = fn(
    used : BSet,
    body : Array[BytesView],
    texts : Array[BytesView]?,
    defines : BSet,
  ) -> Bytes {
    // A unit: the prelude, the declarations and externs `used` needs (in an order of their own), then `body`; with
    // `texts` (its functions), the structs they need defined, the others declared only. `defines`: the globals the
    // unit defines (a data unit's), not declared extern in it (an anonymous struct's type, declared twice in one
    // unit, is two types).
    let need = match texts {
      Some(ts) if declare_only => defined_needed(ts, globals, fields)
      _ => None
    }
    let (want_d, want_e, fwd_made) = closure(
      ids_of_set(used),
      match need {
        Some(nd) => Some(ids_of_set(nd))
        None => None
      },
    )
    // (its parts, put together once in a text made to their length)
    let parts : Array[BytesView] = [unit_head[:], internal[:], prelude[:], b"\n"[:]]
    for n in fwd_made {
      parts.push(b"struct "[:])
      parts.push(n[:])
      parts.push(b";\n"[:])
    }
    for t in canonical(want_d) {
      parts.push(t)
      if !ends(t, b"\n") {
        parts.push(b"\n"[:])
      }
    }
    for t in stable_sort(
        want_e
        .filter(fn(k) {
          defines.size() == 0 || eitems[k].declares.inter(defines).size() == 0
        })
        .map(fn(k) { e_text[e_at[k]:e_at[k + 1]] }),
        bcmp,
      ) {
      parts.push(t)
    }
    for n in used.inter(layout_names).sorted() {
      parts.push(b"extern CSPLIT_INTERNAL const uint32_t "[:])
      parts.push(n[:])
      parts.push(b";\n"[:])
    }
    parts.push(b"\n"[:])
    for b in body {
      parts.push(b)
    }
    parts.push(b"\n"[:])
    concat(parts)
  }
  tick("kinds, needs")
  // the units, each written as it is made (mbc builds what changed): those every unit's declarations are
  // in here, then the functions' and moonbit_init's pieces' units in jobs, in processes of their own (run_jobs)
  let written : Array[(Bytes, Int)] = [] // (name, characters)
  let mut changed = 0
  let put = fn(name : Bytes, text : Bytes) {
    if write_if_changed(join_path(outdir, name), text) {
      changed += 1
    }
    written.push((name, clen(text)))
  }
  put(
    b"decls.h",
    cat([
      b"#ifndef CSPLIT_DECLS\n#define CSPLIT_DECLS\n",
      internal,
      prelude,
      b"\n",
      decls_all,
      b"#endif\n",
    ]),
  )
  put(
    b"externs.h",
    cat([
      b"#ifndef CSPLIT_EXTERNS\n#define CSPLIT_EXTERNS\n",
      cat(eitems.map(fn(e) { e.t })),
      b"#endif\n",
    ]),
  )
  // data.c: the prelude's own definitions (CSPLIT_DEFS), defined once; the globals in units of their own, below
  put(
    b"data.c",
    cat([unit_head, b"#define CSPLIT_DEFS\n", internal, prelude, b"\n"]),
  )
  // jobs: (file, what its entries are (0 functions, 1 moonbit_init's pieces, 2 globals), its entries)
  let jobs : Array[(Bytes, Int, Array[(Bytes, Int)])] = []
  // A global's object names its layout by its content too, as a function's header does: moonc numbers the layouts
  // across the program, so a type put in anywhere renumbered those after it, and every data unit with an object of
  // one was new text (184 of the 419 units a branch's change of 19 files compiled again for that alone,
  // vault-slack-oauth, 2026-11-15). A static initializer can take no constant of another unit, so the object's
  // header says the layout's index 0, and moonbit_init sets it first of all from data_layout.c's table of them
  // (csplit_fix_layouts). Only an object of one header (`struct { int32_t rc; uint32_t meta; …}`); with moonbit_init
  // in one unit, as it was. MBC_DATA_LAYOUTS=0: the numbers kept in the globals, as they were
  let fixes : Array[(Bytes, Bytes)] = [] // (a global as renamed, its layout's name)
  if !whole_init && env_is("MBC_DATA_LAYOUTS", "1") != b"0" {
    let head = b"struct { int32_t rc; uint32_t meta;"
    for k, n in data_names {
      let t = data_r[k]
      let ms = layout_matches(t)
      let lead = collapse_space(t[0:(if t.length() < 120 { t.length() } else { 120 })])
      let at = find(lead, head, 0)
      if ms.length() == 1 && at >= 0 && at <= 18 {
        let m = ms[0]
        fixes.push(
          (
            names.get_or_default(n, n),
            layout_named[key_of[parse_int(t[m.0:m.1])]],
          ),
        )
        data_r[k] = cat([sub(t, 0, m.0), b"0", sub(t, m.1, t.length())])
      }
    }
  }
  let fix_names = BSet::new()
  let layout_fixes = if fixes.length() == 0 {
    b""
  } else {
    let sorted = stable_sort(Array::makei(fixes.length(), fn(i) { i }), fn(a, b) {
      bcmp(fixes[a].0, fixes[b].0)
    })
    let buf = Buffer()
    buf.write_bytes(
      b"static const struct { uint32_t *meta; const uint32_t *layout; } csplit_layout_fixes[",
    )
    buf.write_bytes(bint(fixes.length()))
    buf.write_bytes(b"] = {\n")
    for i in sorted {
      let (g, l) = fixes[i]
      fix_names.add(g)
      buf.write_bytes(b"  { &")
      buf.write_bytes(g)
      buf.write_bytes(b".meta, &")
      buf.write_bytes(l)
      buf.write_bytes(b" },\n")
    }
    buf.write_bytes(b"};\nCSPLIT_INTERNAL void csplit_fix_layouts(void) {\n  for (int i = 0; i < ")
    buf.write_bytes(bint(fixes.length()))
    buf.write_bytes(
      b"; i++) {\n    *csplit_layout_fixes[i].meta |= (*csplit_layout_fixes[i].layout & MOONBIT_REGULAR_LAYOUT_INDEX_MASK)\n      << MOONBIT_REGULAR_LAYOUT_INDEX_SHIFT;\n  }\n}\n",
    )
    buf.to_bytes()
  }
  stats.push(("objects_layouts_fixed", fixes.length()))
  // moonbit_init too: with all of decls.h it was compiled again for any type changed anywhere
  if whole_init {
    let (t, used) = init_part(init.text.to_owned())
    put(b"init.c", unit_text(used, [t[:]], None, BSet::new()))
  } else {
    let buf = Buffer()
    for f in init_calls {
      buf.write_bytes(b"CSPLIT_INTERNAL void ")
      buf.write_bytes(f)
      buf.write_bytes(b"(void);\n")
    }
    if fixes.length() > 0 {
      buf.write_bytes(b"CSPLIT_INTERNAL void csplit_fix_layouts(void);\n")
    }
    buf.write_bytes(b"void moonbit_init() {\n")
    if fixes.length() > 0 {
      buf.write_bytes(b"csplit_fix_layouts();\n")
    }
    for f in init_calls {
      buf.write_bytes(f)
      buf.write_bytes(b"();\n")
    }
    buf.write_bytes(b"}\n")
    put(
      b"init.c",
      unit_text(BSet::new(), [buf.to_bytes()[:]], Some([]), BSet::new()),
    )
    let iu = []
    for u, _ in init_units {
      iu.push(u)
    }
    for u in sort_bytes(iu) {
      jobs.push((cat([u, b".c"]), 1, init_units[u]))
    }
  }
  // the globals in units of their own, each of a package's (its globals, and the string literals it alone uses),
  // a big package's in pieces by its globals' names without their numbers (moonc's numbers move as a program
  // has more or fewer of them); the literals more than one package uses in pieces of their own by their names
  // (named by their content); moonc's layout table with the layouts' constants in one. A unit is then the same text
  // in each test and each build that has the same globals of that package, kept (MBC_STORE): one data.c was made
  // new by every program and every change
  let lit = b"moonbit_string_literal_"
  // (which packages use each literal: its functions, its globals; and the first by name of the source files whose
  // functions use it)
  let lit_users : Map[Bytes, BSet] = Map([])
  let lit_file : Map[Bytes, Bytes] = Map([])
  let note_users = fn(text : BytesView, pkg : Bytes, file : Bytes?) {
    let mut p = 0
    while true {
      let s = find(text, lit, p)
      if s < 0 {
        break
      }
      let e = ident_end(text, s)
      let n = text[s:e].to_owned()
      match lit_users.get(n) {
        Some(u) => u.add(pkg)
        None => lit_users[n] = BSet::of([pkg])
      }
      if file is Some(fl) {
        match lit_file.get(n) {
          Some(old) if bcmp(old, fl) <= 0 => ()
          _ => lit_file[n] = fl
        }
      }
      p = e
    }
  }
  for k, f in rest {
    note_users(f.text, pk[k], ffile[k])
  }
  note_users(init.text, b" init", None)
  for k, n in data_names {
    if !starts(n, lit) {
      note_users(data[k], package_of(n), None)
    }
  }
  // (each global's group, and what places it in its group's pieces)
  let group_of = fn(k : Int) -> (Bytes, Bytes) {
    let n = data_names[k]
    if n == b"moonbit_layout_table_data" {
      (b" layout", b"")
    } else if starts(n, lit) {
      let renamed = names.get_or_default(n, n)
      match lit_users.get(n) {
        // (a package's literal in its pieces by the source file using it: a test's places, `file.mbt:245:3-245:30`,
        // move with every line put in above them, and by their names they were in every piece of the package: a
        // change of 68 lines to one file made all 64 of sfapp's pieces new, 2026-10-23)
        Some(u) if u.size() == 1 && u.items()[0] != b" init" =>
          (u.items()[0], lit_file.get_or_default(n, renamed))
        _ => (b" strings", renamed)
      }
    } else {
      (package_of(n), digits_stem(n).0)
    }
  }
  let groups = data_names.mapi(fn(k, _) { group_of(k) })
  let group_size : Map[Bytes, Int] = Map([])
  for k, g in groups {
    group_size[g.0] = group_size.get_or_default(g.0, 0) + clen(data_r[k])
  }
  let data_units : Map[Bytes, Array[(Bytes, Int)]] = Map([])
  for k, n in data_names {
    let (g, key) = groups[k]
    let label = if g == b" layout" {
      b"layout"
    } else if g == b" strings" {
      b"strings"
    } else {
      cat([b"p_", unit_label(g)])
    }
    let mut pieces = 1
    while g != b" layout" && pieces * (target / 2) < group_size[g] {
      pieces *= 2
    }
    let unit = if pieces > 1 {
      cat([
        b"data_",
        label,
        b"_",
        utf8((crc32(key) % pieces.reinterpret_as_uint()).to_string()),
      ])
    } else {
      cat([b"data_", label])
    }
    match data_units.get(unit) {
      Some(u) => u.push((names.get_or_default(n, n), k))
      None => data_units[unit] = [(names.get_or_default(n, n), k)]
    }
  }
  if !data_units.contains(b"data_layout") && layout_defs.length() > 0 {
    data_units[b"data_layout"] = []
  }
  let dus = []
  for u, _ in data_units {
    dus.push(u)
  }
  for u in sort_bytes(dus) {
    jobs.push((cat([u, b".c"]), 2, data_units[u]))
  }
  let nfirst = jobs.length()
  let us = []
  for u, _ in units {
    us.push(u)
  }
  for u in sort_bytes(us) {
    jobs.push((cat([u, b".c"]), 0, units[u]))
  }
  let ps = match pieces {
    Some(p) => p
    None => []
  }
  let size_of = fn(i : Int) {
    let (_, kind, entries) = jobs[i]
    let mut n = 0
    for e in entries {
      n += if kind == 1 {
        ps[e.1].1.length() + ps[e.1].2.length()
      } else if kind == 2 {
        data_r[e.1].length()
      } else {
        rest[e.1].text.length()
      }
    }
    n
  }
  tick("kinds, needs, first units")
  // (the globals as renamed in one text, as the declarations')
  let (r_text, r_at) = in_one(data_r)
  let global_text = fn(k : Int) -> BytesView { r_text[r_at[k]:r_at[k + 1]] }
  let results = run_jobs(jobs.length(), outdir, size_of, fn(i) {
    let (name, kind, entries) = jobs[i]
    if kind == 2 {
      // (globals: by their names, each after those of the unit it uses, each defined here and declared nowhere else
      // in the unit. In moonc's order, which moves with the program, a unit of the same globals was new text: 77 of
      // sfapp's test's units after a change to one file, 2026-10-23)
      let used = BSet::new()
      let defines = BSet::new()
      let at : Map[Bytes, Int] = Map([])
      for i, e in entries {
        at[e.0] = i
      }
      let by_name = stable_sort(Array::makei(entries.length(), fn(i) { i }), fn(a, b) {
        let c = bcmp(entries[a].0, entries[b].0)
        if c != 0 {
          c
        } else {
          bcmp(global_text(entries[a].1), global_text(entries[b].1))
        }
      })
      let placed = Array::make(entries.length(), false)
      let texts : Array[BytesView] = []
      fn place(i : Int) -> Unit {
        if placed[i] {
          return
        }
        placed[i] = true
        for id in sort_bytes(data_ids[entries[i].1].items()) {
          match at.get(id) {
            Some(j) if j != i => place(j)
            _ => ()
          }
        }
        texts.push(global_text(entries[i].1))
      }
      for i in by_name {
        place(i)
      }
      for e in entries {
        used.add_all(data_ids[e.1])
        defines.add(e.0)
      }
      if name == b"data_layout.c" {
        texts.push(layout_defs[:])
        texts.push(layout_fixes[:])
        used.add_all(fix_names)
      }
      let text = unit_text(used, lines_between(texts), None, defines)
      let ch = if write_if_changed(join_path(outdir, name), text) { 1 } else { 0 }
      return (clen(text), 0, ch)
    }
    let is_init = kind == 1
    let texts : Array[(Bytes, BytesView)] = []
    let used = BSet::new()
    for e in entries {
      if is_init {
        let x = ps[e.1]
        let (t, u) = init_part(cat([x.1, x.2]))
        texts.push(
          (
            e.0,
            cat([b"CSPLIT_INTERNAL void ", e.0, b"(void) {\n", t, b"}\n"])[:],
          ),
        )
        used.add_all(u)
      } else {
        let (t0, _) = rename(
          rest[e.1].text,
          names_t,
          local_ok=Some(file_ids),
          plain=Some(plain),
          used~,
        )
        let (t1, lu) = name_layouts(t0)
        texts.push((e.0, flatten(t1)))
        used.add_all(lu)
      }
    }
    let ordered = if is_init {
      texts
    } else {
      stable_sort(texts, fn(a, b) {
        let c = bcmp(a.0, b.0)
        if c != 0 {
          c
        } else {
          bcmp(a.1, b.1)
        }
      })
    }
    let text = unit_text(
      used,
      lines_between(ordered.map(fn(x) { x.1 })),
      Some(texts.map(fn(x) { x.1 })),
      BSet::new(),
    )
    let mut load = 0
    for x in texts {
      load += clen(x.1)
    }
    let ch = if write_if_changed(join_path(outdir, name), text) { 1 } else { 0 }
    (clen(text), load, ch)
  })
  let loads = []
  for i, r in results {
    written.push((jobs[i].0, r.0))
    changed += r.2
    if i >= nfirst {
      loads.push(r.1)
    }
  }
  tick("units")
  let mut npp = 0
  let mut nadded = 0
  for s in stats {
    if s.0 == "pp" {
      npp = s.1
    }
    if s.0 == "prototypes_added" {
      nadded = s.1
    }
  }
  let accounted = data.length() + funcs.length() + (decls.length() - npp - nadded)
  if accounted != nitems - npp {
    raise SplitError("\{nitems - npp} items, \{accounted} placed")
  }
  let mut largest = (-1, b"")
  for k, f in rest {
    let l = fclen[k]
    if l > largest.0 || (l == largest.0 && bcmp(f.name, largest.1) > 0) {
      largest = (l, f.name)
    }
  }
  // moonc's statics, global in the split: by their names and as renamed (mbc check)
  let made = static_names.copy()
  for n in statics.items() {
    match names.get(n) {
      Some(r) => made.add(r)
      None => ()
    }
  }
  made.add_all(layout_names)
  if fixes.length() > 0 {
    made.add(b"csplit_fix_layouts")
  }
  for f in init_calls {
    made.add(f)
  }
  {
    files: written,
    changed,
    functions: funcs.length(),
    globals: data.length(),
    stats,
    init_bytes: clen(init.text),
    unit_loads: loads,
    largest_function: largest.1,
    made_global: made.sorted(),
  }
}

///|
/// A binary heap of ints in `cmp`'s order, the least first
priv struct Heap {
  a : Array[Int]
  cmp : (Int, Int) -> Int
}

///|
fn Heap::new(cmp : (Int, Int) -> Int) -> Heap {
  { a: [], cmp }
}

///|
fn Heap::size(self : Heap) -> Int {
  self.a.length()
}

///|
fn Heap::push(self : Heap, x : Int) -> Unit {
  let a = self.a
  a.push(x)
  let mut i = a.length() - 1
  while i > 0 {
    let p = (i - 1) / 2
    if (self.cmp)(a[i], a[p]) >= 0 {
      break
    }
    let t = a[i]
    a[i] = a[p]
    a[p] = t
    i = p
  }
}

///|
fn Heap::pop(self : Heap) -> Int {
  let a = self.a
  let top = a[0]
  let last = a.pop().unwrap()
  if a.length() > 0 {
    a[0] = last
    let n = a.length()
    let mut i = 0
    while true {
      let l = 2 * i + 1
      let r = l + 1
      let mut m = i
      if l < n && (self.cmp)(a[l], a[m]) < 0 {
        m = l
      }
      if r < n && (self.cmp)(a[r], a[m]) < 0 {
        m = r
      }
      if m == i {
        break
      }
      let t = a[i]
      a[i] = a[m]
      a[m] = t
      i = m
    }
  }
  top
}

///|
/// What a function is an instance for: its name from the first `G` that opens moonc's type arguments (`Map0keysG…E`,
/// not a type's own name, which follows a `0`), its closures' `C…l…` taken off its end, so a type's instances of one
/// generic file and their closures are one piece of it; a name with none, itself.
fn type_args(name : Bytes) -> Bytes {
  let mut end = name.length()
  while true {
    // (a closure's: C<digits>l<digits> at the end)
    let mut j = end
    while j > 0 && is_digit(name[j - 1]) {
      j -= 1
    }
    if j == end || j == 0 || name[j - 1] != b'l' {
      break
    }
    let mut k = j - 1
    while k > 0 && is_digit(name[k - 1]) {
      k -= 1
    }
    if k == j - 1 || k == 0 || name[k - 1] != b'C' {
      break
    }
    end = k - 1
  }
  for i in 1..<end {
    if name[i] == b'G' && name[i - 1] != b'0' && name[i - 1] != b'_' {
      return sub(name, i, end)
    }
  }
  name
}
