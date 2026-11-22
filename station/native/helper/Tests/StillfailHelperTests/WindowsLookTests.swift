import CoreGraphics
import Foundation
import Testing
import VideoToolbox
@testable import StillfailHelper

/// A window as CGWindowListCopyWindowInfo lists it.
private func info(_ id: Int, pid: Int = 100, title: String = "t", app: String = "App", layer: Int = 0, _ rect: CGRect = CGRect(x: 10, y: 20, width: 800, height: 600)) -> [String: Any] {
  [
    kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid, kCGWindowName as String: title,
    kCGWindowOwnerName as String: app, kCGWindowLayer as String: layer, kCGWindowBounds as String: rect.dictionaryRepresentation,
  ]
}

private let own: pid_t = 7

@Test
func theFirstLookAsksAndTheSameWindowsAskNothing() {
  let infos = [info(2), info(1, title: "a")]
  let first = ScreenView.look(infos, own: own, shown: nil, frame: nil, seen: nil)
  #expect(first.ask)
  #expect(first.seen.map(\.id) == [1, 2])
  #expect(first.shown == .same)
  let again = ScreenView.look(infos.reversed(), own: own, shown: nil, frame: nil, seen: first.seen)
  #expect(!again.ask)
  #expect(again.seen == first.seen)
}

@Test
func aWindowDraggedAsksNothing() {
  let seen = ScreenView.look([info(1)], own: own, shown: nil, frame: nil, seen: nil).seen
  let dragged = ScreenView.look([info(1, CGRect(x: 300, y: 200, width: 900, height: 700))], own: own, shown: nil, frame: nil, seen: seen)
  #expect(!dragged.ask)
}

@Test
func aWindowComingGoingOrRenamedAsks() {
  let seen = ScreenView.look([info(1), info(2)], own: own, shown: nil, frame: nil, seen: nil).seen
  #expect(ScreenView.look([info(1), info(2), info(3)], own: own, shown: nil, frame: nil, seen: seen).ask)
  #expect(ScreenView.look([info(1)], own: own, shown: nil, frame: nil, seen: seen).ask)
  #expect(ScreenView.look([info(1), info(2, title: "other")], own: own, shown: nil, frame: nil, seen: seen).ask)
  #expect(ScreenView.look([info(1), info(2, app: "Other")], own: own, shown: nil, frame: nil, seen: seen).ask)
}

@Test
func onlyWindowsThatCouldBeSaidCount() {
  let seen = ScreenView.look([info(1)], own: own, shown: nil, frame: nil, seen: nil).seen
  // a menu bar's, this app's own, a sliver: none could be said, so none asks
  let others = [info(1), info(5, layer: 25), info(6, pid: Int(own)), info(7, CGRect(x: 0, y: 0, width: 40, height: 600)), info(8, CGRect(x: 0, y: 0, width: 400, height: 30))]
  let look = ScreenView.look(others, own: own, shown: nil, frame: nil, seen: seen)
  #expect(!look.ask)
  #expect(look.seen.map(\.id) == [1])
}

@Test
func theWindowShownAloneIsFollowed() {
  let at = CGRect(x: 10, y: 20, width: 800, height: 600)
  let seen = ScreenView.look([info(1, at)], own: own, shown: 1, frame: at, seen: nil).seen
  let still = ScreenView.look([info(1, at)], own: own, shown: 1, frame: at, seen: seen)
  #expect(still.shown == .same)
  #expect(!still.ask)
  let moved = CGRect(x: 110, y: 120, width: 800, height: 600)
  #expect(ScreenView.look([info(1, moved)], own: own, shown: 1, frame: at, seen: seen).shown == .moved(moved, resized: false))
  let resized = CGRect(x: 10, y: 20, width: 1000, height: 600)
  let look = ScreenView.look([info(1, resized)], own: own, shown: 1, frame: at, seen: seen)
  #expect(look.shown == .moved(resized, resized: true))
  #expect(!look.ask)
  let closed = ScreenView.look([info(2)], own: own, shown: 1, frame: at, seen: seen)
  #expect(closed.shown == .gone)
  #expect(closed.ask)
  // shrunk to a sliver it is still followed (not one that could be said, but on screen)
  let sliver = CGRect(x: 10, y: 20, width: 50, height: 40)
  #expect(ScreenView.look([info(1, sliver)], own: own, shown: 1, frame: at, seen: seen).shown == .moved(sliver, resized: true))
}

@Test
func h264AsksForHighFirstThenFallsBack() {
  #expect(ScreenView.profiles("h264") == [
    kVTProfileLevel_H264_High_AutoLevel, kVTProfileLevel_H264_ConstrainedHigh_AutoLevel, kVTProfileLevel_H264_Main_AutoLevel,
    kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel, kVTProfileLevel_H264_Baseline_AutoLevel,
  ])
  #expect(ScreenView.profiles("h265") == [kVTProfileLevel_HEVC_Main_AutoLevel])
}
