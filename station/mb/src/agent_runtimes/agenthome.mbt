// agenthome/module.ts: the agents' home kept as a part of the station — at the start and whenever the config changes,
// a round: the station's own skills written into each workspace's and what stations before linked into the profiles'
// homes taken away (`keep`), then every home's transcripts put in each runtime's one shared place (`transcripts`).
// One round at a time: changes while one runs make one more after it, none once the station closes. The rounds
// themselves are sessions/agent-home.ts's (`agentHomes`, `writeBuiltinSkills`, `unlinkAgentHome`,
// `linkTranscripts`), given; this is when they run.

///|
/// `feedback`: stillfail-feedback goes with the feedback_send tool, on the stable channel with still.fail cloud's.
pub fn agent_home_feedback(channel : String, spec : J?) -> Bool {
  channel == "stable" && is_true(get(spec, "feedback"))
}

///|
/// When its rounds run: one is running (`running`), one more is asked for after it (`again`: TypeScript's, which a
/// change sets and the round it asked for clears as it begins), the station closed.
pub struct AgentHome {
  mut running : Bool
  mut again : Bool
  /// A round asked for, waiting for the one running to end (the promise chain's next `then`).
  mut queued : Bool
  mut closed : Bool
  mut rounds : Int
  trace : Array[String]
}

///|
/// The first round, at the start (the part is ready once it ended).
pub fn AgentHome::new() -> AgentHome {
  { running: true, again: false, queued: false, closed: false, rounds: 1, trace: ["round"] }
}

///|
/// The config changed (`config.listen`).
pub fn AgentHome::changed(self : AgentHome) -> Unit {
  if self.closed || self.again {
    return
  }
  self.again = true
  self.queued = true
}

///|
/// What is due now runs: the round asked for begins once none runs (closed: none).
pub fn AgentHome::flush(self : AgentHome) -> Unit {
  if self.queued && !self.running {
    self.queued = false
    self.again = false
    if !self.closed {
      self.running = true
      self.rounds += 1
      self.trace.push("round")
    }
  }
}

///|
/// The round running ended.
pub fn AgentHome::ended(self : AgentHome) -> Unit {
  self.running = false
  self.flush()
}

///|
/// The station closes: no round begins any more; the one running ends.
pub fn AgentHome::close(self : AgentHome) -> Unit {
  self.closed = true
  self.trace.push("close")
}
