// What makes a view do more than it must, found where it is written: a scoped computed or a bare effect where a node's
// own watch would do (scoped-computed, raw-effect), rows made by a loop in what a pick or a show makes
// (pick-loop), a list's row its least height said and no height (each-min-height), a list's row looking its item up in
// a whole list (each-lookup), a size of the layout read off a way as it is drawn (layout-drawn-while), a structure
// switched by the width a room is given (width-structure), a reused block's key read once as it is made
// (reused-untracked-key), and a fade out kept by hand (manual-fade-way).

///|
/// A lambda written at `k` (its `fn`): its parameters' names (`_` as written) and its body's `{`
fn MbtFile::lambda_at(self : MbtFile, k : Int) -> (Array[String], Int)? {
  let toks = self.toks
  guard k + 1 < toks.length() &&
    toks[k].kind == "ident" &&
    toks[k].text == "fn" &&
    toks[k + 1].text == "(" &&
    toks[k + 1].end >= 0 else {
    return None
  }
  let close = toks[k + 1].end
  let names = []
  let mut first = true
  let mut j = k + 2
  while j < close {
    let t = toks[j]
    if first && t.kind == "ident" {
      names.push(t.text)
      first = false
    }
    if is_open(t) && t.end >= 0 {
      j = t.end + 1
      continue
    }
    if t.kind == "op" && t.text == "," {
      first = true
    }
    j += 1
  }
  let mut b = close + 1
  while b < toks.length() && !(toks[b].kind == "op" && toks[b].text == "{") {
    if toks[b].kind == "op" && (toks[b].text == "(" || toks[b].text == "[") && toks[b].end >= 0 {
      b = toks[b].end
    }
    b += 1
  }
  if b < toks.length() && toks[b].end >= 0 {
    Some((names, b))
  } else {
    None
  }
}

///|
/// A call's argument: by its label, else its i-th positional one
fn arg_at(f : MbtFile, c : Call, i : Int, label : String) -> Array[Int]? {
  for a in c.args {
    if a.0 == Some(label) {
      return Some(a.1)
    }
  }
  let ps = positional(f, c.args)
  if i < ps.length() {
    Some(ps[i])
  } else {
    None
  }
}

///|
/// The lambda an argument is, its first parameter named: (that name, its body's `{`)
fn lambda_arg(f : MbtFile, a : Array[Int]?) -> (String, Int)? {
  guard a is Some(a) && a.length() > 0 else { return None }
  match f.lambda_at(a[0]) {
    Some((ps, b)) if ps.length() > 0 && ps[0] != "_" => Some((ps[0], b))
    _ => None
  }
}

///|
/// What a structure of the window's tree makes with what it is given (View::pick's make, show's then, each's row): the
/// view it is made in (the lambda's first parameter) and the lambda's body
priv struct Made {
  kind : String
  view : String
  open : Int
  close : Int
}

///|
fn made_by(f : MbtFile) -> Array[Made] {
  let out = []
  for c in f.calls {
    if c.kind != "method" || c.is_def {
      continue
    }
    let (i, label, least) = match c.name {
      // (switch_by: a pick at once, its make the same)
      "pick" | "switch_by" => (1, "make", 2)
      "show" => (1, "then", 2)
      "each" => (2, "row", 3)
      "each_of" => (1, "row", 2)
      _ => continue
    }
    // (an Array's each, given one function, is no structure)
    if positional(f, c.args).length() < least {
      continue
    }
    match lambda_arg(f, arg_at(f, c, i, label)) {
      Some((view, open)) =>
        out.push({ kind: c.name, view, open, close: f.toks[open].end })
      None => ()
    }
  }
  out
}

///|
/// The receiver of the method called at k, when it is a name alone (`v.box(…)`, not `a.b.box(…)` nor `f().box(…)`)
fn MbtFile::receiver_name(self : MbtFile, k : Int) -> String? {
  let toks = self.toks
  if k >= 2 &&
    toks[k - 1].text == "." &&
    toks[k - 2].kind == "ident" &&
    !(k >= 3 && toks[k - 3].text == ".") {
    Some(toks[k - 2].text)
  } else {
    None
  }
}

