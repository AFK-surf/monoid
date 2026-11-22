// Native MoonBit whitebox tests for session_storage archive policy, formatting, and error helpers.

///|
test "thread_address, packed_path, and from_before" {
  assert_eq(thread_address("CHAT", "1700000000.000100"), "CHAT/1700000000.000100")
  assert_eq(packed_path("/data/sessions/chat/c-1"), "/data/sessions/chat/c-1.zst")
  assert_true(from_before("remote tasks are not enabled"))
  assert_true(from_before("missing task key"))
  assert_true(!from_before("plain"))
}

///|
test "archive policy parsing, serialization, and change summary" {
  let p = policy_from(None)
  assert_eq(p.policy, default_policy.policy)
  assert_eq(p.options.length(), default_policy.options.length())
  let back = policy_from(Some(p.to_json()))
  assert_eq(back.policy, p.policy)
  assert_eq(back.options.length(), p.options.length())

  let custom = checked_policy(
    Some({
      "policy": "Archive old chats",
      "options": [
        { "id": "done", "name": "Done", "rubric": "Finished", "archive": true },
        { "id": "keep", "name": "Keep", "rubric": "Active", "archive": false },
      ],
    }),
  )
  assert_eq(custom.options.length(), 2)
  assert_true(change_summary(default_policy, custom).length() > 0)
  assert_true(policy_question(custom) is Object(_))
  assert_true(policy_since(1000000.0) < 1000000.0)
}

///|
test "checked_policy rejects invalid option lists" {
  let no_opts = try {
    ignore(checked_policy(Some({ "policy": "ok", "options": [] })))
    ""
  } catch {
    e => message_of(e)
  }
  assert_true(no_opts.length() > 0)
  let empty_name = try {
    ignore(checked_policy(Some({ "policy": "ok", "options": [{ "name": "  ", "archive": true }] })))
    ""
  } catch {
    e => message_of(e)
  }
  assert_true(empty_name.length() > 0)
  let no_archive = try {
    ignore(checked_policy(Some({ "policy": "ok", "options": [{ "name": "Keep", "archive": false }] })))
    ""
  } catch {
    e => message_of(e)
  }
  assert_true(no_archive.length() > 0)
}

///|
test "archive_mass, recommends, and policy_checks" {
  let p = checked_policy(
    Some({
      "policy": "Auto archive",
      "options": [
        { "id": "archive_it", "name": "Archive", "archive": true },
        { "id": "keep_it", "name": "Keep", "archive": false },
      ],
    }),
  )
  let result : Json = { "selected": "archive_it", "probabilities": { "archive_it": 0.9, "keep_it": 0.1 } }
  assert_eq(archive_mass(result, p), 0.9)
  assert_true(recommends(result, p, 0.8))
  assert_true(!recommends(result, p, 0.95))
  let checks = policy_checks(
    [{ "key": "chat:a", "archive": true }, { "key": "chat:b", "archive": false }],
    k => k == "chat:a",
  )
  assert_true(checks is Object(_) || checks is Array(_))
}

///|
test "format_steps and error classification helpers" {
  let steps : Array[Json] = [
    { "kind": "assistant", "text": "Checking files" },
    { "kind": "tool", "name": "read_file" },
  ]
  let formatted = format_steps(1, steps, 2)
  assert_true(formatted.length() > 0)
  let err = failed("boom")
  assert_true(is_kind(err, "Error"))
  assert_true(!is_kind(err, "Refused"))
  assert_eq(message_of(err), "boom")
  assert_eq(digits_of("12345"), 12345)
  assert_eq(digits_of("12a"), -1)
  assert_eq(digits_of(""), -1)
  assert_eq(cut("abcdef", 1, end=4), "bcd")
}

///|
test "rename_retrying_by and retire_workspace_by retry transient locks and roll back on persistent EPERM" {
  let rt = @effect.Runtime::new()
  // Transient EPERM clears on retry: no archive removal or worktree unlock.
  let ok_attempts = Ref::new(0)
  let ok_waits : Array[Int] = []
  let ok_rm = Ref::new(false)
  let ok_unlock = Ref::new(false)
  let f1 = rt.fork(async fn() {
    retire_workspace_by(
      async fn() {
        rename_retrying_by(
          async fn(_a, _b) {
            ok_attempts.val += 1
            if ok_attempts.val <= 2 {
              raise failed("EPERM: operation not permitted")
            }
          },
          "/room/workspace",
          "/room/workspace.retiring",
          backoff=workspace_rename_backoff,
          wait=async fn(ms) { ok_waits.push(ms) },
        )
      },
      async fn() { ok_rm.val = true },
      async fn() { ok_unlock.val = true },
    )
  })
  rt.advance(1)
  assert_true(f1.poll() is Some(Succeeded(_)))
  assert_eq(ok_attempts.val, 3)
  assert_eq(ok_waits, [50, 100])
  assert_true(!ok_rm.val)
  assert_true(!ok_unlock.val)
  // Persistent EPERM exhausts workspace backoff, removes archive, unlocks worktrees, and re-raises.
  let fail_attempts = Ref::new(0)
  let fail_waits : Array[Int] = []
  let fail_rm = Ref::new(false)
  let fail_unlock = Ref::new(false)
  let f2 = rt.fork(async fn() {
    retire_workspace_by(
      async fn() {
        rename_retrying_by(
          async fn(_a, _b) {
            fail_attempts.val += 1
            raise failed("Operation not permitted (os error 1)")
          },
          "/room/workspace",
          "/room/workspace.retiring",
          backoff=workspace_rename_backoff,
          wait=async fn(ms) { fail_waits.push(ms) },
        )
      },
      async fn() { fail_rm.val = true },
      async fn() { fail_unlock.val = true },
    )
  })
  rt.advance(1)
  match f2.poll() {
    Some(Failed(e)) => assert_eq(code_of(e), "EPERM")
    _ => fail("expected persistent EPERM to fail")
  }
  assert_eq(fail_attempts.val, 6)
  assert_eq(fail_waits, [50, 100, 200, 400, 800])
  assert_true(fail_rm.val)
  assert_true(fail_unlock.val)
}
