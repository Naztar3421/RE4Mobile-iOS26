# RE4 Stage J.8.8 — Complete SJLJ pthread TSD lifecycle

Date: 2026-11-03
Baseline: J.8.7 actual-provider audit and host model
Branch: feature/stage-i-d-lazy-prebind

## Objective

Join Register, forced Resume, InstallContext, end-of-stack return, and the Res4 #101 caller-side Unregister into one explicit transition trace. The model separates the process-wide key from each thread's TSD value and records the provider boundary independently from caller continuation.

## Provider-derived transition rules

1. Key creation is process-wide. The pinned provider's MakeTopOfFunctionStackKey passes a null destructor to pthread_key_create.
2. Register reads the current thread's value with pthread_getspecific, writes it to frame+0 as frame->prev, then publishes the new frame with pthread_setspecific.
3. Forced Resume obtains that thread's top and follows frame->prev newest-to-oldest. Traversing a frame does not itself publish each predecessor as the TSD top.
4. InstallContext publishes the selected frame as the new TSD top, restores the selected frame's R7/SP/PC and branches with BX. That transfer does not return to the old Resume caller's following instruction.
5. If phase 2 reaches end-of-stack, the provider returns reason 5 without clearing the key. Res4 #101 then continues at its instruction after Resume and calls Unregister, which publishes the supplied frame's predecessor.
6. Unregister mirrors the machine code literally: it reads the caller-supplied frame->prev and writes it to the key. It does not search the chain or validate that the supplied frame is currently top.

## Model boundaries

The key is represented once, but top/frame collections are separated by thread ID. A lifecycle snapshot contains the initial top, visit order, provider result, top at the provider return/InstallContext boundary, whether Resume returned to its call site, whether caller Unregister ran, and the final modeled top.

The model intentionally does not delete a frame record after Unregister; this preserves inspectable evidence and does not assert a native allocation lifetime. It does not simulate pthread thread teardown, key destruction, scheduler changes, or real callback invocation.

## Tests and validation

- 8/8 host-only regression tests cover one-time key creation with null destructor, per-thread isolation, Register linkage, EOS retention, the #101 Resume-then-Unregister continuation, InstallContext non-returning transfer, literal frame->prev Unregister semantics, and forced newest-to-oldest traversal.
- Release-mode Swift module compile is part of the validator.
- The validator chains into J.8.9 so the CI path covers the complete TSD lifecycle followed by restore preconditions.

No pthread function, provider code, callback, guest instruction, Guest Memory write, CPU context, or control transfer is executed. Runtime readiness remains NOT READY TO ENTER.
