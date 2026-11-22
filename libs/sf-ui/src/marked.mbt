// What a search found, as its rows show it:
// the words found in a line marked (bold, a hand-drawn stroke under each), what is said of a row beside each other, and
// what each kind found is drawn with. The phone's search and the desktop's ⌘K both draw with them.

///|
/// Words beside each other in a row's meta: the ones said, " · " between them.
pub fn join_meta(parts : Array[String]) -> String {
  parts.filter(fn(p) { p != "" }).join(" · ")
}

///|
/// What a kind is drawn with.
pub fn kind_icon(kind : String) -> String {
  match kind {
    "file" => "file"
    "job" => "web"
    "station" => "server"
    "member" => "user"
    _ => "search"
  }
}
