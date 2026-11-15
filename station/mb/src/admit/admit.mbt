// The station's queue for other stations' tasks (run by station/mb/src/reader/jobs.mbt) (station_task, src/jobs/remote.ts): a task that arrives while the
// machine's memory is under pressure, or the screen it needs is taken, waits here. Nothing is estimated beforehand (a
// build takes more or less by its caches): what is measured decides.
//
// - How busy the CPUs are holds no task back: busy CPUs make the tasks slower, not the machine unable to run them.
//   (They did, and wasted the machine: their busy share is 100% as soon as each core has something, however little
//   waits; the load average lags a minute, high while the cores sit idle after tasks end; a ramp after each start held
//   tasks of an idle machine back. 2026-10-24, 2026-11-09.) Nor is a task told how many CPUs to take: the same share
//   made that one (`MAKEFLAGS=-j1`) on a machine whose cores each had something, a build beside others on one core
//   of twelve; the system shares the cores among what runs (the user, 2026-11-10).
// - None starts while the system says its memory is under pressure (high or critical), but a small task while it is only
//   high: there is always a way to look at a machine short of running out (a small diagnostic waited with the rest
//   over 40 minutes, nothing else able to reach it, #4355).
// - A task that uses the screen (windows, a simulator, screenshots) throughout starts only while no other task has the
//   screen, and none of the commands that asked for it before it came waits for it.
// - Which one: of the sessions that have tasks waiting, the one whose task last started longest ago (one never started
//   first), its oldest task. A session that asks for ten does not keep the others behind them.
//
// The screen is one task's at a time; a task has it while it uses it: one prepared with `screen` for as long as it
// runs, any other while a command of its holds it (`stillfail-job screen <command>`: a claim, below). A task that
// takes pictures between builds and tests has it only for the pictures: the rest of it runs beside the others' (with
// whole tasks having it, one that had drawn its pictures in 40 s held it minutes more for its tests, the others with
// pictures to take waited 20 minutes and more in line, the CPUs a third busy, 2026-10-25).
//
// The screen is a machine's work's, done in minutes: a window put up for a person and left there (a virtual machine
// to try, a simulator to look at) is no claim on it (`stillfail-job show <command>`: it waits for the screen to be
// free, opens, and holds nothing; a Mac VM held the screen 23 hours as a claim, every task with pictures to take in
// line behind it, 2026-10-27). And while a person uses the screen (the machine's input not idle: someone at it, or
// working it through still.fail), it is theirs: nothing more is given it, so no window comes up under their hand; what
// holds it goes on.
//
// One explicitly small offscreen task may run beside busy builds. Its own slot is bounded to one task, it is told to
// use one CPU, and it waits only when memory is critical. This is for brief work such as drawing with a prebuilt renderer.

///|
/// The machine's input idle less than this: a person is at it (or works it through still.fail).
pub let person_idle_ms : Double = 60000.0

///|
/// A command that has held the screen this long while another waits for it: its agent is told (once), the screen
/// being for work done in minutes, a window left up for a person `stillfail-job show`'s.
pub let held_long_ms : Double = 600000.0

///|
pub(all) struct Waiting {
  id : String
  session : String
  screen : Bool
  queued_at : Double
  small : Bool
} derive(Eq, Show, Debug)

///|
pub(all) struct Started {
  id : String
  screen : Bool
  small : Bool
} derive(Eq, Show, Debug)

///|
/// A command's claim on the screen (`stillfail-job screen`): its job, the process that asked (the command's shell),
/// when it first asked (the store's clock, as a task's queued_at), whether it has the screen now, and since when (none
/// for one that does not, or one an earlier station gave it: then when it asked).
pub(all) struct Claim {
  job : String
  pid : Int
  at : Double
  held : Bool
  since : Double?
} derive(Eq, Show, Debug)

///|
/// What the claims say to the queue: whether one holds the screen, and when the first still waiting asked.
pub(all) struct Claims {
  held : Bool
  asked : Double?
} derive(Eq, Show, Debug)

///|
/// The task to start now, or why the first waiting waits (memory, small, screen, person).
pub(all) enum Picked {
  Start(Waiting)
  Wait(String)
} derive(Eq, Show, Debug)

///|
pub fn claims_held(claims : Array[Claim]) -> Claims {
  let mut asked = None
  for c in claims {
    if !c.held {
      asked = Some(c.at)
      break
    }
  }
  { held: claims.iter().any(c => c.held), asked }
}

