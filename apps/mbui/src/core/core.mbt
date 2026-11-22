// The app's one core: the engine (src/host/core_api.h; Hermes on the Rust shell, on macOS, iOS, Android and Windows)
// linked into the app, its messages posted by core_native.c to mbui's queue on the channel "core" (mb_post, any thread), which hands each to `receive`
// on the UI thread as the next frame begins (the app's `@ui.on_message("core", @core.receive)`). In a browser it is the
// page's (js.mbt: still.fail's web core worker, its messages posted to the same queue).

///|
priv struct Engine {
  mut started : Bool
  mut data_dir : String
  mut cloud : String
  mut beta : Bool
  restarts : Array[Double]
  auths : Map[Int, (Result[String, String]) -> Unit]
  mut next_auth : Int
}

///|
let engine : Engine = {
  started: false,
  data_dir: "",
  cloud: "",
  beta: false,
  restarts: [],
  auths: {},
  next_auth: 1,
}

///|
/// The engine's way in: a message, and the bytes beside it if any.
fn engine_send(s : String, b : Bytes?) -> Unit {
  // (on the app's own clock, the core told it first: what this sets off is timed from now)
  clock_before_send()
  match b {
    Some(b) => ffi_send_bytes(s, b)
    None => ffi_send(s)
  }
}

///|
/// Where the app's messages go: the engine, or a kept conversation given again (replay.mbt).
let transport : Ref[(String, Bytes?) -> Unit] = { val: engine_send }

///|
/// Told as each message is received, before it is (a kept conversation given again: its wall clock then, replay.mbt).
let receive_hook : Ref[(() -> Unit)?] = { val: None }

///|
/// The wall clock a kept conversation had (replay.mbt), in place of this machine's.
let wall_override : Ref[(() -> Double)?] = { val: None }

///|
/// How many made-up cores have taken the engine's place (serve), the one serving now's number; 0: the engine's.
let served_count : Ref[Int] = Ref(0)

///|
let serving : Ref[Int] = Ref(0)

///|
/// A made-up core in the engine's place (a test's: sffixture's round_trip_again), as a kept conversation takes it
/// (Replay::attach): what the app's client sends goes to `send`, the client started anew; what it answers it gives
/// `receive` as the engine's messages come. Its number, to tell whether it still serves (served). Till serve_end.
pub fn serve(send : (String) -> Unit) -> Int {
  served_count.val += 1
  serving.val = served_count.val
  transport.val = fn(s, _) { send(s) }
  wall_override.val = None
  receive_hook.val = None
  client.reset()
  serving.val
}

///|
/// The number of the made-up core serving now (serve), 0 where the engine (or a kept conversation, Replay::attach) is
/// the core: one serving no more says nothing to the client.
pub fn served() -> Int {
  serving.val
}

///|
/// The engine is the core again, a made-up one done with (serve).
pub fn serve_end() -> Unit {
  if serving.val != 0 {
    serving.val = 0
    transport.val = engine_send
  }
}

///|
/// The app's client of its core.
pub let client : Client = Client::new(
  fn(s) {
    trace_out(s, ffi_wall_ms())
    (transport.val)(s, None)
  },
  send_bytes=fn(s, b) {
    trace_out(s, ffi_wall_ms(), bytes=b)
    (transport.val)(s, Some(b))
  },
)

///|
/// Starts the core: its files in `data_dir` (empty: the platform's place for the app's data, or $MBUI_CORE_DATA),
/// still.fail cloud at `cloud`. What it says is taken as a frame begins (mbui's queue, the app's handler for "core":
/// `receive`). False when this build has no engine linked in.
pub fn start(
  data_dir? : String = "",
  cloud? : String = "https://app.still.fail",
  beta? : Bool = false,
) -> Bool {
  if engine.started {
    return true
  }
  engine.data_dir = data_dir
  engine.cloud = cloud
  engine.beta = beta
  engine.started = ffi_start(data_dir, cloud, if beta { 1 } else { 0 }) != 0
  engine.started
}

///|
/// Where still.fail cloud is, as the core was started with it (`start`'s `cloud`).
pub fn cloud() -> String {
  engine.cloud
}

