# RE4 Stage J.8.7 — Real 8C148 SJLJ provider ABI audit (checkpoint 1)

Date: 2026-11-03  
Baseline: Stage J.8.6; CI run #41618127691 SUCCESS  
Branch: `feature/stage-i-d-lazy-prebind`

## Input identity

The supplied shared cache was independently extracted and hashed:

- ZIP size: 64,679,001 bytes
- Extracted member: `dyld_shared_cache_armv6`, 166,722,970 bytes
- Extracted cache SHA-256: `ab9dbbc1e7efcc6e8c7f79d20f90dab62d4309be5269a2055e3cd5136a62d024`

This matches the previously pinned iOS 4.2.1 / 8C148 ARMv6 cache exactly.

The supplied IPA is 80,574,900 bytes, SHA-256 `81f4befd43e8af684dfa62e45a819be406229f30874eb20aa87153b8e1fc4b7c`. Its fat Mach-O contains ARMv6 (CPU subtype 6) and ARMv7 (subtype 9) slices. The analysis in this checkpoint uses the ARMv6 slice only.

Shared-cache image table identifies:

- `/usr/lib/libgcc_s.1.dylib` at image address `0x358CC000`
- `/usr/lib/libstdc++.6.dylib` at image address `0x3748D000`

The provider symbols below were read from the embedded Mach-O symbol tables, then disassembled from the pinned cache bytes. They are not guessed from symbol-name searches alone.

## 1. Forced Resume stop-callback ABI — confirmed from machine code

Relevant libgcc_s symbols:

| Symbol | Address |
|---|---:|
| `_unwind_phase2_forced` | `0x358CF7F8` |
| `__Unwind_SjLj_Resume` | `0x358CFA24` |
| `__Unwind_SjLj_Resume_or_Rethrow` | `0x358CFBA0` |
| `__Unwind_SjLj_Register` | `0x358CFB34` |
| `__Unwind_SjLj_Unregister` | `0x358CF7B8` |

At `0x358CFA2C–0x358CFA3C`, Resume reads:

- exception + `0x0C` into R1 (SJLJ `private_1`);
- exception + `0x10` into R2 (SJLJ `private_2`);

and calls `_unwind_phase2_forced(exception, private_1, private_2)` when `private_1 != 0`.

In `_unwind_phase2_forced`, the stop function is retained in R8 and the opaque stop parameter in R6. For each current SJLJ frame, the callback call sequence at `0x358CF840–0x358CF858` is:

- R0 = 1 (unwind interface version)
- R1 = 10 (`_UA_CLEANUP_PHASE | _UA_FORCE_UNWIND`)
- R2/R3 = the low/high words of exception_class, loaded from exception + 0
- stack argument 0 = exception object pointer
- stack argument 1 = current SJLJ frame/context pointer
- stack argument 2 = original `private_2` stop parameter
- branch-and-link through R8 (`BLX R8`), i.e. the raw `private_1` callback address

The provider checks the callback's R0 return value immediately. Zero continues forced unwinding; nonzero returns fatal phase-2 error (reason code 2) from this path.

Thus the stop callback ABI is the six-argument ARM AAPCS32 form:

`stop(version, actions, exceptionClass[64], exceptionObject, context, stopParameter)`

The exception class occupies R2/R3 as one 64-bit argument. The exception object, current frame/context, and stop parameter are three stack arguments. This is not a four-argument callback and `private_2` is not passed in R2 at the callback boundary.

### Difference from the current J.8.5/J.8.6 event model

The existing `RE4StageJ6ForcedStopEvent` records raw callback token, opaque stop parameter, frame address and reason 10. That is useful traversal metadata, but it is not yet a complete ABI call record. It omits at least:

- interface version (1);
- exception class low/high words;
- exception object pointer;
- explicit context/frame pointer as the second stack argument;
- the ordered argument-register/stack layout.

J.8.7 should add a separate, fully typed host-side callback invocation record and tests for the six arguments. It must continue to treat the raw callback pointer as opaque and never invoke it.

