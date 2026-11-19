# Station mesh base, ways, relays, and marks (for agents)

## Mesh base isolation

- The mesh base knows nothing of still.fail admission or routes so another program can run on it:
  - `station/src/mesh/wire.ts`: lines and requests on a stream.
  - `station/src/mesh/door.ts`: control-stream hello, renewals, and one request per stream. Holds a refused hello until closed, or closes it with the refusal code and reason after `REFUSED_CLOSE_MS`.
  - `station/src/mesh/endpoint.ts`: addon endpoint wrapper loaded from a caller-provided path (`STILLFAIL_MESH_NATIVE` and extras live in `station/src/mesh/native.ts`).
  - `station/src/mesh/accept.ts`: accepts connections, serves them with the caller's handler (`station/src/mesh/mesh.ts` provides station protocols), and closes each with code 0 after serving finishes so writes arrive first.
- `station/src/mesh/serve.ts` owns still.fail admission (credentials, locks, revocations) and request handling, passed to `door.ts` as `Admit`.
- `scripts/mesh-base.ts` (run by `scripts/check.sh`) rejects imports from station business modules (including types) and any occurrence of still.fail's name in base files. Pass needed data as parameters.

## Workspace ways and relays

- A workspace's custom relays and disabled routes live on its stations (`station/src/mesh/ways.ts`): one newest record per workspace, synced across its stations, read by devices via `GET /ways`, and pushed via `ways`.
- An agent adds a relay with the `relays` tool without human approval because relays carry only end-to-end encrypted packets and slow relays are ignored. Probe relay reachability before adding, and record who added it.
- Each station reports its kept record to still.fail cloud on the presence socket (`station/src/cloud/presence.ts` `waysTeller`) without waiting on it, so browsers and new devices learn workspace relays from `/v1/me`.
- Disabled relays apply to stations too (`station/src/mesh/relays.ts`): keep each station on its workspaces' enabled relays (`wantedRelays`, falling back to still.fail's when in none) and dial peers only through relays enabled by shared workspaces (`stationAddr`, `disabledRelays`, overriding Address Lookup).
- `station/src/mesh/peer-relays.ts` holds the live per-peer policy shared by RPC, HTTP, and existing backup paths across all shared workspaces. Await it before use, and restore it on front reconnect before routing or dialing.

## Station name and icon

- A station's name and mark (emoji, glyph, or image address) belong to the station (`station/src/mesh/station-marks.ts`), shared across all its workspaces and changed only while online.
- Owners and admins set it via `PUT /station-mark`. Peer stations keep and sync copies, devices read `GET /station-marks`, and changes push via `stationMarks`.
- Unset stations fall back to the cloud listing. Devices still mirror updates to the cloud for older apps. Images stay in the cloud image store while the record holds the address.
- A rig (task-only station) keeps no station-mark record and keeps its cloud name.
