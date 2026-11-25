---
name: stillfail-projects
description: Manage workspace chat projects and tags (`project_manage` and `chat_configure`): inspect all projects and tags across stations, propose new projects, maintain project descriptions/paths/GitHub links, rename or merge projects, and bulk reclassify chats. Read before managing projects or tags.
---

# Workspace Projects & Tags (`stillfail-projects`)

Chats in a workspace can be classified with:
- **`project`** (single string per chat):
  - unset (`null`): unclassified (default on new chat)
  - `""`: explicitly cross-project / misc (not tied to any single project)
  - `"<name>"`: belongs to that project (e.g. `"still.fail"`, `"farview"`)
- **`tags`** (up to 3 short, reusable strings per chat, trimmed and deduplicated)

Projects are plain strings stored on each chat's host station. There are no project IDs or separate registries: a project exists as soon as a chat uses its name or an entry is saved in the workspace's shared `PROJECTS.jsonl`.

## Classifying a chat silently (`chat_configure`)

Use `chat_configure` with classification parameters only (do **not** combine with `runtime`/`model`/`effort`/`speed`/`fast`/`context`/`preset`/`repick`/`for` in the same call):

- `chat`: target chat link, session key, local `CHANNEL/THREAD_TS`, or omit / `"self"` for the current chat.
- `project`: existing project name, or `""` for cross-project / misc. Unknown project names are rejected (use `project_manage(action="propose")` instead).
- `tags`: replace all tags (array of up to 3 short strings).
- `tags_add` / `tags_remove`: incrementally add or remove tags (cannot combine with `tags`).

Rules:
- Classification changes are silent (no notice posted in the chat) and work on multi-agent threads.
- If a member manually set or confirmed a chat's classification (`projectLocked: true`), `chat_configure` refuses to overwrite `project` or `tags`. Tell the member they can change it in the chat header, or propose a new project if appropriate.
- Wait until the topic is clear before classifying; do not guess on vague openings.

## Managing projects (`project_manage`)

`project_manage` takes `{ action, args? }`. There is intentionally **no `create` action** — creating a new project always goes through `propose`.

### 1. `action: "list"`
Aggregates active projects and tags across this station, the workspace's shared `PROJECTS.jsonl` info file, and all online full stations in the same workspace (skipping rigs and other workspaces).
- `args`: none required.
- Returns `{ projects: [{ name, count, note?, refs? }], tags: [{ name, count }], peers: [{ station, name?, status }] }`.

### 2. `action: "propose"`
Proposes creating a **new** project (even when a user explicitly asks to create one) by posting a silent confirmation bar in the chat.
- `args`:
  - `name` (required string): proposed project name (max 80 chars, no commas or control characters).
  - `note` (optional string): one-line description or classification hint (e.g. "Aura component library also belongs here").
  - `refs` (optional `string[]`): reference directories (`station:path`, e.g. `tokyo:~/code/monoid`) or GitHub URLs (plain text hints for agents, not parsed or validated).
  - `to` (optional string): target thread address if not the current chat.
- On Slack, Feishu, group, and Comma threads, posts readable text with a direct still.fail link to confirm (without exposing internal notes or paths).
- **Important**: A project proposal is **not** a blocking question and does not enter 待处理. **Never end your turn with `need_human` for a proposal** (the station will reject it).

### 3. `action: "set_info"`
Maintains an existing project's shared description and reference paths/links in the workspace's `PROJECTS.jsonl` (automatically synced across workspace stations via shared memory).
- `args`:
  - `name` (required string): existing project name.
  - `note` (optional string or `null` to clear): short description / classification hints.
  - `refs` (optional `string[]` or `null` to clear): list of `station:path` or GitHub URLs.
  - `delete` (optional boolean): `true` to remove the metadata entry (does not change existing chats).

### 4. `action: "rename"` / `action: "merge"`
Bulk-replaces `project = from` with `to` on this station and all online full stations in the workspace, and merges `PROJECTS.jsonl` metadata.
- `args`:
  - `from` (required string): source project name.
  - `to` (required string for `rename`; existing project or `""` for `merge` to dissolve into cross-project): destination project name.
- Updates `projectLocked: true` chats as well while preserving their lock so no dangling project names remain.

### 5. `action: "reclassify"`
Batch-updates `project` and/or `tags` on up to 100 chats (local or cross-station). Only accepts existing projects (or `""`) and respects `projectLocked: true`.
- `args`:
  - `items`: array of `{ chat, project?, tags?, tags_add?, tags_remove? }`.

## Reporting partial results to people

Because project names live on each chat's host station, cross-station `list`, `rename`, `merge`, and `reclassify` report per-station status:
- **`status: "offline"`**: report which station(s) were offline so their chats were not scanned/renamed yet.
- **`status: "unsupported"`**: report which station(s) are running an older release that does not yet support project RPCs and need an update.
- **`infoError`**: if updating `PROJECTS.jsonl` failed during `rename`/`merge`, tell the user so they can inspect or retry.
