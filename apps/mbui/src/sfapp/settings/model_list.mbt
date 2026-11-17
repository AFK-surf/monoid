// What every model a run can move to is said by (its list is run_node.mbt's run_model_block): where it comes from
// after its name (ModelFrom), and which of them the core's pick names.

///|
// kept across runs: a value (no field of it changes)
let model_from_words : @ui.TextStyle = @ui.text_style(size=Caption, color=Muted, wrap=false)

///|
/// The model the core's `picked` names: by its own name, else among the names it also goes by (optionOf).
fn model_option_of(models : Array[Json], picked : String) -> Json? {
  if picked == "" {
    return None
  }
  match models.iter().find_first(fn(m) { text(Some(m), "model") == picked }) {
    Some(m) => Some(m)
    None => models.iter().find_first(fn(m) { strings(Some(m), "ids").contains(picked) })
  }
}

