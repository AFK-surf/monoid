// A chat's Farview tab's sign-in form, filled by the station (src/browser/farview-form.ts, 登录态, "Signing in from a
// card"), as signin_form.mbt fills a Chrome tab's: the same finder picks the fields, each marked for the step that
// types into it (Farview's own typing: the page hears it as keys), the form sent with Enter, else by its button
// clicked. Over the tab's agent port (farview_agent.mbt), so what is typed is on no command line and in no log.

///|
pub fn farview_form(net : FarviewNet, port : Int) -> SignInForm {
  let url = async fn() -> String {
    match (try Some(ask_tab(net, port, Look)) catch { _ => None }) {
      Some(Seen(u, _, _)) => u
      _ => ""
    }
  }
  let host = async fn() { host_of(url()) }
  let mark = "[\{farview_mark}]"
  {
    url,
    host,
    on: async fn(site) {
      let h = host()
      h != "" && of_sites(h, [site])
    },
    look: async fn() { FormAsks::of_value(eval_in(net, port, look_script()) catch { _ => None }) },
    type_: async fn(kind, value) {
      if !is_true(eval_in(net, port, mark_script(kind))) {
        return false
      }
      ask_tab(net, port, Act("type", mark, value)) is Seen(_, _, _)
    },
    enter: async fn() { ignore(ask_tab(net, port, Act("key", mark, "Enter"))) },
    press: async fn() {
      if !is_true(eval_in(net, port, button_mark())) {
        return false
      }
      ask_tab(net, port, Act("click", "[\{farview_mark}-button]", "")) is Seen(_, _, _)
    },
    mark: async fn() { ignore(eval_in(net, port, "(window.__stillfailSent = true)")) },
    marked: async fn() { is_true(eval_in(net, port, "window.__stillfailSent === true") catch { _ => None }) },
    close: () => (),
  }
}
