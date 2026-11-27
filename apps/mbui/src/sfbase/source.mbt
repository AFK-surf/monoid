// Where the app's pages read and write: the still.fail core (src/stillfail, over mbui/core) or a fixture of made-up
// chats (fixture.mbt: no core, the same views' shapes), for screenshots that are the same on every run.

///|
/// A topic as it stands: its value, or why it could not be read; `version` counts its changes.
pub(all) struct Topic {
  value : Json?
  error : Json?
  version : Int
}

///|
/// The same topic as it stood: what derive(Eq) says, its version looked at first and its value last, the one JSON or
/// equal (a value set again is mostly the one it was).
pub impl Eq for Topic with equal(a, b) {
  a.version == b.version && a.error == b.error && @signals.same_value(a.value, b.value)
}

///|
/// A topic as a value a signal can carry, including whether its first value waits on a station.
pub(all) struct TopicState {
  value : Json?
  error : Json?
  version : Int
  waiting : Bool
}

///|
/// As Topic's, and whether it waits.
pub impl Eq for TopicState with equal(a, b) {
  a.version == b.version && a.waiting == b.waiting && a.error == b.error && @signals.same_value(a.value, b.value)
}

///|
/// The fields used by older page code after reading a topic signal.
pub fn TopicState::snapshot(self : TopicState) -> Topic {
  { value: self.value, error: self.error, version: self.version }
}

///|
/// Whether the value is what the core last said before it was let go of (`lasting`, shown again at once while its
/// answer comes), not its answer now: its version is below every core's (LastSaid).
pub fn TopicState::kept(self : TopicState) -> Bool {
  self.version < -1
}

///|
/// A legacy topic read leaves by name; an owned read releases only the supplied, independently owned reader.
pub(all) enum TopicLeave {
  Legacy
  Owned(() -> Unit)
}

///|
/// How a source read is owned. A lease may explicitly move to another view after it is created.
#derive(Eq)
pub(all) enum TopicReadMode {
  Raw
  Graph
  Lease
}

///|
/// Where signing in to still.fail stands, as the sign-in page says it: nothing under way; its page being opened; out in
/// the browser, the app waiting for it to come back; what it brought back being checked; or failed, why in the person's
/// words ("" when there are none).
#derive(Eq, Debug)
pub(all) enum SignInStep {
  Idle
  Opening
  InBrowser
  Verifying
  Failed(String)
}

///|
/// The step a sign-in's state says (sfcore's SignIn: `failed` "" when it did not fail, "!" when it did with no words).
pub fn SignInStep::of(busy~ : Bool, verifying~ : Bool, waiting~ : Bool, failed~ : String) -> SignInStep {
  if verifying {
    Verifying
  } else if busy {
    Opening
  } else if waiting {
    InBrowser
  } else if failed != "" {
    Failed(if failed == "!" { "" } else { failed })
  } else {
    Idle
  }
}

///|
pub(all) struct Source {
  /// The low-level topic reader used to build `topic`. Use `prefetch` for an independent early read.
  topic_read : (String, Map[String, Json]) -> Topic
  /// This source's subscription identity, after any parameter normalization; equal keys share a subscription.
  topic_key : (String, Map[String, Json]) -> String
  /// A topic's keyed list (the field of its value the core keys by `keys`: a chat's `messages` by `seq` and
  /// `outgoing`), kept by key as the core changes it item by item (@core.Sub::keyed): what reads an item told only as
  /// it changes. None where the source keeps none (a made-up core that gives values whole) or the topic is not held:
  /// its reader works it out of the value as before. Of the subscription `topic` reads, acquiring none (what reads it
  /// reads the topic, which holds it).
  topic_keyed : (String, Map[String, Json], String, Array[String]) -> @signals.KeyedList[String, Json]?
  /// A view source distinguishes graph evaluation from an independent read.
  topic_scope : ((TopicReadMode, () -> TopicState) -> TopicState)?
  /// Whether the source can still create a reader (a view-owned source ends with its view).
  topic_alive : () -> Bool
  /// Attach a new lease to all views which currently own this source; returns a cleanup deregistration.
  topic_lease_own : ((() -> Unit) -> () -> Unit)?
  /// whether the core said that topic, which has no value yet, waits on a station for it: none of what it shows is on
  /// the device (a chat whose messages are still to come), not the core still reading what is. Read as `topic` is.
  waits : (String, Map[String, Json]) -> Bool
  /// The core's lifetime and whether a retained topic value came from it; does not acquire the topic.
  generation : (String, Map[String, Json]) -> (Int, Bool)
  /// a call to the core; `done` gets its answer or its error, or is `answer_unread`: nobody reads it
  call : (String, Json, (Result[Json, Json]) -> Unit) -> Unit
  /// a call with bytes beside it (a file's part going up: `station.upload.part`)
  call_bytes : (String, Json, Bytes, (Result[Json, Json]) -> Unit) -> Unit
  /// a call whose answer has bytes beside it (a part of a drive's file: `drive.read`)
  read_bytes : (String, Json, (Result[(Json, Bytes), Json]) -> Unit) -> Unit
  /// a call whose answer has bytes beside it and that says how far it has got before it (`station.file` with
  /// `progress`: `{loaded, total}` each time, then the file): `on_value` each time, then `done`
  read_going : (String, Json, (Json) -> Unit, (Result[(Json, Bytes), Json]) -> Unit) -> Unit
  /// a call that says how it goes before its answer (`station.preview` with `stream`: the answer's head, then each
  /// piece of its body with its bytes): `on_value(value, bytes)` each time, then `done`; the call's id, for `cancel`
  stream : (String, Json, Bytes?, (Json, Bytes?) -> Unit, (Result[Json, Json]) -> Unit) -> Int
  /// a streamed call stopped (nothing more of it comes)
  cancel : (Int) -> Unit
  /// 登录 pressed
  sign_in : () -> Unit
  /// whether a sign-in is under way
  signing_in : () -> Bool
  /// where signing in stands: what the sign-in page's button and the line under it say
  sign_in_step : () -> SignInStep
  /// a picture by its URL (a person's, a station's icon) as it is put up on its page's time on top `stint`
  /// (Ctx::page_stint): an image's src once it is here, "" until then (the core's `picture`: core_pictures.mbt)
  picture : (String, Int) -> String
  /// whether a page opening waits for the picture at a URL (sfbase's pictures_in): one the device holds, asked of the
  /// core as it holds it by this if it was not, while the core reads it or it is not decoded yet. False of one the device
  /// has not (the network's to bring), one that could not be had, and where pages wait for no picture
  /// (core_pictures.mbt's `waits`)
  picture_waits : (String) -> Bool
  /// what the core said when it stopped, if it did
  fatal : () -> String?
  /// a file of a chat as its messages show it (`station.file`, an image's thumbnail): by its station, the session
  /// that keeps it and its name; an image's key once it is here, "" while it comes, "!" when it could not be had
  file : (String, String, String) -> String
  /// a video of a chat's still as the station makes it (`station.poster`: its first frame, a small JPEG), by the same
  /// three; an image's key once it is here, "" while it comes, "!" when the station has none
  poster : (String, String, String) -> String
  /// a picture of a draft's file the page holds no bytes of (a draft kept, read again as the app starts:
  /// `composer.picture`), by the draft's key and the file's id: an image's key once here, "" while it comes, "!" when
  /// the device keeps none
  draft_picture : (String, String) -> String
  /// what became of those pictures, each by its id (file_image_id, poster_image_id): which failed for want of their
  /// station, to be asked again (chat_images.mbt)
  images : ChatImages
  /// the time of day, in milliseconds since 1970 (how long an agent's turn has run)
  now : () -> Double
  /// a topic no page shows any more (`unsubscribe`)
  leave : (String, Map[String, Json], TopicLeave) -> Unit
  /// a signal reader ended; another graph reader or a legacy untracked hold may still need the topic
  release : (String, Map[String, Json]) -> Unit
  /// ask an already held topic for a fresh value without dropping its readers
  refresh : (String, Map[String, Json]) -> Unit
  /// nothing the reader does is told to the core (MBUI_READONLY=1): no read marks, no place kept, nothing sent, no
  /// draft kept, no file put up
  read_only : Bool
  /// whether what the places open on is kept as last said (`lasting`) and asked ahead of them (places_ahead): not of
  /// a run seen again that was recorded before the app did, whose core is asked only what the run asked
  reads_ahead : () -> Bool
  /// whether the stations' places and pages ask for the workspace's devices (`devices`): not of a run seen again that
  /// was recorded before the app did
  asks_devices : () -> Bool
  /// whether an open chat's page asks for its outline (`chatOutline`: its rail of ticks, its outline's panel): not of a
  /// run seen again that was recorded before the app did
  asks_outline : () -> Bool
  /// whether a choice that switches what its page reads asks ahead of the switch what it will read, the switch made as
  /// that is answered (switch_answered): not of a run seen again that was recorded before the app did, whose choice
  /// switched at the press and asked as the page then read
  switches_ahead : () -> Bool
  /// whether the stations' newer releases waiting for this person are asked for (`stationUpdates`: their key beside
  /// the app's update, sfpages station_updates.mbt): not of a run seen again that was recorded before the app did
  asks_station_updates : () -> Bool
  /// whether a station's page asks what of it moves (`stationMove`: its 迁移 row while a move runs, something is
  /// stopped or a turn failed, sfpages station_node.mbt): not of a run seen again that was recorded before the app did
  asks_station_move : () -> Bool
  /// whether a station's settings page asks for its workspace memberships (`memberships`: sfpages station_node.mbt):
  /// not of a run seen again that was recorded before the app did
  asks_station_workspaces : () -> Bool
  /// whether a station's terminals are asked for (`terminals`, among its screens: sfpages station_terminals_node.mbt):
  /// not of a run seen again that was recorded before the app did
  asks_terminals : () -> Bool
  /// Whether the usage page asks for the workspace's live output rates (not in older recorded runs).
  asks_agent_rates : () -> Bool
  /// whether a page's, a panel's or a card's own view reads what makes it whole at once (a chat's services' pop its
  /// bar's summary till its own comes, an agent's card what its model's menu lists, asked ahead): not of a run seen
  /// again that was recorded before the app did (MBUI_SWR_VIEWS)
  swr_views : () -> Bool
  /// whether a card, a panel or a sheet opened the first time waits for what it reads of the device before it comes in, and
  /// a page opened by a press for what it shows (@sf.OpenGate: as made, Source::topic; route_open_asks): not of a run seen
  /// again that was recorded before the app did (MBUI_OPEN_WHOLE), nor of a fixture, whose tests say what a page shows
  /// before the core answers
  gates_opens : () -> Bool
}

