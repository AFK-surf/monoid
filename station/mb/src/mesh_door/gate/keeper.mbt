// What the station's mesh stands on and is not the mesh's own (station/src/mesh/serve.ts's `Cloud`, the lock's rules,
// the person logs kept, the ways and the stations' marks, the builds seen): given to it as one `Keeper`, typed, so the
// door's admission and the lock's routes are worked out here whoever keeps those. The station's MoonBit cloud gives
// its own; the harness one that asks the TypeScript station's (`Keeper::asking`), so what is worked out here is held
// to the TypeScript on the same state.

///|
/// A lock's device, as the state says it (cloud/lock.ts `Device`: what the mesh reads of it).
pub(all) struct LockDevice {
  id : String
  sub : String
  kind : String
  by : String?
  sign_key : String?
}

///|
/// A lock's state (cloud/lock.ts `LockState`), what the mesh reads of it; `ref_` the keeper's own of it, given back to
/// the rules with it.
pub(all) struct LockState {
  ref_ : Json
  seq : Int
  head : String
  genesis : String
  moved : String?
  devices : Map[String, LockDevice]
  /// Each member's role.
  members : Map[String, String]
  /// The stations it names, by key.
  stations : Array[String]
  /// The person log each member bound themselves to: its genesis.
  persons : Map[String, String]
}

///|
/// `Cloud.locked`/`Cloud.list`: the state in force (None: broken) and whether the station waits for what makes it.
pub(all) struct Locked {
  state : LockState?
  waiting : Bool
}

///|
/// Who a connection is, as the lock's rules are asked of it.
pub(all) struct Who {
  sub : String
  endpoint : String
  base : String?
  proof : String?
}

///|
/// A refusal by the lock (the client asks to be confirmed), not a bad credential.
pub(all) suberror LockRefusal {
  LockRefusal(String)
}

///|
/// What `keep_lock` did: how many taken, why each other was not (`off`), the rules' refusal.
pub(all) struct Kept {
  taken : Int
  off : Array[Json]
  refusal : String?
}

///|
/// What `take_chain`'s keeping says (person-chains.ts `take`): taken, the chain gone by, whether what was brought is on
/// it, why each off.
pub(all) struct ChainTaken {
  taken : Int
  chain : Array[Json]
  on : Bool
  off : Array[Json]
}

///|
/// The builds above which a core is too old for a moved workspace, and the oldest one answered (api/oldest.ts,
/// api/moved-from.ts).
pub(all) struct Floors {
  oldest_core : Int
  counted_from : Int
  moved_from : Int
  root_out_from : Int
  logs_before : Int
  logs_any_from : Int
}

///|
/// Words the station says (cloud/state.ts, person-chains.ts).
pub let fork_words : String = "the entry disagrees with this station's lock (a fork)"

///|
pub let not_given : String = "this station has not yet been given this workspace's settings by a trusted device: connect from a device of the workspace's owner, or wait for another of its stations to bring them"

///|
pub let at_odds : String = "this device brought a lock at odds with the one its person has here"