///|
/// The name a chain of methods called at k starts from (`row.grow(…).min_height(…)`: `row`)
fn MbtFile::chain_root(self : MbtFile, k : Int) -> String? {
  let toks = self.toks
  let mut at = k
  while at >= 2 && toks[at - 1].text == "." {
    let r = at - 2
    if toks[r].kind == "op" && toks[r].text == ")" {
      let o = self.open_of(r)
      if o >= 1 && toks[o - 1].kind == "ident" {
        at = o - 1
        continue
      }
      return None
    }
    if toks[r].kind == "ident" {
      if r >= 1 && toks[r - 1].text == "." {
        return None
      }
      return Some(toks[r].text)
    }
    return None
  }
  None
}

///|
/// The first positional argument of a call, when it is a name alone
fn first_name(f : MbtFile, c : Call) -> String? {
  match positional(f, c.args) {
    [a, ..] if a.length() == 1 && f.toks[a[0]].kind == "ident" => Some(f.toks[a[0]].text)
    _ => None
  }
}

///|
/// The methods of a View that make nodes in it
let node_makers : Array[String] = ["box", "show", "pick", "switch_by", "each", "each_of", "scrolls_window", "by_room"]

///|
/// What a view's call says of how it is laid out, given it: no node made
let node_setters : Array[String] = ["style_node", "presses_node"]

///|
/// Whether a call makes a node in one of `views`: a View's maker on it (`v.box(…)`), or a part made in it (its first
/// argument, a `*_node`, or what is given a function to make in it: `rg.item(v, …, fn(o, item) { … })`)
fn makes_in(f : MbtFile, c : Call, views : Array[String]) -> Bool {
  if c.is_def {
    return false
  }
  if c.kind == "method" && node_makers.contains(c.name) {
    match f.receiver_name(c.at) {
      Some(r) if views.contains(r) => return true
      _ => ()
    }
  }
  match first_name(f, c) {
    Some(v) if views.contains(v) && !node_setters.contains(c.name) =>
      c.name.has_suffix("_node") ||
      c.args.iter().any(fn(a) { lambda_arg(f, Some(a.1)) is Some(_) })
    _ => false
  }
}

///|
/// Whether a call runs what it is given later than it makes (a handler, a fiber, a callback): not as the view is made
fn runs_later(c : Call, label : String?) -> Bool {
  c.name.has_prefix("on_") ||
  handler_methods.contains(c.name) ||
  later_calls.contains(c.name) ||
  (match label {
    Some(l) => l.has_prefix("on_") || later_labels.contains(l) || l == "press"
    None => false
  })
}

///|
/// pick-loop: a `for` in what a pick or a show makes (that its own, not an each's in it) that makes nodes as it goes
/// round, as the view is made: each lambda between them one that makes in a view of it (`b.box(fn(r) { … })`,
/// `@sf.waiting_node(b, fn(w) { … })`), never one given to a handler or a binding, which runs later or reads
/// (`fn() { … }`)
fn lint_pick_loop(f : MbtFile, made : Array[Made], given : Map[Int, (Call, String?)], out : Array[Finding]) -> Unit {
  let toks = f.toks
  for k, t in toks {
    if t.kind != "ident" || t.text != "for" || f.in_test(k) {
      continue
    }
    // the innermost structure's making this `for` is in
    let mut inner : Made? = None
    for m in made {
      if m.open < k && k < m.close {
        match inner {
          Some(i) if i.close - i.open <= m.close - m.open => ()
          _ => inner = Some(m)
        }
      }
    }
    guard inner is Some(m) && (m.kind == "pick" || m.kind == "switch_by" || m.kind == "show") else { continue }
    // the lambdas between, outermost first: each made in a view of what holds it
    let views = [m.view]
    let mut made_now = true
    for j in (m.open + 1)..<k {
      if toks[j].kind != "ident" || toks[j].text != "fn" {
        continue
      }
      match f.lambda_at(j) {
        Some((ps, b)) if b < k && k < toks[b].end => {
          let ok = ps.length() > 0 &&
            ps[0] != "_" &&
            (match given.get(j) {
              Some((c, label)) =>
                !runs_later(c, label) &&
                (match f.receiver_name(c.at) {
                  Some(r) if c.kind == "method" && views.contains(r) => true
                  _ =>
                    match first_name(f, c) {
                      Some(v) => views.contains(v)
                      None => false
                    }
                })
              None => false
            })
          if !ok {
            made_now = false
            break
          }
          views.push(ps[0])
        }
        _ => ()
      }
    }
    if !made_now {
      continue
    }
    // its body: past its head (what it goes over, a lambda in it passed over)
    let mut b = k + 1
    while b < toks.length() && !(toks[b].kind == "op" && toks[b].text == "{") {
      if toks[b].kind == "ident" && toks[b].text == "fn" {
        match f.lambda_at(b) {
          Some((_, lb)) => {
            b = toks[lb].end + 1
            continue
          }
          None => ()
        }
      }
      if is_open(toks[b]) && toks[b].end >= 0 {
        b = toks[b].end
      }
      b += 1
    }
    if b >= toks.length() || toks[b].end < 0 {
      continue
    }
    let e = toks[b].end
    if f.calls.iter().any(fn(c) { b < c.at && c.at < e && makes_in(f, c, views) }) {
      out.push(finding("pick-loop", f.rel, t.line, f.line_text(k)))
    }
  }
}

