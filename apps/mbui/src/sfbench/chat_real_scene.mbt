// A chat of real size as a phone has it, for the benches' chat-real scenes (MBUI_FIXTURE=chat-real): the chat the
// fixture opens (s-c1) answered with what the core sends it on the workspace of real size (src/sfrealsize: its messages,
// cards and agents as many and as long as on a workspace in use), through the app's own client as a phone's core is
// (sffixture's round_trip_again: each message the client's text, parsed on the frames' thread), and after it opens, as
// an agent works in it: every `chat_real_every_ms` the next of what changes it on the real workspace, sent as the core
// sends it (its keyed ops, never the value whole again: `delta_of`), a message come each time anew (its seq the next),
// the agent's step between them. What a frame does as a real chat changes under it, as the made-up chats' scenes
// (a few short messages, an answer all at once) never show.

///|
/// How often the chat is changed once it is open, as an agent at work changes it.
let chat_real_every_ms : Int = 120

///|
/// The scene's source (the head says what).
fn chat_real_source() -> @sfapp.Source {
  let base = @sfapp.fixture_app("chat")
  let c = @sfrealsize.RealSizeChanging::new()
  let src = @sffixture.round_trip_again(c.source(base), 0.0, delta_of=fn(name, params) { c.last_ops(name, params) })
  chat_real_changing(c)
  src
}

///|
/// The changes of the real workspace, put one after another every `chat_real_every_ms` on the ways of asking the chat
/// screen read (the chat's own, its agents' steps, its row), cycling; a message come made a new one each time.
fn chat_real_changing(c : @sfrealsize.RealSizeChanging) -> Unit {
  let n = Ref(0)
  // (what changes each way, read of the real size once as the screen first asked it: the bench's own, kept apart
  // from what a frame does)
  let plan : Array[(Int, Json)] = []
  let planned = Ref(0)
  fn tick() -> Unit {
    let ways = c.ways()
    while planned.val < ways.length() {
      let i = planned.val
      let w = ways[i]
      if w.0 == "chat" || w.0 == "live" || w.0 == "chatRow" {
        for change in c.changed(i) {
          for m in change.1 {
            plan.push((i, m))
          }
        }
      }
      planned.val += 1
    }
    if plan.length() > 0 {
      let (at, m) = plan[n.val % plan.length()]
      c.put(at, chat_real_anew(m, n.val))
      n.val += 1
    }
    @ui.runtime().after(chat_real_every_ms, tick)
  }
  @ui.runtime().after(1000, tick)
}

///|
/// Message `m` (the core's keyed ops) made the `k`th time: a message it puts, and the chat's last entry it sets, a new
/// one (its seq, its ts and its words its own), so each comes anew as a message said in the chat does.
fn chat_real_anew(m : Json, k : Int) -> Json {
  guard m is Array(ops) else { return m }
  let seq = 1000 + k
  Json::array(
    ops.map(fn(op) {
      guard op is Object(o) else { return op }
      let o = o.copy()
      match (o.get("path"), o.get("put")) {
        (Some(Array([String("messages")])), Some(Object(put))) if put.contains("seq") => {
          let p = put.copy()
          p["seq"] = Json::number(seq.to_double())
          p["ts"] = Json::string("1001.00\{seq}")
          match p.get("text") {
            Some(String(t)) => {
              let words = t + " (\{k})"
              p["text"] = Json::string(words)
              p["words"] = Json::array([{ "text": Json::string(words) }])
            }
            _ => ()
          }
          o["put"] = Json::object(p)
        }
        (Some(Array([String("lastEntry")])), _) => o["set"] = Json::number(seq.to_double())
        _ => ()
      }
      Json::object(o)
    }),
  )
}
