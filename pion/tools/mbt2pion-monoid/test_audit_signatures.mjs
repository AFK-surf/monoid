#!/usr/bin/env node
// Unit tests for audit_signatures.mjs:
//   - Strict scalar Int32 <-> Int normalization (preserving UInt/Int64/containers/scope)
//   - Parameter-rename rule validator (rejecting type/optionality/default mismatches like w? : Len -> weight? : Weight)
//   - Dynamic AFirstLine scan separation (definition vs controls callsites vs app callsites)
//   - Temporary @ui.css / @ui.css_read drift ledger registration

import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {
  normalizeTypeForCompare,
  typesCompatible,
  parseFnSig,
  validateParamRenameRule,
  scanAFirstLine,
} from './audit_signatures.mjs';

const SCRIPT_DIR = path.dirname(new URL(import.meta.url).pathname);
const REPO_ROOT = path.resolve(SCRIPT_DIR, '../../..');

// 1. Strict Int32 <-> Int scalar synonym normalization
assert.equal(normalizeTypeForCompare('Int32'), 'Int');
assert.equal(normalizeTypeForCompare('Int'), 'Int');
assert.equal(normalizeTypeForCompare('Array[Int32]'), 'Array[Int]');
assert.equal(normalizeTypeForCompare('Array[(String, String, Int32)]'), 'Array[(String,String,Int)]');
assert.equal(normalizeTypeForCompare('() -> Int32'), '()->Int');
assert.equal(normalizeTypeForCompare('Int32?'), 'Option[Int]');
assert.equal(normalizeTypeForCompare('Map[String, Int32]'), 'Map[String,Int]');
assert.equal(typesCompatible('Int32', 'Int', 'x', false), true);
assert.equal(typesCompatible('Array[Int32]', 'Array[Int]', 'xs', false), true);

// Must preserve signedness, bit-width, containers, and scoped/user-defined names
assert.equal(normalizeTypeForCompare('UInt'), 'UInt');
assert.equal(normalizeTypeForCompare('UInt32'), 'UInt32');
assert.equal(normalizeTypeForCompare('Int64'), 'Int64');
assert.equal(normalizeTypeForCompare('UInt64'), 'UInt64');
assert.equal(normalizeTypeForCompare('MyInt32'), 'MyInt32');
assert.equal(normalizeTypeForCompare('Int32Array'), 'Int32Array');
assert.equal(normalizeTypeForCompare('foo::Int32'), 'Int32');
assert.equal(normalizeTypeForCompare('@foo.Int32'), 'Int32');
assert.equal(typesCompatible('UInt', 'Int', 'x', false), false);
assert.equal(typesCompatible('UInt32', 'Int', 'x', false), false);
assert.equal(typesCompatible('Int64', 'Int', 'x', false), false);
assert.equal(typesCompatible('foo::Int32', 'Int', 'x', false), false);
assert.equal(typesCompatible('@foo.Int32', 'Int', 'x', false), false);
assert.equal(typesCompatible('Array[Int32]', 'Option[Int]', 'x', false), false);

// 2. Parameter-rename validator: reject type, optionality, or default mismatches
const mbtiTextStyle = parseFnSig(
  'pub fn text_style(size? : TextSize, weight? : Weight, color? : Color, w? : Len, center? : Bool, balance? : Bool) -> TextStyle'
);
const invarTextStyle = parseFnSig(
  'fn text_style(size?: TextSize, weight?: Weight, color?: Color) -> TextStyle'
);
assert.throws(
  () => validateParamRenameRule({ from: 'w', to: 'weight' }, mbtiTextStyle, invarTextStyle),
  /type mismatch/
);

const fnSrcOpt = parseFnSig('pub fn demo(a? : Int32, b~ : Bool = false, c? : @one.Int32) -> Unit');
const fnDstMismatchOpt = parseFnSig('fn demo(a_new~ : Int, b_new~ : Bool = false) -> Unit');
const fnDstMismatchDefault = parseFnSig('fn demo(a_new? : Int, b_new~ : Bool) -> Unit');
const fnDstMismatchDefaultVal = parseFnSig('fn demo(a_new? : Int, b_new~ : Bool = true) -> Unit');
const fnDstMismatchScope = parseFnSig('fn demo(c_new? : two::Int32) -> Unit');
const fnDstValid = parseFnSig('fn demo(a_new? : Int, b_new~ : Bool = false) -> Unit');

