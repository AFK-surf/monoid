// A place something went to or came from (a Slack thread, a Feishu chat, a Comma Task, a Group conversation, a still.fail
// chat) as a node of the window's tree, made once: its platform's mark and its name, pressed where it leads somewhere (an
// agent's history's line, a message's route in a chat).

///|
/// Place `name` of platform `surface` (the core's; its mark place_mark_name's), each as it changes, in `parent`: its mark
/// `mark` across and its name in `words`, in a box of `look` (given whether the hand is on it: lit_node's, where it is
/// pressed; its ground, its padding, its corner), giving way in its line (its name cut or wrapped where it is long, as
/// `words` says). `press`: what pressing it does, while `on` says
/// it leads somewhere (None, or `on` false: it is not pressed, never lit). The node.
#callsite(autofill(loc))
pub fn place_node(
  parent : @view.View,
  surface : () -> String,
  name : () -> String,
  look : (Bool) -> @ui.Style,
  words : @ui.TextStyle,
  press? : (() -> Unit)? = None,
  on? : () -> Bool = fn() { true },
  mark? : Double = 12.0,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(p) {
    style_node(loc~, p, fn() { look(press is Some(_) && on() && lit_node(p)) })
    // (giving way in its line: its name wrapped or cut where it is long)
    p.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
    match press {
      Some(go) => presses_node(p, go, on~)
      None => ()
    }
    p.pick(fn() { place_mark_name(surface(), theme().dark) }, fn(d, name) { place_mark_node(d, name, mark) |> ignore })
    words_node(p, name, fn() { words }).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
  })
}

///|
/// The drawable a place of platform `surface` (the core's Place `surface`) is marked with, in the dark theme where
/// `dark`: still.fail's for chat | ember | stillfail, Feishu's, Comma's, Group's, else Slack's.
pub fn place_mark_name(surface : String, dark : Bool) -> String {
  match surface {
    "chat" | "ember" | "stillfail" => if dark { "stillfail_mark_dark" } else { "stillfail_mark" }
    "feishu" | "comma" | "group" => surface
    _ => "slack"
  }
}

///|
/// A place's mark `name` (place_mark_name's) `w` wide in `parent`: Comma's, one colour, in the page's ink; the others
/// in their own colours. The node.
#callsite(autofill(loc))
pub fn place_mark_node(parent : @view.View, name : String, w : Double, loc~ : SourceLoc) -> @view.View {
  if name == "comma" {
    drawable_node(parent, name, w, tint=fn() { Some(theme().p.text) }, loc~)
  } else {
    drawable_node(parent, name, w, loc~)
  }
}
