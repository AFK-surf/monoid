// The pictures a browser's page cannot read from where they are (GET /v1/pictures?url=: client/core-ts's
// picture-relay.ts says which): fetched here and answered as this host's own. Slack's people's and bots' pictures,
// whose server says nothing of other pages, so the app in a browser drew their initials instead. Only those: any other
// address is refused, and what comes back is answered only when it is a picture (not SVG, which runs scripts) of up to
// PICTURE_BYTES. Their addresses name each picture for good, so they are kept a day, here and by the browser.
import { reply } from "./auth";
import { relayedPicture } from "../../client/core-ts/src/picture-relay.ts";

/** How large a picture fetched for a page may be. */
export const PICTURE_BYTES = 2 * 1024 * 1024;
const KEPT_SECONDS = 86_400;

/** GET /v1/pictures: the picture at `url`, as `get` (the Worker's fetch) has it. */
export async function servePicture(request: Request, get: (url: string, init: RequestInit) => Promise<Response> = fetch): Promise<Response> {
  const url = new URL(request.url).searchParams.get("url") ?? "";
  if (!relayedPicture(url)) return reply({ error: "not_relayed" }, 400);
  let r: Response;
  try {
    r = await get(url, { redirect: "manual", headers: { "user-agent": "stillfail-cloud" }, cf: { cacheEverything: true, cacheTtl: KEPT_SECONDS } } as RequestInit);
  } catch {
    return reply({ error: "unreachable" }, 502);
  }
  const type = (r.headers.get("content-type") ?? "").split(";")[0]!.trim().toLowerCase();
  if (r.status !== 200 || !type.startsWith("image/") || type.includes("svg")) {
    await r.body?.cancel().catch(() => {});
    return reply({ error: "not_found" }, 404);
  }
  if (Number(r.headers.get("content-length") ?? 0) > PICTURE_BYTES) {
    await r.body?.cancel().catch(() => {});
    return reply({ error: "too_large" }, 413);
  }
  // A length header may be absent or wrong: stop reading as soon as the body exceeds the limit.
  // One growing buffer also bounds bookkeeping when the upstream sends many tiny chunks.
  let body = new Uint8Array(0);
  let length = 0;
  const reader = r.body?.getReader();
  if (reader) {
    try {
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        length += value.byteLength;
        if (length > PICTURE_BYTES) {
          // A broken connection's cleanup must not turn a size rejection into an unrelated error.
          await reader.cancel().catch(() => {});
          return reply({ error: "too_large" }, 413);
        }
        if (length > body.byteLength) {
          const grown = new Uint8Array(Math.min(PICTURE_BYTES, Math.max(length, body.byteLength * 2)));
          grown.set(body);
          body = grown;
        }
        body.set(value, length - value.byteLength);
      }
    } catch {
      return reply({ error: "unreachable" }, 502);
    } finally {
      reader.releaseLock();
    }
  }
  return new Response(body.subarray(0, length), {
    headers: {
      "content-type": type,
      "cache-control": `public, max-age=${KEPT_SECONDS}`,
      "x-content-type-options": "nosniff",
      "content-security-policy": "default-src 'none'",
      "referrer-policy": "no-referrer",
    },
  });
}
