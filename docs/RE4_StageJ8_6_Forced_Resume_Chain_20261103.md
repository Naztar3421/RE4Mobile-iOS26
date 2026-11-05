# RE4 Stage J.8.6 — Forced Resume multi-cleanup chain

Date: 2026-11-03  
Baseline: Stage J.8.5, GitHub Actions run \`41498238621\` (\`success\`)  
Branch: \`feature/stage-i-d-lazy-prebind\`

## Objective

Extend the bounded Stage J.8.5 forced-Resume completion model from one cleanup-to-next-cleanup transition into a repeated chain. The new orchestration layer does not modify the existing J.6/J.7/J.8.2/J.8.5 models. Each newly selected #101 cleanup receives a fresh J.8.2/J.7 metadata handoff, then a subsequent J.8.5 completion cycle.

## Chain semantics

1. The caller supplies the first already-selected forced-cleanup handoff and an explicit exception-object pointer for the J.8.2 GR0 mapping.
2. J.8.5 records the current cleanup-completion sentinel (\`0xFFFFFFFF\`) in the synthetic frame model, verifies 32-bit \`GetIP\` wrap to zero, and runs the host J.6 forced-Resume traversal using only the supplied host stop closure.
3. If Resume selects another #101 cleanup with \`INSTALL_CONTEXT\`, J.8.6 validates the installed frame/TSD-top metadata and rebuilds a J.8.2/J.7 handoff for that exact frame.
4. The chain repeats until the model reports end-of-stack, a nonzero stop-callback result, an unresolved call-site index, a corrupt frame chain, or the explicit cleanup-frame cap.

\`private_1\` remains an opaque raw stop-function token and \`private_2\` remains the opaque callback parameter. The raw target function address is never invoked. The host callback receives the existing forced-unwind reason value \`10\`.

## Synthetic test topology

The primary fixture registers three cleanup-only #101 frames in oldest-to-newest order, separated by ordinary synthetic frames, above a synthetic bottom frame:

\`bottom -> cleanup-A -> ordinary-A -> cleanup-B -> ordinary-B -> cleanup-C (top)\`

The chain therefore tests three distinct cleanup completion cycles in newest-to-oldest order. It is not a trace from a live guest thread and does not assert that the real process has this exact stack topology.

## Local validation

\`tools/validate-stage-j8-6.sh\` performs both:

- Host synthetic tests with \`RE4_HOST_TESTING\` enabled.
- A production-surface Swift module compile without test-only APIs.

Results on the local validation environment:

- 8/8 Stage J.8.6 tests passed.
- Release-mode model compile passed.

Coverage includes repeated three-cleanup completion, per-cycle frame visitation order, stable stop-token/parameter/reason values, stop-callback rejection, unresolved selector handling, cleanup-limit termination, sentinel retention, and explicit no-Guest-execution invariants.

## TSD top interpretation

At modeled end-of-stack, the current J.6 host state machine leaves its TSD-top metadata at the most recently installed cleanup frame. J.8.6 reports that model value faithfully; it does **not** rewrite it to zero or claim that the real pthread TSD key has been cleared. A later provider/runtime audit must establish the actual target behavior before making such a claim.

## Scope and non-claims

This stage is still a host-side metadata/state model. It does not execute or invoke:

- the target stop callback or \`__Unwind_SjLj_Resume\`;
- the target personality, landing pad, destructor, or SJLJ unwinder;
- pthread TSD or real stack-frame memory;
- ARM/Thumb guest instructions;
- Guest Memory writes or CPU context restoration;
- BX/control transfer or a Res4 initializer.

Consequently, J.8.6 completion and CI success do not establish Guest Runtime readiness. Overall Runtime readiness remains **NOT READY TO ENTER**.

## Files

- \`RE4MCTPreview/RE4StageJ86ForcedResumeChainModel.swift\`
- \`RE4MCTPreview/RE4StageJ86ForcedResumeChainTests.swift\`
- \`tools/test-stage-j8-6.swift\`
- \`tools/validate-stage-j8-6.sh\`
