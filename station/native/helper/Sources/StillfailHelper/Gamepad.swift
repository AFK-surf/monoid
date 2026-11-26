// A person's game controllers driving this Mac (station/src/screens/mac-input.ts `{op: "gamepad"}`): macOS gives an app
// no virtual controller to make, so they drive the desktop, as station/src/screens/gamepad-desktop.ts maps one: the
// pointer by the left stick (smooth, past its dead zone, faster the further it is pushed), the wheel by the right, A the
// left button, B the right, X Escape, Y Return, LB ⇧Tab, RB Tab, LT Page Up, RT Page Down, Back Delete, Start Space,
// the d-pad the arrow keys. While a stick is pushed the pointer and wheel move 60 times a second on the input's queue;
// a controller let go of (`connected: false`, the view's end) lets go of all it holds.
import CoreGraphics
import Foundation

/// The W3C Standard Gamepad's buttons, by their bit.
enum PadButton: Int {
  case a = 0, b, x, y, lb, rb, lt, rt, back, start, ls, rs, up, down, left, right, home
}

/// One controller's state as the station says it.
struct PadState: Equatable {
  var buttons = 0
  var lx = 0.0, ly = 0.0, rx = 0.0, ry = 0.0, lt = 0.0, rt = 0.0

  init() {}

  init(_ op: [String: Any]) {
    let n = { (k: String) -> Double in
      let v = (op[k] as? NSNumber)?.doubleValue ?? 0
      return v.isFinite ? v : 0
    }
    buttons = ((op["buttons"] as? NSNumber)?.intValue ?? 0) & 0x1ffff
    lx = min(max(n("lx"), -1), 1); ly = min(max(n("ly"), -1), 1)
    rx = min(max(n("rx"), -1), 1); ry = min(max(n("ry"), -1), 1)
    lt = min(max(n("lt"), 0), 1); rt = min(max(n("rt"), 0), 1)
  }

  /// The buttons it holds down, the triggers pressed past half way as two more.
  var held: Int {
    let triggers = (1 << PadButton.lt.rawValue) | (1 << PadButton.rt.rawValue)
    return (buttons & ~triggers) | (lt > Gamepads.triggerDown ? 1 << PadButton.lt.rawValue : 0) | (rt > Gamepads.triggerDown ? 1 << PadButton.rt.rawValue : 0)
  }

  /// A stick or the wheel pushed past its dead zone.
  var moving: Bool { [lx, ly, rx, ry].contains { Gamepads.past($0) != 0 } }
}

final class Gamepads {
  static let deadZone = 0.15
  static let triggerDown = 0.5
  /// Points a second at a stick's full travel (its travel squared: fine near the centre), and the wheel's pixels.
  static let pointerSpeed = 1500.0
  static let wheelSpeed = 2400.0
  static let tick = 1.0 / 60

  /// A stick's travel past its dead zone, 0..1 again, its sign kept.
  static func past(_ v: Double) -> Double {
    let a = abs(v)
    return a <= deadZone ? 0 : (v < 0 ? -1 : 1) * (a - deadZone) / (1 - deadZone)
  }

  /// Keys the buttons press: the Mac's virtual key and the flags it goes with.
  static let keys: [(button: PadButton, keycode: CGKeyCode, flags: UInt64)] = {
    let fn: UInt64 = 0x800000, arrow: UInt64 = 0x200000 | 0x800000, shift: UInt64 = 0x20000
    return [
      (.x, 0x35, 0), (.y, 0x24, 0), (.lb, 0x30, shift), (.rb, 0x30, 0), (.back, 0x33, 0), (.start, 0x31, 0),
      (.up, 0x7e, arrow), (.down, 0x7d, arrow), (.left, 0x7b, arrow), (.right, 0x7c, arrow), (.lt, 0x74, fn), (.rt, 0x79, fn),
    ]
  }()

  /// What a change of the buttons held presses and lets go of: (the button, down).
  static func changes(from was: Int, to now: Int) -> [(PadButton, Bool)] {
    var out: [(PadButton, Bool)] = []
    for bit in 0..<17 where (was ^ now) & (1 << bit) != 0 {
      if let b = PadButton(rawValue: bit) { out.append((b, now & (1 << bit) != 0)) }
    }
    return out
  }

  /// How far a tick moves the pointer and the wheel for a state: points, and pixels (a page's: down positive).
  static func step(_ s: PadState, dt: Double = tick) -> (dx: Double, dy: Double, wx: Double, wy: Double) {
    let sq = { (v: Double) -> Double in let p = past(v); return p * abs(p) }
    return (sq(s.lx) * pointerSpeed * dt, sq(s.ly) * pointerSpeed * dt, past(s.rx) * wheelSpeed * dt, past(s.ry) * wheelSpeed * dt)
  }

  unowned let input: ScreenInput
  private var pads: [Int: PadState] = [:]
  private var timer: DispatchSourceTimer?
  /// Explicit opt-in for mouse/keyboard emulation (off by default: macOS has no native virtual controller API).
  var allowMouse: Bool
  /// What of a pixel the wheel moved and was not posted yet.
  private var wheel = (x: 0.0, y: 0.0)
  /// Where the pointer is driven to, between ticks (fractions of a point kept).
  private var at: CGPoint?

