import Foundation
import Testing
@testable import LockedUseCore

// MARK: the unlock

@Test
func anUnlockIsTakenOnceAndOnlyWhileGivenOut() throws {
  var u = Unlock()
  try u.arm(now: 100, idle: 120, secureInput: false)
  do { let r = u.take(now: 101); #expect(r) }
  do { let r = u.take(now: 101.5); #expect(!r) }
  var late = Unlock()
  try late.arm(now: 100, idle: 120, secureInput: false)
  do { let r = late.take(now: 100 + Unlock.armedFor); #expect(!r) }
}

@Test
func noUnlockWhileSomeoneWasAtTheMacOrSecureInputIsOn() {
  var u = Unlock()
  #expect(throws: Refusal.cooldown) { try u.arm(now: 0, idle: 59, secureInput: false) }
  #expect(throws: Refusal.secureInput) { try u.arm(now: 0, idle: 600, secureInput: true) }
  #expect(u.state == .idle)
}

@Test
func anUntakenUnlockThatExpiresLeavesTheScreenLocked() throws {
  var u = Unlock()
  try u.arm(now: 0, idle: 600, secureInput: false)
  do { let r = u.tick(now: 3.9, locked: true); #expect(r == .none) }
  do { let r = u.tick(now: 4, locked: true); #expect(r == .uncover) }
  #expect(u.state == .idle)
}

@Test
func aTakenUnlockSeenLateIsStillRelocked() throws {
  var u = Unlock()
  try u.arm(now: 0, idle: 600, secureInput: false)
  do { let r = u.take(now: 1); #expect(r) }
  // Not unlocked within the wait: watched on.
  do { let r = u.tick(now: 1 + Unlock.unlockWithin, locked: true); #expect(r == .none) }
  // Then seen unlocked: relocked, never left open.
  do { let r = u.tick(now: 1 + Unlock.unlockWithin + 1, locked: false); #expect(r == .relock) }
  #expect(u.state == .relocking)
  u.relocked()
  #expect(u.state == .idle)
}

@Test
func aTakenUnlockThatNeverShowsEndsAfterTheWatch() throws {
  var u = Unlock()
  try u.arm(now: 0, idle: 600, secureInput: false)
  do { let r = u.take(now: 0); #expect(r) }
  do { let r = u.tick(now: Unlock.unlockWithin + Unlock.watchAfter, locked: true); #expect(r == .uncover) }
}

@Test
func localInputRelocksAndHoldsUnlocksUntilAManualOne() throws {
  var u = Unlock()
  try u.arm(now: 0, idle: 600, secureInput: false)
  do { let r = u.take(now: 1); #expect(r) }
  do { let r = u.sawUnlocked(now: 2); #expect(r == .none) }
  do { let r = u.localInput(); #expect(r == .relock) }
  u.relocked()
  #expect(throws: Refusal.suppressed) { try u.arm(now: 100, idle: 600, secureInput: false) }
  u.manualUnlock()
  try u.arm(now: 200, idle: 600, secureInput: false)
}

@Test
func localInputWhileGivenOutVoidsIt() throws {
  var u = Unlock()
  try u.arm(now: 0, idle: 600, secureInput: false)
  do { let r = u.localInput(); #expect(r == .uncover) }
  do { let r = u.take(now: 1); #expect(!r) }
}

@Test
func localInputBetweenTakeAndUnlockRelocksTheMomentItUnlocks() throws {
  var u = Unlock()
  try u.arm(now: 0, idle: 600, secureInput: false)
  do { let r = u.take(now: 1); #expect(r) }
  do { let r = u.localInput(); #expect(r == .relock) }
  #expect(u.state == .relocking)
}

@Test
func aPersonsOwnUnlockIsNeverRelocked() throws {
  var u = Unlock()
  // Nothing given out: an unlock seen is a person's.
  do { let r = u.sawUnlocked(now: 0); #expect(r == .none) }
  do { let r = u.end(); #expect(r == .none) }
  // Given out but not taken, then unlocked by hand: ours is void, nothing to relock.
  try u.arm(now: 10, idle: 600, secureInput: false)
  do { let r = u.sawUnlocked(now: 11); #expect(r == .none) }
  do { let r = u.end(); #expect(r == .none) }
}

@Test
func theEndRelocksWhatWasUnlocked() throws {
  var u = Unlock()
  try u.arm(now: 0, idle: 600, secureInput: false)
  do { let r = u.take(now: 1); #expect(r) }
  do { let r = u.sawUnlocked(now: 2); #expect(r == .none) }
  do { let r = u.end(); #expect(r == .relock) }
}

@Test
func aGuardStartingAgainRelocksOnlyAfterAFreshDeath() {
  let r = Remains(boot: "b1", heartbeat: 1000)
  #expect(r.relockNow(boot: "b1", uptime: 1010, locked: false))
  #expect(!r.relockNow(boot: "b1", uptime: 1016, locked: false))
  #expect(!r.relockNow(boot: "b2", uptime: 1010, locked: false))
  #expect(!r.relockNow(boot: "b1", uptime: 1010, locked: true))
}

// MARK: the screensaver rule

private func rules(_ d: [String: AnyHashable]) -> [String]? { (d["rule"] as? [AnyHashable])?.compactMap { $0 as? String } }

private let codex = "com.openai.sky.CUAService.AuthorizationPlugin.remote"

@Test
func aSingleRuleGetsOursFirstAndAnyOneOf() throws {
  let plain: [String: AnyHashable] = ["class": "rule", "rule": ["use-login-window-ui"] as [AnyHashable], "version": 1]
  let i = try #require(try ScreensaverRule.install(plain))
  #expect(rules(i.rule) == [ScreensaverRule.ours, "use-login-window-ui"])
  #expect(i.rule["k-of-n"] as? Int == 1)
  #expect(i.addedK)
  #expect(i.original == nil)
  // And back.
  let back = try ScreensaverRule.uninstall(i.rule, originalRight: nil, addedK: true)
  #expect(back.rule == plain)
}

@Test
func anotherAnyOneOfKeepsItsRules() throws {
  let theirs: [String: AnyHashable] = ["class": "rule", "k-of-n": 1, "rule": [codex, "use-login-window-ui"] as [AnyHashable]]
  let i = try #require(try ScreensaverRule.install(theirs))
  #expect(rules(i.rule) == [ScreensaverRule.ours, codex, "use-login-window-ui"])
  #expect(!i.addedK)
  #expect(try ScreensaverRule.uninstall(i.rule, originalRight: nil, addedK: false).rule == theirs)
}

@Test
func installingAgainChangesNothing() throws {
  let ours: [String: AnyHashable] = ["class": "rule", "k-of-n": 1, "rule": [ScreensaverRule.ours, "use-login-window-ui"] as [AnyHashable]]
  #expect(try ScreensaverRule.install(ours) == nil)
}

@Test
func aRuleOfAllOfIsNeverWeakened() {
  let mfa: [String: AnyHashable] = ["class": "rule", "rule": ["use-login-window-ui", "com.example.second-factor"] as [AnyHashable]]
  #expect(throws: RuleError.allOf(["use-login-window-ui", "com.example.second-factor"], k: nil)) { try ScreensaverRule.install(mfa) }
  var twoOfThree = mfa
  twoOfThree["rule"] = ["a", "b", "c"] as [AnyHashable]
  twoOfThree["k-of-n"] = 2
  #expect(throws: RuleError.allOf(["a", "b", "c"], k: 2)) { try ScreensaverRule.install(twoOfThree) }
}

@Test
func anotherClassIsKeptWholeUnderItsOwnName() throws {
  let mechanisms: [String: AnyHashable] = ["class": "evaluate-mechanisms", "mechanisms": ["builtin:authenticate"] as [AnyHashable]]
  let i = try #require(try ScreensaverRule.install(mechanisms))
  #expect(i.original == mechanisms)
  #expect(rules(i.rule) == [ScreensaverRule.ours, ScreensaverRule.original])
  let back = try ScreensaverRule.uninstall(i.rule, originalRight: mechanisms, addedK: false)
  #expect(back.rule == mechanisms)
  #expect(back.dropOriginal)
}

@Test
func uninstallingKeepsAnyOneOfWhenOthersAddedTheirsSince() throws {
  // Installed on a plain Mac (k-of-n added), then another's rule came: "all of" the two left would lock it.
  let now: [String: AnyHashable] = ["class": "rule", "k-of-n": 1, "rule": [codex, ScreensaverRule.ours, "use-login-window-ui"] as [AnyHashable]]
  let back = try ScreensaverRule.uninstall(now, originalRight: nil, addedK: true)
  #expect(rules(back.rule) == [codex, "use-login-window-ui"])
  #expect(back.rule["k-of-n"] as? Int == 1)
}

@Test
func uninstallingNeverLeavesAnEmptyList() throws {
  let only: [String: AnyHashable] = ["class": "rule", "k-of-n": 1, "rule": [ScreensaverRule.ours] as [AnyHashable]]
  let back = try ScreensaverRule.uninstall(only, originalRight: nil, addedK: false)
  #expect(rules(back.rule) == [ScreensaverRule.system])
}

// MARK: the binding and the wire

@Test
func aBindingTakesOnlyWhatItSays() throws {
  let key = String(repeating: "ab", count: 32)
  let b = try Binding(sub: "user_01ABC", stations: [key.uppercased()])
  #expect(b.stations == [key])
  #expect(throws: BindingError.self) { try Binding(sub: "a b", stations: []) }
  #expect(throws: BindingError.self) { try Binding(sub: "x\"; rm -rf /", stations: []) }
  #expect(throws: BindingError.self) { try Binding(sub: "x", stations: ["12"]) }
  let data = try BindingFile.encode([501: b])
  #expect(try BindingFile.decode(data) == [501: b])
}

@Test
func theWireSaysYesOnlyInFull() {
  #expect(Wire.asked(Wire.ask(uid: 501)) == 501)
  #expect(Wire.asked(Array(Wire.ask(uid: 501).dropLast())) == nil)
  #expect(Wire.isYes(Wire.answer(true)))
  #expect(!Wire.isYes(Wire.answer(false)))
  #expect(!Wire.isYes(Array("SFLU".utf8) + [2, 1]))
}
