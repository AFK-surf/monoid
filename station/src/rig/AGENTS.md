# Task-only stations (rigs) (for agents)

## Whole vs. rig mode

- A station can be whole (`full`), task-only (`tasks` / `rig`), or mixed across multiple workspaces (e.g., whole in WS A and task-only in WS B). A pure-rig process (`RigLive`) runs only when every workspace the machine belongs to is task-only; a mixed-mode station runs `StationLive` with `RigSide` mounted so rig-mode workspaces enforce rig grants, explicit peer method allowlists, and refuse member HTTP connections while full-mode workspaces operate normally.
- Both modes share one release and one station list. Enroll directly as a rig with `enroll --rig <owner personal lock hash>`, join additional workspaces as a rig (`enroll --join --rig <hash>`, `POST /workspaces/join`, or `rig.join`), or switch modes per workspace in the app without reinstalling. Apps do not connect to rigs directly: workspace stations report rig status (`station/src/rigs/`).

## Ownership and mode switching

- A whole station may be converted to a rig in a workspace by the member who added it or by any workspace owner or admin; whoever converts it becomes the rig's owner in that workspace. An existing rig is never taken over: only its owner changes its grants, settings, devices, or converts it back to whole, and converting back also requires workspace owner or admin permission (regular members cannot add a whole station). `cloud/src/directory/stations.ts` `setStationMode` enforces this per workspace because the machine does not know who added it.
- Changing mode requires two matching signals per workspace, never one alone:
  1. An out-of-band machine request (kept for 1 hour): whole to rig via `POST /mode` from a member's device carrying their lock hash to pin, or rig to whole via the owner's signed `rig.full`.
  2. The control plane listing the new mode under that same owner (`station/src/cloud/presence.ts`).
- Before switching a workspace from whole to rig, stop agents for that workspace (or all agents, connects, and jobs if no full workspaces remain) (`station/src/sessions/agents.ts`). Keep existing chats in the database, hidden until the station becomes whole in that workspace again.

## Signed grants and moved workspaces

- A chat uses a rig only with a statement signed by the rig owner's personal lock (`client/core-ts/src/rig-form.ts`): a fixed or idle-timed grant, a revocation, or 免批准 (open to every chat in the workspace). The rig verifies signatures against its pinned lock itself. Neither cloud nor another station can bypass this.
- In safe mode, stations accept a rig only after its owner signs for it (`station/src/rigs/adds.ts`) or the lock already lists it.
- A rig that joined before safe mode was turned on pins no workspace lock. Its owner's add names one (`AddBody.lock`), and the rig names it to pin only when a key on its owner's personal lock signed it (the add, or `pin` beside a workspace-lock-signed add). It never replaces a lock already pinned or named (`station/src/rig/grants.ts` `added`, `station/src/rig/module.ts`).
- In a moved workspace, the rig pins the chain by its enrollment hash and waits for state. Meanwhile it answers peer stations with `rig.added` and `rig.proof` (`station/src/mesh/peer.ts` `heardWaiting`), and a peer sends it the logs and bodies (`Cloud.givenTo`, `station/src/mesh/person-sync.ts`) which the rig verifies against its pinned chain (`station/test/rig-moved.test.ts`).

## Minimal rig surface and attached devices

- A rig never sends requests to stations. It only pushes notifications (`RIG_TELLS` and `task.changed` in `station/src/mesh/peer.ts`).
- Every rig method requires a grant unless listed in `UNGATED` (`station/src/rig/module.ts`), which is restricted to reading back and stopping work a chat already started there. Never add new methods to `UNGATED` for convenience.
- Devices requiring owner approval attach to a rig and are signed by its owner (`client/core-ts/src/rig-form.ts` `DeviceBody`). `station/src/rig/grants.ts` stores and checks device grants (granted alone, with the rig, or 免批准).
