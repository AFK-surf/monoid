// Trigger menu (@, /, # mention and slash-command triggers): pure UTF-16-safe trigger detection, replacement, and a
// lightweight coordinator tracking the active option index and Escape-dismissed trigger positions. Draws nothing, lays
// out nothing, and knows no theme.

///|
/// A rule describing a trigger prefix (such as `@`, `/`, or `#`).
/// `allow_spaces`: whether the query after the trigger may contain spaces.
/// `start_only`: whether the trigger is only recognized at the start of the text or immediately after a newline.
#derive(Eq, Debug)
pub(all) struct TriggerRule {
  trigger : String
  allow_spaces : Bool
  start_only : Bool
}

///|
/// A detected trigger match immediately preceding the cursor, with UTF-16 code unit offsets `[start, end)`.
#derive(Eq, Debug)
pub(all) struct TriggerMatch {
  trigger : String
  query : String
  start : Int
  end : Int
}

///|
fn tm_is_newline(cu : Int) -> Bool {
  cu == 0x0A || cu == 0x0D
}

///|
fn tm_is_space(cu : Int) -> Bool {
  cu == 0x20 || cu == 0x09 || cu == 0x3000
}

///|
fn tm_slice(text : String, start : Int, end : Int) -> String {
  if start >= end || start < 0 || end > text.length() {
    ""
  } else {
    text[start:end].to_owned()
  }
}

///|
fn tm_matches_at(text : String, pos : Int, trigger : String) -> Bool {
  let tlen = trigger.length()
  if tlen == 0 || pos < 0 || pos + tlen > text.length() {
    return false
  }
  for i in 0..<tlen {
    if text.code_unit_at(pos + i) != trigger.code_unit_at(i) {
      return false
    }
  }
  true
}

///|
fn tm_valid_boundary(text : String, pos : Int, start_only : Bool) -> Bool {
  if pos == 0 {
    return true
  }
  let prev = text.code_unit_at(pos - 1).to_int()
  if tm_is_newline(prev) {
    true
  } else if start_only {
    false
  } else {
    tm_is_space(prev)
  }
}

///|
/// Scan leftwards from `cursor` (UTF-16 code unit offset in `text`) for the nearest trigger matching one of `rules`.
/// A trigger must appear at the start of `text`, immediately after a newline, or (when `start_only` is false) after
/// whitespace. Scanning stops at a newline; spaces in the query are only accepted for rules with `allow_spaces = true`.
pub fn detect_trigger(text : String, cursor : Int, rules : Array[TriggerRule]) -> TriggerMatch? {
  let len = text.length()
  if rules.is_empty() || len == 0 {
    return None
  }
  let end = if cursor < 0 { 0 } else if cursor > len { len } else { cursor }
  if end == 0 {
    return None
  }
  let mut any_allow_spaces = false
  for r in rules {
    if r.allow_spaces {
      any_allow_spaces = true
      break
    }
  }
  let mut saw_space = false
  let mut pos = end - 1
  while pos >= 0 {
    let cu = text.code_unit_at(pos).to_int()
    if tm_is_newline(cu) {
      break
    }
    // Check whether any rule starts at `pos` and fits before `end`.
    for rule in rules {
      let tlen = rule.trigger.length()
      if tlen == 0 || pos + tlen > end {
        continue
      }
      if !tm_valid_boundary(text, pos, rule.start_only) {
        continue
      }
      if !tm_matches_at(text, pos, rule.trigger) {
        continue
      }
      // Verify the query slice `[pos + tlen, end)` has no newlines and obeys `allow_spaces`.
      let q_start = pos + tlen
      let mut ok = true
      if !rule.allow_spaces {
        for j in q_start..<end {
          let qcu = text.code_unit_at(j).to_int()
          if tm_is_space(qcu) || tm_is_newline(qcu) {
            ok = false
            break
          }
        }
      } else {
        for j in q_start..<end {
          if tm_is_newline(text.code_unit_at(j).to_int()) {
            ok = false
            break
          }
        }
      }
      if ok {
        return Some({ trigger: rule.trigger, query: tm_slice(text, q_start, end), start: pos, end })
      }
    }
    if tm_is_space(cu) {
      saw_space = true
      if !any_allow_spaces {
        break
      }
    }
    pos = pos - 1
  }
  let _ = saw_space
  None
}

///|
/// Replace the matched range `[m.start, m.end)` in `text` with `replacement` (plus a trailing space when
/// `trailing_space` is true). Returns `(new_text, new_cursor)` where `new_cursor` is the UTF-16 offset right after the
/// inserted text.
pub fn apply_trigger(
  text : String,
  m : TriggerMatch,
  replacement : String,
  trailing_space? : Bool = true,
) -> (String, Int) {
  let len = text.length()
  let start = if m.start < 0 { 0 } else if m.start > len { len } else { m.start }
  let end = if m.end < start { start } else if m.end > len { len } else { m.end }
  let before = tm_slice(text, 0, start)
  let after = tm_slice(text, end, len)
  let inserted = if trailing_space { replacement + " " } else { replacement }
  (before + inserted + after, start + inserted.length())
}