///|
/// A read-only signal of one core subscription. Readers of the same source, name and params share its subscription;
/// the graph releases it when the last reader leaves. An immediate-mode page holds its untracked frame read until it leaves.
pub fn Source::topic(src : Source, name : String, params : Map[String, Json]) -> @signals.Computed[TopicState] {
  src.topic_said(name, params, topic_key(name, params))
}

///|
/// Source::topic, its key (topic_key) worked out already: what reads a topic by its key too (Derived) writes it once.
fn Source::topic_said(
  src : Source,
  name : String,
  params : Map[String, Json],
  said : String,
) -> @signals.Computed[TopicState] {
  let collecting = @view.hold_collecting() && (src.gates_opens)()
  let sig = topic_read_by(src, name, params, said)
  if collecting {
    @view.hold_note(fn() { topic_told(sig.get()) })
  }
  sig
}

///|
/// Whether what the core said of a topic lets what waits for it go on (@sf.OpenGate, a page opened by a press): its
/// value or why not, or that it waits on a station for it (what shows that it waits, at once, never held for a station).
pub fn topic_told(st : TopicState) -> Bool {
  st.value is Some(_) || st.error is Some(_) || st.waiting
}

///|
/// Picture `key` (an image's key, "" none) put up as what a card, a panel or a sheet holds is made: waited for by it where
/// the device holds it not decoded yet (@sf.OpenGate), as a source that gates opens (gates_opens) has its pictures.
pub fn picture_gated(key : String) -> Unit {
  @sf.open_gate_picture(key)
}

///|
/// Source::topic's, its key `said`.
fn topic_read_by(src : Source, name : String, params : Map[String, Json], said : String) -> @signals.Computed[TopicState] {
  // (read by what follows it, as a binding or a computed reads it again at each of its evaluations: the same signal as
  // the last such read of it, so the reader's link to it is the one it had (no signal made, followed and let go of
  // again each time). One read outside any reader, which may keep it and let it go itself, is a signal of its own.)
  if @signals.active_sub() is Some(_) {
    match topic_readers.get(said) {
      Some(readers) =>
        match readers.search_by(fn(r) { physical_equal(r.0, src) }) {
          Some(i) => return readers[i].1
          None => ()
        }
      None => ()
    }
    let made = topic_signal(src, name, params, said)
    match topic_readers.get(said) {
      Some(readers) => readers.push((src, made))
      None => topic_readers[said] = [(src, made)]
    }
    return made
  }
  topic_signal(src, name, params, said)
}

///|
// kept across runs: each made of the source it is kept with, let go of as that source's topic is (topic_readers_drop)
/// The signal of each topic Source::topic made for what follows it, by its key (topic_key) and source.
let topic_readers : Map[String, Array[(Source, @signals.Computed[TopicState])]] = Map([])

///|
/// Topic `said` of `src` let go of: the signal Source::topic kept for it with it, so one made anew follows the next.
fn topic_readers_drop(src : Source, said : String) -> Unit {
  match topic_readers.get(said) {
    Some(readers) => {
      let left = readers.filter(fn(r) { !physical_equal(r.0, src) })
      if left.is_empty() {
        topic_readers.remove(said)
      } else {
        topic_readers[said] = left
      }
    }
    None => ()
  }
}

///|
/// Topic `name` with `params` (its key `said`) of `src` as a signal (Source::topic's).
fn topic_signal(src : Source, name : String, params : Map[String, Json], said : String) -> @signals.Computed[TopicState] {
  let key = params.copy()
  @signals.computed_scoped(fn(_) {
    followed_topic(src, name, key, said~).get()
  }, untracked_read=Some(fn() {
    if !held_building.val && src.topic_scope is None {
      return None
    }
    // A Raw read on a parked view source must never bypass the parked guard via a watched Graph holder.
    if src.topic_scope is Some(_) && !held_building.val && source_parked_raw_blocked(src, name) {
      return Some({ value: None, error: None, version: 0, waiting: false })
    }
    // An event in a build can read a topic the graph already holds. Use that value without adding a manual hold. So
    // can an event of a view's (a press on what its page shows, outside any build) through that view's source: as it
    // is then, held no longer than the graph holds it, not for as long as the view lives (Source::owned_by's raw read).
    if src.topic_scope is None || !held_building.val {
      match existing_followed_topic(src, name, key, said~) {
        Some(holder) if holder.watched() => return Some(holder.get())
        _ => ()
      }
    }
    Some(match src.topic_scope {
      Some(scope) => scope(Raw, fn() { read_topic_state(src, name, key) })
      None => read_topic_state(src, name, key)
    })
  }))
}

///|
/// Read ahead independently of any current graph. A view source holds this read until it leaves or its view ends.
pub fn Source::prefetch(src : Source, name : String, params : Map[String, Json]) -> Topic {
  @signals.untracked(fn() {
    let read = fn() {
      let topic = (src.topic_read)(name, params)
      { value: topic.value, error: topic.error, version: topic.version, waiting: false }
    }
    let state = match src.topic_scope {
      Some(scope) => scope(Raw, read)
      None => read()
    }
    state.snapshot()
  })
}

