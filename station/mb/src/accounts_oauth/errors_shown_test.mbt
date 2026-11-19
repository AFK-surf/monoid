// The accounts' failures show their words alone, as the TypeScript's `message`: never the constructor's path
// (`station/accounts_oauth.Said.Said`), which a station's log printed for a Claude token not renewed.

///|
test "each failure shows its words alone" {
  let errors : Array[Error] = [
    @accounts_oauth.Said("x"),
    @accounts_oauth.RenewRefused(Some(401), "y"),
    @accounts_oauth.Failed("z"),
    @accounts_oauth.FsError("ENOENT", "w"),
    @accounts_oauth.JsonError("bad"),
  ]
  assert_eq(errors.map(e => e.to_string()), ["x", "y", "z", "w", "bad"])
  assert_eq(errors.map(e => "\{e}"), ["x", "y", "z", "w", "bad"])
  assert_eq(errors.map(e => @accounts_oauth.message_of(e)), ["x", "y", "z", "w", "bad"])
}
