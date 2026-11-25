// Whose this Mac's locked use is (`/Library/Application Support/still.fail/LockedUse.plist`, root's, written only by
// `stillfail-lockeduse bind`): for each user of the Mac allowed it, the still.fail account (`sub`) whose chats may
// unlock it and the stations (their mesh keys) whose tasks may. No file, or no entry for a user: no locked use.
import Foundation

public enum Paths {
  public static let root = "/Library/Application Support/still.fail"
  public static let binding = root + "/LockedUse.plist"
  public static let guardApp = root + "/Guard.app"
  public static let guardExecutable = guardApp + "/Contents/MacOS/stillfail-guard"
  public static let launchAgent = "/Library/LaunchAgents/fail.still.guard.plist"
  public static let plugin = "/Library/Security/SecurityAgentPlugins/StillfailLockedUse.bundle"
  public static let originalRule = root + "/screensaver-rule.original.plist"
  /// A user's sockets and state: `<uid>:_securityagent 0750`.
  public static func user(_ uid: uid_t) -> String { root + "/lockuse/\(uid)" }
  /// The plugin's way to the guard (0660).
  public static func auth(_ uid: uid_t) -> String { user(uid) + "/auth.sock" }
  /// The Helper's way to the guard (0600).
  public static func control(_ uid: uid_t) -> String { user(uid) + "/control.sock" }
  /// What a guard leaves for the next one while an unlock is out (`Remains`).
  public static func state(_ uid: uid_t) -> String { user(uid) + "/state" }
}

public struct Binding: Equatable, Sendable {
  public var sub: String
  /// Mesh keys (64 hex) of the stations whose tasks may unlock this Mac, besides this station's own chats.
  public var stations: [String]

  public init(sub: String, stations: [String]) throws {
    guard Binding.validSub(sub) else { throw BindingError.sub }
    let keys = stations.map { $0.lowercased() }
    guard keys.allSatisfy(Binding.validKey), Set(keys).count == keys.count, keys.count <= 16 else { throw BindingError.station }
    self.sub = sub
    self.stations = keys
  }

  /// An account id as the cloud gives them: letters, digits, `-`, `_`, `|`, `.`, `:`, at most 128.
  public static func validSub(_ s: String) -> Bool {
    !s.isEmpty && s.utf8.count <= 128 && s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "-_|.:".unicodeScalars.contains($0) }
  }

  public static func validKey(_ s: String) -> Bool {
    s.utf8.count == 64 && s.unicodeScalars.allSatisfy { "0123456789abcdef".unicodeScalars.contains($0) }
  }
}

public enum BindingError: Error, CustomStringConvertible {
  case sub, station, file(String)
  public var description: String {
    switch self {
    case .sub: return "not a still.fail account id"
    case .station: return "station keys are 64 hex digits, at most 16, each once"
    case let .file(why): return "LockedUse.plist: \(why)"
    }
  }
}

/// The whole file: users (uid as a string key) to their binding.
public enum BindingFile {
  public static func decode(_ data: Data) throws -> [uid_t: Binding] {
    guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
      plist["version"] as? Int == 1, let users = plist["users"] as? [String: Any]
    else { throw BindingError.file("not version 1") }
    var out: [uid_t: Binding] = [:]
    for (key, value) in users {
      guard let uid = uid_t(key), uid >= 500, let entry = value as? [String: Any], let sub = entry["sub"] as? String,
        let stations = entry["stations"] as? [String]
      else { throw BindingError.file("entry \(key)") }
      out[uid] = try Binding(sub: sub, stations: stations)
    }
    return out
  }

  public static func encode(_ users: [uid_t: Binding]) throws -> Data {
    var all: [String: Any] = [:]
    for (uid, b) in users { all[String(uid)] = ["sub": b.sub, "stations": b.stations] }
    return try PropertyListSerialization.data(fromPropertyList: ["version": 1, "users": all], format: .xml, options: 0)
  }
}