///|
pub(all) struct Keeper {
  /// Unix seconds now (credentials' and the lock's times are the machine's).
  now_secs : () -> Int64
  floors : Floors
  verify : Verify
  /// Told on every change of the cloud's state (what it gives calls it off).
  listen : (() -> Unit) -> () -> Unit
  /// Told on every change of the person logs kept.
  persons_listen : (() -> Unit) -> () -> Unit
  // The cloud's state.
  home : async () -> String?
  removed : async () -> Bool
  station : async () -> String
  /// This station's name as the control plane lists it (`state.name`), and in a workspace (`membership(ws).name`).
  name : async () -> String
  membership : async (String) -> (String, Array[Revocation])?
  memberships : async () -> Array[Membership]
  grant_keys : async (String?) -> Json
  /// The keys the control plane's state says (`state.grant_keys`) and a joined workspace's revocations.
  state_grant_keys : async () -> Json
  joined_revocations : async (String) -> Array[Revocation]
  accepted : async () -> Accepted
  /// Why a joined workspace's members are left out for a lock (`pending`, `unpinned`, `home`), None: they are not.
  left_out : async (String) -> String?
  // The locks.
  chain : async (String?) -> (Bool, LockState?)
  locked : async (String?) -> Locked?
  list : async (String?) -> Locked?
  root_out : async (String?) -> Bool
  needs : async (String?) -> Int
  take_lock : async (Array[Json], String?) -> Int
  keep_lock : async (Array[Json], String?, Bool) -> Kept
  lock_after : async (Int, String?) -> Array[Json]
  take_bodies : async (String?, Array[Json]) -> (Int, Array[Json])
  bodies : async (String?) -> Array[(String, Json)]
  lacking : async (String?) -> Json
  logs_of : async (String?) -> Array[String]
  /// The bodies' hashes `key` is given in `ws`, None: all.
  given_to : async (String?, String) -> Array[String]?
  pin_brought : async (String?, String, Array[Json], Json, Json, Who, String) -> Unit
  // The person logs kept.
  person_of : async (String) -> Array[(String, Array[Json])]
  person_kept : async (String) -> Array[Json]?
  person_chosen : async (String, String, Array[Json]) -> Array[Json]
  person_keep : async (String, Array[Json], String) -> Unit
  person_take : async (String, String, Array[Json], String?, Bool) -> ChainTaken
  person_every : async () -> Array[(String, Array[Json])]
  persons_written : async () -> Unit
  // The rules.
  admit : async (LockState, Who, Int64) -> (LockDevice, String)
  admit_person : async (LockState, Who, Array[Json]) -> (String, String)
  person_fold : async (Array[Json], String?) -> (String, Array[String])
  fold : async (Array[Json], Int64?) -> LockState
  endpoint_proof : async (String, String, String, String) -> Bool
  as_entry : async (Json) -> Json?
  hash_of : async (Json) -> String
  /// The person log a chain is checked as (person-sync.ts `checkChain`): its genesis and the chain, or why not.
  check_chain : async (Json, String?) -> (String, Array[Json])
  // What the stations keep each other level in.
  lock_kept : async (String?) -> Array[Json]
  /// A lock turned off here: what was kept of it (its entries, those aside).
  lock_off : async (String?) -> (Array[Json], Array[Json])?
  person_heard_in : async (String) -> Array[(String, Array[Json])]
  person_all : async (String) -> Array[Json]
  person_aside_of : async (String) -> Int
  force_word : async (String?) -> String
  // The roster (the control plane's, as safe mode leaves it).
  peers_current : async () -> Bool
  has_state : async () -> Bool
  is_rig : async () -> Bool
  is_rig_in : async (String) -> Bool
  /// A workspace this station is in, as the roster says it (`{workspace, name, home, peers, revocations}`), None: none.
  member_of : async (String) -> Json?
  members_all : async () -> Array[Json]
  /// The joined workspaces as the state says them (`{workspace, peers}`).
  joined : async () -> Array[Json]
  unprotected : async (String) -> Array[Json]
  rig_of : async (String, String?) -> Json?
  rigs : async (String) -> Array[Json]
  rigs_named : async (String) -> Array[Json]
  rig_vouched : async (String, Json) -> Bool
  moved_offered : async (String) -> Bool
  waiting : async (String?) -> Bool
  answer_ways : async (Json, String) -> Json
  answer_marks : async (Json, String) -> Json
  /// A joined workspace's moved chain pinned once a station of it gives what names this one (moved-pin.ts `pinMoved`):
  /// whether it was.
  pin_moved : async (PeerCall, String, Array[String], String) -> Bool
  // What else a device reads here.
  builds_saw : async (String, Int?, Int64) -> Unit
  builds_of : async (Array[String]) -> Json
  seen : SeenDevices
  ways_view : async (String) -> Json
  ways_set_relays : async (String, Json, String?) -> Json
  ways_set_way : async (String, String, Bool) -> Json
  marks_of : async (String) -> Json
  marks_change : async (Json, Json) -> Json
}

///|
/// A request to another station of the workspace: its answer's JSON and the bytes after it, if any (bus.ts `PeerCall`;
/// station "" with method `peers` is the transport's roster).
pub type PeerCall = async (String, String?, Json, Body?) -> (Json, Body?)

///|
/// Bytes after a request's or an answer's head (bus.ts `BYTES`): the next piece, None at their end; `stop` lets go
/// of the rest (TS's `return`); `check`, made before each piece is written (bus.ts `CHECK_BYTES`).
pub(all) struct Body {
  next : async () -> Bytes?
  stop : async () -> Unit
  check : (() -> Unit raise)?
}

///|
/// The roles, lowest first.
pub let roles : Array[String] = ["viewer", "member", "admin", "owner"]

///|
/// The lower of two roles: the control plane may take rights away, never give them (an unknown role is the lowest).
pub fn lower_role(a : String, b : String) -> String {
  let rank = (r : String) => roles.search(r).unwrap_or(-1)
  let lo = if rank(a) < rank(b) { rank(a) } else { rank(b) }
  roles[if lo < 0 { 0 } else { lo }]
}

///|
fn init {
  @door.add_words(e => match e {
    LockRefusal(m) | Refused(m) | WaysRefusal(m) | MarkRefusal(m) | PeerRefused(m) | NoLink(m) | NoBytes(m) => Some(m)
    PeerGone(m, _) => Some(m)
    HttpRefusal(_, m, _) | DeviceRefused(_, m) => Some(m)
    _ => None
  })
}
