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
  those first, but not one whose leaving would stop other items here: both refused, naming what it would stop; a need
  usable there though it is not, `usableThere`, is neither waited for nor taken along), moves back in the reverse order
  (refused while something there needs it, naming that), and tells what
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
- The modules: `accounts` (needs none: a login, by the share, key or own profile it is known by across the workspace
  now, moved by share/index.ts `moveProfile`; this machine's own never; one not shared whose login can be
  (`shareRefusal`) is shared as it moves, with the two stations alone, so this station borrows it after and nothing here
  stops (the lead, 2026-11-14: a drill's one login carried 396 chats), that share undone as it comes back unless a person
  opened it to another station meanwhile (`accounts-shared.json`); one that cannot be (SuperGrok, Cursor, Devin,
  Antigravity, a Kimi sign-in) is gone from here and stops what needs it; what each was known by kept as it moves away,
  `accounts-known.json`; there once the other hosts it: one it only borrows is here, this station's still, and usable
  there, `usableThere`), `chats` (needs accounts, connects, repos, vault: one chat by
  `station/src/replica/handover.ts`, its files a mirror by difference: the station it goes to says what it has in
  place, what differs is sent, what the lists no longer name is removed there, in its room alone), `jobs` (needs
  chats: started there once its chat is there; one chat moved by the tool or the app moves its jobs right after, and
  moved back takes them back first, so a job never runs on two stations; a job back while its chat is there is kept
  here stopped, and starts as its chat comes), `connects` (needs chats: a Slack or Feishu connect once the chats that came through it are
  there; a Comma or single-session connect's chats need it instead, so it goes first, stopping them here, and each goes
  on there as it moves: the connect arrives knowing which of its chats are still to come (`connect.take`'s
  `awaiting`) and keeps what its platform says, in order, until they are all there, never a new session for one on its
  way, connects/workspace.ts `arrived`), `repos` (a canonical clone a chat's linked worktree hangs on, by its remote: cloned there, what
  no remote has fetched from a bundle; back, removed there only where this move made it; the chat's move only adds
  its worktree, `rebuildGits` `clone: false`), `vault` (an owner's plain items and the vaults they own, rows sent as
  they are; back, the other lets go of what this move put there), `agent-home` (agent-carry.ts's merge, what it added
  kept so that back takes out exactly that) and `settings` (config.json's settings that are a person's choice,
  settings.ts `SETTINGS`: what the other has already is never overwritten, the owner's 「不好搬但有其它办法规避的部分直接规避，
  避免脚本乱改改错」: one it lacks it takes, a map the keys it lacks, another value of its own it keeps and the item
  cannot move; back takes out exactly what was added). These four copy, so what moved is still usable here
  (`usableHere`): moving one stops nothing. What each moved is kept across a start (`kept.ts`). Grants do not move: a vault's is sealed to this station's
  keeper and kept in its memory, a plain one is taken up as a station starts; the owner approves again there.
- What the app shows is `GET /move?to=` (routes.ts: the modules in order with their needs, done of total, how many cannot move (`cannot`), a page of
  items each, and `last`, the workspace's last turn and what came of it, kept in `last.json`), told changed as `move`
  on the event stream. People move with `POST /move` and `POST /move/back` (owners and admins; 202, the scheduler's
  turn going on; one turn at a time, an agent's and a person's alike: a second while one runs is 409). No card there:
  the press in the app is the confirmation.
- Moving is switched on per machine (config.json `move: true`, off unless set; not one of the settings that move), and
  is offered only where it is on (the overview's `move.offered`) until the real run between our own stations has
  passed; then the switch goes (the lead, 2026-11-14). Off, every turn is refused before anything is held (the
  scheduler asks `refusal` first: here, then `move.open` there, one that refuses it being from before and off, one not reached said to be out of reach), and a
  station that is off takes no `handover.begin` and sends nothing back; `GET /move` still answers.
- A message a device wrote under its idempotency key (api/admin.ts `once`) goes with its chat: what was kept of it is
  sent with `handover.show` and kept there under the thread's id there, so the device's retry there is answered as
  here, not posted again (`keptSends`, `keepSends`).
- A chat's files go twice (`station/src/replica/handover.ts`): first while it works, then held only for what changed
  since, the station it goes to keeping what the first placed (`placed.txt`), so its pause does not grow with its room.
- A turn holds the station's self-update from its first item to its end, and the station taking a request or a chat
  holds it while it does (`station/src/updates/holds.ts`). A turn cut by a stop is kept as `last` saying so (`turn.json`); as
  the station starts, and as a station is heard from again, what waits for an item that is here goes on
  (`settleStopped`). `POST /move/stop` and station_move `stop` stop a turn: nothing further starts, a chat not yet
  gone gives up and goes on here, one gone completes. `all` goes through every chat a page at a time.
- `station_move` (`station/src/tools/move.ts`, skill `station/src/skills/stillfail-move.md`) is the scheduler's face: one chat or item
  needs no card (it pauses seconds and moving it back undoes it); `all` is confirmed once on a card by an owner or admin
  in the app (`MoveAsks`, the card choice `move`).
