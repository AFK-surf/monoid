// Zero-config strict pure-tree preset (`detlint --preset=tree <ROOT>`) and its tree-specific rules:
// - scroll-each: `.each(` / `.each_of(` directly inside a `.scrolls(...)` callback instead of virtualized list
// - bare-on-press: `.on_press(` without `.says(` or `.as_ground()` on the same node
// - old-run-ctx: legacy immediate-mode entries (`@ui.run`, `@film.run`/`picture`/`film`, `Tester::new`)

///|
let preset_tree_rules : Array[String] = [
  // legacy Ctx / mixed entry blockers
  "old-run-ctx", "old-empty-around", "old-set-theme", "old-list", "old-island", "retired-api",
  "ui-current", "click-read", "key-read", "submitted-read",
  // pure-tree performance and reactivity anti-patterns
  "scroll-each", "raw-effect", "scoped-computed", "pick-loop", "each-min-height", "each-lookup",
  "layout-drawn-while", "width-structure", "reused-untracked-key", "layout-told",
  "along-row-at-once", "headless-on-drag", "structure-box",
  // accessibility and interaction robustness
  "bare-on-press",
  // determinism and test quality
  "frame-request", "settle", "flow-wait", "script-wait", "at-rest-wait", "frame-count",
  "frame-walk", "frame-wait", "unsettled-ok", "panic-test", "abort-unsaid", "wall-clock",
  "engine-math", "builtin-hash", "hash-order", "host-import", "host-read",
]

///|
let preset_tree_skip : Array[String] = [
  "_build", "_build/*", "*/_build", "*/_build/*",
  ".mooncakes", ".mooncakes/*", "*/.mooncakes", "*/.mooncakes/*",
  "target", "target/*", "*/target", "*/target/*",
  "node_modules", "node_modules/*", "*/node_modules", "*/node_modules/*",
  "out", "out/*", "*/out", "*/out/*",
  "libs/mbui", "libs/mbui/*", "*/libs/mbui", "*/libs/mbui/*",
  "monoid", "monoid/*", "*/monoid", "*/monoid/*",
  "vendor", "vendor/*", "*/vendor", "*/vendor/*",
]

///|
fn preset_tree_config() -> Config {
  let base = Config::new(@rjson.Value::Obj([]))
  {
    ..base,
    mbt_roots: ["."],
    flows: ["*.drive"],
    skip: preset_tree_skip,
  }
}

///|
/// scroll-each: `.each(...)` or `.each_of(...)` (View structures, not Array::each) inside a `.scrolls(...)` callback
/// body, outside tests and outside deferred handlers.
fn lint_scroll_each(f : MbtFile, given : Map[Int, (Call, String?)], out : Array[Finding]) -> Unit {
  let toks = f.toks
  let seen : Map[Int, Bool] = Map([])
  for c in f.calls {
    if c.kind != "method" || c.name != "scrolls" || c.is_def || f.in_test(c.at) {
      continue
    }
    let mut body : (Int, Int)? = None
    for a in c.args {
      if a.1.length() == 0 {
        continue
      }
      if runs_later(c, a.0) {
        continue
      }
      match f.lambda_at(a.1[0]) {
        Some((ps, open)) if ps.length() >= 1 && toks[open].end >= 0 =>
          body = Some((open, toks[open].end))
        _ => ()
      }
    }
    guard body is Some((open, close)) else { continue }
    for d in f.calls {
      if d.at <= open ||
        d.at >= close ||
        d.is_def ||
        d.kind != "method" ||
        (d.name != "each" && d.name != "each_of") ||
        seen.contains(d.at) {
        continue
      }
      let has_row_label = d.args.iter().any(fn(a) { a.0 == Some("row") })
      let pos = positional(f, d.args).length()
      let is_view_each = if d.name == "each" {
        pos >= 3 || has_row_label
      } else {
        pos >= 2 || has_row_label
      }
      if !is_view_each || later_between(f, given, open, d.at) {
        continue
      }
      seen[d.at] = true
      out.push(finding("scroll-each", f.rel, toks[d.at].line, f.line_text(d.at)))
    }
  }
}

///|
/// Whether a method chain containing the method call at token `k` includes `.says(...)` or `.as_ground(...)`
/// (or a `.box(fn(v) { ... })` earlier in the chain whose body calls `v.says(...)` / `v.as_ground(...)`).
fn chain_has_a11y(f : MbtFile, k : Int) -> Bool {
  let toks = f.toks
  // walk backward along `.method(...)` chain
  let mut at = k
  while at >= 2 && toks[at - 1].text == "." {
    let r = at - 2
    if toks[r].kind == "op" && toks[r].text == ")" {
      let o = f.open_of(r)
      if o >= 1 && toks[o - 1].kind == "ident" {
        let prev_name = toks[o - 1].text
        if prev_name == "says" || prev_name == "as_ground" {
          return true
        }
        if prev_name == "box" {
          // check if the `.box(fn(v) { ... })` body sets `v.says` or `v.as_ground`
          for c in f.calls {
            if c.at == o - 1 {
              for a in c.args {
                if a.1.length() > 0 {
                  match f.lambda_at(a.1[0]) {
                    Some((ps, b)) if ps.length() >= 1 && ps[0] != "_" && toks[b].end >= 0 =>
                      if block_has_a11y(f, ps[0], b, toks[b].end) {
                        return true
                      }
                    _ => ()
                  }
                }
              }
              break
            }
          }
        }
        at = o - 1
        continue
      }
      break
    }
    break
  }
  // walk forward along `.method(...)` chain
  if k + 1 < toks.length() && toks[k + 1].text == "(" && toks[k + 1].end >= 0 {
    let mut end = toks[k + 1].end
    while end + 3 < toks.length() &&
      toks[end + 1].kind == "op" &&
      toks[end + 1].text == "." &&
      toks[end + 2].kind == "ident" &&
      toks[end + 3].kind == "op" &&
      toks[end + 3].text == "(" &&
      toks[end + 3].end >= 0 {
      let next_name = toks[end + 2].text
      if next_name == "says" || next_name == "as_ground" {
        return true
      }
      end = toks[end + 3].end
    }
  }
  false
}

