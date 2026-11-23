// Inline edit: click-or-key-to-edit state machine coordinating a preview node and an editor node.
// Enter or F2 (or click / optional double-click) on the preview enters editing with a draft initialized from `value()`;
// Enter in the editor commits and returns focus to the preview; Escape cancels, discards the draft, and returns focus;
// losing focus from the editor commits or cancels according to `submit_on_blur`. Draws nothing and lays out nothing.

///|
let ie_key_enter : Int = 7

///|
let ie_key_escape : Int = 17

///|
/// Key code for F2 (used alongside Enter to activate inline editing from the preview node).
pub let inline_edit_key_f2 : Int = 113

///|
/// Headless inline-edit state machine coordinating a preview node (`InlineEdit::preview`) and an editor node
/// (`InlineEdit::editor`).
pub struct InlineEdit {
  priv value_ : () -> String
  priv on_commit_ : (String) -> Unit
  priv on_cancel_ : () -> Unit
  priv disabled_ : () -> Bool
  priv submit_on_blur_ : Bool
  priv trim_ : Bool
  priv cancel_if_empty_ : Bool
  priv cancel_if_unchanged_ : Bool
  priv commit_on_outside_press_ : Bool
  priv editing_ : @signals.Signal[Bool]
  priv draft_ : @signals.Signal[String]
  priv trigger_ : Ref[@view.View?]
}

///|
/// Create an inline-edit controller over controlled `value`, calling `on_commit` with the draft on commit and
/// `on_cancel` on cancel.
pub fn InlineEdit::new(
  value : () -> String,
  on_commit : (String) -> Unit,
  on_cancel? : () -> Unit = fn() {  },
  disabled? : () -> Bool = fn() { false },
  submit_on_blur? : Bool = true,
  trim? : Bool = false,
  cancel_if_empty? : Bool = false,
  cancel_if_unchanged? : Bool = false,
  start_editing? : Bool = false,
  commit_on_outside_press? : Bool = false,
) -> InlineEdit {
  {
    value_: value,
    on_commit_: on_commit,
    on_cancel_: on_cancel,
    disabled_: disabled,
    submit_on_blur_: submit_on_blur,
    trim_: trim,
    cancel_if_empty_: cancel_if_empty,
    cancel_if_unchanged_: cancel_if_unchanged,
    commit_on_outside_press_: commit_on_outside_press,
    editing_: @signals.signal(start_editing),
    draft_: @signals.signal(if start_editing { @signals.untracked(value) } else { "" }),
    trigger_: Ref(None),
  }
}

///|
/// Whether the control is currently in editing mode. Followed where a binding reads it.
pub fn InlineEdit::editing(self : InlineEdit) -> Bool {
  self.editing_.get()
}

///|
/// The current editing draft text. Followed where a binding reads it.
pub fn InlineEdit::draft(self : InlineEdit) -> String {
  self.draft_.get()
}

///|
/// Update the editing draft text.
pub fn InlineEdit::set_draft(self : InlineEdit, text : String) -> Unit {
  self.draft_.set(text)
}

///|
/// Enter editing mode (when enabled and not already editing), copying the current `value()` into `draft`.
pub fn InlineEdit::start(self : InlineEdit) -> Unit {
  if @signals.untracked(self.disabled_) || self.editing_.untracked() {
    return
  }
  self.draft_.set(@signals.untracked(self.value_))
  self.editing_.set(true)
}

///|
fn InlineEdit::return_focus(self : InlineEdit) -> Unit {
  if self.trigger_.val is Some(t) && t.alive() {
    t.ask_focus() |> ignore
  }
}

///|
fn InlineEdit::finish_commit(self : InlineEdit, refocus : Bool) -> Unit {
  if !self.editing_.untracked() {
    return
  }
  let raw = self.draft_.untracked()
  let text = if self.trim_ { raw.trim(chars=" \t\n\r").to_owned() } else { raw }
  if (self.cancel_if_empty_ && text == "") ||
    (self.cancel_if_unchanged_ && text == @signals.untracked(self.value_)) {
    self.finish_cancel(refocus)
    return
  }
  self.editing_.set(false)
  (self.on_commit_)(text)
  if refocus {
    self.return_focus()
  }
}

///|
fn InlineEdit::finish_cancel(self : InlineEdit, refocus : Bool) -> Unit {
  if !self.editing_.untracked() {
    return
  }
  self.editing_.set(false)
  self.draft_.set(@signals.untracked(self.value_))
  (self.on_cancel_)()
  if refocus {
    self.return_focus()
  }
}