///|
fn read_topic_state(src : Source, name : String, params : Map[String, Json]) -> TopicState {
  let topic = (src.topic_read)(name, params)
  let waiting = (src.waits)(name, params)
  // (the accounts said anew, one signed in or out: nothing kept of what another's showed)
  if name == "accounts" && src.topic_scope is None && topic.value is Some(now) {
    if last_accounts.val != Some(now) {
      last_accounts.val = Some(now)
      last_said.val = last_said.val.filter(fn(l) { !physical_equal(l.source, src) })
    }
  }
  // (a view's own source reads through the one it is of, which keeps them: topic_scope none)
  if src.topic_scope is None && !topic_policy_sensitive(name, Json::object(params)) && topic_policy_lasting(name, Json::object(params)) && (src.reads_ahead)() {
    let key = topic_key(name, params)
    match (topic.value, topic.error) {
      (Some(value), _) => last_put(src, name, params, key, value)
      (None, None) =>
        match last_said.val.search_by(fn(l) { physical_equal(l.source, src) && l.key == key }) {
          Some(i) => {
            let l = last_said.val[i]
            return { value: Some(l.value), error: None, version: l.version, waiting: false }
          }
          None => ()
        }
      _ => ()
    }
  }
  { value: topic.value, error: topic.error, version: topic.version, waiting }
}

///|
// kept across runs: a value (nothing of it changes)
let empty_topic_params : Json = Json::object({})

///|
/// Whether topic `name` is one of Home's own `lasting` lists (`MBUI_HOME_SAME`), delegated to
/// `topic_policy_gen.mbt` (generated from `client/core-ts/src/topic-policy.ts`).
pub fn home_lasting_of(name : String) -> Bool {
  topic_policy_home_lasting(name, empty_topic_params)
}

///|
/// How many values of topic `name` asked with `params` (its JSON as the core is asked it, its name in it too) the
/// core's client keeps as they are let go of, to ask them again with their version (@core.Client::keep: the core
/// answers `same` where one has not changed, what changed from it where it has); 0, none.
pub fn topic_kept(name : String, params : Json) -> Int {
  topic_kept_by(name, params, true)
}

///|
/// topic_kept, with the views' own (`views_kept`, a chat's last 8) where `views` (MBUI_SWR_VIEWS): a replay of a run
/// from before it keeps what that run's app did.
pub fn topic_kept_by(name : String, params : Json, views : Bool) -> Int {
  topic_policy_keep(name, params, views)
}

///|
/// Whether topic `name`'s value kept is shown at once as it is asked again, before the core answers
/// (@core.Client::show_kept): a view's own (`views_kept`). Not a chat's (its page places its rows by its first value),
/// nor the lists the places open on (`lasting`: shown again by the source that read them, last_said, never to what names
/// a station by them, station_marks).
pub fn topic_shown_kept(name : String) -> Bool {
  topic_policy_show_kept(name, empty_topic_params, true)
}

///|
/// Parameter-aware `topic_shown_kept` (handles `byParam` topics such as `stationPart` and unconditional `sensitive` ceiling).
pub fn topic_shown_kept_params(name : String, params : Json) -> Bool {
  topic_policy_show_kept(name, params, true)
}

///|
fn sanitize_profile_item_json(item : Json) -> Json {
  match item {
    Object(obj) => {
      let has_login = obj.contains("login")
      let has_nested_login = match obj.get("profile") {
        Some(Object(p)) => p.contains("login")
        _ => false
      }
      if !has_login && !has_nested_login {
        return item
      }
      let out : Map[String, Json] = Map([])
      for k, v in obj {
        if k == "login" {
          continue
        }
        if k == "profile" && has_nested_login {
          match v {
            Object(p) => {
              let clean_p : Map[String, Json] = Map([])
              for pk, pv in p {
                if pk != "login" {
                  clean_p[pk] = pv
                }
              }
              out[k] = Json::object(clean_p)
            }
            _ => out[k] = v
          }
        } else {
          out[k] = v
        }
      }
      Json::object(out)
    }
    _ => item
  }
}

///|
fn sanitize_profile_array_json(arr : Json) -> (Bool, Json) {
  match arr {
    Array(items) => {
      let mut changed = false
      let out : Array[Json] = []
      for item in items {
        let clean = sanitize_profile_item_json(item)
        if !physical_equal(clean, item) {
          changed = true
        }
        out.push(clean)
      }
      if changed { (true, Json::array(out)) } else { (false, arr) }
    }
    _ => (false, arr)
  }
}

///|
/// Strips sensitive / privilege / active-login fields (`machineLogins`, `logins`, `manages`,
/// `profiles[].login`, `overview.profiles[].login`) from kept values of aggregate topics
/// (`profiles`, `station`, `stationPart(part="profiles")`) before storing in `Client::kept` or `last_said`,
/// so cached values and first-frame SWR contain zero sensitive fields while fresh answers remain intact.
pub fn sanitize_kept_json(name : String, value : Json) -> Json {
  match (name, value) {
    ("stationPart", Array(_)) => sanitize_profile_array_json(value).1
    ("profiles", Object(obj)) => {
      let has_top = obj.contains("machineLogins") || obj.contains("manages")
      let (items_changed, clean_items) = match obj.get("items") {
        Some(a) => sanitize_profile_array_json(a)
        None => (false, Json::null())
      }
      let (profiles_changed, clean_profiles) = match obj.get("profiles") {
        Some(a) => sanitize_profile_array_json(a)
        None => (false, Json::null())
      }
      if !has_top && !items_changed && !profiles_changed {
        return value
      }
      let out : Map[String, Json] = Map([])
      for k, v in obj {
        if k == "machineLogins" || k == "manages" {
          continue
        }
        if k == "items" && items_changed {
          out[k] = clean_items
        } else if k == "profiles" && profiles_changed {
          out[k] = clean_profiles
        } else {
          out[k] = v
        }
      }
      Json::object(out)
    }
    ("station", Object(obj)) => {
      let has_top = obj.contains("machineLogins") || obj.contains("manages")
      let (ov_profiles_changed, clean_ov_profiles) = match obj.get("overview") {
        Some(Object(ov)) =>
          match ov.get("profiles") {
            Some(a) => sanitize_profile_array_json(a)
            None => (false, Json::null())
          }
        _ => (false, Json::null())
      }
      let has_ov = match obj.get("overview") {
        Some(Object(ov)) => ov.contains("machineLogins") || ov.contains("logins") || ov_profiles_changed
        _ => false
      }
      if !has_top && !has_ov {
        return value
      }
      let out : Map[String, Json] = Map([])
      for k, v in obj {
        if k == "machineLogins" || k == "manages" {
          continue
        }
        if k == "overview" && has_ov {
          match v {
            Object(ov) => {
              let clean_ov : Map[String, Json] = Map([])
              for ok, ov_v in ov {
                if ok == "machineLogins" || ok == "logins" {
                  continue
                }
                if ok == "profiles" && ov_profiles_changed {
                  clean_ov[ok] = clean_ov_profiles
                } else {
                  clean_ov[ok] = ov_v
                }
              }
              out[k] = Json::object(clean_ov)
            }
            _ => out[k] = v
          }
        } else {
          out[k] = v
        }
      }
      Json::object(out)
    }
    _ => value
  }
}

///|
/// How many values the core's client keeps of every name together (@core.Client::keep's `most`): as many as the core
/// remembers for it (client/core-ts topic-policy.ts KEPT_PER_CLIENT) where `views` (MBUI_SWR_VIEWS), its 64 of before else.
pub fn kept_most_by(views : Bool) -> Int {
  if views { topic_policy_kept_per_client } else { topic_policy_kept_most_before }
}

