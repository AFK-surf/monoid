// Input history: chat and command-line prompt history with draft preservation, consecutive deduplication, blank-entry
// filtering, and bounded capacity. Draws nothing, lays out nothing, and knows no theme.

///|
/// Bounded input history with up/down cursor navigation and draft preservation.
pub struct InputHistory {
  priv max_entries : Int
  priv list : Array[String]
  priv mut cursor : Int
  priv mut saved_draft : String
}

///|
/// Create a new `InputHistory` retaining up to `max_entries` most recent entries (default 100).
pub fn InputHistory::new(max_entries? : Int = 100) -> InputHistory {
  { max_entries: if max_entries < 0 { 0 } else { max_entries }, list: [], cursor: -1, saved_draft: "" }
}

///|
fn ih_is_blank(s : String) -> Bool {
  for c in s {
    if c != ' ' && c != '\t' && c != '\n' && c != '\r' && c != '\u{3000}' {
      return false
    }
  }
  true
}

///|
/// Record `entry` into the history, resetting the browsing cursor.
/// Ignores pure-whitespace entries and consecutive duplicates; evicts the oldest entry when exceeding `max_entries`.
pub fn InputHistory::push(self : InputHistory, entry : String) -> Unit {
  self.reset_cursor()
  if self.max_entries == 0 || ih_is_blank(entry) {
    return
  }
  let n = self.list.length()
  if n > 0 && self.list[n - 1] == entry {
    return
  }
  self.list.push(entry)
  while self.list.length() > self.max_entries {
    self.list.remove(0) |> ignore
  }
}

///|
/// Step backward to an older history entry.
/// On the first step from the live input, saves `current_draft` so stepping forward to the bottom restores it.
/// Returns `None` when the history is empty or already at the oldest entry.
pub fn InputHistory::prev(self : InputHistory, current_draft : String) -> String? {
  let n = self.list.length()
  if n == 0 {
    return None
  }
  if self.cursor < 0 {
    self.saved_draft = current_draft
    self.cursor = n - 1
    Some(self.list[self.cursor])
  } else if self.cursor > 0 {
    self.cursor = self.cursor - 1
    Some(self.list[self.cursor])
  } else {
    None
  }
}

///|
/// Step forward toward newer entries.
/// Past the newest entry, restores the saved draft and exits history browsing. Returns `None` when not browsing.
pub fn InputHistory::next(self : InputHistory) -> String? {
  if self.cursor < 0 {
    return None
  }
  let n = self.list.length()
  if self.cursor + 1 < n {
    self.cursor = self.cursor + 1
    Some(self.list[self.cursor])
  } else {
    let draft = self.saved_draft
    self.cursor = -1
    self.saved_draft = ""
    Some(draft)
  }
}

///|
/// Exit history browsing and discard any saved draft.
pub fn InputHistory::reset_cursor(self : InputHistory) -> Unit {
  self.cursor = -1
  self.saved_draft = ""
}

///|
/// A snapshot of recorded entries from oldest to newest.
pub fn InputHistory::entries(self : InputHistory) -> Array[String] {
  self.list.copy()
}

///|
/// Whether the cursor is currently positioned on a history entry (rather than the live draft).
pub fn InputHistory::at_history(self : InputHistory) -> Bool {
  self.cursor >= 0
}
