// A session's page in the app (still.fail cloud's pages): the link a new Slack thread is given first ("在 still.fail
// 中查看此会话", hub.ts), a job's service link and a Comma Task's (read/outflow.ts) are all made here.

/// Where this station's session pages are: its control plane's origin, its home workspace and its id there.
export type PageBase = { origin: string; workspace: string; station: string };

/// server.rs `encode` (encodeURIComponent).
const encode = encodeURIComponent;

/// The apps' own origins that one cloud answers (cloud/src/guests.ts: still.fail's and monoid's, each with its test
/// channel's), by the origin people are given: the product's, never its test channel's. A link in Slack, Feishu or a
/// card on youdid.wtf or monoid.zone was taken for another product's or a phishing page (FB-81), while the product's
/// own origin opens every station's pages, whatever channel the station or the person's app is on.
const PUBLIC: Record<string, string> = {
  "https://app.still.fail": "https://app.still.fail",
  "https://app.youdid.wtf": "https://app.still.fail",
  "https://app.monoid.build": "https://app.monoid.build",
  "https://app.monoid.zone": "https://app.monoid.build",
};

/// The app's origin for links a station enrolled at `origin` gives people about a workspace whose lock in force says
/// `origins` (the pages its passkeys sign on, `LockState.origins`: the workspace's own, the same on every station
/// that pins it): the first of them that is one of PUBLIC's where the station's own is too (the same cloud answering
/// both), else the station's own; either as people are given it (PUBLIC). A control plane of another's (a cloud of
/// one's own) keeps its origin as it is.
export const pageOrigin = (origin: string, origins: readonly string[] = []): string => {
  const own = PUBLIC[origin];
  if (own === undefined) return origin;
  for (const o of origins) {
    const said = PUBLIC[o.replace(/\/+$/, "")];
    if (said !== undefined) return said;
  }
  return own;
};

/// `<origin>/o/<workspace>/<station>/<session key>`.
export const sessionPage = (at: PageBase, workspace: string, key: string): string =>
  `${at.origin}/o/${workspace}/${at.station}/${encode(key)}`;
