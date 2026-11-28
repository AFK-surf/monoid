// The SDK reads its direct API token once at startup. Give it a session-bound local
// endpoint backed by the borrower’s memory cache, including after runner handover.
import { createHmac, timingSafeEqual } from "node:crypto";
import type { IncomingHttpHeaders, IncomingMessage, ServerResponse } from "node:http";
import { request as httpsRequest } from "node:https";
import { buffer } from "node:stream/consumers";
import { pipeline } from "node:stream/promises";
import { proxyAgent } from "../ops/agent-env.ts";
import type { DoorRoute } from "../parts.ts";
import type { CopilotLease } from "./copilot.ts";

export function copilotDoorToken(secret: string, profile: string): string {
  return createHmac("sha256", secret).update("copilot-api\0" + profile).digest("hex");
}

export function copilotDoor(
  sessionToken: (key: string, profile: string) => string | undefined,
  borrow: (profile: string, rejected?: string) => Promise<CopilotLease>,
  connect = httpsRequest,
): DoorRoute {
  return {
    prefix: "copilot-api",
    async upgrade(_req, socket) { socket.destroy(); },
    async request(req: IncomingMessage, res: ServerResponse) {
      const route = /^\/copilot-api\/([^/?]+)\/([^/?]+)(\/[^#]*)$/.exec(req.url ?? "");
      if (!route || (req.method !== "GET" && req.method !== "POST")) { res.writeHead(404).end(); return; }
      let key: string, profile: string;
      try { key = decodeURIComponent(route[1]!); profile = decodeURIComponent(route[2]!); }
      catch { res.writeHead(400).end(); return; }
      const secret = sessionToken(key, profile);
      const bearer = /^Bearer ([a-f0-9]{64})$/i.exec(req.headers.authorization ?? "")?.[1];
      if (!secret || !bearer || !timingSafeEqual(Buffer.from(bearer), Buffer.from(copilotDoorToken(secret, profile)))) {
        res.writeHead(403).end(); return;
      }
      // Retain at most one small request for a single retry after an explicit upstream 401.
      // Large and chunked uploads stay streaming. Their next SDK attempt uses the renewed credential.
      const size = req.headers["content-length"];
      const replay = req.method === "GET" ? Buffer.alloc(0)
        : size !== undefined && Number(size) <= 1024 * 1024 ? await buffer(req) : undefined;
      const send = async (rejected?: string): Promise<void> => {
        const lease = await borrow(profile, rejected).catch(() => null);
        if (res.destroyed) return;
        if (!lease || sessionToken(key, profile) !== secret) {
          res.writeHead(503).end("Copilot sharing unavailable. Check the host station and its sign-in.");
          return;
        }
        const headers: IncomingHttpHeaders = { ...req.headers, authorization: `Bearer ${lease.token}` };
        for (const name of ["host", "cookie", "connection", "transfer-encoding", "proxy-authorization", "upgrade", "forwarded"]) delete headers[name];
        const upstream = connect(lease.api, { method: req.method, path: route[3], headers, agent: proxyAgent() ?? undefined });
        const abort = () => upstream.destroy();
        res.once("close", abort);
        upstream.once("close", () => res.off("close", abort));
        upstream.on("error", () => {
          if (!res.headersSent) res.writeHead(502).end("Copilot API unavailable");
          else res.destroy();
        });
        upstream.once("response", async (answer) => {
          const status = answer.statusCode ?? 502;
          if (status === 401) {
            if (!rejected && replay !== undefined) {
              answer.resume();
              await send(lease.token).catch(() => res.destroy());
              return;
            }
            // Discard the refused lease even when the upload cannot be replayed.
            void borrow(profile, lease.token).catch(() => {});
          }
          if (status >= 300 && status < 400) { answer.resume(); res.writeHead(502).end(); return; }
          const headers = { ...answer.headers };
          for (const name of ["set-cookie", "connection", "transfer-encoding", "upgrade"]) delete headers[name];
          res.writeHead(status, headers);
          await pipeline(answer, res).catch(() => res.destroy());
        });
        if (replay !== undefined) upstream.end(replay);
        else req.pipe(upstream);
      };
      await send();
    },
  };
}
