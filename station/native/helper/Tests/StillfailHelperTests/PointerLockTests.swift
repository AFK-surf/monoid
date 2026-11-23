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
  // a move while shown or hidden only by typing never counts once an app hides it later
  r.moved(at: 920)
  #expect(!r.take(hidden: true, appHidden: nil, foreground: 1, at: 950))
  #expect(!r.take(hidden: true, appHidden: nil, foreground: 1, at: 1100))
  // another app in front: forgotten
  r.moved(at: 1110)
  #expect(!r.take(hidden: true, appHidden: nil, foreground: 2, at: 1250))
}

@Test
func aMoveBeforeHidingCountsForNothingWhenHeldStillAfter() {
  let d = Passive()
  #expect(!d.take(s(hidden: false, x: 500, y: 400, serial: 5), eligible: true, at: 0))
  // moved slightly while still shown, then hidden (as typing hides it after the pointer stops): no move while hidden
  for t in stride(from: 50.0, through: 500, by: 50) {
    #expect(!d.take(s(hidden: true, x: 500.5, y: 400, serial: 6), eligible: true, at: t))
  }
}

/// `CGCursorIsVisible` of macOS 27.2 as SkyLight has it, at `cgBase`.
private let cgBase = 0x1_9931_8b2c
private let cg: [UInt32] = [
  0xd503237f, 0xa9bf7bfd, 0x910003fd, 0x97f3d4b5, 0xb40000c0, 0xf9400008, 0x3940bd08, 0x36000068, 0x52800000, 0x14000008,
  0x97f3d4ae, 0xb40000a0, 0xf9400008, 0x3940c108, 0x52000100, 0x14000002, 0x52800020, 0xa8c17bfd, 0xd65f0fff,
]
private let cgLayout = PointerLockWatch.CursorScoreboardLayout(target: 0x1_9900_de0c, appOffset: 0x2f, typingOffset: 0x30)

private func decode(_ insns: [UInt32], base: Int = cgBase) -> PointerLockWatch.CursorScoreboardLayout? {
  PointerLockWatch.decodeCursorScoreboard(instructions: insns, base: base)
}

/// `cg` with instruction `i` replaced.
private func cgWith(_ i: Int, _ insn: UInt32) -> [UInt32] {
  var c = cg
  c[i] = insn
  return c
}

@Test
func cgCursorIsVisibleOfMacOS27DecodesToItsScoreboard() {
  #expect(decode(cg) == cgLayout)
  // what follows the return is never read
  #expect(decode(cg + [0x9400_0010, 0x3940_0000, 0x3940_0000]) == cgLayout)
}

@Test
func anotherCallBeforeTheScoreboardsIsNotDecoded() {
  // `bl` in place of `mov x29, sp`, before the first `bl CGSScoreboard`
  #expect(decode(cgWith(2, 0x9400_0010)) == nil)
  // or put in before it, everything moved on
  var more = cg
  more.insert(0x9400_0010, at: 3)
  #expect(decode(more) == nil)
}

@Test
func callsToTwoPlacesAreNotDecoded() {
  // the second `bl` one instruction further
  #expect(decode(cgWith(10, 0x97f3_d4af)) == nil)
}

@Test
func aByteNotReadThroughTheLoadedPointerIsNotDecoded() {
  // `ldrb w8, [x9, #0x2f]` after `ldr x8, [x0]`
  #expect(decode(cgWith(6, 0x3940_bd28)) == nil)
  // `ldrb w8, [x9, #0x30]` after `ldr x8, [x0]`
  #expect(decode(cgWith(13, 0x3940_c128)) == nil)
  // `ldr xzr, [x0]`
  #expect(decode(cgWith(5, 0xf940_001f)) == nil)
}

@Test
func anotherTestOrResultIsNotDecoded() {
  // `tbnz w8, #0` is as good as `tbz`
  #expect(decode(cgWith(7, 0x3700_0068)) == cgLayout)
  // `tbz w8, #1`
  #expect(decode(cgWith(7, 0x3608_0068)) == nil)
  // `tbz w9, #0`
  #expect(decode(cgWith(7, 0x3600_0069)) == nil)
  // `eor w0, w8, #2`
  #expect(decode(cgWith(14, 0x521f_0100)) == nil)
  // `eor w0, w9, #1`
  #expect(decode(cgWith(14, 0x5200_0120)) == nil)
  // `cbnz x0` for `cbz x0`
  #expect(decode(cgWith(4, 0xb50000c0)) == nil)
}

@Test
func oneByteForBothIsNotDecoded() {
  // `ldrb w8, [x8, #0x2f]` both times
  #expect(decode(cgWith(13, 0x3940_bd08)) == nil)
}

@Test
func aReturnBeforeTheSequenceEndsIsNotDecoded() {
  #expect(decode(cgWith(12, 0xd65f_03c0)) == nil)
  #expect(decode(cgWith(14, 0xd65f_0fff)) == nil)
  #expect(decode(cgWith(8, 0xd65f_0bff)) == nil)
  // no return at all
  #expect(decode(Array(cg.dropLast())) == nil)
}

@Test
func anyRegisterIsDecodedNotX8Alone() {
  // `ldr x9, [x0]`, `ldrb w9, [x9, #off]`, `tbz w9, #0`, `eor w0, w9, #1`
  let x9 = cg.enumerated().map { i, insn -> UInt32 in
    switch i {
    case 5, 12: return 0xf940_0009
    case 6: return 0x3940_bd29
    case 7: return 0x3600_0069
    case 13: return 0x3940_c129
    case 14: return 0x5200_0120
    default: return insn
    }
  }
  #expect(decode(x9) == cgLayout)
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