///|
/// Ends the core (waits for its thread); nothing comes from it after.
pub fn stop() -> Unit {
  if engine.started {
    ffi_stop()
    engine.started = false
  }
}

///|
/// What is asked of the core is awaited until answered or first read (see Client::track): an mbui app gives its
/// runtime's `outside_start` and `outside_end`, so its screens are settled only once what they asked of the core is in.
pub fn track(start : (String) -> Int, end : (Int) -> Unit) -> Unit {
  client.track(start, end)
}

///|
/// The subscription to `topic` (see Client::subscribe): repeated reads share one Sub and one direct hold, so a view
/// can call it every frame. They are not independently releasable direct handles.
pub fn subscribe(topic : String, params? : Map[String, Json] = {}) -> Sub {
  client.subscribe(topic, params~)
}

///|
/// Read a source topic as a signal dependency, or as a legacy untracked source hold.
pub fn follow_topic(topic : String, params? : Map[String, Json] = {}) -> Sub {
  client.follow_topic(topic, params~)
}

///|
/// Refresh an existing topic without interrupting its readers.
pub fn refresh_topic(topic : String, params? : Map[String, Json] = {}) -> Unit {
  client.refresh_topic(topic, params~)
}

///|
/// Calls `name` (see Client::call); `bytes` beside it. No `on_done`: nobody reads its answer (Client::call).
pub fn call(
  name : String,
  params? : Json = Json::object({}),
  bytes? : Bytes? = None,
  on_done? : (Result[Json, Json]) -> Unit,
) -> Unit {
  client.call(name, params~, bytes~, on_done?) |> ignore
}

///|
/// Calls `name` for an answer with bytes beside it (see Client::call_bytes):
/// `media.image`'s picture, say.
pub fn call_bytes(
  name : String,
  params? : Json = Json::object({}),
  on_done~ : (Result[(Json, Bytes?), Json]) -> Unit,
) -> Unit {
  client.call_bytes(name, params~, on_done~) |> ignore
}

///|
/// Calls `name` and hears how it goes (see Client::stream); the call's id, for `cancel`.
pub fn stream(
  name : String,
  params? : Json = Json::object({}),
  bytes? : Bytes? = None,
  on_value~ : (Json, Bytes?) -> Unit,
  on_done? : (Result[Json, Json]) -> Unit,
) -> Int {
  client.stream(name, params~, bytes~, on_value~, on_done?)
}

///|
/// A remote screen's frame `ts` acknowledged straight to its station, where the engine's shell reads the view of call
/// `call` itself (Apple's: client/shell `istream.tap`): no message to the core, no answer. False: not so (the app
/// calls `screen.ack`).
pub fn screen_ack(call : Int, ts : Double) -> Bool {
  ffi_screen_ack(call.to_double(), ts) != 0
}

///|
/// The app's input to a remote screen (`input`: the JSON `screen.input` says in its `input`) sent straight to its
/// station, in order, where the engine's shell reads the view of call `call` itself (client/shell
/// `sf_shell_screen_input`): no message to the core, no answer. Only the engine's (none while a made-up core serves).
/// False: not so (not a pointer's, the wheel's, a key's or a controller's, or not tapped: the app calls `screen.input`).
pub fn screen_input(call : Int, input : String) -> Bool {
  serving.val == 0 && ffi_screen_input(call.to_double(), input) != 0
}

///|
/// The values of call `name` for which `f` says true change nothing a frame reads: taken as they come, they build
/// nothing (Client::quiet). Said once, as the app starts.
pub fn quiet(name : String, f : (Json) -> Bool) -> Unit {
  client.quiet(name, f)
}

///|
/// Nobody reads the answer of call `name`: taken as it comes, it builds nothing (Client::unread). Said once, as the app
/// starts.
pub fn unread(name : String) -> Unit {
  client.unread(name)
}

///|
/// Whether call `name`'s answers are taken as they come (said or unread): for a test holding that a replay takes them as
/// a device does (still.fail's sfreplay).
pub fn taken_as_they_come(name : String) -> Bool {
  client.taken_as_they_come(name)
}

///|
/// The answer of call `name` changes only signals: taken as it comes, what read them is built again, nothing else
/// (Client::said). Said once, as the app starts.
pub fn said(name : String) -> Unit {
  client.said(name)
}

