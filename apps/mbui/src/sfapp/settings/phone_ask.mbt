// An agent's request to debug its person's phone as a card (2026-10-29: as a vault request's): what
// is asked in its title, the agent's reason under it, and at its foot 允许 as the one solid button, 拒绝 beside it, and
// how long it is allowed a choice beside them that starts at the longest (`adb.decide` on the chat's station). Only the
// viewer's own request is answered; elsewhere a line says whose it is. Decided, a line says how it went. What it
// keeps between frames (its menu, the length picked, the answer under way) is the vault card's, keyed `phone/<id>`.
// Allowed on the phone itself, its 共享调试 switch is turned on with it; what the phone still lacks is a card under the
// line once granted (decision.mbt), each step done from there (2026-11-11: it said 需要先… and 查看步骤 took 允许's
// place, a settings page away, and back again for pairing). Only what cannot be allowed here at all takes 允许 away:
// this device not approved yet (查看步骤: settings' 共享调试 is that step), a station from before signatures.

///|
/// A request as the core has it (`adbShare`'s `grants`): whose it is, and what stands in its way.
fn phone_row(core : Core, request : String) -> Json? {
  items((core.topic)("adbShare", Map([])).get().value, "grants").iter().find_first(fn(g) { text(Some(g), "id") == request })
}

///|
/// How a granted phone is held by its station's adb, in words.
fn phone_link_words(link : String) -> String {
  match link {
    "connected" | "unpaired" | "gone" | "off" | "unauthorized" | "failed" | "missing" => tr("android-misc.adb.ask.link." + link)
    _ => tr("android-misc.adb.attaching")
  }
}

///|
/// How the station at `station` holds this phone for a granted request: as this phone's own lending to it says
/// (`adbShare`'s `lends`, as it changes) where it is lent there, else as the station said on the card (`said`).
pub fn phone_link(core : Core?, station : String, said : String) -> String {
  match core {
    Some(core) => {
      let view = adb_lend_view((core.topic)("adbShare", Map([])).get().value, station)
      if flag(view, "sharing") && text(view, "station") == station && text(view, "phase") == "offered" && text(view, "adb") != "" {
        text(view, "adb")
      } else {
        said
      }
    }
    None => said
  }
}

///|
/// How a request ended, in words (phone_outcome's).
pub fn phone_outcome_words(status : String, scope : String, why : String) -> String {
  let scope = if scope == "hour" || scope == "idle" || scope == "eight" { scope } else { "chat" }
  match status {
    "granted" => fill("android-misc.adb.ask.granted", [("scope", tr("android-settings.vault.scope." + scope))])
    "denied" if why == "" => tr("android-misc.adb.ask.denied")
    _ => fill("android-misc.adb.ask.ended", [("why", if why == "" { tr("android-misc.adb.ask.denied") } else { why })])
  }
}
