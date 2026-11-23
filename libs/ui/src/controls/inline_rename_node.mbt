// A name changed in its place (a chat's row's title, a file's name in its row): one field, one way of ending it, as a
// desktop's file manager has it. Enter keeps the new name, Escape lets it be, and leaving it (a press anywhere else, or
// the focus gone from it) keeps it too; a name kept is trimmed, and one empty or as it was lets it be.

///|
/// What of the name is picked as its field comes (inline_rename_node's `picks`): all of it (a chat's title), all but
/// its extension (a file's name: its stem, as a file manager picks it), or as the field holds it already.
#derive(Eq)
pub(all) enum RenamePick {
  NameWhole
  NameStem
  NameAsGiven
}

///|
/// A name changed in its place in `parent`: a box (`frame` its look, said by the caller: where it stands, its ground,
/// its line) holding a line to type in, editing `field` (its words the name as it was, `was`); the focus given to it
/// as it comes (View::focus_opens: after what opened it, a menu closing, has given back what it took), or as soon as it
/// takes input where something still going over it holds it from it first. What of the name is picked then: `picks`.
/// It ends once: Enter, a press outside it, or the focus gone from it keeps what it holds (`commit`, given it trimmed)
/// where that is not empty and not `was`, else lets it be (`cancel`); Escape lets it be. Its words `size_by` large on
/// a line of `line` (0: their own), in `colors_by` (the words', the placeholder's, the caret's); `label` what a screen
/// reader calls it. The field's node.
#callsite(autofill(loc))
pub fn inline_rename_node(
  parent : @view.View,
  field : @ui.Field,
  was : String,
  label : String,
  commit : (String) -> Unit,
  cancel : () -> Unit,
  picks? : RenamePick = NameAsGiven,
  frame? : (@view.View) -> Unit = fn(_) {  },
  size_by? : () -> Double = fn() { theme().t.ui },
  line? : Double = 0.0,
  colors_by? : () -> (Int64, Int64, Int64) = fn() {
    let p = theme().p
    (p.text, p.muted, p.accent)
  },
  loc~ : SourceLoc,
) -> @view.View {
  let ie = @headless.InlineEdit::new(
    fn() { was },
    commit,
    on_cancel=cancel,
    trim=true,
    cancel_if_empty=true,
    cancel_if_unchanged=true,
    start_editing=true,
    commit_on_outside_press=true,
  )
  match picks {
    NameWhole => field.pick(0, field.text().length())
    NameStem => {
      let name = field.text()
      let to = match name.rev_find(".") {
        Some(i) if i > 0 => i
        _ => name.length()
      }
      field.pick(0, to)
    }
    NameAsGiven => ()
  }
  let made : Ref[@view.View?] = Ref(None)
  parent.box(made_for=loc, fn(b) {
    frame(b)
    let typed = @ui.field(
      b,
      field,
      size_by~,
      label~,
      line~,
      max_lines=1,
      enter_sends=true,
      colors_by~,
      submitted=fn(words) {
        ie.set_draft(words)
        ie.commit()
      },
    )
    typed.grow(Is(1.0)).basis(Is(Some(0.0))).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
    typed.reacts(fn() { field.text() }, fn(words) { ie.set_draft(words) })
    ie.editor(typed)
    b.focus_opens(typed) |> ignore
    made.val = Some(typed)
  })
  |> ignore
  made.val.unwrap()
}
