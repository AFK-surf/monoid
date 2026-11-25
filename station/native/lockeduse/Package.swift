// swift-tools-version: 6.2
// Locked use: agents of still.fail use this Mac's screen while it is locked, behind a guard (AGENTS.md here says how
// it holds together). Three parts installed by an administrator into root-owned paths, never by the station itself:
//   stillfail-guard      the guard (Guard.app): grants one unlock at a time, covers the displays, relocks on local input
//   stillfail-lockeduse  the administrator's tool (bind, rule-install, rule-uninstall, uninstall)
//   plugin/              the SecurityAgent mechanism (C, built by plugin/build.sh): asks the guard for its one unlock
// LockedUseCore is what of them is decided without the machine: the unlock's state, the screensaver rule's rewrite, the
// binding, the plugin's wire; `swift test` here tests it.
import PackageDescription

let package = Package(
  name: "LockedUse",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "stillfail-guard", targets: ["StillfailGuard"]),
    .executable(name: "stillfail-lockeduse", targets: ["StillfailLockedUse"]),
  ],
  targets: [
    .target(name: "LockedUseCore", swiftSettings: [.swiftLanguageMode(.v5)]),
    .executableTarget(name: "StillfailGuard", dependencies: ["LockedUseCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    .executableTarget(name: "StillfailLockedUse", dependencies: ["LockedUseCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(name: "LockedUseCoreTests", dependencies: ["LockedUseCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
  ]
)
