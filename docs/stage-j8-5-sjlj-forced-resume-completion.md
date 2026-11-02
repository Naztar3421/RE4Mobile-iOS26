# Stage J.8.5 — SJLJ Forced-Unwind Resume Completion

**Target profile:** Res4 initializer #101, iOS 4.2.1 / 8C148 ARMv6  
**Parent stages:** J.6 forced phase-2 model, J.7 cleanup-context reconstruction, J.8.2 handoff, J.8.3 normal Resume completion, J.8.4 multi-frame normal Resume  
**Local host validation:** 25/25 tests passed; production-mode Swift module compile passed

## Purpose

J.8.5 covers the forced-unwind branch of SJLJ Resume. It is intentionally separate from J.8.3/J.8.4 normal Resume:

- private_1 is the raw stop-function token and must be nonzero.
- private_2 is the opaque stop-function parameter. It is not a handler-frame address and may be zero.
- The forced stop callback is represented only by an explicit host closure supplied to the J.6 state machine.
- Every forced phase-2 frame visit uses the forced-cleanup action and invokes the synthetic stop closure with reason 10 before the frame's personality decision.

The raw stop-function token is carried through event metadata. No code resolves or calls that address.

## Synthetic stack and handoff

The fixture creates this oldest-to-newest chain:

1. A bottom synthetic outer-frame stand-in at 0x7000.
2. A second #101 ExtraProductList cleanup frame at 0x7400.
3. Ordinary synthetic frame at 0x7200.
4. Ordinary synthetic frame at 0x7300.
5. Current #101 ExtraProductList cleanup frame at 0x7600.

The initial forced phase-2 model starts at 0x7600. A host stop closure returns zero, so J.6 evaluates the #101 cleanup-only LSDA row and returns INSTALL_CONTEXT metadata. J.8.2 then creates the corresponding J.7 cleanup-context plan. The GR0 exception pointer is supplied separately from private_2; the stop parameter is not reused as an exception-object address.

## Forced Resume after cleanup completion

1. The selected #101 cleanup frame is still the synthetic TSD top after INSTALL_CONTEXT.
2. The model records the audited cleanup completion sentinel 0xFFFFFFFF in its synthetic selector word.
3. The pinned 32-bit GetIP arithmetic wraps the sentinel plus one to zero.
4. Resume reads private_1/private_2 as the forced stop token and opaque parameter, then calls only the J.6 host state machine with the supplied synthetic stop closure.
5. The completed cleanup frame is visited first again. Its callback result is recorded; GetIP zero makes its personality decision continue past the completed cleanup.
6. The two ordinary frames receive forced-cleanup actions, each receives the same stop token, parameter and reason 10, and each continues when the synthetic callback returns zero.
7. The next #101 cleanup frame is visited. Its callback runs before its personality decision. With a zero callback result and a valid selector, the cleanup-only personality produces a new forced INSTALL_CONTEXT plan and the model TSD top changes to that selected frame.

This represents one bounded forced-unwind continuation from one completed #101 cleanup to the next #101 cleanup. It does not claim that the entire forced unwind has completed.

## Stop callback result handling

The J.6 model treats any nonzero synthetic stop result as a fatal phase-2 result at that frame. J.8.5 makes this visible as stopCallbackRejected and verifies that no deeper frame or personality cleanup is processed after the rejection.

The test suite exercises rejection at the completed frame, an intermediate frame, and the next cleanup frame. Both positive and negative nonzero values are covered.

When there is no further #101 cleanup, ordinary synthetic frames may all continue and J.6 returns its modeled end-of-stack result. That result is only the host state-machine outcome; it is not a claim about actual process termination, actual TSD unlinking, or final runtime cleanup semantics.

## Test coverage

The 25 top-level tests cover:

1. Initial forced phase-2 selection and J.8.2/J.7 handoff.
2. Cleanup sentinel write and UInt32 GetIP wrap to zero.
3. TSD-top retention across the sentinel write.
4. Resume re-visiting the completed cleanup frame first.
5. Preservation of stop token, opaque parameter and reason 10.
6. Callback/frame visit order across completed cleanup, intermediate frames and next cleanup.
7. Forced-cleanup action and continueUnwind decisions for intermediate frames.
8. Next #101 forced INSTALL_CONTEXT selection.
9. Next cleanup plan R7/SP/PC agreement with its synthetic frame.
10. Confirmation that private_2 is not used as a handler-frame address.
11. Zero as a valid opaque stop parameter.
12–14. Stop callback rejection at the completed, intermediate and next-cleanup frames.
15. All 19 audited current-cleanup selector rows (2...20).
16. All 19 audited next-cleanup selector rows (2...20).
17. Modeled end-of-stack when only ordinary frames remain.
18–20. Missing host callback, normal-route private_1 value, and zero stop-token rejection before sentinel mutation.
21. Rejection of a normal-cleanup handoff on the forced route.
22. Corrupt synthetic frame-chain detection (host-test-only fault injection).
23. Out-of-profile next selector remains unresolved.
24. Negative nonzero stop callback return.
25. Explicit no-target-call/no-Guest-execution/no-write/no-context-apply/no-control-transfer scope.

The host test suite is compiled with RE4_HOST_TESTING. The model is also separately compiled without that define to verify the production-mode API surface.

## Scope and limits

The synthetic stop closure is not the target stop function. Callback event records and J.6 visits are host metadata. The bottom outer frame and both cleanup frames are synthetic records. The modeled end-of-stack result does not establish actual runtime termination.

No target stop-function pointer, __Unwind_SjLj_Resume, personality, unwinder, destructor, pthread TSD operation, Guest instruction, Guest Memory write, CPU context application, or branch is executed.

**Stage J.8.5 host-only forced Resume validation: PASS locally. GitHub Actions result pending. Guest Runtime remains NOT READY.**
