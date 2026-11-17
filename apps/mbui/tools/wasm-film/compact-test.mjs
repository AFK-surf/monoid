// Validate the loader's local reuse against actual Wasm execution through branches and loop back-edges.
import assert from 'node:assert/strict';
import { compactStart, hasStartSection } from './compact.mjs';
const u = value => { const a = []; do { let c = value & 127; value >>>= 7; if (value) c |= 128; a.push(c); } while (value); return a; };
const str = value => [...u(Buffer.byteLength(value)), ...Buffer.from(value)];
const section = (id, body) => [id, ...u(body.length), ...body];
const body = code => [...u(code.length), ...code];
const code = [
  1, 9, 0x7f,                         // nine i32 locals
  0x41, 7, 0x21, 0,                  // local 0 is live across the branches
  0x41, 42, 0x21, 1, 0x20, 1, 0x1a,
  0x10, 0, 0x04, 0x40,               // if choose()
    0x41, 5, 0x21, 2,
    0x20, 2, 0x41, 1, 0x6a, 0x21, 3,
    0x20, 3, 0x24, 0,
  0x05,
    0x41, 9, 0x21, 4,
    0x20, 4, 0x24, 0,
  0x0b,
  0x20, 0, 0x23, 0, 0x6a, 0x24, 0,
  0x20, 5, 0x23, 0, 0x6a, 0x24, 0, // local 5 must retain its initial zero
  0x10, 0, 0x04, 0x40,
    0x41, 8, 0x21, 6,                // a write skipped when choose() is false
  0x0b,
  0x20, 6, 0x23, 0, 0x6a, 0x24, 0,
  0x41, 3, 0x21, 7,
  0x41, 0, 0x21, 8,
  0x02, 0x40, 0x03, 0x40,           // sum 3 + 2 + 1 across loop iterations
    0x20, 7, 0x45, 0x0d, 1,
    0x20, 8, 0x20, 7, 0x6a, 0x21, 8,
    0x20, 7, 0x41, 1, 0x6b, 0x21, 7,
    0x0c, 0,
  0x0b, 0x0b,
  0x20, 8, 0x23, 0, 0x6a, 0x24, 0,
  0x0b,
];
const getter = [0, 0x23, 0, 0x0b];
const fixture = Buffer.from([
  0, 97, 115, 109, 1, 0, 0, 0,
  ...section(1, [2, 0x60, 0, 0, 0x60, 0, 1, 0x7f]),
  ...section(2, [1, ...str('env'), ...str('choose'), 0, 1]),
  ...section(3, [2, 0, 1]),
  ...section(6, [1, 0x7f, 1, 0x41, 0, 0x0b]),
  ...section(7, [1, ...str('result'), 0, 2]),
  ...section(8, [1]),
  ...section(10, [2, ...body(code), ...body(getter)]),
]);
assert(WebAssembly.validate(fixture));
const compacted = compactStart(fixture);
assert(WebAssembly.validate(compacted));
for (const [choice, expected] of [[0, 22], [1, 27]]) {
  const imports = { env: { choose: () => choice } };
  const before = new WebAssembly.Instance(new WebAssembly.Module(fixture), imports).exports.result();
  const after = new WebAssembly.Instance(new WebAssembly.Module(compacted), imports).exports.result();
  assert.equal(before, expected);
  assert.equal(after, expected);
}
assert.throws(() => compactStart(Buffer.from([0, 97, 115, 109, 1, 0, 0, 0])), /no local start/);
assert.throws(() => compactStart(Buffer.from([0, 97, 115])), /not a classic Wasm module/);
const simd = Buffer.from([
  0, 97, 115, 109, 1, 0, 0, 0,
  ...section(1, [1, 0x60, 0, 0]), ...section(3, [1, 0]), ...section(8, [0]),
  ...section(10, [1, ...body([0, 0xfd, 0x0c, ...Array(16).fill(0), 0x1a, 0x0b])]),
]);
assert(WebAssembly.validate(simd));
assert.throws(() => compactStart(simd), /unsupported Wasm instruction fd/);
// Past V8's 50,000-local per-function cap, raw source fails V8 validation until compactStart folds non-overlapping slots.
const overV8CapOps = [];
for (let i = 0; i < 50_005; i++) overV8CapOps.push(0x41, 1, 0x21, ...u(i));
overV8CapOps.push(0x20, ...u(0), 0x20, ...u(50_004), 0x6a, 0x24, 0, 0x0b);
const overV8Cap = Buffer.from([
  0, 97, 115, 109, 1, 0, 0, 0,
  ...section(1, [2, 0x60, 0, 0, 0x60, 0, 1, 0x7f]),
  ...section(3, [2, 0, 1]),
  ...section(6, [1, 0x7f, 1, 0x41, 0, 0x0b]),
  ...section(7, [1, ...str('result'), 0, 1]),
  ...section(8, [0]),
  ...section(10, [2, ...body([1, ...u(50_005), 0x7f, ...overV8CapOps]), ...body(getter)]),
]);
assert.equal(WebAssembly.validate(overV8Cap), false);
const compactedOverCap = compactStart(overV8Cap);
assert(WebAssembly.validate(compactedOverCap));
assert.equal(new WebAssembly.Instance(new WebAssembly.Module(compactedOverCap)).exports.result(), 2);
assert(hasStartSection(overV8Cap));
// moonc v0.10.21 (moon 0.1.20261117): no start section; `_start` exported, no locals of its own, guarding against a
// second run, then calling the initializer (past V8's cap) and an empty `main`. The initializer is what is compacted.
const wrapper = [0, 0x23, 1, 0x04, 0x40, 0x00, 0x0b, 0x41, 1, 0x24, 1, 0x10, 1, 0x10, 2, 0x0b];
const exportedStart = Buffer.from([
  0, 97, 115, 109, 1, 0, 0, 0,
  ...section(1, [2, 0x60, 0, 0, 0x60, 0, 1, 0x7f]),
  ...section(3, [4, 0, 0, 0, 1]),
  ...section(6, [2, 0x7f, 1, 0x41, 0, 0x0b, 0x7f, 1, 0x41, 0, 0x0b]),
  ...section(7, [2, ...str('result'), 0, 3, ...str('_start'), 0, 0]),
  ...section(10, [4, ...body(wrapper), ...body([1, ...u(50_005), 0x7f, ...overV8CapOps]), ...body([0, 0x0b]),
    ...body(getter)]),
]);
assert.equal(hasStartSection(exportedStart), false);
assert.equal(WebAssembly.validate(exportedStart), false);
const compactedExported = compactStart(exportedStart);
assert(WebAssembly.validate(compactedExported));
const started = new WebAssembly.Instance(new WebAssembly.Module(compactedExported)).exports;
assert.equal(started.result(), 0);
started._start();
assert.equal(started.result(), 2);
assert.throws(() => started._start(), WebAssembly.RuntimeError);
// `_start` that calls only an import has no local initializer: fail closed.
const importOnly = Buffer.from([
  0, 97, 115, 109, 1, 0, 0, 0,
  ...section(1, [1, 0x60, 0, 0]),
  ...section(2, [1, ...str('env'), ...str('init'), 0, 0]),
  ...section(3, [1, 0]),
  ...section(7, [1, ...str('_start'), 0, 1]),
  ...section(10, [1, ...body([0, 0x10, 0, 0x0b])]),
]);
assert(WebAssembly.validate(importOnly));
assert.throws(() => compactStart(importOnly), /no local start/);
console.log('compact-test: branch paths, initial zeroes, >50k start locals and loop-carried values preserved; the initializer an exported _start calls compacted; unsupported instructions rejected');