///|
/// Calls `name` and hears how it goes, for an answer with bytes beside it (see Client::stream_bytes); the call's id,
/// for `cancel`.
pub fn stream_bytes(
  name : String,
  params? : Json = Json::object({}),
  on_value~ : (Json, Bytes?) -> Unit,
  on_done~ : (Result[(Json, Bytes?), Json]) -> Unit,
) -> Int {
  client.stream_bytes(name, params~, on_value~, on_done~)
}

///|
/// A streamed call stopped (see Client::cancel).
pub fn cancel(id : Int) -> Unit {
  client.cancel(id)
}

///|
/// The time of day, in milliseconds since 1970: when something was done, as
/// the core and the stations compare it (a reading place's `at`).
pub fn wall_ms() -> Double {
  match wall_override.val {
    Some(f) => f()
    None => ffi_wall_ms()
  }
}

///|
/// Releases a direct subscription; other readers keep it until they leave.
pub fn unsubscribe(s : Sub) -> Unit {
  client.unsubscribe(s)
}

///|
/// Ends a topic if it was asked, without starting a new subscription for it.
pub fn unsubscribe_topic(topic : String, params? : Map[String, Json] = {}) -> Unit {
  client.unsubscribe_topic(topic, params~)
}

///|
/// A graph-owned reader ended; keep a topic still held by another reader.
pub fn release_topic(topic : String, params? : Map[String, Json] = {}) -> Unit {
  client.release_topic(topic, params~)
}

///|
/// A legacy source reader ended; a direct subscription remains held.
pub fn leave_topic(topic : String, params? : Map[String, Json] = {}) -> Unit {
  client.leave_topic(topic, params~)
}

///|
/// The core's reason when it has failed and was not started again.
pub fn fatal() -> String? {
  client.fatal_said.get() |> ignore
  client.fatal
}

///|
/// What the core said, one message (its JSON, the bytes beside it): the app's handler for mbui's channel "core"
/// (`@ui.on_message("core", @core.receive)`), which mbui calls as a frame begins with everything posted since the last,
/// in the order it came; so what came is seen whole at a frame's boundary, never part-way through one, and how much a
/// frame sees depends on frames, not on when the core's thread answered. A kept conversation given again (replay.mbt)
/// comes this way too.
pub fn receive(text : String, bytes : Bytes?) -> Unit {
  // (what a take let be and nothing undid, though nothing leaves it so: taken first, in the order it came)
  voided_flush()
  // (for an id nothing holds: let be, unread; for one let go of, kept unread)
  if unheld(text, bytes) {
    return
  }
  let t0 = if perf_counts() { ffi_now() } else { -1.0 }
  // (how long it took, parsed and taken, by what it was (never what it said), for a hang it is in:
  // @hostapi.work_part)
  let name = Ref("?")
  @hostapi.work_part(fn() { "core " + name.val }, fn() { receive_taken(text, bytes, t0, name) })
}

///|
/// Whether message `text` is for an id nothing holds (Client::unheld), or for a subscription let go of (Client::later):
/// taken unread, a kept conversation's clock told it came all the same (receive_hook). One for a subscription let go of
/// is read as ever while a conversation is recorded, whose trace says each message as it was read, and with bytes
/// beside it (none of these has any).
fn unheld(text : String, bytes : Bytes?) -> Bool {
  guard client.taken_unread(text, later=tracer.val is None && bytes is None) else { return false }
  match receive_hook.val {
    Some(f) => f()
    None => ()
  }
  true
}

///|
/// The messages let be unread since this was last asked, for ids nothing held, by what the ids were (`topic stations`,
/// `call screen.view`; `?` one let go of longer ago), the most first: how many, their length in all
/// (Client::unheld_said).
pub fn unheld_said() -> Array[(String, Int, Int)] {
  client.unheld_said()
}

///|
/// The message receive_said read and left for the frame, with what it read of it: `receive`, handed the same text as
/// the frame is built, reads it no second time.
// kept across runs: taken by the `receive` it was left for, another's put in its place
let parsed_left : Ref[(String, Json)?] = Ref(None)

