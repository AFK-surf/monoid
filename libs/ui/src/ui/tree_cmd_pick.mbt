// Quick-pick over selectable tree words while the command modifier (⌘ on macOS, Ctrl elsewhere) is held:
// a `words_picked` scope opts in via `words_cmd_pick(v, enabled, accent, on_click)`. While `enabled()` is true and the
// command modifier is held, hovering over any `picked_of` words node highlights and underlines the clause (or active
// selection) under the pointer with a pointing-hand cursor, and clicking it invokes `on_click(of, text)` instead of
// starting a text selection. Zero work runs when no scope is enabled or the command modifier is not held.

///|
priv struct CmdPickScope {
  enabled : () -> Bool
  accent : () -> Int64
  on_click : (String, String) -> Unit
}

///|
#derive(Eq)
priv struct CmdHover {
  scope_id : @view.NodeId
  node : @view.NodeId
  from : Int
  to : Int
  of : String
  text : String
  full_text : String
  accent : Int64
}

///|
// kept across runs: cleaned up by View::owns and window_kept_ui_7
let cmd_pick_scopes : Map[@view.NodeId, CmdPickScope] = Map([])

///|
// kept across runs: reset by view_forget and window_kept_ui_7
let cmd_hover : Ref[CmdHover?] = Ref(None)

///|
// kept across runs: reset by view_forget and window_kept_ui_7
let cmd_pick_down : Ref[(CmdHover, Double, Double)?] = Ref(None)

///|
// Active manual-selection underline while ⌘/Ctrl is held: `(scope_id, accent)` when the current tree selection
// belongs to an enabled `words_cmd_pick` scope and the command modifier is held.
// kept across runs: reset by view_forget and window_kept_ui_7
let cmd_sel_underline : Ref[(@view.NodeId, Int64)?] = Ref(None)

///|
/// Register a `words_picked` scope `v` for Cmd-hover quick-pick: while `enabled()` is true and the command modifier
/// (`mod_cmd` on macOS, `mod_ctrl` elsewhere) is held, hovering over any `picked_of` words node in `v`'s selection
/// scope highlights and underlines the clause under the pointer (or the active selection if the pointer is over it),
/// and clicking it invokes `on_click(of, text)`.
pub fn words_cmd_pick(
  v : @view.View,
  enabled : () -> Bool,
  accent : () -> Int64,
  on_click : (String, String) -> Unit,
) -> Unit {
  let scope_id = v.lent(words_picks).unwrap_or_else(fn() { v.id() })
  cmd_pick_scopes[scope_id] = { enabled, accent, on_click }
  v.owns(fn() {
    cmd_pick_scopes.remove(scope_id)
    match cmd_hover.val {
      Some(h) if h.scope_id == scope_id => cmd_hover_set(None)
      _ => ()
    }
    match cmd_pick_down.val {
      Some((h, _, _)) if h.scope_id == scope_id => cmd_pick_down.val = None
      _ => ()
    }
    match cmd_sel_underline.val {
      Some((sid, _)) if sid == scope_id => cmd_sel_underline_set(None)
      _ => ()
    }
  })
  |> ignore
}

///|
/// Update `cmd_sel_underline` and repaint every currently selected paragraph node so cached blocks immediately show
/// or hide the underline when ⌘/Ctrl is pressed or released during or after manual text selection.
fn cmd_sel_underline_set(next : (@view.NodeId, Int64)?) -> Unit {
  if cmd_sel_underline.val == next {
    return
  }
  // (a value, said as one: the pick's underline now, or none)
  match next {
    Some(u) => cmd_sel_underline.val = Some(u)
    None => cmd_sel_underline.val = None
  }
  match view_app.val {
    Some(tree) =>
      picked.spans.each(fn(k, sp) {
        if sp.a < sp.b {
          match picked_shown.get(k) {
            Some((node_id, _, _)) => tree.repaint_node(node_id)
            None => ()
          }
        }
      })
    None => ()
  }
  h_frame_owed()
}

///|
/// Recompute whether the active manual tree selection should display the ⌘/Ctrl underline.
fn cmd_sel_underline_update(mods? : Int? = None) -> Unit {
  let next : (@view.NodeId, Int64)? = if cmd_pick_held(mods~) && !picked.spans.is_empty() {
    match picked.layer {
      TreeScope(_, scope_id) =>
        match cmd_pick_scopes.get(scope_id) {
          Some(scope) if @signals.untracked(scope.enabled) => Some((scope_id, @signals.untracked(scope.accent)))
          _ => None
        }
      _ => None
    }
  } else {
    None
  }
  cmd_sel_underline_set(next)
}

