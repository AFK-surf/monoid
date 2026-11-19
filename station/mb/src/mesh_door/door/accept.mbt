// An endpoint's connections, taken as they come (station/src/mesh/accept.ts): each served in a fiber of its own while
// the others are, and closed once it is served no more. Which protocol a connection speaks, what serves it and what is
// said when serving it fails are given to it.

///|
pub(all) struct Taken {
  /// Called as a connection is accepted, before it is served and before the next is accepted.
  arrived : (Connection) -> Unit
  /// One connection, served until it ends.
  serve : async (Connection) -> Unit
  /// What is said of a connection whose serving failed: by default, the log's "connection ended".
  failed : ((Error, Connection) -> Unit)?
  /// The reason a connection is closed with, code 0, as soon as it is served no more.
  closing : String
}

///|
/// Takes the endpoint's connections until it gives no more (`next` answers None), then returns, the connections still
/// served in `scope` until it closes.
pub async fn accept(next : async () -> Connection?, how : Taken, scope : @effect.Scope) -> Unit {
  while next() is Some(conn) {
    (how.arrived)(conn)
    ignore(
      scope.fork_daemon("mesh connection", on_error=e => log("info", "mesh", "connection ended", { "error": Json::string(message_of(e)) }), () => {
        defer (conn.close)(0, how.closing)
        (how.serve)(conn) catch {
          e =>
            match how.failed {
              Some(f) => f(e, conn)
              None =>
                log("info", "mesh", "connection ended", { "error": Json::string(message_of(e)) })
            }
        }
      }),
    )
  }
}
