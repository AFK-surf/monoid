// Whether an app on this Mac holds the pointer (a game, a 3D view, a page's Pointer Lock): said to the station as
// message 4 `{pointerLock}` as it changes, so the viewer's app sends its moves as relative ones (ScreenInput's
// `relative`). A hidden pointer alone is never enough (a video, a slideshow, the pointer hidden while typing hide it
// too): it also takes a second, independent sign, kept for 100 ms each way:
//   - the pointer jumped 8 points or more as it was hidden, with no move event (the app warped it to its centre);
//   - it stays within a point of one place, inside a display, while move events keep coming (the app pulls it back);
//   - the viewer's own moves keep coming while it stays hidden (what this view posts, the moves above cannot tell).
// Looked at every 50 ms on the main thread with public calls only (whether the pointer is shown, the session's move
// count, where it is, the frontmost app); why it is hidden is not had (macOS says it nowhere public), so it is
// unknown, which counts as hidden. The detectors are pure (tests: PointerLockTests.swift).
import AppKit
import CoreGraphics
import Foundation

/// One look at the pointer.
struct PointerSample: Equatable {
  /// The system says it is hidden.
  var hidden: Bool
  /// Why: true an app hid it, false only typing or touch did, nil not known.
  var appHidden: Bool?
  /// Held within a rectangle smaller than the desktop (Windows' clip; no such thing on macOS: false).
  var confined = false
  var x: Double
  var y: Double
  /// The session's count of move events (any app's, this one's posted moves too), wrapping.
  var motionSerial: UInt32
  var motionObservable = true
  /// The frontmost app's process.
  var foreground: Int32
  /// Strictly inside a display, 8 points in from each of its edges.
  var interior: Bool
}

/// The passive detector: hidden, and warped or held still while moves come.
struct PointerLockDetector {
  static let enterMs = 100.0
  static let exitMs = 100.0
  static let stillMs = 100.0
  static let stillMoves = 1
  static let stillWithin = 1.0
  static let warpAtLeast = 8.0

  private(set) var locked = false
  private var last: PointerSample?
  private var lastHidden = false
  private var anchor: (x: Double, y: Double)?
  private var stillSince = 0.0
  private var moves = 0
  private var warped = false
  private var enterSince: Double?
  private var exitSince: Double?

  /// Everything forgotten.
  mutating func reset() {
    self = PointerLockDetector()
  }

  /// A sample (nil: none had) at `at` ms, while it may be held (`eligible`: the view drives the Mac); whether it is.
  mutating func take(_ sample: PointerSample?, eligible: Bool, at: Double) -> Bool {
    guard let s = sample, eligible else {
      reset()
      return false
    }
    let effective = s.hidden && s.appHidden != false
    let sameApp = last != nil && last!.foreground == s.foreground
    let stationary = sameApp && anchor != nil && abs(anchor!.x - s.x) <= Self.stillWithin && abs(anchor!.y - s.y) <= Self.stillWithin
    var hideWarp = false
    if let p = last, s.motionObservable, effective, !lastHidden, p.motionSerial == s.motionSerial {
      hideWarp = ((p.x - s.x) * (p.x - s.x) + (p.y - s.y) * (p.y - s.y)).squareRoot() >= Self.warpAtLeast
    }
    if !sameApp {
      // The frontmost app changed: whatever was seen of the one before goes.
      reset()
      stillSince = at
    }
    if hideWarp && s.interior { warped = true }
    if !effective { warped = false }
    if !stationary || !effective || !s.interior {
      stillSince = at
      anchor = (s.x, s.y)
      moves = 0
    } else if let p = last, p.motionSerial != s.motionSerial {
      moves += 1
    }
    let motionLock = s.motionObservable && s.interior && stationary && (locked || (moves >= Self.stillMoves && at - stillSince >= Self.stillMs))
    let evidence = effective && (s.confined || motionLock || warped)
    if evidence {
      exitSince = nil
      if enterSince == nil { enterSince = at }
      if at - enterSince! >= Self.enterMs { locked = true }
    } else {
      enterSince = nil
      if exitSince == nil { exitSince = at }
      if at - exitSince! >= Self.exitMs { locked = false }
    }
    last = s
    lastHidden = effective
    return locked
  }
}

