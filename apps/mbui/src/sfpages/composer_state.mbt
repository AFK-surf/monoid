// What a composer is, apart from how a view draws it: whether it is opened (a box, its words over its row) or a
// capsule of one line, whether what is written can go, and what pressing send (or Enter) does with it. Read alike by
// the old view (composer.mbt) and the one made as nodes, each from what it keeps of its own (whether its field has
// the keyboard's focus, whether the box it stayed a moment after that went is still kept).

///|
/// Whether draft `w`'s composer is opened: laid out roomy (a new chat's in its page's middle), its field focused or
/// the box it stayed a moment after that left still kept (`lingers`), something written in it, a file or a quote
/// waiting.
fn composer_wants_open(w : Writing, roomy~ : Bool, focused~ : Bool, lingers~ : Bool) -> Bool {
  roomy ||
  focused ||
  lingers ||
  w.text.get() != "" ||
  w.files.get().length() > 0 ||
  w.quotes.get().length() > 0
}

///|
/// Whether what is written in draft `w` can go: as the core says, or as soon as there are words in its field (the
/// core's say comes a moment after them, its topic; send pressed meanwhile is not lost: what goes is the core's to
/// take, composer.take, nothing taken nothing sent); never while it is `locked`.
fn composer_ready(w : Writing, locked~ : Bool) -> Bool {
  (w.ready.get() || (w.field.text().trim() != "" && !w.starting.get())) && !locked
}

///|
/// Send pressed (or Enter) in draft `w`'s composer on `station`, where it is ready: its field's words as they are
/// now (typed since the core last heard, a frame not drawn yet) told the core first, then `send` once what they refer
/// to can be read in this workspace (sfbase's outside.mbt). True where it went on to send.
fn composer_submit(src : Source, w : Writing, station : String, locked~ : Bool, send : (Writing) -> Unit) -> Bool {
  guard composer_ready(w, locked~) else { return false }
  writing_text(src, w, w.field.text())
  @sfbase.send_sharing(src, w.key, station, w.text.get().trim(chars=" \n\t").to_owned(), fn() { send(w) })
  true
}