///|
/// Message `text` parsed and taken (receive's), what it was said in `name`; its counts kept where `t0` (the record's
/// clock as it came) is not below 0.
fn receive_taken(text : String, bytes : Bytes?, t0 : Double, name : Ref[String]) -> Unit {
  let msg = match parsed_left.val {
    Some((t, m)) if physical_equal(t, text) => {
      parsed_left.val = None
      m
    }
    _ => @json.parse(text) catch { _ => return }
  }
  let what = client.perf_name(msg)
  name.val = what
  take(msg, bytes)
  if t0 >= 0.0 {
    perf_in(what, text, bytes, ffi_now() - t0)
  }
}

///|
/// Whether what goes between the app and the core is counted: while the device's performance record is kept, or with
/// MBUI_PROBE=1 (mbui's probe, which says perf_said's line on the log: a Mac's, which keeps no record).
fn perf_counts() -> Bool {
  if probe_env.val < 0 {
    probe_env.val = if @hostapi.env("MBUI_PROBE") == "1" { 1 } else { 0 }
  }
  probe_env.val == 1 || @hostapi.perf_recording()
}

///|
// kept across runs: read once from the environment (-1: not yet)
let probe_env : Ref[Int] = Ref(-1)

///|
/// While the device's performance record is kept: what the core said to the app, by what it was (Client::perf_name),
/// each its count, bytes and the app's time taking it (ms: parsed, a topic's delta applied, a call's answer handed
/// on); and what the app asked of the core, by name, each its count. Said and begun again with each summary of the
/// frames (perf_said).
// kept across runs: the record's counts, taken by perf_said
let perf_ins : Map[String, (Int, Int, Double)] = Map([])

///|
// kept across runs: the record's counts, taken by perf_said
let perf_outs : Map[String, Int] = Map([])

///|
fn perf_in(what : String, text : String, bytes : Bytes?, ms : Double) -> Unit {
  let n = text.length() +
    (match bytes {
      Some(b) => b.length()
      None => 0
    })
  let (k, b, t) = perf_ins.get(what).unwrap_or((0, 0, 0.0))
  perf_ins[what] = (k + 1, b + n, t + ms)
}

///|
/// What the app asked of the core (a call's name, `sub <topic>`), counted while the record is kept (Client::call,
/// Client::ask).
fn perf_out(what : String) -> Unit {
  if perf_counts() {
    perf_outs[what] = perf_outs.get(what).unwrap_or(0) + 1
  }
}

///|
/// The record's line of the core's messages since it was last asked (@ui.perf_also "core"), the heaviest first:
/// `in (ms/count/KB, the 6 longest): 3.2ms/12/40.1KB topic chats delta | … || out (count, the 6 most): 4 chat.read |
/// …`; "" where none came or went. Begun again.
pub fn perf_said(span : Double) -> String {
  ignore(span)
  if !perf_counts() {
    client.perf_forget()
  }
  if perf_ins.is_empty() && perf_outs.is_empty() {
    return ""
  }
  let ins = perf_ins.to_array()
  ins.sort_by(fn(a, b) { b.1.2.compare(a.1.2) })
  let outs = perf_outs.to_array()
  outs.sort_by(fn(a, b) { b.1.compare(a.1) })
  let line = StringBuilder()
  line.write_string("in (ms/count/KB, the 6 longest):")
  for i, e in ins {
    if i >= 6 {
      break
    }
    let (k, b, t) = e.1
    line.write_string((if i == 0 { " " } else { " | " }) + "\{(t * 10.0).round() / 10.0}ms/\{k}/\{(b.to_double() / 102.4).round() / 10.0}KB \{e.0}")
  }
  line.write_string(" || out (count, the 6 most):")
  for i, e in outs {
    if i >= 6 {
      break
    }
    line.write_string((if i == 0 { " " } else { " | " }) + "\{e.1} \{e.0}")
  }
  perf_ins.clear()
  perf_outs.clear()
  line.to_string()
}

///|
/// What the core said, taken as it comes where it is a topic's change alone (Client::topic_said: what it changes is its
/// topic's signal and nothing else) or a call's that changes nothing a frame reads (Client::call_said: a quiet value, an
/// answer nobody reads), before the frame decides what it does: what read the topic is built again, nothing else
/// (@ui.on_message_said, "core"). Whether it was; else it is left for `receive`, as the frame is built.
pub fn receive_said(text : String, bytes : Bytes?) -> Bool {
  // (one a whole value of its topic after it in the same take undoes: let be, unread, receive_ahead)
  if voids(text, bytes) {
    return true
  }
  receive_said_now(text, bytes)
}

