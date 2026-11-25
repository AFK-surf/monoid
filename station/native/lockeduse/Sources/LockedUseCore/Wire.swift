// The plugin's question to the guard and its answer on `auth.sock`: fixed-size, no parsing beyond comparing bytes
// (plugin/StillfailLockedUse.c has the same layout). The plugin asks once per connection; anything else than a whole,
// well-formed `yes` answer is no.
//
//   ask:    "SFLU" | version (1 byte, 1) | op (1 byte, 1: take the unlock) | uid (4 bytes, big-endian)
//   answer: "SFLU" | version (1)         | 1: yes, take it / 0: no
import Foundation

public enum Wire {
  public static let magic: [UInt8] = Array("SFLU".utf8)
  public static let version: UInt8 = 1
  public static let take: UInt8 = 1
  public static let askSize = 10
  public static let answerSize = 6

  public static func ask(uid: UInt32) -> [UInt8] {
    magic + [version, take, UInt8(uid >> 24 & 0xff), UInt8(uid >> 16 & 0xff), UInt8(uid >> 8 & 0xff), UInt8(uid & 0xff)]
  }

  /// The uid an ask is for, nil for anything else.
  public static func asked(_ bytes: [UInt8]) -> UInt32? {
    guard bytes.count == askSize, Array(bytes[0..<4]) == magic, bytes[4] == version, bytes[5] == take else { return nil }
    return UInt32(bytes[6]) << 24 | UInt32(bytes[7]) << 16 | UInt32(bytes[8]) << 8 | UInt32(bytes[9])
  }

  public static func answer(_ yes: Bool) -> [UInt8] { magic + [version, yes ? 1 : 0] }

  public static func isYes(_ bytes: [UInt8]) -> Bool {
    bytes.count == answerSize && Array(bytes[0..<4]) == magic && bytes[4] == version && bytes[5] == 1
  }
}
