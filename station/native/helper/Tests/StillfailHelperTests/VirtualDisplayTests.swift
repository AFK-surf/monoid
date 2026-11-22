import CoreGraphics
import Testing
@testable import StillfailHelper

@Test
func aDisplayOfItsOwnIsForASizeTheMacsHasNoModeOf() {
  let modes = [(1800, 1169), (1512, 982), (1352, 878)]
  #expect(!VirtualDisplays.wanted(width: 1512, height: 982, modes: modes))
  #expect(VirtualDisplays.wanted(width: 1366, height: 1024, modes: modes))
  #expect(!VirtualDisplays.wanted(width: 640, height: 480, modes: modes))
  #expect(!VirtualDisplays.wanted(width: 8000, height: 2000, modes: modes))
  #expect(!VirtualDisplays.wanted(width: 1000, height: 5000, modes: modes))
  #expect(VirtualDisplays.wanted(width: 800, height: 600, modes: []))
}

@Test
func itsPixelsAreTwiceItsPoints() {
  let spec = VirtualDisplays.spec(width: 1366, height: 1024)
  #expect(spec.pixelWidth == 2732)
  #expect(spec.pixelHeight == 2048)
  #expect(spec.millimetres.width > 300 && spec.millimetres.width < 330)
}

@Test
func noDisplayOfItsOwnIsShownWhileNoneIsMade() {
  #expect(VirtualDisplays.shared.shown(5) == 5)
  #expect(!VirtualDisplays.shared.owns(5))
}