assert.throws(
  () => validateParamRenameRule({ from: 'a', to: 'a_new' }, fnSrcOpt, fnDstMismatchOpt),
  /optionality mismatch/
);
assert.throws(
  () => validateParamRenameRule({ from: 'b', to: 'b_new' }, fnSrcOpt, fnDstMismatchDefault),
  /default-value mismatch/
);
assert.throws(
  () => validateParamRenameRule({ from: 'b', to: 'b_new' }, fnSrcOpt, fnDstMismatchDefaultVal),
  /default-value expression mismatch/
);
assert.throws(
  () => validateParamRenameRule({ from: 'c', to: 'c_new' }, fnSrcOpt, fnDstMismatchScope),
  /type mismatch/
);
assert.equal(validateParamRenameRule({ from: 'a', to: 'a_new' }, fnSrcOpt, fnDstValid), true);
assert.equal(validateParamRenameRule({ from: 'b', to: 'b_new' }, fnSrcOpt, fnDstValid), true);

// 3. Dynamic AFirstLine scan separation
const af = scanAFirstLine(REPO_ROOT);
assert.ok(af.definition_locations.length >= 1, 'expected AFirstLine definitions in libs/ui/src/ui');
assert.ok(af.definition_locations.every(l => l.startsWith('libs/ui/src/ui/')));
assert.ok(af.controls_callsites.length >= 1, 'expected AFirstLine callsites in libs/ui/src/controls');
assert.ok(af.controls_callsites.every(l => l.startsWith('libs/ui/src/controls/')));
assert.ok(af.app_callsites.length >= 1, 'expected AFirstLine callsites in apps/mbui/src');
assert.ok(af.app_callsites.every(l => l.startsWith('apps/mbui/src/')));

// 4. Verify generated api_map.json, m1_invar_blockers.json, drift_ledger.json
const apiMap = JSON.parse(fs.readFileSync(path.join(SCRIPT_DIR, 'api_map.json'), 'utf8'));
const blockers = JSON.parse(fs.readFileSync(path.join(SCRIPT_DIR, 'm1_invar_blockers.json'), 'utf8'));
const drift = JSON.parse(fs.readFileSync(path.join(SCRIPT_DIR, 'drift_ledger.json'), 'utf8'));

const tempCss = (apiMap.drift_ledger || []).find(x => x.source === '@ui.css');
assert.ok(tempCss && tempCss.temporary_target === 'sf::css');
assert.ok(tempCss.removal_condition.includes('delete sf/src/style_css.pion in the exact commit Invar Wave P0-2 Track 2A ui::css lands'));
assert.ok((drift.temporary_mappings || []).some(x => x.source === '@ui.css_read' && x.temporary_target === 'sf::css_read'));

const textStyleBlocker = blockers.strict_invar_blockers.find(b => b.source === '@ui.text_style');
assert.ok(textStyleBlocker, 'expected @ui.text_style Layer 2 blocker');
assert.ok(textStyleBlocker.missing_params.some(p => p.startsWith('w?')));
assert.ok(textStyleBlocker.missing_params.some(p => p.startsWith('center?')));
assert.ok(textStyleBlocker.missing_params.some(p => p.startsWith('balance?')));

const afBlocker = blockers.strict_invar_blockers.find(b => b.source === '@ui.Align::AFirstLine');
assert.ok(afBlocker && Array.isArray(afBlocker.definition_locations) && Array.isArray(afBlocker.controls_callsites) && Array.isArray(afBlocker.app_callsites));
assert.equal(afBlocker.call_count, afBlocker.controls_callsites.length + afBlocker.app_callsites.length);

console.log('OK: all audit_signatures.mjs unit tests passed');
