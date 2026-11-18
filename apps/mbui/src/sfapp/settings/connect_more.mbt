// What the connects' pages share of the settings: a value by the first of its names the core gives. The connects'
// pages, a new one's dialog and a connect's Slack app are src/sfdesk's (connects.mbt, connect.mbt, new_connect.mbt, slack_app.mbt), one each in every frame.

///|
/// The first of `keys` that `v` has, else `or_else`.
pub fn first_text(v : Json?, keys : Array[String], or_else : String) -> String {
  for k in keys {
    match opt_text(v, k) {
      Some(x) => return x
      None => ()
    }
  }
  or_else
}