///|
/// structure-box: a `.show(…)` / `.pick(…)` / `.switch_by(…)` callback `fn(x) { … }` or `fn(x, _) { … }` whose body
/// has only a single top-level `x.box(…)` call (with optional chain and `|> ignore` / `ignore(…)` / `let _ = …`)
/// and no other statements on `x`.
fn lint_structure_box(f : MbtFile, made : Array[Made], out : Array[Finding]) -> Unit {
  let toks = f.toks
  for m in made {
    if !(m.kind == "show" || m.kind == "pick" || m.kind == "switch_by") || f.in_test(m.open) {
      continue
    }
    let mut i = m.open + 1
    let mut end = m.close
    while end > i && toks[end - 1].kind == "op" && toks[end - 1].text == ";" {
      end -= 1
    }
    if i >= end {
      continue
    }
    let mut wrapped_ignore = false
    if i + 2 < end &&
      toks[i].kind == "ident" &&
      toks[i].text == "let" &&
      toks[i + 1].kind == "ident" &&
      toks[i + 1].text == "_" &&
      toks[i + 2].kind == "op" &&
      toks[i + 2].text == "=" {
      i += 3
    } else if i + 1 < end &&
      toks[i].kind == "ident" &&
      toks[i].text == "ignore" &&
      toks[i + 1].kind == "op" &&
      toks[i + 1].text == "(" &&
      toks[i + 1].end == end - 1 {
      i += 2
      end -= 1
      wrapped_ignore = true
    }
    if i + 3 >= end {
      continue
    }
    if !(toks[i].kind == "ident" &&
      toks[i].text == m.view &&
      toks[i + 1].kind == "op" &&
      toks[i + 1].text == "." &&
      toks[i + 2].kind == "ident" &&
      toks[i + 2].text == "box" &&
      toks[i + 3].kind == "op" &&
      toks[i + 3].text == "(" &&
      toks[i + 3].end >= 0 &&
      toks[i + 3].end < end) {
      continue
    }
    let box_tok = i + 2
    let mut j = toks[i + 3].end + 1
    while j + 2 < end &&
      toks[j].kind == "op" &&
      toks[j].text == "." &&
      toks[j + 1].kind == "ident" &&
      toks[j + 2].kind == "op" &&
      toks[j + 2].text == "(" &&
      toks[j + 2].end >= 0 &&
      toks[j + 2].end < end {
      j = toks[j + 2].end + 1
    }
    if !wrapped_ignore &&
      j + 1 < end &&
      toks[j].kind == "op" &&
      toks[j].text == "|>" &&
      toks[j + 1].kind == "ident" &&
      toks[j + 1].text == "ignore" {
      j += 2
      if j + 1 < end && toks[j].kind == "op" && toks[j].text == "(" && toks[j].end == j + 1 {
        j += 2
      }
    }
    if j == end {
      out.push(finding("structure-box", f.rel, toks[box_tok].line, f.line_text(box_tok)))
    }
  }
}

///|
/// A named style's say of a height: (its least said, other than none or 0; its height said)
priv struct Tall {
  least : Bool
  height : Bool
}

///|
let css_least : @re.Regex = rx("(?:^|[^\\w])min_h=(?!0(?:\\.0)?(?:[^\\w.]|$)|Z(?:[^\\w]|$))")

///|
let css_height : @re.Regex = rx("(?:^|[^\\w])h=")

