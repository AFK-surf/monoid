// Where the names book (names.mbt) keeps what a platform calls people and channels, and under what (connects/keys.ts):
// each platform's own file, a person or a channel by the place its names are of (a Slack workspace's team: two
// connects in one Slack workspace share its names; a Feishu, Comma or group connect itself: its people's ids are its
// app's own, its Comma Group's or its IM server's). The surfaces write them; the readers read them.

///|
/// Each platform's names file in the data directory (`NAMES_FILE`).
pub fn names_file(kind : String) -> String? {
  match kind {
    "slack" => Some("slack-names.json")
    "feishu" => Some("feishu-names.json")
    "comma" => Some("comma-names.json")
    "group" => Some("group-names.json")
    _ => None
  }
}

///|
/// The connects of other stations whose chats run on this one, as their stations described them (remote.mbt).
pub let remote_file : String = "remote-connects.json"

///|
pub fn person_key(place : String, user : String) -> String {
  "u:\{place}:\{user}"
}

///|
pub fn channel_key(place : String, channel : String) -> String {
  "c:\{place}:\{channel}"
}
