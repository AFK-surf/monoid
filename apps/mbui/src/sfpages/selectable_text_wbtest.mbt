// Informational, error, status, and detail text in cards and profile heads can be selected and copied on wide mouse
// and narrow touch views, while action buttons inside the same card stay interactive and non-selectable.

///|
test "profile quota failure card: mouse hover shows IBeam, drag selects and Cmd+C copies error text, while action button keeps Hand and stays clickable" {
  let t = setting_tester(Profile("ws1/st1", "cc"), 1280.0, platform=0, mode="settings-profile-quota-failed")
  let err_rect = t.rect_of("请求超时，已中止").unwrap()
  let (ex, ey) = (err_rect.0 + 4.0, err_rect.1 + err_rect.3 / 2.0)
  t.move_to(ex, ey)
  t.frame()
  assert_eq(t.cursor(), IBeam, msg="IBeam over card error words")
  t.drag(err_rect.0 + 1.0, ey, err_rect.0 + err_rect.2 + 20.0, ey)
  t.release(err_rect.0 + err_rect.2 + 20.0, ey)
  t.frame()
  assert_eq(t.ctx().selected_text(), "请求超时，已中止")
  t.key(@ui.key_code_copy, mods=@ui.mod_cmd)
  assert_eq(t.clipboard(), "请求超时，已中止")
  // Button inside the same card stays interactive (Hand cursor, not selectable).
  let btn_rect = t.get(Button, label="重新查询额度").rect
  let (bx, by) = (btn_rect.0 + btn_rect.2 / 2.0, btn_rect.1 + btn_rect.3 / 2.0)
  t.move_to(bx, by)
  t.frame()
  assert_eq(t.cursor(), Hand, msg="Hand over card foot button")
  t.press_at(btn_rect.0 + 4.0, by)
  t.move_to(btn_rect.0 + btn_rect.2 - 4.0, by)
  t.release(btn_rect.0 + btn_rect.2 - 4.0, by)
  t.frame()
  assert_eq(t.ctx().selected_text(), "", msg="button label not selected")
}

///|
test "profile verify card: error text and profile header are selectable with mouse drag and narrow finger long press" {
  let t = setting_tester(Profile("ws1/st1", "cc"), 1280.0, platform=0, mode="settings-profile-verify")
  let detail = t.rect_of("Please verify your account in your browser to continue:").unwrap()
  t.drag(detail.0 + 1.0, detail.1 + 4.0, detail.0 + detail.2 + 20.0, detail.1 + detail.3 - 4.0)
  t.release(detail.0 + detail.2 + 20.0, detail.1 + detail.3 - 4.0)
  t.frame()
  assert_true(t.ctx().selected_text().contains("Please verify your account"), msg="selected: \{t.ctx().selected_text()}")
  // Profile title in own_head_node wide is also selectable.
  let head = t.rect_of("Claude 主账号").unwrap()
  let hy = head.1 + head.3 / 2.0
  t.drag(head.0 + 1.0, hy, head.0 + head.2 + 20.0, hy)
  t.release(head.0 + head.2 + 20.0, hy)
  t.frame()
  assert_eq(t.ctx().selected_text(), "Claude 主账号")
  // Narrow touch: long press on card error text selects a word and opens the floating text menu.
  let tn = setting_tester(Profile("ws1/st1", "cc"), 390.0, platform=2, mode="settings-profile-verify")
  let dn = tn.rect_of("Please verify your account in your browser to continue:").unwrap()
  let (tx, ty) = (dn.0 + 20.0, dn.1 + dn.3 / 2.0)
  tn.press_at(tx, ty)
  tn.run_for(@ui.long_press_ms)
  assert_true(tn.ctx().selected_text() != "", msg="finger long-press picked word")
  tn.release(tx, ty)
  tn.draw()
  assert_true(tn.text_menu().0, msg="floating text menu shown")
}
