// A session's page in the app (station/src/sessions/page.ts): the link a new Slack thread is given first, a job's
// service link and a Comma Task's are made here.

///|
pub struct PageBase {
  origin : String
  workspace : String
  station : String
}

///|
/// The app's origin for links a station on `channel` gives people: the test channel's when the station is on beta.
pub fn page_origin(origin : String, channel : String) -> String {
  if channel == "beta" {
    if origin == "https://app.still.fail" {
      "https://app.youdid.wtf"
    } else if origin == "https://app.monoid.build" {
      "https://app.monoid.zone"
    } else {
      origin
    }
  } else {
    origin
  }
}

///|
/// `<origin>/o/<workspace>/<station>/<session key>`.
pub fn session_page(base : PageBase, workspace : String, key : String) -> String {
  "\{base.origin}/o/\{workspace}/\{base.station}/\{encode_uri_component(key)}"
}
