import Testing
@testable import StillfailHelper

/// A pointer hidden (or not) at the middle of a display, its move count `serial`.
private func s(hidden: Bool = true, why: Bool? = nil, x: Double = 500, y: Double = 400, serial: UInt32 = 0, app: Int32 = 7, interior: Bool = true) -> PointerSample {
  PointerSample(hidden: hidden, appHidden: why, x: x, y: y, motionSerial: serial, foreground: app, interior: interior)
}

/// A detector to ask in `#expect` (which takes no mutating call of a value).
private final class Passive {
  var d = PointerLockDetector()
  func take(_ s: PointerSample?, eligible: Bool, at: Double) -> Bool { d.take(s, eligible: eligible, at: at) }
}

private final class Remote {
  var r = RemoteMoveDetector()
  func moved(at: Double) { r.moved(at: at) }
  func take(hidden: Bool, appHidden: Bool?, foreground: Int32, at: Double) -> Bool { r.take(hidden: hidden, appHidden: appHidden, foreground: foreground, at: at) }
}

private final class Carried {
  var c = DeltaCarry()
  func take(_ v: Double) -> Int64 { c.take(v) }
}

@Test
func hiddenAndHeldStillWhileMovesComeIsHeldAfterItsWait() {
  let d = Passive()
  #expect(!d.take(s(serial: 0), eligible: true, at: 0))
  #expect(!d.take(s(serial: 1), eligible: true, at: 50))
  #expect(!d.take(s(serial: 1), eligible: true, at: 100))
  #expect(!d.take(s(serial: 1), eligible: true, at: 199.999))
  #expect(d.take(s(serial: 1), eligible: true, at: 200))
  // still, no moves, held: a player not moving the mouse keeps it
  #expect(d.take(s(serial: 1), eligible: true, at: 300))
  // shown again: it lets go 100 ms after
  #expect(d.take(s(hidden: false, serial: 1), eligible: true, at: 350))
  #expect(d.take(s(hidden: false, serial: 1), eligible: true, at: 449.999))
  #expect(!d.take(s(hidden: false, serial: 1), eligible: true, at: 450))
}

