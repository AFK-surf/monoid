// High-level auto-updater API wrapping `@hostapi` native update primitives.

///|
#derive(Eq, Debug)
pub(all) enum UpdatePhase {
  Idle
  Waiting
  Downloading
  Retrying
  Ready
  Asking
  Installing
  Failed
}

///|
#derive(Eq, Debug)
pub(all) struct UpdateStatus {
  phase : UpdatePhase
  percent : Int
  error : String
  file : String
}

///|
/// Parse the JSON returned by `@hostapi.update_state()`.
pub fn parse_update_state(json_text : String) -> UpdateStatus {
  let empty : UpdateStatus = { phase: Idle, percent: -1, error: "", file: "" }
  if json_text == "" {
    return empty
  }
  let root : Json = @json.parse(json_text) catch { _ => return empty }
  let obj = match root {
    Object(m) => m
    _ => return empty
  }
  let phase = match json_str(obj, "phase") {
    Some("waiting") => Waiting
    Some("downloading") => Downloading
    Some("retrying") => Retrying
    Some("ready") => Ready
    Some("allow") | Some("asking") => Asking
    Some("installing") => Installing
    Some("failed") => Failed
    _ => Idle
  }
  let percent = match obj.get("percent") {
    Some(Number(n, ..)) => n.to_int()
    _ => -1
  }
  let error = json_str(obj, "error").unwrap_or("")
  let file = json_str(obj, "file").unwrap_or("")
  { phase, percent, error, file }
}

///|
/// Read and parse the current native updater status from `@hostapi.update_state()`.
pub fn status() -> UpdateStatus {
  parse_update_state(@hostapi.update_state())
}

///|
/// Check `feed_json` against `current_build` (or `@hostapi.app_version()` when `< 0`),
/// optionally verify its Ed25519 signature against `public_keys`, and start downloading
/// via `@hostapi.update_fetch` if a newer build is available.
/// Returns `Ok(true)` if an update fetch was initiated, `Ok(false)` if already up to date.
pub fn check_and_fetch(
  feed_json : String,
  base_url : String,
  public_keys? : Array[String] = [],
  expected_kind? : String = "",
  now? : Bool = false,
  current_build? : Int = -1,
) -> Result[Bool, String] {
  let cur = if current_build >= 0 { current_build } else { @hostapi.app_version() }
  let feed = match parse_feed(feed_json) {
    Ok(f) => f
    Err(e) => return Err(e)
  }
  if feed.version_code <= cur {
    return Ok(false)
  }
  let delta_json = if public_keys.length() > 0 {
    let signed_raw = match verify_feed(feed, public_keys, expected_kind~) {
      Ok(r) => r
      Err(e) => return Err(e)
    }
    match signed_raw {
      Some(r) =>
        pick_delta_json(
          feed,
          cur,
          base_url,
          signed_raw=Some(r),
          use_signed_raw=true,
        )
      None =>
        match feed.raw {
          // Unsigned top-level `raw` is never trusted when signature verification is active.
          Some(_) =>
            pick_delta_json(
              feed,
              cur,
              base_url,
              signed_raw=None,
              use_signed_raw=true,
            )
          None =>
            pick_delta_json(
              feed,
              cur,
              base_url,
              signed_raw=Some({ sha256: feed.sha256, size: feed.size }),
              use_signed_raw=true,
            )
        }
    }
  } else {
    pick_delta_json(feed, cur, base_url)
  }
  let url = resolve_url(base_url, feed.file)
  @hostapi.update_fetch(
    url,
    feed.sha256,
    feed.size.to_double(),
    path_basename(feed.file),
    now,
    delta_json,
  )
  Ok(true)
}

///|
/// Apply a staged update immediately via `@hostapi.update_apply`.
pub fn apply(note? : String = "") -> Unit {
  @hostapi.update_apply(note)
}
