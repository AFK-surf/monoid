import assert from "node:assert/strict";
import test from "node:test";
import { brotliCompressSync, brotliDecompressSync } from "node:zlib";
import { serveWeb } from "../src/web.ts";

// src/web.ts `packed`, read as it answers (test/hosts.test.ts has it in Miniflare, which keeps an answer's encoding to
// itself): the file the build brotlied, sent as it is and said to be brotli.

const env = { PUBLIC_ORIGIN: "https://app.example", BETA_ORIGIN: "https://beta.example" };
const app = "// the app, as mbui-web built it";
const files = (request: Request): Response => {
  const path = new URL(request.url).pathname;
  if (path === "/mbui/app.js") return new Response(app, { headers: { "content-type": "text/javascript" } });
  if (path === "/mbui/app.js.br") return new Response(brotliCompressSync(app));
  return new Response("<title>still.fail</title>", { headers: { "content-type": "text/html; charset=utf-8" } });
};

test("the app's script goes as its build brotlied it, said to be brotli, to a browser that takes it", async () => {
  for (const origin of [env.PUBLIC_ORIGIN, env.BETA_ORIGIN]) {
    const answer = await serveWeb(new Request(`${origin}/mbui/app.js?b=1`, { headers: { "accept-encoding": "gzip, br" } }), env, files);
    assert.equal(answer.headers.get("content-encoding"), "br", origin);
    assert.equal(answer.headers.get("content-type"), "text/javascript", origin);
    assert.equal(answer.headers.get("content-length"), null, origin);
    assert.equal(brotliDecompressSync(Buffer.from(await answer.arrayBuffer())).toString(), app, origin);
    const plain = await serveWeb(new Request(`${origin}/mbui/app.js?b=1`, { headers: { "accept-encoding": "gzip" } }), env, files);
    assert.equal(plain.headers.get("content-encoding"), null, origin);
    assert.equal(await plain.text(), app, origin);
  }
});

test("a console's request to add a station lets only a listed console in its form-action, and refuses another", async () => {
  const listed = { ...env, CONNECT_CONSOLES: "https://console.example, https://other.example" };
  const ask = (back: string) => new Request(`${env.PUBLIC_ORIGIN}/connect/station?return=${encodeURIComponent(back)}&state=sc_1&name=m1`);
  const csp = (answer: Response) => answer.headers.get("content-security-policy") ?? "";

  const taken = await serveWeb(ask("https://console.example/connect/station"), listed, files);
  assert.equal(taken.status, 200);
  assert.match(csp(taken), /form-action 'self' https:\/\/console\.example https:\/\/accounts\.google\.com;/);

  for (const back of ["https://evil.example/connect/station", "https://console.example/other", "https://console.example/connect/station?x=1", "nonsense"]) {
    const refused = await serveWeb(ask(back), listed, files);
    assert.equal(refused.status, 302, back);
    assert.equal(refused.headers.get("location"), `${env.PUBLIC_ORIGIN}/connect/station?refused=1`, back);
  }
  // Listing none: every console refused. Any other page keeps the form-action it had.
  assert.equal((await serveWeb(ask("https://console.example/connect/station"), env, files)).status, 302);
  const other = await serveWeb(new Request(`${env.PUBLIC_ORIGIN}/login?return=${encodeURIComponent("https://console.example/connect/station")}`), listed, files);
  assert.doesNotMatch(csp(other), /console\.example/);
  assert.doesNotMatch(csp(await serveWeb(new Request(`${env.PUBLIC_ORIGIN}/connect/station?refused=1`), listed, files)), /console\.example/);
});
