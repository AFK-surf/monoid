// still.fail Guard (Package.swift says the three parts): one per user of this Mac, started by launchd in their login
// session (/Library/LaunchAgents/fail.still.guard.plist). It listens on two sockets in its user's directory
// (Paths.user, root-made `<uid>:_securityagent 0750`):
//
//   control.sock (0600)  the Helper alone (its code checked, Peer.meets): one connection is one locked use. A JSON line
//                        `{"op":"begin","lease":…}` → `{"ok":true}` once the screen is unlocked behind the cover, or
//                        `{"error":…,"code":…}`; the connection then stays open while the use lasts. Its end, from either
//                        side and for any reason, relocks.
//   auth.sock (0660)     the SecurityAgent plugin alone (an Apple program of the authorization system): Wire's one
//                        question, answered yes once per unlock given out (Unlock.take).
//
// Whatever goes wrong relocks: the Helper gone, a local input, the event tap turned off, a heartbeat missed, this
// process ending (the Helper watches it and locks itself). The cover goes only once the screen is checked locked.
import AppKit
import Foundation
import LockedUseCore

signal(SIGPIPE, SIG_IGN)

let uid = getuid()
guard uid >= 500 else { exit(0) }
let bindings = (try? Data(contentsOf: URL(fileURLWithPath: Paths.binding))).flatMap { try? BindingFile.decode($0) } ?? [:]
guard bindings[uid] != nil else {
  // Not bound: nothing to guard (launchd keeps it down after a clean exit).
  exit(0)
}

let application = NSApplication.shared
_ = application.setActivationPolicy(.prohibited)
let guardian = Guardian(uid: uid)
guardian.start()
application.run()
