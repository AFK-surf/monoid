// migrations.ts: what changed in how agents work, told to sessions that began before it (the notes themselves are
// texts.mbt `notes`).

///|
/// `latest`: the latest note's number.
pub fn latest() -> Int {
  match notes.last() {
    Some((n, _)) => n
    None => 0
  }
}

///|
/// `untold`: the notes a session told up to `told` has yet to hear, as one block before its messages, and where today's
/// whole instructions are (`full`); empty when there are none.
pub fn untold(told : Double, full : String) -> String {
  let said = notes.filter(n => n.0.to_double() > told && n.0 >= rewritten).map(n => "- \{n.1}")
  if said.is_empty() {
    return ""
  }
  "[still.fail changed how you work since this session began]\n" +
  said.join("\n") +
  "\nToday's whole instructions, tool parameters included, are in \{full}: read them when you need the details (your tool list may not show the new parameters; pass them anyway)."
}