///|
/// Update `cmd_hover` and mark the affected node(s) dirty in the tree so cached blocks (`view_blocks`) and rides
/// (`ride_kept`) repaint only the previously and newly highlighted nodes.
fn cmd_hover_set(next : CmdHover?) -> Unit {
  let prev = cmd_hover.val
  if prev == next {
    return
  }
  cmd_hover.val = next
  match view_app.val {
    Some(tree) => {
      match prev {
        Some(p) => tree.repaint_node(p.node)
        None => ()
      }
      match next {
        Some(n) => tree.repaint_node(n.node)
        None => ()
      }
    }
    None => ()
  }
  h_frame_owed()
}

///|
/// The command modifier bit for this platform's keys: ⌘ on macOS (`h_keys() == 0`), Ctrl elsewhere.
fn cmd_pick_mod() -> Int {
  if h_keys() == 0 {
    mod_cmd
  } else {
    mod_ctrl
  }
}

///|
/// Whether the command modifier is currently held according to the live modifier bits (`mods` from a key event when
/// available, else the host's live `mods_held()`, never stale across Cmd+Tab / focus changes).
fn cmd_pick_held(mods? : Int? = None) -> Bool {
  let m = match mods {
    Some(v) => v
    None => mods_held()
  }
  (m & cmd_pick_mod()) != 0
}

///|
/// Whether any registered `words_cmd_pick` scope is currently enabled.
fn cmd_pick_any_enabled() -> Bool {
  if cmd_pick_scopes.is_empty() {
    return false
  }
  let mut any = false
  cmd_pick_scopes.each(fn(_, s) {
    if !any && @signals.untracked(s.enabled) {
      any = true
    }
  })
  any
}

///|
/// Whether UTF-16 code unit `u` is whitespace.
fn cmd_pick_space(u : Int) -> Bool {
  u == 0x20 || u == 0x09 || u == 0x0A || u == 0x0D || u == 0x3000
}

///|
/// Whether UTF-16 code unit `u` is a CJK / full-width sentence terminator (`。`, `！`, `？`, `；`, `．`, `…`).
fn cmd_pick_cjk_stop(u : Int) -> Bool {
  u == 0x3002 || u == 0xFF01 || u == 0xFF1F || u == 0xFF1B || u == 0xFF0E || u == 0x2026
}

///|
/// Whether UTF-16 code unit `u` is an ASCII sentence terminator (`.`, `!`, `?`, `;`).
fn cmd_pick_ascii_stop(u : Int) -> Bool {
  u == 0x2E || u == 0x21 || u == 0x3F || u == 0x3B
}

///|
/// Whether UTF-16 code unit `u` is a CJK ideograph / Kana / Hangul (for splitting `好的!然后` without spaces).
fn cmd_pick_cjk_char(u : Int) -> Bool {
  (u >= 0x4E00 && u <= 0x9FFF) || (u >= 0x3400 && u <= 0x4DBF) || (u >= 0x3040 && u <= 0x30FF) || (u >= 0xAC00 && u <= 0xD7AF)
}

///|
/// Whether index `i` in `text` (within `[line_start, line_end)`) is a sentence boundary terminator:
/// a CJK terminator anywhere, `!`/`?` before whitespace, EOL, or CJK, or `.`/`;` before whitespace or EOL (so URLs
/// like `still.fail`, versions like `0.1.2`, and file names like `foo.mbt` stay intact).
fn cmd_pick_is_stop(text : String, i : Int, line_end : Int) -> Bool {
  let u = text.code_unit_at(i).to_int()
  if cmd_pick_cjk_stop(u) {
    return true
  }
  if cmd_pick_ascii_stop(u) {
    if i + 1 >= line_end {
      return true
    }
    let next = text.code_unit_at(i + 1).to_int()
    if cmd_pick_space(next) {
      return true
    }
    if (u == 0x21 || u == 0x3F) && cmd_pick_cjk_char(next) {
      return true
    }
    if (next == 0x22 || next == 0x27 || next == 0x29 || next == 0x5D || next == 0x300D || next == 0x201D) &&
      (i + 2 >= line_end || cmd_pick_space(text.code_unit_at(i + 2).to_int())) {
      return true
    }
  }
  false
}

