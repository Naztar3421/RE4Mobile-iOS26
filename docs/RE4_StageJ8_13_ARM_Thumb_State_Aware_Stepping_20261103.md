# RE4 Stage J.8.13 — ARM/Thumb state-aware instruction stepping

Date: 2026-11-03  
Target: Res4 / iOS 4.2.1 / 8C148 / ARMv6  
Baseline: current branch HEAD before this stage, J.8.11 architectural snapshots, J.8.12 VFP D8-D15 stack transfers

## Decision

The Guest Core now has an explicit current instruction-set state and selects instruction fetch width and decode path from that state. ARM execution remains 32-bit. Thumb execution uses a 16-bit fetch path, a halfword-aligned canonical PC, and advances by two bytes per instruction.

This stage introduced a deliberately bounded Thumb-1 subset. J.8.14 subsequently adds BX/BLX-register interworking, but the Core is still not a complete ARMv6 Thumb emulator and does not apply live SJLJ contexts.

## Implemented

- `RE4GuestARMv6Memory.readInstruction16` reads exactly two bytes and requires execute permission, parallel to the existing 32-bit instruction fetch.
- `RE4GuestARMv6Core.instructionSetState` records ARM or Thumb independently from the canonical PC.
- `run(entry:initialInstructionSetState:)` explicitly chooses the initial instruction set and validates word alignment for ARM or halfword alignment for Thumb. It does not infer a state transition from an odd address.
- ARM stepping fetches 32-bit instructions and advances sequential PC by four.
- Thumb stepping fetches 16-bit instructions and advances sequential PC by two.
- The modeled PC operand value is state-sensitive: ARM `PC+8`; Thumb `Align(PC+4, 4)`.
- The implemented Thumb-1 subset is:
  - `MOVS Rd,#imm8`
  - `CMP Rd,#imm8`
  - `ADDS Rd,#imm8`
  - `SUBS Rd,#imm8`
  - PC-relative literal `LDR Rt,[PC,#imm8*4]`
  - unconditional `B label`
  - conditional `B<cond> label` for conditions EQ through LE
- ADD/CMP update the modeled NZCV flags; MOVS updates N/Z while preserving C/V.
- Branch displacement sign extension and PC+4-relative target calculation are covered by tests.
- J.8.11 architectural snapshots now report the current execution mode and validate canonical PC alignment according to ARM or Thumb. The separate J.8.11 live-state commit transaction remains ARM-only.
- The J.8.10 capability report now marks bounded Thumb instruction stepping as present.

## Deliberately not implemented

- At the original J.8.13 baseline, Thumb BX/BLX-register interworking and ARM-to-Thumb transitions were absent. These are implemented by the follow-on J.8.14 stage with explicit alignment and encoding gates.
- Thumb wide/32-bit encodings, the full Thumb-1 data-processing/load-store/stack instruction set, exception entry/return, IT state, or full CPSR.
- Any live application of a prepared SJLJ context.
- Execution of the original Res4 initializer #101 or any original game/provider callback.

J.8.14 supersedes the former fail-closed-only behavior with actual register-branch state publication. The J.8.13 baseline tests are retained in the chain and now assert that BX state selection executes correctly.

## Validation

A dedicated 13-case host regression suite covers:

1. exact 16-bit fetch at a boundary where a 32-bit fetch would overrun;
2. Thumb sequential PC advance by two;
3. MOVS/ADDS/SUBS/CMP immediate behavior and NZCV;
4. 32-bit signed-overflow/carry behavior;
5. taken and untaken conditional branches;
6. signed backward unconditional branch displacement;
7. ARM word-aligned and Thumb halfword-aligned entry preconditions;
8. execute-permission enforcement on Thumb fetch;
9. Thumb BX decoding and same-state target execution;
10. ARM BX to Thumb with state publication and target instruction execution;
11. preserved ARM 32-bit instruction stepping;
12. explicit Thumb state in the run result and architectural snapshot;
13. Thumb literal-load PC alignment via `Align(PC+4,4)`.

The validator runs the host tests and separately compiles the production sources without `RE4_HOST_TESTING`.

## Readiness

Thumb stepping is now available only for the listed subset and only when Thumb is explicitly selected as the initial run state. The Core's register BX/BLX interworking is implemented in J.8.14; J.8.11's live architectural-state commit remains ARM-only. No provider BX, stop callback, Guest context restore, or original game code has been executed.

Runtime readiness remains **NOT READY TO ENTER**.
