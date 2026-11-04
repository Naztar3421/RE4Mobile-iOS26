# Stage J.10 — Provider Callable Closure Audit

**Target:** Res4 / iOS 4.2.1 / build 8C148 / ARMv6  
**Reviewed HEAD:** c95af97f98aed4d6ce0b2851c3692c65065330c8  
**Scope:** Read-only provider/import/ABI inventory. No provider, Guest callback, pthread operation, destructor, personality, unwinder, initializer, or Guest instruction is executed.

## 1. Decision

| Gate | Result | Meaning |
|---|---|---|
| Seven direct provider symbols | STATIC MAP PASS (7/7) | Each imported pointer has an identified provider VA/state, Stage I-D readback PASS, and shared-cache TEXT_RX/RX mapping. |
| Direct-callsite crosswalk | PASS (502/502) | Seven imported symbols join to 502 unique J.1 static call sites after path-label deduplication. |
| Transitive provider-body inventory | STATIC AUDIT PARTIAL | SJLJ, __cxa_atexit, ios_base::Init, and selected wide-string routines have static body evidence; this is not executable ABI closure. |
| Existing host-side models | BOUNDED PASS | J.4/J.6–J.8.5 model selected state/data contracts; none is a target-compatible provider implementation. |
| Explicit HLE coverage of seven imports | 0/7 | None of the seven symbols appears in the current HLE implemented-function set. |
| Guest-callable provider closure | BLOCKED | Pointer mapping is not a callable ABI bridge. pthread TSD, callbacks, C++ runtime, indirect personality and context transfer remain unresolved. |
| Global Guest Runtime entry | NOT READY | J.10 does not change the J.9 readiness decision. |

**Critical distinction:** Stage I-D proves that each raw pointer was staged/read back at an executable shared-cache address. It does not prove that the CPU can enter the target in the correct ARM/Thumb state, that every transitive import and runtime object exists, or that the required ABI and thread state are available.

## 2. Seven direct Res4 provider imports

Counts are unique static imported machine call sites, not runtime invocation counts.

| Symbol | Provider and target | State | Res4 stub / pointer slot | Static call sites | ABI32 contract | Host-side evidence | Guest-side status |
|---|---|---|---|---:|---|---|---|
| ___cxa_atexit | libSystem.B.dylib, VA 0x35E0AFE8; raw pointer 0x35E0AFE9 | Thumb | stub 0x0019FE5C / slot 0x001C17A0 | 240 | R0=callback; R1=argument; R2=DSO; status in R0 | Actual 8C148 provider body statically audited; J.4 host registry model 14/14 | Not callable: Thumb CPSR/decode/entry absent; no HLE |
| __Unwind_SjLj_Register | libgcc_s.1.dylib, VA/raw 0x358CFB34 | ARM | stub 0x0019FCE8 / slot 0x001C1724 | 1 | Frame-context pointer expected in R0; verify actual caller live-in before binding | J.5 provider body static audit; J.6 synthetic frame-chain model | Not callable: no live frame/TSD bridge; no HLE |
| __Unwind_SjLj_Resume | libgcc_s.1.dylib, VA/raw 0x358CFA24 | ARM | stub 0x0019FCF4 / slot 0x001C1728 | 1 | Exception-object pointer in R0; transfers through unwind phase 2 rather than ordinary return | J.5 body audit; J.6/J.8.2–J.8.5 host models | Not callable: no actual phase walk, personality call, register restore or branch; no HLE |
| __Unwind_SjLj_Unregister | libgcc_s.1.dylib, VA/raw 0x358CF7B8 | ARM | stub 0x0019FD00 / slot 0x001C172C | 1 | Frame-context pointer expected in R0; verify exact caller live-in before binding | J.5 provider body audit; J.6 synthetic registry model | Not callable: no real per-thread frame-chain mutation; no HLE |
| Wide-string C1: __ZNSbIwSt11char_traitsIwESaIwEEC1EPKwRKS1_ | libstdc++.6.dylib, VA/raw 0x374E5C6C | ARM | stub 0x0019FD3C / slot 0x001C1740 | 20 | C++ member ABI: R0=this; R1=NUL-terminated wchar_t pointer; R2=allocator reference | C1/C2 path statically inspected; no host Guest-string execution | Not callable: allocator, wchar_t, SJLJ and ownership closure absent; no HLE |
| Wide-string D2: __ZNSbIwSt11char_traitsIwESaIwEED2Ev | libstdc++.6.dylib, VA/raw 0x374E4724 | ARM | stub 0x0019FD48 / slot 0x001C1744 | 1 | C++ member ABI: R0=this | D2 provider body statically inspected; J.7/J.8 only model cleanup metadata/continuation | Not callable: refcount/deallocation/C++ delete path unresolved; no HLE |
| ios_base::Init C1: __ZNSt8ios_base4InitC1Ev | libstdc++.6.dylib, VA/raw 0x37496B50 | ARM | stub 0x0019FDB4 / slot 0x001C1768 | 238 | C++ member ABI: R0=this | Actual C1/C2 provider path statically audited; target-specific lifecycle model and J.4 tests | Not callable: no process-wide C++/stdio lifecycle or SJLJ bridge; no HLE |

