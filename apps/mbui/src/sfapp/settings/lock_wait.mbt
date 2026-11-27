// A device not yet confirmed in the workspace's safe mode (its lock): whether it waits, and the lock's calls. The page
// it shows while it waits is sfpages' lock_wait_node.mbt.

///|
/// Whether this device waits to be let in to the workspace's lock: to be confirmed (the lock's `me.waiting`), or, a web
/// page nobody can approve there, for its person's first app to approve it (`me.needsAppText`): either way the
/// workspace's place is the waiting page (sfpages' lock_wait_node.mbt), which says which.
pub fn lock_waiting(core : Core, ws : String) -> Bool {
  let me = field((core.topic)("lock", { "workspace": str(ws) }).get().value, "me")
  flag(me, "waiting") || text(me, "needsAppText") != ""
}

///|
/// What a web page nobody can approve in the workspace's lock says, the core's words (the lock's `me.needsAppText`):
/// "" where it is not one.
pub fn lock_needs_app(core : Core, ws : String) -> String {
  text(field((core.topic)("lock", { "workspace": str(ws) }).get().value, "me"), "needsAppText")
}

///|
/// `lock.<name>` on this workspace, let go on by itself and said how it ended (AppState.lockCall).
pub fn lock_call(
  core : Core,
  ws : String,
  name : String,
  what : String,
  params : Array[(String, String)],
  done? : String = "",
) -> Unit {
  let p : Array[(String, Json)] = [("workspace", str(ws))]
  for kv in params {
    p.push((kv.0, str(kv.1)))
  }
  act(core, what, "lock." + name, obj(p), done~)
}

///|
/// A station of the workspace not in the lock, taken in once its owner says it is theirs (设置 › 安全, and the station
/// itself: its page's and its list card's 保护).
pub fn join_dialog(core : Core, ws : String, station : String, name : String) -> Unit {
  @sf.confirm(
    @sf.t("web-pages.security.joinTitle"),
    @sf.t("web-pages.security.joinBody"),
    @sf.t("web-pages.security.join"),
    facts=[(@sf.t("common.confirmFact.station"), name)],
    fn() {
      lock_call(
        core,
        ws,
        "joinStation",
        @sf.t("web-pages.security.join"),
        [("station", station)],
        done=@sf.t("web-pages.security.joined", args=[("name", name)]),
      )
    },
  )
}
