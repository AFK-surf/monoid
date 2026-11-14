# Moving to another station (for agents)

A migration between two stations of a workspace is a set of independent modules and a scheduler that only orders them
(左子健, 2026-11-14: 「每个模块独立迁移，有依赖的模块显式给出依赖，要求先迁依赖项，模块内部带进度迁移，可回滚」). Both stations
keep working throughout; a whole station is every item moved, its connects and logins last by their needs; moving back
is the way back. It replaces the whole-station switch of `station/src/replica/retire.ts` (its first real use, 2026-11-14:
chats paused 18 minutes, a half-moved state, no way back), whose start stays switched off.

- One seam (`module.ts`): a module plans its items (each naming what it needs, only of the modules it declares; why it
  cannot move, in words that say what to do), moves one, moves one back, says where each stands. Each item's state is
  its module's, durable, so either side started again goes on or undoes. The scheduler (`scheduler.ts`) never does a
  module's work: it orders by the items' needs (one whose need is not there is refused naming it; `withNeeds` moves
  those first), moves back in the reverse order (refused while something there needs it, naming that), and tells what
  changed. No polling.
- When an item moves away, every item here that needs it and cannot have it here any more is stopped first (a state of
  its own, `stopped.json`, held again as the station starts), never left to fail (左子健, 2026-11-14: 「依赖项被迁走就停掉啊」):
  "needs" is "usable on this station" (an account moved away that this station borrows stops nothing, `usableHere`). A
  stopped chat is held as one being handed over is: no turn, its jobs stopped and kept, what is said to it kept in its
  logs and delivered once where it ends up; nothing posted, its agent not woken. It goes on as what it waits for comes
  back, or as it moves itself. The plan says what a move would stop (`wouldStop`).
- An item may go, either way, to where something it needs is not usable: it arrives there stopped, waiting for that,
  and goes on as it arrives (the owner's rule both ways, 2026-11-14). The stopped set is each station's own: the one an
  item arrives at keeps it (a hand-over's `stoppedFor`, scheduler `noteStopped`), and is told as what it waits for
  comes (`move.arrived`). Forward goes needs-first unless asked `arriveStopped`; back, what needs an item there comes
  first, arriving stopped, then the item. Modules may need each other (chats and connects do); items may not: a chain
  of items needing each other round is refused, named.
- The modules: `accounts` (needs none: a login, by the share or key it is known by across the workspace, moved by
  share/index.ts `moveProfile`; this machine's own never), `chats` (needs accounts, connects, repos, vault: one chat by
  `station/src/replica/handover.ts`, its files a mirror by difference: the station it goes to says what it has in
  place, what differs is sent, what the lists no longer name is removed there, in its room alone), `jobs` (needs
  chats: started there once its chat is there; one chat moved by the tool moves its jobs right after, so a job never
  runs on two stations), `connects` (needs chats: a Slack or Feishu connect once the chats that came through it are
  there; a Comma or single-session connect's chats need it instead, so it goes first, stopping them here, and each goes
  on there as it moves), `repos` (a canonical clone a chat's linked worktree hangs on, by its remote: cloned there, what
  no remote has fetched from a bundle; back, removed there only where this move made it; the chat's move only adds
  its worktree, `rebuildGits` `clone: false`), `vault` (an owner's plain items and the vaults they own, rows sent as
  they are; back, the other lets go of what this move put there), `agent-home` (agent-carry.ts's merge, what it added
  kept so that back takes out exactly that) and `settings` (config.json's settings that are a person's choice,
  settings.ts `SETTINGS`; back, the other's former values). Grants do not move: a vault's is sealed to this station's
  keeper and kept in its memory, a plain one is taken up as a station starts; the owner approves again there.
- What the app shows is `GET /move?to=` (routes.ts: the modules in order with their needs, done of total, a page of
  items each), told changed as `move` on the event stream.
- `station_move` (`station/src/tools/move.ts`, skill `station/src/skills/stillfail-move.md`) is the scheduler's face: one chat or item
  needs no card (it pauses seconds and moving it back undoes it); `all` is confirmed once on a card by an owner or admin
  in the app (`MoveAsks`, the card choice `move`).
