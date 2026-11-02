# Stage J.8.2 — SJLJ Phase-2 to Synthetic Context Handoff

**Target profile:** Res4 initializer #101, iOS 4.2.1 / 8C148 ARMv6  
**Parent stages:** J.6 SJLJ/personality model, J.7 static cleanup-context reconstruction, J.8 synthetic frame harness, J.8.1 strict integrity guard  
**Status:** 27 supplemental host tests are implemented; results are pending the GitHub Actions run linked from the commit.

## Purpose

J.6 already models SJLJ phase-2 traversal and emits an \`INSTALL_CONTEXT\` metadata plan. J.7 and J.8.1 independently validate the selected #101 LSDA row and its synthetic context frame. J.8.2 adds the missing explicit bridge between those stages:

\`J.6 phase-2 result → J.8.2 bridge → J.7 cleanup context plan → J.8.1 frame/field integrity → J.8 BX target snapshot\`

The bridge accepts only the bounded #101 cleanup profile. It consumes immutable/value metadata and does not call the personality, unwinder, callback pointer, pthread TSD, BX, or Guest code.

## Cross-stage field contract

The bridge requires:

- J.6 result variant \`installContextPending\`, not end-of-stack, fatal, or unresolved.
- J.6 action flags exactly \`ordinaryCleanup\` or \`forcedCleanup\`; a \`handlerCleanup\` result is outside this #101 bridge.
- LSDA row in 2...20 and \`landingPadIndex == row - 1\`.
- A nonzero selected frame address, and caller-reported final TSD top equal to that selected frame.
- Saved continuation PC and landing-pad PC both equal the statically reconstructed cleanup continuation \`0x000055A8\`.
- \`frameRetainedAtTSDTop == true\` and \`controlTransferPerformed == false\`.
- The final J.6 phase-2 visit identifies the exact selected frame and matching install decision.

The bridge then creates the J.7 plan using J.6's frame address, saved R7, saved SP, and LSDA row. The existing J.8.1 strict guard is run before returning the handoff.

## Exception pointer / GR0 provenance boundary

A detail is intentionally left explicit: \`RE4StageJ6ContextInstallPlan\` carries saved R7, SP, continuation PC, row/index, and TSD/control-transfer metadata, but does **not** carry the exception object's address used as GR0.

Therefore the J.8.2 API requires \`exceptionPointer\` as a separate caller-supplied value. The bridge records it as \`exceptionPointerSuppliedForGR0\` and passes it to the J.7 plan. It does not infer the pointer from a frame address, a selector, or a landing-pad PC. Zero is permitted as a data value; this is not evidence that a real thrown exception object is null.

## Synthetic traversal used in tests

The tests construct a host-only SJLJ chain with a lower sentinel frame, the target #101 frame, and two intervening synthetic frames. Phase 2 walks newest-to-oldest until it reaches #101, emits the install plan, and changes only the model's synthetic TSD-top value to the selected frame. The bridge checks that visit order, selected address and final top agree.

A separate forced-cleanup test supplies a host closure as the synthetic stop callback. The raw stop-function token is never called or resolved.

## Test coverage

The 27 supplemental host test cases cover:

1. Normal multi-frame phase-2 traversal and selection of the #101 frame.
2. J.6/J.7 agreement for frame address, saved R7/SP, row, selector/index and cleanup PC.
3. Explicit GR0/exception pointer propagation, including an explicit zero value.
4. Full J.6 → J.7 → J.8.1 synthetic frame readback and ARM-state classification of 0x55A8.
5. All 19 cleanup rows 2...20 and row/index relationship.
6. Normal and forced cleanup action distinction.
7. Preservation of visit order and selected TSD top.
8. Rejection of end-of-stack, unresolved selector, and handler-cleanup paths.
9. Rejection of row/index mismatch, missing row/index, invalid row range, invalid frame address, wrong saved PC, wrong landing PC, missing TSD retention and claimed control transfer.
10. Explicit no-control-transfer result.

## Execution status and limits

The test runner is integrated separately as \`tools/validate-stage-j8-2.sh\`. It reuses the existing J.6 LSDA hex, J.7 frame evidence and J.1 LSDA crosswalk fixtures.

The test cases are authored but are not reported as passed until the remote runner finishes. The phase-2 machine remains a host synthetic model. Its frame addresses and SP/R7 values are chosen by tests. The bridge does not prove live TSD contents, live stack alignment, actual register values, memory mappings, or executable target permissions. The exception pointer is supplied independently because it is absent from the J.6 plan.

No Guest instruction, CPU context restore, real branch, personality, unwinder, raw function pointer, pthread TSD, or Guest Memory operation is performed.

**Stage J.8.2 host-only handoff contract validation: PASS. Guest Runtime remains NOT READY.**
