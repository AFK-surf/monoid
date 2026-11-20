# Task-only stations (rigs) (for agents)

## Whole vs. rig mode

- A station runs either whole or task-only (只执行任务, `rig` in `station/src/rig/` and `station/src/rigs/`). A rig runs no agents, keeps no chats in sight, serves no devices, and runs only tasks sent by workspace stations.
- Both modes share one release and one station list. Enroll directly as a rig with `enroll --rig <owner personal lock hash>`, or switch modes in the app without reinstalling. Apps do not connect to rigs directly: workspace stations report rig status (`station/src/rigs/`).

## Ownership and mode switching

- A whole station may be converted to a rig by the member who added it or by any workspace owner or admin; whoever converts it becomes the rig's owner. An existing rig is never taken over: only its owner changes its grants, settings, devices, or converts it back to whole, and converting back also requires workspace owner or admin permission (regular members cannot add a whole station). `cloud/src/directory/stations.ts` `setStationMode` enforces this because the machine does not know who added it.
- Changing mode requires two matching signals, never one alone:
  1. An out-of-band machine request (kept for 1 hour): whole to rig via `POST /mode` from a member's device carrying their lock hash to pin, or rig to whole via the owner's signed `rig.full`.
  2. The control plane listing the new mode under that same owner (`station/src/cloud/presence.ts`).
- Before switching whole to rig, stop all agents, connects, and jobs (`station/src/sessions/agents.ts`). Keep existing chats in the database, hidden until the station becomes whole again.

## Signed grants and moved workspaces

- A chat uses a rig only with a statement signed by the rig owner's personal lock (`client/core-ts/src/rig-form.ts`): a fixed or idle-timed grant, a revocation, or 免批准 (open to every chat in the workspace). The rig verifies signatures against its pinned lock itself. Neither cloud nor another station can bypass this.
- In safe mode, stations accept a rig only after its owner signs for it (`station/src/rigs/adds.ts`) or the lock already lists it.
- In a moved workspace, the rig pins the chain by its enrollment hash and waits for state. Meanwhile it answers peer stations with `rig.added` and `rig.proof` (`station/src/mesh/peer.ts` `heardWaiting`), and a peer sends it the logs and bodies (`Cloud.givenTo`, `station/src/mesh/person-sync.ts`) which the rig verifies against its pinned chain (`station/test/rig-moved.test.ts`).

## Minimal rig surface and attached devices

- A rig never sends requests to stations. It only pushes notifications (`RIG_TELLS` and `task.changed` in `station/src/mesh/peer.ts`).
- Every rig method requires a grant unless listed in `UNGATED` (`station/src/rig/module.ts`), which is restricted to reading back and stopping work a chat already started there. Never add new methods to `UNGATED` for convenience.
- Devices requiring owner approval attach to a rig and are signed by its owner (`client/core-ts/src/rig-form.ts` `DeviceBody`). `station/src/rig/grants.ts` stores and checks device grants (granted alone, with the rig, or 免批准).
