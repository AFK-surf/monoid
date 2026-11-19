// Shared clock, timer and background-daemon helpers on `@host.Host` and `@effect`.

///|
fn clamp_ms(ms : Int) -> Int {
  if ms > 0 {
    ms
  } else {
    0
  }
}

///|
/// Sleep for `ms` milliseconds (clamped at 0).
pub async fn sleep_ms(ms : Int) -> Unit {
  @effect.sleep(clamp_ms(ms))
}

///|
/// A wall-clock function carried forward from a caller-provided initial wall timestamp using the steady clock.
pub fn steady_wall_clock(initial_wall_ms : Double) -> () -> Double {
  let steady = @host.now()
  () => initial_wall_ms + (@host.now() - steady).to_double()
}

///|
/// Schedule a one-shot callback via a forked sleeping fiber; returns a cancel function.
pub fn after(host : @host.Host, ms : Int, f : () -> Unit) -> () -> Unit {
  let fiber = host.rt.fork(async fn() {
    sleep_ms(ms)
    f()
  })
  () => fiber.interrupt()
}

///|
/// Schedule a one-shot async callback via a forked sleeping fiber; returns a cancel function.
pub fn after_async(
  host : @host.Host,
  ms : Int,
  f : async () -> Unit,
  swallow_error? : Bool = false,
) -> () -> Unit {
  let fiber = host.rt.fork(async fn() {
    sleep_ms(ms)
    if swallow_error {
      f() catch {
        _ => ()
      }
    } else {
      f()
    }
  })
  () => fiber.interrupt()
}

///|
/// Schedule a one-shot callback directly on `host.rt.after` with a cancellation flag.
pub fn after_cb(host : @host.Host, ms : Int, f : () -> Unit) -> () -> Unit {
  let live = Ref(true)
  host.rt.after(clamp_ms(ms), () => if live.val {
    live.val = false
    f()
  })
  () => live.val = false
}

///|
/// Schedule a repeating callback via a forked sleeping fiber; returns a cancel function.
pub fn every(host : @host.Host, ms : Int, f : () -> Unit) -> () -> Unit {
  // timer: repeating interval owned by the caller (e.g. lock heartbeat)
  let fiber = host.rt.fork(async fn() {
    while true {
      sleep_ms(ms)
      f()
    }
  })
  () => fiber.interrupt()
}

///|
/// Schedule a repeating async callback via a forked sleeping fiber (errors swallowed); returns a cancel function.
pub fn every_async(host : @host.Host, ms : Int, f : async () -> Unit) -> () -> Unit {
  // timer: repeating interval owned by the caller (e.g. coordinator sweep)
  let fiber = host.rt.fork(async fn() {
    while true {
      sleep_ms(ms)
      f() catch {
        _ => ()
      }
    }
  })
  () => fiber.interrupt()
}

///|
/// Spawn a named background daemon fiber on `host.rt`, logging failures via `@host.note` unless `silent` is true.
pub fn spawn_daemon(
  host : @host.Host,
  name : String,
  f : async () -> Unit,
  silent? : Bool = false,
) -> Unit {
  ignore(
    host.rt.fork_daemon(
      name,
      async fn() {
        if silent {
          f() catch {
            _ => ()
          }
        } else {
          f()
        }
      },
      on_error=if silent {
        _ => ()
      } else {
        e => @host.note("\{name}: background work failed: \{e}")
      },
    ),
  )
}
