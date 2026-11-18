import { after, test } from "node:test";
import { writeFileSync } from "node:fs";
import { once } from "node:events";
import { MbProcess } from "../src/read/mb-reader.ts";

let child;
test("a reader ready to stop", async () => {
  child = new MbProcess(process.execPath, ["-e", `process.on('SIGTERM', () => setTimeout(() => process.exit(0), 50)); console.log('{}');`]);
  await once(child, "message");
  child.ref(false);
});
after(async () => {
  await child.terminate();
  writeFileSync(process.env.TERMINATE_MARKER, "closed");
});
