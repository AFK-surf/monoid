// The screensaver's authorization rule (`system.login.screensaver` in the authorization database), rewritten so that
// one more way unlocks it: ours (`fail.still.lockeduse`), tried first, any one way enough. Never a way less: whatever
// unlocked it before still does, and a rule that asks for several things at once (a password and a second factor) is
// left alone, as "any one" would drop the second factor.
//
// Read and written as `security authorizationdb read|write` has them: a property list dictionary.
import Foundation

public enum RuleError: Error, Equatable, CustomStringConvertible {
  /// Several rules that must all pass (or k of them, k > 1): making it "any one" would weaken it.
  case allOf([String], k: Int?)
  case malformed(String)

  public var description: String {
    switch self {
    case let .allOf(rules, k):
      return "the screensaver rule asks for \(k.map { "\($0) of" } ?? "all of") \(rules.joined(separator: ", ")): locked use would let any one of them do, so it is not installed"
    case let .malformed(why):
      return "the screensaver rule is not one this tool knows (\(why)): nothing is changed"
    }
  }
}

public enum ScreensaverRule {
  public static let ours = "fail.still.lockeduse"
  /// A rule that was not a list of rules, kept under this name while ours is installed.
  public static let original = "fail.still.lockeduse.orig"
  /// The system's own rule for the screensaver (what an empty list goes back to).
  public static let system = "use-login-window-ui"

  /// What installing changes.
  public struct Install: Equatable {
    /// The screensaver rule to write.
    public var rule: [String: AnyHashable]
    /// A right to write first under `original` (the rule as it was), when it was not a list of rules.
    public var original: [String: AnyHashable]?
    /// `k-of-n` was missing and is written as 1 (taken away again on uninstall when one rule is left).
    public var addedK: Bool
  }

  /// Our right: one mechanism of the plugin, tried once, never shared.
  public static func right(mechanism: String = "StillfailLockedUse:allow") -> [String: AnyHashable] {
    [
      "class": "evaluate-mechanisms",
      "comment": "still.fail locked use: an unlock the still.fail guard gave out for one moment",
      "mechanisms": [mechanism] as [AnyHashable],
      "shared": false,
      "tries": 1,
      "version": 1,
    ]
  }

  /// Installing on `current`: nil when ours is there already (installing again changes nothing).
  public static func install(_ current: [String: AnyHashable]) throws -> Install? {
    if current["class"] as? String == "rule" {
      guard let rules = current["rule"] as? [AnyHashable] else { throw RuleError.malformed("a rule class without a rule list") }
      let names = try rules.map { r -> String in
        guard let name = r as? String else { throw RuleError.malformed("a rule list of other than names") }
        return name
      }
      if names.contains(ours) { return nil }
      let k = (current["k-of-n"] as? NSNumber)?.intValue
      guard names.count == 1 || k == 1 else { throw RuleError.allOf(names, k: k) }
      var rule = current
      rule["rule"] = ([ours] + names) as [AnyHashable]
      rule["k-of-n"] = 1
      return Install(rule: rule, original: nil, addedK: k == nil)
    }
    guard current["class"] is String else { throw RuleError.malformed("no class") }
    // A rule of another class (mechanisms, a user to authenticate): kept whole under its own name, beside ours.
    let rule: [String: AnyHashable] = [
      "class": "rule",
      "comment": "still.fail locked use, or the rule this Mac had (\(original))",
      "k-of-n": 1,
      "rule": [ours, original] as [AnyHashable],
      "version": 1,
    ]
    return Install(rule: rule, original: current, addedK: false)
  }

  /// Uninstalling from `current` (rules others added since stay): the screensaver rule to write, and whether
  /// `original` is to be removed after. `addedK` is what installing said.
  public static func uninstall(_ current: [String: AnyHashable], originalRight: [String: AnyHashable]?, addedK: Bool) throws -> (rule: [String: AnyHashable], dropOriginal: Bool) {
    guard current["class"] as? String == "rule", let rules = current["rule"] as? [AnyHashable] else { return (current, false) }
    let left = rules.filter { ($0 as? String) != ours }
    if left.count == rules.count { return (current, false) }
    if left.isEmpty {
      // Nothing else left (others removed theirs since): the system's own way, never an empty list.
      var rule = current
      rule["rule"] = [system] as [AnyHashable]
      rule.removeValue(forKey: "k-of-n")
      return (rule, false)
    }
    if left.count == 1, (left[0] as? String) == original, let originalRight {
      // Wrapped when installed and nothing added since: the rule as it was.
      return (originalRight, true)
    }
    var rule = current
    rule["rule"] = left
    // `k-of-n` written by us comes away only where one rule is left: with several (another's added since), "all of"
    // would lock the Mac.
    if addedK && left.count == 1 { rule.removeValue(forKey: "k-of-n") }
    return (rule, false)
  }
}
