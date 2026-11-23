// What the settings' pages share beside the library's page (src/sf page.mbt): one arrangement's pieces they still draw
// themselves (desk_list_title, narrow_row, …: the library's, named here), counted by detlint's page-look in the pages,
// each file's only falling. The desktop's settings pages not moved here yet take them by these names (sfdesk
// settings_page.mbt).

using @sf {
  desk_lane_most,
  desk_lane_in,
  desk_column_most,
  desk_column_in,
}

///|
// kept across runs: a value (no field of it changes)
pub let desk_said_line : @ui.Style = @ui.css("row w=Full align=ACenter")

///|
// kept across runs: a value (no field of it changes)
pub let narrow_note : @ui.TextStyle = @sf.pg_note

///|
// kept across runs: a value (no field of it changes)
pub let narrow_row : @ui.Style = @sf.pg_row

///|
// kept across runs: a value (no field of it changes)
pub let narrow_row_title : @ui.TextStyle = @sf.pg_row_title

///|
/// How many dialogs were put up (a dialog's fields' keys, new each time it opens).
// kept across runs: counted by open_dialog_nodes; reset puts it back
pub let desk_dialogs : Ref[Int] = Ref(0)

///|
/// Puts up a dialog over the page (parts.tsx Dialog: the library's panel opened by nothing, @sf.panel_nodes): its
/// title, what it is about, what it holds and its buttons at its foot nodes of the window's tree made once as it opens,
/// each given what closes it; `wide`, 640 wide; `live`: its title, its step's count and what it is about as they are
/// now (a wizard's); `steps`: what it holds goes in steps in it (@sf.panel_go_nodes), `back` what back does on its
/// first where they follow a flow kept elsewhere; `on_gone`: what is let go of as it closes by its ✕, Esc or a press
/// outside.
fn open_dialog_nodes(
  title : String,
  body : (@view.View, () -> Unit) -> Unit,
  foot : (@view.View, () -> Unit) -> Unit,
  description? : String = "",
  wide? : Bool = false,
  live? : () -> (String, String, String),
  on_gone? : () -> Unit = fn() {  },
  steps? : Bool = false,
  back? : () -> Unit,
) -> Unit {
  desk_dialogs.val += 1
  @sf.panel_nodes(title, body, from=Unanchored, description~, foot~, wide~, live?, gone=on_gone, steps~, back?)
}

///|
/// The same with no buttons at its foot (open_dialog_nodes'): what it holds is pressed to do what it does.
fn open_dialog_bare_nodes(
  title : String,
  body : (@view.View, () -> Unit) -> Unit,
  description? : String = "",
  wide? : Bool = false,
  on_gone? : () -> Unit = fn() {  },
) -> Unit {
  desk_dialogs.val += 1
  @sf.panel_nodes(title, body, from=Unanchored, description~, wide~, gone=on_gone)
}

// ── who a profile or a key is, at the head of its page, and a card's foot ──

///|
// kept across runs: a value (no field of it changes)
pub let pf_name_line : @ui.Style = @ui.css("row gap=S1 align=ACenter")

///|
pub let pf_spin : Double = 14.0