///|
/// What a source last said of a lasting topic. `version` is below every core's (those count up from 0), another for
/// each value kept: what is worked out of a topic by its version never takes this for the answer that follows it.
priv struct LastSaid {
  source : Source
  name : String
  params : Map[String, Json]
  key : String
  value : Json
  version : Int
}

///|
/// The newest last (last_most of them: a list asked for many ways, the oldest forgotten).
// kept across runs: put back as a run begins (reset)
let last_said : Ref[Array[LastSaid]] = Ref([])

///|
/// Live count and serialized UTF-8 byte size of the client's lasting lists `last_said` cache
/// (places SWR lists only; parked pages release their own topic holds via `rest(drop_holds=true)` and are not in this cache).
pub fn last_said_stats() -> (Int, Int) {
  let mut bytes = 0
  for entry in last_said.val {
    let s = entry.value.stringify()
    for ch in s {
      let cp = ch.to_int()
      if cp <= 0x7F {
        bytes += 1
      } else if cp <= 0x7FF {
        bytes += 2
      } else if cp <= 0xFFFF {
        bytes += 3
      } else {
        bytes += 4
      }
    }
  }
  (last_said.val.length(), bytes)
}

///|
let chats_kept : Int = topic_policy_keep("chat", empty_topic_params, true)

///|
let last_most : Int = topic_policy_last_most

///|
// kept across runs: only counted on
let last_count : Ref[Int] = Ref(0)

///|
fn last_put(src : Source, name : String, params : Map[String, Json], key : String, value : Json) -> Unit {
  let clean = sanitize_kept_json(name, value)
  let at = last_said.val.search_by(fn(l) { physical_equal(l.source, src) && l.key == key })
  match at {
    Some(i) if physical_equal(last_said.val[i].value, clean) => return
    _ => ()
  }
  last_count.val += 1
  let kept = last_said.val.filter(fn(l) { !(physical_equal(l.source, src) && l.key == key) })
  kept.push({ source: src, name, params: params.copy(), key, value: clean, version: -2 - last_count.val })
  last_said.val = if kept.length() > last_most { kept[kept.length() - last_most:].to_owned() } else { kept }
}

///|
/// Local synchronous vault-lock masking hook installed by the app host (`@core.client.mask_scope(VaultAll)`),
/// invoked by `sfpages/vault.mbt` on the lock button press before next paint/input.
// kept across runs: installed once by the app host as it starts
pub let mask_vault_all : Ref[() -> () -> Unit] = Ref(fn() { fn() {  } })

///|
/// Local synchronous global-scope masking hook installed by the app host (`@core.client.mask_scope(Global)`),
/// invoked by `sfpages/account.mbt` when the user confirms sign-out or account deletion.
/// Returns an undo closure that restores subscriptions if the control call fails.
// kept across runs: installed once by the app host as it starts
pub let mask_global : Ref[() -> () -> Unit] = Ref(fn() { fn() {  } })

///|
/// Clears transient vault secrets held in page memory (such as `recovery_words` in `sfpages/vault.mbt`)
/// when an auth/vault boundary fires. Wired by `sfpages/vault.mbt`.
// kept across runs: installed once by sfpages/vault.mbt init
pub let clear_vault_secrets : Ref[(String, String) -> Unit] = Ref(fn(_, _) {  })

///|
/// Synchronously invalidates `last_said`, active `Graph` and transferable `Lease` followers, and derived `Kept` caches
/// belonging to `src` for every topic matched by `matches` (leaves unrelated workspaces and unaffected vaults intact).
pub fn invalidate_auth_scope(src : Source, matches : (String, Map[String, Json]) -> Bool) -> Unit {
  last_said.val = last_said.val.filter(fn(l) {
    !(physical_equal(l.source, src) && matches(l.name, l.params))
  })
  let gone = followed_topics.val.filter(fn(t) { physical_equal(t.source, src) && matches(t.name, t.params) })
  if !gone.is_empty() {
    followed_topics.val = followed_topics.val.filter(fn(t) {
      !(physical_equal(t.source, src) && matches(t.name, t.params))
    })
    for t in gone {
      if !t.independent {
        topic_readers_drop(src, t.key)
      }
      t.holder.dispose()
    }
  }
  kept_forget_matching(src, fn(key) {
    match key.find("\u{1}") {
      Some(i) => {
        let name = key[:i].to_owned()
        let raw = key[i + 1:].to_owned()
        let parsed = @json.parse(raw) catch { _ => Json::object({}) }
        let params = match parsed {
          Object(m) => m
          _ => Map([])
        }
        matches(name, params)
      }
      None => matches(key, Map([]))
    }
  })
}

///|
/// The accounts as last said (read_topic_state).
// kept across runs: put back as a run begins (reset)
let last_accounts : Ref[Json?] = Ref(None)

///|
/// Per-workspace owning account (`ws_id -> sub/email`), updated outside computed getters from `workspaces` topic.
// kept across runs: put back as a run begins (last_reset)
let workspace_owners : Map[String, String] = Map([])

///|
/// Whether at least one complete `workspaces` snapshot has been synced in this run.
// kept across runs: put back as a run begins (last_reset)
let workspace_owners_seen_snapshot : Ref[Bool] = Ref(false)

///|
/// Monotonic reactive version bumped whenever workspace ownership or active account list changes,
/// allowing `lone_tree` and standalone windows to re-evaluate ownership reactively.
// kept across runs: put back as a run begins (last_reset)
pub let workspace_owners_version : @signals.Signal[Int] = @signals.signal(0)

///|
/// Whether at least one complete `workspaces` snapshot has been synced in this run.
pub fn workspace_owners_synced() -> Bool {
  workspace_owners_seen_snapshot.val
}

///|
/// Explicit owning account of workspace `ws` without falling back to `account_principal_sig`.
/// Returns `None` if `ws` is revoked or has no explicit owner entry yet.
pub fn workspace_explicit_owner_of(ws : String) -> String? {
  if ws == "" || workspace_is_revoked(ws) {
    return None
  }
  match workspace_owners.get(ws) {
    Some(owner) if owner != "" => Some(owner)
    _ => None
  }
}

///|
/// Workspaces that disappeared from a complete `workspaces` snapshot (no signed-in account still has access).
/// Distinguished from "snapshot not yet received" so `workspace_owner_of` never falls back to `account_principal_sig`.
// kept across runs: put back as a run begins (last_reset)
let workspace_revoked : Map[String, Bool] = Map([])

///|
/// Workspaces currently pending resolution under at least one still-loading (`loaded=false`) account.
// kept across runs: put back as a run begins (last_reset)
let workspace_pending_ws : Map[String, Bool] = Map([])

///|
/// Workspaces that entered `workspace_pending_ws` specifically because a previous confirmed owner explicitly
/// lost access (or was blocked) while a candidate fallback account was still `loaded=false`. Distinguished
/// from cold-start Core unallocated pending so offline DB recovery can immediately promote `Owned(B)` while
/// explicit-loss pending stays idempotently `Pending` until B confirms with `loaded=true`.
// kept across runs: put back as a run begins (last_reset)
let workspace_pending_explicit_loss : Map[String, Bool] = Map([])

///|
/// Accounts whose latest `workspaces` snapshot entry has `loaded=false`.
// kept across runs: put back as a run begins (last_reset)
let workspace_pending_owners : Map[String, Bool] = Map([])

///|
/// Accounts whose latest `workspaces` snapshot entry has `loaded=true`.
// kept across runs: put back as a run begins (last_reset)
let workspace_loaded_owners : Map[String, Bool] = Map([])

///|
/// Per-workspace membership map recorded across all `loaded=true` accounts (even when the workspace is also
/// in `workspace_pending_ws`), distinguishing "loaded and still a member" from "loaded and lost access".
// kept across runs: put back as a run begins (last_reset)
let workspace_loaded_members : Map[String, Map[String, Bool]] = Map([])

