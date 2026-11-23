// GET /events (routes/events.ts): every change to what the API shows, pushed as it happens (the events' part).

///|
/// Rust's `parse::<usize>()`: digits only (a leading + too).
fn usize_of(v : String?) -> Double? {
  match v {
    Some(s) if re("^\\+?[0-9]+$").matches(s) => Some(js_number(s))
    _ => None
  }
}

///|
fn Admin::events_routes(self : Admin) -> Array[Route] {
  [
    route("GET", "^\\/events$", async fn(r, _) {
      if !self.setup.has("events") {
        return error(503, "events not ready")
      }
      let froms = r.params("from")
      let lasts = r.params("last")
      let live = []
      for i, key in r.params("live") {
        let f = js_number(froms.get(i).unwrap_or(""))
        let from = match froms.get(i) {
          Some(s) if trim_js(s) != "" && !f.is_nan() => {
            let m = @cmp.maximum(0.0, f)
            if m.is_inf() {
              m
            } else {
              m.floor()
            }
          }
          _ => 0.0
        }
        let last = usize_of(lasts.get(i))
        let entry = jarr([
          js(key),
          jnum(if from.is_inf() { 9007199254740991.0 } else { from }),
          match last {
            Some(l) if l > 0.0 => jnum(l)
            _ => Null
          },
        ])
        // Only the viewer's workspace's (api/seen.ts).
        let exists = self.setup.has("store") &&
          !nullish(self.store("getSession", [js(key)]))
        if exists && self.session_seen(r.viewer, key) {
          live.push(entry)
        }
      }
      let lines = r.params("lines")
      let logs = []
      for i, id in r.params("job") {
        let n = @cmp.minimum(
          1000.0,
          @cmp.maximum(1.0, usize_of(lines.get(i)).unwrap_or(200.0)),
        )
        if !self.setup.has("store") || self.job_seen(r.viewer, id) {
          logs.push(jarr([js(id), jnum(n)]))
        }
      }
      let logins = if read_only(r.viewer) {
        []
      } else {
        r.params("login").filter(id => re("^[0-9a-z]{1,40}$").matches(id))
      }
      let running = r.param("running") == Some("1")
      let spare = if running && r.param("spare") == Some("1") {
        let seen : Map[String, Unit] = Map([])
        let open : Array[String] = []
        for key in r.params("open") {
          if open.length() >= 16 {
            break
          }
          if seen.contains(key) {
            continue
          }
          seen[key] = ()
          let exists = self.setup.has("store") &&
            !nullish(self.store("getSession", [js(key)]))
          if exists && self.session_seen(r.viewer, key) {
            open.push(key)
          }
        }
        jstrs(open)
      } else {
        Null
      }
      let said = self.backend.ask("events.open", [
        r.viewer,
        js(r.lang),
        jbool(r.param("host") == Some("1")),
        jarr(live),
        jarr(logs),
        jopt(r.param("since")),
        jbool(r.param("brief") == Some("1")),
        jstrs(logins),
        jbool(running),
        spare,
      ])
      self.answer_from(said)
    }),
  ]
}
