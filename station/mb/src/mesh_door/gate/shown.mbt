///|
/// What a refusal or a failure of the mesh says is its words, as `words_of` gives them: an error's text (a tool's
/// answer, a log line's `error`) is never its type's name (`station/mesh_door/gate.PeerRefused.PeerRefused`, which
/// was all station_task and station_file said of a refusal, 0.1.9984).
pub impl Show for Refused with output(self, logger) {
  logger.write_string(words_of(self))
}

///|
pub impl Show for PeerRefused with output(self, logger) {
  logger.write_string(words_of(self))
}

///|
pub impl Show for NoLink with output(self, logger) {
  logger.write_string(words_of(self))
}

///|
pub impl Show for NoBytes with output(self, logger) {
  logger.write_string(words_of(self))
}

///|
pub impl Show for PeerGone with output(self, logger) {
  logger.write_string(words_of(self))
}

///|
pub impl Show for LockRefusal with output(self, logger) {
  logger.write_string(words_of(self))
}

///|
pub impl Show for HttpRefusal with output(self, logger) {
  logger.write_string(words_of(self))
}

///|
pub impl Show for DeviceRefused with output(self, logger) {
  logger.write_string(words_of(self))
}

///|
pub impl Show for WaysRefusal with output(self, logger) {
  logger.write_string(words_of(self))
}

///|
pub impl Show for MarkRefusal with output(self, logger) {
  logger.write_string(words_of(self))
}
