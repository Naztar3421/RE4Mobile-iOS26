# Stage J.9 — SJLJ Integration Readiness Review

**Target:** Res4 / iOS 4.2.1 / build 8C148 / ARMv6; bounded to ExtraProductList initializer #101.  
**Reviewed HEAD:** 6a3f4ffb0048fec034f46e49e7e3483267d64be6  
**Integrated CI:** [Run #41498238621](https://github.com/Naztar3421/RE4Mobile-iOS26/actions/runs/41498238621) — SUCCESS.

## Decision

| Gate | Status |
|---|---|
| #101 static profile and context evidence | PASS WITH RECORDED CROSSWALK LIMIT |
| #101 host-model integration | PASS |
| Executable target SJLJ runtime | BLOCKED |
| Global Guest Runtime entry | NOT READY |

J.6 through J.8.5 connect the bounded #101 static evidence to host models of phase traversal, context planning, normal completion, and forced completion. They close the analysis/model handoff gap. They do not demonstrate an executable target runtime.

## Static evidence established

- Personality: ___gxx_personality_sj0 in libstdc++.6.dylib at 0x374EF9F8.
- Function: ExtraProductList at 0x5188. LSDA: 0x001C0996.
- LSDA: FF FF 03 header, 0x28-byte call-site table, 20 rows, selector/index 0...19 and zero action offsets.
- Crosswalk: 19 distinct table rows matched, 20 code-site correlations; row 1 unmatched, row 2 shared by two code sites (0x555C and 0x5588).
- Cleanup continuation: 0x55A8, recovered from the saved frame continuation field at +0x24.
- The pinned provider's INSTALL_CONTEXT path retains the current frame as TSD top before restoring the saved context. The static Res4 cleanup path writes 0xFFFFFFFF at 0x560C and calls Resume at 0x5610; the normal path reaches Unregister at 0x5618.

These are read-only static facts, not observations of a running game.

## Host-model evidence

| Stage | Scope | Result |
|---|---|---:|
| J.6 | LSDA/personality and SJLJ phase models | 20/20 |
| J.7 | #101 frame/context reconstruction | 26/26 |
| J.8 | Synthetic frame and target-state arithmetic | 26/26 |
| J.8.1 | Context integrity supplement | 24/24 |
| J.8.2 | Phase-to-context bridge | 27/27 |
| J.8.3 | Normal Resume completion and Unregister distinction | 23/23 |
| J.8.4 | Multi-frame normal Resume | 16/16 |
| J.8.5 | Forced Resume completion | 25/25 |

The counts remain per-suite; do not add them into a unique aggregate because the suites overlap in purpose and fixtures.

Run #41498238621 passed every J.6–J.8.5 validation step, the unsigned app build, IPA packaging and artifact upload. This certifies host tests and compilation/package only.

## What remains blocked

1. **Target personality and unwinder:** provider addresses are statically identified, but target personality and _Unwind_SjLj_* routines are not called.
2. **Live frame chain and pthread TSD:** frame addresses and TSD top are host synthetic state; no live thread-local storage is read or written.
3. **Real handler and exception object:** J.8.3/J.8.4 use a synthetic outer handler. The real application handler/catch semantics and live exception-object provenance are not established.
4. **Cleanup execution:** the wide-string cleanup path is statically audited; no destructor is run.
5. **Forced stop callback:** J.8.5 uses a supplied host closure. The raw target stop-function token is never resolved or invoked.
6. **CPU context transfer:** J.8/J.8.1 inspect synthetic frame bytes and address/state arithmetic. They do not update a CPU register file, change execution state, fetch instructions or branch.
7. **General exception support:** the model covers only the #101 cleanup-only zero-action LSDA. Typed catches, action chains and arbitrary personality profiles remain unsupported.
8. **Whole-program startup:** #101 evidence does not execute the 240 initializers or complete dyld, C++ or Objective-C/process lifecycle requirements.

The sentence above describes the original J.9 baseline and is superseded by the later bounded Core work: J.8.13 added a limited Thumb-1 fetch/decode path, J.8.14 added actual in-Core register BX/BLX interworking, and the J.8.11 mode-aware transaction is now implemented on the feature branch. These are bounded interpreter capabilities only; they do not implement a complete CPSR, execute the original provider's BX, or close the callable-provider/TSD/personality dependencies. J.8.11 CI validation is pending.

## Gate policy

- SJLJ_STATIC_PROFILE_GATE = PASS_WITH_RECORDED_CROSSWALK_LIMIT
- SJLJ_HOST_MODEL_GATE = PASS
- SJLJ_EXECUTABLE_RUNTIME_GATE = BLOCKED
- GUEST_RUNTIME_ENTRY_GATE = NOT_READY

## Next prerequisites

Before reconsidering executable SJLJ readiness, separately establish: (1) callable provider/import closure, including ARM/Thumb support; (2) live per-thread SJLJ registration and TSD semantics; (3) exception-object, stop-callback and destructor contracts; (4) CPU context representation and transfer prerequisites; and (5) integration with relocation/import readiness and ordered application startup.

These are evidence prerequisites, not permission to execute Guest code.

**J.9 conclusion:** The bounded #101 static and host-model gap is closed. Executable SJLJ remains BLOCKED. Global Guest Runtime remains NOT READY.


## J.8.7–J.8.10 adapter-design checkpoint (2026-11-03)

The subsequent provider audits and host models extend the earlier J.9 review:

- J.8.7: six-argument AAPCS32 stop callback ABI, callback identity ledger and provider TSD rules.
- J.8.8: per-thread TSD lifecycle, distinguishing provider end-of-stack return from the caller's later Unregister.
- J.8.9: #101 stack/frame relations, provider R7/SP/PC loads and target epilogue responsibilities.
- J.8.10: immutable Guest CPU successor-state projection for the forced InstallContext tail. It accounts for the raw continuation value remaining in R0, changes the planned R7/SP/PC/T state, preserves the currently modelled N/Z/C/V flags, and checks that provider R4 identifies the selected frame.

J.8.10 remains a data-only adapter contract: it does not mutate the core or execute BX. The current core still lacks Thumb fetch/decode/state, an atomic architectural-state snapshot/commit API, full CPSR representation, and actual VFP D8–D15 stack payload transfers (its legacy VFP push/pop handlers currently adjust SP only). These are executable-runtime blockers.

The J.8.10 local regression suite reports 13/13 and Release-mode compile PASS. The validator is chained after J.8.9. This does not change the gate decision: SJLJ executable runtime remains BLOCKED and global Guest Runtime remains NOT READY.