///|
/// Lightweight trigger-menu coordinator combining `detect_trigger` with active item navigation (`move_next`,
/// `move_prev`, `choose`, `dismiss`, `active`). Remembers a dismissed trigger `start` position so pressing Escape
/// suppresses reopening until the cursor leaves that trigger or the text changes.
pub struct TriggerMenu[K] {
  priv rules : Array[TriggerRule]
  priv mut items : Array[K]
  priv current : Ref[TriggerMatch?]
  priv active_idx : @signals.Signal[Int]
  priv dismissed : Ref[(Int, String)?]
  priv last_text : Ref[String]
}

///|
/// Create a new `TriggerMenu` matching `rules`.
pub fn[K] TriggerMenu::new(rules : Array[TriggerRule]) -> TriggerMenu[K] {
  {
    rules: rules.copy(),
    items: [],
    current: Ref(None),
    active_idx: @signals.signal(-1),
    dismissed: Ref(None),
    last_text: Ref(""),
  }
}

///|
/// Synchronize the menu with the current input `text`, `cursor`, and filtered candidate `items`.
/// Returns the active `TriggerMatch` if open (not dismissed), or `None`.
pub fn[K] TriggerMenu::update(
  self : TriggerMenu[K],
  text : String,
  cursor : Int,
  items : Array[K],
) -> TriggerMatch? {
  self.last_text.val = text
  self.items = items.copy()
  match detect_trigger(text, cursor, self.rules) {
    None => {
      self.dismissed.val = None
      self.current.val = None
      self.active_idx.set(-1)
      None
    }
    Some(m) => {
      if self.dismissed.val is Some((d_start, d_text)) {
        if d_start == m.start && d_text == text {
          self.current.val = None
          self.active_idx.set(-1)
          return None
        }
        self.dismissed.val = None
      }
      let prev_start = match self.current.val {
        Some(prev) => prev.start
        None => -1
      }
      self.current.val = Some(m)
      let n = self.items.length()
      if n == 0 {
        self.active_idx.set(-1)
      } else {
        let cur = self.active_idx.untracked()
        if prev_start != m.start || cur < 0 || cur >= n {
          self.active_idx.set(0)
        }
      }
      Some(m)
    }
  }
}

///|
/// The current active `TriggerMatch`, or `None` when closed or dismissed.
pub fn[K] TriggerMenu::matched(self : TriggerMenu[K]) -> TriggerMatch? {
  self.current.val
}

///|
/// Whether the menu is currently open with at least one candidate item.
pub fn[K] TriggerMenu::is_open(self : TriggerMenu[K]) -> Bool {
  self.current.val is Some(_) && self.active_idx.get() >= 0 && !self.items.is_empty()
}

///|
/// The currently highlighted candidate item, or `None` when closed or empty.
pub fn[K] TriggerMenu::active(self : TriggerMenu[K]) -> K? {
  let idx = self.active_idx.get()
  if self.current.val is Some(_) && idx >= 0 && idx < self.items.length() {
    Some(self.items[idx])
  } else {
    None
  }
}

///|
/// The currently highlighted candidate index (`-1` when closed or empty).
pub fn[K] TriggerMenu::active_index(self : TriggerMenu[K]) -> Int {
  let idx = self.active_idx.get()
  if self.current.val is Some(_) && idx >= 0 && idx < self.items.length() {
    idx
  } else {
    -1
  }
}

///|
/// Move the active index forward (wrapping around) and return the newly active item.
pub fn[K] TriggerMenu::move_next(self : TriggerMenu[K]) -> K? {
  let n = self.items.length()
  guard self.current.val is Some(_) && n > 0 else { return None }
  let cur = self.active_idx.untracked()
  let next = if cur < 0 || cur + 1 >= n { 0 } else { cur + 1 }
  self.active_idx.set(next)
  Some(self.items[next])
}

///|
/// Move the active index backward (wrapping around) and return the newly active item.
pub fn[K] TriggerMenu::move_prev(self : TriggerMenu[K]) -> K? {
  let n = self.items.length()
  guard self.current.val is Some(_) && n > 0 else { return None }
  let cur = self.active_idx.untracked()
  let prev = if cur <= 0 || cur >= n { n - 1 } else { cur - 1 }
  self.active_idx.set(prev)
  Some(self.items[prev])
}

///|
/// Choose the currently active item, closing the menu and returning the chosen item (or `None` if closed/empty).
pub fn[K] TriggerMenu::choose(self : TriggerMenu[K]) -> K? {
  let idx = self.active_idx.untracked()
  guard self.current.val is Some(_) && idx >= 0 && idx < self.items.length() else { return None }
  let picked = self.items[idx]
  self.current.val = None
  self.dismissed.val = None
  self.active_idx.set(-1)
  Some(picked)
}

///|
/// Dismiss the currently open menu (as on Escape). The same trigger `start` position stays suppressed until the cursor
/// leaves the trigger or the input text changes.
pub fn[K] TriggerMenu::dismiss(self : TriggerMenu[K]) -> Unit {
  if self.current.val is Some(m) {
    self.dismissed.val = Some((m.start, self.last_text.val))
  }
  self.current.val = None
  self.active_idx.set(-1)
}