///|
/// The claims with the screen given out (`now`: since when): to the first waiting while no task has it and no person
/// uses it, and at once to a job's that has it already (`screen_jobs`: those running that use it throughout; or a
/// command of its own holds it), so a command inside another, or inside a task that has the screen throughout, does not
/// wait for itself.
pub fn served(claims : Array[Claim], screen_jobs : Array[String], now : Double, person : Bool) -> Array[Claim] {
  let having : Map[String, Bool] = {}
  for j in screen_jobs {
    having[j] = true
  }
  for c in claims {
    if c.held {
      having[c.job] = true
    }
  }
  claims.map(c => {
    if c.held || (having.length() > 0 && !having.contains(c.job)) || (person && !having.contains(c.job)) {
      return c
    }
    having[c.job] = true
    { ..c, held: true, since: Some(now) }
  })
}

///|
/// The claims that have held the screen held_long_ms or more while another waits for it (none while none waits).
pub fn overstaying(claims : Array[Claim], now : Double) -> Array[Claim] {
  if !claims.iter().any(c => !c.held) {
    return []
  }
  claims.filter(c => c.held && now - c.since.unwrap_or(c.at) >= held_long_ms)
}

///|
/// Oldest first by when each one's session last started a task (never: first), then by when it came.
fn in_line(waiting : Array[Waiting], last_of : (String) -> Double?) -> Array[Waiting] {
  let last = (w : Waiting) => last_of(w.session)
  let sorted = waiting.copy()
  sorted.sort_by((a, b) => {
    let by = match (last(a), last(b)) {
      (None, None) => 0
      (None, Some(_)) => -1
      (Some(_), None) => 1
      (Some(x), Some(y)) => x.compare(y)
    }
    if by != 0 {
      by
    } else {
      a.queued_at.compare(b.queued_at)
    }
  })
  sorted
}

///|
/// The task to start now, if any, and else why the first waiting waits.
pub fn pick(
  waiting : Array[Waiting],
  running : Array[Started],
  pressure : String?,
  person : Bool,
  last_of : (String) -> Double?,
  claims : Claims,
) -> Picked? {
  if waiting.length() == 0 {
    return None
  }
  if pressure == Some("critical") {
    return Some(Wait("memory"))
  }
  let roomy = pressure != Some("high")
  if !roomy && !waiting.iter().any(w => w.small) {
    return Some(Wait("memory"))
  }
  // (the screen another task's, a person's, or asked for by a command before this task came)
  let screen_busy = running.iter().any(r => r.screen) || claims.held
  let able = waiting.filter(w => {
    (roomy || w.small) &&
    !(
      w.screen &&
      (
        screen_busy ||
        person ||
        (match claims.asked {
          Some(a) => a <= w.queued_at
          None => false
        })
      )
    )
  })
  if !roomy && able.length() == 0 {
    return Some(Wait("memory"))
  }
  if able.length() == 0 {
    return Some(Wait(if !screen_busy && person { "person" } else { "screen" }))
  }
  // (one small task at a time beside the rest)
  let small_busy = running.iter().any(r => r.small)
  let ready = able.filter(w => !w.small || !small_busy)
  if ready.length() == 0 {
    return Some(Wait("small"))
  }
  Some(Start(in_line(ready, last_of)[0]))
}

///|
/// Where a waiting task is in line: 1 for the next.
pub fn place(waiting : Array[Waiting], id : String, last_of : (String) -> Double?) -> Int? {
  match in_line(waiting, last_of).search_by(w => w.id == id) {
    Some(i) => Some(i + 1)
    None => None
  }
}

///|
/// A service that ran this long before it ended starts again at once; one that keeps ending waits longer each time.
let steady_ms : Double = 60000.0

///|
let max_pause_ms : Double = 60000.0

///|
/// How long a service that ended waits before it starts again (jobs.mbt): none after a steady run, else 1 s doubling
/// with each quick end, 60 s at most.
pub fn restart_pause(restarts : Int, ran_ms : Double) -> Double {
  if ran_ms >= steady_ms {
    return 0.0
  }
  let mut v = 1000.0
  let n = if restarts < 0 { 0 } else if restarts > 6 { 6 } else { restarts }
  for i = 0; i < n; i = i + 1 {
    v = v * 2.0
  }
  if v > max_pause_ms {
    max_pause_ms
  } else {
    v
  }
}
