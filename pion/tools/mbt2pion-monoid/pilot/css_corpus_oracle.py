#!/usr/bin/env python3
"""Batch 3-engine full production `@ui.css(...)` corpus parity oracle.

Runs ALL distinct decoded `@ui.css(...)` strings from `css_corpus_manifest.json`
(`2,096` production callsites / `1,237` distinct strings) in a SINGLE batch binary
execution per engine:
  1. `moon run --target wasm-gc` (real `libs/ui/src/ui/style_css.mbt` `@ui.css_read`)
  2. `pionc run` native (real `pion/ui/packages/sf/src/style_css.pion` `sf::css_read`)
  3. `pionc run --target wasm32` (real `sf::css_read` on wasm32)

Compares ALL `base` + 7 state (`narrow`, `dark`, `selected`, `hovered`, `focused`,
`pressed`, `disabled`) `Patch` fields (32 fields per patch, recursive enum payloads,
nested `Over`/`A`/`Exact`/`Cast`/`InnerOr`, and IEEE-754 64-bit `Double` bits) OR
exact error text + cursor offset (`AFirstLine` explicitly asserted as fail-loud).
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

TIMEOUT_S = 180
EXPECTED_CALLSITES = 2096
EXPECTED_DISTINCT = 1237

MOON_DRIVER = r'''
fn dbits(d : Double) -> String {
  d.reinterpret_as_uint64().to_string()
}

fn ser_bool(v : Bool?) -> String {
  match v {
    None => "-"
    Some(true) => "true"
    Some(false) => "false"
  }
}

fn ser_len(v : @ui.Len?) -> String {
  match v {
    None => "-"
    Some(x) =>
      match x {
        Hug => "Hug"
        Cut => "Cut"
        Full => "Full"
        Grow(d) => "Grow(" + dbits(d) + ")"
        Fixed(d) => "Fixed(" + dbits(d) + ")"
        Pct(d) => "Pct(" + dbits(d) + ")"
        Within(d) => "Within(" + dbits(d) + ")"
        S0 => "S0"
        SPx => "SPx"
        S0_5 => "S0_5"
        S1 => "S1"
        S1_25 => "S1_25"
        S1_5 => "S1_5"
        S2 => "S2"
        S2_5 => "S2_5"
        S3 => "S3"
        S3_5 => "S3_5"
        S4 => "S4"
        S4_5 => "S4_5"
        S5 => "S5"
        S6 => "S6"
        S7 => "S7"
        S8 => "S8"
        S9 => "S9"
        S10 => "S10"
        S11 => "S11"
        S12 => "S12"
        S14 => "S14"
        S16 => "S16"
        S20 => "S20"
        S24 => "S24"
        S28 => "S28"
        S32 => "S32"
        S36 => "S36"
        S40 => "S40"
        S44 => "S44"
        S48 => "S48"
        S52 => "S52"
        S56 => "S56"
        S60 => "S60"
        S64 => "S64"
        S72 => "S72"
        S80 => "S80"
        S96 => "S96"
      }
  }
}

fn ser_space(v : @ui.Space?) -> String {
  match v {
    None => "-"
    Some(x) =>
      match x {
        S0 => "S0"
        SPx => "SPx"
        S0_5 => "S0_5"
        S1 => "S1"
        S1_25 => "S1_25"
        S1_5 => "S1_5"
        S2 => "S2"
        S2_5 => "S2_5"
        S3 => "S3"
        S3_5 => "S3_5"
        S4 => "S4"
        S4_5 => "S4_5"
        S5 => "S5"
        S6 => "S6"
        S7 => "S7"
        S8 => "S8"
        S9 => "S9"
        S10 => "S10"
        S11 => "S11"
        S12 => "S12"
        S14 => "S14"
        S16 => "S16"
        S20 => "S20"
        S24 => "S24"
        S28 => "S28"
        S32 => "S32"
        S36 => "S36"
        S40 => "S40"
        S44 => "S44"
        S48 => "S48"
        S52 => "S52"
        S56 => "S56"
        S60 => "S60"
        S64 => "S64"
        S72 => "S72"
        S80 => "S80"
        S96 => "S96"
        Exact(d) => "Exact(" + dbits(d) + ")"
      }
  }
}

fn ser_align(v : @ui.Align?) -> String {
  match v {
    None => "-"
    Some(x) =>
      match x {
        AStart => "Start"
        ACenter => "Center"
        AEnd => "End"
        AStretch => "Stretch"
        ABaseline => "Baseline"
        AFirstLine => "FirstLine"
      }
  }
}

fn ser_justify(v : @ui.Justify?) -> String {
  match v {
    None => "-"
    Some(x) =>
      match x {
        JStart => "Start"
        JCenter => "Center"
        JEnd => "End"
        JBetween => "Between"
      }
  }
}

fn ser_opacity_val(x : @ui.Opacity) -> String {
  match x {
    O0 => "O0"
    O5 => "O5"
    O10 => "O10"
    O15 => "O15"
    O20 => "O20"
    O25 => "O25"
    O30 => "O30"
    O35 => "O35"
    O40 => "O40"
    O45 => "O45"
    O50 => "O50"
    O55 => "O55"
    O60 => "O60"
    O65 => "O65"
    O70 => "O70"
    O75 => "O75"
    O80 => "O80"
    O85 => "O85"
    O90 => "O90"
    O95 => "O95"
    O100 => "O100"
    Exact(d) => "Exact(" + dbits(d) + ")"
  }
}

fn ser_opacity(v : @ui.Opacity?) -> String {
  match v {
    None => "-"
    Some(x) => ser_opacity_val(x)
  }
}

fn ser_color_val(x : @ui.Color) -> String {
  match x {
    Clear => "Clear"
    Bg => "Bg"
    Surface => "Surface"
    Raised => "Raised"
    Card => "Card"
    Fg => "Fg"
    Muted => "Muted"
    Subtle => "Subtle"
    Faint => "Faint"
    Line => "Line"
    Border => "Border"
    Accent => "Accent"
    AccentText => "AccentText"
    AccentBg => "AccentBg"
    OnAccent => "OnAccent"
    Primary => "Primary"
    OnPrimary => "OnPrimary"
    Positive => "Positive"
    Danger => "Danger"
    DangerBg => "DangerBg"
    OnDanger => "OnDanger"
    Neutral => "Neutral"
    Hover => "Hover"
    Selected => "Selected"
    Focus => "Focus"
    Scrim => "Scrim"
    Link => "Link"
    ShadowC => "ShadowC"
    Warn => "Warn"
    WarnInk => "WarnInk"
    Tint => "Tint"
    TintStrong => "TintStrong"
    Floating => "Floating"
    Veil => "Veil"
    VeilDeep => "VeilDeep"
    OnVeil => "OnVeil"
    Theater => "Theater"
    Lifted => "Lifted"
    Wash => "Wash"
    Sidebar => "Sidebar"
    ListGround => "ListGround"
    FieldHover => "FieldHover"
    A(c, o) => "A(" + ser_color_val(c) + "," + ser_opacity_val(o) + ")"
    Over(a, b) => "Over(" + ser_color_val(a) + "," + ser_color_val(b) + ")"
    Exact(n) => "Exact(" + n.to_string() + ")"
    Data(n) => "Data(" + n.to_string() + ")"
  }
}

fn ser_color(v : @ui.Color?) -> String {
  match v {
    None => "-"
    Some(x) => ser_color_val(x)
  }
}

fn ser_radius_val(x : @ui.Radius) -> String {
  match x {
    Sharp => "Sharp"
    Sm => "Sm"
    Base => "Base"
    Md => "Md"
    Lg => "Lg"
    Xl => "Xl"
    Xl1_5 => "Xl1_5"
    Xl2 => "Xl2"
    Xl3 => "Xl3"
    Xl4 => "Xl4"
    Full => "Full"
    Inner => "Inner"
    InnerOr(r) => "InnerOr(" + ser_radius_val(r) + ")"
    Around => "Around"
    Exact(d) => "Exact(" + dbits(d) + ")"
    Corners(a, b, c, d) => "Corners(" + dbits(a) + "," + dbits(b) + "," + dbits(c) + "," + dbits(d) + ")"
    _ => "OtherRadius"
  }
}

fn ser_radius(v : @ui.Radius?) -> String {
  match v {
    None => "-"
    Some(x) => ser_radius_val(x)
  }
}

fn ser_stroke(v : @ui.Stroke?) -> String {
  match v {
    None => "-"
    Some(x) =>
      match x {
        B0 => "B0"
        B0_5 => "B0_5"
        B1 => "B1"
        B1_5 => "B1_5"
        B2 => "B2"
        B4 => "B4"
        B8 => "B8"
      }
  }
}

fn ser_shadow(v : @ui.Shadow?) -> String {
  match v {
    None => "-"
    Some(x) =>
      match x {
        NoShadow => "NoShadow"
        Sm => "Sm"
        Base => "Base"
        Md => "Md"
        Lg => "Lg"
        Xl => "Xl"
        Cast(b, y, c) => "Cast(" + dbits(b) + "," + dbits(y) + "," + c.to_string() + ")"
      }
  }
}

fn ser_patch(p : @ui.Patch) -> String {
  "{" +
  "row=" + ser_bool(p.row) +
  ",w=" + ser_len(p.w) +
  ",h=" + ser_len(p.h) +
  ",min_w=" + ser_len(p.min_w) +
  ",max_w=" + ser_len(p.max_w) +
  ",min_h=" + ser_len(p.min_h) +
  ",max_h=" + ser_len(p.max_h) +
  ",p=" + ser_space(p.p) +
  ",px=" + ser_space(p.px) +
  ",py=" + ser_space(p.py) +
  ",pl=" + ser_space(p.pl) +
  ",pr=" + ser_space(p.pr) +
  ",pt=" + ser_space(p.pt) +
  ",pb=" + ser_space(p.pb) +
  ",m=" + ser_space(p.m) +
  ",mx=" + ser_space(p.mx) +
  ",my=" + ser_space(p.my) +
  ",ml=" + ser_space(p.ml) +
  ",mr=" + ser_space(p.mr) +
  ",mt=" + ser_space(p.mt) +
  ",mb=" + ser_space(p.mb) +
  ",gap=" + ser_space(p.gap) +
  ",align=" + ser_align(p.align) +
  ",justify=" + ser_justify(p.justify) +
  ",bg=" + ser_color(p.bg) +
  ",radius=" + ser_radius(p.radius) +
  ",border=" + ser_stroke(p.border) +
  ",border_color=" + ser_color(p.border_color) +
  ",dashed=" + ser_bool(p.dashed) +
  ",shadow=" + ser_shadow(p.shadow) +
  ",clip=" + ser_bool(p.clip) +
  ",opacity=" + ser_opacity(p.opacity) +
  "}"
}

fn ser_opt_patch(p : @ui.Patch?) -> String {
  match p {
    None => "-"
    Some(x) => ser_patch(x)
  }
}

fn ser_style(st : @ui.Style) -> String {
  "base=" + ser_patch(st.base) +
  ";narrow=" + ser_opt_patch(st.narrow) +
  ";dark=" + ser_opt_patch(st.dark) +
  ";selected=" + ser_opt_patch(st.selected) +
  ";hovered=" + ser_opt_patch(st.hovered) +
  ";focused=" + ser_opt_patch(st.focused) +
  ";pressed=" + ser_opt_patch(st.pressed) +
  ";disabled=" + ser_opt_patch(st.disabled)
}

fn main {
  let xs = corpus_strings()
  for i = 0; i < xs.length(); i = i + 1 {
    match @ui.css_read(xs[i]) {
      Ok(st) => println("R " + i.to_string() + " OK:" + ser_style(st))
      Err(e) => println("R " + i.to_string() + " ERR:" + e)
    }
    println("A css_corpus.entry." + i.to_string())
  }
  println("A css_corpus.total." + xs.length().to_string())
}
'''

PION_DRIVER = r'''
import "sf"
import "ui"

fn dbits(d : Double) -> String {
  d.reinterpret_as_uint64().to_string()
}

fn ser_bool(v : Option[Bool]) -> String {
  match v {
    None => "-"
    Some(true) => "true"
    Some(false) => "false"
  }
}

fn ser_len(v : Option[ui::Len]) -> String {
  match v {
    None => "-"
    Some(x) =>
      match x {
        ui::Len::Hug => "Hug"
        ui::Len::Cut => "Cut"
        ui::Len::Full => "Full"
        ui::Len::Grow(d) => "Grow(" + dbits(d) + ")"
        ui::Len::Fixed(d) => "Fixed(" + dbits(d) + ")"
        ui::Len::Pct(d) => "Pct(" + dbits(d) + ")"
        ui::Len::Within(d) => "Within(" + dbits(d) + ")"
        ui::Len::S0 => "S0"
        ui::Len::SPx => "SPx"
        ui::Len::S0_5 => "S0_5"
        ui::Len::S1 => "S1"
        ui::Len::S1_25 => "S1_25"
        ui::Len::S1_5 => "S1_5"
        ui::Len::S2 => "S2"
        ui::Len::S2_5 => "S2_5"
        ui::Len::S3 => "S3"
        ui::Len::S3_5 => "S3_5"
        ui::Len::S4 => "S4"
        ui::Len::S4_5 => "S4_5"
        ui::Len::S5 => "S5"
        ui::Len::S6 => "S6"
        ui::Len::S7 => "S7"
        ui::Len::S8 => "S8"
        ui::Len::S9 => "S9"
        ui::Len::S10 => "S10"
        ui::Len::S11 => "S11"
        ui::Len::S12 => "S12"
        ui::Len::S14 => "S14"
        ui::Len::S16 => "S16"
        ui::Len::S20 => "S20"
        ui::Len::S24 => "S24"
        ui::Len::S28 => "S28"
        ui::Len::S32 => "S32"
        ui::Len::S36 => "S36"
        ui::Len::S40 => "S40"
        ui::Len::S44 => "S44"
        ui::Len::S48 => "S48"
        ui::Len::S52 => "S52"
        ui::Len::S56 => "S56"
        ui::Len::S60 => "S60"
        ui::Len::S64 => "S64"
        ui::Len::S72 => "S72"
        ui::Len::S80 => "S80"
        ui::Len::S96 => "S96"
      }
  }
}

fn ser_space(v : Option[ui::Space]) -> String {
  match v {
    None => "-"
    Some(x) =>
      match x {
        ui::Space::S0 => "S0"
        ui::Space::SPx => "SPx"
        ui::Space::S0_5 => "S0_5"
        ui::Space::S1 => "S1"
        ui::Space::S1_25 => "S1_25"
        ui::Space::S1_5 => "S1_5"
        ui::Space::S2 => "S2"
        ui::Space::S2_5 => "S2_5"
        ui::Space::S3 => "S3"
        ui::Space::S3_5 => "S3_5"
        ui::Space::S4 => "S4"
        ui::Space::S4_5 => "S4_5"
        ui::Space::S5 => "S5"
        ui::Space::S6 => "S6"
        ui::Space::S7 => "S7"
        ui::Space::S8 => "S8"
        ui::Space::S9 => "S9"
        ui::Space::S10 => "S10"
        ui::Space::S11 => "S11"
        ui::Space::S12 => "S12"
        ui::Space::S14 => "S14"
        ui::Space::S16 => "S16"
        ui::Space::S20 => "S20"
        ui::Space::S24 => "S24"
        ui::Space::S28 => "S28"
        ui::Space::S32 => "S32"
        ui::Space::S36 => "S36"
        ui::Space::S40 => "S40"
        ui::Space::S44 => "S44"
        ui::Space::S48 => "S48"
        ui::Space::S52 => "S52"
        ui::Space::S56 => "S56"
        ui::Space::S60 => "S60"
        ui::Space::S64 => "S64"
        ui::Space::S72 => "S72"
        ui::Space::S80 => "S80"
        ui::Space::S96 => "S96"
        ui::Space::Exact(d) => "Exact(" + dbits(d) + ")"
      }
  }
}

fn ser_align(v : Option[ui::Align]) -> String {
  match v {
    None => "-"
    Some(x) =>
      match x {
        ui::Align::Start => "Start"
        ui::Align::Center => "Center"
        ui::Align::End => "End"
        ui::Align::Stretch => "Stretch"
        ui::Align::Baseline => "Baseline"
      }
  }
}

fn ser_justify(v : Option[ui::Justify]) -> String {
  match v {
    None => "-"
    Some(x) =>
      match x {
        ui::Justify::Start => "Start"
        ui::Justify::Center => "Center"
        ui::Justify::End => "End"
        ui::Justify::Between => "Between"
        ui::Justify::Around => "Around"
        ui::Justify::Evenly => "Evenly"
      }
  }
}

fn ser_opacity_val(x : ui::Opacity) -> String {
  match x {
    ui::Opacity::O0 => "O0"
    ui::Opacity::O5 => "O5"
    ui::Opacity::O10 => "O10"
    ui::Opacity::O15 => "O15"
    ui::Opacity::O20 => "O20"
    ui::Opacity::O25 => "O25"
    ui::Opacity::O30 => "O30"
    ui::Opacity::O35 => "O35"
    ui::Opacity::O40 => "O40"
    ui::Opacity::O45 => "O45"
    ui::Opacity::O50 => "O50"
    ui::Opacity::O55 => "O55"
    ui::Opacity::O60 => "O60"
    ui::Opacity::O65 => "O65"
    ui::Opacity::O70 => "O70"
    ui::Opacity::O75 => "O75"
    ui::Opacity::O80 => "O80"
    ui::Opacity::O85 => "O85"
    ui::Opacity::O90 => "O90"
    ui::Opacity::O95 => "O95"
    ui::Opacity::O100 => "O100"
    ui::Opacity::Exact(d) => "Exact(" + dbits(d) + ")"
  }
}

fn ser_opacity(v : Option[ui::Opacity]) -> String {
  match v {
    None => "-"
    Some(x) => ser_opacity_val(x)
  }
}

fn ser_color_val(x : ui::Color) -> String {
  match x {
    ui::Color::Clear => "Clear"
    ui::Color::Bg => "Bg"
    ui::Color::Surface => "Surface"
    ui::Color::Raised => "Raised"
    ui::Color::Card => "Card"
    ui::Color::Fg => "Fg"
    ui::Color::Muted => "Muted"
    ui::Color::Subtle => "Subtle"
    ui::Color::Faint => "Faint"
    ui::Color::Line => "Line"
    ui::Color::Border => "Border"
    ui::Color::Accent => "Accent"
    ui::Color::AccentText => "AccentText"
    ui::Color::AccentBg => "AccentBg"
    ui::Color::OnAccent => "OnAccent"
    ui::Color::Primary => "Primary"
    ui::Color::OnPrimary => "OnPrimary"
    ui::Color::Positive => "Positive"
    ui::Color::Danger => "Danger"
    ui::Color::DangerBg => "DangerBg"
    ui::Color::OnDanger => "OnDanger"
    ui::Color::Neutral => "Neutral"
    ui::Color::Hover => "Hover"
    ui::Color::Selected => "Selected"
    ui::Color::Focus => "Focus"
    ui::Color::Scrim => "Scrim"
    ui::Color::Link => "Link"
    ui::Color::ShadowC => "ShadowC"
    ui::Color::Warn => "Warn"
    ui::Color::WarnInk => "WarnInk"
    ui::Color::Tint => "Tint"
    ui::Color::TintStrong => "TintStrong"
    ui::Color::Floating => "Floating"
    ui::Color::Veil => "Veil"
    ui::Color::VeilDeep => "VeilDeep"
    ui::Color::OnVeil => "OnVeil"
    ui::Color::Theater => "Theater"
    ui::Color::Lifted => "Lifted"
    ui::Color::Wash => "Wash"
    ui::Color::Sidebar => "Sidebar"
    ui::Color::ListGround => "ListGround"
    ui::Color::FieldHover => "FieldHover"
    ui::Color::A(c, o) => "A(" + ser_color_val(c) + "," + ser_opacity_val(o) + ")"
    ui::Color::Over(a, b) => "Over(" + ser_color_val(a) + "," + ser_color_val(b) + ")"
    ui::Color::Exact(n) => "Exact(" + n.to_string() + ")"
    ui::Color::Data(n) => "Data(" + n.to_string() + ")"
  }
}

fn ser_color(v : Option[ui::Color]) -> String {
  match v {
    None => "-"
    Some(x) => ser_color_val(x)
  }
}

fn ser_radius_val(x : ui::Radius) -> String {
  match x {
    ui::Radius::Sharp => "Sharp"
    ui::Radius::Sm => "Sm"
    ui::Radius::Base => "Base"
    ui::Radius::Md => "Md"
    ui::Radius::Lg => "Lg"
    ui::Radius::Xl => "Xl"
    ui::Radius::Xl1_5 => "Xl1_5"
    ui::Radius::Xl2 => "Xl2"
    ui::Radius::Xl3 => "Xl3"
    ui::Radius::Xl4 => "Xl4"
    ui::Radius::Full => "Full"
    ui::Radius::Inner => "Inner"
    ui::Radius::InnerOr(r) => "InnerOr(" + ser_radius_val(r) + ")"
    ui::Radius::Around => "Around"
    ui::Radius::Exact(d) => "Exact(" + dbits(d) + ")"
    ui::Radius::Corners(a, b, c, d) => "Corners(" + dbits(a) + "," + dbits(b) + "," + dbits(c) + "," + dbits(d) + ")"
    _ => "OtherRadius"
  }
}

fn ser_radius(v : Option[ui::Radius]) -> String {
  match v {
    None => "-"
    Some(x) => ser_radius_val(x)
  }
}

fn ser_stroke(v : Option[ui::Stroke]) -> String {
  match v {
    None => "-"
    Some(x) =>
      match x {
        ui::Stroke::B0 => "B0"
        ui::Stroke::B0_5 => "B0_5"
        ui::Stroke::B1 => "B1"
        ui::Stroke::B1_5 => "B1_5"
        ui::Stroke::B2 => "B2"
        ui::Stroke::B4 => "B4"
        ui::Stroke::B8 => "B8"
      }
  }
}

fn ser_shadow(v : Option[ui::Shadow]) -> String {
  match v {
    None => "-"
    Some(x) =>
      match x {
        ui::Shadow::NoShadow => "NoShadow"
        ui::Shadow::Sm => "Sm"
        ui::Shadow::Base => "Base"
        ui::Shadow::Md => "Md"
        ui::Shadow::Lg => "Lg"
        ui::Shadow::Xl => "Xl"
        ui::Shadow::Cast(b, y, c) => "Cast(" + dbits(b) + "," + dbits(y) + "," + c.to_string() + ")"
      }
  }
}

fn ser_patch(p : ui::Patch) -> String {
  "{" +
  "row=" + ser_bool(p.row) +
  ",w=" + ser_len(p.w) +
  ",h=" + ser_len(p.h) +
  ",min_w=" + ser_len(p.min_w) +
  ",max_w=" + ser_len(p.max_w) +
  ",min_h=" + ser_len(p.min_h) +
  ",max_h=" + ser_len(p.max_h) +
  ",p=" + ser_space(p.p) +
  ",px=" + ser_space(p.px) +
  ",py=" + ser_space(p.py) +
  ",pl=" + ser_space(p.pl) +
  ",pr=" + ser_space(p.pr) +
  ",pt=" + ser_space(p.pt) +
  ",pb=" + ser_space(p.pb) +
  ",m=" + ser_space(p.m) +
  ",mx=" + ser_space(p.mx) +
  ",my=" + ser_space(p.my) +
  ",ml=" + ser_space(p.ml) +
  ",mr=" + ser_space(p.mr) +
  ",mt=" + ser_space(p.mt) +
  ",mb=" + ser_space(p.mb) +
  ",gap=" + ser_space(p.gap) +
  ",align=" + ser_align(p.align) +
  ",justify=" + ser_justify(p.justify) +
  ",bg=" + ser_color(p.bg) +
  ",radius=" + ser_radius(p.radius) +
  ",border=" + ser_stroke(p.border) +
  ",border_color=" + ser_color(p.border_color) +
  ",dashed=" + ser_bool(p.dashed) +
  ",shadow=" + ser_shadow(p.shadow) +
  ",clip=" + ser_bool(p.clip) +
  ",opacity=" + ser_opacity(p.opacity) +
  "}"
}

fn ser_opt_patch(p : Option[ui::Patch]) -> String {
  match p {
    None => "-"
    Some(x) => ser_patch(x)
  }
}

fn ser_style(st : ui::Style) -> String {
  "base=" + ser_patch(st.base) +
  ";narrow=" + ser_opt_patch(st.narrow) +
  ";dark=" + ser_opt_patch(st.dark) +
  ";selected=" + ser_opt_patch(st.selected) +
  ";hovered=" + ser_opt_patch(st.hovered) +
  ";focused=" + ser_opt_patch(st.focused) +
  ";pressed=" + ser_opt_patch(st.pressed) +
  ";disabled=" + ser_opt_patch(st.disabled)
}

pub fn main(world : World) -> Int {
  let xs = corpus_strings()
  let mut i = 0
  while i < xs.length() {
    match sf::css_read(xs[i]) {
      Ok(st) => io_println(world, "R " + i.to_string() + " OK:" + ser_style(st))
      Err(e) => io_println(world, "R " + i.to_string() + " ERR:" + e)
    }
    io_println(world, "A css_corpus.entry." + i.to_string())
    i = i + 1
  }
  io_println(world, "A css_corpus.total." + xs.length().to_string())
  0
}
'''


def escape_str_literal(s):
    return json.dumps(s, ensure_ascii=False)


def gen_corpus_array_mbt(strings):
    lines = ["fn corpus_strings() -> Array[String] {", "  let xs : Array[String] = []"]
    for s in strings:
        lines.append(f"  xs.push({escape_str_literal(s)})")
    lines.append("  xs")
    lines.append("}")
    return "\n".join(lines) + "\n"


def gen_corpus_array_pion(strings):
    lines = ["fn corpus_strings() -> Array[String] {", "  let xs : Array[String] = []"]
    for s in strings:
        lines.append(f"  xs.push({escape_str_literal(s)})")
    lines.append("  xs")
    lines.append("}")
    return "\n".join(lines) + "\n"


def run_cmd(cmd, cwd=None):
    t0 = time.time()
    p = subprocess.run(
        cmd,
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=TIMEOUT_S,
    )
    return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace"), time.time() - t0


def parse_engine_output(out):
    records = {}
    asserts = []
    junk = []
    for line in out.splitlines():
        if line.startswith("R "):
            parts = line.split(" ", 2)
            if len(parts) == 3 and parts[1].isdigit():
                records[int(parts[1])] = parts[2]
            else:
                junk.append(line)
        elif line.startswith("A "):
            asserts.append(line[2:])
        elif line.strip():
            junk.append(line)
    return records, asserts, junk


def compare_engine_outputs(strings, moon_out, nat_out, wasm_out):
    """Compare all 3 engine outputs across all distinct CSS strings. Returns list of error strings."""
    errs = []
    n = len(strings)
    expected_asserts = [f"css_corpus.entry.{i}" for i in range(n)] + [f"css_corpus.total.{n}"]

    m_rec, m_ass, m_junk = parse_engine_output(moon_out)
    n_rec, n_ass, n_junk = parse_engine_output(nat_out)
    w_rec, w_ass, w_junk = parse_engine_output(wasm_out)

    for label, rec, ass, junk in [
        ("moon", m_rec, m_ass, m_junk),
        ("pion-native", n_rec, n_ass, n_junk),
        ("pion-wasm32", w_rec, w_ass, w_junk),
    ]:
        if junk:
            errs.append(f"{label}: unexpected stdout lines: {junk[:3]!r}")
        if len(rec) != n:
            errs.append(f"{label}: record count {len(rec)} != expected {n}")
        if ass != expected_asserts:
            errs.append(f"{label}: assertion IDs mismatch (got {len(ass)}, expected {len(expected_asserts)})")

    if errs:
        return errs

    afirstline_checked = 0
    for i, css_text in enumerate(strings):
        mv = m_rec[i]
        nv = n_rec[i]
        wv = w_rec[i]
        if nv != wv:
            errs.append(f"[{i}] pion-native != pion-wasm32 for {css_text!r}: native={nv!r} wasm32={wv!r}")
            if len(errs) >= 10:
                break
            continue
        if "AFirstLine" in css_text:
            afirstline_checked += 1
            if not (mv.startswith("OK:") and "align=FirstLine" in mv):
                errs.append(f"[{i}] moon expected OK with align=FirstLine for {css_text!r}, got {mv!r}")
            if not (nv.startswith("ERR:css: unsupported Align AFirstLine (missing in invar ui::Align) at ")):
                errs.append(f"[{i}] pion expected fail-loud AFirstLine error for {css_text!r}, got {nv!r}")
        else:
            if mv != nv:
                errs.append(f"[{i}] moon != pion for {css_text!r}:\n  moon={mv}\n  pion={nv}")
                if len(errs) >= 10:
                    break

    if afirstline_checked == 0:
        errs.append("expected at least 1 AFirstLine production corpus string to be verified fail-loud")

    return errs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--repo-root", required=True)
    ap.add_argument("--moon-bin", default="moon")
    ap.add_argument("--pionc-bin", default="pionc")
    ap.add_argument("--invar-rev", required=True)
    ap.add_argument("--mbt-compat-dir", required=True)
    ap.add_argument("--verify-negative", action="store_true")
    args = ap.parse_args()

    manifest = json.load(open(args.manifest, "r", encoding="utf-8"))
    if manifest.get("callsites_total") != EXPECTED_CALLSITES:
        print(f"ERROR: callsites_total={manifest.get('callsites_total')} != frozen {EXPECTED_CALLSITES}", file=sys.stderr)
        return 1
    strings = manifest.get("distinct_strings", [])
    if len(strings) != EXPECTED_DISTINCT:
        print(f"ERROR: distinct_strings={len(strings)} != frozen {EXPECTED_DISTINCT}", file=sys.stderr)
        return 1

    work = tempfile.mkdtemp(prefix="m12-css-corpus.")
    try:
        # 1. Assemble batch MoonBit project staging real `libs/ui/src/*`
        moon_work = os.path.join(work, "moon_css")
        shutil.copytree(os.path.join(args.repo_root, "pion/tools/mbt2pion-monoid/pilot/moon_pilot"), moon_work)
        libs_ui_src = os.path.join(args.repo_root, "libs/ui/src")
        for dep_pkg in (
            "halt", "dmath", "zip", "codec", "signals", "pixels", "paint",
            "text", "flex", "effect", "damage", "hostapi", "view", "ui",
        ):
            shutil.copytree(
                os.path.join(libs_ui_src, dep_pkg),
                os.path.join(moon_work, "src", dep_pkg),
                ignore=shutil.ignore_patterns("*_test.mbt", "*_wbtest.mbt"),
            )
        with open(os.path.join(moon_work, "src/controls/main.mbt"), "w", encoding="utf-8") as f:
            f.write(MOON_DRIVER)
        with open(os.path.join(moon_work, "src/controls/corpus_data.mbt"), "w", encoding="utf-8") as f:
            f.write(gen_corpus_array_mbt(strings))

        # 2. Assemble batch Pion workspace using real `pion/ui/packages/sf`
        pion_ws = os.path.join(work, "pion_css_ws")
        pion_pkg = os.path.join(pion_ws, "css_batch")
        os.makedirs(os.path.join(pion_pkg, "src"))
        with open(os.path.join(pion_ws, "pion.toml"), "w", encoding="utf-8") as f:
            f.write(f'''[workspace]
members = ["css_batch"]

[workspace.dependencies]
base64 = {{ git = "https://github.com/AFK-surf/pion-packages.git", tag = "base64-v0.1.0", subdir = "packages/base64" }}
mbt_compat = {{ path = "{args.mbt_compat_dir}" }}
sf = {{ path = "{os.path.join(args.repo_root, 'pion/ui/packages/sf')}" }}
signals = {{ git = "https://github.com/AFK-surf/invar.git", rev = "{args.invar_rev}", subdir = "packages/signals" }}
view = {{ git = "https://github.com/AFK-surf/invar.git", rev = "{args.invar_rev}", subdir = "packages/view" }}
ui = {{ git = "https://github.com/AFK-surf/invar.git", rev = "{args.invar_rev}", subdir = "packages/ui" }}
zip = {{ git = "https://github.com/AFK-surf/invar.git", rev = "{args.invar_rev}", subdir = "packages/zip" }}
pixels = {{ git = "https://github.com/AFK-surf/invar.git", rev = "{args.invar_rev}", subdir = "packages/pixels" }}
paint = {{ git = "https://github.com/AFK-surf/invar.git", rev = "{args.invar_rev}", subdir = "packages/paint" }}
''')
        with open(os.path.join(pion_pkg, "pion.toml"), "w", encoding="utf-8") as f:
            f.write('''[package]
name = "m12_css_corpus_batch"
version = "0.1.0"

[dependencies]
sf = { workspace = true }
ui = { workspace = true }
''')
        with open(os.path.join(pion_pkg, "src/main.pion"), "w", encoding="utf-8") as f:
            f.write(PION_DRIVER)
        with open(os.path.join(pion_pkg, "src/corpus_data.pion"), "w", encoding="utf-8") as f:
            f.write(gen_corpus_array_pion(strings))

        native_bin = os.path.join(work, "css_batch_native")
        wasm_bin = os.path.join(work, "css_batch.wasm")

        for cmd, cwd, label in [
            ([args.moon_bin, "build", "--target", "wasm-gc"], moon_work, "moon build --target wasm-gc"),
            ([args.pionc_bin, "check", "--json", pion_pkg], None, "pionc check css_batch"),
            ([args.pionc_bin, "build", pion_pkg, "-o", native_bin], None, "pionc build css_batch"),
            ([args.pionc_bin, "build", "--target", "wasm32", pion_pkg, "-o", wasm_bin], None, "pionc build --target wasm32 css_batch"),
        ]:
            rc, out, err, secs = run_cmd(cmd, cwd=cwd)
            if rc != 0:
                print(f"SETUP FAILED: {label} (rc={rc})\n{out[-1500:]}\n{err[-1500:]}", file=sys.stderr)
                return 2
            print(f"[css-corpus] setup ok  {label:<38s} ({secs:.2f}s)")

        # 3. Single batch binary execution per engine
        m_rc, m_out, m_err, m_s = run_cmd([args.moon_bin, "run", "--target", "wasm-gc", "src/controls"], cwd=moon_work)
        n_rc, n_out, n_err, n_s = run_cmd([native_bin])
        w_rc, w_out, w_err, w_s = run_cmd([args.pionc_bin, "run", "--target", "wasm32", pion_pkg])

        for label, rc, err in [("moon", m_rc, m_err), ("pion-native", n_rc, n_err), ("pion-wasm32", w_rc, w_err)]:
            if rc != 0:
                print(f"RUN FAILED: {label} exited {rc}\n{err[-1500:]}", file=sys.stderr)
                return 2

        print(f"[css-corpus] batch run timings: moon={m_s:.2f}s pion-native={n_s:.2f}s pion-wasm32={w_s:.2f}s")

        errs = compare_engine_outputs(strings, m_out, n_out, w_out)
        if errs:
            for e in errs:
                print(f"ERROR: {e}", file=sys.stderr)
            return 1

        print(
            f"[css-corpus] PASS: 100% 3-engine parity across {EXPECTED_CALLSITES} production callsites / "
            f"{EXPECTED_DISTINCT} distinct decoded CSS strings (32 fields x 8 patches + Double bits + AFirstLine fail-loud)"
        )

        # 4. Optional negative self-check: prove mutating 1 state field fails compare_engine_outputs!
        if args.verify_negative:
            mutated_nat = None
            for line in n_out.splitlines():
                if ";hovered={" in line:
                    mutated_nat = n_out.replace(line, line.replace(";hovered={", ";hovered={row=true,", 1), 1)
                    break
            assert mutated_nat is not None and mutated_nat != n_out, "expected at least one hovered state block in corpus"
            neg_errs = compare_engine_outputs(strings, m_out, mutated_nat, w_out)
            if not neg_errs:
                print("FAIL (neg-mutate-state): mutating 1 state field was NOT caught by compare_engine_outputs!", file=sys.stderr)
                return 1
            print(f"[css-corpus] PASS (neg-mutate-state): mutated hovered state field caught ({neg_errs[0][:120]})")

        return 0
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
