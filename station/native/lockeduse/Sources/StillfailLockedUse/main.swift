// stillfail-lockeduse: the administrator's tool for locked use, installed root's beside the guard
// (/Library/Application Support/still.fail/stillfail-lockeduse) and run as root only: from the package's postinstall,
// from the still.fail settings through the system's administrator prompt (`osascript … with administrator
// privileges`, its arguments passed with `quoted form of`), or by hand with sudo. It reads no file a user can write.
//
//   status                           JSON: installed parts, the screensaver rule, the bindings
//   rule-install                     add ours to system.login.screensaver (ScreensaverRule.install), checked after
//   bind <sub> [<station key>…]      bind the console user to an account and stations; makes their directory
//   unbind                           take the console user's binding away
//   uninstall                        everything away again, the rule first and checked before anything is deleted
import Foundation
import LockedUseCore

func fail(_ why: String) -> Never {
  FileHandle.standardError.write(Data("stillfail-lockeduse: \(why)\n".utf8))
  exit(1)
}

@discardableResult
func run(_ path: String, _ arguments: [String], input: Data? = nil) -> (status: Int32, out: Data) {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: path)
  p.arguments = arguments
  let out = Pipe()
  p.standardOutput = out
  p.standardError = FileHandle.nullDevice
  let into = Pipe()
  if input != nil { p.standardInput = into }
  do { try p.run() } catch { return (-1, Data()) }
  if let input {
    into.fileHandleForWriting.write(input)
    try? into.fileHandleForWriting.close()
  }
  let data = out.fileHandleForReading.readDataToEndOfFile()
  p.waitUntilExit()
  return (p.terminationStatus, data)
}

enum Db {
  static func read(_ right: String) -> [String: AnyHashable]? {
    let r = run("/usr/bin/security", ["authorizationdb", "read", right])
    guard r.status == 0 else { return nil }
    guard var plist = (try? PropertyListSerialization.propertyList(from: r.out, format: nil)) as? [String: AnyHashable] else { return nil }
    // What the database adds itself.
    for key in ["created", "modified"] { plist.removeValue(forKey: key) }
    return plist
  }

  static func write(_ right: String, _ value: [String: AnyHashable]) {
    guard let data = try? PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0) else { fail("\(right): not a property list") }
    guard run("/usr/bin/security", ["authorizationdb", "write", right], input: data).status == 0 else { fail("\(right): not written") }
  }

  static func remove(_ right: String) {
    run("/usr/bin/security", ["authorizationdb", "remove", right])
  }
}

let screensaver = "system.login.screensaver"
/// What installing did that uninstalling undoes (whether `k-of-n` was added, and the rule wrapped).
let installed = Paths.root + "/rule-install.plist"

func consoleUid() -> uid_t? {
  var st = stat()
  guard stat("/dev/console", &st) == 0, st.st_uid >= 500 else { return nil }
  return st.st_uid
}

func consoleUser() -> uid_t {
  guard let uid = consoleUid() else { fail("no user is logged in at this Mac's console") }
  return uid
}

func readBindings() -> [uid_t: Binding] {
  let fd = open(Paths.binding, O_RDONLY | O_NOFOLLOW)
  guard fd >= 0 else { return [:] }
  let data = FileHandle(fileDescriptor: fd, closeOnDealloc: true).readDataToEndOfFile()
  do { return try BindingFile.decode(data) } catch { fail("\(error)") }
}

func writeRoot(_ path: String, _ data: Data, mode: mode_t = 0o644) {
  let tmp = path + ".new"
  unlink(tmp)
  let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
  guard fd >= 0 else { fail("\(tmp): \(String(cString: strerror(errno)))") }
  let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
  h.write(data)
  try? h.close()
  guard chown(tmp, 0, 0) == 0, rename(tmp, path) == 0 else { fail("\(path) not written") }
}

func ruleInstall() {
  guard let current = Db.read(screensaver) else { fail("\(screensaver) could not be read") }
  let plan: ScreensaverRule.Install?
  do { plan = try ScreensaverRule.install(current) } catch { fail("\(error)") }
  guard let plan else {
    print("already installed")
    return
  }
  // The rule as it was before still.fail, once: never overwritten by a later install.
  if access(Paths.originalRule, F_OK) != 0, let data = try? PropertyListSerialization.data(fromPropertyList: current, format: .xml, options: 0) {
    writeRoot(Paths.originalRule, data, mode: 0o600)
  }
  let record: [String: Any] = ["addedK": plan.addedK, "wrapped": plan.original != nil]
  writeRoot(installed, try! PropertyListSerialization.data(fromPropertyList: record, format: .xml, options: 0), mode: 0o600)
  Db.write(ScreensaverRule.ours, ScreensaverRule.right())
  if let original = plan.original { Db.write(ScreensaverRule.original, original) }
  Db.write(screensaver, plan.rule)
  // Checked: anything else than what was meant goes back to what was there.
  guard let after = Db.read(screensaver), after == plan.rule else {
    Db.write(screensaver, current)
    Db.remove(ScreensaverRule.ours)
    if plan.original != nil { Db.remove(ScreensaverRule.original) }
    fail("\(screensaver) did not read back as written: put back as it was")
  }
  print("installed")
}

