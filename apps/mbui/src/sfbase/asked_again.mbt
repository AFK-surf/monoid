// What a page put by at rest on the stack's kept left (Nav::try_park_left) shows as it is taken back: its topics asked
// of the core again (what it held let go of while it was put by: page_entry_parked), each with nothing yet and no error
// till the core's first answer. What a structure is switched by holds what it last read meanwhile, so nothing of the
// page is let go and made again for that moment; what was never read (a page opened cold) is as the topic says.

///|
/// Topic `name` with `params` as `src` reads it, its value: what it last was while it is asked again (no value, no
/// error), read as it changes.
pub fn topic_value_held(src : Source, name : String, params : Map[String, Json]) -> @signals.Computed[Json?] {
  @signals.computed(fn(was) {
    let t = src.topic(name, params).get()
    match (t.value, t.error, was) {
      (None, None, Some(Some(v))) => Some(v)
      _ => t.value
    }
  })
}

///|
/// The station at `address` as the workspace in view's marks show it (station_marks): what it last was while their rows
/// are asked again (no value, or only a kept one, and no error), read as it changes.
pub fn station_mark_held(src : Source, address : String) -> @signals.Computed[Station?] {
  @signals.computed(fn(was) {
    let w = match workspace_in_view(src).0 {
      Some(w) => w.id
      None => ""
    }
    let found = station_marks(src, w).iter().find_first(fn(s) { s.address == address })
    match (found, was) {
      (None, Some(Some(prev))) => {
        let t = station_rows(src, w)
        if (t.value is None || t.kept()) && t.error is None {
          Some(prev)
        } else {
          None
        }
      }
      _ => found
    }
  })
}
