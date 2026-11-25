// A person at the Mac while an unlock is out: seen at the HID layer (IOHIDManager: the devices themselves, which
// posted events never pass through) and kept from the apps under the cover (an event tap swallowing every event of a
// device, source pid 0; posted ones, the Helper's and a task's own, go on). Either one seeing a person relocks.
//
// Known gaps (Universal Control, remapping drivers that repost a device's events as their own) are refused before an
// unlock starts where they can be seen (`universalControl`), and named in AGENTS.md.
import AppKit
import CoreGraphics
import IOKit.hid

final class Watch {
  private var manager: IOHIDManager?
  private var tap: CFMachPort?
  private var source: CFRunLoopSource?
  private let heard: () -> Void

  /// `heard` runs on the main queue, at most once per burst, never inside the tap's callback.
  init(heard: @escaping () -> Void) {
    self.heard = heard
  }

  private var told = false
  private func tell() {
    guard !told else { return }
    told = true
    DispatchQueue.main.async { self.heard() }
  }

  /// False when either part could not start (the unlock is then refused: half a watch is none).
  func start() -> Bool {
    told = false
    let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let pages: [[String: Int]] = [
      [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard],
      [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keypad],
      [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse],
      [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Pointer],
      [kIOHIDDeviceUsagePageKey: kHIDPage_Digitizer],
      [kIOHIDDeviceUsagePageKey: kHIDPage_Consumer],
    ]
    IOHIDManagerSetDeviceMatchingMultiple(m, pages as CFArray)
    let me = Unmanaged.passUnretained(self).toOpaque()
    IOHIDManagerRegisterInputValueCallback(m, { context, _, _, _ in
      guard let context else { return }
      Unmanaged<Watch>.fromOpaque(context).takeUnretainedValue().tell()
    }, me)
    // A device plugged in while an unlock is out is a person too (a keyboard brought to the Mac).
    var started = false
    IOHIDManagerRegisterDeviceMatchingCallback(m, { context, _, _, _ in
      guard let context else { return }
      let watch = Unmanaged<Watch>.fromOpaque(context).takeUnretainedValue()
      if watch.armedForDevices { watch.tell() }
    }, me)
    IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    guard IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return false }
    manager = m
    // The devices there now are matched at once; only those after count.
    DispatchQueue.main.async { self.armedForDevices = true }
    started = true

    let mask: CGEventMask = [
      CGEventType.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
      .otherMouseDown, .otherMouseUp, .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel,
    ].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) } | (1 << 29) /* gesture */ | (1 << 14) /* NX_SYSDEFINED */
    guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
      guard let context else { return Unmanaged.passUnretained(event) }
      let watch = Unmanaged<Watch>.fromOpaque(context).takeUnretainedValue()
      if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        // Never turned on again: input might have gone through while it was off.
        watch.tell()
        return Unmanaged.passUnretained(event)
      }
      if event.getIntegerValueField(.eventSourceUnixProcessID) == 0 {
        watch.tell()
        return nil
      }
      return Unmanaged.passUnretained(event)
    }, userInfo: me) else {
      stop()
      return false
    }
    tap = t
    source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: t, enable: true)
    return started
  }

  private var armedForDevices = false

  func stop() {
    armedForDevices = false
    if let tap {
      CGEvent.tapEnable(tap: tap, enable: false)
      if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
      CFMachPortInvalidate(tap)
    }
    tap = nil
    source = nil
    if let manager {
      IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
      IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }
    manager = nil
  }

  /// Universal Control on: another Mac's or iPad's keyboard and pointer reach this one as posted events.
  static func universalControl() -> Bool {
    let defaults = UserDefaults(suiteName: "com.apple.universalcontrol")
    return defaults?.object(forKey: "Disable") as? Bool != true && NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.universalcontrol").isEmpty == false
  }
}
