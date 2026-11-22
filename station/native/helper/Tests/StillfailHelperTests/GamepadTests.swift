import Testing
@testable import StillfailHelper

@Test
func aSticksRestIsNoMove() {
  #expect(Gamepads.past(0.1) == 0)
  #expect(Gamepads.past(-0.15) == 0)
  #expect(Gamepads.past(1) == 1)
  #expect(Gamepads.past(-1) == -1)
  var s = PadState()
  s.lx = 0.1
  #expect(!s.moving)
  s.ry = -0.5
  #expect(s.moving)
}

@Test
func aSticksStepGrowsWithItsTravelSquared() {
  var s = PadState()
  s.lx = 1
  s.ly = -1
  let full = Gamepads.step(s, dt: 1)
  #expect(full.dx == Gamepads.pointerSpeed)
  #expect(full.dy == -Gamepads.pointerSpeed)
  s.lx = Gamepads.deadZone + (1 - Gamepads.deadZone) / 2
  #expect(abs(Gamepads.step(s, dt: 1).dx - Gamepads.pointerSpeed / 4) < 1e-9)
}

@Test
func triggersPressPastHalfWay() {
  var s = PadState(["buttons": 1 << 6, "lt": 0.2, "rt": 0.8])
  #expect(s.held & (1 << 6) == 0)
  #expect(s.held & (1 << 7) != 0)
  s.buttons = 1
  #expect(s.held & 1 != 0)
}

@Test
func whatChangesIsPressedAndLetGo() {
  let c = Gamepads.changes(from: 0b101, to: 0b110)
  #expect(c.map { $0.0 } == [.a, .b])
  #expect(c.map { $0.1 } == [false, true])
}
