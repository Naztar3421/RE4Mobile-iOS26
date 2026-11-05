# Stage J.8.3 — SJLJ Resume Completion-State Model

**Target profile:** Res4 initializer #101, iOS 4.2.1 / 8C148 ARMv6  
**Parent stages:** J.6 SJLJ/personality, J.7 cleanup-context reconstruction, J.8/J.8.1 synthetic frame checks, J.8.2 SJLJ-to-context handoff  
**Local host validation:** 23/23 tests passed

## Purpose

J.8.3 closes the state-transition gap after the J.8.2 INSTALL_CONTEXT handoff. J.6 already models current-frame retention, the cleanup sentinel write, 32-bit GetIP arithmetic, and Resume's phase-2 walk. J.8.3 exercises those facts as one continuous host-side scenario using the J.8.2 handoff values.

The model also makes the normal completion path explicit so it cannot be confused with exceptional cleanup.

## Exceptional path: cleanup -> sentinel -> Resume

1. J.6 phase 2 selects the #101 ExtraProductList cleanup frame and returns INSTALL_CONTEXT metadata. The pinned provider's phase-2 path calls pthread_setspecific(key, currentFrame); the current frame remains TSD top.
2. The J.7/J.8.2 handoff identifies the same frame and carries the selected LSDA row, saved R7/SP/PC, and a caller-supplied GR0 exception pointer.
3. After the cleanup trampoline has completed its destructor work, the audited code at 0x560C writes 0xFFFFFFFF to frame+4. J.8.3 records this in the J.6 host state machine through markCleanupContinuationComplete; it does not run a destructor or write real memory.
4. The pinned GetIP helper is a 32-bit add of one. Therefore 0xFFFFFFFF + 1 wraps to 0, which J.6 interprets as a zero call-site index.
5. Resume re-enters phase 2 with private_1 == 0 (normal route) and private_2 identifying the predecessor handler frame. Phase 2 revisits the sentinel-marked cleanup frame, observes GetIP == 0, returns continueUnwind for that frame, and walks to the predecessor.
6. The test uses a synthetic outer-handler frame to make the continuation observable: phase 2 reaches that frame and returns its synthetic handler install plan. The J.6 model then places that selected outer frame at the synthetic TSD top.

The completed #101 frame remains present in the host model's registry with the sentinel value for audit. That registry retention is not a claim that the frame remains active on the runtime stack after phase 2 advances.

## Normal path: Unregister, not Resume

The original Res4 normal path branches around the cleanup trampoline at 0x55A4 toward 0x5614, then reaches __Unwind_SjLj_Unregister at 0x5618.

J.8.3 models this separately:

- TSD top moves directly from the completed frame to its predecessor.
- The original nonzero selector remains unchanged; GetIP remains the original dispatch index.
- No 0xFFFFFFFF sentinel is written.
- No exceptional Resume route is invoked.

The two paths are asserted to have distinct state signatures in the tests.

## Test coverage

The 23 top-level host tests cover:

- J.6 INSTALL_CONTEXT frame retention and agreement with the J.8.2 handoff/J.7 plan.
- The original selector, sentinel write, and UInt32.max wrapping to GetIP zero.
- TSD top remaining at #101 across the sentinel write and before Resume.
- Resume revisiting the completed frame first, treating it as continueUnwind, and reaching the immediate synthetic predecessor handler.
- The selected synthetic outer handler becoming the post-Resume TSD top.
- The original #101 record remaining inspectable in the host registry with its sentinel.
- Normal Unregister moving TSD top to the predecessor without changing the selector, and rejection of an exceptional completion mark after normal Unregister.
- Rejection of a forced-stop route, a wrong predecessor, a mismatched J.8.2/J.7 frame identity, a wrong TSD top, and a repeated Resume attempt.
- All 19 nonzero #101 cleanup selectors (rows 2...20) converging on sentinel/GetIP-zero behavior.
- Explicit no-control-transfer and zero-Guest-Memory-write invariants.

tools/validate-stage-j8-3.sh compiles the J.6, J.7, J.8.1, J.8.2 and J.8.3 source files with the host Swift compiler and uses the pinned J.6 LSDA and J.7 evidence fixtures.

## Scope and limitations

This is a host-side model of state and metadata only. The synthetic outer handler is a test stand-in, not a reconstructed application handler. The model only covers the audited ordinary cleanup Resume route where private_1 == 0; forced unwinding remains a separate J.6/J.8.2 path.

No real __Unwind_SjLj_Resume, destructor, __Unwind_SjLj_Unregister function pointer, personality, unwinder, pthread TSD, CPU context, BX, Guest instruction, or Guest Memory operation is executed. The test does not establish actual runtime stack lifetime, scheduler/thread behavior, or that every possible predecessor frame has the synthetic test shape.

**Stage J.8.3 host-only completion-state validation: PASS locally. GitHub Actions result pending. Guest Runtime remains NOT READY.**
