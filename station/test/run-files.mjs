// Node's --test CLI sorts positional files; run() keeps the slice's longest-first order.
import { run } from "node:test";
import { spec } from "node:test/reporters";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

for (const key of ["SSL_CERT_FILE", "SSL_CERT_DIR", "CODEX_CA_CERTIFICATE"]) delete process.env[key];
if (!process.env.STILLFAIL_TEST_TMP) {
  const own = mkdtempSync(process.platform === "win32" ? join(tmpdir(), "sft-") : "/tmp/sft-");
  process.env.STILLFAIL_TEST_TMP = own;
  process.env.TMPDIR = process.env.TMP = process.env.TEMP = own;
  process.on("exit", () => rmSync(own, { recursive: true, force: true, maxRetries: 3 }));
}

const concurrency = process.env.STILLFAIL_NODE_TEST_JOBS
  ? Number(process.env.STILLFAIL_NODE_TEST_JOBS)
  : true;
const stream = run({ files: process.argv.slice(2), concurrency, timeout: 600000, execArgv: ["--import", "./test/setup-env.mjs"] });
stream.on("test:fail", () => { process.exitCode = 1; });
stream.on("error", (error) => { console.error(error); process.exitCode = 1; });
stream.compose(spec).pipe(process.stdout);
