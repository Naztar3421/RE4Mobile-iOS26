# Stage J.8.11 — ARMv6 Core Architectural State Snapshot / Atomic Commit

Date: 2026-11-03

## Scope

J.8.11 connects the J.8.10 immutable forced-Resume projection to the real
RE4GuestARMv6Core through an explicit snapshot and two-phase GPR/NZCV/execution-mode commit.

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
   (including the currently active ARM/Thumb mode) to reject stale tokens;
   then replaces the complete GPR array, NZCV and bounded interpreter mode.
   No throwing operation follows the first assignment.

This is failure-atomic for the Core's single-execution-thread model, not a
cross-thread synchronization primitive. The API does not reset steps,
termination state, Guest Memory or VFP registers.

## Capability gates

- ARM candidate: requires a word-aligned canonical PC.
- Thumb candidate: accepted only for the bounded Thumb-1 interpreter path and
  requires a halfword-aligned canonical PC.
- Complete CPSR restore: rejected.
- Direct D8-D15 injection into the GPR/NZCV commit: rejected.
- D8-D15 restored by #101's target VPOP: accepted only because J.8.12 now
  implements the exact VPUSH/VPOP stack-transfer capability.
- Misaligned PC/SP and malformed register arrays: rejected before mutation.
- Source state changed after preflight: rejected.

The J.8.10-to-J.8.11 bridge carries #101's D8-D15 epilogue obligation forward.
J.8.12 satisfies the VFP stack-transfer portion: the resumed function's own
epilogue restores D8-D15 from Guest Memory. J.8.13/J.8.14 provide bounded
Thumb stepping and in-Core register BX/BLX interworking; this update now lets
the two-phase transaction publish either bounded interpreter mode. This still
does not execute the original provider's BX or apply a live SJLJ context.

## Validation

tools/test-stage-j8-11.swift covers snapshots, GPR/NZCV/mode commits in both
directions, ARM/Thumb PC alignment, post-commit 16-bit Thumb fetch, stale-token
rejection after an execution-mode change, malformed candidates,
CPSR/direct-VFP-restore gates, and J.8.10 obligation propagation (17 cases).

tools/validate-stage-j8-11.sh runs those tests and a Release-mode compile,
then chains to J.8.12's dedicated VFP regression suite.

## Explicitly not delivered

- No complete ARMv6/Thumb instruction set; Thumb support remains the bounded
  subset described by Stage J.8.13.
- No complete CPSR serialization/restoration.
- No execution of the original provider's BX or live provider context transfer.
- No claim that Resident Evil 4 runtime startup is ready.

## Stage J.8.11 mode-aware commit update — 2026-11-04

The current Core already has a bounded Thumb-1 fetch/decode path (J.8.13) and
register-form BX/BLX interworking (J.8.14). This update removes the obsolete
ARM-only transaction gate and extends the opaque preflight token to carry the
validated execution mode.

The transaction now:
- validates ARM PC alignment at four-byte boundaries and Thumb PC alignment
  at two-byte boundaries;
- keeps SP word-alignment validation and all existing GPR/NZCV/VFP/CPSR gates;
- includes the live source execution mode in the stale-token snapshot;
- commits all 16 GPRs, NZCV and the selected bounded ARM/Thumb mode with no
  throwing operation after the first publication;
- reports the committed mode in the receipt.

The updated regression suite passed 17/17 in GitHub Actions Run #212, including
an independent Release-mode compile. The full workflow also passed the J.8.5
umbrella chain (J.8.6-J.8.14), unsigned iOS Release build, IPA packaging and
artifact upload. The post-commit Thumb fetch case writes a synthetic MOVS halfword
to Guest Memory, commits Thumb mode, performs one Core step, and checks R0
plus the two-byte PC advance. This is still a synthetic Core test: no provider
function, original SJLJ BX, callback, pthread operation, or initializer runs.

J.8.10 remains an immutable projection until a separate gated integration
harness explicitly submits one prepared #101 context to the Core and stops
before any original provider/game code. Global runtime readiness remains
NOT READY TO ENTER.


## CI confirmation — 2026-11-04

- GitHub Actions Run [#212](https://github.com/Naztar3421/RE4Mobile-iOS26/actions/runs/41839376228): **SUCCESS**.
- J.8.11 architectural-state suite: **17/17 PASS**.
- J.8.11 Release-mode Swift module compile: **PASS**.
- All preceding MCT, Mach-O, C++ ABI, J.4, J.6, J.7 and J.8-J.8.5 umbrella validations: **PASS**.
- Unsigned iOS app build, IPA packaging and artifact upload: **PASS**.
- Code/test head: `1348642a6de9966a7ffe6fd20dfc4da22819ec4b`.
- IPA artifact ID: `13328820353`; size: 1,014,823 bytes; SHA-256:
  `677444cee5b6359cf38a3aa7f0874b195090e1c146490ce3981f2cb06bf46bb5`.

Test 17 confirms the mode token independently: the ARM and Thumb target candidates
carry identical GPR/NZCV values, and applying the Thumb candidate invalidates
the previously prepared ARM token solely because the active execution mode changed.

This CI success validates the bounded Core state transaction, not execution of
the original provider's BX, pthread TSD, personality, unwinder, or initializer.
Global Guest Runtime readiness remains **NOT READY TO ENTER**.
