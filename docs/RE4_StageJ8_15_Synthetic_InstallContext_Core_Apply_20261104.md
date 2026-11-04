# RE4 Stage J.8.15 — Synthetic #101 InstallContext Core application gate

Date: 2026-11-04  
Target: Res4 / iOS 4.2.1 / 8C148 / ARMv6, ExtraProductList initializer #101  
Baseline: J.8.10 immutable forced-Resume projection, J.8.11 mode-aware Core transaction, J.8.12 VFP stack transfers, J.8.13 bounded Thumb-1 stepping, J.8.14 BX/BLX interworking

## Decision

J.8.15 is a **synthetic-only integration gate** between the J.8.10 prepared successor context and the bounded `RE4GuestARMv6Core`. It deliberately leaves the J.8.10 adapter data-only. The test builds the immutable projection, converts it into a J.8.11 candidate, preflights and commits it, and then executes exactly one test-authored marker instruction in the selected mode. An instruction hook stops at the next PC before any further fetch.

This proves only the controlled Core handoff and bounded ARM/Thumb execution path. It does not run the original provider BX, Res4 code, or any application initializer.

## Harness flow

1. Construct a synthetic #101-shaped frame at `0x8000` with GR0/GR1, LSDA, saved R7, continuation PC and saved SP matching the pinned J.8.9 preconditions.
2. Construct a 16-register ARM source state with R4 identifying that frame.
3. Call `RE4StageJ810GuestCPUContextAdapter.prepareForcedInstallContext`. Assert the returned projection is immutable data: no Guest instruction, no Guest Memory write, no CPU mutation and no BX.
4. Convert the projection with `RE4StageJ811CPUStateCandidate.from(preparedContext:)`.
5. Call `prepareArchitecturalStateCommit`, confirm no live Core field changed, then apply with `commitArchitecturalStateAtomically`.
6. Install one **synthetic** marker instruction at the continuation VA `0x55A8` in the test's otherwise empty Guest Memory:
   - ARM case: A32 `MOV R2,#0x2A` (`0xE3A0202A`), followed by a stop hook at `0x55AC`.
   - Thumb case: T16 `MOVS R2,#0x2A` (`0x222A`), followed by a stop hook at `0x55AA`.
7. Execute the marker and invoke the stop hook on the next `step()`; assert no instruction after the marker is fetched.

The test writes only its own marker bytes to a fresh synthetic Guest Memory. It does not load the original Res4 image or IPA at these addresses. The real #101 continuation address is used only as an address/profile anchor; the bytes at that address in this test are synthetic instructions.

## Validation cases

| Case | Assertion |
|---|---|
| 01 | ARM projection commits R0/R7/SP/PC/NZCV and ARM mode; one A32 marker executes; hook stops before the next fetch |
| 02 | Thumb projection retains raw odd BX operand in R0, canonicalizes PC, commits Thumb mode; one T16 marker executes; hook stops before the next fetch |
| 03 | R4/frame identity mismatch is rejected before any Core mutation |
| 04 | Unpredictable ARM BX operand with low bits `10` is rejected before any Core mutation |

The J.8.11 transaction continues to enforce its existing gates: 16 GPRs, PC alignment for the selected mode, word-aligned SP, modeled NZCV only, and D8-D15 restoration by the target epilogue's implemented stack path. It does not inject VFP data into the GPR/NZCV/mode commit.

## Validation scope and hard boundaries

- J.8.10 remains an immutable, data-only provider successor-state projection.
- J.8.11 performs the modeled register/flag/mode transaction, with no Guest instruction executed during commit.
- J.8.15 separately executes one generated ARM or Thumb marker in synthetic memory, then stops before the next fetch.
- No original provider function, provider BX, SJLJ Resume, personality, stop callback, pthread API/TSD, destructor, callback, or initializer is called.
- No original IPA or game code bytes are mapped or executed.
- Full CPSR, complete ARMv6/Thumb instruction coverage, and whole-game startup remain out of scope.

Overall Guest Runtime readiness remains **NOT READY TO ENTER**.

