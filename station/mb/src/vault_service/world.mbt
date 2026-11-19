// What the vault's service asks of the rest of the station (station/src/vault/module.ts's deps, secrets.ts's
// `SecretsDeps`, signin.ts's `SignInDeps`): one structure of callbacks, given by whoever runs it (the station's program
// in Phase 4, the harness's test now). Synchronous where station/src calls synchronously (the store's reads and its
// writes of cards, the lock, the clock), async where it awaits (a post, a browser, another station, a process). The
// machine's own (a command started, TLS opened, a key signed) is `Machine` (machine.mbt).

///|
/// A conversation of a session's (store.ts `SessionThread`): its connect and its thread's id, channel, ts and surface.
#derive(Eq, Debug)
pub(all) struct Thread {
  connect : String
  id : Int
  channel : String
  thread_ts : String
  surface : String
}

///|
/// A thread as the store gives it, as JSON (`{connect, thread: {id, channel, threadTs, surface}}`).
pub fn Thread::of_json(j : Json) -> Thread? {
  let t = get(Some(j), "thread")
  match (gn(t, "id"), gs(t, "channel"), gs(t, "threadTs")) {
    (Some(id), Some(channel), Some(thread_ts)) =>
      Some({
        connect: gtext(Some(j), "connect"),
        id: id.to_int(),
        channel,
        thread_ts,
        surface: gtext(t, "surface"),
      })
    _ => None
  }
}

///|
pub fn Thread::to_json(self : Thread) -> Json {
  obj([
    ("connect", js(self.connect)),
    (
      "thread",
      obj([
        ("id", ji(self.id)),
        ("channel", js(self.channel)),
        ("threadTs", js(self.thread_ts)),
        ("surface", js(self.surface)),
      ]),
    ),
  ])
}

///|
/// A session's row as the vault reads it: its workspace (none: the station's home's) and whether its chat is archived.
#derive(Eq, Debug)
pub(all) struct SessionRow {
  ws : String?
  archived : Bool
}

///|
/// A message the store refuses for now: its writer is busy (store.ts `MessageWriteBusy`), tried again after a pause.
pub suberror WriteBusy

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for WriteBusy with output(self, logger) {
  match self {
    WriteBusy => logger.write_string("the store's writer is busy: the message is tried again after a pause")
  }
}

///|
/// The station's store as the vault and its sign-ins read and write it (secrets.ts `hub.store`, signin.ts's).
pub(all) struct Store {
  get_session : (String) -> SessionRow?
  /// Whoever started a session's chat (their email).
  starter : (String) -> String?
  /// The people who wrote in a session's chat.
  participants : (String) -> Array[String]
  latest_thread : (String) -> Thread?
  /// A session's latest thread where its order is ready (None: the store has no such read; Some(None): not ready).
  latest_thread_if_ready : ((String) -> Thread??)?
  session_thread_by_id : (String, Int) -> Thread?
  /// The ts of the card waiting in a thread, none where none waits.
  pending_card_header : (Int) -> String?
  pending_card_header_if_ready : ((Int) -> String??)?
  /// A message kept (store.ts `insertMessage`): its number; `before` run in its write first (it may refuse it).
  insert_message : (Json, (() -> Unit raise)?) -> Int raise
  withdraw_card : (String, Int, String) -> Bool
  restate_card : (String, Int, String, (Json?) -> Json) -> Bool
}

///|
/// The hub (sessions/hub.ts) as the vault asks it.
pub(all) struct Hub {
  store : Store
  prepare_latest_threads : (async (Array[String]) -> Unit)?
  prepare_card_posts : (async (Array[Int]) -> Unit)?
  /// A post said in a chat (`hub.chat(connect).post`): its ts.
  post : async (String, String, String, String) -> String
  shared : (Int, Int, String, String) -> Unit
  /// A notice given a session (`hub.notify`): raises where the session is gone.
  notify : (String, String) -> Unit raise
  /// The identity a session's actor says its messages with (`actors.get(session)?.messageIdentity()`).
  identity : async (String) -> Json?
}

///|
/// The lock pinned in a workspace, as the vault reads it (cloud/lock.ts `LockState`).
pub struct Lock {
  json : Json
  ws : String
  view : @vault.LockView
  /// Its members in their order: sub, email.
  members : Array[(String, String)]
  /// Its devices in their order: id, sub.
  devices : Array[(String, String)]
}

///|
/// A lock from its JSON: `{ws, members: {sub: {email, …}}, devices: {id: {sub, kind, sign_key, own}}, signKeys}`.
pub fn Lock::of_json(j : Json) -> Lock {
  let members = []
  if get(Some(j), "members") is Some(Object(ms)) {
    for sub, m in ms {
      members.push((sub, gtext(Some(m), "email")))
    }
  }
  let devices = []
  if get(Some(j), "devices") is Some(Object(ds)) {
    for id, d in ds {
      devices.push((id, gtext(Some(d), "sub")))
    }
  }
  {
    json: j,
    ws: gtext(Some(j), "ws"),
    view: @vault_crypto.lock_view(j),
    members,
    devices,
  }
}

