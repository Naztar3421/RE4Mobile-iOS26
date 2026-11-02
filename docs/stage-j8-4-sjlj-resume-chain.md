# Stage J.8.4 — SJLJ Resume Multi-Frame Chain Completion

**Target profile:** Res4 initializer #101, iOS 4.2.1 / 8C148 ARMv6  
**Parent stages:** J.6 SJLJ/personality model, J.7 cleanup-context reconstruction, J.8/J.8.1 synthetic context checks, J.8.2 context handoff, J.8.3 single-predecessor Resume completion  
**Local host validation:** 16/16 tests passed; J.8.3 regression remains 23/23

## Purpose

J.8.3 exercised cleanup completion when the private_2 handler was the immediate predecessor of the #101 cleanup frame. J.8.4 removes that test-shape restriction. It creates two intervening synthetic SJLJ frames and proves that the J.6 host phase-2 walker visits them in chain order, returns continueUnwind for each, and reaches only the frame named by private_2 as the handler.

The change reuses the existing J.6 state machine, J.7 context plan, and J.8.2 handoff. It does not change the pinned provider interpretation or claim that the synthetic frames reproduce every live stack shape.

## Synthetic chain

The test registers the following chain, oldest to newest:

1. Outer synthetic handler at 0x7000 (syntheticOuterHandler).
2. Outer intervening frame at 0x7200 (none).
3. Inner intervening frame at 0x7300 (none).
4. Res4 #101 ExtraProductList cleanup frame at 0x7100 (extraProductListCleanupOnly).

The TSD top begins at the #101 cleanup frame. The initial J.6 phase-2 traversal selects that cleanup frame and J.8.2 derives the J.7 handoff. The exception passed to the completion model has private_1 == 0 and private_2 == 0x7000.

## Normal Resume traversal

1. J.8.4 validates the J.6/J.7/J.8.2 field contract and confirms the selected cleanup frame remains the synthetic TSD top.
2. The host model records the audited cleanup completion value 0xFFFFFFFF in the synthetic selector word.
3. The pinned 32-bit GetIP arithmetic wraps 0xFFFFFFFF + 1 to zero. The cleanup frame remains TSD top until Resume is evaluated.
4. J.8.4 calls only RE4StageJ6SJLJStateMachine.resume, a host metadata/state model. J.6 revisits the cleanup frame, sees GetIP zero, and records continueUnwind.
5. J.6 visits 0x7300, then 0x7200; both are ordinary cleanup visits and both return continueUnwind.
6. J.6 reaches private_2 == 0x7000, assigns handlerCleanup, and the synthetic outer-handler stand-in returns INSTALL_CONTEXT metadata (row=0, index=0).
7. The selected handler frame becomes the synthetic TSD top. Its saved R7, SP, and continuation PC are checked against the returned install plan.

## Negative cases

The 16 host tests include:

- private_2 not present in the chain: phase 2 reaches end-of-stack; no handler is fabricated.
- private_2 pointing at a registered intermediate .none frame: phase 2 reports a fatal phase-2 result rather than treating it as a handler.
- Corrupted chain: a test-only fault-injection hook removes an intermediate synthetic frame record but leaves the predecessor link intact; J.6 reports the missing frame as corruptFrameChain.
- A mismatched J.8.2/J.7 frame contract is rejected before sentinel mutation.
- A forced Resume route (private_1 != 0) is rejected because J.8.4 covers only the normal route.

The corruption hook is explicitly named ForTesting and mutates only the host-side synthetic frame registry; it never touches Guest Memory or a live runtime frame. It is included in the app target only as inert test-support code and is not called by application flows.

## Test coverage

The 16 top-level tests cover:

1. Exact visit order: cleanup → inner intermediate → outer intermediate → handler.
2. Selector sentinel and GetIP wrap to zero.
3. TSD top retention before Resume.
4. continueUnwind for each intermediate frame.
5. Handler classification only at private_2.
6. Handler handlerCleanup / synthetic INSTALL_CONTEXT decision.
7. Install plan R7/SP/PC readback.
8. Final synthetic TSD top.
9. Retention of the completed cleanup record for audit.
10. All 19 nonzero #101 cleanup selectors, rows 2...20.
11. Handler not in chain.
12. Wrong handler address pointing to an intermediate frame.
13. Corrupted chain with a dangling predecessor.
14. Cross-stage handoff mismatch.
15. Forced route rejection.
16. Explicit no-execution/no-write/no-context-apply/no-transfer invariants.

tools/validate-stage-j8-4.sh compiles J.6/J.7/J.8.1/J.8.2/J.8.3/J.8.4 host sources with Swift and the RE4_HOST_TESTING define, using the same pinned LSDA, J.7 evidence, and crosswalk fixtures as the preceding stages.

## Scope and limits

The two intermediate frames and outer handler are synthetic host records. The model checks state and metadata transitions only; it does not prove live pthread TSD, stack lifetime, arbitrary personality behavior, or a real handler's context shape. J.8.4 does not cover forced unwind; that remains a separate future task.

No target __Unwind_SjLj_Resume, personality, unwinder, destructor, stop callback, pthread TSD operation, Guest instruction, Guest Memory write, CPU context application, or branch is executed.

**Stage J.8.4 host-only multi-frame Resume validation: PASS locally. GitHub Actions result pending. Guest Runtime remains NOT READY.**
