// White-box tests for the runtime Agent Bridge (`agent_bridge.mbt`).

///|
fn ab_box(parent : @view.View, w : Double, h : Double, body : (@view.View) -> Unit) -> @view.View {
  parent.box(fn(v) {
    v.width(Is(Some(w))).height(Is(Some(h))) |> ignore
    body(v)
  })
}

///|
test "agent_bridge: snapshot visibility, modal occlusion, agent_hidden subtree, and sources" {
  let modal_open = @signals.signal(false)
  let hidden_clicked = Ref(false)
  let base_clicked = Ref(false)
  let modal_clicked = Ref(false)
  let t = Tester::tree(
    fn(root) {
      ab_box(root, 400.0, 300.0, fn(page) {
        ab_box(page, 120.0, 32.0, fn(btn) {
          btn
          .presses(Is(true))
          .focusable(Is(true))
          .says(Is(Some(@view.said(Button, label="Save", description="Persist draft"))))
          .on_press(fn() { base_clicked.val = true })
          |> ignore
        })
        |> ignore
        // Visually hidden via View::hides
        ab_box(page, 120.0, 32.0, fn(hid) {
          hid
          .hides(Is(true))
          .presses(Is(true))
          .says(Is(Some(@view.said(Button, label="Aria Hidden"))))
          .on_press(fn() { () })
          |> ignore
        })
        |> ignore
        // Hidden from agent via agent_hidden on a non-said container
        ab_box(page, 160.0, 60.0, fn(secret_panel) {
          agent_hidden(secret_panel)
          ab_box(secret_panel, 120.0, 32.0, fn(inner) {
            inner
            .presses(Is(true))
            .says(Is(Some(@view.said(Button, label="Internal Debug"))))
            .on_press(fn() { hidden_clicked.val = true })
            |> ignore
          })
          |> ignore
        })
        |> ignore
        // Modal layer when modal_open is true
        page.show(fn() { modal_open.get() }, fn(host) {
          ab_box(host, 240.0, 120.0, fn(dlg) {
            dlg
            .over(Is(true))
            .modal(Is(true))
            .says(Is(Some(@view.said(Dialog, label="Confirm Modal"))))
            |> ignore
            ab_box(dlg, 100.0, 32.0, fn(ok_btn) {
              ok_btn
              .presses(Is(true))
              .says(Is(Some(@view.said(Button, label="Modal OK"))))
              .on_press(fn() { modal_clicked.val = true })
              |> ignore
            })
            |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    w=420.0,
    h=320.0,
  )
  // Before modal opens: only "Save" is visible; "Aria Hidden" and "Internal Debug" are excluded.
  let snap = t.agent_snapshot()
  assert_eq(snap.length(), 1)
  let save = snap[0]
  assert_eq(save.role, @view.Button)
  assert_eq(save.label, "Save")
  assert_eq(save.description, "Persist draft")
  assert_true(save.ref_id.has_prefix("n:"))
  assert_true(save.actions.contains("press"))
  assert_true(save.actions.contains("focus"))
  assert_true(save.source.contains("agent_bridge_wbtest.mbt"))
  // agent_hidden node cannot be targeted by act
  assert_true(t.agent_act({ target: "Internal Debug", action: Press }) is Err(NotFound(_)))
  assert_eq(hidden_clicked.val, false)
  // Open modal: underlying "Save" is occluded (!allowed), only modal dialog + "Modal OK" remain visible.
  modal_open.set(true)
  t.draw()
  let modal_snap = t.agent_snapshot()
  let labels = modal_snap.map(fn(e) { e.label })
  assert_true(!labels.contains("Save"))
  assert_true(labels.contains("Confirm Modal"))
  assert_true(labels.contains("Modal OK"))
  assert_true(t.agent_act({ target: "Save", action: Press }) is Err(NotFound(_)))
  assert_eq(base_clicked.val, false)
  assert_true(t.agent_act({ target: "Modal OK", action: Press }) is Ok(_))
  assert_eq(modal_clicked.val, true)
  t.assert_idle()
}

///|
test "agent_bridge: agent_secret redaction, anti-side-channel query, and SetValue" {
  let api_key = @signals.signal("sk-live-secret-999")
  let t = Tester::tree(
    fn(root) {
      ab_box(root, 320.0, 120.0, fn(form) {
        ab_box(form, 240.0, 36.0, fn(field) {
          agent_secret(field)
          agent_value_writer(field, fn(v) { api_key.set(v) })
          field
          .presses(Is(true))
          .focusable(Is(true))
          .says(By(fn() { Some(@view.said(TextField, label="API Key", value=api_key.get())) }))
          |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    w=360.0,
    h=160.0,
  )
  let snap = t.agent_snapshot()
  assert_eq(snap.length(), 1)
  assert_eq(snap[0].label, "API Key")
  assert_eq(snap[0].value, "[redacted]")
  assert_eq(snap[0].redacted, true)
  assert_true(snap[0].actions.contains("set_value"))
  // Plaintext never appears in JSON output.
  let json = agent_snapshot_json(snap)
  assert_true(!json.contains("sk-live-secret-999"))
  assert_true(json.contains("[redacted]"))
  assert_true(json.contains("\"redacted\":true"))
  // Anti-side-channel: querying by secret plaintext or "[redacted]" must not match redacted value.
  assert_eq(t.agent_query(text="sk-live-secret-999").length(), 0)
  assert_eq(t.agent_query(text="secret-999").length(), 0)
  assert_eq(t.agent_query(text="redacted").length(), 0)
  // Querying by label still finds the control.
  assert_eq(t.agent_query(text="api key").length(), 1)
  // SetValue still writes the new secret cleanly, and the new secret stays redacted.
  let res = t.agent_act({ target: "API Key", action: SetValue("sk-rotated-777") })
  match res {
    Ok(updated) => {
      assert_eq(updated.value, "[redacted]")
      assert_eq(updated.redacted, true)
    }
    Err(err) => fail("expected Ok from SetValue on secret field, got \{err}")
  }
  assert_eq(api_key.get(), "sk-rotated-777")
  assert_eq(t.agent_query(text="sk-rotated-777").length(), 0)
  assert_true(!agent_snapshot_json(t.agent_snapshot()).contains("sk-rotated-777"))
  t.assert_idle()
}

///|
test "agent_bridge: agent_confirm gating, ancestor inheritance, and nearest override" {
  let outer_deleted = Ref(false)
  let inner_purged = Ref(false)
  let seen_reason = Ref("")
  let t = Tester::tree(
    fn(root) {
      ab_box(root, 360.0, 160.0, fn(danger) {
        agent_confirm(danger, "删除项目及全部文件")
        ab_box(danger, 140.0, 32.0, fn(btn1) {
          btn1
          .presses(Is(true))
          .says(Is(Some(@view.said(Button, label="Delete Project"))))
          .on_press(fn() { outer_deleted.val = true })
          |> ignore
        })
        |> ignore
        ab_box(danger, 140.0, 32.0, fn(btn2) {
          agent_confirm(btn2, "永久清空备份")
          btn2
          .presses(Is(true))
          .says(Is(Some(@view.said(Button, label="Purge Backups"))))
          .on_press(fn() { inner_purged.val = true })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    w=400.0,
    h=200.0,
  )
  let snap = t.agent_snapshot()
  assert_eq(snap.length(), 2)
  assert_eq(snap[0].confirm, Some("删除项目及全部文件"))
  assert_eq(snap[1].confirm, Some("永久清空备份"))
  // Without allow: rejected with NeedsConfirm and zero side effects.
  assert_eq(t.agent_act({ target: "Delete Project", action: Press }), Err(NeedsConfirm("删除项目及全部文件")))
  assert_eq(outer_deleted.val, false)
  // With allow returning false: rejected with zero side effects.
  assert_eq(
    t.agent_act({ target: "Delete Project", action: Press }, allow=fn(a) {
      seen_reason.val = a.reason
      false
    }),
    Err(NeedsConfirm("删除项目及全部文件")),
  )
  assert_eq(seen_reason.val, "删除项目及全部文件")
  assert_eq(outer_deleted.val, false)
  // With allow returning true: executes callback.
  assert_true(
    t.agent_act({ target: "Delete Project", action: Press }, allow=fn(a) { a.reason == "删除项目及全部文件" })
    is Ok(_),
  )
  assert_eq(outer_deleted.val, true)
  // Nearest confirm overrides outer ancestor confirm.
  assert_eq(t.agent_act({ target: "Purge Backups", action: Press }), Err(NeedsConfirm("永久清空备份")))
  assert_eq(inner_purged.val, false)
  assert_true(
    t.agent_act({ target: "Purge Backups", action: Press }, allow=fn(a) { a.reason == "永久清空备份" }) is Ok(_),
  )
  assert_eq(inner_purged.val, true)
  t.assert_idle()
}

///|
test "agent_bridge: ambiguous label rejected, exact ref_id succeeds" {
  let first_hits = Ref(0)
  let second_hits = Ref(0)
  let t = Tester::tree(
    fn(root) {
      ab_box(root, 320.0, 120.0, fn(row) {
        ab_box(row, 100.0, 32.0, fn(b1) {
          b1
          .presses(Is(true))
          .says(Is(Some(@view.said(Button, label="删除"))))
          .on_press(fn() { first_hits.val += 1 })
          |> ignore
        })
        |> ignore
        ab_box(row, 100.0, 32.0, fn(b2) {
          b2
          .presses(Is(true))
          .says(Is(Some(@view.said(Button, label="删除"))))
          .on_press(fn() { second_hits.val += 1 })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    w=360.0,
    h=160.0,
  )
  let snap = t.agent_snapshot()
  assert_eq(snap.length(), 2)
  let ref1 = snap[0].ref_id
  let ref2 = snap[1].ref_id
  assert_true(ref1 != ref2)
  // Ambiguous label must fail and click neither button.
  match t.agent_act({ target: "删除", action: Press }) {
    Err(Ambiguous(refs)) => {
      assert_eq(refs.length(), 2)
      assert_true(refs.contains(ref1))
      assert_true(refs.contains(ref2))
    }
    Ok(e) => fail("expected Err(Ambiguous), got Ok(\{e})")
    Err(err) => fail("expected Err(Ambiguous), got Err(\{err})")
  }
  assert_eq(first_hits.val, 0)
  assert_eq(second_hits.val, 0)
  // Exact ref_id clicks only the targeted button.
  assert_true(t.agent_act({ target: ref2, action: Press }) is Ok(_))
  assert_eq(first_hits.val, 0)
  assert_eq(second_hits.val, 1)
  t.assert_idle()
}

///|
test "agent_bridge: empty target never matches unlabeled controls" {
  let unlabeled_clicked = Ref(false)
  let t = Tester::tree(
    fn(root) {
      ab_box(root, 200.0, 80.0, fn(row) {
        ab_box(row, 40.0, 32.0, fn(icon_btn) {
          icon_btn
          .presses(Is(true))
          .says(Is(Some(@view.said(Button, label=""))))
          .on_press(fn() { unlabeled_clicked.val = true })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    w=240.0,
    h=120.0,
    unnamed_press_held=false,
  )
  let snap = t.agent_snapshot()
  assert_eq(snap.length(), 1)
  assert_eq(snap[0].label, "")
  assert_eq(t.agent_act({ target: "", action: Press }), Err(NotFound("")))
  assert_eq(unlabeled_clicked.val, false)
  // Targeting by explicit ref_id still works.
  assert_true(t.agent_act({ target: snap[0].ref_id, action: Press }) is Ok(_))
  assert_eq(unlabeled_clicked.val, true)
  t.assert_idle()
}

///|
test "agent_bridge: full actions, query filters, agent_act_all short-circuit, and unmount cleanup" {
  let toggled = @signals.signal(false)
  let volume = @signals.signal(50.0)
  let name = @signals.signal("draft")
  let show_ephemeral = @signals.signal(true)
  let ephemeral_id : Ref[@view.NodeId?] = Ref(None)
  let t = Tester::tree(
    fn(root) {
      ab_box(root, 400.0, 300.0, fn(page) {
        ab_box(page, 380.0, 120.0, fn(section) {
          section.says(Is(Some(@view.said(Region, label="Audio Settings")))) |> ignore
          ab_box(section, 120.0, 32.0, fn(sw) {
            sw
            .presses(Is(true))
            .focusable(Is(true))
            .says(By(fn() {
              Some(@view.said(Switch, label="Mute", check=if toggled.get() { @view.On } else { @view.Off }))
            }))
            .on_press(fn() { toggled.set(!toggled.get()) })
            |> ignore
          })
          |> ignore
          ab_box(section, 160.0, 32.0, fn(sl) {
            sl
            .presses(Is(true))
            .focusable(Is(true))
            .says(By(fn() {
              Some(
                @view.said(
                  Slider,
                  label="Volume",
                  value="\{volume.get().to_int()}%",
                  range=(0.0, volume.get(), 100.0),
                  actions=[Increment, Decrement],
                ),
              )
            }))
            .on_step(fn(by) {
              let next = volume.get() + by.to_double() * 10.0
              volume.set(if next < 0.0 { 0.0 } else if next > 100.0 { 100.0 } else { next })
            })
            |> ignore
          })
          |> ignore
        })
        |> ignore
        ab_box(page, 200.0, 36.0, fn(input) {
          agent_value_writer(input, fn(s) { name.set(s) })
          input
          .presses(Is(true))
          .focusable(Is(true))
          .says(By(fn() { Some(@view.said(TextField, label="Project Name", value=name.get())) }))
          |> ignore
        })
        |> ignore
        ab_box(page, 120.0, 32.0, fn(dis) {
          dis
          .presses(Is(false))
          .says(Is(Some(@view.said(Button, label="Locked Action"))))
          .on_press(fn() { () })
          |> ignore
        })
        |> ignore
        page.show(fn() { show_ephemeral.get() }, fn(host) {
          ab_box(host, 120.0, 32.0, fn(ep) {
            ephemeral_id.val = Some(ep.id())
            agent_confirm(ep, "temp confirm")
            agent_secret(ep)
            agent_hidden(ep)
            agent_value_writer(ep, fn(_) { () })
            ep.says(Is(Some(@view.said(TextField, label="Ephemeral", value="x")))) |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    w=420.0,
    h=320.0,
  )
  // Query by within + role.
  let sliders = t.agent_query(role=@view.Slider, within="Audio Settings")
  assert_eq(sliders.length(), 1)
  assert_eq(sliders[0].label, "Volume")
  // Press switch
  match t.agent_act({ target: "Mute", action: Press }) {
    Ok(e) => assert_eq(e.check, Some(@view.On))
    Err(err) => fail("Mute press failed: \{err}")
  }
  // Focus
  assert_true(t.agent_act({ target: "Project Name", action: Focus }) is Ok(_))
  guard view_tree() is Some(tree) else { fail("expected active view_tree") }
  let (focused, _) = tree.focused_now()
  let proj_entry = t.agent_query(text="Project Name")[0]
  assert_eq(focused, Some(proj_entry.node_id))
  // Increment & Decrement slider
  match t.agent_act({ target: "Volume", action: Increment }) {
    Ok(e) => assert_eq(e.value, "60%")
    Err(err) => fail("Volume increment failed: \{err}")
  }
  match t.agent_act({ target: "Volume", action: Decrement }) {
    Ok(e) => assert_eq(e.value, "50%")
    Err(err) => fail("Volume decrement failed: \{err}")
  }
  // SetValue
  match t.agent_act({ target: "Project Name", action: SetValue("monoid-v2") }) {
    Ok(e) => assert_eq(e.value, "monoid-v2")
    Err(err) => fail("SetValue failed: \{err}")
  }
  // Disabled and UnsupportedAction errors
  assert_true(t.agent_act({ target: "Locked Action", action: Press }) is Err(Disabled(_)))
  assert_true(t.agent_act({ target: "Mute", action: Increment }) is Err(UnsupportedAction(_)))
  // agent_act_all short-circuits on first Err (third step must not run)
  let batch = agent_act_all(tree, [
    { target: "Volume", action: Increment },
    { target: "Locked Action", action: Press },
    { target: "Volume", action: Increment },
  ])
  t.draw()
  assert_eq(batch.length(), 2)
  assert_true(batch[0] is Ok(_))
  assert_true(batch[1] is Err(Disabled(_)))
  assert_eq(volume.get(), 60.0)
  // Unmount cleanup: all 4 marker registries release the unmounted node id with zero leak.
  guard ephemeral_id.val is Some(eid) else { fail("expected ephemeral node id") }
  assert_true(agent_confirms.contains(eid))
  assert_true(agent_secrets.contains(eid))
  assert_true(agent_hiddens.contains(eid))
  assert_true(agent_writers.contains(eid))
  show_ephemeral.set(false)
  t.draw()
  assert_true(!agent_confirms.contains(eid))
  assert_true(!agent_secrets.contains(eid))
  assert_true(!agent_hiddens.contains(eid))
  assert_true(!agent_writers.contains(eid))
  t.assert_idle()
}

///|
test "agent_bridge: real field(secret=true) auto-registers agent_secret and prevents side-channel queries" {
  let pw = Field::new(text="super-secret-pass-42")
  let plain = Field::new(text="public-user-name")
  let t = Tester::tree(
    fn(root) {
      ab_box(root, 360.0, 140.0, fn(form) {
        field(form, pw, label="Password", secret=true) |> ignore
        field(form, plain, label="Username", secret=false) |> ignore
      })
      |> ignore
    },
    w=400.0,
    h=180.0,
  )
  let snap = t.agent_snapshot()
  assert_eq(snap.length(), 2)
  let pw_entry = snap.iter().find_first(fn(e) { e.label == "Password" }).unwrap()
  let plain_entry = snap.iter().find_first(fn(e) { e.label == "Username" }).unwrap()
  assert_eq(pw_entry.value, "[redacted]")
  assert_eq(pw_entry.redacted, true)
  assert_eq(plain_entry.value, "public-user-name")
  assert_eq(plain_entry.redacted, false)
  let json = agent_snapshot_json(snap)
  assert_true(!json.contains("super-secret-pass-42"))
  assert_true(json.contains("[redacted]"))
  assert_true(json.contains("public-user-name"))
  // Anti-side-channel: querying by plaintext secret or "[redacted]" returns nothing.
  assert_eq(t.agent_query(text="super-secret-pass-42").length(), 0)
  assert_eq(t.agent_query(text="pass-42").length(), 0)
  assert_eq(t.agent_query(text="redacted").length(), 0)
  // Querying by label still finds the password field.
  assert_eq(t.agent_query(text="Password").length(), 1)
  t.assert_idle()
}