## 2. SJLJ frame context helpers — offsets confirmed

The real libgcc_s helper implementations confirm the following operations:

| Helper | Address | Machine-code behavior |
|---|---:|---|
| `__Unwind_GetLanguageSpecificData` | `0x358CF6A8` | load context + `0x1C` |
| `__Unwind_GetGR` | `0x358CF6B0` | index GPR slot, load at slot + `0x08` |
| `__Unwind_SetGR` | `0x358CF6C0` | index GPR slot, store at slot + `0x08` |
| `__Unwind_GetIP` | `0x358CF6D0` | load context + `0x04`, then add 1 (32-bit) |
| `__Unwind_GetIPInfo` | `0x358CF6DC` | write 0 to second argument, then same +4 / +1 IP calculation |
| `__Unwind_SetIP` | `0x358CF6F0` | subtract 1, store at context + `0x04` |
| `__Unwind_GetRegionStart` | `0x358CF6FC` | returns 0 in this provider |

This directly confirms the J.6 model's `callSiteIP = selectorRaw &+ 1` behavior, including 32-bit wrap of `0xFFFFFFFF` to zero, and confirms the LSDA pointer at frame/context + `0x1C`. The frame/context GPR slots use a separate base/stride calculation and should not be conflated with the SJLJ frame's saved R7/SP/PC words.

## 3. pthread TSD top — registration, unregistration and forced Resume

The libgcc_s disassembly establishes the following operations:

### Key creation

`___Unwind_SjLj_MakeTopOfFunctionStackKey` at `0x358CF798` calls the provider's key-creation import with the address of the SJLJ key and a null destructor argument. The key is therefore a pthread TSD key, not a process-global frame pointer.

### Register

`__Unwind_SjLj_Register` at `0x358CFB34`:

1. obtains the current thread's top frame using `pthread_getspecific(key)`;
2. stores that previous top through the new frame pointer (frame + `0x00`);
3. calls `pthread_setspecific(key, newFrame)`.

The chain is thread-local and newest registration becomes the TSD top.

### Unregister

`__Unwind_SjLj_Unregister` at `0x358CF7B8`:

1. reads `frame->prev` from offset `0x00`;
2. obtains the same key;
3. calls `pthread_setspecific(key, frame->prev)`.

Unregister does not independently search the chain; the caller supplies the frame whose predecessor becomes the new top.

### Forced Resume walk

`_unwind_phase2_forced` obtains the current top with `pthread_getspecific(key)`, visits that frame, and follows each frame's predecessor at offset `0x00` when the personality returns `_URC_CONTINUE_UNWIND` (8). It does not clear the TSD key merely because traversal reaches a null predecessor.

When a personality returns `_URC_INSTALL_CONTEXT` (7), the provider sets the TSD key to the selected frame, then restores:

- R7 from frame + `0x20`;
- SP from frame + `0x28`;
- PC from frame + `0x24`;

and transfers with `BX R0` at `0x358CF8E8`.

This confirms that J.8.6's reported TSD top at the exact end-of-stack return boundary is not supposed to be fabricated as zero. The caller's post-Resume continuation must be considered separately.

## 4. Cross-check against the real Res4 #101 cleanup block

The supplied ARMv6 Res4 slice confirms the cleanup block at `[0x55A8, 0x5628)`:

- `0x560C`: writes `0xFFFFFFFF` to the SJLJ selector slot;
- `0x5610`: calls the Res4 stub for `__Unwind_SjLj_Resume`;
- `0x5618`: calls the Res4 stub for `__Unwind_SjLj_Unregister`, after Resume returns.

This ordering is significant:

- If Resume installs another cleanup context, provider control transfers to that context and the old Resume call does not return to execute the `0x5618` instruction at that point.
- If Resume returns at end-of-stack, execution continues after `0x5610` and reaches `0x5618`, which unregisters the current frame and changes TSD top to its predecessor.

