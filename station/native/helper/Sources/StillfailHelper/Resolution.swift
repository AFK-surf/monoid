// A display's resolution (System Settings › Displays: "Looks like 1512×982"), read and set as Settings does (the
// helper's `resolution` op, Daemon.swift): the modes Core Graphics lists for it, the scaled HiDPI ones among them
// (`kCGDisplayShowDuplicateLowResolutionModes`), one set for this login session alone (`.forSession`: nothing
// outlasts it should the station go before putting it back). Sizes are in points, as Settings names them; Windows'
// stillfail-screen says pixels (station/native/screen/src/resolution.rs), the same shapes either way.
import CoreGraphics
import Foundation

/// A mode as Core Graphics lists it: its size in points and in the pixels behind them, its rate (0 where the panel's
/// is variable), whether it is one for a desktop.
struct DisplayMode: Equatable {
  let id: Int32
  let width: Int
  let height: Int
  let pixelWidth: Int
  let pixelHeight: Int
  let hz: Int
  let usable: Bool
  var hiDPI: Bool { pixelWidth > width }
  var pixels: Int { pixelWidth * pixelHeight }
}

extension DisplayMode {
  init(_ mode: CGDisplayMode) {
    self.init(
      id: mode.ioDisplayModeID, width: mode.width, height: mode.height, pixelWidth: mode.pixelWidth,
      pixelHeight: mode.pixelHeight, hz: Int(mode.refreshRate.rounded()), usable: mode.isUsableForDesktopGUI())
  }
}

enum Resolution {
  /// The least width a mode offered has (resolution.rs `LEAST_WIDTH`).
  static let leastWidth = 800

  /// The sizes worth offering of `all`, as `now` is: for a desktop, landscape, at least `leastWidth` wide, HiDPI where
  /// `now` is and the display has such (a Retina display is never offered its blurred 1x modes), each once, the
  /// largest first; the current one always among them.
  static func offered(_ all: [DisplayMode], now: DisplayMode) -> [(Int, Int)] {
    let fit = all.filter { $0.usable && $0.width >= leastWidth && $0.width > $0.height }
    let alike = fit.filter { $0.hiDPI == now.hiDPI }
    var sizes = (alike.isEmpty ? fit : alike).map { ($0.width, $0.height) }
    sizes.append((now.width, now.height))
    sizes.sort { ($0.0 * $0.1, $0.0) > ($1.0 * $1.1, $1.0) }
    var once: [(Int, Int)] = []
    for size in sizes where once.last.map({ $0 != size }) ?? true { once.append(size) }
    return once
  }

  /// The mode of `all` to set for `width`×`height`: `modeID` where it is that size (the one put back, as it was);
  /// else HiDPI as `now` is where the size has it, the most pixels behind it, `now`'s rate where it has it, else the
  /// highest; nil when the display lists no such size.
  static func chosen(_ all: [DisplayMode], now: DisplayMode, width: Int, height: Int, modeID: Int32? = nil) -> DisplayMode? {
    if let modeID, let same = all.first(where: { $0.id == modeID && $0.width == width && $0.height == height }) { return same }
    let sized = all.filter { $0.usable && $0.width == width && $0.height == height }
    let alike = sized.filter { $0.hiDPI == now.hiDPI }
    let pool = alike.isEmpty ? sized : alike
    guard let most = pool.map(\.pixels).max() else { return nil }
    let sharpest = pool.filter { $0.pixels == most }
    if now.hz > 0, let rate = sharpest.first(where: { $0.hz == now.hz }) { return rate }
    return sharpest.max { $0.hz < $1.hz }
  }

  /// The display's mode now and every mode it lists, HiDPI ones too.
  static func modes(_ display: CGDirectDisplayID) -> (CGDisplayMode, [CGDisplayMode])? {
    guard let now = CGDisplayCopyDisplayMode(display) else { return nil }
    let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
    return (now, (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode]) ?? [])
  }

  /// `{width, height, modeID, modes: [{width, height}…]}` of `display`, or `{error}`.
  static func read(_ display: CGDirectDisplayID) -> [String: Any] {
    guard let had = modes(display) else { return ["error": "macOS did not say the display's mode"] }
    let (now, all) = had
    let current = DisplayMode(now)
    let sizes = offered(all.map(DisplayMode.init), now: current)
    return ["width": current.width, "height": current.height, "modeID": Int(current.id), "modes": sizes.map { ["width": $0.0, "height": $0.1] }]
  }

  /// Sets `display` to `width`×`height` (one of its modes, `modeID` where given), then says it as `read` does.
  static func set(_ display: CGDirectDisplayID, width: Int, height: Int, modeID: Int32? = nil) -> [String: Any] {
    guard let had = modes(display) else { return ["error": "macOS did not say the display's mode"] }
    let (now, all) = had
    let listed = all.map(DisplayMode.init)
    let current = DisplayMode(now)
    guard let want = chosen(listed, now: current, width: width, height: height, modeID: modeID), let at = listed.firstIndex(of: want) else {
      return ["error": "\(width)×\(height) is not a mode of this display"]
    }
    if want.id != current.id {
      var config: CGDisplayConfigRef?
      guard CGBeginDisplayConfiguration(&config) == .success, let config else { return ["error": "macOS did not begin the display's configuration"] }
      let given = CGConfigureDisplayWithDisplayMode(config, display, all[at], nil)
      if given != .success {
        CGCancelDisplayConfiguration(config)
        return ["error": "macOS did not take \(width)×\(height) (\(given.rawValue))"]
      }
      let done = CGCompleteDisplayConfiguration(config, .forSession)
      if done != .success { return ["error": "macOS did not take \(width)×\(height) (\(done.rawValue))"] }
    }
    return read(display)
  }
}
