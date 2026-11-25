// One unlock of a locked Mac, as the guard holds it: given out once, for a moment, and relocked whatever happens once
// it was given out.
//
//   idle ──arm──▶ armed ──take──▶ consumed ──unlocked──▶ unlocked ──(all leases end, local input, any fault)──▶ relocking
//                   │ (expired, local input: never taken)                                                         │
//                   ▼                                                                                             ▼
//                 idle (the screen stayed locked: the cover goes once that is checked)                   idle (locked again)
//
// An unlock the plugin took counts as given out from then on: even when the screen is not seen unlocked within the
// wait, it is watched a while longer and relocked the moment it is seen unlocked. Only an unlock never taken may end
// without relocking. And only an unlock this guard gave out is ever relocked: a Mac its person unlocked is left alone.
import Foundation

/// The machine's own clock (`CLOCK_UPTIME_RAW`, in seconds), never the wall clock: correcting the time moves no deadline.
public typealias Seconds = Double

public enum UnlockState: Equatable, Sendable {
  case idle
  /// Given out until `until`, not taken yet.
  case armed(until: Seconds)
  /// Taken by the plugin at `at`: the screen is about to unlock (or did and was not seen yet).
  case consumed(at: Seconds)
  case unlocked(since: Seconds)
  case relocking
}

/// Why an unlock may not start.
public enum Refusal: String, Error, Sendable {
  /// Someone touched this Mac in the last `Unlock.cooldown` seconds.
  case cooldown
  /// An app holds Secure Event Input: the guard's event tap would not see the keyboard.
  case secureInput = "secure-input"
  /// Local input was seen during locked use in this login session: only a person unlocking it by hand lifts that.
  case suppressed
  /// An unlock is under way already.
  case busy
}

/// What the guard is to do next.
public enum Step: Equatable, Sendable {
  case none
  /// Lock the screen (and keep the cover until it is checked locked).
  case relock
  /// Nothing was unlocked: take the cover away once the screen is checked locked.
  case uncover
}

public struct Unlock: Sendable {
  /// How long an unlock stays given out untaken.
  public static let armedFor: Seconds = 4
  /// No local input for this long before an unlock is given out.
  public static let cooldown: Seconds = 60
  /// After the plugin took it, how long the screen may take to be seen unlocked before the unlock counts as failed
  /// (and is still relocked if seen unlocked within `watchAfter` more).
  public static let unlockWithin: Seconds = 10
  public static let watchAfter: Seconds = 5

  public private(set) var state: UnlockState = .idle
  /// Local input was seen during locked use: no unlock until a manual one (`manualUnlock`).
  public private(set) var suppressed = false
  /// Local input seen since the unlock was given out (to be relocked at once when it unlocks).
  private var inputSinceArmed = false

  public init() {}

  /// Give out one unlock, if this Mac has been left alone for `cooldown` (`idle`: its HID idle time) and no app holds
  /// Secure Event Input.
  public mutating func arm(now: Seconds, idle: Seconds, secureInput: Bool) throws {
    guard state == .idle else { throw Refusal.busy }
    if suppressed { throw Refusal.suppressed }
    if secureInput { throw Refusal.secureInput }
    if idle < Unlock.cooldown { throw Refusal.cooldown }
    inputSinceArmed = false
    state = .armed(until: now + Unlock.armedFor)
  }

  /// The plugin asks for the unlock: yes once, while it is given out and untaken.
  public mutating func take(now: Seconds) -> Bool {
    guard case let .armed(until) = state, now < until, !inputSinceArmed else { return false }
    state = .consumed(at: now)
    return true
  }

  /// The screen was seen unlocked (checked against the session, never a notification alone).
  public mutating func sawUnlocked(now: Seconds) -> Step {
    switch state {
    case .consumed:
      if inputSinceArmed {
        state = .relocking
        return .relock
      }
      state = .unlocked(since: now)
      return .none
    case .armed:
      // Unlocked without our unlock taken: a person did it. Ours is void; nothing of ours to relock.
      state = .idle
      return .none
    default:
      return .none
    }
  }

  /// Time passing: an untaken unlock expires, a taken one that never showed fails (relocked if it shows late).
  public mutating func tick(now: Seconds, locked: Bool) -> Step {
    switch state {
    case let .armed(until) where now >= until:
      state = .idle
      return .uncover
    case let .consumed(at) where now >= at + Unlock.unlockWithin:
      if !locked {
        state = .relocking
        return .relock
      }
      if now >= at + Unlock.unlockWithin + Unlock.watchAfter {
        state = .idle
        return .uncover
      }
      return .none
    default:
      return .none
    }
  }

  /// Local input (the guard's HID watch): void an untaken unlock, relock an unlocked screen, and no more unlocks until
  /// a manual one.
  public mutating func localInput() -> Step {
    suppressed = true
    switch state {
    case .armed:
      state = .idle
      return .uncover
    case .consumed:
      inputSinceArmed = true
      state = .relocking
      return .relock
    case .unlocked:
      state = .relocking
      return .relock
    default:
      return .none
    }
  }

  /// The use ends (all leases gone, a fault, the station gone): relock what was unlocked.
  public mutating func end() -> Step {
    switch state {
    case .armed:
      state = .idle
      return .uncover
    case .consumed, .unlocked:
      state = .relocking
      return .relock
    default:
      return .none
    }
  }

  /// The screen was checked locked after a relock.
  public mutating func relocked() {
    if state == .relocking { state = .idle }
  }

  /// A person unlocked this Mac by hand (a lock then an unlock no unlock of ours let through).
  public mutating func manualUnlock() {
    suppressed = false
  }
}

/// After the guard started again: whether the last guard died with an unlock out, and the screen is to be locked now.
/// The dead guard saw nothing of what happened while it was gone, so only a fresh death counts: the same boot, a
/// heartbeat at most `fresh` old. Older than that, a person may have locked and unlocked it since: never lock them out.
public struct Remains: Codable, Equatable, Sendable {
  public var boot: String
  /// `CLOCK_UPTIME_RAW` seconds of the last heartbeat while an unlock was out.
  public var heartbeat: Seconds
  public init(boot: String, heartbeat: Seconds) {
    self.boot = boot
    self.heartbeat = heartbeat
  }

  public static let fresh: Seconds = 15

  public func relockNow(boot now: String, uptime: Seconds, locked: Bool) -> Bool {
    !locked && boot == now && uptime >= heartbeat && uptime - heartbeat <= Remains.fresh
  }
}