///|
/// What the core said in one take of mbui's (all that came between two frames, or as a frame begins), as the core's
/// channel sees it (another channel's message None), before any of it is offered to `receive_said`
/// (@ui.on_messages_ahead, "core"): each of the core's messages a whole value of its topic undoes, later in the take, is
/// let be unread as it comes. A topic's value, or what changed of it, for one held past its first answer
/// (Client::voidable) followed by such a whole value, with nothing between them but more of the same for others
/// (Client::reads_no_other) and none from elsewhere: read, applied and told, a chat's or a list's took 15 to 45 ms on a
/// phone, and in the one change the take is (mbui's view_event: one batch of signals, nothing that reads them run
/// before its end) nothing reads what it did before the whole value is taken in its place. Not while a conversation is
/// recorded or given again, whose trace and clock say each message as it is read (tracer, receive_hook).
pub fn receive_ahead(came : Array[(String, Bytes?)?]) -> Unit {
  voided_flush()
  ahead_void.clear()
  ahead_at.val = 0
  if tracer.val is Some(_) || receive_hook.val is Some(_) {
    return
  }
  let n = came.length()
  let flags = Array::make(n, false)
  // (the subscriptions a whole value comes for later in the take, with nothing but what reads no other till then)
  let whole_after : Map[Int, Bool] = Map([])
  for k = n - 1; k >= 0; k = k - 1 {
    match came[k] {
      Some((text, None)) =>
        match head_of(text) {
          Some((id, whole)) if client.reads_no_other(id) =>
            if client.voidable(id) {
              if whole_after.contains(id) {
                flags[k] = true
              }
              if whole {
                whole_after[id] = true
              }
            }
          _ => whole_after.clear()
        }
      _ => whole_after.clear()
    }
  }
  for k, m in came {
    match m {
      Some((text, _)) => ahead_void.push((text, flags[k]))
      None => ()
    }
  }
}

///|
/// The core's messages of the take receive_ahead was shown, in order, and whether each is undone by a whole value
/// after it; the next to come at `ahead_at`.
// kept across runs: said anew by each take (receive_ahead)
let ahead_void : Array[(String, Bool)] = []

///|
// kept across runs: said anew by each take (receive_ahead)
let ahead_at : Ref[Int] = Ref(0)

///|
/// The messages let be so far, by their subscriptions' ids, in the order they came: dropped as the whole value that
/// undoes them comes, taken in order before anything else that comes first (voided_flush).
// kept across runs: none left once a take's whole values have come
let voided : Array[(Int, String)] = []

///|
/// Whether message `text` is let be unread as it comes (receive_ahead's). What was let be before it is dropped where it
/// is the whole value that undoes it, kept where it reads nothing of it, and else taken first, in the order it came.
fn voids(text : String, bytes : Bytes?) -> Bool {
  let undone = match ahead_void.get(ahead_at.val) {
    Some((t, f)) if physical_equal(t, text) => {
      ahead_at.val += 1
      f
    }
    // (not the take it was shown: none of it let be)
    _ => {
      ahead_void.clear()
      ahead_at.val = 0
      false
    }
  }
  let head = if bytes is None { head_of(text) } else { None }
  if undone &&
    @signals.batch_depth() > 0 &&
    tracer.val is None &&
    receive_hook.val is None &&
    head is Some((id, _)) &&
    client.voidable(id) {
    voided.push((id, text))
    if perf_counts() {
      perf_in(client.voided_name(id), text, None, 0.0)
    }
    return true
  }
  if voided.length() > 0 {
    let waits = fn(id) { voided.iter().any(fn(v) { v.0 == id }) }
    match head {
      Some((id, true)) if waits(id) && client.voidable(id) => voided.retain(fn(v) { v.0 != id })
      Some((id, _)) if !waits(id) && client.reads_no_other(id) => ()
      _ => voided_flush()
    }
  }
  false
}

