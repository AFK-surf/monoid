// Who is at the other end of a Unix socket: its audit token (`LOCAL_PEERTOKEN`), then its code as the kernel ran it.
import Foundation
import Security

struct Peer {
  let token: audit_token_t
  let euid: uid_t
  let pid: pid_t

  static func of(_ fd: Int32) -> Peer? {
    var token = audit_token_t()
    var size = socklen_t(MemoryLayout<audit_token_t>.size)
    guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0, size == MemoryLayout<audit_token_t>.size else { return nil }
    // audit_token_t: val[1] the euid, val[5] the pid (bsm/libbsm.h audit_token_to_*).
    return Peer(token: token, euid: uid_t(token.val.1), pid: pid_t(token.val.5))
  }

  /// The peer's code, if it is valid now (not only as signed: as running), meets `requirement`, has the hardened
  /// runtime, is not being debugged, and holds none of the entitlements that let another process change what it runs.
  func meets(_ requirement: String) -> Bool {
    let tokenData = withUnsafeBytes(of: token) { Data($0) }
    var code: SecCode?
    guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &code) == errSecSuccess, let code else { return false }
    var req: SecRequirement?
    guard SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req else { return false }
    guard SecCodeCheckValidity(code, [], req) == errSecSuccess else { return false }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
    var info: CFDictionary?
    let flags = SecCSFlags(rawValue: kSecCSDynamicInformation | kSecCSSigningInformation | kSecCSRequirementInformation)
    guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess, let all = info as? [String: Any] else { return false }
    let signed = (all[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
    guard signed & SecCodeSignatureFlags.runtime.rawValue != 0 else { return false }
    // The running process's status (kSecCSDynamicInformation): CS_VALID set, CS_DEBUGGED not.
    var dynamic: CFDictionary?
    guard SecCodeCopySigningInformation(unsafeBitCast(code, to: SecStaticCode.self), SecCSFlags(rawValue: kSecCSDynamicInformation), &dynamic) == errSecSuccess,
      let status = ((dynamic as? [String: Any])?[kSecCodeInfoStatus as String] as? NSNumber)?.uint32Value
    else { return false }
    let csValid: UInt32 = 0x1, csDebugged: UInt32 = 0x1000_0000
    guard status & csValid != 0, status & csDebugged == 0 else { return false }
    let entitlements = all[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
    for risky in [
      "com.apple.security.get-task-allow", "com.apple.security.cs.allow-dyld-environment-variables",
      "com.apple.security.cs.disable-library-validation",
    ] where (entitlements[risky] as? Bool) == true {
      return false
    }
    return true
  }

  /// An Apple program of the authorization system (the plugin's host): what asks for an unlock on auth.sock.
  func isAuthorizationHost() -> Bool {
    // _securityagent (92) runs a mechanism that is not privileged, root one that is.
    guard euid == 92 || euid == 0 else { return false }
    return meets(#"anchor apple and (identifier "com.apple.SecurityAgent" or identifier "com.apple.SecurityAgentHelper" or identifier "com.apple.authorizationhost" or identifier "com.apple.SecurityAgentHelper-arm64" or identifier "com.apple.SecurityAgentHelper-x86_64")"#)
  }
}

/// The Helper's code as it must be: still.fail's Developer ID, its identifier. Its other checks are `Peer.meets`'s.
let helperRequirement = #"anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "D9AAN3VJK8" and identifier "fail.still.helper""#
