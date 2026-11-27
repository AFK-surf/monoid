// The SDK reads its direct API token once at startup. Give it a session-bound local
// endpoint so long turns and inherited runners obtain the current lease on every call.
import { createHmac, timingSafeEqual } from "node:crypto";
import type { IncomingHttpHeaders, IncomingMessage, ServerResponse } from "node:http";
import { request as httpsRequest } from "node:https";
import { pipeline } from "node:stream/promises";
import { proxyAgent } from "../ops/agent-env.ts";
import type { DoorRoute } from "../parts.ts";
import type { CopilotLease } from "./copilot.ts";

export function copilotDoorToken(secret: string, profile: string): string {
  return createHmac("sha256", secret).update("copilot-api\0" + profile).digest("hex");
}

export function copilotDoor(
  sessionToken: (key: string, profile: string) => string | undefined,
  borrow: (profile: string) => Promise<CopilotLease>,
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
      const lease = await borrow(profile).catch(() => null);
      if (!lease) { res.writeHead(503).end("Copilot sharing unavailable. Check the host station and its sign-in."); return; }
      if (res.destroyed) return;
      const headers: IncomingHttpHeaders = { ...req.headers, authorization: `Bearer ${lease.token}` };
      for (const name of ["host", "cookie", "connection", "transfer-encoding", "proxy-authorization", "upgrade", "forwarded"]) delete headers[name];
      // Supply the origin and the request path separately. An absolute URL in the path cannot change the destination.
      const upstream = httpsRequest(lease.api, { method: req.method, path: route[3], headers, agent: proxyAgent() ?? undefined });
      const abort = () => upstream.destroy();
      res.once("close", abort);
      upstream.on("error", () => {
        if (!res.headersSent) res.writeHead(502).end("Copilot API unavailable");
        else res.destroy();
      });
      upstream.once("response", async (answer) => {
        const status = answer.statusCode ?? 502;
        if (status >= 300 && status < 400) { answer.resume(); res.writeHead(502).end(); return; }
        const headers = { ...answer.headers };
        for (const name of ["set-cookie", "connection", "transfer-encoding", "upgrade"]) delete headers[name];
        res.writeHead(status, headers);
        await pipeline(answer, res).catch(() => res.destroy());
      });
      req.pipe(upstream);
    },
  };
}
