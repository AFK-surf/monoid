// What the settings say of the workspace as a whole (views/settings.ts).
import assert from "node:assert/strict";
import { test } from "node:test";
import { holdLanguage } from "../src/i18n.ts";
import { PROGRESS_DEFAULT } from "../src/progress-prefs.ts";
import { settingsView } from "../src/views/settings.ts";

holdLanguage();

const station = (id: string, completion: unknown) => ({ id, station: `w/${id}`, name: id.toUpperCase(), online: true, overview: { automaticDecisions: { settings: { completion } } } });

test("the_automatic_decisions_say_how_many_stations_have_them_on", () => {
  const on = settingsView(PROGRESS_DEFAULT, [station("a", { enabled: true }), station("b", { enabled: false }), station("c", { enabled: true }), { id: "d", station: "w/d" }]);
  assert.deepEqual([on.decisionsOn, on.decisionsText], [2, "2 台 station 已启用"]);
  const off = settingsView(PROGRESS_DEFAULT, [station("a", { enabled: false }), { id: "b", station: "w/b", overview: {} }]);
  assert.deepEqual([off.decisionsOn, off.decisionsText], [0, "未启用"]);
  assert.equal(settingsView(PROGRESS_DEFAULT, []).decisionsText, "未启用");
});

test("the_hint_by_review_says_what_the_stations_reviews_mean", () => {
  const some = settingsView(PROGRESS_DEFAULT, [station("a", { enabled: true }), station("b", { enabled: false }), { id: "c", station: "w/c", name: "C", online: false }]);
  assert.deepEqual([some.hintNoReview, some.hintReviewText.includes("A"), some.hintReviewText.includes("B")], [false, true, true]);
  const none = settingsView(PROGRESS_DEFAULT, [station("a", { enabled: false })]);
  assert.equal(none.hintNoReview, true);
  assert.notEqual(none.hintReviewText, "");
  assert.deepEqual([settingsView(PROGRESS_DEFAULT, [station("a", { enabled: true })]).hintReviewText, settingsView(PROGRESS_DEFAULT, []).hintReviewText], ["", ""]);
});

test("the_settings_say_how_the_person_s_agents_are_asked_for_progress", () => {
  const v = settingsView({ minutes: 30, strength: "remind" }, []);
  assert.deepEqual([v.progressMinutes, v.progressStrength], [30, "remind"]);
});
