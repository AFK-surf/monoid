// A card, a panel or a sheet collects local reads before its first entrance. It waits for those reads and local
// image decodes on the tree's timeline. A topic that waits on a station can let the entrance start immediately.

///|
/// The most time a card, a panel or a sheet waits for local content before it comes in.
pub let open_hold_ms : Double = 120.0

///|
/// The gate for the first entrance of a card, a panel or a sheet.
pub struct OpenGate {
  priv gate : @view.HoldGate
}

///|
pub fn OpenGate::new() -> OpenGate {
  { gate: @view.HoldGate::new(once=true) }
}

///|
pub fn OpenGate::collect(self : OpenGate, make : () -> Unit) -> Unit {
  self.gate.collect(make)
}

///|
/// Whether the current make or readiness check is collecting conditions.
pub fn open_gate_collecting() -> Bool {
  @view.hold_collecting()
}

///|
/// Wait for the decode of a picture if the device already has its bytes.
pub fn open_gate_picture(key : String) -> Unit {
  if key != "" && @view.hold_collecting() && @ui.has_image(key) && !@ui.image_any_ready(key) {
    @view.hold_note(fn() { @ui.image_any_ready(key) })
  }
}

///|
pub fn OpenGate::holding(self : OpenGate) -> Bool {
  self.gate.is_pending()
}

///|
pub fn OpenGate::seal(self : OpenGate, n : @view.View) -> Unit {
  self.gate.seal(n)
}

///|
pub fn OpenGate::go(self : OpenGate, v : @view.View, go : () -> Unit) -> Unit {
  self.gate.go(v, most=open_hold_ms, go)
}

///|
pub fn OpenGate::stop(self : OpenGate) -> Unit {
  self.gate.stop(give_up=false)
}
