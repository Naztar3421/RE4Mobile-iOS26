# Stage J.8 — ARMv6 synthetic context-restore harness

## Purpose

Stage J.8 consumes the Stage J.7 \`RE4StageJ7CleanupContextPlan\` and projects it into a **local synthetic frame**. The harness then reads that byte array back and emits an immutable data snapshot describing the register slots and the ARMv6 \`BX\` target interpretation.

This stage tests the shape and arithmetic of a possible restore. It does not implement a CPU context switch.

## Synthetic frame layout

The frame is exactly \`0x2C\` bytes and all words are little-endian. Offsets are relative to the J.7 frame base (\`post-prologue SP + 0x18\`), not the function's entry SP.

| Offset | Value | Purpose in the model |
|---:|---|---|
| \`+0x04\` | SetIP dispatch index minus one | SJLJ selector/call-site word; deliberately separate from PC |
| \`+0x08\` | unwind GR0 | Exception pointer supplied by the J.7 plan |
| \`+0x0C\` | unwind GR1 | Zero in the audited #101 profile |
| \`+0x1C\` | LSDA VA | \`0x001C0996\` |
| \`+0x20\` | saved R7 | Readback of the saved frame register |
| \`+0x24\` | saved continuation PC | \`0x000055A8\` for the bounded cleanup profile |
| \`+0x28\` | saved SP | Synthetic restore SP; checked for 8-byte alignment |

The frame bytes are owned by the host test process. They are not backed by \`RE4GuestMemory\`, shared cache, the IPA, or the guest address space.

## Restore snapshot

\`inspectRestore\` reads the seven data words above and returns a value-only \`RE4StageJ8SyntheticRestoreSnapshot\` containing:

- \`unwindGR0\`, \`unwindGR1\`, \`restoredR7\`, and \`restoredSP\`;
- the raw PC operand and the normalized branch address/state;
- explicit negative-scope fields: \`guestInstructionsExecuted = false\`, \`guestMemoryWrites = 0\`, \`cpuContextApplied = false\`, and \`controlTransferPerformed = false\`.

The \`restored*\` names describe what the target provider's frame slots mean; the harness never writes those values into the host CPU or a guest CPU structure.

## ARMv6 BX interpretation

The target provider's disassembly ends the bounded restore sequence with \`BX R0\`. Stage J.8 interprets the saved PC word as the value that would be supplied to BX, without issuing the instruction:

- bit 0 selects the target instruction state: \`1\` means Thumb, \`0\` means ARM;
- a Thumb target address clears bit 0;
- an ARM target must have low bits \`00\`; low bits \`10\` are rejected as UNPREDICTABLE rather than silently rounded down;
- the resulting address must be inside the caller-supplied synthetic interval \`[lowerBound, upperBoundExclusive)\`.

The pinned cleanup target \`0x000055A8\` is even and word-aligned, so it is classified as ARM state. The ARM Architecture Reference Manual, ARM DDI 0100I, describes BX interworking by bit 0 and marks \`Rm[1:0] == 10\` UNPREDICTABLE (A7-32/A7-33). The interval \`[0x5000, 0x6000)\` exists solely for tests; it is not asserted to be the real mapped executable range.

## SP alignment

The harness enforces \`SP % 8 == 0\` for the synthetic restore input. This is a test precondition for the restore snapshot, not a measurement of a live iPhone stack pointer. The tests include both an accepted aligned SP and a rejected \`SP % 8 == 4\` value.

## Test coverage

\`tools/validate-stage-j8.sh\` compiles the J.7 model, J.8 harness and J.8 tests with the host Swift compiler. The 26 tests cover:

1. frame byte count, base alignment, little-endian field readback, GR0/GR1, LSDA and selector separation;
2. R7/SP/PC slot mapping and SP alignment acceptance/rejection;
3. ARM/Thumb state classification, Thumb bit-0 clearing and ARM low-bit \`10\` rejection;
4. inclusive lower and exclusive upper branch bounds for ARM and Thumb, plus UInt32 maximum-address rejection;
5. malformed frame/range rejection and explicit no-execution/no-write/no-transfer invariants;
6. convergence of every nonzero J.7 cleanup selector on \`0x55A8\` in ARM state.

## Results

Host validation: **26/26 passed**.

## Limits and gate state

- This is a host-side synthetic byte-array test only.
- It does not execute ARM/Thumb instructions, \`BX\`, the cleanup trampoline, \`___gxx_personality_sj0\`, SJLJ provider code, callbacks, or pthread TSD operations.
- It does not restore real CPU registers, change CPSR.T, perform an instruction fetch, or write Guest Memory.
- The test code range is supplied by the test, not discovered from a live process mapping. The harness does not decode Thumb instruction widths or prove that a real target instruction is mapped/executable.
- The SP alignment assertion applies only to synthetic test values; it is not evidence of a live stack snapshot.

**Stage J.8 host synthetic validation: PASS. Guest Runtime remains NOT READY.**