The seven counts total 502 unique static machine call sites: 240 + 1 + 1 + 1 + 20 + 1 + 238. All seven raw provider pointers passed Stage I-D readback and resolve into shared-cache TEXT_RX with RX permissions. All seven have Explicit_HLE_Implemented = NO.

### #101 caller-side facts

- The #101 __cxa_atexit call at 0x521C passes R0=0x0019E8F4, R1=0, R2=0x1000. The callback pointer is a Res4-local wrapper, not a direct pointer into libstdc++.
- A second __cxa_atexit registration occurs at 0x55A0 for the wide-string collection cleanup wrapper. The Stage J.5 callback/cleanup record identifies the wrapper as ___tcf_13 at 0x0019E8B4, with raw callback pointer 0x0019E8B5 (Thumb). Do not conflate this registration with the callback at 0x521C.
- The normal wide-string collection callback destroys 20 slots in reverse order (19 down to 0). Each slot is four bytes.
- The exceptional cleanup block is 0x55A8..0x5614. Its D2 callsite is 0x55FC; the partially constructed prefix is destroyed in reverse order. The sentinel write at 0x560C is followed by SJLJ Resume at 0x5610.
- The provider entry for ___cxa_atexit is itself Thumb (raw pointer 0x35E0AFE9). The normal callback wrapper at 0x0019E8B5 is also Thumb. Both need real Thumb interworking before they could be entered.

## 3. SJLJ provider transitive closure

The three Res4 imports are not self-contained. The J.5 static provider trace identifies these provider routines:

| Provider routine | VA | State | Observed dependency and behavior |
|---|---:|---|---|
| ___Unwind_SjLj_MakeTopOfFunctionStackKey | 0x358CF798 | ARM | Calls pthread_key_create to establish the per-thread SJLJ-top key. |
| __Unwind_SjLj_Register | 0x358CFB34 | ARM | Uses pthread_once, pthread_getspecific and pthread_setspecific; stores predecessor at frame+0 and installs the new TSD top. |
| __Unwind_SjLj_Unregister | 0x358CF7B8 | ARM | Uses pthread_once and pthread_setspecific; restores predecessor from frame+0. |
| __Unwind_SjLj_RaiseException | 0x358CFA78 | ARM | Uses pthread_once, pthread_getspecific and indirect personality calls; walks frame chain and handles personality responses 6/8. |
| __Unwind_SjLj_Resume | 0x358CFA24 | ARM | Chooses _unwind_phase2 or _unwind_phase2_forced based on exception private_1. |
| _unwind_phase2 | 0x358CF904 | ARM | Uses pthread_once/getspecific, indirect personality and setspecific; INSTALL_CONTEXT restores saved R7/SP/PC and transfers to continuation. |
| _unwind_phase2_forced | 0x358CF7F8 | ARM | Uses pthread_once/getspecific, stop callback, indirect personality and setspecific; forced action/reason is 10. |

### pthread TSD functions

| Function | Evidence in provider trace | Address/state | Host-side status | Guest-side status |
|---|---|---|---|---|
| pthread_key_create | Dependency of 0x358CF798 | Exact export VA/raw pointer/state not pinned in the supplied crosswalk | No real pthread binding | Not in HLE; no Guest key lifecycle |
| pthread_once | Used by Register/Unregister/RaiseException/phase2/forced | Exact export VA/raw pointer/state not pinned | No real pthread-once bridge | Not in HLE; no Guest once-control storage |
| pthread_getspecific | Used by Register/RaiseException/phase2/forced | Exact export VA/raw pointer/state not pinned | Swift threadID-keyed model is synthetic only | Not in HLE; no real Guest TSD |
| pthread_setspecific | Used by Register/Unregister/phase2/forced | Phase-2 callsite 0x358CF9CC branches to 0x358CFD5C; complete pthread export/veneer crosswalk not established | Synthetic state only | Not in HLE; not proven callable |
| pthread_mutex_lock/unlock | Conditional threaded path in __cxa_atexit registry | Exact export VA/raw pointer/state not pinned | No real mutex binding | Not in HLE; conditional provider dependency |

