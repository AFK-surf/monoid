// Locked use (station/native/lockeduse/AGENTS.md): the station's leases on this Mac's locked screen, held on the
// guard's control socket. The first lease opens the guard's connection (the guard unlocks behind its cover); the last
// one to end closes it (the guard relocks). A lease is the station's connection to this Helper that asked for it: it
// ends when the station closes it, says `lockuse.end`, or is gone. And whatever the guard does, if its process ends
// while a lease is held, this Helper locks the screen itself.
import AppKit
import Foundation

final class LockedUse {
  static let shared = LockedUse()

  private let lock = NSLock()
  private var leases: Set<String> = []
  private var guardFd: Int32 = -1
  private var exitWatch: DispatchSourceProcess?

  var active: Bool {
    lock.lock()
    defer { lock.unlock() }
    return guardFd >= 0
  }

  private static let root = "/Library/Application Support/still.fail"

  /// What the station shows and decides by: installed, bound (and to whom), locked now.
  static func status() -> [String: Any] {
    let uid = getuid()
    var out: [String: Any] = [
      "locked": Status.screenLocked(), "uid": Int(uid),
      "installed": FileManager.default.isExecutableFile(atPath: root + "/Guard.app/Contents/MacOS/stillfail-guard")
        && FileManager.default.fileExists(atPath: "/Library/Security/SecurityAgentPlugins/StillfailLockedUse.bundle"),
    ]
    if let data = FileManager.default.contents(atPath: root + "/LockedUse.plist"),
      let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
      let users = plist["users"] as? [String: Any], let mine = users[String(uid)] as? [String: Any]
    {
      out["bound"] = true
      out["binding"] = ["sub": mine["sub"] ?? "", "stations": mine["stations"] ?? []]
    } else {
      out["bound"] = false
    }
    return out
  }

  /// A lease on `channel` (the station's connection): answered, then held until the channel ends.
  func serve(_ request: [String: Any], _ channel: Channel) {
    guard let lease = request["lease"] as? String, !lease.isEmpty, lease.utf8.count <= 128 else {
      channel.line(["error": "no lease", "code": "args"])
      return
    }
    if let error = take(lease) {
      channel.line(error)
      return
    }
    channel.line(["ok": true])
    while channel.readLine() != nil {}
    release(lease)
  }

  func end(_ lease: String) { release(lease) }

  private func take(_ lease: String) -> [String: Any]? {
    lock.lock()
    defer { lock.unlock() }
    if guardFd >= 0 {
      leases.insert(lease)
      return nil
    }
    let status = LockedUse.status()
    guard status["installed"] as? Bool == true else { return ["error": "locked use is not installed on this Mac", "code": "not-installed"] }
    guard status["bound"] as? Bool == true else { return ["error": "locked use is not bound to an account on this Mac", "code": "not-bound"] }
    let path = LockedUse.root + "/lockuse/\(getuid())/control.sock"
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = path.utf8CString
    withUnsafeMutablePointer(to: &address.sun_path) { p in
      bytes.withUnsafeBufferPointer { UnsafeMutableRawPointer(p).copyMemory(from: $0.baseAddress!, byteCount: min($0.count, 104)) }
    }
    let connected = withUnsafePointer(to: &address) { p in
      p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else {
      close(fd)
      return ["error": "the still.fail guard is not running", "code": "no-guard"]
    }
    let guardChannel = Channel(fd: fd)
    guardChannel.line(["op": "begin", "v": 1, "lease": lease])
    guard let line = guardChannel.readLine(), let answer = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
      close(fd)
      LockedUse.lockNow()
      return ["error": "the guard ended without an answer: locked", "code": "failed"]
    }
    guard answer["ok"] as? Bool == true else {
      close(fd)
      return ["error": answer["error"] ?? "refused", "code": answer["code"] ?? "failed"]
    }
    guardFd = fd
    leases.insert(lease)
    watchGuard(fd)
    return nil
  }

  private func release(_ lease: String) {
    lock.lock()
    defer { lock.unlock() }
    leases.remove(lease)
    guard leases.isEmpty, guardFd >= 0 else { return }
    // The last lease: the guard relocks as its connection ends.
    exitWatch?.cancel()
    exitWatch = nil
    close(guardFd)
    guardFd = -1
  }

  /// The guard's process watched while a lease is held: its end locks the screen here, at once.
  private func watchGuard(_ fd: Int32) {
    var token = audit_token_t()
    var size = socklen_t(MemoryLayout<audit_token_t>.size)
    guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0 else { return }
    let pid = pid_t(token.val.5)
    let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .userInteractive))
    source.setEventHandler { [weak self] in
      LockedUse.lockNow()
      guard let self else { return }
      self.lock.lock()
      self.leases.removeAll()
      if self.guardFd >= 0 { close(self.guardFd) }
      self.guardFd = -1
      self.exitWatch = nil
      self.lock.unlock()
    }
    source.resume()
    exitWatch = source
  }

  private static let login = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY)

  /// The screen locked from here (the guard's own way, when the guard cannot).
  static func lockNow() {
    guard let login, let f = dlsym(login, "SACLockScreenImmediate") else { return }
    typealias Fn = @convention(c) () -> Int32
    _ = unsafeBitCast(f, to: Fn.self)()
  }
}
