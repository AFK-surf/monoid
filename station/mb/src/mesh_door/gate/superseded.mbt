// A device's connections that its own process left behind (station/src/mesh/superseded.ts): when a device's endpoint
// connects again while it has connections here, each of those is asked whether its other end is still there, and closed
// if nothing is heard back. One that answers is left alone.

///|
pub let supersede_ms : Int = 3000

///|
pub let gone_code : Int = 4

///|
pub struct Superseded {
  open : Map[String, Array[@door.Connection]]
  within : Int
}

///|
pub fn Superseded::new(within? : Int = supersede_ms) -> Superseded {
  { open: Map([]), within }
}

///|
/// The connections of `id` it has open now.
pub fn Superseded::of(self : Superseded, id : String) -> Int {
  self.open.get(id).map(a => a.length()).unwrap_or(0)
}

///|
/// A connection came: those of its endpoint here before it are asked whether they are still there. Returns once each
/// has answered or been closed.
pub async fn Superseded::arrived(self : Superseded, conn : @door.Connection) -> Unit {
  let id = (conn.remote_id)()
  let mine = match self.open.get(id) {
    Some(m) => m
    None => {
      let m = []
      self.open[id] = m
      m
    }
  }
  let before = mine.filter(c => !(c.is_closed)())
  mine.push(conn)
  let rt = @effect.runtime()
  ignore(rt.fork_daemon("superseded forget", on_error=_ => (), () => {
    ignore((conn.closed)()) catch {
      _ => ()
    }
    match mine.search_by(c => physical_equal(c, conn)) {
      Some(i) => ignore(mine.remove(i))
      None => ()
    }
    if mine.length() == 0 && self.open.get(id) is Some(m) && physical_equal(m, mine) {
      self.open.remove(id)
    }
  }))
  ignore(@effect.all(before.map(old => async fn() { self.ask(old) })))
}

///|
async fn Superseded::ask(self : Superseded, old : @door.Connection) -> Unit {
  guard old.answers is Some(answers) else { return }
  let there = answers(self.within) catch { _ => true }
  if there || (old.is_closed)() {
    return
  }
  let id = (old.remote_id)()
  @door.log("info", "mesh", "a device's older connection is gone: closed", {
    "device": Json::string(if id.length() > 12 { id.clamped_view(end=12).to_owned() } else { id }),
  })
  (old.close)(gone_code, "gone")
}
