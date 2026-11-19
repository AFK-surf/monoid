// The index for one workspace of the station's, its home one or one it joined (station/src/comma/workspace-index.ts).
// The old comma-stats.db remains the Router's compatibility record; its index has no owner recorded and therefore cannot
// safely be sent after a station is enrolled in a different workspace.

///|
/// `within`: whether the station is in `workspace` now; `version` moves whenever the station's workspaces change.
pub fn workspace_index(
  data : String,
  workspace : String,
  within : () -> Bool,
  version : () -> Int,
  read : async (Double, Double) -> ReadRows,
  changes : ((Bool) -> Unit) -> () -> Unit,
  io : Io,
  runtime : @effect.Runtime,
) -> (CommaStats, CommaIndexes) raise {
  let guarded = async fn(from : Double, to : Double) -> ReadRows {
    let at = version()
    let valid = () => within() && version() == at
    if !valid() {
      return { stations: [], unread: [], valid: Some(valid) }
    }
    let result = read(from, to)
    let inner = result.valid
    {
      ..result,
      valid: Some(
        () => valid() &&
          (match inner {
            Some(f) => f()
            None => true
          }),
      ),
    }
  }
  let stats = CommaStats::in_workspace(
    data,
    workspace,
    guarded,
    changed => changes(fast => if within() { changed(fast) }),
    io,
    runtime,
  )
  let started : Ref[Int?] = Ref(None)
  (
    stats,
    {
      stats: stats.stats,
      tasks: stats.tasks,
      start: () => {
        let now = version()
        match started.val {
          None => {
            started.val = Some(now)
            stats.start()
          }
          Some(s) if s != now => {
            started.val = Some(now)
            stats.build()
          }
          _ => ()
        }
      },
    },
  )
}
