// The guard's one unlock at a time (LockedUseCore.Unlock decides; this does what it says), on the main queue.
import AppKit
import Foundation
import LockedUseCore

@MainActor
final class Guardian {
  let uid: uid_t
  private var unlock = Unlock()
  private let cover = Cover()
  private lazy var watch = Watch { [weak self] in MainActor.assumeIsolated { self?.heardLocal() } }
  private var awake: System.Awake?
  /// The Helper's connection holding the use (one at a time).
  private var holder: Int32 = -1
  /// Its answer still owed (the begin waits for the unlock to show).
  private var owed: ((Result<Void, GuardError>) -> Void)?
  private var ticker: Timer?
  /// The screen was locked when last looked at: a lock then an unlock no unlock of ours let through is a person's.
  private var lastLocked = System.locked()

  nonisolated init(uid: uid_t) { self.uid = uid }

  nonisolated func start() {
    MainActor.assumeIsolated {
      recover()
      listen(Paths.auth(uid), mode: 0o660) { [weak self] fd in self?.serveAuth(fd) }
      listen(Paths.control(uid), mode: 0o600) { [weak self] fd in self?.serveControl(fd) }
      // Lock and unlock are told by notification: only a hint to look (any process may post one).
      let center = DistributedNotificationCenter.default()
      for name in ["com.apple.screenIsUnlocked", "com.apple.screenIsLocked"] {
        center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.look() }
        }
      }
    }
  }

  // MARK: what is decided

  private func look() {
    let locked = System.locked()
    let now = System.uptime()
    if !locked && lastLocked {
      switch unlock.state {
      case .consumed, .armed:
        act(unlock.sawUnlocked(now: now))
        if case .unlocked = unlock.state { answer(.success(())) }
      case .idle:
        unlock.manualUnlock()
        log.info("unlocked by hand: locked use may unlock again")
      default: break
      }
    }
    lastLocked = locked
    if case .relocking = unlock.state, locked {
      finish()
    }
  }

  private func tick() {
    let locked = System.locked()
    act(unlock.tick(now: System.uptime(), locked: locked))
    look()
    if unlock.state != .idle { writeRemains() }
    // Secure Event Input taken while unlocked: the tap no longer sees the keyboard.
    if case .unlocked = unlock.state, System.secureInput() {
      log.notice("secure input turned on: relocking")
      act(unlock.end())
    }
  }

  private func heardLocal() {
    log.notice("local input: relocking, no more unlocks until one by hand")
    act(unlock.localInput())
  }

  private func act(_ step: Step) {
    switch step {
    case .none: return
    case .relock:
      answer(.failure(.failed))
      let done = System.lock { seconds in
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
          if System.locked() { return true }
          RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return System.locked()
      }
      if done {
        lastLocked = true
        unlock.relocked()
        finish()
      } else {
        // Not seen locked: the cover and the watch stay, and so does the state (tick tries again).
        log.fault("could not lock the screen: the cover stays")
      }
    case .uncover:
      answer(.failure(.failed))
      if System.locked() { finish() } else { act(.relock) }
    }
  }

  /// The use over and the screen locked: everything let go.
  private func finish() {
    guard System.locked() else { return }
    cover.hide()
    watch.stop()
    awake?.release()
    awake = nil
    ticker?.invalidate()
    ticker = nil
    try? FileManager.default.removeItem(atPath: Paths.state(uid))
    if holder >= 0 {
      Darwin.shutdown(holder, SHUT_RDWR)
      holder = -1
    }
  }

  private func answer(_ result: Result<Void, GuardError>) {
    guard let owed else { return }
    self.owed = nil
    owed(result)
  }

  // MARK: a use

  /// The Helper asks for a use: refused unless the screen is locked and this Mac left alone; otherwise the cover goes
  /// up, the watch starts, the unlock is given out and the lock screen asked to try it.
  private func begin(fd: Int32, lease: String, reply: @escaping (Result<Void, GuardError>) -> Void) {
    guard holder < 0 else { return reply(.failure(.busy)) }
    guard System.locked(), System.onConsole() else { return reply(.failure(.notLocked)) }
    if Watch.universalControl() { return reply(.failure(.universalControl)) }
    do {
      try unlock.arm(now: System.uptime(), idle: System.idle(), secureInput: System.secureInput())
    } catch let refusal as Refusal {
      return reply(.failure(.refused(refusal)))
    } catch {
      return reply(.failure(.failed))
    }
    holder = fd
    owed = reply
    cover.show()
    guard watch.start() else {
      log.error("the watch did not start (Accessibility or Input Monitoring not granted?)")
      act(unlock.end())
      return
    }
    awake = System.Awake()
    writeRemains()
    log.notice("locked use begins (lease \(lease, privacy: .public))")
    ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
    Trigger.askLockScreen()
  }

  private func end(fd: Int32) {
    guard fd == holder else { return }
    holder = -1
    log.notice("locked use ends")
    act(unlock.end())
    if unlock.state == .idle { finish() }
  }

  // MARK: after a crash

  private func writeRemains() {
    let r = Remains(boot: System.boot(), heartbeat: System.uptime())
    guard let data = try? JSONEncoder().encode(r) else { return }
    let path = Paths.state(uid)
    let tmp = path + ".tmp"
    FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600])
    rename(tmp, path)
  }

  private func recover() {
    let fd = open(Paths.state(uid), O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { return }
    let data = FileHandle(fileDescriptor: fd, closeOnDealloc: true).readDataToEndOfFile()
    try? FileManager.default.removeItem(atPath: Paths.state(uid))
    guard let r = try? JSONDecoder().decode(Remains.self, from: data) else { return }
    if r.relockNow(boot: System.boot(), uptime: System.uptime(), locked: System.locked()) {
      log.fault("the last guard ended with an unlock out: locking")
      _ = System.lock { _ in System.locked() }
    }
  }

  // MARK: the sockets

  private func listen(_ path: String, mode: mode_t, serve: @escaping (Int32) -> Void) {
    unlink(path)
    let server = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = path.utf8CString
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return }
    withUnsafeMutablePointer(to: &address.sun_path) { p in
      bytes.withUnsafeBufferPointer { UnsafeMutableRawPointer(p).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
    }
    let bound = withUnsafePointer(to: &address) { p in
      p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard bound == 0, chmod(path, mode) == 0, Darwin.listen(server, 8) == 0 else {
      log.error("not listening on \(path, privacy: .public): \(String(cString: strerror(errno)), privacy: .public)")
      close(server)
      return
    }
    Thread.detachNewThread {
      while true {
        let client = accept(server, nil, nil)
        if client < 0 { if errno == EINTR || errno == ECONNABORTED { continue } else { return } }
        Thread.detachNewThread { serve(client) }
      }
    }
  }

  /// One question of the plugin's, on its own thread.
  nonisolated private func serveAuth(_ fd: Int32) {
    defer { close(fd) }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    guard let peer = Peer.of(fd), peer.isAuthorizationHost() else {
      log.error("auth.sock: a peer that is not the authorization system")
      _ = Wire.answer(false).withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
      return
    }
    var ask = [UInt8](repeating: 0, count: Wire.askSize)
    guard read(fd, &ask, ask.count) == ask.count, let asked = Wire.asked(ask), asked == uid else {
      _ = Wire.answer(false).withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
      return
    }
    let yes = DispatchQueue.main.sync { MainActor.assumeIsolated { unlock.take(now: System.uptime()) } }
    log.notice("the lock screen asked for an unlock: \(yes ? "given" : "refused", privacy: .public)")
    _ = Wire.answer(yes).withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
  }

  /// The Helper's connection, on its own thread, for as long as the use lasts.
  nonisolated private func serveControl(_ fd: Int32) {
    defer { close(fd) }
    guard let peer = Peer.of(fd), peer.euid == uid, peer.meets(helperRequirement) else {
      _ = writeLine(fd, ["error": "not the still.fail Helper", "code": "peer"])
      return
    }
    guard let line = readLine(fd), let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
      request["op"] as? String == "begin", request["v"] as? Int == 1, let lease = request["lease"] as? String
    else {
      _ = writeLine(fd, ["error": "not a begin of protocol 1", "code": "protocol"])
      return
    }
    let answered = DispatchSemaphore(value: 0)
    var result: Result<Void, GuardError> = .failure(.failed)
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        self.begin(fd: fd, lease: lease) { r in
          result = r
          answered.signal()
        }
      }
    }
    answered.wait()
    switch result {
    case .success:
      _ = writeLine(fd, ["ok": true])
      // Held until the Helper closes it or the guard does (finish): either way the use ends.
      var byte: UInt8 = 0
      while Darwin.read(fd, &byte, 1) > 0 {}
      DispatchQueue.main.sync { MainActor.assumeIsolated { self.end(fd: fd) } }
    case let .failure(why):
      _ = writeLine(fd, ["error": why.description, "code": why.code])
      DispatchQueue.main.sync { MainActor.assumeIsolated { self.end(fd: fd) } }
    }
  }
}