///|
/// What the tokens from..<to say of a height: css text (`min_h=S5`, `h=Fixed(…)`), a style's labels (`min_h=Fixed(…)`,
/// `h=…`), and the named styles (top-level lets) they name, each as it says
fn tall_of(
  f : MbtFile,
  idx : Array[Int],
  named : Map[String, (MbtFile, Item)],
  memo : Map[String, Tall],
) -> Tall {
  let toks = f.toks
  let mut least = false
  let mut height = false
  for k in idx {
    let t = toks[k]
    if t.kind == "str" {
      least = least || css_least.search(t.text) is Some(_)
      height = height || css_height.search(t.text) is Some(_)
    } else if t.kind == "ident" && k + 1 < toks.length() && toks[k + 1].text == "=" {
      if t.text == "min_h" {
        let zero = k + 4 < toks.length() &&
          toks[k + 2].text == "Fixed" &&
          toks[k + 3].text == "(" &&
          toks[k + 4].kind == "num" &&
          (toks[k + 4].text == "0" || toks[k + 4].text == "0.0")
        least = least || !zero
      } else if t.text == "h" {
        height = true
      }
    } else if t.kind == "ident" &&
      (!(k > 0 && toks[k - 1].text == ".") || (k > 1 && toks[k - 2].kind == "at")) {
      match named_tall(t.text, named, memo) {
        Some(n) => {
          least = least || n.least
          height = height || n.height
        }
        None => ()
      }
    }
  }
  { least, height }
}

///|
fn named_tall(
  name : String,
  named : Map[String, (MbtFile, Item)],
  memo : Map[String, Tall],
) -> Tall? {
  match memo.get(name) {
    Some(t) => return Some(t)
    None => ()
  }
  guard named.get(name) is Some((nf, it)) else { return None }
  // (asked again on the way: says nothing more)
  memo[name] = { least: false, height: false }
  let got = tall_of(nf, Array::makei(it.end - it.start, fn(i) { it.start + 1 + i }), named, memo)
  memo[name] = got
  Some(got)
}

///|
/// Whether a View's height setter is given none, or a least of 0 (`Is(None)`, `Is(Some(0.0))`): what lets it shrink
fn said_none(f : MbtFile, c : Call) -> Bool {
  match positional(f, c.args) {
    [a, ..] => {
      let s = a.map(fn(i) { f.toks[i].text }).join("")
      s == "Is(None)" || s == "Is(Some(0.0))" || s == "Is(Some(0))"
    }
    _ => false
  }
}

///|
/// each-min-height: a row of View::each (each_of) whose own node says how tall it is at the least (`row.min_height`,
/// a style given it with `min_h=`, by name too) and says no height: laid out by what it holds, its words measured
/// every time the list lays it out
fn lint_each_min_height(
  f : MbtFile,
  made : Array[Made],
  named : Map[String, (MbtFile, Item)],
  memo : Map[String, Tall],
  out : Array[Finding],
) -> Unit {
  for m in made {
    if (m.kind != "each" && m.kind != "each_of") || f.in_test(m.open) {
      continue
    }
    let mut least_at = -1
    let mut height = false
    for c in f.calls {
      if c.at <= m.open || c.at >= m.close || c.is_def {
        continue
      }
      if c.kind == "method" && (c.name == "min_height" || c.name == "height") {
        if f.chain_root(c.at) != Some(m.view) || said_none(f, c) {
          continue
        }
        if c.name == "height" {
          height = true
        } else if least_at < 0 {
          least_at = c.at
        }
      } else if c.name == "style_node" && first_name(f, c) == Some(m.view) {
        let look = match positional(f, c.args) {
          [_, look, ..] => look
          _ => []
        }
        let t = tall_of(f, look, named, memo)
        height = height || t.height
        if t.least && least_at < 0 {
          least_at = c.at
        }
      }
    }
    if least_at >= 0 && !height {
      out.push(finding("each-min-height", f.rel, f.toks[least_at].line, f.line_text(least_at)))
    }
  }
}

