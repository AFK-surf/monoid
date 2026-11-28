import assert from "node:assert/strict";
import test from "node:test";
import { harness } from "./harness.ts";
import { catalog } from "../src/models.ts";

// GET /v1/models: models.dev's catalog as stations read it (src/models.ts).

/// models.dev as it answers, cut to two makers: a model's canonical entry (models.json) and the providers' (api.json),
/// one of them reselling the other's model at a price of its own.
const CANONICAL = {
  "anthropic/claude-opus-5-5": { name: "Claude Opus 5.5", family: "claude-opus", reasoning: true, modalities: { input: ["text", "image", "pdf"], output: ["text"] }, limit: { context: 1_000_000, output: 128_000 } },
  "deepseek/deepseek-v4-pro": { name: "DeepSeek V4 Pro", reasoning: true, modalities: { input: ["text"], output: ["text"] }, limit: { context: 1_000_000, output: 384_000 } },
  "nowhere/odd": { name: "Odd", modalities: { input: "text" }, limit: { context: -1 } },
};
const PROVIDERS = {
  anthropic: { name: "Anthropic", models: { "claude-opus-5-5": { reasoning_options: [{ type: "effort", values: ["low", "medium", "high", "xhigh", "max"] }], cost: { input: 4, output: 20, cache_read: 0.2, cache_write: 5 } } } },
  openrouter: { models: { "deepseek/deepseek-v4-pro": { cost: { input: 9, output: 9 } } } },
};

test("each model is keyed without its maker, with its maker's own prices and effort levels", () => {
  assert.deepEqual(catalog(CANONICAL, PROVIDERS), {
    "claude-opus-5-5": {
      name: "Claude Opus 5.5", maker: "anthropic", makerName: "Anthropic", family: "Claude Opus", input: ["text", "image", "pdf"], reasoning: true, context: 1_000_000, output: 128_000,
      efforts: ["low", "medium", "high", "xhigh", "max"], cost: { input: 4, output: 20, cacheRead: 0.2, cacheWrite: 5 },
    },
    // A reseller's price is what it charges, not the model's: none.
    "deepseek-v4-pro": { name: "DeepSeek V4 Pro", maker: "deepseek", input: ["text"], reasoning: true, context: 1_000_000, output: 384_000 },
    // What is of no shape known is left out.
    odd: { name: "Odd", maker: "nowhere" },
  });
  assert.deepEqual(catalog(null, null), {});
});

test("a model's maker is its lab, named as its own API is; its series as its name spells it", () => {
  const canonical = {
    "meta/muse-spark-1.3": { name: "Muse Spark 1.3", family: "muse" },
    "stepfun/step-5-preview": { name: "Step 5 Preview" },
    "xiaomi/mimo-v2.6-pro": { name: "MiMo-V2.6-Pro", family: "mimo" },
    "tencent/hy3": { name: "Hy3", family: "Hy" },
    "openai/gpt-6.1-sol": { name: "GPT-6.1 Sol", family: "gpt-sol" },
  };
  const providers = { meta: { name: "Meta", models: {} }, stepfun: { name: "StepFun (China)", models: {} }, xiaomi: { name: "Xiaomi", models: {} } };
  const said = Object.fromEntries(Object.entries(catalog(canonical, providers)).map(([k, f]) => [k, [f.maker, f.makerName ?? null, f.family ?? null]]));
  assert.deepEqual(said, {
    "muse-spark-1.3": ["meta", "Meta", "Muse"],
    "step-5-preview": ["stepfun", "StepFun", null],
    "mimo-v2.6-pro": ["xiaomi", "Xiaomi", "MiMo"],
    // A lab selling no API of its own has no name there.
    hy3: ["tencent", null, "Hy"],
    // A series its name does not spell: none.
    "gpt-6.1-sol": ["openai", null, null],
  });
});

test("a model its maker sells under another name, or by its dated version, has that entry's prices", () => {
  const canonical = {
    "deepseek/deepseek-v4.1-flash-1017": { name: "DeepSeek V4.1 Flash 1017" },
    "deepseek/deepseek-v4.1-flash": { name: "DeepSeek V4.1 Flash" },
    "deepseek/deepseek-v4.1-flash-0910": { name: "DeepSeek V4.1 Flash 0910" },
    "cohere/command-a": { name: "Command A" },
    "meta/llama-5": { name: "Llama 5" },
  };
  const flash = { input: 0.15, output: 0.6, cache_read: 0.003 };
  const providers = {
    deepseek: { models: {
      "deepseek-flash": { canonical_model_id: "deepseek/deepseek-v4.1-flash-1017", cost: flash },
      "deepseek-v4-flash": { canonical_model_id: "deepseek/deepseek-v4.1-flash-1017", cost: flash },
    } },
    // Versions not dated, of other prices: not this model's.
    cohere: { models: { "command-a-plus-05-2026": { canonical_model_id: "cohere/command-a-plus-05-2026", cost: { input: 9, output: 9 } } } },
    openrouter: { models: { "meta/llama-5": { canonical_model_id: "meta/llama-5", cost: { input: 1, output: 1 } } } },
  };
  const priced = Object.fromEntries(Object.entries(catalog(canonical, providers)).map(([k, f]) => [k, f.cost ?? null]));
  const cost = { input: 0.15, output: 0.6, cacheRead: 0.003 };
  assert.deepEqual(priced, {
    "deepseek-v4.1-flash-1017": cost,
    "deepseek-v4.1-flash": cost,
    // Its maker sells it no longer.
    "deepseek-v4.1-flash-0910": null,
    "command-a": null,
    // Only resold: no list price of its maker's.
    "llama-5": null,
    // The names it sells it by, which sessions record: that model at those prices.
    "deepseek-flash": cost,
    "deepseek-v4-flash": cost,
  });
  assert.equal(catalog(canonical, providers)["deepseek-flash"]!.name, "DeepSeek V4.1 Flash 1017");
  // Dated versions of different prices: none of them.
  const two = { deepseek: { models: { a: { canonical_model_id: "deepseek/deepseek-v4.1-flash-1017", cost: flash }, b: { canonical_model_id: "deepseek/deepseek-v4.1-flash-1120", cost: { input: 1, output: 1 } } } } };
  assert.equal(catalog({ "deepseek/deepseek-v4.1-flash": {} }, two)["deepseek-v4.1-flash"]!.cost, undefined);
});

