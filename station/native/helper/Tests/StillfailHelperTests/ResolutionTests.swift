import Testing
@testable import StillfailHelper

/// A mode: its size in points, the pixels behind it (×`scale`), its rate.
private func m(_ id: Int32, _ width: Int, _ height: Int, scale: Int = 1, hz: Int = 60, usable: Bool = true) -> DisplayMode {
  DisplayMode(id: id, width: width, height: height, pixelWidth: width * scale, pixelHeight: height * scale, hz: hz, usable: usable)
}

private func sizes(_ s: [(Int, Int)]) -> [[Int]] { s.map { [$0.0, $0.1] } }

@Test
func aRetinaDisplayIsOfferedItsHiDPIModesAlone() {
  // A MacBook Pro's panel: the scaled sizes at 2x, and the same sizes again at 1x (blurred), which are left out.
  let now = m(1, 1512, 982, scale: 2, hz: 120)
  let all = [
    now, m(2, 1800, 1169, scale: 2, hz: 120), m(3, 1352, 878, scale: 2, hz: 120), m(4, 1147, 745, scale: 2, hz: 120),
    m(5, 1512, 982, hz: 120), m(6, 3024, 1964, hz: 120), m(7, 1024, 665, hz: 120),
  ]
  #expect(sizes(Resolution.offered(all, now: now)) == [[1800, 1169], [1512, 982], [1352, 878], [1147, 745]])
}

@Test
func anExternalDisplayAt1xIsOfferedIts1xModes() {
  let now = m(1, 1920, 1080)
  let all = [now, m(2, 1920, 1080, hz: 75), m(3, 1680, 1050), m(4, 1280, 720), m(5, 960, 540, scale: 2)]
  #expect(sizes(Resolution.offered(all, now: now)) == [[1920, 1080], [1680, 1050], [1280, 720]])
  // A display that lists none alike: every size it has.
  #expect(sizes(Resolution.offered([m(2, 1280, 800, scale: 2)], now: m(1, 2560, 1600))) == [[2560, 1600], [1280, 800]])
}

@Test
func narrowUprightAndUnusableModesAreNotOffered() {
  let now = m(1, 1920, 1080)
  let all = [m(2, 640, 480), m(3, 1080, 1920), m(4, 1600, 900, usable: false), m(5, 1024, 768), m(6, 1600, 1200), m(7, 1680, 1050)]
  // (the largest first, each once)
  #expect(sizes(Resolution.offered(all + [m(8, 1680, 1050, hz: 50)], now: now)) == [[1920, 1080], [1600, 1200], [1680, 1050], [1024, 768]])
}

@Test
func theCurrentModeIsOfferedEvenUnlisted() {
  #expect(sizes(Resolution.offered([], now: m(1, 1366, 768))) == [[1366, 768]])
  // An upright one too; of two as large, the wider first.
  #expect(sizes(Resolution.offered([m(2, 1920, 1080)], now: m(1, 1080, 1920))) == [[1920, 1080], [1080, 1920]])
}

@Test
func theModePutBackIsTheOneItWas() {
  let now = m(1, 1800, 1169, scale: 2, hz: 120)
  let all = [now, m(2, 1512, 982, scale: 2, hz: 120), m(3, 1512, 982, scale: 2, hz: 60), m(4, 1512, 982, hz: 120)]
  #expect(Resolution.chosen(all, now: now, width: 1512, height: 982, modeID: 3)?.id == 3)
  // Another size's id, or one not listed: chosen as without it.
  #expect(Resolution.chosen(all, now: now, width: 1512, height: 982, modeID: 1)?.id == 2)
  #expect(Resolution.chosen(all, now: now, width: 1512, height: 982, modeID: 99)?.id == 2)
}

@Test
func theModeSetKeepsHiDPIThePixelsAndTheRateWhereItCan() {
  let now = m(1, 1512, 982, scale: 2, hz: 120)
  let all = [
    now, m(2, 1800, 1169, hz: 120), m(3, 1800, 1169, scale: 2, hz: 60), m(4, 1800, 1169, scale: 2, hz: 120),
    m(5, 1280, 800, scale: 2, hz: 60), m(6, 1280, 800, scale: 2, hz: 48), m(7, 1280, 800, hz: 60),
    DisplayMode(id: 8, width: 1280, height: 800, pixelWidth: 2048, pixelHeight: 1280, hz: 60, usable: true),
    m(9, 1024, 640, scale: 2, hz: 120, usable: false),
  ]
  // HiDPI as now, at its rate.
  #expect(Resolution.chosen(all, now: now, width: 1800, height: 1169)?.id == 4)
  // The most pixels behind the size; no 120 Hz there, the highest it has.
  #expect(Resolution.chosen(all, now: now, width: 1280, height: 800)?.id == 5)
  // A display at 1x keeps to 1x.
  #expect(Resolution.chosen(all, now: m(10, 1920, 1080, hz: 120), width: 1800, height: 1169)?.id == 2)
  // A rate of 0 (a variable one): the highest.
  #expect(Resolution.chosen(all, now: m(11, 1512, 982, scale: 2, hz: 0), width: 1800, height: 1169)?.id == 4)
  #expect(Resolution.chosen(all, now: now, width: 1024, height: 640) == nil)
  #expect(Resolution.chosen(all, now: now, width: 1000, height: 600) == nil)
}
