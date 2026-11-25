# GitHub Copilot

The station's `copilot` runtime runs each session as one `copilot --acp --stdio` process (the GitHub Copilot CLI's own
ACP server), like `dsh` and Pi. The station installs the CLI through its updater (`@github/copilot`); there is no
station-side ACP adapter.

## How a session runs

- One CLI process per session, under the station's runner.
- `COPILOT_HOME` is the profile's `copilot/` directory, so its session state and settings are the profile's.
- The station writes its instructions to `copilot/instructions/stillfail.instructions.md` and points
  `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` there. The CLI's own tools (`bash`, `edit`, `view`, `web_fetch`, …) are excluded:
  a session gets the station's MCP server from ACP's `session/new`, and nothing else.
- The profile's model is passed with `--model`; its reasoning effort with `--effort`. `auto` leaves Copilot's own
  routing.
- `session/prompt`, `session/cancel`, streaming updates, tool calls and permission requests are ACP's, handled by
  `station/src/agents/acp.ts`.

## Auth

Profiles sign in with GitHub's OAuth device flow (`station/src/accounts/copilot.ts`): the app shows
`github.com/login/device` and the code, and the token is kept in `<profile home>/copilot/github-token`. The driver passes
it as `COPILOT_GITHUB_TOKEN`; a token in `access.key` or the profile's environment works too. With none, the CLI uses its
own `copilot login` in `COPILOT_HOME` (development).

## Models and allowance

The profile check lists the account's chat models from GitHub's Copilot model catalog
(`https://api.githubcopilot.com/models`), and reads the premium-request allowance from
`https://api.github.com/copilot_internal/user` (window, reset date and plan). The app shows both; a chat can pick any
listed model.

## Packaging

The CLI is a station runtime, installed and updated by the station's software page (`npm install -g @github/copilot`),
not bundled in the station's own tarball. Its `--acp` mode is in public preview and subject to change; pin the station's
CLI through the updater and probe `initialize` capabilities rather than assuming.

## Trying it

```sh
pnpm install
pnpm --filter @stillfail/station build
# run a disposable station from source (see docs/development.md)
```

Add a profile with `runtime: "copilot"`, sign it in, then open a chat on it. The session's runtime is `copilot`; its
transcript is kept under `<profile home>/copilot/sessions`.
