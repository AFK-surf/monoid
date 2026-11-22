// A person's input to a view, posted (station/src/screens/mac-input.ts says what each op is).
import CoreGraphics
import Foundation

final class ScreenInput {
  let channel: Channel
  let displayID: CGDirectDisplayID
  let queue = DispatchQueue(label: "fail.still.helper.input")
  let source = CGEventSource(stateID: .hidSystemState)
  var pointer = CGPoint(x: -1, y: -1)
  var refusedTold = false
  /// What the picture shows, in global points: the display, or the window shown alone (ScreenView's `area`).
  var area: () -> CGRect
  /// What of a pixel each axis's moves left over (`dx`, `dy`), carried to the next.
  var carry = (x: DeltaCarry(), y: DeltaCarry())
  /// The person's game controllers, driving this Mac's pointer, wheel and keys (Gamepad.swift).
  lazy var pads = Gamepads(input: self)
  /// Told of each of the viewer's absolute moves posted (PointerLock.swift's detector of them).
  var moved: (() -> Void)?

  init(channel: Channel, displayID: CGDirectDisplayID) {
    self.channel = channel
    self.displayID = displayID
    area = { CGDisplayBounds(displayID) }
  }

  func post(_ op: [String: Any]) {
    queue.async { self.perform(op) }
  }

  func point(_ x: Double, _ y: Double) -> CGPoint {
    let bounds = area()
    let cx = min(max(x, 0), 1), cy = min(max(y, 0), 1)
    return CGPoint(x: ScreenInput.below(bounds.minX + cx * (bounds.width - 1), bounds.maxX), y: ScreenInput.below(bounds.minY + cy * (bounds.height - 1), bounds.maxY))
  }

  /// `v` as the largest Float32 no greater than it, and below `edge`: WindowServer keeps the pointer in Float32, and one
  /// rounded up to a display's right or bottom edge is off it (the Dock that hides, a full screen app's menu bar, never
  /// shown).
  static func below(_ v: Double, _ edge: Double) -> Double {
    var f = Float(v)
    if Double(f) > v { f = f.nextDown }
    while Double(f) >= edge { f = f.nextDown }
    return Double(f)
  }

  /// Where the pointer is now, in global points (an app that holds it moved it there).
  func current() -> CGPoint {
    CGEvent(source: nil)?.location ?? pointer
  }

  func send(_ event: CGEvent?, flags: UInt64) {
    guard let event else { return }
    event.flags = CGEventFlags(rawValue: flags)
    event.post(tap: .cghidEventTap)
  }

  /// ⌘V where the focus is (what the viewer set on the clipboard, pasted); on this queue, after the input before it.
  func paste() {
    guard Status.inputAllowed() else { return }
    let command = CGEventFlags.maskCommand.rawValue
    send(CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true), flags: command)
    send(CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false), flags: command)
  }

  func perform(_ op: [String: Any]) {
    if !Status.inputAllowed() {
      if !refusedTold {
        refusedTold = true
        channel.sendJSON(4, ["refused": "control"])
      }
      return
    }
    let flags = (op["flags"] as? NSNumber)?.uint64Value ?? 0
    switch op["op"] as? String {
    case "mouse":
      let at = point((op["x"] as? Double) ?? 0, (op["y"] as? Double) ?? 0)
      let button = (op["button"] as? Int) ?? 0
      let buttons = (op["buttons"] as? Int) ?? 0
      let pressed: CGMouseButton = button == 2 ? .right : button == 1 ? .center : .left
      var type: CGEventType
      var held = pressed
      switch op["type"] as? String {
      case "down": type = button == 2 ? .rightMouseDown : button == 1 ? .otherMouseDown : .leftMouseDown
      case "up": type = button == 2 ? .rightMouseUp : button == 1 ? .otherMouseUp : .leftMouseUp
      default:
        if buttons & 1 != 0 { type = .leftMouseDragged; held = .left }
        else if buttons & 2 != 0 { type = .rightMouseDragged; held = .right }
        else if buttons & 4 != 0 { type = .otherMouseDragged; held = .center }
        else { type = .mouseMoved }
      }
      // How far the person's pointer moved: its deltas, each pixel's part carried; `relative` (an app holds the pointer):
      // only that, where the pointer is (kept on the display), the app reading the deltas whole.
      let dx = op["dx"] as? Double, dy = op["dy"] as? Double
      // (a press with `relative` too: where the pointer is, never put back at x, y under a game's crosshair)
      let relative = op["relative"] as? Bool == true
      var place = at
      if relative {
        let now = current(), bounds = area()
        place = CGPoint(x: ScreenInput.below(min(max(now.x, bounds.minX), bounds.maxX), bounds.maxX), y: ScreenInput.below(min(max(now.y, bounds.minY), bounds.maxY), bounds.maxY))
      }
      let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: place, mouseButton: held)
      if let clicks = op["clicks"] as? Int, type != .mouseMoved { event?.setIntegerValueField(.mouseEventClickState, value: Int64(clicks)) }
      if let dx, let dy {
        event?.setIntegerValueField(.mouseEventDeltaX, value: carry.x.take(dx))
        event?.setIntegerValueField(.mouseEventDeltaY, value: carry.y.take(dy))
      }
      send(event, flags: flags)
      if !relative && type == .mouseMoved && place != pointer { moved?() }
      pointer = place
    case "scroll":
      let at = point((op["x"] as? Double) ?? 0, (op["y"] as? Double) ?? 0)
      // A wheel turns what is under the pointer: it goes there first.
      if at != pointer {
        send(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: at, mouseButton: .left), flags: flags)
        pointer = at
      }
      let dx = Int32(((op["dx"] as? Double) ?? 0).rounded()), dy = Int32(((op["dy"] as? Double) ?? 0).rounded())
      // A page's deltas are positive down and right; a wheel's, up and left.
      let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: -dy, wheel2: -dx, wheel3: 0)
      event?.location = at
      send(event, flags: flags)
    case "key":
      let keycode = CGKeyCode((op["keycode"] as? Int) ?? 0)
      send(CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: (op["down"] as? Bool) ?? true), flags: flags)
    case "text":
      let units = Array(((op["text"] as? String) ?? "").utf16)
      // At most 20 UTF-16 units an event (what a keyboard event carries); a surrogate pair is not split.
      var at = 0
      while at < units.count {
        var chunk = Array(units[at..<min(at + 20, units.count)])
        if chunk.count == 20, UTF16.isLeadSurrogate(chunk[19]) { chunk.removeLast() }
        for down in [true, false] {
          let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
          event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
          send(event, flags: 0)
        }
        at += chunk.count
      }
    case "gamepad":
      pads.take(op)
    default:
      break
    }
  }
}

/// What of a pixel an axis's moves left over: each move goes as whole pixels, rounded with what the ones before left
/// (`whole = round(rest + v)`, `rest -= whole`), so many slow moves add up to all of theirs (100 of 0.3: 30).
struct DeltaCarry {
  var rest = 0.0

  mutating func take(_ v: Double) -> Int64 {
    let given = v.isFinite ? v : 0
    let whole = (rest + given).rounded()
    rest += given - whole
    return Int64(whole)
  }
}
