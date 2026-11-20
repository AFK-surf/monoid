// still.fail's own notices in a chat, as the clients draw them (the web's Chat.tsx SystemNotice, the desktop's
// sfdesk/message.mbt): self-contained, for the web's demo core too.

/** What a notice about a profile says to do, as the station words it now and before (station.json `station.notice.auth`,
 * `station.notice.refused`; before 2026-11-19 they ended in 在 Profile 中…, in the profile), and as a pill says it: what
 * went wrong, its profile named where it is known, then the action that opens that profile's page. */
const PROFILE_ACTIONS: { said: string[]; words: (name: string | null) => string; action: string }[] = [
  { said: ["账号认证失败：在 Profile 中重新登录", "账号认证失败：重新登录", "账号认证失败"], words: (name) => (name !== null ? `「${name}」认证失败` : "账号认证失败"), action: "重新登录" },
  { said: ["Sign-in failed: sign in again in the profile", "Sign-in failed: sign in again", "Sign-in failed"], words: (name) => (name !== null ? `${name} sign-in failed` : "Sign-in failed"), action: "Sign in again" },
  { said: ["模型服务不支持此 station 所在地区：在 Profile 中设置代理", "模型服务不支持此 station 所在地区：设置代理", "模型服务不支持此 station 所在地区"], words: () => "模型服务不支持此 station 所在地区", action: "设置代理" },
  { said: ["The provider doesn't serve this station's region: set a proxy in the profile", "The provider doesn't serve this station's region: set a proxy", "The provider doesn't serve this station's region"], words: () => "The provider doesn't serve this station's region", action: "Set proxy" },
];

/** still.fail's notice as a chat shows it: a line of the UI, not prose. The station begins its failures with ⚠️ (Slack
 * shows it so): `failed`, the mark left out of `words`; no 。 at its end (stations before 2026-09-30 wrote them as
 * sentences). One about a profile (`profiled`): one the station says what to do of (PROFILE_ACTIONS) says what went
 * wrong (its profile's name, `profileName`, in it where known) and that, `profileAction`, which opens the profile's
 * page; another, where what went wrong begins in `words`, after its ： (or ": "), which links to that page. A failure
 * the station says what failed said of under it (a code block after its first paragraph, 2026-11-03): that apart, as
 * `detail`, shown when the notice is opened. */
export function noticeOf(text: string, profiled: boolean, profileName?: string | null): { failed: boolean; words: string; linkAt?: number; profileAction?: string; detail?: string } {
  const mark = /^⚠️\s*/u.exec(text);
  const all = mark ? text.slice(mark[0].length) : text;
  const block = /\n\n```\n([\s\S]*?)\n?```\s*$/u.exec(all);
  const words = (block ? all.slice(0, block.index) : all).replace(/。\s*$/u, "");
  const out: { failed: boolean; words: string; linkAt?: number; profileAction?: string; detail?: string } = { failed: mark !== null, words };
  const known = profiled ? PROFILE_ACTIONS.find((a) => a.said.includes(words)) : undefined;
  if (known !== undefined) {
    out.words = known.words(profileName ? profileName : null);
    out.profileAction = known.action;
  } else if (profiled) {
    const zh = words.indexOf("：");
    const en = zh >= 0 ? -1 : words.indexOf(": ");
    if (zh >= 0) out.linkAt = zh + 1;
    else if (en >= 0) out.linkAt = en + 2;
  }
  if (block && block[1]!.trim() !== "") out.detail = block[1]!.trim();
  return out;
}
