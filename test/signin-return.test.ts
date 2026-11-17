import assert from "node:assert/strict";
import test from "node:test";
import { returnTo } from "../web/src/login/return-to.ts";

const query = (to: string) => new URLSearchParams({ return_to: to }).toString();

test("signing in returns only to a path on this origin after the browser resolves it", () => {
  for (const to of [
    "https://other.example/", "//other.example/", "/\\other.example/", "/\n/other.example/",
    "/\t/other.example/", "/a/..//other.example/", "/\\[", "relative",
  ]) {
    const next = returnTo(query(to));
    assert.equal(new URL(next, "https://app.example/login").origin, "https://app.example", JSON.stringify(to));
    assert.equal(next, "/", JSON.stringify(to));
  }
});

test("a return path cannot normalize back into the sign-in pages", () => {
  for (const to of ["/login", "/login?again=1", "/auth/callback", "/a/../login", "/a/%2e%2e/auth/callback", "/a\\..\\login"]) {
    assert.equal(returnTo(query(to)), "/", to);
  }
});

test("a return path keeps the app destination, query and fragment", () => {
  for (const to of ["/", "/w/team/chats?thread=a%2Fb#latest", "/admin/users?email=a%40example.com", "/docs/%2Fname"]) {
    assert.equal(returnTo(query(to)), to);
  }
  assert.equal(returnTo(""), "/");
  assert.equal(returnTo(query("/a/../w/team")), "/w/team");
});
