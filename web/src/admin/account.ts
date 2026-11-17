// Which signed-in account is the console's admin: each is asked once per page load (`admin.me`). A 404 or 403 is a
// no for good; anything else (the network, a 5xx, too many asks) is asked again a little later, twice, and then said as
// what failed with a way to try again, never as 没有权限.
import { useEffect, useState } from "preact/hooks";
import { useAccounts, type Account } from "../cloud/accounts.ts";
import { admin } from "../cloud/api.ts";
import type { CoreError } from "../core/client.ts";

type Known = "yes" | "no";
/** Each account's answer, once it is one (a failure that may pass is not kept). */
const answers = new Map<string, Known>();
const asking = new Map<string, Promise<Known>>();
/** The waits before an account is asked again after a failure that may pass. */
const AGAIN_MS = [1000, 2500];

const wait = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)); // timer: a retry after a failure, with a backoff

function ask(sub: string): Promise<Known> {
  const known = answers.get(sub);
  if (known) return Promise.resolve(known);
  let pending = asking.get(sub);
  if (!pending) {
    pending = (async () => {
      for (let i = 0; ; i++) {
        try {
          await admin.me(sub);
          answers.set(sub, "yes");
          return "yes" as const;
        } catch (e) {
          const status = (e as CoreError).status;
          if (status === 404 || status === 403) {
            answers.set(sub, "no");
            return "no" as const;
          }
          if (i >= AGAIN_MS.length) throw e;
          await wait(AGAIN_MS[i]!);
        }
      }
    })().finally(() => asking.delete(sub));
    asking.set(sub, pending);
  }
  return pending;
}

/**
 * The signed-in account that is the console's admin: undefined until known, null when none is; `error` what asking
 * failed with where none is known to be and one could not be asked (`retry` asks again).
 */
export function useAdminAccount(): { account: Account | null | undefined; error: Error | null; retry(): void } {
  const list = useAccounts();
  const [known, setKnown] = useState<Record<string, Known>>({});
  const [error, setError] = useState<Error | null>(null);
  const [round, setRound] = useState(0);
  useEffect(() => {
    let current = true;
    setError(null);
    for (const account of list ?? []) {
      ask(account.sub).then(
        (answer) => { if (current) setKnown((k) => (k[account.sub] === answer ? k : { ...k, [account.sub]: answer })); },
        (e: unknown) => { if (current) setError(e instanceof Error ? e : new Error(String(e))); },
      );
    }
    return () => { current = false; };
  }, [list, round]);
  const retry = () => { setError(null); setRound((n) => n + 1); };
  if (!list) return { account: undefined, error: null, retry };
  const found = list.find((a) => known[a.sub] === "yes");
  if (found) return { account: found, error: null, retry };
  if (list.every((a) => known[a.sub] === "no")) return { account: null, error: null, retry };
  return { account: undefined, error, retry };
}
