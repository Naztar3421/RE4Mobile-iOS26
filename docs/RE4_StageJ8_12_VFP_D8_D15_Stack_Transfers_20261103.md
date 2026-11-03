# Stage J.8.12 — ARMv6 VFP D8-D15 stack payload transfers

Date: 2026-11-03
Target: Res4 initializer #101, iOS 4.2.1 / 8C148 / ARMv6

## Purpose

The #101 disassembly audit identifies the prologue save at 0x5194 using
instruction 0xED2D8B10 and the epilogue restore at 0x5620 using 0xECBD8B10.
Before this stage the Guest Core handled these opcodes by adjusting SP only,
losing all eight 64-bit values.

## Implemented semantics

- D8-D15 map to S16-S31, two consecutive 32-bit words per D register.
- VPUSH {D8-D15} (0xED2D8B10) performs VSTMDB SP!, saving D8 through D15 in
  ascending register order at the new SP. Each double is stored low word then
  high word in little-endian Guest Memory.
- VPOP {D8-D15} (0xECBD8B10) performs VLDMIA SP!, reads the complete 64-byte
  range, stages all sixteen S words, then publishes the VFP bank and SP.
- A separate VFP snapshot/restore API captures exactly eight 64-bit values.
  The J.8.11 GPR/NZCV snapshot remains separate and does not claim VFP coverage.
- Stack-pointer arithmetic checks underflow/overflow. VPUSH uses one contiguous
  64-byte Guest Memory write before updating SP. VPOP copies and decodes all
  64 bytes before updating VFP/SP.
- Dense and sparse Guest Memory stacks use the same bounds/protection-aware API.

## J.8.11 context-commit integration

The J.8.10 adapter's #101 D8-D15 obligation is no longer interpreted as a
request to inject VFP values into the GPR/NZCV commit token. The bridge records
d8ThroughD15RequiredByGuestEpilogue, which the Core accepts only while its
exact stack-transfer capability is implemented. Direct D8-D15 CPU-context
injection remains rejected.

This follows #101 control flow: the unwinder restores R7/SP/PC; the resumed
function's own epilogue executes VPOP to restore its callee-saved VFP bank.

## Validation

tools/test-stage-j8-12.swift validates mapping/fidelity, VPUSH memory order,
VPOP restoration, full instruction-path round trip, failed memory transfer
state preservation, sparse-stack support, arithmetic overflow/underflow,
register accessor bounds, and malformed VFP snapshot shape.

tools/validate-stage-j8-12.sh runs the tests and a Release-mode Swift module
compile. It is chained after J.8.11 within the existing J.8.5 CI umbrella.

## Not delivered

- No Thumb decoder or execution.
- No BX/BLX interworking or provider context application.
- No full CPSR implementation.
- No invocation of the original #101 initializer, exception provider,
  callback, or original game instruction stream.
- Overall runtime readiness remains NOT READY TO ENTER.