Therefore two different observations must be kept distinct:
1. TSD top at the instant the provider returns end-of-stack; and
2. TSD top after the caller executes its following Unregister.

J.8.6 models the first boundary. Its current final top value is not evidence that the real thread leaves the frame registered after the #101 cleanup function finishes. The post-return Unregister is a separate caller action and should be represented explicitly in a later lifecycle integration test.

## 5. Current evidence boundary and next work

Confirmed from exact 8C148 provider bytes:

- six-argument stop callback ABI and callback return handling;
- SJLJ exception private-word offsets used by Resume;
- frame predecessor, selector/IP, LSDA and saved context offsets listed above;
- thread-local TSD registration and unregistration operations;
- forced Resume traversal, InstallContext TSD update and R7/SP/PC restore sequence;
- #101's Resume-then-Unregister call-site order.

Not yet established by this checkpoint:

- complete semantic behavior of all possible personality return codes and malformed frame cases;
- all pthread key lifecycle/thread-exit interactions and any key destructor behavior beyond the null key-destructor argument;
- exact runtime stack alignment/register preservation at every Res4-to-provider boundary on a live device;
- whether the complete Res4 #101 multi-cleanup topology matches the synthetic three-cleanup fixture in every possible real invocation;
- live execution correctness of ARMv6 context restoration or the full runtime.

### Recommended J.8.7 implementation sequence

1. Add a typed stop-callback ABI record with version, actions, exception class, exception pointer, context pointer and stop parameter.
2. Add a provider-derived TSD lifecycle transition model that distinguishes provider end-of-stack return from the caller's subsequent Unregister.
3. Add exact #101 call-site tests for Resume followed by Unregister, and for the non-returning InstallContext branch.
4. Compare all J.8.5/J.8.6 transition assumptions against the provider state machine before designing the Guest CPU context adapter.

No provider routine, callback, pthread function, Res4 initializer, ARM instruction stream or live Guest context was executed by this audit. Runtime readiness remains **NOT READY TO ENTER**.

## Host model implementation checkpoint

The provider-derived host model and regression harness have now been added:

- `RE4MCTPreview/RE4StageJ87ProviderABIModel.swift`
- `tools/test-stage-j8-7.swift`
- `tools/validate-stage-j8-7.sh`

The callback record explicitly carries the raw callback token, version 1, actions 10, both exception-class words, exception-object pointer, current frame/context pointer, and private_2 stop parameter. It exposes the AAPCS32 register and stack argument order separately and only classifies a supplied synthetic return code; it never invokes the raw callback.

The TSD model separately represents key creation, Register, Unregister, forced traversal, InstallContext publication, end-of-stack return, and caller-side Unregister. The J.8.7 validator is now chained after J.8.6 in the existing CI validation path.

CI result for this new implementation is pending at the time of this documentation update. No PASS is claimed until the workflow reports the J.8.7 test and Release compile steps successful.


## J.8.7 completion and callback identity/lifetime boundary

GitHub Actions run [#41620588181](https://github.com/Naztar3421/RE4Mobile-iOS26/actions/runs/41620588181) completed successfully. The provider ABI/TSD suite reported 8/8 at the original checkpoint; the production-surface compile passed, followed by the unsigned iOS Release build and IPA upload. Artifact ID: 13223647808; uploaded ZIP SHA-256: b8d0f7dceb656fd17026825f29d8690bb0741081343e6f347ab87f010f4b0fbc.

The follow-on lifetime ledger makes the callback boundary explicit. Across callbacks belonging to one modeled forced phase-2 invocation, the exception-object pointer and private_2 stop parameter are stable identities; the context pointer is a borrowed pointer to the current frame and is checked against the frame being visited, so it may change from callback to callback. This is an identity/argument-lifetime assertion only: it does not infer ownership, allocation, retain/release, deletion, or validity beyond the provider call. The expanded J.8.7 suite checks both stable exception/stop-parameter identity and per-frame context association.

J.8.7 is host-only. No raw callback, exception runtime object, pthread API, provider function, Guest memory or CPU state is invoked.
