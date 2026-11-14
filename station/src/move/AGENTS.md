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
- The modules: `accounts` (needs none: a login, by the share or key it is known by across the workspace, moved by
  share/index.ts `moveProfile`; this machine's own never), `chats` (needs accounts: one chat by
  `station/src/replica/handover.ts`), `jobs` (needs chats: a job a chat had running, started there once its chat is there; one
  chat moved by the tool moves its jobs right after, so a job never runs on two stations), `connects` (needs chats: a
  Slack or Feishu connect by connects/workspace.ts `move` once its chats are there; a Comma or single-session connect
  runs its chats where it runs and cannot be moved apart from them: moving the two together is not built, its plan says
  so). `agent-home`, `settings`, `repos`, `vault` plan one item each that says it is not built and what to do instead
  (`pending.ts`): a chat's worktree is made again as it moves, so it needs no repos item; a chat's secret grants do not
  move with it, its owner approves again there.
- `station_move` (`station/src/tools/move.ts`, skill `station/src/skills/stillfail-move.md`) is the scheduler's face: one chat or item
  needs no card (it pauses seconds and moving it back undoes it); `all` is confirmed once on a card by an owner or admin
  in the app (`MoveAsks`, the card choice `move`).