///|
fn lint_perf(files : Array[MbtFile], cfg : Config, out : Array[Finding]) -> Unit {
  // the named styles: every top-level let, by its name
  let named : Map[String, (MbtFile, Item)] = Map([])
  for f in files {
    for it in f.items {
      if it.kind == "let" && it.name != "" {
        named[it.name] = (f, it)
      }
    }
  }
  let memo : Map[String, Tall] = Map([])
  for f in files {
    // a scoped computed or a bare effect, outside the parts said to keep them (detlint.json `signals`) and the tests
    for c in f.calls {
      if c.kind != "pkg" || c.qual != "@signals" || c.is_def || f.in_test(c.at) {
        continue
      }
      if c.name == "computed_scoped" && !under(f.rel, cfg.scoped_ok) {
        out.push(finding("scoped-computed", f.rel, f.toks[c.at].line, f.line_text(c.at)))
      }
      if (c.name == "effect" || c.name == "effect_cleanup") && !under(f.rel, cfg.effect_ok) {
        out.push(finding("raw-effect", f.rel, f.toks[c.at].line, f.line_text(c.at)))
      }
    }
    lint_layout_drawn_while(f, out)
    if under(f.rel, cfg.pages) || under(f.rel, cfg.library) {
      lint_raw_hover_ground(f, out)
    }
    lint_manual_fade_way(f, cfg, out)
    // each lambda given whole to a call: that call, and its label
    let given : Map[Int, (Call, String?)] = Map([])
    for c in f.calls {
      for a in c.args {
        if a.1.length() > 0 && f.toks[a.1[0]].text == "fn" {
          given[a.1[0]] = (c, a.0)
        }
      }
    }
    lint_width_structure(f, given, out)
    lint_reused_untracked_key(f, given, out)
    lint_scroll_each(f, given, out)
    lint_bare_on_press(f, out)
    lint_old_run_ctx(f, out)
    let made = made_by(f)
    if made.is_empty() {
      continue
    }
    lint_pick_loop(f, made, given, out)
    lint_structure_box(f, made, out)
    lint_each_min_height(f, made, named, memo, out)
    lint_each_lookup(f, made, given, out)
  }
}

///|
/// Whether the call at token `at`, in what was made from `open` to `close`, is in a lambda given to what runs it later
/// than the view is made or its bindings read (a handler, a press, a callback said by its label)
fn later_between(f : MbtFile, given : Map[Int, (Call, String?)], open : Int, at : Int) -> Bool {
  let toks = f.toks
  for j in (open + 1)..<at {
    if toks[j].kind != "ident" || toks[j].text != "fn" {
      continue
    }
    match f.lambda_at(j) {
      Some((_, b)) if b < at && at < toks[b].end =>
        match given.get(j) {
          Some((c, label)) if runs_later(c, label) || later_hands.contains(label.unwrap_or("")) => return true
          _ => ()
        }
      _ => ()
    }
  }
  false
}

///|
/// What a gesture is given to run as the hand does it (View::gesture's): later than the view is made
let later_hands : Array[String] = ["tap", "drag", "hold", "menu"]

///|
/// The methods that walk a list to find one of it
let lookup_methods : Array[String] = ["find_first", "search_by"]

///|
/// each-lookup: what a row of View::each (each_of) makes or binds looks its item up in a list by walking it
/// (`.find_first(…)`, `.search_by(…)`), what runs later than it (a press, a handler) aside: each row walks the list, and
/// what woke one woke them all, n rows n times n
fn lint_each_lookup(f : MbtFile, made : Array[Made], given : Map[Int, (Call, String?)], out : Array[Finding]) -> Unit {
  let seen : Map[Int, Bool] = Map([])
  for m in made {
    if (m.kind != "each" && m.kind != "each_of") || f.in_test(m.open) {
      continue
    }
    for c in f.calls {
      if c.at <= m.open || c.at >= m.close || c.is_def || c.kind != "method" || !lookup_methods.contains(c.name) {
        continue
      }
      // (one each in another: found once)
      if seen.contains(c.at) || later_between(f, given, m.open, c.at) {
        continue
      }
      seen[c.at] = true
      out.push(finding("each-lookup", f.rel, f.toks[c.at].line, f.line_text(c.at)))
    }
  }
}

///|
/// The setters of a node's size and room in the layout: what is laid out again as one changes
let layout_setters : Array[String] = [
  "width", "height", "min_width", "max_width", "min_height", "max_height", "padding", "margin", "basis", "gap",
]

///|
/// The reads of a way as it is drawn, which follow the clock while it goes
let drawn_reads : Array[String] = ["drawn_while", "shown_on"]

