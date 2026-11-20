// A display of this helper's own (Core Graphics' CGVirtualDisplay), HiDPI, for a view whose size the Mac's displays
// have no mode of (an iPad's 4:3, a phone's), or a Mac with no display at all (a Mac mini with none plugged in): made
// as the size is asked (`resolution`) or the view opens with nothing to capture, the Mac's own display mirroring it
// (what is on it shows on both), and gone again once the station puts the resolution back, the last view of it ends
// or the helper quits, so no display of it is left behind. CGVirtualDisplay is no part of the SDK's headers: its
// classes are found at run time (no private framework linked), and where macOS has them no more there is none, each
// view then on the Mac's own display as before.
import CoreGraphics
import Foundation
import ObjectiveC

final class VirtualDisplays {
  static let shared = VirtualDisplays()

  /// What a display of its own may be, in points (`Resolution.set`'s size).
  static let widths = 800...7680
  static let heights = 600...4320
  static let name = "still.fail Display"
  static let hz = 60.0
  /// Points per millimetre at a HiDPI panel's density (about 220 pixels an inch, as a Retina display's).
  static let pointsPerMillimetre = 220.0 / 25.4 / 2

  /// Whether `width`×`height` points is a display of its own's: within its bounds, and a size no mode of the Mac's
  /// own display has (`modes`, as Resolution offers them).
  static func wanted(width: Int, height: Int, modes: [(Int, Int)]) -> Bool {
    widths.contains(width) && heights.contains(height) && !modes.contains { $0 == (width, height) }
  }

  /// The pixels behind `width`×`height` points (HiDPI: twice each way), and its size in millimetres.
  static func spec(width: Int, height: Int) -> (pixelWidth: Int, pixelHeight: Int, millimetres: CGSize) {
    (width * 2, height * 2, CGSize(width: (Double(width) / pointsPerMillimetre).rounded(), height: (Double(height) / pointsPerMillimetre).rounded()))
  }

  /// Whether macOS has what makes one.
  static var available: Bool {
    ["CGVirtualDisplay", "CGVirtualDisplayDescriptor", "CGVirtualDisplaySettings", "CGVirtualDisplayMode"].allSatisfy { NSClassFromString($0) != nil }
  }

  private let lock = NSLock()
  /// The display made (its object, kept for as long as it is to be), its id, its size in points, and the Mac's own
  /// display that mirrors it (none on a Mac with none).
  private var display: NSObject?
  private(set) var id: CGDirectDisplayID?
  private(set) var size: (Int, Int)?
  private(set) var physical: CGDirectDisplayID?
  /// Views open on it.
  private var views = 0

  /// The display a view of `asked` captures: the one of its own where there is one, else `asked`.
  func shown(_ asked: CGDirectDisplayID) -> CGDirectDisplayID {
    lock.lock()
    defer { lock.unlock() }
    return id ?? asked
  }