///|
/// Whether workspace `ws` is currently pending under an unloaded account (no definitive owner confirmed yet).
pub fn workspace_is_pending(ws : String) -> Bool {
  ws != "" && workspace_pending_ws.contains(ws)
}

///|
/// Whether workspace `ws` is currently pending under an unloaded account and `expected` has not been proven
/// to have lost access (either `expected` is itself still loading, or `expected` is loaded and still lists `ws`).
/// Signed-out accounts (absent from both `workspace_pending_owners` and `workspace_loaded_members`) return `false`.
pub fn workspace_owner_pending_for(ws : String, expected : String) -> Bool {
  guard ws != "" && expected != "" && workspace_pending_ws.contains(ws) else { return false }
  if workspace_pending_owners.contains(expected) {
    return true
  }
  match workspace_loaded_members.get(ws) {
    Some(m) => m.contains(expected)
    None => false
  }
}

///|
/// Whether workspace `ws` has been revoked (disappeared from the latest complete `workspaces` snapshot).
pub fn workspace_is_revoked(ws : String) -> Bool {
  ws != "" && workspace_revoked.get(ws) == Some(true)
}

///|
/// Currently signed-in account subs (updated outside computed getters by `sfcore`'s `accounts_told`).
// kept across runs: put back as a run begins (last_reset)
let active_account_subs : Ref[Array[String]] = Ref([])

///|
/// Fallback single-account principal when a workspace owner has not been populated yet.
// kept across runs: put back as a run begins (last_reset)
pub let account_principal_sig : @signals.Signal[String] = @signals.signal("", same=fn(a, b) { a == b })

///|
/// Synchronous hooks notified when a specific account `removed_account` is signed out or replaced.
// kept across runs: registered once at package init
let account_revoke_listeners : Array[(String) -> Unit] = []

///|
/// Synchronous hooks notified when workspace `ws` changes owner from `old_owner` to `new_owner`.
// kept across runs: registered once at package init
let workspace_owner_change_listeners : Array[(String, String, String) -> Unit] = []

///|
/// Owning account of workspace `ws`: explicit owner when confirmed, `"\u{3}revoked"` when revoked or missing
/// from a complete snapshot, `"\u{3}pending"` while awaiting an unloaded higher-priority/candidate account, and
/// falling back to `account_principal_sig` only before any `workspaces` snapshot has been synced.
pub fn workspace_owner_of(ws : String) -> String {
  if ws != "" {
    if workspace_revoked.get(ws) == Some(true) {
      return "\u{3}revoked"
    }
    match workspace_owners.get(ws) {
      Some(owner) if owner != "" => return owner
      _ => ()
    }
    if workspace_pending_ws.contains(ws) {
      return "\u{3}pending"
    }
    if workspace_owners_seen_snapshot.val {
      return "\u{3}revoked"
    }
  }
  account_principal_sig.untracked()
}

///|
/// Set the owning account for workspace `ws` (outside computed getters). If `ws` previously belonged to a different
/// owner, synchronously revokes only `(ws, old_owner)` resources.
pub fn workspace_owner_set(ws : String, owner : String) -> Unit {
  guard ws != "" else { return }
  if owner != "" {
    workspace_revoked.remove(ws)
    workspace_pending_ws.remove(ws)
    workspace_pending_explicit_loss.remove(ws)
  }
  match workspace_owners.get(ws) {
    Some(prev) =>
      if prev != owner {
        workspace_owners[ws] = owner
        workspace_owners_version.set(workspace_owners_version.untracked() + 1)
        for f in workspace_owner_change_listeners {
          f(ws, prev, owner)
        }
      }
    None => {
      workspace_owners[ws] = owner
      workspace_owners_version.set(workspace_owners_version.untracked() + 1)
      let fallback = account_principal_sig.untracked()
      if fallback != "" && fallback != owner {
        for f in workspace_owner_change_listeners {
          f(ws, fallback, owner)
        }
      }
    }
  }
}

///|
/// Sync per-workspace account ownership from a complete `workspaces` topic payload (called from reactive effects,
/// never inside a computed getter). Workspaces that disappeared from all signed-in accounts are marked revoked and
/// synchronously stripped of their previous owner's resources without falling back to the first signed-in account.
pub fn workspace_owners_sync_json(v : Json?) -> Unit {
  guard v is Some(Array(accounts)) else { return }
  let seen : Map[String, String] = Map([])
  let present_owners : Map[String, Bool] = Map([])
  let pending_owners : Map[String, Bool] = Map([])
  let pending_ws : Map[String, Bool] = Map([])
  let loaded_owners : Map[String, Bool] = Map([])
  let loaded_members : Map[String, Map[String, Bool]] = Map([])
  let next_explicit_loss : Map[String, Bool] = Map([])
  let core_owned : Map[String, (String, Bool)] = Map([])
  let listed_ws : Map[String, Bool] = Map([])
  let mut has_core_owned = false
  for a in accounts {
    if field(Some(a), "ownedWorkspaces") is Some(Array(_)) {
      has_core_owned = true
      break
    }
  }
  // Pass 1: collect all present/loaded/pending accounts and Core-declared ownership without making ownership decisions,
  // eliminating any sensitivity to account ordering ([A, B] vs [B, A]).
  for a in accounts {
    let s = Some(a)
    let acc = field(s, "account")
    let sub = text(acc, "sub")
    let owner = if sub != "" { sub } else { text(acc, "email") }
    if owner == "" {
      continue
    }
    present_owners[owner] = true
    let is_blocked = match field(s, "blocked") {
      Some(String(b)) => b != ""
      Some(True) => true
      _ => false
    }
    if is_blocked {
      loaded_owners[owner] = true
      continue
    }
    let acc_loaded = match field(s, "loaded") {
      Some(False) => false
      _ => true
    }
    let ws_list = items(s, "workspaces")
    if !acc_loaded {
      pending_owners[owner] = true
    } else {
      loaded_owners[owner] = true
      for w in ws_list {
        let id = text(Some(w), "id")
        if id != "" {
          match loaded_members.get(id) {
            Some(m) => m[owner] = true
            None => {
              let m : Map[String, Bool] = Map([])
              m[owner] = true
              loaded_members[id] = m
            }
          }
        }
      }
    }
    if has_core_owned {
      for ow in items(s, "ownedWorkspaces") {
        guard ow is String(id) && id != "" else { continue }
        if !core_owned.contains(id) {
          core_owned[id] = (owner, acc_loaded)
        }
      }
      for w in ws_list {
        let id = text(Some(w), "id")
        if id != "" {
          listed_ws[id] = true
        }
      }
    }
  }
  // Pass 2: decide Owned / Pending / Revoked with complete present_owners, loaded_owners & loaded_members sets.
  let is_loaded_member = fn(id : String, owner : String) -> Bool {
    match loaded_members.get(id) {
      Some(m) => m.contains(owner)
      None => false
    }
  }
  let prev_owner_lost = fn(id : String, candidate : String) -> Bool {
    match workspace_owners.get(id) {
      Some(p) if p != candidate =>
        !present_owners.contains(p) || (loaded_owners.contains(p) && !is_loaded_member(id, p))
      _ => false
    }
  }
  if has_core_owned {
    for id, pair in core_owned {
      let (owner, acc_loaded) = pair
      if !acc_loaded && (workspace_pending_explicit_loss.contains(id) || prev_owner_lost(id, owner)) {
        pending_ws[id] = true
        next_explicit_loss[id] = true
      } else {
        seen[id] = owner
      }
    }
    for id, _ in listed_ws {
      if !seen.contains(id) && !pending_ws.contains(id) {
        pending_ws[id] = true
        if workspace_pending_explicit_loss.contains(id) || prev_owner_lost(id, "") {
          next_explicit_loss[id] = true
        }
      }
    }
  } else {
    let mut earlier_unloaded_empty = false
    for a in accounts {
      let s = Some(a)
      let acc = field(s, "account")
      let sub = text(acc, "sub")
      let owner = if sub != "" { sub } else { text(acc, "email") }
      if owner == "" {
        continue
      }
      let is_blocked = match field(s, "blocked") {
        Some(String(b)) => b != ""
        Some(True) => true
        _ => false
      }
      if is_blocked {
        continue
      }
      let acc_loaded = match field(s, "loaded") {
        Some(False) => false
        _ => true
      }
      let ws_list = items(s, "workspaces")
      if !acc_loaded {
        if ws_list.is_empty() {
          earlier_unloaded_empty = true
        }
        for w in ws_list {
          let id = text(Some(w), "id")
          if id != "" && !seen.contains(id) {
            if earlier_unloaded_empty && workspace_owners.get(id) != Some(owner) {
              pending_ws[id] = true
            } else if workspace_pending_ws.contains(id) || prev_owner_lost(id, owner) {
              pending_ws[id] = true
              if workspace_pending_explicit_loss.contains(id) || prev_owner_lost(id, owner) {
                next_explicit_loss[id] = true
              }
            } else {
              seen[id] = owner
            }
          }
        }
        continue
      }
      for w in ws_list {
        let id = text(Some(w), "id")
        if id != "" && !seen.contains(id) && !pending_ws.contains(id) {
          if earlier_unloaded_empty && workspace_owners.get(id) != Some(owner) {
            pending_ws[id] = true
          } else {
            seen[id] = owner
          }
        }
      }
    }
  }
  workspace_owners_seen_snapshot.val = true
  let prev_pending_ws = workspace_pending_ws.keys().collect()
  workspace_pending_ws.clear()
  for id, _ in pending_ws {
    if !seen.contains(id) {
      workspace_pending_ws[id] = true
      workspace_revoked.remove(id)
    }
  }
  workspace_pending_explicit_loss.clear()
  for id, _ in next_explicit_loss {
    if workspace_pending_ws.contains(id) {
      workspace_pending_explicit_loss[id] = true
    }
  }
  workspace_pending_owners.clear()
  for owner, _ in pending_owners {
    workspace_pending_owners[owner] = true
  }
  workspace_loaded_owners.clear()
  for owner, _ in loaded_owners {
    workspace_loaded_owners[owner] = true
  }
  workspace_loaded_members.clear()
  for id, m in loaded_members {
    workspace_loaded_members[id] = m
  }
  for ws in workspace_owners.keys().collect() {
    if !seen.contains(ws) {
      let old_owner = workspace_owners.get(ws).unwrap_or("")
      workspace_owners.remove(ws)
      if !pending_ws.contains(ws) {
        workspace_revoked[ws] = true
      }
      for f in workspace_owner_change_listeners {
        f(ws, old_owner, "")
      }
    }
  }
  for ws in prev_pending_ws {
    if !seen.contains(ws) && !pending_ws.contains(ws) {
      workspace_revoked[ws] = true
    }
  }
  for ws, owner in seen {
    let was_revoked = workspace_revoked.get(ws) == Some(true)
    workspace_revoked.remove(ws)
    if was_revoked {
      workspace_owners[ws] = owner
      for f in workspace_owner_change_listeners {
        f(ws, "\u{3}revoked", owner)
      }
    } else {
      workspace_owner_set(ws, owner)
    }
  }
  workspace_owners_version.set(workspace_owners_version.untracked() + 1)
}