///|
/// Whether index `i` in `text` (within `[line_start, line_end)`) is a clause comma: `，` anywhere, or `,` before
/// whitespace or EOL (so numbers like `1,000` and lists like `a,b` stay intact). A comma ends the picked clause
/// without being part of it.
fn cmd_pick_is_comma(text : String, i : Int, line_end : Int) -> Bool {
  let u = text.code_unit_at(i).to_int()
  if u == 0xFF0C {
    return true
  }
  u == 0x2C && (i + 1 >= line_end || cmd_pick_space(text.code_unit_at(i + 1).to_int()))
}

///|
/// Trim leading and trailing whitespace from UTF-16 range `[a, b)` in `text`.
fn cmd_pick_trim(text : String, a : Int, b : Int) -> (Int, Int) {
  let mut s = a
  let mut e = b
  while s < e && cmd_pick_space(text.code_unit_at(s).to_int()) {
    s = s + 1
  }
  while e > s && cmd_pick_space(text.code_unit_at(e - 1).to_int()) {
    e = e - 1
  }
  (s, e)
}

///|
/// Find the clause (between sentence terminators or commas, or a single line) containing UTF-16 offset `off` in
/// `text`. A sentence terminator stays in the clause; a comma does not.
fn cmd_pick_sentence(text : String, off : Int) -> (Int, Int) {
  let n = text.length()
  if n == 0 {
    return (0, 0)
  }
  let mut p = if off < 0 { 0 } else if off >= n { n - 1 } else { off }
  let mut line_start = p
  while line_start > 0 && text.code_unit_at(line_start - 1).to_int() != 0x0A {
    line_start = line_start - 1
  }
  let mut line_end = p
  while line_end < n && text.code_unit_at(line_end).to_int() != 0x0A {
    line_end = line_end + 1
  }
  if p >= line_end && p > line_start {
    p = line_end - 1
  }
  let mut s = p
  while s > line_start {
    if cmd_pick_is_stop(text, s - 1, line_end) || cmd_pick_is_comma(text, s - 1, line_end) {
      break
    }
    s = s - 1
  }
  let mut e = p
  while e < line_end {
    if cmd_pick_is_comma(text, e, line_end) {
      break
    }
    if cmd_pick_is_stop(text, e, line_end) {
      e = e + 1
      if e < line_end {
        let u = text.code_unit_at(e).to_int()
        if u == 0x22 || u == 0x27 || u == 0x29 || u == 0x5D || u == 0x300D || u == 0x201D || u == 0xFF09 {
          e = e + 1
        }
      }
      break
    }
    e = e + 1
  }
  let (ts, te) = cmd_pick_trim(text, s, e)
  if ts < te {
    (ts, te)
  } else {
    cmd_pick_trim(text, line_start, line_end)
  }
}

