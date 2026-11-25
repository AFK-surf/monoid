// The cover over every display while an unlock is out: above everything, on every Space, never key, letting the
// Helper's posted clicks through to what is under it (a person's own input never gets that far: Watch swallows it).
// Agent views capture without it (ScreenCaptureKit excludes this app); people see it, never the desktop.
import AppKit

@MainActor
final class Cover {
  private var windows: [NSWindow] = []
  private var screensObserver: NSObjectProtocol?

  var shown: Bool { !windows.isEmpty }

  func show() {
    guard windows.isEmpty else { return }
    place()
    // Displays come and go: the cover follows them.
    screensObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.place() }
    }
  }

  /// Only once the screen is checked locked (or was never unlocked): never a desktop shown in between.
  func hide() {
    for w in windows { w.orderOut(nil) }
    windows = []
    if let screensObserver { NotificationCenter.default.removeObserver(screensObserver) }
    screensObserver = nil
  }

  private func place() {
    for w in windows { w.orderOut(nil) }
    windows = NSScreen.screens.map { screen in
      let w = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
      w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
      w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
      w.ignoresMouseEvents = true
      w.isOpaque = true
      w.hasShadow = false
      w.backgroundColor = NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.08, alpha: 1)
      w.sharingType = .readOnly
      let label = NSTextField(labelWithString: "still.fail 的代理正在使用这台 Mac · 按任意键或点一下即锁定\nA still.fail agent is using this Mac. Press any key or click to lock it.")
      label.alignment = .center
      label.textColor = .white
      label.font = .systemFont(ofSize: 22, weight: .medium)
      label.maximumNumberOfLines = 2
      label.translatesAutoresizingMaskIntoConstraints = false
      let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
      view.addSubview(label)
      NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: view.centerXAnchor), label.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
      w.contentView = view
      w.setFrame(screen.frame, display: true)
      w.orderFrontRegardless()
      return w
    }
  }
}
