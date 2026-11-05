# RE4 Stage J.8.9 — Res4 #101 ARMv6 context-restore preconditions

Date: 2026-11-03
Baseline: pinned iOS 4.2.1 / 8C148 ARMv6 shared cache and supplied Res4 ARMv6 IPA slice
Branch: feature/stage-i-d-lazy-prebind

## Objective

Audit the exact values consumed by the provider's InstallContext path and distinguish those direct restores from the target function's own stack epilogue. This stage creates a data-only preflight contract; it does not implement the Guest CPU context adapter.

## SJLJ frame fields

The provider's frame prefix is 0x2C bytes. The relevant fields are:

| Offset | Meaning | Evidence |
|---:|---|---|
| +0x00 | previous SJLJ frame | Register/phase-2 chain |
| +0x04 | selector / call-site word | GetIP and SetIP helpers |
| +0x08 | personality GR0 | SetGR(context, 0, exception pointer) |
| +0x0C | personality GR1 | SetGR(context, 1, zero) |
| +0x18 | personality function pointer | forced phase-2 callback dispatch |
| +0x1C | LSDA pointer | actual #101 LSDA 0x001C0996 |
| +0x20 | saved R7 | provider LDR R7 |
| +0x24 | continuation PC | provider LDR R0 then BX R0 |
| +0x28 | saved SP | provider LDR SP |

GR0/GR1 are SJLJ personality context slots. They are not aliases for the architectural ARM core registers R0 and R1.

## Actual #101 prologue arithmetic

The ARMv6 words at Res4 VAs 0x5188–0x5198 decode as:

- 0x5188: push {r4,r5,r6,r7,lr}, 0x14 bytes.
- 0x518C: add r7,sp,#12, so R7 = entrySP - 8.
- 0x5190: push {r8,r10,r11}, 0x0C bytes.
- 0x5194: vpush {d8-d15}, 0x40 bytes.
- 0x5198: sub sp,sp,#0x60, 0x60 bytes.

Total stack movement is 0xC0 bytes. Under the AAPCS32 assumption that entry SP is 8-byte aligned, body SP remains 8-byte aligned. The frame base at 0x51A4 is body SP + 0x18. The SJLJ frame stores current R7 at frame+0x20, body SP at frame+0x28 and cleanup continuation 0x55A8 at frame+0x24. Therefore the audited target-specific relations are:

- savedSP = frameBase - 0x18
- savedR7 = savedSP + 0xB8
- savedSP mod 8 = 0

These are strict #101 profile relations, not universal SJLJ frame rules.

## What the provider restores directly

The actual forced phase-2 InstallContext instructions load R7 from frame+0x20, SP from frame+0x28, PC into R0 from frame+0x24, then execute BX R0.

Thus this provider path directly restores only R7, SP and the continuation target. It does not directly reload R4-R6, R8, R10-R11, LR, the general-purpose register file, or a full CPSR image.

For #101, those preserved registers are handled by #101's ordinary prologue/epilogue stack discipline:
- prologue saves R4-R7 and LR, then R8/R10/R11;
- VFP prologue saves D8-D15;
- cleanup continuation 0x55A8 resumes with the saved body SP and frame pointer;
- the #101 epilogue at 0x561C–0x562C rebases SP from R7, restores D8-D15, restores R8/R10/R11, then pops R4-R7 and the saved LR into PC.

The LR is therefore returned through the function's stack epilogue, not through a provider-side LR load. VFP D8-D15 are also restored by the target epilogue, not by the SJLJ provider.

## CPSR and interworking

The final BX uses the raw saved PC operand. Bit 0 selects ARM versus Thumb state; for the actual #101 continuation 0x55A8, bit 0 is zero and the address is ARM-aligned. A generic odd raw pointer such as 0x55A9 is classified as Thumb with normalized address 0x55A8.

This is not restoration of a full saved CPSR. The audited provider sequence has no saved-CPSR load or MSR restore in this InstallContext path. Do not model condition flags as restored by this sequence. BX state selection is an interworking rule, not a full CPSR snapshot restore.

## Preflight model and tests

The host-only preflight checks frame alignment and 32-bit span arithmetic; frame, saved SP and saved R7 stack membership; saved SP 8-byte alignment; #101 frame-base/SP and R7/SP relations; GR0/GR1 and LSDA invariants; BX target state, ARM alignment and executable text range.

The test suite has 11 tests for prologue stack arithmetic, exact R7/SP relations, provider restore scope, stack epilogue inventory, GR0/GR1 meaning, invalid SP alignment, inconsistent R7 relation, #101 ARM target, generic Thumb selection, ARM low-bit rejection, and no-Guest-execution invariants. The validator also cross-checks selected prologue/provider/epilogue words in the evidence CSV and compiles a Release-mode Swift module.

No live CPU state is read or changed. No Guest Memory is written. No BX is executed. The J.8.9 preflight is not a completed Guest context restore adapter. Runtime readiness remains NOT READY TO ENTER.