///|
/// Commit the current draft, exit editing mode, and return focus to the preview node if alive.
pub fn InlineEdit::commit(self : InlineEdit) -> Unit {
  self.finish_commit(true)
}

///|
/// Cancel editing, discard the draft back to `value()`, exit editing mode, and return focus to the preview node if
/// alive.
pub fn InlineEdit::cancel(self : InlineEdit) -> Unit {
  self.finish_cancel(true)
}

///|
/// Bind preview behavior to `v`: records `v` for focus return when editing ends, makes it focusable while enabled,
/// activates editing on Enter or F2, and activates on click (or double-click when `on_activate_double_click` is true).
pub fn InlineEdit::preview(self : InlineEdit, v : @view.View, on_activate_double_click? : Bool = false) -> Unit {
  self.trigger_.val = Some(v)
  v.owns(fn() {
    if self.trigger_.val is Some(t) && t.id() == v.id() {
      self.trigger_.val = None
    }
  })
  |> ignore
  let able = fn() { !(self.disabled_)() }
  v
  .presses(By(able))
  .focusable(By(able), keys=0)
  .on_key(fn(k) {
    if (self.disabled_)() || self.editing_.untracked() || k.mods != 0 {
      return false
    }
    if k.code == ie_key_enter || k.code == inline_edit_key_f2 {
      self.start()
      true
    } else {
      false
    }
  })
  |> ignore
  if on_activate_double_click {
    v.on_drag(fn(d) {
      if (self.disabled_)() || self.editing_.untracked() {
        return
      }
      if d.kind == Up && v.twice(d) {
        self.start()
      }
    })
    |> ignore
  } else {
    v.on_press(fn() {
      if !(self.disabled_)() && !self.editing_.untracked() {
        self.start()
      }
    })
    |> ignore
  }
}

///|
/// Bind editor behavior to `v`: focuses `v` when editing starts, commits and returns focus on Enter, cancels and
/// returns focus on Escape, and commits or cancels on blur according to `submit_on_blur`.
pub fn InlineEdit::editor(self : InlineEdit, v : @view.View) -> Unit {
  let able = fn() { !(self.disabled_)() && self.editing_.get() }
  v
  .presses(By(able))
  .focusable(By(able), keys=0)
  .on_key(fn(k) {
    if !self.editing_.untracked() || k.mods != 0 {
      return false
    }
    if k.code == ie_key_enter {
      self.commit()
      true
    } else if k.code == ie_key_escape {
      self.cancel()
      true
    } else {
      false
    }
  })
  |> ignore
  let seen_focus = Ref(false)
  let waiting_input = Ref(false)
  v.reacts(fn() { self.editing_.get() }, fn(ed) {
    if ed {
      seen_focus.val = false
      waiting_input.val = false
      if v.alive() && !@signals.untracked(self.disabled_) {
        if @signals.untracked(fn() { v.takes_input() }) {
          v.ask_focus() |> ignore
        } else {
          waiting_input.val = true
        }
      }
    }
  })
  // Deferred focus recovery: if `v` could not take input when editing started (e.g. a closing menu was still modal),
  // ask focus as soon as `takes_input()` becomes true and before focus has been seen.
  v.reacts(fn() { v.takes_input() }, at_start=false, fn(takes) {
    if !takes {
      if self.editing_.untracked() && !seen_focus.val {
        waiting_input.val = true
      }
    } else if waiting_input.val &&
      !seen_focus.val &&
      self.editing_.untracked() &&
      !@signals.untracked(self.disabled_) &&
      !@signals.untracked(fn() { v.focused() }) {
      waiting_input.val = false
      v.ask_focus() |> ignore
    }
  })
  if self.commit_on_outside_press_ {
    window_downs_while(v, fn() { self.editing_.get() }, fn(x, y) {
      let (left, top, w, h) = v.placed_window_now()
      if w > 0.0 && h > 0.0 && (x < left || x >= left + w || y < top || y >= top + h) {
        v.focus_let_go()
        if self.editing_.untracked() {
          if self.submit_on_blur_ {
            self.finish_commit(false)
          } else {
            self.finish_cancel(false)
          }
        }
      }
    })
  }
  let was_focused = Ref(false)
  v.reacts(fn() { v.focused() }, fn(now) {
    let prev = was_focused.val
    was_focused.val = now
    if now {
      seen_focus.val = true
      waiting_input.val = false
    } else if prev && self.editing_.untracked() {
      if self.submit_on_blur_ {
        self.finish_commit(false)
      } else {
        self.finish_cancel(false)
      }
    }
  })
}