test("a name a maker sells only another lab's model by, or under a path, is not that model", () => {
  const canonical = { "mistral/ministral-3": { name: "Ministral 3" }, "zhipuai/glm-5.3": { name: "GLM-5.3" } };
  const providers = {
    mistral: { models: {
      "zai-glm-5-3": { canonical_model_id: "zhipuai/glm-5.3", cost: { input: 9, output: 9 } },
      "ministral-latest": { canonical_model_id: "mistral/ministral-3", cost: { input: 0.1, output: 0.1 } },
      "mistral/ministral-x": { canonical_model_id: "mistral/ministral-3", cost: { input: 0.1, output: 0.1 } },
      "ministral-3": { cost: { input: 0.1, output: 0.1 } },
    } },
  };
  assert.deepEqual(Object.keys(catalog(canonical, providers)).sort(), ["glm-5.3", "ministral-3", "ministral-latest"]);
});

test("the catalog is made once, and a station that has it is told so", async () => {
  const asked: string[] = [];
  const h = await harness({
    push: (request) => {
      asked.push(request.url);
      if (request.url === "https://models.dev/models.json") return { status: 200, body: JSON.stringify(CANONICAL) };
      if (request.url === "https://models.dev/api.json") return { status: 200, body: JSON.stringify(PROVIDERS) };
      return { status: 404 };
    },
  });
  try {
    const first = await h.fetch("/v1/models");
    assert.equal(first.status, 200);
    const etag = first.headers.get("etag");
    assert.ok(etag);
    const body = (await first.json()) as { models: Record<string, any> };
    assert.equal(body.models["claude-opus-5-5"].cost.input, 4);

    const again = await h.fetch("/v1/models", { headers: { "if-none-match": etag! } });
    assert.equal(again.status, 304);
    await again.arrayBuffer();
    const other = await h.fetch("/v1/models", { headers: { "if-none-match": '"else"' } });
    assert.deepEqual(await other.json(), body);
    // Made once: each source read once for the three asks.
    assert.deepEqual(asked.sort(), ["https://models.dev/api.json", "https://models.dev/models.json"]);
  } finally {
    await h.close();
  }
});

test("serveModels matches weak, multi-value, and wildcard If-None-Match headers and refreshes stale ?v= entries cleanly", async () => {
  let fetches = 0;
  let failUpstream = false;
  const h = await harness({
    push: (request) => {
      fetches++;
      if (failUpstream) return { status: 502, body: "upstream error" };
      if (request.url === "https://models.dev/models.json") return { status: 200, body: JSON.stringify(CANONICAL) };
      if (request.url === "https://models.dev/api.json") return { status: 200, body: JSON.stringify(PROVIDERS) };
      return { status: 404 };
    },
  });
  try {
    const first = await h.fetch("/v1/models");
    assert.equal(first.status, 200);
    const etag = first.headers.get("etag")!;
    await first.arrayBuffer();

    for (const header of [`W/${etag}`, `"old", ${etag}`, `  ${etag}  `, "*"]) {
      const hit = await h.fetch("/v1/models", { headers: { "if-none-match": header } });
      assert.equal(hit.status, 304, header);
      assert.equal(hit.headers.get("etag"), etag);
      await hit.arrayBuffer();
    }
    assert.equal(fetches, 2);

    // Mismatched ?v= cancels the cached body and refreshes from upstream.
    const refreshed = await h.fetch("/v1/models?v=%22stale%22");
    assert.equal(refreshed.status, 200);
    assert.equal(refreshed.headers.get("etag"), etag);
    await refreshed.arrayBuffer();
    assert.equal(fetches, 4);

    // Non-OK upstream response body is cancelled before returning 502.
    failUpstream = true;
    const failed = await h.fetch("/v1/models?v=%22stale2%22");
    assert.equal(failed.status, 502);
    await failed.arrayBuffer();
  } finally {
    await h.close();
  }
});
