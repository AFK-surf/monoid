// What failed a turn, from what Claude Code said of it: the station's reasons (station/src/agents/runtime.ts
// `FailureReason`) as the TypeScript station told them apart before this was moved here (claude.ts `refused` and
// `classifyResult`, with runtime.ts `failureRest`; frames_test.mbt holds what it said), the same words in the same
// cases: `toLowerCase` as V8's (@jscase.lower), a word as /[^\p{L}\p{N}]+/u parts them (@jscase.has_word), `\b`, `\w`
// and `\d` ASCII's, and a regular expression's `i` folding ASCII letters alone.

///|
fn ascii_lower(text : String) -> String {
  let out = StringBuilder(capacity=text.length())
  for i in 0..<text.length() {
    let c = text.unsafe_get(i).to_int()
    out.write_char((if c >= 0x41 && c <= 0x5a { c + 32 } else { c }).unsafe_to_char())
  }
  out.to_string()
}

///|
/// `[A-Za-z0-9_]`, what `\w` and `\b` take.
fn word_unit(c : Int) -> Bool {
  (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c == 0x5f
}

///|
/// Whether `\b` holds before `at` in `s`.
fn boundary(s : String, at : Int) -> Bool {
  let before = at > 0 && word_unit(s.unsafe_get(at - 1).to_int())
  let after = at < s.length() && word_unit(s.unsafe_get(at).to_int())
  before != after
}

///|
/// Whether `w` is in `s` from `at`.
fn at_is(s : String, at : Int, w : String) -> Bool {
  if at < 0 || at + w.length() > s.length() {
    return false
  }
  for j in 0..<w.length() {
    if s.unsafe_get(at + j) != w.unsafe_get(j) {
      return false
    }
  }
  true
}

///|
/// `/\bw\b/.test(s)`, for a `w` that begins and ends with a word's character.
fn has_bounded(s : String, w : String) -> Bool {
  for i = 0; i + w.length() <= s.length(); i = i + 1 {
    if boundary(s, i) && at_is(s, i, w) && boundary(s, i + w.length()) {
      return true
    }
  }
  false
}

///|
/// `/\bhit your \d+[- ]hour limit\b/.test(s)`.
fn hourly_limit(s : String) -> Bool {
  let hit = "hit your "
  let hour = "hour limit"
  for i = 0; i + hit.length() <= s.length(); i = i + 1 {
    if !boundary(s, i) || !at_is(s, i, hit) {
      continue
    }
    let mut j = i + hit.length()
    let digits = j
    while j < s.length() && s.unsafe_get(j).to_int() >= 0x30 && s.unsafe_get(j).to_int() <= 0x39 {
      j += 1
    }
    if j > digits &&
      j < s.length() &&
      (s.unsafe_get(j).to_int() == 0x2d || s.unsafe_get(j).to_int() == 0x20) &&
      at_is(s, j + 1, hour) &&
      boundary(s, j + 1 + hour.length()) {
      return true
    }
  }
  false
}

///|
/// `/\b(?:reached|hit) your [\w.\- ]+ limit\b/.test(s)`: a model's own allowance ("You've reached your Fable limit",
/// "You've hit your Fable limit · resets …") as an account's ("You've hit your weekly limit").
fn named_limit(s : String) -> Bool {
  let limit = " limit"
  let named = (c : Int) => word_unit(c) || c == 0x2e || c == 0x2d || c == 0x20
  for i = 0; i < s.length(); i = i + 1 {
    if !boundary(s, i) {
      continue
    }
    let from = if at_is(s, i, "reached your ") {
      i + 13
    } else if at_is(s, i, "hit your ") {
      i + 9
    } else {
      continue
    }
    // [\w.\- ]+ then " limit" then \b: " limit" begins anywhere past the first of the run, all before it of the run.
    let mut k = from
    while k < s.length() && named(s.unsafe_get(k).to_int()) {
      k += 1
      if at_is(s, k, limit) && boundary(s, k + limit.length()) {
        return true
      }
    }
  }
  false
}

///|
/// runtime.ts `failureRest`: the network, the conversation's size, else the model.
fn failure_rest(text : String, lower : String) -> String {
  let context = [
    "context window", "context_window", "context length", "context_length", "context overflow", "prompt is too long",
    "maximum context", "too many tokens", "input is too long",
  ]
  if context.iter().any(w => lower.contains(w)) {
    return "context"
  }
  let folded = ascii_lower(text)
  let network = [
    "stream disconnected", "error sending request", "connection reset", "connection refused", "connection closed",
    "connection error", "connection failed", "network error", "timed out", "timeout", "econnreset", "econnrefused",
    "etimedout", "enotfound", "eai_again", "epipe", "socket hang up", "fetch failed", "dns error", "tls handshake",
  ]
  if network.iter().any(w => folded.contains(w)) {
    return "network"
  }
  "model"
}

///|
/// claude.ts `refused`: Anthropic turning the request away before any account is looked at (a region it does not serve,
/// a proxy's address it refuses), a 403 "Request not allowed", "forbidden". Signing in again changes nothing.
pub fn refused(text : String) -> Bool {
  let lower = @jscase.lower(text)
  lower.contains("request not allowed") || has_bounded(lower, "forbidden")
}

///|
/// Whether the provider's words say the account itself is restricted (e.g. Anthropic Verification Portal, FB-68).
fn account_restricted(lower : String) -> Bool {
  ["can't receive replies", "cannot receive replies", "verification portal"].iter().any(w => lower.contains(w))
}

///|
/// claude.ts `classifyResult`: what failed a turn whose result was an error, by what it said.
pub fn classify_result(text : String) -> String {
  let lower = @jscase.lower(text)
  let word = (w : String) => @jscase.has_word(lower, w)
  let says = (w : String) => lower.contains(w)
  if refused(text) {
    return "refused"
  }
  if word("401") || word("403") || says("authenticat") || says("api key") || account_restricted(lower) {
    return "auth"
  }
  if word("429") ||
    ["rate limit", "rate-limit", "rate_limit", "ratelimit", "usage limit", "credit balance"].iter().any(says) ||
    ["session", "weekly", "daily"].iter().any(window => says("hit your \{window} limit")) ||
    hourly_limit(lower) ||
    named_limit(lower) ||
    says("you've hit your limit") {
    return "rate_limit"
  }
  if word("529") || says("overloaded") || says("at capacity") {
    return "overloaded"
  }
  failure_rest(text, lower)
}

///|
/// A turn that failed on authentication (an api_retry's 401 or 403, `auth_failure`): refused, or the account's.
pub fn auth_outcome(failure : String) -> J {
  failed(if refused(failure) { "refused" } else { "auth" }, failure)
}

///|
/// A turn whose result was an error, saying `text`: told apart by it, and at most 1000 characters of it kept.
pub fn error_outcome(text : String) -> J {
  failed(classify_result(text), chars(text, 1000))
}

///|
/// runtime.ts `failureOf`: what failed a turn by what a runtime said of it, its error's code first where the text gives
/// one (its words parted as /[^\p{L}\p{N}_]+/u parts them), then its phrases; with a runtime's own words of its account
/// and its limits (`FailureWords`: `auth_codes`, `auth`, `limit_codes`, `limit`).
pub fn failure_of(
  text : String,
  auth_codes~ : Array[String] = [],
  auth~ : Array[String] = [],
  limit_codes~ : Array[String] = [],
  limit~ : Array[String] = [],
) -> String {
  let extra_auth = auth
  let extra_limit = limit
  let lower = @jscase.lower(text)
  let word = (w : String) => @jscase.has_word_by(lower, w, c => c == 0x5f || @jscase.is_word_point(c))
  let says = (w : String) => lower.contains(w)
  let auth = [
    "unauthorized", "authenticat", "not logged in", "sign in", "log in", "api key", "permission_denied", "invalid credential",
    "can't receive replies", "cannot receive replies", "verification portal",
  ]
  let refused = [
    "request not allowed", "unsupported_country", "unsupported country", "not available in your region", "region is not supported",
    "not authorized in this region",
  ]
  let block_page = ["<html", "<!doctype html", "attention required", "just a moment", "cloudflare"]
  let limit = ["rate limit", "rate_limit", "quota", "usage limit", "limit reached", "resource_exhausted", "too many requests", "credit balance"]
  let auth = auth + extra_auth
  let limit = limit + extra_limit
  if word("401") || auth_codes.iter().any(word) {
    return "auth"
  }
  if word("403") {
    return if auth.iter().any(says) || says("token") || says("scope") {
      "auth"
    } else if refused.iter().any(says) {
      "refused"
    } else if block_page.iter().any(says) {
      "blocked"
    } else {
      "denied"
    }
  }
  if word("429") || limit_codes.iter().any(word) {
    return "rate_limit"
  }
  if word("529") {
    return "overloaded"
  }
  if refused.iter().any(says) {
    return "refused"
  }
  if says("forbidden") {
    return "denied"
  }
  if auth.iter().any(says) {
    return "auth"
  }
  if limit.iter().any(says) {
    return "rate_limit"
  }
  if says("overloaded") || says("at capacity") {
    return "overloaded"
  }
  failure_rest(text, lower)
}
