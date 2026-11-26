import Testing
@testable import StillfailHelper

@Test
func daemonGrantedSinceDetectsScreenAndFolderGrants() {
  let none: [String: String] = [
    "all": "unknown", "documents": "unknown", "desktop": "unknown",
    "downloads": "unknown", "removable": "unknown", "network": "unknown",
  ]
  #expect(!Daemon.grantedSince(started: (false, false), startedFiles: none, fresh: ["capture": false, "control": false, "files": none]))
  // Screen grants still trigger restart.
  #expect(Daemon.grantedSince(started: (false, false), startedFiles: none, fresh: ["capture": true, "control": false, "files": none]))
  #expect(Daemon.grantedSince(started: (false, false), startedFiles: none, fresh: ["capture": false, "control": true, "files": none]))
  // Every individual folder grant gained after startup triggers restart.
  for grant in FileGrant.allCases {
    var granted = none
    granted[grant.rawValue] = "granted"
    #expect(Daemon.grantedSince(started: (false, false), startedFiles: none, fresh: ["capture": false, "control": false, "files": granted]))
    // Already granted at startup: no restart when nothing new was granted.
    #expect(!Daemon.grantedSince(started: (false, false), startedFiles: granted, fresh: ["capture": false, "control": false, "files": granted]))
  }
  var withDocs = none
  withDocs["documents"] = "granted"
  // Full Disk Access gained after startup triggers restart even if individual folders were granted before.
  var withAll = withDocs
  withAll["all"] = "granted"
  #expect(Daemon.grantedSince(started: (false, false), startedFiles: withDocs, fresh: ["capture": false, "control": false, "files": withAll]))
  // Missing files map does not falsely trigger restart.
  #expect(!Daemon.grantedSince(started: (true, true), startedFiles: none, fresh: ["capture": true, "control": true]))
}

@Test
func filesAccessStatePrefersFreshLookupAndFallsBackToLive() {
  let live: (FileGrant) -> String = { $0 == .downloads ? "granted" : "unknown" }
  #expect(Files.accessState(for: .documents, liveState: live, freshFiles: ["all": "unknown", "documents": "granted"]) == "granted")
  #expect(Files.accessState(for: .desktop, liveState: live, freshFiles: ["all": "unknown", "desktop": "denied"]) == "denied")
  #expect(Files.accessState(for: .documents, liveState: live, freshFiles: ["all": "granted", "documents": "unknown"]) == "granted")
  // Nil or missing entry falls back to the running process's live preflight.
  #expect(Files.accessState(for: .downloads, liveState: live, freshFiles: nil) == "granted")
  #expect(Files.accessState(for: .documents, liveState: live, freshFiles: ["all": "unknown"]) == "unknown")
}

@Test
func filesShouldRestartHandlesStaleGrantAndEpermRefusals() {
  let none: [String: String] = ["all": "unknown", "documents": "unknown", "desktop": "unknown"]
  let hadDocs: [String: String] = ["all": "unknown", "documents": "granted", "desktop": "unknown"]

  // Running process guardGrant refused with `grant`, but a fresh process already sees it granted: restart.
  #expect(Files.shouldRestart(
    refusalCode: "grant",
    refusalGrant: .documents,
    pathGrants: [.documents],
    startedFiles: none,
    liveState: { _ in "unknown" },
    freshFiles: { ["all": "unknown", "documents": "granted"] }
  ))
  // Full Disk Access in fresh process also triggers restart on `grant`.
  #expect(Files.shouldRestart(
    refusalCode: "grant",
    refusalGrant: .documents,
    pathGrants: [.documents],
    startedFiles: none,
    liveState: { _ in "denied" },
    freshFiles: { ["all": "granted", "documents": "unknown"] }
  ))
  // Genuinely not granted in fresh process (or fresh unavailable): do not restart.
  #expect(!Files.shouldRestart(
    refusalCode: "grant",
    refusalGrant: .documents,
    pathGrants: [.documents],
    startedFiles: none,
    liveState: { _ in "unknown" },
    freshFiles: { ["all": "unknown", "documents": "unknown"] }
  ))
  #expect(!Files.shouldRestart(
    refusalCode: "grant",
    refusalGrant: .documents,
    pathGrants: [.documents],
    startedFiles: none,
    liveState: { _ in "unknown" },
    freshFiles: { nil }
  ))

  // EPERM on a folder already granted at startup (e.g. POSIX mode): never spawns fresh, never restarts.
  var freshCalls = 0
  #expect(!Files.shouldRestart(
    refusalCode: "EPERM",
    refusalGrant: nil,
    pathGrants: [.documents],
    startedFiles: hadDocs,
    liveState: { _ in "granted" },
    freshFiles: { freshCalls += 1; return ["all": "unknown", "documents": "granted"] }
  ))
  #expect(freshCalls == 0)

  // EPERM on a folder granted since startup: restarts via liveState without spawning fresh.
  #expect(Files.shouldRestart(
    refusalCode: "EPERM",
    refusalGrant: nil,
    pathGrants: [.documents],
    startedFiles: none,
    liveState: { $0 == .documents ? "granted" : "unknown" },
    freshFiles: { freshCalls += 1; return nil }
  ))
  #expect(freshCalls == 0)

  // EACCES where liveState is still stale but fresh sees granted: restarts via fresh.
  #expect(Files.shouldRestart(
    refusalCode: "EACCES",
    refusalGrant: nil,
    pathGrants: [.documents],
    startedFiles: none,
    liveState: { _ in "unknown" },
    freshFiles: { freshCalls += 1; return ["all": "unknown", "documents": "granted"] }
  ))
  #expect(freshCalls == 1)

  // Cross-folder op (e.g. rename from already-granted Documents into newly-granted Desktop): restarts for Desktop.
  #expect(Files.shouldRestart(
    refusalCode: "EPERM",
    refusalGrant: nil,
    pathGrants: [.documents, .desktop],
    startedFiles: hadDocs,
    liveState: { $0 == .documents ? "granted" : "unknown" },
    freshFiles: { freshCalls += 1; return ["all": "unknown", "documents": "granted", "desktop": "granted"] }
  ))
  #expect(freshCalls == 2)

  // Non-permission refusal never restarts or spawns fresh.
  #expect(!Files.shouldRestart(
    refusalCode: "ENOENT",
    refusalGrant: nil,
    pathGrants: [.documents],
    startedFiles: none,
    liveState: { _ in "granted" },
    freshFiles: { freshCalls += 1; return ["all": "granted"] }
  ))
  #expect(freshCalls == 2)
}