@Test
func aPointerHiddenWithNoMovesIsNeverHeld() {
  // a video, a slideshow, typing
  let d = Passive()
  for t in stride(from: 0.0, through: 2000, by: 50) { #expect(!d.take(s(serial: 3), eligible: true, at: t)) }
}

@Test
func movesNearADisplaysEdgeCountForNothing() {
  let d = Passive()
  for (i, t) in stride(from: 0.0, through: 1000, by: 50).enumerated() { #expect(!d.take(s(serial: UInt32(i), interior: false), eligible: true, at: t)) }
}

@Test
func aPointerMovingWhileHiddenIsNotHeld() {
  // moving normally, or drifting half a point a sample, its count rising: the anchor goes with it
  let d = Passive()
  for (i, t) in stride(from: 0.0, through: 1000, by: 50).enumerated() {
    #expect(!d.take(s(x: 500 + Double(i) * 0.5 * 3, serial: UInt32(i)), eligible: true, at: t))
  }
}

@Test
func aJumpAsItHidesWithNoMoveIsAWarp() {
  let d = Passive()
  #expect(!d.take(s(hidden: false, x: 100, y: 100, serial: 5), eligible: true, at: 0))
  // hidden and at the window's centre, no move event between: the app warped it
  #expect(!d.take(s(x: 500, y: 400, serial: 5), eligible: true, at: 50))
  #expect(!d.take(s(x: 520, y: 410, serial: 9), eligible: true, at: 100))
  #expect(d.take(s(x: 480, y: 390, serial: 12), eligible: true, at: 150))
}

@Test
func hiddenWhileTypingIsNeverHeldWhateverElse() {
  let d = Passive()
  #expect(!d.take(s(hidden: false, x: 100, y: 100, serial: 5), eligible: true, at: 0))
  for (i, t) in stride(from: 50.0, through: 1000, by: 50).enumerated() { #expect(!d.take(s(why: false, serial: 5 + UInt32(i)), eligible: true, at: t)) }
}

@Test
func anotherAppInFrontForgetsAllAtOnce() {
  let d = Passive()
  _ = d.take(s(serial: 0), eligible: true, at: 0)
  _ = d.take(s(serial: 1), eligible: true, at: 50)
  _ = d.take(s(serial: 1), eligible: true, at: 100)
  #expect(d.take(s(serial: 1), eligible: true, at: 200))
  #expect(!d.take(s(serial: 1, app: 8), eligible: true, at: 250))
  #expect(!d.take(s(serial: 1, app: 8), eligible: true, at: 400))
}

@Test
func notEligibleOrNoSampleForgetsIt() {
  let d = Passive()
  _ = d.take(s(serial: 0), eligible: true, at: 0)
  _ = d.take(s(serial: 1), eligible: true, at: 50)
  _ = d.take(s(serial: 1), eligible: true, at: 100)
  #expect(d.take(s(serial: 1), eligible: true, at: 200))
  #expect(!d.take(nil, eligible: true, at: 250))
  #expect(!d.take(s(serial: 1), eligible: true, at: 300))
  #expect(!d.take(s(serial: 1), eligible: false, at: 600))
}

@Test
func heldAgainAfterLetGoTakesItsSignsAnew() {
  let d = Passive()
  _ = d.take(s(serial: 0), eligible: true, at: 0)
  _ = d.take(s(serial: 1), eligible: true, at: 50)
  _ = d.take(s(serial: 1), eligible: true, at: 100)
  #expect(d.take(s(serial: 1), eligible: true, at: 200))
  _ = d.take(s(hidden: false, serial: 1), eligible: true, at: 250)
  #expect(!d.take(s(hidden: false, serial: 1), eligible: true, at: 350))
  // hidden again where it was, absolute moves only: nothing of before carries
  #expect(!d.take(s(x: 501, serial: 2), eligible: true, at: 400))
  #expect(!d.take(s(x: 503, serial: 3), eligible: true, at: 450))
}

@Test
func theViewersOwnMovesWhileHiddenHoldIt() {
  let r = Remote()
  #expect(!r.take(hidden: true, appHidden: nil, foreground: 1, at: 0))
  r.moved(at: 10)
  #expect(!r.take(hidden: true, appHidden: nil, foreground: 1, at: 50))
  #expect(!r.take(hidden: true, appHidden: nil, foreground: 1, at: 109.9))
  #expect(r.take(hidden: true, appHidden: nil, foreground: 1, at: 110))
  // held with no more moves
  #expect(r.take(hidden: true, appHidden: nil, foreground: 1, at: 500))
  // shown: let go of 100 ms after
  #expect(r.take(hidden: false, appHidden: nil, foreground: 1, at: 550))
  #expect(!r.take(hidden: false, appHidden: nil, foreground: 1, at: 650))
  // hidden only by typing: never
  r.moved(at: 700)
  #expect(!r.take(hidden: true, appHidden: false, foreground: 1, at: 900))
  // another app in front: forgotten
  r.moved(at: 950)
  _ = r.take(hidden: true, appHidden: nil, foreground: 1, at: 960)
  #expect(!r.take(hidden: true, appHidden: nil, foreground: 2, at: 1100))
}

@Test
func movesAddUpToTheirWholePixels() {
  let c = Carried()
  var sum: Int64 = 0
  for _ in 0..<100 { sum += c.take(0.3) }
  #expect(sum == 30)
  #expect(c.take(.nan) == 0)
  #expect(c.take(-2.6) == -3)
}

@Test
func aPointersPlaceIsBelowTheEdgeAsFloat32() {
  #expect(ScreenInput.below(1439.9999999, 1440) < 1440)
  #expect(ScreenInput.below(1439.9999999, 1440) <= 1439.9999999)
  #expect(ScreenInput.below(12.5, 1440) == 12.5)
}
