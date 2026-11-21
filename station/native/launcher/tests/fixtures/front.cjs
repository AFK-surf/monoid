// A stand-in for the front (front.rs) that answers on its socket as the MoonBit front does: each line asked is answered
// `{"id":…,"error":…}` (it has no operation of the launcher's asks). Run as `front.cjs --builder mesh --socket S
// --shell-dir D`; its pid appended to <data>/fronts, each ask to <data>/front-asks; it ends with its stdin.
"use strict";
const fs = require("fs");
const net = require("net");
const path = require("path");

const args = process.argv.slice(2);
const socket = args[args.indexOf("--socket") + 1];
const data = path.dirname(path.dirname(socket));
fs.appendFileSync(path.join(data, "fronts"), `${process.pid}\n`);
try { fs.rmSync(socket); } catch {}
const server = net.createServer((c) => {
  let pending = "";
  c.on("data", (chunk) => {
    pending += chunk;
    for (let at; (at = pending.indexOf("\n")) >= 0; ) {
      const asked = JSON.parse(pending.slice(0, at));
      pending = pending.slice(at + 1);
      fs.appendFileSync(path.join(data, "front-asks"), `${asked.op}\n`);
      c.write(JSON.stringify({ id: asked.id, error: `no operation ${asked.op}` }) + "\n");
    }
  });
  c.on("error", () => {});
});
server.listen(socket, () => process.stdout.write(JSON.stringify({ listening: socket, streams: 6 }) + "\n"));
process.stdin.on("data", () => {});
process.stdin.on("end", () => process.exit(0));