///|
/// Sync currently signed-in account subs (called from `sfcore`'s `accounts_told`, outside computed getters).
/// Only accounts that disappeared from `subs` are synchronously revoked; unrelated accounts are untouched.
/// When transitioning from no signed-in accounts to the first signed-in account, revokes any orphan `""` sessions.
pub fn accounts_subs_sync(subs : Array[String]) -> Unit {
  let prev = active_account_subs.val
  let prev_fallback = account_principal_sig.untracked()
  let removed : Array[String] = []
  for old in prev {
    if old != "" && !subs.contains(old) {
      removed.push(old)
    }
  }
  let orphan_empty = prev.is_empty() && prev_fallback == "" && !subs.is_empty()
  active_account_subs.val = subs.copy()
  let next_fallback = subs.get(0).unwrap_or("")
  if prev_fallback != next_fallback {
    account_principal_sig.set(next_fallback)
  }
  workspace_owners_version.set(workspace_owners_version.untracked() + 1)
  if orphan_empty {
    for f in account_revoke_listeners {
      f("")
    }
  }
  for old in removed {
    for ws in workspace_owners.keys().collect() {
      if workspace_owners.get(ws) == Some(old) {
        workspace_owners.remove(ws)
        workspace_pending_ws[ws] = true
        workspace_pending_explicit_loss[ws] = true
      }
    }
    for f in account_revoke_listeners {
      f(old)
    }
  }
}

///|
/// Current fallback account principal string without tracking.
pub fn account_principal_now() -> String {
  account_principal_sig.untracked()
}

///|
/// Update the active single-account principal (used in tests and single-account switches) and synchronously revoke
/// the previous account when switching from a non-empty principal to a different one.
pub fn account_principal_set(who : String) -> Unit {
  let prev = account_principal_sig.untracked()
  if prev == who {
    return
  }
  account_principal_sig.set(who)
  active_account_subs.val = if who == "" { [] } else { [who] }
  if prev != "" {
    for ws in workspace_owners.keys().collect() {
      if workspace_owners.get(ws) == Some(prev) {
        workspace_owners.remove(ws)
        workspace_pending_ws[ws] = true
        workspace_pending_explicit_loss[ws] = true
      }
    }
    for f in account_revoke_listeners {
      f(prev)
    }
  }
}

///|
/// Register a synchronous listener called when a specific account is revoked/signed out.
pub fn on_account_revoked(f : (String) -> Unit) -> Unit {
  account_revoke_listeners.push(f)
}

///|
/// Register a synchronous listener called when workspace `ws` changes owner `(ws, old_owner, new_owner)`.
pub fn on_workspace_owner_change(f : (String, String, String) -> Unit) -> Unit {
  workspace_owner_change_listeners.push(f)
}

///|
fn last_reset() -> Unit {
  last_said.val = []
  last_accounts.val = None
  workspace_owners.clear()
  workspace_owners_seen_snapshot.val = false
  workspace_owners_version.set(0)
  workspace_revoked.clear()
  workspace_pending_ws.clear()
  workspace_pending_explicit_loss.clear()
  workspace_pending_owners.clear()
  workspace_loaded_owners.clear()
  workspace_loaded_members.clear()
  active_account_subs.val = []
  account_principal_sig.set("")
  parked_owners.val = []
}

///|
/// A page scope already has a graph reader and must not also acquire an untracked frame hold.
fn scoped_topic(src : Source, name : String, params : Map[String, Json], independent? : Bool = false) -> @signals.Computed[TopicState] {
  let key = params.copy()
  let said = topic_key(name, key)
  @signals.computed_scoped(fn(_) { followed_topic(src, name, key, said~, independent~).get() })
}

///|
/// A shared topic's computed and its lifetime, shared by every reader of the same source and parameters.
priv struct FollowedTopic {
  source : Source
  key : String
  name : String
  params : Map[String, Json]
  independent : Bool
  holder : @signals.Computed[TopicState]
  token : Ref[Bool]
}

///|
/// Topic `name` with `params` as one key: what tells its followers (FollowedTopic's `key`) from another's.
fn topic_key(name : String, params : Map[String, Json]) -> String {
  // (none: what an empty object is written as, the same text)
  if params.is_empty() {
    return name + "\u{1}{}"
  }
  name + "\u{1}" + Json::object(params).stringify()
}

