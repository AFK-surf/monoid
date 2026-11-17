// The copies of this station's chats as a part of the station (module.ts `CopiesLive`): the export, what the store says
// changed told to it, the other stations' requests of the copies this one keeps (`replica.*`) and of a retirement
// (`retire.*`), the copies' part of the overview; a station's retirement and station_retire's cards.

///|
/// Whether a person (POST /retire) or an agent (station_retire start, hand_over) may start retiring a station here. Off
/// (左子健, 2026-11-14): starting is refused in words; the rest is as it was.
pub let retire_starts = false

///|
/// The connect ids this station's chats of `ws` name (retire.ts `#used`), read of the station's database.
pub async fn used_connects(fs : Fs, db : String, ws : String, home : Bool) -> Array[String] {
  let d = @sql.Db::attach(fs.host, db, wait=5000)
  let rows = d.all(
    if home {
      "SELECT DISTINCT connect FROM sessions WHERE (ws = ? OR ws IS NULL)"
    } else {
      "SELECT DISTINCT connect FROM sessions WHERE ws = ?"
    },
    [Json::string(ws)],
  ) catch {
    e => {
      d.close()
      raise e
    }
  }
  d.close()
  rows.filter_map(r => match r.get("connect") {
    Some(String(c)) => Some(c)
    _ => None
  })
}

///|
/// The part: the copies, the retirement and its asks.
pub struct CopiesPart {
  copies : Copies
  retire : Retire
  asks : RetireAsks
}

///|
/// What this station answers of the copies and of a retirement, by the method's name (`replica.`, `retire.`).
pub async fn CopiesPart::answer(self : CopiesPart, peer : String, request : J, body : Body?, workspace : String?) -> Answer {
  let method = str_at(request, "method").unwrap_or("")
  if method.has_prefix("retire.") {
    let v = self.retire.answer((p, ws) => self.copies.in_workspace(p, ws), peer, request, body, workspace)
    return { value: v, body: None }
  }
  self.copies.answer(peer, request, body, workspace)
}

///|
/// The copies' part of the overview, for a viewer of `ws` (`manage`: an owner or admin).
pub fn CopiesPart::overview(self : CopiesPart, ws : String, manage : Bool) -> J {
  merged(self.copies.overview(ws, manage~), self.retire.overview(ws))
}

///|
/// Begun (the mesh attached).
pub async fn CopiesPart::start(self : CopiesPart) -> Unit {
  self.copies.start() catch {
    e => self.copies.w.warn("copies", "the copies did not start", jo([("error", js(message_of(e)))]))
  }
  self.retire.start() catch {
    e => self.copies.w.warn("retire", "the retirement did not go on", jo([("error", js(message_of(e)))]))
  }
}

///|
pub async fn CopiesPart::close(self : CopiesPart) -> Unit {
  self.retire.close()
  self.copies.close()
}
