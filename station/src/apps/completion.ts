// The completion a station app's widget asks of the chat it is shown in (POST /apps/<id>/llm): that chat's profile,
// its own provider and key (title-completion.ts `titleCompletion`: text in, text out, no tools); the widget never sees
// the key. A profile that cannot make one is refused saying what to do instead.
import type { RunOn } from "../sessions/accounts.ts";
import type { SessionRow } from "../store/rows.ts";
import { titleCompletion } from "../sessions/title-completion.ts";
import type { AppCompletion } from "../api/routes/apps.ts";

export type CompletionSide = {
  getSession(key: string): SessionRow | null;
  profile(id: string): RunOn | null;
  allows(key: string, profile: RunOn): boolean;
  /// The station's home workspace, for a session of it (its row's `ws` null).
  home(): string;
};

export function appCompletion(side: CompletionSide, key: string): AppCompletion | null {
  const row = side.getSession(key);
  if (row === null) return null;
  const ws = row.ws ?? side.home();
  const profile = side.profile(row.profile);
  if (!profile || !side.allows(row.key, profile)) {
    return { ws, refusal: "this chat has no profile it may use for the app's model: give the chat a profile (its settings), then ask again" };
  }
  const config = titleCompletion(profile, row.model, row.key);
  if (config === null) {
    return { ws, refusal: `the chat's profile "${row.profile}" cannot answer an app (only a DeepSeek Harness profile with a key whose provider speaks chat completions can): show the app in a chat on such a profile, or add one to this station` };
  }
  return { ws, config };
}