///|
/// layout-drawn-while: a size or room of the layout (`width`, `padding`…) given what reads a way as it is drawn
/// (`.drawn_while(…)`, `.shown_on(…)`): laid out again every frame of the way, its words measured and broken again
fn lint_layout_drawn_while(f : MbtFile, out : Array[Finding]) -> Unit {
  let toks = f.toks
  for c in f.calls {
    if c.kind != "method" || c.is_def || !layout_setters.contains(c.name) || f.in_test(c.at) {
      continue
    }
    guard c.at + 1 < toks.length() && toks[c.at + 1].text == "(" && toks[c.at + 1].end >= 0 else { continue }
    let close = toks[c.at + 1].end
    for d in f.calls {
      if d.at > c.at + 1 && d.at < close && d.kind == "method" && !d.is_def && drawn_reads.contains(d.name) {
        out.push(finding("layout-drawn-while", f.rel, toks[c.at].line, f.line_text(c.at)))
        break
      }
    }
  }
}

///|
/// Instantaneous hover/pointer predicates that must not switch `View::ground(By(…))` directly without easing.
let hover_hand_reads : Array[String] = [
  "lit_node", "hovered_node", "lit_in_node", "hovered_in_node", "pointed", "hovered",
]

///|
/// Easing reads whose presence in a `ground(By(…))` binding means the hover state is eased rather than snapped.
let hover_eased_reads : Array[String] = ["shown", "shown_on"]

///|
/// raw-hover-ground: `View::ground(By(…))` branching directly on `lit_node` / `hovered_node` / `pointed` / `hovered`
/// with no easing way (`shown`, `shown_on`), which snaps at 0 ms and overwrites any base `Card` or semantic ground.
fn lint_raw_hover_ground(f : MbtFile, out : Array[Finding]) -> Unit {
  let toks = f.toks
  for c in f.calls {
    if c.kind != "method" || c.is_def || c.name != "ground" || f.in_test(c.at) {
      continue
    }
    guard c.at + 1 < toks.length() && toks[c.at + 1].text == "(" && toks[c.at + 1].end >= 0 else { continue }
    let close = toks[c.at + 1].end
    let mut reads_hand = false
    let mut reads_eased = false
    for d in f.calls {
      if d.at > c.at + 1 && d.at < close && !d.is_def {
        if hover_hand_reads.contains(d.name) {
          reads_hand = true
        }
        if hover_eased_reads.contains(d.name) {
          reads_eased = true
        }
      }
    }
    if reads_hand && !reads_eased {
      out.push(finding("raw-hover-ground", f.rel, toks[c.at].line, f.line_text(c.at)))
    }
  }
}


///|
/// Whether a call is of the method `name` on the name `recv` alone (`recv.name(…)`)
fn MbtFile::called_on(self : MbtFile, c : Call, recv : String, name : String) -> Bool {
  c.kind == "method" && !c.is_def && c.name == name && self.receiver_name(c.at) == Some(recv)
}

///|
/// Whether the token at k names one of `names` as a value or a call of it: not a field or a method (`x.name`), not a
/// label (`name=`, `name~`), not what a `let` binds
fn MbtFile::names_one(self : MbtFile, k : Int, names : Map[String, Bool]) -> Bool {
  let toks = self.toks
  let t = toks[k]
  t.kind == "ident" &&
  names.contains(t.text) &&
  !(k > 0 && toks[k - 1].kind == "op" && toks[k - 1].text == ".") &&
  !(k > 0 && toks[k - 1].kind == "ident" && (toks[k - 1].text == "let" || toks[k - 1].text == "mut")) &&
  !(k + 1 < toks.length() &&
    toks[k + 1].kind == "op" &&
    (toks[k + 1].text == "~" || (toks[k + 1].text == "=" && !(k > 0 && toks[k - 1].text == "let"))))
}

///|
/// Whether a token from lo to hi names one of `names` (MbtFile::names_one)
fn MbtFile::names_within(self : MbtFile, lo : Int, hi : Int, names : Map[String, Bool]) -> Bool {
  for k in lo..=hi {
    if self.names_one(k, names) {
      return true
    }
  }
  false
}

