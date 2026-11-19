# Station locks, cloud sync, and TCP entries (for agents)

## Lock pinning and fork choice

- Release or replace a pinned lock (home or joined workspace) only through the lock's `disable` entry or a local CLI command (`stillfail lock reset [--workspace ID]`, `enroll --join --lock`), never through control-plane frames or unauthenticated mesh requests (`station/src/cloud/state.ts` `leftJoined`, `station/src/cloud/presence.ts` `took`, `station/src/cli.ts` `nameJoinedLock`).
- Every lock (home, joined workspace, personal log) follows the rules fork choice (`station/src/cloud/log-keep.ts`, forks kept in `aside` up to `ASIDE_MOST`). Switch branches only for entries accepted by another keeper (another station of the lock, or a device with `keep`). Fresh device or control-plane entries must extend the current head.
- Devices read and submit locks over station endpoints (`GET /lock`, `/lock/person`, `/lock/devices`, `/lock/logs`, `/lock/bodies`), receive changes via `station/src/mesh/lock-events.ts`, and stations sync each other via `station/src/mesh/lock-sync.ts` and `station/src/mesh/person-sync.ts`.
- The cloud lock copy exists only for older stations and devices and goes 7 days after these stations ship. It follows fork choice (`cloud/src/lock.ts` `keepLockAt`): stations push their chain when the cloud diverges (`station/src/cloud/presence.ts` `planeParted`) without waiting on the cloud.

## Moved workspaces (`moved {root}`)

- Once a workspace chain ends in `moved {root}`, `Cloud.locked` (`station/src/cloud/lock.ts` `state4Moved`, `roster4Moved`) computes effective state from the moved chain, personal logs, and statement bodies (`station/src/cloud/lock-bodies.ts`). `Cloud.chain` reads the raw chain. When pinned, go by effective state (`leftOut`, `station/src/cli.ts` `joinWorkspace`), never the control plane's `locked` flag.
- Accept statement bodies only when committed by a kept log entry (`bodyRefusal`). Serve them only within their workspace to stations and devices in the state (`Cloud.givenTo`), or send only the removal chain to a removed device (`toldOut`). Support head-based sync (`GET /lock/heads`, `POST /lock/given`) alongside whole reads for older cores.
- Refused devices receive no logs or bodies and get a `left` refusal (`leftOf`) listing up to 16 approving app devices plus `apps` (whether the person has any app device in the state). Before a chain moves, `GET /lock/logs` gives admitted devices member logs (`Cloud.logsOf`) so handover drops no member devices.
- An unpinned joined station never pins a moved chain from the control plane alone: pin only once workspace-station logs and bodies produce a state naming this station's key (`station/src/mesh/moved-pin.ts`). A home station enrolled by token alone pins only what an owner's device brings (`POST /lock`, `pinBrought`: state must admit that device as owner and name this station). A hash-enrolled station pins only a chain holding that hash.
- After a move, the root person is an ordinary member (`rules/AGENTS.md` `~root`). Effective state selects their active logs (`station/src/mesh/serve.ts` `ownChainsOf`), and `station/src/mesh/person-chains.ts` never evicts the root log under `CHAINS_A_PERSON`.

## Device builds and version floors (`station/src/api/moved-from.ts`)

- Record the latest build seen per device (`station/src/mesh/device-builds.ts`) and serve `builds`, `heads`, `carried`, `bind`, and `rootout` in `GET /lock` only for devices named by the asker's lock.
- Return `426` (`movedTooOld` / `movedFloor`) to clients below `MOVED_FROM_BUILD`, `LOGS_ANY_FROM_BUILD` (when logs exceed `LOGS_BEFORE`), or `ROOT_OUT_FROM_BUILD` (when the genesis person is removed from `~root`) so the app prompts them to update.

## Lock tests

- Moved-workspace tests: `station/test/lock-moved-model.test.ts`, `station/test/lock-left-out.test.ts`, `station/test/lock-moved-joined.test.ts`, `station/test/lock-moved-pin.test.ts`, `station/test/device-builds.test.ts`, `station/test/lock-heads.test.ts`, `station/test/lock-root-out.test.ts`.
- World simulation (`station/test/lock-world-sim.ts`, run by `station/test/lock-world-1.test.ts` to `-3`): passes when failures match `KNOWN_SEEDS` and `KNOWN_TOLD` exactly. Remove any entry that now passes so those tables only shrink.
- Fork-choice model runners (`station/test/lock-fork-choice.test.ts`, `station/test/lock-roster.test.ts`, `station/test/lock-roster4.test.ts`) assert model soundness. Use `LOCK_FORK_*`, `LOCK_ROSTER_*`, and `LOCK_ROSTER4_*` for full counts.

## Cloud TCP entries

- `config.json` can name one `cloudEntry` (`{"origin":"https://app.still.fail","host":"entry.example","port":24443}`), supplied and updated by the owner with no discovery or health polling.
- Only canonical still.fail cloud HTTP and the presence socket use it. Comma, custom origins, and third-party downloads keep direct routes. TLS, Host, signatures, and certificate checks keep the canonical origin.
- `station/src/cloud/transport.ts` owns pending dials and the HTTP pool. A request cancellation never aborts a pool dial. Direct TLS gets 1 second before the entry starts, and both candidates share 10 seconds for HTTP and 20 seconds for presence Upgrade.