///|
/// `lock.members.get(sub)?.email`.
pub fn Lock::email_of(self : Lock, sub : String) -> String? {
  for m in self.members {
    if m.0 == sub {
      return Some(m.1)
    }
  }
  None
}

///|
/// `lock.devices.get(id)?.sub`.
pub fn Lock::device_sub(self : Lock, id : String) -> String? {
  for d in self.devices {
    if d.0 == id {
      return Some(d.1)
    }
  }
  None
}

///|
/// `memberWithEmail(lock, email)?.sub`: the first member whose email, lower case, is `email`.
pub fn Lock::member_with_email(self : Lock, email : String) -> String? {
  for m in self.members {
    if lower(m.1) == email {
      return Some(m.0)
    }
  }
  None
}

///|
/// `membersWithEmail(lock, email)`: their subs, in the lock's order.
pub fn Lock::members_with_email(self : Lock, email : String) -> Array[String] {
  self.members.filter(m => lower(m.1) == email).map(m => m.0)
}

///|
/// `devicesFor(lock, sub)`.
pub fn Lock::devices_for(self : Lock, sub : String) -> Array[String] {
  self.devices.filter(d => d.1 == sub).map(d => d.0)
}

///|
/// The chats' browsers (secrets.ts `SignIns`, browser/browsers.ts).
pub(all) struct Browsers {
  cookies : async (String, Array[String], Bool) -> String
  passkeys_in : (async (String, Json) -> Unit)?
  sign_in : async (String, Json) -> Unit
  extend_sign_in : ((String, String, Double) -> Unit)?
}

///|
/// Another station of the workspace (secrets.ts `peer`): its id and name, None for this station; raises why not.
pub(all) struct Peer {
  id : String
  name : String
}

///|
/// What the process before this one does (module.ts `previous`): whether it is gone, and waiting for that.
pub(all) struct Previous {
  /// None: there was none (gone at the start).
  gone : (async () -> Unit)?
}

///|
/// A card's outcome kept with the write that decides it (store/card-outbox.ts `CardOutcomeSaver`).
pub(all) struct CardOutcomes {
  save : (Json, () -> Unit raise) -> Unit raise
}

///|
/// The station as the vault's service asks it.
pub(all) struct World {
  hub : Hub
  card_outcomes : CardOutcomes?
  /// The station's home workspace.
  home : () -> String?
  /// A chat's title, for the uses of a secret.
  title : ((String) -> String? raise)?
  /// Its title where its order is ready (Some(None): none; None: not ready).
  title_if_ready : ((String) -> String?? raise)?
  /// The station's data directory.
  data : String
  /// The lock pinned in a workspace (None: the home's), None where none is.
  lock : (String?) -> Lock?
  /// Milliseconds.
  now : () -> Double
  /// `f` once, `ms` from now (the machine's time); what it gives calls it off.
  after : (Double, () -> Unit) -> () -> Unit
  /// A pause of `ms` (the machine's time).
  sleep : async (Double) -> Unit
  peer : ((String) -> Peer? raise)?
  /// A request to another station of the workspace.
  ask : (async (String, Json) -> Json)?
  work_of : ((String, String, String) -> String)?
  coming : (() -> Bool)?
  previous : Previous
  browsers : Browsers?
  /// What the station keeps of the machine (machine.mbt).
  machine : Machine
  /// A hold on the station's updating itself (updates/holds.ts `hold`): what it gives lets go.
  hold : () -> () -> Unit
  /// The station's log (`log.info` / `warn` / `error`): its level, part, words and what they are about.
  log : (String, String, String, Json) -> Unit
  /// Random bytes.
  random : (Int) -> Bytes
  /// The station's environment (`process.env`), for the commands run with a secret.
  env : () -> Array[(String, String)]
  /// A connection of its own to the station's database, for the vault's background indexes (use-index.ts's reader,
  /// signin-save-builder.ts's builder); None where the database is in memory (a test's), where none is opened.
  index_db : (() -> @sql.Db raise)?
  /// The backfills' one permit (store/backfill.ts): taken while no foreground write waits (false: not now), given back.
  backfill_take : () -> Bool
  backfill_give : () -> Unit
  /// A foreground write under way (`foreground`): said as it begins and as it ends.
  foreground : (Bool) -> Unit
}

///|
fn World::warn(self : World, part : String, said : String, about : Json) -> Unit {
  (self.log)("warn", part, said, about)
}

///|
fn World::secs(self : World) -> Double {
  ((self.now)() / 1000.0).floor()
}