///|
/// The functions a lambda's body (from its `{` at open to its `}` at close) binds to a name of its own
/// (`let room = fn() { … }`, `let fit : () -> Fitted? = fn() { … }`): each name, its body's `{`
fn MbtFile::local_fns(self : MbtFile, open : Int, close : Int) -> Array[(String, Int)] {
  let toks = self.toks
  let out = []
  for j in (open + 1)..<close {
    if toks[j].kind != "ident" || toks[j].text != "let" {
      continue
    }
    let mut n = j + 1
    if n < close && toks[n].kind == "ident" && toks[n].text == "mut" {
      n += 1
    }
    guard n + 1 < close && toks[n].kind == "ident" else { continue }
    // (past its type, where it says one: to its `=`, a bracket in it passed whole)
    let mut e = n + 1
    if toks[e].kind == "op" && toks[e].text == ":" {
      while e < close && !(toks[e].kind == "op" && toks[e].text == "=") {
        if is_open(toks[e]) && toks[e].end >= 0 {
          e = toks[e].end
        }
        e += 1
      }
    }
    guard e + 1 < close && toks[e].kind == "op" && toks[e].text == "=" else { continue }
    match self.lambda_at(e + 1) {
      Some((_, b)) if toks[b].end < close => out.push((toks[n].text, b))
      _ => ()
    }
  }
  out
}

///|
/// width-structure: in what a View::by_room makes (`fn(v, room) { … }`), a pick or a show whose condition reads the
/// room's width (`room.width()`), itself or through a function of the room's body that does, called or handed on
/// (`let room_w = fn() { given.width() - … }`, `let scale = fn() { … room_w() … }`, `show(menu, …)`): what is switched
/// is a structure made and let go as the width crosses it, coming and going as the window or a column is dragged. What
/// changes with the width is a binding (By). A pick or a show in another room's making of the same name is that one's;
/// one in what runs later (a press, a handler) is no arrangement.
fn lint_width_structure(f : MbtFile, given : Map[Int, (Call, String?)], out : Array[Finding]) -> Unit {
  let toks = f.toks
  // each room's making: its room's name and its body
  let rooms : Array[(String, Int, Int)] = []
  for c in f.calls {
    if !(c.kind == "method" && c.name == "by_room") || c.is_def || f.in_test(c.at) {
      continue
    }
    match arg_at(f, c, 0, "make") {
      Some(a) if a.length() > 0 =>
        match f.lambda_at(a[0]) {
          Some((ps, b)) if ps.length() >= 2 && ps[1] != "_" => rooms.push((ps[1], b, toks[b].end))
          _ => ()
        }
      _ => ()
    }
  }
  let seen : Map[Int, Bool] = Map([])
  for r in rooms {
    let (room, open, close) = r
    // whether the tokens lo..=hi read the room's width: its own `width()`, or a function of its body that does
    let wide : Map[String, Bool] = Map([])
    let reads = fn(lo : Int, hi : Int) {
      f.calls.iter().any(fn(d) { d.at >= lo && d.at <= hi && f.called_on(d, room, "width") }) ||
      f.names_within(lo, hi, wide)
    }
    // the room's body's functions that read its width, themselves or through another of them (to a fixed point)
    let fns = f.local_fns(open, close)
    let mut more = true
    while more {
      more = false
      for lf in fns {
        let (name, b) = lf
        if !wide.contains(name) && reads(b + 1, toks[b].end - 1) {
          wide[name] = true
          more = true
        }
      }
    }
    for c in f.calls {
      if c.at <= open ||
        c.at >= close ||
        c.kind != "method" ||
        c.is_def ||
        (c.name != "pick" && c.name != "show") ||
        seen.contains(c.at) {
        continue
      }
      // (an Array's or an Option's, given one function, is no structure)
      let said = c.args
        .iter()
        .filter(fn(a) { a.0 == Some("when") || a.0 == Some("then") || a.0 == Some("make") })
        .count()
      if positional(f, c.args).length() + said < 2 {
        continue
      }
      // (in another room's making that names its room the same: that one's)
      if rooms.iter().any(fn(o) { o.0 == room && o.1 > open && o.1 < c.at && c.at < o.2 }) {
        continue
      }
      if later_between(f, given, open, c.at) {
        continue
      }
      let cond = match arg_at(f, c, 0, "when") {
        Some(a) if a.length() > 0 => a
        _ => continue
      }
      if reads(cond[0], cond[cond.length() - 1]) {
        seen[c.at] = true
        out.push(finding("width-structure", f.rel, toks[c.at].line, f.line_text(c.at)))
      }
    }
  }
}

