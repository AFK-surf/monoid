// What the route modules keep between requests in the station's one process (module-level in station/src/api/routes):
// the uploads in parts and what the uploads hold by content (hub.ts), each person's stars as last read (stars.ts).

///|
priv struct Held {
  mut path : String
  size : Double
  mtime_ms : Double
}

///|
priv struct State {
  /// What each uploads folder holds by its content (SHA-256, hex), oldest first.
  contents : Map[String, Map[String, Held]]
  /// Uploads in parts named as their parts come, by id: the running SHA-256.
  naming : Map[String, @hash.Sha256]
  /// Uploads in parts that are whole, by their id.
  assembled : Map[String, (Double, JV)]
  /// The last part asked of each upload in parts still under way: the next waits for it.
  part_turns : Map[String, @effect.Deferred[Unit]]
  /// Slack apps' ids learned from bot tokens, by connect.
  app_ids : Map[String, String]
  /// Each person's stars as last read or written.
  stars : Map[String, JV]
  /// The callbacks given the station's parts, by id (`{"$fn": id}`).
  callbacks : Map[Int32, async (Array[JV]) -> JV]
  mut callback_next : Int32
  /// What the routes set going and do not wait for.
  background : Array[@effect.Fiber[Unit]]
}

///|
fn State::new() -> State {
  {
    contents: {},
    naming: {},
    assembled: {},
    part_turns: {},
    app_ids: {},
    stars: {},
    callbacks: {},
    callback_next: 0,
    background: [],
  }
}
