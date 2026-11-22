// What the hub asks of what is outside it (station/src/sessions/hub.ts `HubOptions`, `SessionDeps`, and the parts the
// TypeScript hub is handed: the sessions' actors, the drivers, the chat surfaces, the accounts, the files): one seam,
// named calls in JSON, which the station's program answers with its own parts (the actors are the reader's
// `actors.mbt`, the rest Node's while they are) and the test with its fakes (harness.mbt).
//
// - `tell`: what the hub does of something outside that answers nothing (an actor's `kick`, a driver's `detach`, the
//   live view told a session runs): in the order the hub does it, at once.
// - `ask`: what it waits on (a post to a chat, an account picked, a file read).
// - the rest is read at once: its clock, its config, its workspaces, which chats are connected and what of them it
//   reads (their bot, their team), each actor's process state.

///|
pub(all) struct World {
  tell : (String, Json) -> Unit
  ask : async (String, Json) -> Json
  /// Now, by the hub's clock (ms).
  now : () -> Double
  /// HubConfig as JSON (config.ts `hubConfig`): read on every use.
  config : () -> Json
  /// The workspaces the station is in now, its home one first; none outside any.
  workspaces : () -> Array[String]
  /// This station's id in its workspaces.
  station : () -> String?
  /// A session's page in still.fail (its /o/ link).
  link : (String) -> String?
  /// A connect's chat surface where it is connected: `{botUserId, workspace, has: [its optional calls]}`.
  chat : (String) -> Json?
  /// An actor's process state ("running", "warm", "cold") and how long it has idled (None: not idle).
  process_state : (String) -> String
  idle_ms : (String, Double) -> Double?
  /// Random bytes (node:crypto `randomBytes`), as hex.
  random_hex : (Int) -> String
  /// Whether moving to another station is on here (every station's since it graduated; a test's may say not), as
  /// `HubOptions.moveOn` says it; None: not said (on).
  move_on : () -> Bool?
}

///|
/// Whether a connected chat surface has an optional call (`download`, `history`, `quoted`, `sessionLink`, …).
pub fn chat_has(chat : Json, call : String) -> Bool {
  items(field(chat, "has")).contains(Json::string(call))
}