  init(input: ScreenInput, allowMouse: Bool = false) {
    self.input = input
    self.allowMouse = allowMouse
  }

  /// Current gamepad capability/mode event for message 4.
  var statusEvent: [String: Any] {
    ["gamepad": ["native": false, "driver": "unsupported", "mouse": allowMouse]]
  }

  /// Toggle mouse/keyboard emulation mode, releasing any held desktop buttons/keys when turning off.
  func setMouse(_ on: Bool) {
    if allowMouse == on {
      input.channel.sendJSON(4, statusEvent)
      return
    }
    if !on {
      release()
    }
    allowMouse = on
    input.channel.sendJSON(4, statusEvent)
  }

  /// One state (on the input's queue).
  func take(_ op: [String: Any]) {
    guard allowMouse else { return }
    guard let index = (op["index"] as? NSNumber)?.intValue, (0...3).contains(index) else { return }
    let was = pads[index] ?? PadState()
    let now = op["connected"] as? Bool == false ? PadState() : PadState(op)
    if op["connected"] as? Bool == false { pads[index] = nil } else { pads[index] = now }
    for (button, down) in Gamepads.changes(from: was.held, to: now.held) { press(button, down) }
    let moving = pads.values.contains { $0.moving }
    if moving && timer == nil {
      let t = DispatchSource.makeTimerSource(queue: input.queue)
      t.schedule(deadline: .now(), repeating: Gamepads.tick, leeway: .milliseconds(2))
      t.setEventHandler { [weak self] in self?.move() }
      t.resume()
      timer = t
    } else if !moving {
      timer?.cancel()
      timer = nil
      at = nil
    }
  }

  /// Every controller let go of (the view ended).
  func release() {
    for index in Array(pads.keys) { take(["index": index, "connected": false]) }
  }

  /// The buttons all controllers hold now, as a mouse's (1 left, 2 right).
  private var mouse: Int {
    let held = pads.values.reduce(0) { $0 | $1.held }
    return (held & (1 << PadButton.a.rawValue) != 0 ? 1 : 0) | (held & (1 << PadButton.b.rawValue) != 0 ? 2 : 0)
  }

  private func press(_ button: PadButton, _ down: Bool) {
    let flags = CGEventSource.flagsState(.hidSystemState).rawValue & 0x1e0000
    if button == .a || button == .b {
      let place = input.current()
      let type: CGEventType = button == .a ? (down ? .leftMouseDown : .leftMouseUp) : (down ? .rightMouseDown : .rightMouseUp)
      let event = CGEvent(mouseEventSource: input.source, mouseType: type, mouseCursorPosition: place, mouseButton: button == .a ? .left : .right)
      event?.setIntegerValueField(.mouseEventClickState, value: 1)
      input.send(event, flags: flags)
      return
    }
    guard let key = Gamepads.keys.first(where: { $0.button == button }) else { return }
    input.send(CGEvent(keyboardEventSource: input.source, virtualKey: key.keycode, keyDown: down), flags: key.flags | flags)
  }

  /// A tick: the pointer and the wheel as the sticks push them.
  private func move() {
    guard Status.inputAllowed() else { return }
    var total = (dx: 0.0, dy: 0.0, wx: 0.0, wy: 0.0)
    for s in pads.values {
      let d = Gamepads.step(s)
      total = (total.dx + d.dx, total.dy + d.dy, total.wx + d.wx, total.wy + d.wy)
    }
    if total.dx != 0 || total.dy != 0 {
      let bounds = input.area()
      let from = at ?? input.current()
      let to = CGPoint(x: ScreenInput.below(min(max(from.x + total.dx, bounds.minX), bounds.maxX), bounds.maxX), y: ScreenInput.below(min(max(from.y + total.dy, bounds.minY), bounds.maxY), bounds.maxY))
      at = to
      let buttons = mouse
      let type: CGEventType = buttons & 1 != 0 ? .leftMouseDragged : buttons & 2 != 0 ? .rightMouseDragged : .mouseMoved
      let event = CGEvent(mouseEventSource: input.source, mouseType: type, mouseCursorPosition: to, mouseButton: buttons & 2 != 0 && buttons & 1 == 0 ? .right : .left)
      event?.setIntegerValueField(.mouseEventDeltaX, value: input.carry.x.take(total.dx))
      event?.setIntegerValueField(.mouseEventDeltaY, value: input.carry.y.take(total.dy))
      input.send(event, flags: 0)
      input.pointer = to
    }
    wheel.x += total.wx
    wheel.y += total.wy
    let wx = wheel.x.rounded(.towardZero), wy = wheel.y.rounded(.towardZero)
    wheel.x -= wx
    wheel.y -= wy
    if wx != 0 || wy != 0 {
      let event = CGEvent(scrollWheelEvent2Source: input.source, units: .pixel, wheelCount: 2, wheel1: Int32(-wy), wheel2: Int32(-wx), wheel3: 0)
      event?.location = at ?? input.current()
      input.send(event, flags: 0)
    }
  }
}
