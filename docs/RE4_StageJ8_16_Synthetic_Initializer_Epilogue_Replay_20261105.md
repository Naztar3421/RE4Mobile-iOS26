# RE4 Stage J.8.16 — Synthetic #101 initializer epilogue replay

Date: 2026-11-05  
Target evidence: Res4 / iOS 4.2.1 / 8C148 / ARMv6, initializer #101  
Baseline: J.8.11 mode-aware transaction, J.8.12 D8-D15 stack transfer, J.8.13 Thumb-1 subset, J.8.14 BX/BLX, J.8.15 synthetic InstallContext-to-Core application

## Evidence-bound instruction sequence

The five epilogue words below are taken from
`tools/fixtures/RE4_StageJ8_9_Res4_Context_Restore_Evidence.csv`:

| VA | Word | Audited operation |
|---|---:|---|
| 0x561C | E247D058 | `sub sp,r7,#0x58` |
| 0x5620 | ECBD8B10 | `vpop {d8-d15}` |
| 0x5624 | E247D018 | `sub sp,r7,#0x18` |
| 0x5628 | E8BD0D00 | `pop {r8,r10,r11}` |
| 0x562C | E8BD80F0 | `pop {r4,r5,r6,r7,pc}` |

The tested stack geometry follows the evidence:
- frame base = 0x8000;
- saved body SP = 0x7FE8;
- saved R7/frame pointer = 0x80A0;
- VFP save block begins at R7-0x58 = 0x8048 and contains 64 bytes;
- extended core save block begins at R7-0x18 = 0x8088;
- original R4-R7/LR save block begins at 0x8094;
- entry SP after the final five-word POP is 0x80A8.

The final saved LR word is consumed by `POP {...,pc}` as the caller PC. The LR register itself is not restored by that instruction.

## Harness

The test creates a fresh synthetic Guest Memory. It writes the five audited instruction words and corresponding synthetic stack payloads; no original Res4 image or IPA bytes are mapped.

The Core then executes each instruction with a separate `step()`, checking the SP after each rebase/pop, all eight restored D registers, R8/R10/R11, R4-R7, PC and final entry SP. A hook at the synthetic caller PC stops execution before any caller instruction fetch. A second case protects the VFP save range against reads and confirms a failed VPOP leaves the D8-D15 bank and rebased SP unchanged.

## Test cases

1. Full ordered #101 epilogue replay through the final POP and stop hook.
2. VPOP read failure is fail-closed for the VFP bank and SP publication.

The validator also matches every tested epilogue word against the checked-in evidence CSV and compiles a Release-mode Swift module.

## Hard boundaries

- This is an instruction replay in synthetic Guest Memory, not execution of the original function bytes.
- It does not call the provider BX, SJLJ Resume, personality, stop callback, pthread API/TSD, destructor, callback, or initializer.
- It does not read the original IPA or execute the caller's code.
- The Core's bounded instruction subset and modeled NZCV are not a complete ARMv6/CPSR implementation.
- Overall Guest Runtime readiness remains **NOT READY TO ENTER**.

