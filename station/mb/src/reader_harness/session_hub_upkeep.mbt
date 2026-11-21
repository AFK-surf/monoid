// Deterministic harness (`--builder harness-session-hub`) for testing `session_hub` single-flight upkeep-state load:
// blocks `world.ask("upkeepState.read")` behind an `@effect.Deferred[Unit]`, starts `run_archive_upkeep_if_due` (A),
// waits until A is suspended in the read, starts `clean_idle_rebuildable` (B), asserts B measures nothing before
// the gate opens, then releases the gate and reports what B measured.

///|
async fn harness_session_hub(host : @host.Host) -> Unit {
  while host.line() is Some(line) {
    if line == "" {
      continue
    }
    let ask = @json.parse(line) catch { _ => Json::null() }
    let id = sn_at(ask, "id").unwrap_or(Json::null())
    let op = sn_str(ask, "op")
    let reply : Result[Json, String] = try {
      match op {
        "race.upkeepStateLoad" => {
          let db_path = sn_str(ask, "db")
          let now = match sn_at(ask, "now") {
            Some(Number(n, ..)) => n
            _ => 1_800_000_000_000.0
          }
          let upkeep_state = sn_at(ask, "upkeepState").unwrap_or(Json::null())
          let db = @sql.Db::attach(host, db_path, wait=5000)
          defer {
            db.close()
          }
          let store = @store_sessions.Store::open(db, () => now.to_int64(), 0L)
          let threads = @store_threads.Store::new(db, now)
          let read_started : @effect.Deferred[Unit] = @effect.Deferred::new()
          let read_gate : @effect.Deferred[Unit] = @effect.Deferred::new()
          let read_count : Ref[Int] = Ref(0)
          let patch_count : Ref[Int] = Ref(0)
          let measured : Array[String] = []
          let world : @session_hub.World = {
            tell: (_, _) => (),
            ask: async fn(what, args) {
              match what {
                "upkeepState.read" => {
                  read_count.val += 1
                  ignore(read_started.succeed(()))
                  read_gate.wait() catch { _ => () }
                  upkeep_state
                }
                "upkeepState.patch" => {
                  patch_count.val += 1
                  Json::boolean(true)
                }
                "cold.expires" => Json::boolean(true)
                "cold.cleanIdleRebuildable" => {
                  match args {
                    String(k) => measured.push(k)
                    _ => ()
                  }
                  Json::number(4096.0)
                }
                _ => Json::null()
              }
            },
            now: () => now,
            config: () => ({ "dataDir": "/tmp", "archivedWorkspaceMs": 0 } : Json),
            workspaces: () => [],
            station: () => None,
            link: _ => None,
            chat: _ => None,
            process_state: _ => "cold",
            idle_ms: (_, _) => None,
            random_hex: _ => "00000000",
            move_on: () => None,
          }
          let hub = @session_hub.Hub::new(world, store, threads)
          let mut due_ran = false
          let mut cleaned_count = 0
          let mut measured_before_release = 0
          let mut f2_done_before_release = false
          @effect.scoped(scope => {
            let f1 = scope.fork(async fn() { hub.run_archive_upkeep_if_due(now) })
            read_started.wait() catch { _ => () }
            // `@effect`'s ready queue is strictly FIFO (`libs/mbui/src/effect/runtime.mbt:416`). Forking `f2`
            // before `turn` and joining `turn` guarantees `f2` runs to its first suspension (or completes)
            // before `turn` executes:
            // - Unfixed code: `f2` sees `upkeep_state_loaded == true`, has no real suspension in fake `world.ask`,
            //   and completes all 16 measurements (`f2.is_done() == true`, `measured.length() == 16`) before `turn`.
            // - Fixed code: `f2` suspends on `d.wait()` (`f2.is_done() == false`, `measured.length() == 0`) until
            //   `read_gate.succeed(())` lets `f1` finish loading and resolve `d`.
            let f2 = scope.fork(async fn() { hub.clean_idle_rebuildable(now) })
            let turn = scope.fork(async fn() { () })
            turn.join() catch { _ => () }
            f2_done_before_release = f2.is_done()
            measured_before_release = measured.length()
            ignore(read_gate.succeed(()))
            due_ran = f1.join() catch { _ => false }
            cleaned_count = f2.join() catch { _ => 0 }
          })
          Ok(
            {
              "dueRan": Json::boolean(due_ran),
              "cleanedCount": Json::number(cleaned_count.to_double()),
              "f2DoneBeforeRelease": Json::boolean(f2_done_before_release),
              "measuredBeforeRelease": Json::number(measured_before_release.to_double()),
              "measured": Json::array(measured.map(Json::string)),
              "readCount": Json::number(read_count.val.to_double()),
              "patchCount": Json::number(patch_count.val.to_double()),
            },
          )
        }
        _ => Err("unknown op \{op}")
      }
    } catch {
      e => Err(e.to_string())
    }
    match reply {
      Ok(v) => host.say(Json::object({ "id": id, "ok": v }).stringify())
      Err(m) => host.say(Json::object({ "id": id, "error": Json::string(m) }).stringify())
    }
  }
}
