---
name: stillfail-projects
description: Manage workspace chat projects and tags (`project_manage` and `chat_configure`): inspect all projects and tags across stations, propose new projects, maintain project descriptions/paths/GitHub links, rename or merge projects, and bulk reclassify chats. Read before managing projects or tags.
---

# Workspace Projects & Tags (`stillfail-projects`)

A **project** is a **conceptual** workstream or area of work — **it does NOT need to correspond to a GitHub repo or folder**. Examples include "办公室 CI" (office CI), "客户交付", "团队招聘", "公司运维", "Q4 增长", a research topic, or a software product — many projects have **zero** repositories or folders attached. Never force chats into code-repo buckets or drop non-repo workstreams into unclassified just because they lack a repository. Use **tags** for orthogonal attributes (e.g. `review`, `bug`, `ops`, `urgent`, `client`).

Chats in a workspace can be classified with:
- **`project`** (single string per chat):
  - unset (`null`) or `""`: **Unclassified** (shown together in one unified fallback bucket; use `""` when explicitly marking a chat as having no project)
  - `"<name>"`: belongs to that project (e.g. `"Monoid"`, `"客户交付"`, `"团队招聘"`, `"Q4 增长"`)
- **`tags`** (up to 3 short, reusable strings per chat, trimmed and deduplicated)

Projects are plain strings stored on each chat's host station. There are no project IDs or separate registries: a project exists as soon as a chat uses its name or an entry is saved in the workspace's shared `PROJECTS.jsonl`.

## Classifying a chat silently (`chat_configure`)

Use `chat_configure` with classification parameters only (do **not** combine with `runtime`/`model`/`effort`/`speed`/`fast`/`context`/`preset`/`repick`/`for` in the same call):

- `chat`: target chat link, session key, local `CHANNEL/THREAD_TS`, or omit / `"self"` for the current chat.
- `project`: existing project name, or `""` to leave unclassified. Unknown project names are rejected (use `project_manage(action="propose")` instead).
- `tags`: replace all tags (array of up to 3 short strings).
- `tags_add` / `tags_remove`: incrementally add or remove tags (cannot combine with `tags`).

Rules:
- Classification changes are silent (no notice posted in the chat) and work on multi-agent threads.
- If a member manually set or confirmed a chat's classification (`projectLocked: true`), `chat_configure` refuses to overwrite `project` or `tags`. Tell the member they can change it in the chat header, or propose a new project if appropriate.
- Wait until the topic is clear before classifying; do not guess on vague openings.
- **Tags are optional (0–3) and conservative**: only add a tag when you are confident it is genuinely useful and reusable across many chats. Strongly prefer existing workspace tags (from `<workspace-projects>` or `project_manage(action="list")`). **If unsure, leave `tags` empty — never invent one-off tags, never guess tags just to fill slots, and never duplicate the project name as a tag.**

## Bulk inventory (`chat_list`)

When organizing or auditing chats across the workspace, use `chat_list` with:
- `compact: true`: compact one-line summary per chat (`- <address> "<title>" [project: <p>, tags: ..., locked, archived]`) with `limit` up to `500`. When listing another station or `station: "all"`, pass `{ station: "<station>", chat: "<address>" }` into `reclassify`.
- `offset`: paginate through all matching chats on a station (`offset: 0, 500, 1000, ...`).
- `project`: filter by an existing project name, or `""` to list only unclassified chats.
- `archived: false`: list only active chats.
- `station`: query one station at a time (by name or id) when paginating large workspaces.

## Managing projects (`project_manage`)

`project_manage` takes `{ action, args? }`. There is intentionally **no `create` action** — creating a new project always goes through `propose`.

### 1. `action: "list"`
Aggregates active projects and tags across this station, the workspace's shared `PROJECTS.jsonl` info file, and all online full stations in the same workspace (skipping rigs and other workspaces).
- `args`: none required.
- Returns `{ projects: [{ name, count, note?, refs? }], tags: [{ name, count }], peers: [{ station, name?, status }] }`.

### 2. `action: "propose"`
Proposes creating a **new** project (even when a user explicitly asks to create one) by posting a silent confirmation bar in the chat.
- Accepting a proposal **only creates/registers the project** — it does **not** auto-assign or lock the current chat. Classify chats explicitly with `chat_configure` or `reclassify` once the project exists.
- `args`:
  - `name` (required string): proposed project name (max 80 chars, no commas or control characters).
  - `note` (optional string): one-line description or classification hint (e.g. "Includes design reviews, customer onboarding, and ops for X").
  - `refs` (optional `string[]`): optional reference links, docs, folders (`station:path`), or repositories (plain text hints for agents, not required for non-code projects).
  - `to` (optional string): target thread address if not the current chat.
- On Slack, Feishu, group, and Comma threads, posts readable text with a direct still.fail link to confirm (without exposing internal notes or paths).
- **Important**: A project proposal is **not** a blocking question and does not enter 待处理. **Never end your turn with `need_human` for a proposal** (the station will reject it).

### 3. `action: "set_info"`
Maintains an existing project's shared description and reference paths/links in the workspace's `PROJECTS.jsonl` (automatically synced across workspace stations via shared memory).
- `args`:
  - `name` (required string): existing project name.
  - `note` (optional string or `null` to clear): short description / classification hints.
  - `refs` (optional `string[]` or `null` to clear): list of `station:path`, docs, or URLs.
  - `delete` (optional boolean): `true` to remove the metadata entry (does not change existing chats).

### 4. `action: "rename"` / `action: "merge"`
Bulk-replaces `project = from` with `to` on this station and all online full stations in the workspace, and merges `PROJECTS.jsonl` metadata.
- `args`:
  - `from` (required string): source project name.
  - `to` (required string for `rename`; existing project or `""` for `merge` to dissolve into unclassified): destination project name.
- Updates `projectLocked: true` chats as well while preserving their lock so no dangling project names remain.

### 5. `action: "reclassify"`
Batch-updates `project` and/or `tags` on up to **500** chats (local or cross-station), automatically grouped into one batch RPC per station. Only accepts existing projects (or `""`) and respects `projectLocked: true`.
- `args`:
  - `items`: array of `{ chat, station?, project?, tags?, tags_add?, tags_remove? }` (`chat` can be a full link, or a session key / `CHANNEL/THREAD_TS` paired with `station` name or id).

## Reporting partial results to people

Because project names live on each chat's host station, cross-station `list`, `rename`, `merge`, and `reclassify` report per-station status:
- **`status: "offline"`**: report which station(s) were offline so their chats were not scanned/renamed yet.
- **`status: "unsupported"`**: report which station(s) are running an older release that does not yet support project RPCs and need an update.
- **`infoError`**: if updating `PROJECTS.jsonl` failed during `rename`/`merge`, tell the user so they can inspect or retry.
