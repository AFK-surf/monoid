// What the guard asks of macOS: is the screen locked, how long since a person touched the Mac, does an app hold
// Secure Event Input, and the lock itself.
import AppKit
import Carbon
import CoreGraphics
import Foundation
import IOKit
import IOKit.pwr_mgt
import os

let log = Logger(subsystem: "fail.still.lockeduse", category: "guard")

enum System {
  /// The session's own word (never a notification: any process of the user can post those).
  static func locked() -> Bool {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
    return (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue == true
  }

  /// Whether this session is the one on the console (switched away to the login window: it is not).
  static func onConsole() -> Bool {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return (session[kCGSessionOnConsoleKey as String] as? NSNumber)?.boolValue == true
  }

  /// Seconds since the last input of a person (IOHIDSystem's HIDIdleTime); 0 when unknown (taken as just touched).
  static func idle() -> Double {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
    guard service != 0 else { return 0 }
    defer { IOObjectRelease(service) }
    guard let ns = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
    else { return 0 }
    return ns.doubleValue / 1_000_000_000
  }

  static func secureInput() -> Bool { IsSecureEventInputEnabled() }

  /// `CLOCK_UPTIME_RAW` in seconds: deadlines that correcting the time does not move.
  static func uptime() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000 }

  static func boot() -> String {
    var size = 0
    sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0)
    var bytes = [CChar](repeating: 0, count: max(size, 1))
    sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0)
    return String(cString: bytes)
  }

  private static let login = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY)

  private static func call(_ name: String) -> Bool {
    guard let login, let f = dlsym(login, name) else { return false }
    typealias Fn = @convention(c) () -> Int32
    _ = unsafeBitCast(f, to: Fn.self)()
    return true
  }

  /// Lock the screen, by every way there is until one is seen to hold (each checked against the session): the lock
  /// screen, then the login window, then the display put to sleep (its password asked on waking). False when none was
  /// seen to: the cover stays, and the station is told.
  static func lock(wait: (Double) -> Bool) -> Bool {
    if call("SACLockScreenImmediate"), wait(2) { return true }
    if call("SACSwitchToLoginWindow"), wait(2), !onConsole() { return true }
    let pmset = Process()
    pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    pmset.arguments = ["displaysleepnow"]
    try? pmset.run()
    pmset.waitUntilExit()
    return wait(2)
  }

  /// The display kept on and the Mac awake while an unlock is out: one assertion each, released at its end. Never a
  /// repeated user activity (that wakes a locked display over and over).
  final class Awake {
    private var display: IOPMAssertionID = 0
    private var system: IOPMAssertionID = 0
    init() {
      let reason = "still.fail locked use" as CFString
      IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &display)
      IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &system)
    }
    func release() {
      if display != 0 { IOPMAssertionRelease(display) }
      if system != 0 { IOPMAssertionRelease(system) }
      display = 0
      system = 0
    }
    deinit { release() }
  }
}