enum GuardError: Error, CustomStringConvertible {
  case busy, notLocked, universalControl, failed
  case refused(Refusal)

  var code: String {
    switch self {
    case .busy: return "busy"
    case .notLocked: return "not-locked"
    case .universalControl: return "universal-control"
    case .failed: return "failed"
    case let .refused(r): return r.rawValue
    }
  }

  var description: String {
    switch self {
    case .busy: return "another locked use is under way"
    case .notLocked: return "the screen is not locked (or this user is not on the console)"
    case .universalControl: return "Universal Control is on: another device's input could reach this Mac unseen"
    case .failed: return "the unlock did not happen, or was ended: the screen is locked"
    case .refused(.cooldown): return "someone used this Mac in the last minute"
    case .refused(.secureInput): return "an app holds Secure Event Input"
    case .refused(.suppressed): return "someone used this Mac during locked use: it waits for its person to unlock it by hand"
    case .refused(.busy): return "another locked use is under way"
    }
  }
}

private func readLine(_ fd: Int32, limit: Int = 4096) -> Data? {
  var line = Data()
  var byte: UInt8 = 0
  while line.count < limit {
    let n = read(fd, &byte, 1)
    if n < 0 && errno == EINTR { continue }
    if n <= 0 { return nil }
    if byte == 10 { return line }
    line.append(byte)
  }
  return nil
}

private func writeLine(_ fd: Int32, _ value: [String: Any]) -> Bool {
  guard var data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return false }
  data.append(10)
  return data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == data.count
}
