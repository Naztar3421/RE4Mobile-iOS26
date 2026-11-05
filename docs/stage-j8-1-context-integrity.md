# Stage J.8.1 — Synthetic Context Field Integrity and Fault Injection

**Target profile:** Res4 initializer #101, iOS 4.2.1 / 8C148 ARMv6  
**Parent:** Stage J.7 static landing-pad/context reconstruction and Stage J.8 synthetic restore harness  
**Result:** 24/24 supplemental host tests passed; combined J.8 + J.8.1 suite = 50 top-level tests passed.

## Purpose

J.8.1 adds a strict host-side integrity layer around the existing J.8 harness. It verifies exact plan-to-byte-array round trips, rejects inconsistent J.7 plans before frame construction, and injects corruption into every defined frame word. It does not add a guest CPU, context switch, instruction execution, or Guest Memory access.

## Known frame fields

The bounded synthetic frame is \`0x2C\` bytes. J.7's source-backed fields used by this harness are:

| Offset | Meaning | Strict validation |
|---:|---|---|
| \`+0x04\` | SetIP dispatch-index minus one / selector token | expected-value match; allowed cleanup selector \`1...19\` |
| \`+0x08\` | GR0 exception pointer | exact round-trip against the plan; no invented nonzero constraint |
| \`+0x0C\` | GR1 | exact round-trip; must be zero for the audited zero-action profile |
| \`+0x1C\` | LSDA pointer | expected-value match and exact pinned value \`0x001C0996\` |
| \`+0x20\` | saved R7 | exact round-trip against the plan |
| \`+0x24\` | saved continuation PC | expected-value match and exact cleanup continuation \`0x55A8\` |
| \`+0x28\` | saved SP | exact round-trip; 8-byte alignment checked by the J.8 harness |

The unassigned byte ranges \`+0x00...+0x03\` and \`+0x10...+0x1B\` remain opaque. J.8.1 verifies that writing the known slots does not modify those bytes; it does not guess or name fields that the J.7 evidence does not establish.

## Cross-stage plan validation

Before the J.8 builder creates the frame, the J.8.1 guard checks the invariants carried by the J.7 plan: initializer and LSDA identity, frame-base offset, cleanup rows 2...20, row/selector/dispatch-index/cleanup-count relationship, SetGR and SetIP offsets and arithmetic, zero-action GR1, saved continuation 0x55A8, personality return code 7, current-frame TSD retention, cleanup's GR0 use, Resume exception argument, 0xFFFFFFFF sentinel, GetIP wrap to zero, and the no-control-transfer invariant.

Mutated copies of the J.7 plan are rejected before the synthetic frame is materialized.

## Fault-injection and boundary tests

The 24 supplemental tests cover:

1. Full round-trip of all seven defined frame words.
2. Little-endian byte order using the 0x12345678 pattern.
3. One-bit corruption at each of the seven defined frame slots, with field-specific mismatch errors; the frame base is checked separately.
4. Semantic rejection of selector values outside 1...19, nonzero GR1, wrong LSDA, and incorrect saved continuation PCs, including an in-range PC and a Thumb-tagged PC.
5. Preservation of opaque/unmodeled frame bytes.
6. 32-bit frame address span arithmetic: an exclusive end equal to 0x1_0000_0000 is accepted; a span that wraps is rejected.
7. Negative, misaligned, out-of-range and extreme word offsets for frame reads/writes.
8. Mutated J.7 frame offsets, SetIP arithmetic, target identity, personality result, Resume/TSD relationships and control-transfer flags.
9. All 19 cleanup selectors converging to 0x55A8 / ARM state through synthetic readback.
10. Explicit no-Guest-execution, no-Guest-Memory-write, no-CPU-context-apply and no-control-transfer snapshot flags.

The original \`tools/validate-stage-j8.sh\` runs the original 26 tests. The new \`tools/validate-stage-j8-1.sh\` runs 24 additional tests. Both are host Swift tests and use the same pinned J.7 evidence/crosswalk CSV fixtures.

## Results

- Original Stage J.8: **26/26 passed**.
- Supplemental Stage J.8.1: **24/24 passed**.
- Combined total: **50/50 top-level host tests passed**.

## Limits

The strict snapshot is a data-integrity comparison against a J.7 plan, not proof of a live CPU restore. Synthetic SP and code-range values do not prove the actual iPhone stack alignment or real executable mappings. Opaque bytes stay uninterpreted. No ARM/Thumb instruction, BX, cleanup trampoline, personality, SJLJ provider routine, callback, unwinder, pthread TSD operation, or Guest Memory access/write is performed.

**Stage J.8.1 host-only integrity validation: PASS. Guest Runtime remains NOT READY.**
