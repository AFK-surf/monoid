// A field's edits undone and done again: ⌘Z and ⇧⌘Z on Apple's systems, Ctrl+Z and Ctrl+Y (Ctrl+Shift+Z) elsewhere,
// and the menu bar's 撤销 and 重做, which press them. Each of the person's edits is kept as the field was before it. A
// run of typing is broken into words and at a pause, a change between inserting and deleting, or a bounded length.
// Each input-method candidate, paste and cut is a step of its own. What the app writes in it (Field::set) is not the
// person's edit: what was kept is let go of, as Compose's TextFieldState does after an edit of the program's.

///|
/// Which way a key goes through a field's edits: the last one undone, or the last undone done again.
priv enum Step {
  Undo
  Redo
}

///|
/// How many steps a field keeps to undo (Blink's UndoStack, kMaximumUndoStackDepth); past them the oldest is let go of.
let undo_depth : Int = 1000

///|
/// The kind of a contiguous run; a composition's deletion of a selection and its commit belong together.
#derive(Eq)
priv enum TypingKind {
  Inserting
  Deleting
  Composing
}

///|
/// The field as a run left it, and the last input's time, size and word boundary.
priv struct TypingRun {
  text : String
  anchor : Int
  caret : Int
  kind : TypingKind
  at : Double
  size : Int
  between : Bool
}

///|
/// A pause and an unbroken run's most UTF-16 units; one input is never split, even if it is longer.
let typing_pause_ms = 1000.0

///|
let typing_run_size = 32

///|
/// What key `code` with `mods` held is to a field on system `platform` (@ui.platform), as that system's own fields
/// have it: ⌘Z and ⇧⌘Z on Apple's; Ctrl+Z, Ctrl+Y and Ctrl+Shift+Z elsewhere (Blink's EditingBehavior). None: neither.
fn step_of(code : Int, mods : Int, platform : Int) -> Step? {
  let cmd = match platform {
    0 | 1 => mod_cmd
    _ => mod_ctrl
  }
  let held = mods & (mod_shift | mod_ctrl | mod_alt | mod_cmd)
  if code == key_of_char('z') && held == cmd {
    Some(Undo)
  } else if code == key_of_char('z') && held == (cmd | mod_shift) {
    Some(Redo)
  } else if code == key_of_char('y') && held == mod_ctrl && cmd == mod_ctrl {
    Some(Redo)
  } else {
    None
  }
}

///|
/// An edit made, the field having been `text` with its anchor and caret there before it: kept to undo, what was undone
/// let go of. Typing from where the last run left the field goes on in that step if it is still the same word, kind
/// and burst. Nothing when its words are as they were.
fn EditorState::edited(
  self : EditorState,
  text : String,
  anchor : Int,
  caret : Int,
  typing : Bool,
  now : Double,
  composing? : Bool = false,
) -> Unit {
  if self.text == text {
    return
  }
  let (start, was_end, end) = words_changed(text, self.text)
  let kind = if composing { Composing } else if was_end > start && end == start { Deleting } else { Inserting }
  let (changed, changed_end) = if kind == Deleting { (text, was_end) } else { (self.text, end) }
  let size = if kind == Deleting { was_end - start } else { end - start }
  let begins_between = changed_end > start && between_words_at(changed, start)
  let ends_between = changed_end > start && between_words_at(changed, changed_end - 1)
  let mut prior_size = 0
  let goes_on = match self.typed {
    Some(last) if typing && last.text == text && last.anchor == anchor && last.caret == caret && last.kind == kind => {
      prior_size = last.size
      kind == Composing ||
      (now >= last.at && now - last.at <= typing_pause_ms && last.size + size <= typing_run_size &&
       !(last.between && !begins_between))
    }
    _ => false
  }
  if !goes_on {
    self.undos.push((text, anchor, caret))
    if self.undos.length() > undo_depth {
      self.undos.remove(0) |> ignore
    }
  }
  self.redos.clear()
  self.typed = if typing {
    Some({
      text: self.text, anchor: self.anchor, caret: self.caret, kind, at: now,
      size: if goes_on { prior_size + size } else { size }, between: ends_between,
    })
  } else {
    None
  }
}

///|
/// What was kept to undo and to do again let go of: the app wrote its words.
fn EditorState::forget_edits(self : EditorState) -> Unit {
  self.undos.clear()
  self.redos.clear()
  self.typed = None
}

///|
/// The field's last edit undone, as it was before it, what was picked then picked again (Undo); or the last undone
/// done again (Redo). Nothing while the input method composes (its keys are its own then), nor when there is none.
fn EditorState::step(self : EditorState, s : Step, now : Double) -> Unit {
  let (before, anchor, caret) = (self.text, self.anchor, self.caret)
  self.step_edit(s, now)
  self.words_told()
  self.typed_told(before, anchor, caret, Undone)
}

///|
/// An undo or redo of it (EditorState::step's), done.
fn EditorState::step_edit(self : EditorState, s : Step, now : Double) -> Unit {
  if self.marked.length() > 0 {
    return
  }
  let (from, to) = match s {
    Undo => (self.undos, self.redos)
    Redo => (self.redos, self.undos)
  }
  guard from.pop() is Some((text, anchor, caret)) else { return }
  to.push((self.text, self.anchor, self.caret))
  self.put_words(text)
  self.anchor = anchor
  self.caret = caret
  self.typed = None
  self.pref_x = -1.0
  self.upstream = -1
  self.handle = false
  self.menu = false
  self.sel_handles = false
  self.blink0 = now
}