///|
/// What was let be and is not undone after all (what came before its whole value reads it, or another take came):
/// taken now, in the order it came, as it would have been; one no longer taken as it comes, as `receive` takes it.
fn voided_flush() -> Unit {
  if voided.length() == 0 {
    return
  }
  let was = voided.copy()
  voided.clear()
  for v in was {
    if !receive_said_now(v.1, None) {
      receive(v.1, None)
    }
  }
}

///|
/// receive_said's, of a message not let be.
fn receive_said_now(text : String, bytes : Bytes?) -> Bool {
  // (for an id nothing holds: taken as it comes, unread, nothing built for it; for one let go of, kept unread)
  if unheld(text, bytes) {
    return true
  }
  let t0 = if perf_counts() { ffi_now() } else { -1.0 }
  // (how long it took, parsed and taken, by what it was, for a hang it is in: @hostapi.work_part; one left for
  // `receive` is said parsed: taken there, read here)
  let name = Ref("parsed")
  @hostapi.work_part(fn() { "core " + name.val }, fn() {
    let msg = @json.parse(text) catch { _ => return false }
    match msg {
      Object(m) if !m.contains("mbui_auth") &&
        !m.contains("clocked") &&
        (client.topic_said(m) || client.call_said(m)) => {
        let what = client.perf_name(msg)
        name.val = what
        take(msg, bytes)
        if t0 >= 0.0 {
          perf_in(what, text, bytes, ffi_now() - t0)
        }
        true
      }
      _ => {
        // (left for `receive`, which reads it no second time)
        parsed_left.val = Some((text, msg))
        false
      }
    }
  })
}

///|
fn take(msg : Json, bytes : Bytes?) -> Unit {
  match msg {
    Object(m) if m.contains("mbui_auth") => web_auth_done(m)
    Object(m) if m.contains("clocked") => clocked(m)
    // (the web's: the tab whose worker ran the core went, another tab's runs it now, web/src/core/worker.ts: asked
    // again what this client had asked of the one before)
    Object(m) if m.contains("rejoin") => client.restarted()
    _ => {
      match receive_hook.val {
        Some(f) => f()
        None => ()
      }
      trace_in(msg, bytes, ffi_wall_ms())
      client.receive_json(msg, bytes~)
      if client.fatal is Some(_) && engine.started {
        // (told before it is started again: the reason is the only trace of the core's own failure)
        match on_failed.val {
          Some(f) => f(client.fatal.unwrap())
          None => ()
        }
        restart()
      }
    }
  }
}

///|
/// Told as the core fails, with its reason, before it is started again (or stopped, a third time in a minute): still.fail's
/// Android app reports it as CoreFailed (StillFailCore.onFailed), as src/stillfail's host does.
pub let on_failed : Ref[((String) -> Unit)?] = { val: None }

///|
/// Told once another core was started after one failed (`restart`) and takes calls: what was kept of the failure as it
/// happened (on_failed, when the core it would go to was the one gone) is sent then.
pub let on_restarted : Ref[(() -> Unit)?] = { val: None }

///|
/// What the app times of its topics as they are subscribed and first read (Client::time_topics).
pub fn time_topics(f : ((Int, String, Json?, Bool) -> Unit)?) -> Unit {
  client.time_topics(f)
}

///|
/// A core that failed is stopped and another started, as the Android and desktop apps do; not more than 3 times a
/// minute, so a core that fails as it starts does not spin.
fn restart() -> Unit {
  let now = ffi_now()
  let recent = engine.restarts.filter(fn(t) { now - t < 60000.0 })
  if recent.length() >= 3 {
    stop()
    return
  }
  engine.restarts.clear()
  for t in recent {
    engine.restarts.push(t)
  }
  engine.restarts.push(now)
  ffi_stop()
  engine.started = ffi_start(engine.data_dir, engine.cloud, if engine.beta {
    1
  } else {
    0
  }) !=
    0
  client.restarted()
  // (a core started anew runs on real time until told the app's clock again)
  clock_again()
  if engine.started {
    match on_restarted.val {
      Some(f) => f()
      None => ()
    }
  }
}

