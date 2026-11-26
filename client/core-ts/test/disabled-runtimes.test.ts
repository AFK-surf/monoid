import assert from "node:assert/strict";
import { test } from "node:test";
import { models } from "../src/views/models.ts";

test("models skips profiles with no enabled runtimes and omits disabled runtimes", () => {
  const overview = {
    profiles: [
      {
        id: "cx",
        name: "Codex",
        runtime: "codex",
        runtimes: [],
        enabled: true,
        models: ["gpt-6-sol"],
      },
      {
        id: "groq",
        name: "Groq",
        runtime: "dsh",
        runtimes: ["pi"],
        enabled: true,
        models: ["deepseek-v4-pro"],
      },
    ],
  };
  const listed = models(overview, 0);
  assert.deepEqual(listed.map((m) => [m.model, m.runtimes]), [["deepseek-v4-pro", ["pi"]]]);
});
