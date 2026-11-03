# Stage J.8.11 — ARMv6 Core Architectural State Snapshot / Atomic Commit

Date: 2026-11-03

## Scope

J.8.11 connects the J.8.10 immutable forced-Resume projection to the real
RE4GuestARMv6Core through an explicit snapshot and two-phase GPR/NZCV commit.

The Core snapshot represents R0-R15 and N/Z/C/V. It does not claim a complete
CPSR image. Unmodeled CPSR fields are explicitly marked as not represented.
VFP D8-D15 remain outside this GPR/NZCV snapshot, which records
d8ThroughD15NotCaptured; J.8.12 supplies a separate typed VFP bank snapshot
and the target function's actual VPUSH/VPOP stack transfer instructions.

## Two-phase commit

1. captureArchitecturalStateSnapshot() captures the live GPRs and NZCV.
2. prepareArchitecturalStateCommit(_:) validates the entire candidate and
   returns an opaque commit token without mutating the Core.
3. commitArchitecturalStateAtomically(_:) compares the exact source snapshot
   to reject stale tokens; then replaces the complete GPR array and NZCV.
   No throwing operation follows the first assignment.

This is failure-atomic for the Core's single-execution-thread model, not a
cross-thread synchronization primitive. The API does not reset steps,
termination state, Guest Memory or VFP registers.

## Capability gates

- Thumb candidate: rejected until a Thumb execution path exists.
- Complete CPSR restore: rejected.
- Direct D8-D15 injection into the GPR/NZCV commit: rejected.
- D8-D15 restored by #101's target VPOP: accepted only because J.8.12 now
  implements the exact VPUSH/VPOP stack-transfer capability.
- Misaligned PC/SP and malformed register arrays: rejected before mutation.
- Source state changed after preflight: rejected.

The J.8.10-to-J.8.11 bridge carries #101's D8-D15 epilogue obligation forward.
J.8.12 satisfies the VFP stack-transfer portion: the resumed function's own
epilogue restores D8-D15 from Guest Memory. Thumb and provider BX/context
application remain independent blockers.

## Validation

tools/test-stage-j8-11.swift covers snapshots, GPR/NZCV commit, malformed
candidates, Thumb/CPSR/direct-VFP-restore gates, stale-token rejection, and
J.8.10 obligation propagation.

tools/validate-stage-j8-11.sh runs those tests and a Release-mode compile,
then chains to J.8.12's dedicated VFP regression suite.

## Explicitly not delivered

- No Thumb decoder or Thumb execution.
- No complete CPSR serialization/restoration.
- No BX execution or live provider context transfer.
- No claim that Resident Evil 4 runtime startup is ready.
