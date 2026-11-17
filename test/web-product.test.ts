// A page on another product's host (monoid's console, admin.monoid.build) says that product's name in the catalog's
// words (which say still.fail), and its test channel's host; what is put in for `{name}` (an email at still.fail) stays.
import assert from "node:assert/strict";
import test from "node:test";

test("on monoid's host the words say monoid and its test channel's host; what is put in for {name} is left as it is", async () => {
  Object.defineProperty(globalThis, "location", { value: new URL("https://admin.monoid.build/overview"), configurable: true });
  try {
    const { NAME, BETA_HOST, sayProduct } = await import("../web/src/channel.ts");
    const { addWords, setSaid, tr } = await import("../web/ui/src/i18n.ts");
    assert.deepEqual([NAME, BETA_HOST], ["monoid", "app.monoid.zone"]);
    assert.equal(sayProduct("still.fail 管理后台"), "monoid 管理后台");
    assert.equal(sayProduct("可使用 app.youdid.wtf"), "可使用 app.monoid.zone");
    // Hosts and addresses keep still.fail's.
    assert.equal(sayProduct("打开 app.still.fail 或写信到 noreply@still.fail"), "打开 app.still.fail 或写信到 noreply@still.fail");
    addWords({ zh: { "test.body": "{emails} 不是 still.fail 的管理员。" }, en: { "test.body": "{emails} is not still.fail's admin." } });
    setSaid(sayProduct);
    assert.equal(tr("zh", "test.body", { emails: "ops@still.fail" }), "ops@still.fail 不是 monoid 的管理员。");
    assert.equal(tr("en", "test.body", { emails: "still.fail" }), "still.fail is not monoid's admin.");
    setSaid((text) => text);
  } finally {
    Reflect.deleteProperty(globalThis, "location");
  }
});
