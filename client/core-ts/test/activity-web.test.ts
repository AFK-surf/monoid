import assert from "node:assert/strict";
import { test } from "node:test";
import { doing } from "../src/activity.ts";
import { setCurrent } from "../src/i18n.ts";

test("web calls describe pages without presenting internal references as titles", () => {
  const say = (input: unknown) => doing("web__run", JSON.stringify(input));
  try {
    setCurrent("zh");
    assert.equal(say({ open: [{ ref_id: "turn8search2" }, { ref_id: "turn6search1" }] }), "打开 2 个网页");
    assert.equal(say({ open: [{ ref_id: "turn8search2" }] }), "打开网页");
    assert.equal(say({ open: [{ ref_id: "https://example.com/story" }] }), "打开网页 https://example.com/story");
    assert.equal(say({ open: [{}] }), "打开网页");
    assert.equal(say({ search_query: [{ q: "天气" }] }), "网页搜索「天气」");
    assert.equal(say({ search_query: [{ q: "天气" }, { q: "气温" }] }), "网页搜索 2 个关键词");
    assert.equal(say({ search_query: [{}] }), "网页搜索");
    assert.equal(say({ weather: [{ location: "Singapore" }] }), "网页查询");

    setCurrent("en");
    assert.equal(say({ open: [{ ref_id: "turn8search2" }, { ref_id: "turn6search1" }] }), "Opening 2 web pages");
    assert.equal(say({ open: [{ ref_id: "turn8search2" }] }), "Opening a web page");
    assert.equal(say({ open: [{ ref_id: "https://example.com/story" }] }), "Opening https://example.com/story");
    assert.equal(say({ search_query: [{ q: "weather" }] }), "Searching the web for “weather”");
    assert.equal(say({ search_query: [{ q: "weather" }, { q: "temperature" }] }), "Running 2 web searches");
    assert.equal(say({ search_query: [{}] }), "Searching the web");
    assert.equal(say({ weather: [{ location: "Singapore" }] }), "Looking up on the web");
  } finally {
    setCurrent("zh");
  }
});
