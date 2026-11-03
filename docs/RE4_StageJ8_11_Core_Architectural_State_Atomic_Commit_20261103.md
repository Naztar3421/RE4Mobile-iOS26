# Stage J.8.11 — ARMv6 Core Architectural State Snapshot / Atomic Commit

Date: 2026-11-03

## Scope

J.8.11 connects the J.8.10 immutable forced-Resume projection to the real
RE4GuestARMv6Core through an explicit snapshot and a two-phase state commit.

The current Core represents:
- R0–R15 (16 32-bit general-purpose registers)
- N, Z, C and V condition flags
- an ARM-only 32-bit instruction fetch/step path

It does not represent a complete CPSR image. In particular, no values are
invented for CPSR mode, T, interrupt masks, GE, Q, or other unmodeled fields.
A snapshot labels those CPSR fields notRepresentedByCurrentCore; that marker is
a statement about coverage, not a replacement bit pattern.

VFP D8–D15 are not part of the snapshot. The current vpush {d8-d15} and
vpop {d8-d15} handlers only adjust SP and do not transfer the register payload
to or from Guest Memory. The snapshot therefore records
d8ThroughD15NotCaptured.

## Two-phase commit

1. captureArchitecturalStateSnapshot() reads the live 16 GPRs and NZCV into an
   immutable, validated value.
2. prepareArchitecturalStateCommit(_:) validates the entire candidate:
   exactly 16 registers, ARM word-aligned PC, word-aligned SP, ARM-only mode,
   modeled-NZCV-only CPSR policy, and no D8–D15 restore requirement. It changes
   no live Core field.
3. commitArchitecturalStateAtomically(_:) compares the live state against the
   preflight source snapshot to reject stale plans. Only after that check does
   it replace the complete GPR array and four condition flags. No throwing
   operation follows the first assignment.

The apply phase is failure-atomic for the Core's single-execution-thread model.
It is not a cross-thread synchronization primitive; the Core is not otherwise
thread-safe. Steps, termination state, memory, and VFP registers are not reset
or modified by this commit API.

## Capability gates

- Thumb candidate: rejected (thumbExecutionUnsupported).
- Complete CPSR restore: rejected (fullCPSRRestoreUnsupported).
- D8–D15 restore: rejected (vfpD8ThroughD15RestoreUnsupported).
- Misaligned PC/SP and malformed register arrays: rejected before mutation.
- Source state changed after preflight: rejected (sourceStateChangedBeforeCommit).

The J.8.10-to-J.8.11 bridge carries the target mode and #101's D8–D15 epilogue
obligation forward. Therefore the actual #101 context is still blocked from
live commit while the existing VFP pop path is incomplete. This is intentional:
the stage proves a safe generic ARM GPR/NZCV commit contract, not a runnable
#101 handoff.

## Validation

tools/test-stage-j8-11.swift covers snapshot capture, NZCV, absent CPSR/VFP
coverage, successful full GPR/NZCV apply, malformed candidates, Thumb/CPSR/VFP
gates, stale-source rejection, and propagation of the J.8.10 #101 obligations.

tools/validate-stage-j8-11.sh runs the tests and a Release-mode compile.
The workflow reaches this validator through the existing J.8.5 through J.8.10
validation chain.

## Explicitly not delivered

- No Thumb instruction decoder or CPSR.T implementation.
- No complete CPSR serialization/restoration.
- No VFP D8–D15 load/store implementation.
- No execution of the provider BX, no Guest instruction execution, and no
  claim that Resident Evil 4 runtime startup is ready.
