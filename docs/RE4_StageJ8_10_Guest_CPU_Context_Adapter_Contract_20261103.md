# RE4 Stage J.8.10 — Guest CPU Context Adapter contract

Date: 2026-11-03  
Target: Res4 / iOS 4.2.1 / 8C148 / ARMv6, ExtraProductList initializer #101  
Baseline: J.8.7 provider ABI, J.8.8 TSD lifecycle, J.8.9 context-restore preconditions

## Decision

**The adapter contract is now defined and host-tested; live CPU application and BX remain blocked.** The stage creates an immutable successor-context projection for the exact forced-Resume InstallContext tail. It does not attach to or mutate RE4GuestARMv6Core.

## 1. Forced path address correction

__Unwind_SjLj_Resume reads private_1 at exception + 0x0C. For #101's forced route (private_1 != 0), it calls _unwind_phase2_forced at 0x358CF7F8. The forced InstallContext tail is:

| VA | Instruction | Effect |
|---:|---|---|
| 0x358CF8D8 | call _pthread_setspecific | publish selected SJLJ frame as thread top |
| 0x358CF8DC | LDR R7,[R4,#0x20] | restore R7 |
| 0x358CF8E0 | LDR SP,[R4,#0x28] | restore SP |
| 0x358CF8E4 | LDR R0,[R4,#0x24] | load raw continuation operand into R0 |
| 0x358CF8E8 | BX R0 | select ARM/Thumb state and transfer |

The similar sequence at 0x358CF9D0–0x358CF9DC is the normal _unwind_phase2 route, not the forced path entered by #101's nonzero private_1. Both tails use the same field offsets, but their provider VAs must not be interchanged. The CSV records both sequences explicitly.

## 2. Architectural state contract

The adapter accepts a 16-word GPR snapshot, the currently modelled N/Z/C/V flags, and an explicit instruction-set state. R15 is a canonical instruction address; the ARM/Thumb state bit is represented separately.

For the forced #101 InstallContext tail, the planned post-BX values are:

- R0 = the **raw** value loaded from frame + 0x24 (the BX operand remains in R0 after BX);
- R7 = frame + 0x20;
- SP/R13 = frame + 0x28;
- PC/R15 = canonical target address (bit 0 is removed for Thumb; ARM targets are word aligned);
- instruction state / CPSR.T subset = selected by raw BX operand bit 0;
- N/Z/C/V remain as they were immediately before the final LDR/LDR/LDR/BX tail, because these instructions do not restore condition flags.

The adapter does **not** reconstruct the earlier pre-exception flags. The provider has no full saved-CPSR image or MSR restore in this path. The current core also does not represent the entire CPSR (mode, interrupt masks, Q/GE and other architectural fields), so the contract expressly claims only the current N/Z/C/V subset plus the derived ARM/Thumb state.

The provider's final sequence changes the register-file slots R0, R7, R13 and R15. It does not load a full register file from the SJLJ frame. Other GPR values are retained from the provider's live state at the InstallContext tail; #101's own epilogue later restores the function's saved callee registers from its stack.

## 3. Preconditions enforced by the host adapter

- Exactly 16 GPR words are supplied.
- Provider source state is ARM: the pinned provider tail is ARM code.
- R4 identifies the exact selected SJLJ frame being installed.
- J.8.9 checks frame bounds, saved-SP range/alignment, #101 saved-R7/SP relationship, GR0/GR1, LSDA and BX target validity.
- A raw target with bit 0 clear and bit 1 set is rejected as an unpredictable ARM BX operand; a Thumb target preserves its raw low bit in R0 while exposing a canonical halfword-aligned PC.
- The successor state is returned as immutable data. No live core setter is called.

## 4. Responsibilities after the provider branch

#101's continuation is 0x55A8. The provider does not directly restore the original callee-saved GPR/VFP set. The target function's stack epilogue owns these obligations:

- restore R4–R7, R8, R10, R11 and the saved LR (popped into PC);
- restore VFP D8–D15;
- finish the function return.

This distinction is essential: the SJLJ frame's GR0/GR1 slots are personality data slots, not architectural R0/R1 restores. R0 is instead overwritten with the raw BX operand by the provider's final load.

## 5. Existing Guest core blockers found during adapter design

The current RE4GuestARMv6Core is not yet capable of applying this prepared state safely:

1. step() always calls readInstruction32(PC) and advances ARM PC by four; there is no Thumb 16-bit fetch/decode path or architectural T-state in the core.
2. The current register-branch implementation sets PC = target & ~3. It does not perform BX bit-0 interworking or update T. The separate RE4ARMv6InstructionSetState helper only classifies a target; it does not mutate the core.
3. NZCV are private scalar fields. The core has no public atomic architectural-state snapshot/apply interface, and it does not model a complete CPSR.
4. The legacy vpush {d8-d15} and vpop {d8-d15} cases currently subtract/add 64 from SP only. They do not write/read the D-register payloads to/from Guest Memory. Thus #101's native VFP epilogue responsibility is statically known but not executable in the current core.
5. No transaction boundary exists yet to validate the whole successor context before publishing all registers/state together.

These are hard blockers, not cosmetic cleanup. In particular, classifying an odd BX pointer as Thumb is not equivalent to executing Thumb instructions.

## 6. Test/validation scope

The 13 host tests cover: 16-register shape and canonical PC constraints; provider ARM source state; R4/frame identity; exact forced-vs-normal provider instruction addresses; R0 scratch effect; R7/SP/PC updates; preservation of other GPRs and NZCV; ARM and Thumb BX target semantics; invalid ARM alignment; immutable source snapshot; explicit no-BX/no-Guest-execution invariants; target-epilogue restore responsibilities; and existing Thumb/VFP core capability gaps.

The validator also pins the forced and normal provider address sequences in a CSV and checks the relevant current-core source patterns before compiling both the host test executable and a Release-mode Swift module.

## 7. Required next implementation order

1. Add a typed, complete-enough core snapshot for every state the emulator actually supports, with an atomic validate-then-commit API. Do not invent unsupported CPSR fields.
2. Implement state-aware ARM/Thumb stepping: 32-bit ARM versus 16-bit Thumb fetch, PC alignment/pipeline rules, and explicit CPSR.T state.
3. Correct BX/BLX-register execution to perform real interworking; reject unpredictable or unsupported state transitions rather than masking address bits.
4. Implement actual VFP D8–D15 stack payload loads/stores and verify alignment/order against the #101 prologue/epilogue.
5. Only then connect a prepared SJLJ context to the live core, first in a gated test harness with an explicit stop/return boundary, before any original initializer or full startup path.

No Guest instruction, Guest Memory write, live CPU state, provider function, pthread API, exception callback, or BX is executed by J.8.10. Runtime readiness remains **NOT READY TO ENTER**.


## Stage J.8.12 implementation update — VFP D8-D15 stack transfers

The former stack-transfer blocker is now addressed in the bounded Guest Core for the exact encodings used by #101: VPUSH {D8-D15} (0xED2D8B10) and VPOP {D8-D15} (0xECBD8B10). The implementation maps D8-D15 to S16-S31 and performs complete 64-byte Guest Memory transfers in ascending register order, low word then high word. VPUSH validates/writes the complete range before publishing SP; VPOP reads/decodes all bytes before changing VFP registers or SP. A separate VFP bank snapshot is available; the J.8.11 GPR/NZCV snapshot does not claim to contain VFP state.

J.8.10's capability report now identifies VFP D8-D15 stack transfers as implemented, while Thumb execution remains unsupported. This does not execute BX or make the game runtime ready.


## Stage J.8.12 implementation update — VFP D8-D15 stack transfers

The former stack-transfer blocker is now addressed in the bounded Guest Core
for #101's exact encodings: VPUSH {D8-D15} (0xED2D8B10) and VPOP {D8-D15}
(0xECBD8B10). D8-D15 map to S16-S31 and move as one complete 64-byte
Guest Memory image in ascending register order, low word then high word.
VPUSH completes its validated write before publishing SP; VPOP stages the
complete read before changing the VFP bank and SP. A separate VFP bank
snapshot is available; the J.8.11 GPR/NZCV snapshot does not claim VFP coverage.

The adapter capability report now identifies VFP D8-D15 stack transfers as
implemented. Thumb execution and provider BX remain unsupported; runtime
readiness is not established.