/// The viewer's own moves while the pointer stays hidden: what the passive detector cannot see of a view that posts
/// where the person's pointer is (an app pulling it back is undone by the next of them).
struct RemoteMoveDetector {
  private(set) var locked = false
  private var firstMove: Double?
  private var moves = 0
  private var releaseSince: Double?
  private var foreground: Int32?

  mutating func reset() {
    self = RemoteMoveDetector()
  }

  /// One of the viewer's moves posted (non-zero, finite), at `at` ms.
  mutating func moved(at: Double) {
    if firstMove == nil { firstMove = at }
    moves += 1
  }

  /// A move of this Mac's own mouse or trackpad: what follows is not the viewer's alone.
  mutating func physical() {
    firstMove = nil
    moves = 0
  }

  mutating func take(hidden: Bool, appHidden: Bool?, foreground: Int32, at: Double) -> Bool {
    if let f = self.foreground, f != foreground {
      reset()
    }
    self.foreground = foreground
    if !hidden || appHidden == false {
      physical()
      if releaseSince == nil { releaseSince = at }
      if locked && at - releaseSince! >= PointerLockDetector.exitMs { locked = false }
      return locked
    }
    releaseSince = nil
    if let first = firstMove, moves >= 1, at - first >= PointerLockDetector.enterMs { locked = true }
    return locked
  }
}

/// A view's watch of the pointer: sampled every 50 ms on the main thread while the view lasts, said as it changes.
final class PointerLockWatch {
  static let interval = 0.05
  /// The pointer's visibility as Core Graphics says it (deprecated, with no public replacement; found at run time so
  /// the build says nothing of it): nil where it is not had.
  private static let cursorIsVisible: (@convention(c) () -> Int32)? = {
    guard let f = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGCursorIsVisible") else { return nil }
    return unsafeBitCast(f, to: (@convention(c) () -> Int32).self)
  }()

  let channel: Channel
  private let lock = NSLock()
  private var passive = PointerLockDetector()
  private var remote = RemoteMoveDetector()
  private var said = false
  private var timer: DispatchSourceTimer?
  private let start = DispatchTime.now().uptimeNanoseconds

  init(channel: Channel) {
    self.channel = channel
  }

  private func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 }

  /// One of the viewer's absolute moves posted (on the input's queue).
  func moved() {
    lock.lock()
    remote.moved(at: now())
    lock.unlock()
  }

  func begin() {
    guard Self.cursorIsVisible != nil else { return }
    let t = DispatchSource.makeTimerSource(queue: .main)
    t.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .milliseconds(5))
    t.setEventHandler { [weak self] in self?.look() }
    t.resume()
    timer = t
  }

  func end() {
    timer?.cancel()
    timer = nil
  }

  /// What the pointer is now.
  static func sample() -> PointerSample? {
    guard let visible = cursorIsVisible, let at = CGEvent(source: nil)?.location else { return nil }
    let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
    let serial = types.reduce(UInt32(0)) { $0 &+ CGEventSource.counterForEventType(.combinedSessionState, eventType: $1) }
    var count: UInt32 = 0
    var displays = [CGDirectDisplayID](repeating: 0, count: 16)
    CGGetActiveDisplayList(16, &displays, &count)
    let interior = displays.prefix(Int(count)).contains { id in
      let b = CGDisplayBounds(id)
      return at.x > b.minX + 8 && at.x < b.maxX - 8 && at.y > b.minY + 8 && at.y < b.maxY - 8
    }
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    return PointerSample(hidden: visible() == 0, appHidden: nil, x: at.x, y: at.y, motionSerial: serial, foreground: front, interior: interior)
  }

  private func look() {
    let s = Self.sample()
    let at = now()
    lock.lock()
    let held = passive.take(s, eligible: true, at: at)
    let moved = s.map { remote.take(hidden: $0.hidden, appHidden: $0.appHidden, foreground: $0.foreground, at: at) } ?? remote.locked
    lock.unlock()
    let locked = held || moved
    guard locked != said else { return }
    said = locked
    channel.sendJSON(4, ["pointerLock": locked])
  }
}