/// The rule without ours, checked. False when it did not read back as meant (nothing else is then removed).
func ruleUninstall() -> Bool {
  guard let current = Db.read(screensaver) else { return false }
  let record = (try? Data(contentsOf: URL(fileURLWithPath: installed))).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
  let original = Db.read(ScreensaverRule.original)
  guard let back = try? ScreensaverRule.uninstall(current, originalRight: original, addedK: record["addedK"] as? Bool == true) else { return false }
  if back.rule != current { Db.write(screensaver, back.rule) }
  guard let after = Db.read(screensaver), after == back.rule else { return false }
  Db.remove(ScreensaverRule.ours)
  if back.dropOriginal { Db.remove(ScreensaverRule.original) }
  return true
}

func makeUserDirectory(_ uid: uid_t) {
  let dir = Paths.user(uid)
  let parent = (dir as NSString).deletingLastPathComponent
  mkdir(parent, 0o755)
  guard chown(parent, 0, 0) == 0 else { fail("\(parent): not root's") }
  var st = stat()
  if lstat(dir, &st) == 0, (st.st_mode & S_IFMT) != S_IFDIR { fail("\(dir) is not a directory") }
  mkdir(dir, 0o750)
  // The guard (the user) makes its sockets in it, the plugin (_securityagent, 92) reaches them.
  guard chown(dir, uid, 92) == 0, chmod(dir, 0o750) == 0 else { fail("\(dir): owner not set") }
}

func bind(_ arguments: [String]) {
  guard let sub = arguments.first else { fail("bind <sub> [<station key>…]") }
  let uid = consoleUser()
  let binding: Binding
  do { binding = try Binding(sub: sub, stations: Array(arguments.dropFirst())) } catch { fail("\(error)") }
  var all = readBindings()
  all[uid] = binding
  writeRoot(Paths.binding, try! BindingFile.encode(all))
  makeUserDirectory(uid)
  // The guard of this user started again, to read it.
  run("/bin/launchctl", ["kickstart", "-k", "gui/\(uid)/fail.still.guard"])
  print("bound user \(uid) to \(sub) and \(binding.stations.count) station(s)")
}

func unbind() {
  let uid = consoleUser()
  var all = readBindings()
  all.removeValue(forKey: uid)
  writeRoot(Paths.binding, try! BindingFile.encode(all))
  run("/bin/launchctl", ["kill", "TERM", "gui/\(uid)/fail.still.guard"])
}

/// Removes a path never following a link (a user's directory may hold one put there to make root delete elsewhere).
func removeTree(_ path: String) {
  var st = stat()
  guard lstat(path, &st) == 0 else { return }
  if (st.st_mode & S_IFMT) == S_IFDIR {
    for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] { removeTree((path as NSString).appendingPathComponent(name)) }
    rmdir(path)
  } else {
    unlink(path)
  }
}

func uninstall() {
  var users = Set(readBindings().keys)
  if let console = consoleUid() { users.insert(console) }
  // A use under way ends (the guard relocks as it is told to end), then no guard is left running.
  for uid in users {
    run("/bin/launchctl", ["bootout", "gui/\(uid)", Paths.launchAgent])
  }
  guard ruleUninstall() else { fail("\(screensaver) could not be put back: nothing removed, the original kept at \(Paths.originalRule)") }
  unlink(Paths.launchAgent)
  removeTree(Paths.plugin)
  removeTree(Paths.guardApp)
  removeTree(Paths.root + "/lockuse")
  unlink(Paths.binding)
  unlink(installed)
  unlink(Paths.originalRule)
  run("/usr/sbin/pkgutil", ["--forget", "fail.still.lockeduse"])
  removeTree(Paths.root + "/stillfail-lockeduse")
  print("uninstalled")
}

func status() {
  let all = readBindings()
  let out: [String: Any] = [
    "plugin": access(Paths.plugin, F_OK) == 0,
    "guard": access(Paths.guardExecutable, X_OK) == 0,
    "rule": (Db.read(screensaver)?["rule"] as? [String]) ?? [],
    "bound": Dictionary(uniqueKeysWithValues: all.map { (String($0.key), ["sub": $0.value.sub, "stations": $0.value.stations]) }),
  ]
  print(String(data: try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]), encoding: .utf8)!)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail("status | rule-install | bind <sub> [<station key>…] | unbind | uninstall") }
if command != "status" && geteuid() != 0 { fail("\(command) is run as root (an administrator's)") }
switch command {
case "status": status()
case "rule-install": ruleInstall()
case "bind": bind(Array(arguments.dropFirst()))
case "unbind": unbind()
case "uninstall": uninstall()
default: fail("no command \(command)")
}