J.7 pins the phase-2 setup: instruction at 0x358CF9C4 prepares R1=R4 (the current frame); the setspecific callsite is 0x358CF9CC and the observed branch target is 0x358CFD5C. Treat this as a pinned branch target, not as a fully cross-checked standalone pthread export until its veneer, owning image, raw pointer and ISA state are verified.

### J.7 correction: INSTALL_CONTEXT retains the current frame

An earlier J.5 summary described the phase-2 path as unlinking the selected frame before cleanup. J.7 corrected this from the pinned 8C148 instructions: INSTALL_CONTEXT sets the TSD top to the **current frame** before restoring R7/SP/PC. The current frame remains TSD top while its cleanup continuation executes. Res4 then writes 0xFFFFFFFF to frame+4 and calls Resume; the 32-bit GetIP calculation wraps the completed-frame sentinel to zero. This report follows the corrected J.7 interpretation.

## 4. Personality and context-helper closure

The personality referenced by Res4 #101 is **___gxx_personality_sj0 at 0x374EF9F8 in libstdc++.6.dylib, ARM state**. It is not interchangeable with ___gcc_personality_sj0 at 0x358CE23C in libgcc_s; that is a distinct symbol and is not the personality selected by #101.

| Helper | Provider VA | State | ARM32 ABI shape / observed contract | Host-side evidence | Guest-side status |
|---|---:|---|---|---|---|
| ___gxx_personality_sj0 | 0x374EF9F8 | ARM | R0=version; R1=actions; R2/R3=64-bit exception class; remaining pointer args stack-passed; reason code in R0 | J.6 narrow decision model 20/20 | No indirect target invocation or Guest personality bridge |
| __Unwind_GetLanguageSpecificData | 0x358CF6A8 | ARM | R0=context; returns LSDA pointer from frame+0x1C in R0 | J.6 static metadata helper model | No Guest helper binding |
| __Unwind_GetGR | 0x358CF6B0 | ARM | R0=context; R1=register number; result in R0 | J.6 computes target-relative frame offset only | No real frame read |
| __Unwind_SetGR | 0x358CF6C0 | ARM | R0=context; R1=register number; R2=value | J.7 context-plan builder | No real frame write |
| __Unwind_GetIP | 0x358CF6D0 | ARM | R0=context; returns frame+4 selector plus one | J.6 arithmetic model | No Guest helper binding |
| __Unwind_SetIP | 0x358CF6F0 | ARM | R0=context; R1=dispatch index; stores index-1 at frame+4 | J.7 metadata plan | No real frame write |
| __Unwind_GetRegionStart | 0x358CF6FC | ARM | R0=context; target-specific implementation returns zero | J.6 constant model | Not a generic region-base implementation |
| __Unwind_GetTextRelBase / __Unwind_GetDataRelBase | 0x358CF728 / 0x358CF760 | ARM | Audited helpers route to assertion failure; #101 omits LPStart/TType bases | Unsupported in host profile | Do not call for arbitrary LSDA |

For #101's zero-action path, the personality's bounded behavior is to set GR0 to the supplied exception pointer, GR1 to zero, set the dispatch index, and return INSTALL_CONTEXT (7). The personality call is an indirect provider dependency, not a normal HLE trap. J.6 tests its narrow decision model; J.7 builds context metadata. Neither invokes the personality or writes the actual guest frame. Typed catches, action chains, other LSDA encodings and arbitrary personality profiles remain unsupported.

## 5. Forced-unwind stop callback

The forced helper is _unwind_phase2_forced at 0x358CF7F8 (ARM). The stop routine is caller-supplied, not a fixed libgcc symbol. The J.5 trace says it is carried as a raw callback token in exception private_1; private_2 is the opaque stop parameter. J.8.5 replaces the call with a supplied synthetic host closure and injected return values. The raw target callback token is never resolved or invoked.

The generic stop-callback ABI shape is:

    _Unwind_Reason_Code stop(
        int version,
        _Unwind_Action actions,
        uint64_t exceptionClass,
        struct _Unwind_Exception *exceptionObject,
        struct _Unwind_Context *context,
        void *stopParameter);

