// Asking the lock screen to try its unlock rules once (the plugin, first of them, then answers from the guard).
//
// Not verified on a Mac yet: how a process of the user makes loginwindow evaluate `system.login.screensaver` without
// a person. Tried here: wake the display (one user-activity declaration, released at once) and post one pointer move
// from a private event source, as a person nudging the mouse does. If loginwindow evaluates its rules only on a
// password submitted, this is where another way goes. The posted move has a non-zero source pid, so the guard's own
// watch lets it through.
import CoreGraphics
import Foundation
import IOKit.pwr_mgt

enum Trigger {
  static func askLockScreen() {
    var activity: IOPMAssertionID = 0
    IOPMAssertionDeclareUserActivity("still.fail locked use: asking the lock screen" as CFString, kIOPMUserActiveLocal, &activity)
    if activity != 0 { IOPMAssertionRelease(activity) }
    let source = CGEventSource(stateID: .privateState)
    let here = CGEvent(source: nil)?.location ?? .zero
    CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: here.x + 1, y: here.y), mouseButton: .left)?.post(tap: .cghidEventTap)
    CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: here, mouseButton: .left)?.post(tap: .cghidEventTap)
  }
}