///|
// kept across runs: an active graph reader may outlive an app reset; its last reader removes the entry.
let followed_topics : Ref[Array[FollowedTopic]] = Ref([])

///|
/// Source `src` let go (its owner's view gone): the topics it follows let go of with it, whatever still watches them, so
/// none of them holds on to what it reads through (the source it was made of); what that one reads let go of by its own
/// last watcher as ever, never released here.
fn followed_forget_source(src : Source) -> Unit {
  let gone = followed_topics.val.filter(fn(t) { physical_equal(t.source, src) && !t.independent })
  if gone.is_empty() {
    return
  }
  // (taken out first: what letting each go tells finds none of them)
  followed_topics.val = followed_topics.val.filter(fn(t) { !(physical_equal(t.source, src) && !t.independent) })
  for t in gone {
    topic_readers_drop(src, t.key)
    t.holder.dispose()
  }
}

///|
/// Whether a reader holds topic `name` with `params` now (a page's, a graph's: followed and watched). It asks nothing
/// of the core and acquires nothing.
fn topic_held(name : String, params : Map[String, Json]) -> Bool {
  let key = topic_key(name, params)
  followed_topics.val.iter().any(fn(t) { t.key == key && t.holder.watched() })
}

///|
/// The topics a reader holds now (topic_held's), each once, by the source that follows it: what a page that opens
/// another in its place hands over (open_handing_held).
fn topics_held() -> Array[(Source, String, Map[String, Json])] {
  let seen : Map[String, Bool] = Map([])
  let out : Array[(Source, String, Map[String, Json])] = []
  for t in followed_topics.val {
    if !seen.contains(t.key) && t.holder.watched() {
      seen[t.key] = true
      out.push((t.source, t.name, t.params))
    }
  }
  out
}

///|
/// What is declared (declare_topic) and not let go of: each by its source, name and parameters, and its key (topic_key,
/// written once as it is declared: what is declared again is looked for by it).
// kept across runs: put back as a run begins (declared_reset)
let declared_topics : Ref[Array[(Source, String, Map[String, Json], String)]] = Ref([])

///|
/// Topic `name` with `params` of `src` declared: asked of the core now, outside any build, and kept asked with no
/// reader of its own, so the first reader to come takes it over as it reads (the same subscription, never let go of
/// between) and the graph lets it go once its last reader leaves, as any. One no reader comes to is let go of as what
/// it was declared for ends (declared_let_go). What it holds now. What declares never reads what it declared, then
/// or after (the coordinator of the migration, 2026-11-12): a read of its own would be a reader that holds it past its
/// readers' leaving, its unsubscribe never sent.
pub fn declare_topic(src : Source, name : String, params : Map[String, Json]) -> TopicState {
  let key = topic_key(name, params)
  if !declared_topics.val.iter().any(fn(d) { physical_equal(d.0, src) && d.3 == key }) {
    declared_topics.val.push((src, name, params.copy(), key))
  }
  let owner = @signals.set_owner(None)
  let state = @signals.untracked(fn() { followed_topic(src, name, params, said=key).get() })
  @signals.set_owner(owner) |> ignore
  state
}

///|
/// What is declared that no reader took over, let go of now (what it was declared for ended: another workspace in view,
/// none); what a reader took is the graph's, let go of as its last reader leaves.
pub fn declared_let_go() -> Unit {
  let was = declared_topics.val
  declared_topics.val = []
  let_go_unread(was)
}

///|
/// Each of `declared` that no reader took over let go of now (declared_let_go's, page_declared_let_go's).
fn let_go_unread(declared : Array[(Source, String, Map[String, Json], String)]) -> Unit {
  for d in declared {
    let (src, name, params, key) = d
    match followed_topics.val.search_by(fn(t) { physical_equal(t.source, src) && t.key == key && !t.independent }) {
      Some(i) if !followed_topics.val[i].holder.watched() => {
        let holder = followed_topics.val[i].holder
        followed_topics.val = followed_topics.val.filter(fn(t) { !(physical_equal(t.source, src) && t.key == key && !t.independent) })
        topic_readers_drop(src, key)
        (src.release)(name, params)
        // (its holder, read once as it was declared and by no reader since, let go of what it read: else that read
        // still follows the subscription, which the client then never ends, its unsubscribe never sent; till
        // 2026-11-12, every switch of workspace left what was declared and never read subscribed:
        // src/sfapp/declared_let_go_wbtest.mbt)
        holder.dispose()
      }
      _ => ()
    }
  }
}

///|
/// What the page on top declared as it came on top (declare_page_topic) and no reader took yet, each with its key, as
/// declared_topics.
// kept across runs: put back as a run begins (declared_reset)
let page_declared : Ref[Array[(Source, String, Map[String, Json], String)]] = Ref([])

///|
/// Topic `name` with `params` of `src` declared as a page comes on top (page_opens_node: page_opens), as declare_topic
/// declares what a workspace's first screen reads: asked of the core at that moment, not as the frame that builds the
/// page runs, and taken over by the page's reader as it reads, the same subscription all along. One no reader comes
/// to is let go of as another page comes on top (page_declared_let_go), or another workspace comes in view.
pub fn declare_page_topic(src : Source, name : String, params : Map[String, Json]) -> Unit {
  let key = topic_key(name, params)
  if page_declared.val.iter().any(fn(d) { physical_equal(d.0, src) && d.3 == key }) {
    return
  }
  page_declared.val.push((src, name, params.copy(), key))
  let owner = @signals.set_owner(None)
  @signals.untracked(fn() { followed_topic(src, name, params, said=key).get() }) |> ignore
  @signals.set_owner(owner) |> ignore
  page_declared_told.set(page_declared_told.get() + 1)
}

///|
/// How many topics pages have declared as they came on top, or as what they read said more (declare_page_topic):
/// read by what waits for a page's reads held (sfapp's first_page_node, page_opens_node's chat), told again as one is.
// kept across runs: a count, read only for its changes
let page_declared_told : @signals.Signal[Int] = @signals.signal(0)

///|
/// page_declared_told, read where it is followed.
pub fn page_declared_now() -> Int {
  page_declared_told.get()
}

///|
/// What the page on top before declared and no reader took, let go of now (another page on top).
pub fn page_declared_let_go() -> Unit {
  let was = page_declared.val
  page_declared.val = []
  let_go_unread(was)
  // (told: what declared them in the change that let them go declares again what is still to be read, page_opens_node)
  if was.length() > 0 {
    page_declared_told.set(page_declared_told.get() + 1)
  }
}

///|
/// What is declared and read by no reader now (`name` and parameters, as JSON): at the moment what declared it is
/// shown whole, none; one here is declared and not read, a fault of the declaration (sfapp's declared_read_wbtest).
pub fn declared_unread() -> Array[String] {
  [..declared_topics.val, ..page_declared.val].filter_map(fn(d) {
    let (src, name, params, key) = d
    // (one no longer followed was taken by its reader and let go of as that left: read, not a fault)
    match existing_followed_topic(src, name, params, said=key) {
      Some(h) if !h.watched() => Some(name + " " + Json::object(params).stringify())
      _ => None
    }
  })
}

///|
/// As a run begins: what the run before declared and no reader took let go of, as another workspace coming in view
/// would (declared_let_go), not left followed by nothing into the next run (where it was taken as asked already, its
/// subscription never sent again: a replay's pace pass after one ended before the reader came).
fn declared_reset() -> Unit {
  shelf_workspace.val = None
  declared_let_go()
  page_declared_let_go()
}

///|
/// What `src` holds of a topic followed now, as read_held reads it; None where nothing follows it.
pub fn read_held_found(src : Source) -> (String, Map[String, Json]) -> TopicState? {
  fn(name, params) { existing_followed_topic(src, name, params).map(fn(h) { h.get() }) }
}