For 32-bit ARM AAPCS, the first argument words use R0/R1 and the aligned 64-bit exception class uses R2/R3; subsequent pointer arguments are stack-passed when core argument registers are exhausted, with the reason code returned in R0. This is the generic contract shape for inventory only. The exact callsite stack layout and caller-specific binary prototype have not been verified from a real forced-unwind caller.

**Unresolved:** no actual stop-callback address, raw pointer low bit, ARM/Thumb state, or target implementation is established by J.5–J.9. Record it as UNKNOWN / NOT AVAILABLE, not as ARM merely because the unwind provider is ARM.

## 6. C++ ABI and destructor transitive closure

### ___cxa_atexit / ___cxa_finalize

The actual 8C148 ___cxa_atexit provider uses kind-2 records of 16 bytes (kind, function, argument, DSO), 32 records per node, an 8-byte node header and 0x208-byte dynamic nodes. ___cxa_finalize scans newest node first and descending record index (global LIFO); nonzero DSO means exact equality, while zero means no DSO filter. The source kind is cleared before the callback boundary; the callback runs outside the registry lock in the threaded path, and callback-time registration triggers a root restart.

J.4's host provider model covers the selected registry semantics with 14/14 tests. It models callback plans/data only: it does not execute callbacks, lock a real mutex, allocate a real Guest node or call a target function. The Res4-side ___cxa_finalize trigger/caller was not observed in the seven-symbol import crosswalk; process teardown order remains open.

### Wide-string C1/C2 and D2

- C1 entry 0x374E5C6C is a thunk to C2 at 0x374E5C20.
- The C2 path uses _wcslen stub 0x374F307C, _Rep::_S_create at 0x374E4774, allocation helpers and SJLJ Register/Unregister/Resume.
- C2 registers an SJLJ frame around construction (register site 0x374E47C0, unregister site 0x374E48A4). SJLJ is therefore a normal constructor dependency as well as an exception-path dependency.
- D2 at 0x374E4724 calls _M_dispose at 0x374E46B4, _M_destroy at 0x374E46A4 and C++ delete stub at 0x374F2B8C. The audited path reads the string data pointer, derives the representation header at data-12, decrements its atomic reference count and destroys/deallocates only when required.
- The J.5 cleanup contract identifies 20 string slots and reverse destruction. Guest heap interoperability, wchar_t width, string representation lifetime, atomic operations, operator delete and allocator compatibility are not supplied by current HLE.

### std::ios_base::Init

C1 at 0x37496B50 thunks to C2 at 0x37496664. The provider increments shared _S_refcount; a pre-increment value of zero performs one-time stream setup. D1 at 0x37496660 thunks to D2 at 0x3749651C; a pre-decrement value of two triggers the six-stream flush sequence. The C2 path itself uses SJLJ Register/Resume/Unregister. J.4 models the refcount gates and flush order, but does not construct streams or perform standard I/O. The complete process-wide set of other _S_refcount consumers and the required stream/stdio import closure remain open.

## 7. Host implementation vs Guest callability

| Area | Host-side support | Guest-side implementation |
|---|---|---|
| Seven direct imports | Static evidence plus limited data/state models; no host function installed as a target-compatible provider | 0/7 explicit HLE bindings |
| SJLJ Register/Unregister/Resume | J.6 synthetic frame registry; J.8.2–J.8.5 phase/completion models | No live pthread TSD, guest frame-chain operations, indirect personality dispatch or real context transfer |
| Personality/context helpers | J.6 decision model; J.7 context-plan builder; J.8 readback/guard models | No target personality/helper invoked; no real register-file or PC restore |
| pthread TSD | Swift threadID-keyed synthetic state only | pthread key/once/getspecific/setspecific not implemented in HLE |
| ___cxa_atexit/finalize | J.4 provider-specific registry model 14/14 | No callable provider or callback-dispatch bridge; ___cxa_atexit target is Thumb |
| Wide-string / iostream | Static provider analysis and selected state models | No Guest string allocation/destruction or real stream lifecycle |
| Forced stop callback | J.8.5 synthetic host closure with injected results | Raw target stop token not resolved or called |

The current explicit HLE set is limited to basic memory/string calls and _exit. It does not include any of the seven imports, pthread primitives, personality, Unwind helpers, _wcslen or C++ delete. Basic malloc/free coverage does not close the target's allocator/C++ delete semantics.

