///|
/// The most a controller's state is told a second while it does not change (a stick held over): as a browser's page
/// reads them, once a display's frame at 60.
pub let gamepad_ms : Double = 1000.0 / 60.0

///|
/// How often the controllers are looked for while none is connected.
pub let gamepads_looked_ms : Double = 1000.0

///|
/// Whether a controller's state is to be told now: changed since the last told, or a stick or trigger held off rest
/// and gamepad_ms since.
fn gamepad_due(p : @hostapi.Gamepad, was : (@hostapi.Gamepad, Double)?, at : Double) -> Bool {
  match was {
    None => true
    Some((told, _)) if told != p => true
    Some((_, told_at)) => {
      let held = p.lx != 0.0 || p.ly != 0.0 || p.rx != 0.0 || p.ry != 0.0 || p.lt != 0.0 || p.rt != 0.0
      held && at - told_at >= gamepad_ms
    }
  }
}

///|
/// The game controllers this device reads (@hostapi.gamepads), followed while `on` holds (read as it changes): each
/// told `then` by its slot as it changes, a stick or trigger held off rest again gamepad_ms apart, one gone told once
/// (None); looked at gamepad_ms apart while one is connected, gamepads_looked_ms apart while none is, on the node's
/// clock (not waited for: a test's run is idle across it). Nothing told as `on` stops holding: what was told is
/// forgotten, told again whole as it holds again.
pub fn gamepads_follow(
  v : @view.View,
  on : () -> Bool,
  then : (Int, @hostapi.Gamepad?) -> Unit,
) -> Unit {
  let told : Map[Int, (@hostapi.Gamepad, Double)] = Map([])
  let ticking : Ref[(() -> Unit)?] = Ref(None)
  let active = Ref(false)
  let running = Ref(false)
  let stop_tick = fn() {
    match ticking.val {
      Some(stop) => {
        ticking.val = None
        stop()
      }
      None => ()
    }
  }
  fn look(at : Double) -> Unit {
    ticking.val = None
    if !running.val || !v.alive() {
      return
    }
    let now = if at > v.cause_at() { at } else { v.cause_at() }
    let pads = @hostapi.gamepads()
    for p in pads {
      if gamepad_due(p, told.get(p.index), now) {
        told[p.index] = (p, now)
        then(p.index, Some(p))
      }
    }
    for i in told.keys().to_array() {
      if !arr_any(pads, fn(p) { p.index == i }) {
        told.remove(i)
        then(i, None)
      }
    }
    let next = now + (if pads.is_empty() { gamepads_looked_ms } else { gamepad_ms })
    ticking.val = Some(v.at_moment_active(next, fn() { look(next) }, later=true, while_covered=true))
  }
  let sync = fn() {
    let want = active.val && @signals.untracked(on)
    if want == running.val {
      return
    }
    running.val = want
    stop_tick()
    told.clear()
    if want {
      look(v.cause_at())
    }
  }

  v.when_active(while_covered=true, fn() {
    active.val = true
    sync()
    fn() {
      active.val = false
      sync()
    }
  })
  |> ignore
  v.reacts(on, fn(_) { sync() })
}