///|
/// Whether any call in `open..close` chained on `recv` is `.says(...)` or `.as_ground(...)`.
fn block_has_a11y(f : MbtFile, recv : String, open : Int, close : Int) -> Bool {
  for d in f.calls {
    if d.at > open &&
      d.at < close &&
      !d.is_def &&
      d.kind == "method" &&
      (d.name == "says" || d.name == "as_ground") &&
      f.chain_root(d.at) == Some(recv) {
      return true
    }
  }
  false
}

///|
/// Find the innermost enclosing `{ ... }` block containing token `k` (or the enclosing top-level item bounds).
fn enclosing_brace_or_item(f : MbtFile, k : Int) -> (Int, Int) {
  let toks = f.toks
  let mut o = k - 1
  while o >= 0 {
    if toks[o].kind == "op" && toks[o].text == "{" && toks[o].end > k {
      return (o, toks[o].end)
    }
    o -= 1
  }
  let it = f.item_of[k]
  if it >= 0 {
    (f.items[it].start, f.items[it].end)
  } else {
    (0, toks.length() - 1)
  }
}

///|
/// Find the innermost enclosing `.box(fn(v) { ... })` call (if any) whose lambda parameter is `recv` and contains `k`.
fn enclosing_box_for(f : MbtFile, k : Int, recv : String) -> (Int, Int, Int)? {
  let toks = f.toks
  let mut best : (Int, Int, Int)? = None
  for c in f.calls {
    if c.kind != "method" || c.name != "box" || c.is_def {
      continue
    }
    for a in c.args {
      if a.1.length() == 0 {
        continue
      }
      match f.lambda_at(a.1[0]) {
        Some((ps, b)) if ps.length() >= 1 &&
          ps[0] == recv &&
          toks[b].end >= 0 &&
          b < k &&
          k < toks[b].end =>
          match best {
            Some((_, bo, bc)) if bc - bo <= toks[b].end - b => ()
            _ => best = Some((c.at, b, toks[b].end))
          }
        _ => ()
      }
    }
  }
  best
}

///|
/// bare-on-press: in non-test files (excluding headless implementation itself), a node calling `.on_press(...)`
/// without `.says(...)` or `.as_ground()` in the same method chain or enclosing `.box(fn(v) { ... })` / block.
fn lint_bare_on_press(f : MbtFile, out : Array[Finding]) -> Unit {
  if f.test_file ||
    f.rel.has_prefix("headless/") ||
    f.rel.has_prefix("src/headless/") ||
    f.rel.contains("/headless/") {
    return
  }
  let toks = f.toks
  for c in f.calls {
    if c.kind != "method" || c.name != "on_press" || c.is_def || f.in_test(c.at) {
      continue
    }
    if chain_has_a11y(f, c.at) {
      continue
    }
    let mut ok = false
    match f.chain_root(c.at) {
      Some(recv) =>
        match enclosing_box_for(f, c.at, recv) {
          Some((box_at, b_open, b_close)) =>
            if block_has_a11y(f, recv, b_open, b_close) || chain_has_a11y(f, box_at) {
              ok = true
            }
          None => {
            let (open, close) = enclosing_brace_or_item(f, c.at)
            if block_has_a11y(f, recv, open, close) {
              ok = true
            } else {
              let it = f.item_of[c.at]
              if it >= 0 {
                let item = f.items[it]
                if block_has_a11y(f, recv, item.start, item.end) {
                  ok = true
                }
              }
            }
          }
        }
      None => ()
    }
    if !ok {
      out.push(finding("bare-on-press", f.rel, toks[c.at].line, f.line_text(c.at)))
    }
  }
}

///|
/// old-run-ctx: calls to `@ui.run(`, `@film.run(`, `@film.picture(`, `@film.film(`, or `Tester::new(`.
fn lint_old_run_ctx(f : MbtFile, out : Array[Finding]) -> Unit {
  let toks = f.toks
  for c in f.calls {
    if c.is_def {
      continue
    }
    let hit = (c.kind == "pkg" && c.qual == "@ui" && c.name == "run") ||
      (c.kind == "pkg" &&
      c.qual == "@film" &&
      (c.name == "run" || c.name == "picture" || c.name == "film")) ||
      (c.kind == "type" && c.qual == "Tester" && c.name == "new")
    if hit {
      out.push(finding("old-run-ctx", f.rel, toks[c.at].line, f.line_text(c.at)))
    }
  }
}