This paragraph describes the J.10 reviewed baseline (HEAD c95af97) and is superseded by later Core milestones: J.8.13 adds a bounded Thumb-1 fetch/decode path, J.8.14 executes register-form BX/BLX interworking within the Core, and J.8.11 now carries the bounded ARM/Thumb mode through the failure-atomic GPR/NZCV commit transaction (latest implementation commit f3d095d; full CI pending). These changes do not implement a complete CPSR or full ARMv6/Thumb ISA, and they do not make shared-cache provider addresses callable. The seven direct imports remain 0/7 explicit HLE coverage; provider ABI, pthread TSD, C++ object state, callback contracts, personality/unwinder execution and live context transfer remain unresolved.

## 8. Closure checklist before executable SJLJ work

1. Reconfirm all seven raw pointer words and slots against the exact Stage I-D readback; preserve raw bit 0 separately from canonical target VA.
2. Resolve each pthread primitive's exact veneer, owning image, provider pointer and ISA state, including key initialization and pthread_once lifecycle.
3. Establish caller-side live register/stack values for Register, Unregister, Resume, C++ member calls and stop callbacks; do not infer exact callsite state from prototypes alone.
4. Close ___cxa_atexit registry dependencies: mutex path, allocator, callback ABI, finalizer trigger, re-registration and process teardown order.
5. Close wide-string C1/C2/D2 dependencies: wchar_t width, _wcslen, _Rep layout, atomics, _M_destroy, C++ delete and Guest heap compatibility.
6. Define real per-thread TSD storage and key lifecycle, separately from the current Swift synthetic registry.
7. Implement and validate Thumb execution/interworking before any Thumb provider/callback can be considered callable.
8. Only after the above evidence gates, separately review CPU context representation, indirect personality invocation and landing-pad transfer. This report grants no execution permission.

## 9. Evidence sources

This report consolidates the existing repository docs and generated static evidence:

- RE4_StageJ5_SJLJ_Provider_Trace_20261102.csv
- RE4_StageJ5_Callback_Cleanup_Contracts_20261102.csv
- RE4_StageJ5_HLE_Transitive_Dependency_Map_20261102.csv
- RE4_StageJ_CrossStage_Provider_Evidence_7_20261102.csv
- RE4_StageJ_CrossStage_Evidence_Chain_20261102.md
- docs/stage-j6-sjlj-personality.md
- docs/stage-j7-landing-pad-context.md
- docs/stage-j8-2-sjlj-context-handoff.md
- docs/stage-j8-5-sjlj-forced-resume-completion.md
- docs/stage-j9-sjlj-integration-readiness.md
- docs/stage-j9-sjlj-readiness-matrix.csv
- RE4StageJ6SJLJPersonalityModel.swift
- RE4StageJ7LandingPadContextModel.swift
- RE4StageJ85ForcedResumeCompletionModel.swift
- RE4MachO32HLEBinder.swift
- RE4GuestARMv6Runtime.swift

The J.5 provider trace is used for internal routine identities; the J.7 INSTALL_CONTEXT correction supersedes the earlier frame-unlink wording. Missing addresses/states and caller live-ins are deliberately left unresolved rather than inferred from an even VA or a mapped provider pointer.

**J.10 conclusion:** seven direct provider imports have a cross-referenced address/state/ABI inventory, and their major transitive dependencies are enumerated. Static provider mapping is established; callable runtime closure is not. SJLJ executable runtime remains BLOCKED. GUEST_RUNTIME_ENTRY_GATE remains NOT READY.


## 2026-11-04 superseding Core capability update

The Core limitations in the reviewed J.10 baseline above have been partially
advanced by later bounded stages: J.8.13 adds a limited Thumb-1 fetch/decode
path; J.8.14 adds in-Core register BX/BLX interworking; and J.8.11 adds a
failure-atomic GPR/NZCV/ARM-Thumb-mode state transaction.

GitHub Actions Run [#212](https://github.com/Naztar3421/RE4Mobile-iOS26/actions/runs/41839376228)
completed **SUCCESS**, including J.8.11 **17/17**, Release-mode compile,
the J.8.5-to-J.8.14 validation chain, and unsigned iOS app/IPA packaging.
This does not change the J.10 provider-closure result: seven direct imports
still have **0/7 explicit HLE implementations**. No provider pointer is thereby
made callable; pthread TSD, target callbacks, personality/unwinder execution,
C++ object/allocator lifecycle and live context transfer remain unresolved.
SJLJ executable runtime remains **BLOCKED** and Guest Runtime remains **NOT READY**.