///|
/// Signs a person in with still.fail cloud: `auth.begin` for the login page, the system's browser session for it
/// (ASWebAuthenticationSession on iOS; a Custom Tab on Android), which brings back the `<scheme>://auth/callback` URL
/// the cloud sends the browser to (`auth_redirect`: stillfail, or the app's own where its engine has one), then `auth.complete` with its query. `on_done` gets `auth.complete`'s answer
/// (`{account, return_to}`) or why not (the person closed the page, or an error of the core's).
pub fn sign_in(on_done : (Result[Json, Json]) -> Unit) -> Unit {
  let params : Map[String, Json] = {
    "redirect_uri": Json::string(auth_redirect()),
    "return_to": Json::string(auth_return_to()),
  }
  client.call("auth.begin", params=Json::object(params), on_done=fn(r) {
    match r {
      Ok(Object(ok)) =>
        match ok.get("url") {
          Some(String(url)) =>
            if !browser_session(url, fn(back) {
                match back {
                  Ok(query) =>
                    client.call(
                      "auth.complete",
                      params=Json::object({ "query": Json::string(query) }),
                      on_done~,
                    )
                    |> ignore
                  Err(why) => on_done(Err(error_json("auth", why)))
                }
              }) {
              on_done(Err(error_json("auth", "no browser session in this build")))
            }
          _ => on_done(Err(error_json("auth", "auth.begin gave no url")))
        }
      Ok(_) => on_done(Err(error_json("auth", "auth.begin gave no url")))
      Err(e) => on_done(Err(e))
    }
  })
  |> ignore
}

///|
/// Opens `url` in the system's browser session (`has_browser_session`), which comes back on the app's own scheme
/// (`app_scheme`): `done` gets the query it came back with, or why not ("cancelled": the person closed it). False
/// where this build has none (nothing opened, `done` never called).
pub fn browser_session(url : String, done : (Result[String, String]) -> Unit) -> Bool {
  let token = engine.next_auth
  engine.next_auth += 1
  engine.auths[token] = done
  if ffi_web_auth(token, url, auth_scheme()) == 0 {
    engine.auths.remove(token)
    return false
  }
  true
}

///|
/// The app's own scheme, which its browser session comes back on (`<scheme>://auth/…`).
pub fn app_scheme() -> String {
  auth_scheme()
}

///|
/// Whether this build has the system's browser session `sign_in` needs (ASWebAuthenticationSession on iOS, a Custom Tab
/// coming back on the app's scheme on Android); where it has not (macOS, Windows), an app signs in on
/// `@hostapi.browser_login` (a loopback address) instead.
pub fn has_browser_session() -> Bool {
  ffi_has_web_auth() != 0
}

///|
fn error_json(code : String, message : String) -> Json {
  Json::object({ "code": Json::string(code), "message": Json::string(message) })
}

///|
/// The browser session's end (core_native.c queues it as `{mbui_auth, url}` or `{mbui_auth, error}`).
fn web_auth_done(m : Map[String, Json]) -> Unit {
  let token = match m.get("mbui_auth") {
    Some(Number(d, ..)) => d.to_int()
    _ => return
  }
  guard engine.auths.get(token) is Some(f) else { return }
  engine.auths.remove(token)
  match (m.get("url"), m.get("error")) {
    (Some(String(url)), _) => f(Ok(query_of(url)))
    (_, Some(String(e))) => f(Err(e))
    _ => f(Err("the browser session ended"))
  }
}

///|
/// A URL's query string, without its `?` (and without a `#fragment`).
pub fn query_of(url : String) -> String {
  let q = match url.find("?") {
    Some(i) => url.exact_view(start=i + 1)
    None => return ""
  }
  match q.find("#") {
    Some(j) => q.exact_view(end=j).to_owned()
    None => q.to_owned()
  }
}

///|
/// The keyed list of topic `topic`'s value at `field` (Sub::keyed), of its subscription where there is one: none
/// acquired for it (what reads it reads the topic as well, which holds it).
pub fn keyed_of(
  topic : String,
  params : Map[String, Json],
  field : String,
  keys : Array[String],
) -> @signals.KeyedList[String, Json]? {
  // (none till its subscription has a value: a subscription made anew, its first answer on its way, gives no empty list
  // in the place of the one a reader was given before)
  client.peek_topic(topic, params~).bind(fn(s) { if s.value is Some(_) { Some(s.keyed(field, keys)) } else { None } })
}