  func owns(_ display: CGDirectDisplayID) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return id == display
  }

  /// Whether the Mac has no display to capture (none online, or the only one asleep for good: a headless Mac mini).
  static func headless() -> Bool {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    return count == 0
  }

  /// A display of its own `width`×`height` points (made, or the one there made that size), the Mac's own `physical`
  /// mirroring it; its id, nil where macOS makes none.
  func show(width: Int, height: Int, physical: CGDirectDisplayID?) -> CGDirectDisplayID? {
    lock.lock()
    defer { lock.unlock() }
    if let display, let id {
      guard VirtualDisplays.apply(display, width: width, height: height) else { return nil }
      size = (width, height)
      return id
    }
    guard VirtualDisplays.available, let made = VirtualDisplays.make(width: width, height: height) else { return nil }
    guard VirtualDisplays.apply(made.display, width: width, height: height) else { return nil }
    display = made.display
    id = made.id
    size = (width, height)
    self.physical = physical
    if let physical, physical != made.id { VirtualDisplays.mirror(physical, of: made.id) }
    return made.id
  }

  /// The display of its own gone (the Mac's own no longer mirrors it).
  func remove() {
    lock.lock()
    let had = display, mirrored = physical
    display = nil
    id = nil
    size = nil
    physical = nil
    views = 0
    lock.unlock()
    if let mirrored { VirtualDisplays.mirror(mirrored, of: kCGNullDirectDisplay) }
    // (released here: macOS takes the display away as its last reference goes)
    _ = had
  }

  /// A view opened on it, or ended: the last one's end takes it away.
  func opened() {
    lock.lock()
    if id != nil { views += 1 }
    lock.unlock()
  }

  func ended() {
    lock.lock()
    let last = id != nil && views > 0 && views - 1 == 0
    if views > 0 { views -= 1 }
    lock.unlock()
    if last { remove() }
  }

  // MARK: the classes found at run time

  private static func make(width: Int, height: Int) -> (display: NSObject, id: CGDirectDisplayID)? {
    guard let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
      let displayClass = NSClassFromString("CGVirtualDisplay") as? NSObject.Type
    else { return nil }
    let spec = spec(width: width, height: height)
    let descriptor = descriptorClass.init()
    descriptor.setValue(name, forKey: "name")
    descriptor.setValue(NSNumber(value: UInt32(spec.pixelWidth)), forKey: "maxPixelsWide")
    descriptor.setValue(NSNumber(value: UInt32(spec.pixelHeight)), forKey: "maxPixelsHigh")
    descriptor.setValue(NSValue(size: spec.millimetres), forKey: "sizeInMillimeters")
    descriptor.setValue(NSNumber(value: UInt32(0x5346)), forKey: "vendorID")
    descriptor.setValue(NSNumber(value: UInt32(0x0001)), forKey: "productID")
    descriptor.setValue(NSNumber(value: UInt32(1)), forKey: "serialNum")
    descriptor.setValue(DispatchQueue.main, forKey: "queue")
    let initWith = NSSelectorFromString("initWithDescriptor:")
    guard let method = class_getInstanceMethod(displayClass, initWith) else { return nil }
    typealias InitWith = @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<NSObject>?
    let allocated = (displayClass as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue()
    guard let allocated, let display = unsafeBitCast(method_getImplementation(method), to: InitWith.self)(allocated, initWith, descriptor)?.takeRetainedValue() else { return nil }
    guard let id = (display.value(forKey: "displayID") as? NSNumber)?.uint32Value, id != 0 else { return nil }
    return (display, id)
  }

  /// Its mode: `width`×`height` points, HiDPI, at `hz`.
  private static func apply(_ display: NSObject, width: Int, height: Int) -> Bool {
    guard let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type,
      let modeClass = NSClassFromString("CGVirtualDisplayMode") as? NSObject.Type
    else { return false }
    let spec = spec(width: width, height: height)
    let initMode = NSSelectorFromString("initWithWidth:height:refreshRate:")
    guard let method = class_getInstanceMethod(modeClass, initMode) else { return false }
    typealias InitMode = @convention(c) (AnyObject, Selector, UInt, UInt, Double) -> Unmanaged<NSObject>?
    let make = unsafeBitCast(method_getImplementation(method), to: InitMode.self)
    let mode = { (w: Int, h: Int) -> NSObject? in
      guard let a = (modeClass as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() else { return nil }
      return make(a, initMode, UInt(w), UInt(h), hz)?.takeRetainedValue()
    }
    // (the HiDPI mode's pixels, and its points as a 1x mode beside it: macOS shows the first as "looks like" the second)
    guard let sharp = mode(spec.pixelWidth, spec.pixelHeight), let plain = mode(width, height) else { return false }
    let settings = settingsClass.init()
    settings.setValue(NSNumber(value: UInt32(1)), forKey: "hiDPI")
    settings.setValue([sharp, plain], forKey: "modes")
    let applySettings = NSSelectorFromString("applySettings:")
    guard let applied = class_getInstanceMethod(type(of: display), applySettings) else { return false }
    typealias Apply = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
    return unsafeBitCast(method_getImplementation(applied), to: Apply.self)(display, applySettings, settings)
  }

  /// The Mac's own `display` mirroring `of` (kCGNullDirectDisplay: none), for this login session alone.
  private static func mirror(_ display: CGDirectDisplayID, of: CGDirectDisplayID) {
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
    guard CGConfigureDisplayMirrorOfDisplay(config, display, of) == .success else {
      CGCancelDisplayConfiguration(config)
      return
    }
    CGCompleteDisplayConfiguration(config, .forSession)
  }
}
