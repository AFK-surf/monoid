// Shared timer and background-daemon helpers on `@host.Host` and `@effect`.

///|
pub async fn sleep_ms(ms : Int) -> Unit {
  @effect.sleep(if ms > 0 { ms } else { 0 })
}

///|
pub fn after(host : @host.Host, ms : Int, f : () -> Unit) -> () -> Unit {
  let fiber = host.rt.fork(async fn() { sleep_ms(ms); f() })
  () => fiber.interrupt()
}

///|
pub fn after_async(
  host : @host.Host,
  ms : Int,
  f : async () -> Unit,
  swallow_error? : Bool = false,
) -> () -> Unit {
  let fiber = host.rt.fork(async fn() {
    sleep_ms(ms)
    if swallow_error { f() catch { _ => () } } else { f() }
  })
  () => fiber.interrupt()
}

///|
pub fn every(
  host : @host.Host,
  ms : Int,
  f : async () -> Unit,
  swallow_error? : Bool = false,
) -> () -> Unit {
  // timer: repeating interval owned by the caller
  let fiber = host.rt.fork(async fn() {
    while true {
      sleep_ms(ms)
      if swallow_error { f() catch { _ => () } } else { f() }
    }
  })
  () => fiber.interrupt()
}

///|
pub fn spawn_daemon(
  host : @host.Host,
  name : String,
  f : async () -> Unit,
  silent? : Bool = false,
) -> Unit {
  ignore(
    host.rt.fork_daemon(
      name,
      async fn() { if silent { f() catch { _ => () } } else { f() } },
      on_error=if silent { _ => () } else { e => @host.note("\{name}: background work failed: \{e}") },
    ),
  )
}
