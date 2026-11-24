import Foundation
import Testing
@testable import StillfailHelper

@Test
func aCommandsOutputIsWhatItWroteToItsStdout() async {
  #expect(await SimulatorView.runOutput("/bin/sh", ["-c", "printf 'Device Name: primary\\nUI Orientation: Portrait\\n'"]) == "Device Name: primary\nUI Orientation: Portrait\n")
  #expect(await SimulatorView.runOutput("/nonexistent/simctl", []) == nil)
}

@Test
func aCommandThatNeverEndsIsGivenUpOnAndEnded() async throws {
  let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("simview-\(UUID().uuidString).pid").path
  defer { try? FileManager.default.removeItem(atPath: pidFile) }
  let start = ContinuousClock.now
  #expect(await SimulatorView.runOutput("/bin/sh", ["-c", "echo $$ > \(pidFile); exec sleep 30"], timeout: 0.2) == nil)
  #expect(ContinuousClock.now - start < .seconds(5))
  let pid = try #require(Int32(String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
  // Ended: SIGTERM, then SIGKILL if it outlives it (half a second).
  #expect(await exited(pid, within: 5))
}

/// Whether `pid` exits (or is gone already) within `seconds`: told by the kernel as it does, not looked at again and again.
private func exited(_ pid: Int32, within seconds: Double) async -> Bool {
  await withCheckedContinuation { done in
    let once = Once()
    let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
    let finish = { (gone: Bool) in
      guard once.take() else { return }
      source.cancel()
      done.resume(returning: gone)
    }
    source.setEventHandler { finish(true) }
    source.resume()
    // (armed first: one that ended before it was is no longer there to signal)
    if kill(pid, 0) != 0 { return finish(true) }
    DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { finish(kill(pid, 0) != 0) }
  }
}

@Test
func aChildLeftHoldingTheStdoutKeepsNoOneWaiting() async throws {
  // simctl ended, a child of its left with the pipe: the output never closes.
  let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("simview-\(UUID().uuidString).pid").path
  defer {
    if let text = try? String(contentsOfFile: pidFile, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) { kill(pid, SIGKILL) }
    try? FileManager.default.removeItem(atPath: pidFile)
  }
  let start = ContinuousClock.now
  #expect(await SimulatorView.runOutput("/bin/sh", ["-c", "sleep 30 & echo $! > \(pidFile); echo partial"], timeout: 0.2) == nil)
  #expect(ContinuousClock.now - start < .seconds(5))
}