///|
/// Find the topmost selectable `words_runs` node under `(x, y)` that belongs to an enabled `words_cmd_pick` scope and
/// is not covered by another interactive control (`target_at` must be `Nothing` or `Pressed(c.id)` for the node's own
/// links). Does bounding-box + `seen_bounds` checks only during the tree walk, and runs `view_runs_laid` only on the
/// single hit node.
fn tree_cmd_hover_at(tree : @view.Tree, x : Double, y : Double) -> CmdHover? {
  let target = tree.target_at(x, y)
  let allow_node = match target {
    Nothing => None
    Pressed(id) => Some(id)
    _ => return None
  }
  let hit : Ref[(@view.Content, @view.View, @view.NodeId, CmdPickScope, String, Double, Double, Double)?] = Ref(None)
  tree.each_drawn_scaled(fn(c, cx, cy, a, s) {
    if c.runs.is_empty() || a <= 0.0 || !tree.allows(c.id) {
      return
    }
    if x < cx || y < cy || x >= cx + c.w * s || y >= cy + c.h * s {
      return
    }
    let (bx0, by0, bx1, by1) = tree.seen_bounds(c.id)
    if x < bx0 || y < by0 || x >= bx1 || y >= by1 {
      return
    }
    match allow_node {
      Some(tid) if tid != c.id => return
      _ => ()
    }
    match tree.view_of(c.id) {
      Some(v) =>
        match (v.lent(words_picks), v.lent(picked_ofs)) {
          (Some(scope_id), Some(of)) if v.lent(@view.runs_picker).map(fn(f) { physical_equal(f, words_picker) }) == Some(true) =>
            match cmd_pick_scopes.get(scope_id) {
              Some(scope) if @signals.untracked(scope.enabled) =>
                hit.val = Some((c, v, scope_id, scope, of, cx, cy, s))
              _ => ()
            }
          _ => ()
        }
      None => ()
    }
  })
  guard hit.val is Some((c, v, scope_id, scope, of, ox, oy, sc)) else { return None }
  let (_, lay, _) = view_runs_laid(
    c.runs,
    c.words_look,
    c.runs_look,
    c.w,
    tree.words_scale_of(c.id),
    kept=c.words_breaks,
    tabular=c.words_tabular,
  )
  let lx = (x - ox) / (if sc > 0.0 { sc } else { 1.0 })
  let ly = (y - oy) / (if sc > 0.0 { sc } else { 1.0 })
  let center_in = if c.words_center { c.w } else { -1.0 }
  let dx = rich_shift_at(lay, ly, center_in)
  let off = lay.offset_at(lx - dx, ly)
  let base = tree_key(v)
  // (if the pointer is over an active selection in this paragraph, highlight that selection; if the whole selection is
  // within this message, quote the full selected text)
  let (a, b, quote_text) = match picked.spans.get(base) {
    Some(sp) if sp.a < sp.b && off >= sp.a && off <= sp.b => {
      let full = match @signals.untracked(picked_now) {
        Some(p) if p.of.length() == 1 && p.strays == 0 && p.of[0] == of => p.text
        _ => lay.text.exact_view(start=sp.a, end=sp.b).to_owned()
      }
      (sp.a, sp.b, full)
    }
    _ => {
      let (sa, sb) = cmd_pick_sentence(lay.text, off)
      let slice = if sa < sb { lay.text.exact_view(start=sa, end=sb).to_owned() } else { "" }
      (sa, sb, slice)
    }
  }
  guard a < b && quote_text != "" else { return None }
  Some({
    scope_id,
    node: c.id,
    from: a,
    to: b,
    of,
    text: quote_text,
    full_text: lay.text,
    accent: @signals.untracked(scope.accent),
  })
}

///|
/// Recompute the Cmd-hover highlight target at the current mouse pointer (`view_point`).
/// Fast-paths immediately when no scope is enabled or the command modifier is not held.
fn cmd_hover_update(laid? : Bool = true, over? : Bool = false, mods? : Int? = None) -> Unit {
  cmd_sel_underline_update(mods~)
  // (keep the highlight visible while a Cmd-click press is held down)
  if cmd_pick_down.val is Some(_) {
    return
  }
  let next : CmdHover? = if !over &&
    pointing() is Mouse &&
    view_held.val is None &&
    cmd_pick_held(mods~) &&
    cmd_pick_any_enabled() {
    match (view_app.val, view_point.val) {
      (Some(tree), Some((x, y))) => {
        if laid {
          tree.laid_as_now()
        }
        tree_cmd_hover_at(tree, x, y)
      }
      _ => None
    }
  } else {
    None
  }
  cmd_hover_set(next)
}

///|
/// Clear any active Cmd-hover and pending Cmd-click as the views are forgotten (view_forget).
fn cmd_hover_clear() -> Unit {
  // (as the views are forgotten: nothing left to repaint, so put back as the lets have them)
  cmd_pick_down.val = None
  cmd_hover.val = None
  cmd_sel_underline.val = None
}

///|
/// Handle primary mouse down at (x, y) when Cmd-hover is active: consumes the press so it neither starts a text
/// selection nor activates a link underneath.
fn cmd_pick_press_down(x : Double, y : Double) -> Bool {
  guard pointing() is Mouse && cmd_pick_held() && cmd_pick_any_enabled() else { return false }
  cmd_hover_update(laid=true, over=false)
  match cmd_hover.val {
    Some(h) => {
      cmd_pick_down.val = Some((h, x, y))
      view_held.val = Some(Nowhere)
      h_frame_owed()
      true
    }
    None => false
  }
}