///|
fn existing_followed_topic(
  src : Source,
  name : String,
  params : Map[String, Json],
  said? : String,
) -> @signals.Computed[TopicState]? {
  let key = match said {
    Some(k) => k
    None => topic_key(name, params)
  }
  followed_topics.val.search_by(fn(t) { physical_equal(t.source, src) && t.key == key && !t.independent }).map(fn(i) { followed_topics.val[i].holder })
}

///|
fn followed_topic(
  src : Source,
  name : String,
  params : Map[String, Json],
  said? : String,
  independent? : Bool = false,
) -> @signals.Computed[TopicState] {
  let key = match said {
    Some(k) => k
    None => topic_key(name, params)
  }
  match followed_topics.val.search_by(fn(t) { physical_equal(t.source, src) && t.key == key && t.independent == independent }) {
    Some(i) => followed_topics.val[i].holder
    None => {
      // Read first and on every evaluation, so the lifetime ends only when the holder loses its last reader.
      let lifetime = @signals.signal(0)
      let token = Ref(true)
      lifetime.on_unwatched(fn() {
        // Another reader may take over in this signal flush, outside event or frame. Check once it is finished.
        @signals.after_flush(fn() {
          @ui.after_frame(fn() {
            match followed_topics.val.search_by(fn(t) { physical_equal(t.token, token) }) {
              Some(i) if !followed_topics.val[i].holder.watched() => {
                let holder = followed_topics.val[i].holder
                // A removed Array slot keeps its old value alive; replace the array before releasing.
                followed_topics.val = followed_topics.val.filter(fn(t) { !physical_equal(t.token, token) })
                if !independent {
                  topic_readers_drop(src, key)
                }
                // (its holder let go of what it read before the subscription is released, as let_go_unread's: an untracked
                // read of it since it lost its last reader (existing_followed_topic, read_held_found) linked it to the
                // subscription again, which the client would then never end)
                holder.dispose()
                (src.release)(name, params)
              }
              _ => ()
            }
          })
        })
      })
      let holder = @signals.computed(fn(_) {
        lifetime.get() |> ignore
        match src.topic_scope {
          Some(scope) => scope(if independent { Lease } else { Graph }, fn() { read_topic_state(src, name, params) })
          None => read_topic_state(src, name, params)
        }
      })
      followed_topics.val.push({ source: src, key, name, params: params.copy(), independent, holder, token })
      holder
    }
  }
}

///|
/// The chat page asks for its agents' identities and state. Their full histories and jobs are read by their own
/// pages; older cores ignore the extra parameter and still return the full chat.
pub fn core_topic_params(name : String, params : Map[String, Json]) -> Map[String, Json] {
  if name != "chat" && name != "chatJobs" {
    return params
  }
  let out = params.copy()
  out["compact"] = Json::boolean(true)
  out
}

///|
/// A source which treats its name and each parameter object as given may use this identity.
pub fn exact_topic_key(name : String, params : Map[String, Json]) -> String {
  name.length().to_string() + ":" + name + Json::object(params).stringify()
}

///|
/// Identity of the object sent to a core Client, including the `topic` parameter's override and field order.
pub fn wire_topic_key(name : String, params : Map[String, Json]) -> String {
  let object : Map[String, Json] = { "topic": Json::string(name) }
  for key, value in params { object[key] = value }
  Json::object(object).stringify()
}

///|
/// Bind the client's core once when it starts: Markdown read and code coloured by it (`markdown`, `code.ink`). Static
/// fixtures have no core (the real core's answers kept instead: src/sfkept); a recorded client binds its replay of the
/// same operations. The live renderer never interprets Markdown, TeX or code while an answer is coming.
pub fn use_core_markdown(src : Source) -> Unit {
  @sf.markdown_read.val = Some(fn(words, done) {
    (src.call)("markdown", { "text": Json::string(words) }, fn(answer) {
      match answer {
        Ok(v) => done(field(Some(v), "md"))
        Err(_) => done(None)
      }
    })
  })
  @sf.ink_read.val = Some(fn(code, lang, done) {
    (src.call)("code.ink", { "code": Json::string(code), "lang": Json::string(lang) }, fn(answer) {
      match answer {
        Ok(v) =>
          done(
            match field(Some(v), "ink") {
              Some(String(s)) => Some(s)
              _ => None
            },
          )
        Err(_) => done(None)
      }
    })
  })
}

///|
/// A core made up for a page's own test (sfpages' tests, a page drawn alone in a Tester): what each topic says
/// (`topic`, none by default) and how each call is answered (`call`, an error saying so by default); a stream answered
/// the same way, once. Nothing else: no pictures, no files, no sign-in, the clock at 0.
pub fn made_source(
  topic? : (String, Map[String, Json]) -> Json? = fn(_, _) { None },
  call? : (String, Json, (Result[Json, Json]) -> Unit) -> Unit = fn(name, _, done) {
    done(Err({ "code": "unknown_call", "message": Json::string("no " + name + " made up") }))
  },
) -> Source {
  {
    topic_read: fn(name, params) {
      match topic(name, params) {
        Some(v) => { value: Some(v), error: None, version: 1 }
        None => { value: None, error: None, version: 0 }
      }
    },
    topic_key: exact_topic_key,
    topic_keyed: fn(_, _, _, _) { None },
    topic_scope: None,
    topic_alive: fn() { true },
    topic_lease_own: None,
    waits: fn(_, _) { false },
    generation: fn(_, _) { (0, true) },
    call,
    call_bytes: fn(name, params, _, done) { call(name, params, done) },
    read_bytes: fn(name, _, done) { done(Err({ "code": "unknown_call", "message": Json::string("no " + name) })) },
    read_going: fn(name, _, _, done) { done(Err({ "code": "unknown_call", "message": Json::string("no " + name) })) },
    stream: fn(name, params, _, _, done) {
      call(name, params, done)
      0
    },
    cancel: fn(_) {  },
    sign_in: fn() {  },
    signing_in: fn() { false },
    sign_in_step: fn() { Idle },
    picture: fn(_, _) { "" },
    picture_waits: fn(_) { false },
    fatal: fn() { None },
    file: fn(_, _, _) { "" },
    poster: fn(_, _, _) { "" },
    draft_picture: fn(_, _) { "!" },
    images: ChatImages::new(),
    now: fn() { 0.0 },
    leave: fn(_, _, __reason) {
      if __reason is TopicLeave::Owned(__stop) { __stop(); return }
      },
    release: fn(_, _) {  },
    refresh: fn(_, _) {  },
    read_only: false,
    reads_ahead: fn() { true },
    asks_devices: fn() { true },
    asks_outline: fn() { true },
    switches_ahead: fn() { true },
    asks_station_updates: fn() { true },
    asks_station_move: fn() { true },
    asks_station_workspaces: fn() { true },
    asks_terminals: fn() { true },
    asks_agent_rates: fn() { true },
    swr_views: fn() { true },
    gates_opens: fn() { true },
  }
}

///|
/// The core a page's bones are drawn over (@sf.waiting's `sample`: what it will show, of made-up words): it says
/// nothing and answers nothing, so what is only shown asks the real core for nothing, reads nothing ahead and opens no
/// picture.
// kept across runs: a value (nothing in it is written: its topics none, its calls never answered)
pub let sample_source : Source = { ..made_source(call=fn(_, _, _) {  }), read_only: true }

///|
/// The `done` of a call whose answer nobody reads (@settings.answer_unread, the one value for every page's calls).
pub let answer_unread : (Result[Json, Json]) -> Unit = @settings.answer_unread

///|
/// Whether `done` is answer_unread: the call's answer read by nobody (a source's `call`, as it asks the core).
pub fn unread_answer(done : (Result[Json, Json]) -> Unit) -> Bool {
  physical_equal(done, answer_unread)
}