///|
/// reused-untracked-key: in what makes a page's list's block taken again for another key (View::scrolls_window's
/// `make_reused=fn(v, key) { … }`), the key read untracked (`@signals.untracked(key)`, `untracked(fn() { … key() … })`,
/// `key.untracked()`) as the block is made: what it reads stays the key it was made for, when the block shows another
/// one now. A block reads its key through `key()` where it is bound (By, a pick's which); what runs later than it is
/// made (a press, a handler) reads the key as it is then. So too a page's (the library's `page_node`), whose
/// `make_reused=fn(v, kind, key) { … }` is given the block's kind besides (View::reused_kind), its key the last.
fn lint_reused_untracked_key(f : MbtFile, given : Map[Int, (Call, String?)], out : Array[Finding]) -> Unit {
  let toks = f.toks
  let seen : Map[Int, Bool] = Map([])
  for c in f.calls {
    let listed = c.kind == "method" && c.name == "scrolls_window"
    let paged = c.name == "page_node" && (c.kind == "pkg" || c.kind == "bare")
    if !(listed || paged) || c.is_def || f.in_test(c.at) {
      continue
    }
    let (key, open, close) = match c.args.search_by(fn(a) { a.0 == Some("make_reused") }) {
      Some(i) if c.args[i].1.length() > 0 =>
        match f.lambda_at(c.args[i].1[0]) {
          // (the key its last: a list's `fn(v, key)`, a page's `fn(v, kind, key)`)
          Some((ps, b)) if ps.length() >= 2 && ps[ps.length() - 1] != "_" =>
            (ps[ps.length() - 1], b, toks[b].end)
          _ => continue
        }
      _ => continue
    }
    let keys : Map[String, Bool] = Map([(key, true)])
    for d in f.calls {
      if d.at <= open || d.at >= close || d.is_def || seen.contains(d.at) {
        continue
      }
      let hit = if f.called_on(d, key, "untracked") {
        true
      } else if d.name == "untracked" &&
        ((d.kind == "pkg" && d.qual == "@signals") || d.kind == "bare") {
        // (the key itself given it, or read in what it is given)
        d.args.iter().any(fn(a) { a.1.iter().any(fn(k) { f.names_one(k, keys) }) })
      } else {
        false
      }
      if !hit || later_between(f, given, open, d.at) {
        continue
      }
      seen[d.at] = true
      out.push(finding("reused-untracked-key", f.rel, toks[d.at].line, f.line_text(d.at)))
    }
  }
}

///|
/// manual-fade-way: a function of a page or of the library that fades a part out by hand: an `EdgeWay::new` it goes
/// along, an `at_moment` whose callback sets a signal (`there.set(false)`) and a `show` whose condition reads that
/// signal (`show(fn() { there.get() }, …)`): the part let go by a timer of its own as its own way ends, every such part
/// its own state, timer and way out, where what comes and goes is a structure that leaves over its time
/// (View::show's `leave`) and one fade is the framework's. Found once a function, at its first `EdgeWay::new`.
fn lint_manual_fade_way(f : MbtFile, cfg : Config, out : Array[Finding]) -> Unit {
  if !(under(f.rel, cfg.pages) || under(f.rel, cfg.library)) {
    return
  }
  let toks = f.toks
  for idx, it in f.items {
    if it.kind != "fn" || f.in_test(it.start) {
      continue
    }
    let mut way = -1
    // what an at_moment's callback sets
    let timed : Map[String, Bool] = Map([])
    for c in f.calls {
      if c.item != idx || c.is_def {
        continue
      }
      if c.kind == "type" && c.qual == "EdgeWay" && c.name == "new" && way < 0 {
        way = c.at
      } else if c.kind == "method" && c.name == "at_moment" {
        for a in c.args {
          guard a.1.length() > 0 else { continue }
          let (lo, hi) = (a.1[0], a.1[a.1.length() - 1])
          for d in f.calls {
            if d.at >= lo && d.at <= hi && d.kind == "method" && d.name == "set" && !d.is_def {
              match f.receiver_name(d.at) {
                Some(r) => timed[r] = true
                None => ()
              }
            }
          }
        }
      }
    }
    if way < 0 || timed.is_empty() {
      continue
    }
    let shown = f.calls.iter().any(fn(c) {
      c.item == idx &&
      c.kind == "method" &&
      c.name == "show" &&
      !c.is_def &&
      (match arg_at(f, c, 0, "when") {
        Some(a) if a.length() > 0 => f.names_within(a[0], a[a.length() - 1], timed)
        _ => false
      })
    })
    if shown {
      out.push(finding("manual-fade-way", f.rel, toks[way].line, f.line_text(way)))
    }
  }
}
