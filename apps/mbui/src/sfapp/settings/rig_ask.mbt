// An agent's request for a rig of the workspace as a card (a station that only runs tasks, 2026-11-10; as a phone's request is): which rig
// in its title, the agent's reason under it, and at its foot 允许 as the one solid button, 拒绝 beside it, and for
// how long a choice beside them that starts at what the agent asked (`rig.decide` on the chat's station). Only the
// rig's person answers it (the card's assignee); elsewhere a line says whose it is. What they allow is signed with a
// key on their own lock: a device not on it is sent there first, a web page says where to answer instead. Decided, a
// line says how it went. What it keeps between frames is the vault card's, keyed `rig/<id>`.

///|
/// A length of time in words: 45 分钟, 2 小时, 7 天 (the vault's).
fn rig_time_words(seconds : Int) -> String {
  let minutes = (seconds + 59) / 60
  let days = minutes % 1440 == 0
  let hours = minutes % 60 == 0
  fill(
    if days { "android-settings.vault.timeout.nDays" } else if hours { "android-settings.vault.timeout.nHours" } else { "android-settings.vault.timeout.nMinutes" },
    [("n", (if days { minutes / 1440 } else if hours { minutes / 60 } else { minutes }).to_string())],
  )
}

///|
/// A timeout in words: 闲置 1 小时后失效, 2 小时后失效 (the vault's).
pub fn rig_timeout_words(kind : String, seconds : Int) -> String {
  fill("android-settings.vault.timeout.button." + (if kind == "fixed" { "fixed" } else { "idle" }), [("time", rig_time_words(seconds))])
}

///|
/// A timeout as its choice on the card says it, short enough to stand beside 允许 and 拒绝 on a phone (the long
/// words took a line of their own, the choice in the card's corner off its curve): 闲置 1 小时, 固定 8 小时.
fn rig_timeout_short(kind : String, seconds : Int) -> String {
  fill("web-pages.rigs.ask.time." + (if kind == "fixed" { "fixed" } else { "idle" }), [("time", rig_time_words(seconds))])
}

///|
/// The times a grant is offered for: what the agent asked first, then an hour idle, and an hour, eight, a day and a
/// week fixed.
fn rig_timeouts(asked : (String, Int)) -> Array[(String, Int)] {
  let out = [asked]
  for t in [("idle", 3600), ("fixed", 3600), ("fixed", 28800), ("fixed", 86400), ("fixed", 604800)] {
    if !out.contains(t) {
      out.push(t)
    }
  }
  out
}

///|
/// How a request ended, in words: 已允许使用这台 station · 闲置 1 小时后失效; approved while the rig was away, that it
/// waits for it; 已拒绝使用这台 station; or why it ended (所有者已收回, 对话已归档, 授权已到期, 闲置超时).
pub fn rig_outcome_words(status : String, why : String, delivered : Bool, granted : (String, Int)) -> String {
  match status {
    "granted" if !delivered => tr("web-pages.rigs.ask.away")
    "granted" => fill("web-pages.rigs.ask.granted", [("how", rig_timeout_words(granted.0, granted.1))])
    "denied" if why == "" => tr("web-pages.rigs.ask.denied")
    _ => fill("web-pages.rigs.ask.ended", [("why", if why == "" { tr("web-pages.rigs.ask.denied") } else { why })])
  }
}
