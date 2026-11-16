// Real loopback TLS belongs to the side run. The main suite scripts socket IO and time.
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { once } from "node:events";
import { promisify } from "node:util";
import { createServer, getCACertificates, setDefaultCACertificates } from "node:tls";
import { test } from "node:test";
import { cloudTLS } from "../src/cloud/transport.ts";

test("regional TCP route keeps canonical SNI and rejects a trusted wrong-host certificate", async () => {
  const dir = await mkdtemp(join(tmpdir(), "cloud-tls-"));
  const trusted = getCACertificates("default");
  try {
    for (const name of ["app.still.fail", "wrong.test"]) {
      const key = join(dir, `${name}.key`); const cert = join(dir, `${name}.pem`);
      await promisify(execFile)("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert, "-days", "1", "-subj", `/CN=${name}`, "-addext", `subjectAltName=DNS:${name}`]);
      const pem = await readFile(cert, "utf8"); setDefaultCACertificates([...trusted, pem]);
      const server = createServer({ key: await readFile(key), cert: pem });
      server.on("tlsClientError", () => {});
      server.listen(0, "127.0.0.1"); await once(server, "listening");
      const port = (server.address() as { port: number }).port;
      const socket = cloudTLS("127.0.0.1", port, "app.still.fail");
      try {
        if (name === "app.still.fail") {
          const accepted = once(server, "secureConnection"); await once(socket, "secureConnect");
          const [peer] = await accepted; assert.equal(peer.servername, "app.still.fail"); peer.destroy();
        } else {
          const [error] = await once(socket, "error"); assert.equal(error.code, "ERR_TLS_CERT_ALTNAME_INVALID");
        }
      } finally { socket.destroy(); await new Promise<void>((resolve) => server.close(() => resolve())); }
    }
  } finally { setDefaultCACertificates(trusted); await rm(dir, { recursive: true, force: true }); }
});
