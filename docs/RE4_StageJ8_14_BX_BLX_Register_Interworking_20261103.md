# RE4 Stage J.8.14 — A32/T16 BX and BLX-register interworking

Date: 2026-11-03  
Target: Res4 / iOS 4.2.1 / 8C148 / ARMv6  
Baseline: J.8.13 state-aware ARM/Thumb stepping; J.8.12 VFP D8-D15 stack transfers

## Decision

The Guest Core now performs actual register-form BX and BLX state transitions between ARM and Thumb. A32 and T16 instructions share one validate-before-publish branch-exchange helper. The helper resolves the raw target first; only after validation does it update LR (for BLX), canonical PC, and the current ARM/Thumb execution state.

This is a bounded instruction implementation. It does not provide a complete ARMv6 emulator, a full CPSR, BXJ, exception-return semantics, or live application of a prepared SJLJ context.

## Architectural behavior implemented

### Target state and address

- Raw target bit[0] selects the destination instruction set: 1 = Thumb; 0 = ARM.
- Thumb targets canonicalize by clearing bit[0] only.
- ARM targets must be word-aligned. A raw target whose low bits are `10` is unpredictable for an ARM-state destination and is rejected; the Core does not silently clear bit[1].
- The selected state is recorded separately from R15. R15 contains the canonical instruction address.
- BX does not write LR. BLX writes LR only after the target passes validation.
- BX/BLX do not modify the modeled NZCV flags.

### Link-register semantics

- A32 BLX-register stores the address of the next A32 instruction (`A+4`) in LR.
- T16 BLX-register stores the next Thumb instruction address with bit[0] set (`(A+2)|1`) in LR.
- These values are return-state tokens: the callee can return through BX LR, allowing the same exchange path to restore the caller's instruction set.
- Conditional A32 BLX executes only when its condition passes; an untaken instruction does not update LR, PC, or instruction state.

### PC source operands and reserved cases

- A32 BX PC uses the A32 PC operand value `A+8`.
- T16 BX PC uses the Thumb PC operand value `A+4`. At a word-aligned BX instruction this selects the next A32 word. If the resulting ARM target has low bits `10`, the result is rejected as unpredictable.
- A32 BLX-register with R15 and T16 BLX-register with R15 are rejected as unpredictable.
- T16 BX/BLX reserved low encoding bits are rejected.
- The register subset does not add BXJ or exception-return handling.

These rules follow the ARM Architecture Reference Manual ARMv6 (ARM DDI 0100I, BX/BLX descriptions in A4.1.9, A7.1.18 and A7.1.19) and the ARM Compiler instruction reference for register restrictions and flag behavior:
- https://www.scs.stanford.edu/~zyedidia/docs/arm/armv6.pdf
- https://support.arm.com/documentation/dui0379/e/arm-and-thumb-instructions/blx

## Implementation

- `RE4ARMv6InstructionSetState.resolveBX/resolveBLXRegister` is now a throwing pure resolver. It validates the raw target and yields source state, destination state and canonical PC.
- `RE4GuestARMv6Core.executeRegisterBranchExchange` is the single publication point shared by A32 and T16.
- A32 `BX Rm` / `BLX Rm` and T16 `BX Rm` / `BLX Rm` dispatch through that helper.
- PC is read using the source instruction-set rules when R15 is permitted.
- BLX's LR value is computed from the source instruction address and is not applied until the target has passed validation.
- The J.8.10 prepared-context capability projection now reports that register BX/BLX interworking is present. It remains a data-only projection: it does not execute the provider's BX or apply the context.
- The initializer static audit now propagates an explicit malformed-initializer-pointer error when an ARM function pointer has unpredictable alignment.

## Validation

The dedicated 19-case host test suite covers:

1. A32 BX to Thumb and target execution;
2. A32 BX to ARM and target execution;
3. T16 BX to ARM and target execution;
4. T16 BX to Thumb and target execution;
5. A32 BLX to Thumb, LR value and BX LR return to ARM;
6. A32 BLX to ARM, LR value and same-state return;
7. T16 BLX to ARM, odd Thumb return token and BX LR return to Thumb;
8. T16 BLX to Thumb and same-state return;
9. NZCV preservation across BLX;
10. untaken conditional A32 BLX does not link or branch;
11. invalid A32 BLX ARM target is rejected before LR/state publication;
12. invalid T16 BLX ARM target is rejected before LR/state publication;
13. reserved T16 BX encoding fails closed;
14. architecturally permitted T16 BX PC reads A+4 and branches to the next ARM word;
15. pure target-state and alignment resolution;
16. T16 BLX PC is rejected as unpredictable;
17. A32 BX PC reads A+8 and remains in ARM state;
18. A32 BLX PC is rejected as unpredictable;
19. T16 BX PC at a halfword-only address is rejected when PC+4 would be an unpredictable ARM target.

The validator runs this suite and performs a separate Release-mode compile without `RE4_HOST_TESTING`. It is chained after the J.8.13 validator, itself inside the existing J.8.5 umbrella CI chain.

## Readiness boundary

J.8.14 supplies real A32/T16 register BX/BLX interworking inside the bounded Guest Core, but **does not connect a prepared J.8.10 SJLJ context to the live Core**. J.8.11's two-phase live context transaction remains ARM-only. It also does not execute the original provider code, stop callback, personality, unwinder, pthread TSD operations, or Res4 initializer #101.

The next separate task is to extend the live architectural-state commit contract to an explicit ARM/Thumb state token without inventing full CPSR fields. Only after that should a gated synthetic harness connect the J.8.10 prepared InstallContext successor context to the live Core, with a stop boundary before any original game/provider code.

Runtime readiness remains **NOT READY TO ENTER**.
