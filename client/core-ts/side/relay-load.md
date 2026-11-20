# Browser relay load

This side run measures the production Mesh and LeafLinks in a real browser worker.
Native stations and relays listen on loopback. Alternate entrances forward TCP to the same relay.
The transport is `ws/local-loopback`. Results do not measure TLS handshakes or public network latency.

Install dependencies and native parts as for `side:browser`.
From the repository root, install its pinned browser:

```sh
PLAYWRIGHT_BROWSERS_PATH=/absolute/task/browser-cache pnpm exec playwright-core install chromium-headless-shell
node scripts/native.ts iroh-pkg
```

Set `CHROME_BIN` to the executable in that installation.
From `client/core-ts`, run one scenario:

```sh
CHROME_BIN=/absolute/path/to/chrome-headless-shell RELAY_LOAD_W=3 RELAY_LOAD_VISIBILITY=hidden RELAY_LOAD_REVISION="$(git rev-parse HEAD)" node ../../scripts/native.ts run mesh iroh-relay -- node --test --test-force-exit side/relay-load-browser.ts
```

The default has six relays, two alternate entrances, two stations, and a five-minute window.
Run `RELAY_LOAD_W=1` and `3`, each with `RELAY_LOAD_VISIBILITY=visible` and `hidden`.
`RELAY_LOAD_R`, `RELAY_LOAD_E`, and `RELAY_LOAD_S` change the relay, entrance, and station counts.
Each station joins every workspace. Each workspace keeps its own authenticated station links and event streams.
`RELAY_LOAD_S=1` measures scopes whose inner endpoint is not needed for a peer dial.

`RELAY_LOAD_MS` changes the window for a diagnostic run. Use `300000` for comparisons.
`RELAY_LOAD_STREAM_MS` sends an application stream chunk at that interval. Zero, the default, leaves streams idle.
`RELAY_LOAD_OUT` selects the output directory. Preserve each run in a separate directory.
`RELAY_LOAD_HOT=1` (the default unless `RELAY_LOAD_CONTROLS=1`) enables the two-relay hot set on settled stations. Set `RELAY_LOAD_HOT=0` to measure the full-relay baseline.

The browser has a fresh profile and no Playwright focus emulation.
The hidden case minimizes its native window and checks `document.visibilityState` before and after the measurement.
It does not override the JavaScript property or freeze the worker.

`result.json` contains the source revision, script hashes, browser version, configuration, and measurements.
`cdp.ndjson` records socket creation, handshake, close, and frame metadata from the worker target.
It keeps payload lengths, not payload contents. Relay and browser logs are separate files.

- Concurrent sockets count completed handshakes. The report gives one-second minimum, median, and p95 samples, plus the exact peak.
- New sockets per minute count creation events. Established sockets and connections shorter than ten seconds are separate counts.
- Sent and received rates count WS frames and payload bytes. They exclude transport headers.
- Host groups include the port, so independent loopback relays remain distinct.
- Socket identities separate main and leaf endpoints from temporary entrance probes. Unknown identities remain marked as unclassified.

After the window, the runner waits ten seconds to classify its last short connections.
It then stops the relay selected by the first station link and sends an application request.
Recovery time includes the local browser RPC. The report also records connection identity and event-stream reopen counts.
Use the same script hashes, browser, fixture sizes, visibility, and stream interval when comparing changes.

Set `RELAY_LOAD_CONTROLS=1` to check the optional browser relay APIs after the measurement window.
This writes `relay-controls.json` before the relay failure experiment.
It times path recovery after clearing disabled relays, removing then inserting a relay, and combining removal/reinsertion with a disabled-policy clear. None of these cases reinserts peer addresses with `addAddr`.
A null recovery time means no path appeared within the 30-second observation window.
Every observation checks that the original station connections and event streams remain open.

Worker HTTP requests to relay hosts are grouped by host and `METHOD /path` in `measurement.http`. The raw request times are in `measurement.httpRequests` and `cdp.ndjson`. `RELAY_LOAD_MS=900000` selects a 15-minute window.

The fixture stores the final snapshot, original close reasons, connection records and close events. It fails if an original connection is lost or an application event stream reopens.

Neighbor descriptors come unchanged from native `meshConfigure` and `meshSubscribe`, as in `station/src/mesh/scope-directory.ts`.
Their relay addresses are the scope endpoint's advertised homes, not every allowed relay.
The fixture keeps `relayUrls` as the workspace allowlist, as in `station/src/mesh/leaf.ts`, and pushes descriptor changes to leaf streams.
`stationDescriptors` and `descriptorChanges` preserve these inputs in the result.
Earlier runs that replaced every peer address with all fixture relays use a different measurement setup.

Set `RELAY_LOAD_CUT=dual` for the optional simultaneous two-relay failure case.
It stops the first station's selected relay and its next lowest-RTT relay in the same turn; alternate entrances count as the same relay.
Each station gets one request through production `MeshWire`, which owns any retry or hedge.
The case records per-station event delivery, connection identity, a path timeline, and a separate 35-second post-recovery window.
The full-relay baseline can replace a connection when its path recovery races a new dial, so the default records connection and event-stream continuity without failing on those fields. Application requests and event delivery must still recover.
Set `RELAY_LOAD_REQUIRE_CONTINUITY=1` for a strict experiment: after saving the result, require all original connections to survive and no event stream to reopen.
`RELAY_LOAD_EXPECT_RELAY_PATHS=2` can require exactly two logical relay paths before the cut in a later hot-set experiment; leave it unset for the full-relay baseline.
These are real-network side measurements, not deterministic unit tests. A successful exit establishes the enabled assertions, not a recovery-time performance target or, in the default dual case, uninterrupted connections. Compare the recorded times and continuity fields against a run with the same inputs.