///|
/// Cancel a pending Cmd-click if the pointer moves beyond a small slop before release.
fn cmd_pick_press_move(x : Double, y : Double) -> Unit {
  match cmd_pick_down.val {
    Some((_, x0, y0)) if (x - x0).abs() > 6.0 || (y - y0).abs() > 6.0 => {
      cmd_pick_down.val = None
      cmd_hover_set(None)
    }
    _ => ()
  }
}

///|
/// Complete a pending Cmd-click on primary mouse up, invoking the scope's `on_click(of, text)`.
fn cmd_pick_press_up(fire : Bool) -> Bool {
  match cmd_pick_down.val {
    Some((h, _, _)) => {
      cmd_pick_down.val = None
      view_held.val = None
      if fire {
        match cmd_pick_scopes.get(h.scope_id) {
          Some(scope) if @signals.untracked(scope.enabled) => (scope.on_click)(h.of, h.text)
          _ => ()
        }
      }
      cmd_hover_update(laid=false, over=false)
      h_frame_owed()
      true
    }
    None => false
  }
}

///|
/// Paint the Cmd-hover highlight tint and underline on `c` if `cmd_hover` targets it, and also paint the underline
/// under any manually selected span (`c.runs_picked`) while ⌘/Ctrl is held.
fn paint_cmd_hover(ctx : Ctx, c : @view.Content, lay : RichLayout, center_in : Double) -> Unit {
  let mut hovered_span : (Int, Int)? = None
  match cmd_hover.val {
    Some(h) if h.node == c.id && h.from < h.to && lay.text == h.full_text => {
      hovered_span = Some((h.from, h.to))
      let raw = lay.rects(h.from, h.to)
      let lines : Array[(Double, Double, Double, Double)] = []
      for r in raw {
        let (x, y, w, h0) = r
        match lines.last() {
          Some((lx, ly, lw, lh)) if y < ly + lh && y + h0 > ly => {
            let x0 = dmin(lx, x)
            let y0 = dmin(ly, y)
            lines[lines.length() - 1] = (x0, y0, dmax(lx + lw, x + w) - x0, dmax(ly + lh, y + h0) - y0)
          }
          _ => lines.push(r)
        }
      }
      let ground = (h.accent & 0xFFFFFF00L) | 0x26L
      let line = (h.accent & 0xFFFFFF00L) | 0xE6L
      let line_w = 1.5
      let round = 3.0
      for li, rect in lines {
        let dx = rich_shift_at(lay, rect.1 + rect.3 / 2.0, center_in)
        ctx.emit_rect(rect.0 + dx, rect.1, rect.2, rect.3, 0.0, ground, 0.0, 0L, 1.0)
        let rad = dmin(round, dmin(rect.2, rect.3) / 2.0)
        let first = if li == 0 { rad } else { 0.0 }
        let last = if li == lines.length() - 1 { rad } else { 0.0 }
        ctx.corners_each(ctx.ninst - 1, first, last, last, first)
        ctx.emit_rect(rect.0 + dx, rect.1 + rect.3 - line_w, rect.2, line_w, 0.0, line, 0.0, 0L, 1.0)
      }
    }
    _ => ()
  }
  let (pa, pb) = c.runs_picked
  if pa < pb && hovered_span != Some((pa, pb)) {
    match cmd_sel_underline.val {
      Some((_, accent)) => {
        let raw = lay.rects(pa, pb)
        let lines : Array[(Double, Double, Double, Double)] = []
        for r in raw {
          let (x, y, w, h0) = r
          match lines.last() {
            Some((lx, ly, lw, lh)) if y < ly + lh && y + h0 > ly => {
              let x0 = dmin(lx, x)
              let y0 = dmin(ly, y)
              lines[lines.length() - 1] = (x0, y0, dmax(lx + lw, x + w) - x0, dmax(ly + lh, y + h0) - y0)
            }
            _ => lines.push(r)
          }
        }
        let line = (accent & 0xFFFFFF00L) | 0xE6L
        let line_w = 1.5
        for rect in lines {
          let dx = rich_shift_at(lay, rect.1 + rect.3 / 2.0, center_in)
          ctx.emit_rect(rect.0 + dx, rect.1 + rect.3 - line_w, rect.2, line_w, 0.0, line, 0.0, 0L, 1.0)
        }
      }
      None => ()
    }
  }
}
