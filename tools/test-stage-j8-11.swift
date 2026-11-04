import Foundation

@main
struct StageJ811CoreArchitecturalStateTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw NSError(domain: "J8.11", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    static func makeCore() -> RE4GuestARMv6Core {
        RE4GuestARMv6Core(memory: RE4GuestARMv6Memory(
            size: 0x20000, heapBase: 0x10000,
            stackTop: 0x1F000, returnSentinel: 0xFFF000
        ))
    }

    static func seedCore(_ core: RE4GuestARMv6Core) throws {
        for index in 0..<16 {
            try core.setRegisterValue(index, value: UInt32(0x1000 + index * 0x10))
        }
        try core.setRegisterValue(13, value: 0x1F000)
        try core.setRegisterValue(15, value: 0x1000)
    }

    static func makeCandidate(
        mode: RE4StageJ811ExecutionMode = .arm32Interpreter,
        cpsr: RE4StageJ811CPSRRestoreRequest = .modeledNZCVOnly,
        vfp: RE4StageJ811VFPRestoreRequirement = .notRequired,
        pc: UInt32 = 0x2000,
        sp: UInt32 = 0x1E000,
        count: Int = 16
    ) -> RE4StageJ811CPUStateCandidate {
        var registers = (0..<count).map { UInt32(0xA000 + $0 * 0x20) }
        if count > 13 { registers[13] = sp }
        if count > 15 { registers[15] = pc }
        return RE4StageJ811CPUStateCandidate(
            registers: registers,
            flags: RE4StageJ811ConditionFlags(
                negative: true, zero: true, carry: false, overflow: true
            ),
            executionMode: mode,
            cpsrRestoreRequest: cpsr,
            vfpRestoreRequirement: vfp
        )
    }

    static func makeJ810Frame(pc: UInt32 = 0x55A8) throws -> RE4StageJ89SJLJFrame {
        var frame = try RE4StageJ89SJLJFrame(baseAddress: 0x8000)
        try frame.storeWord(at: 0x08, value: 0xA0F00000)
        try frame.storeWord(at: 0x0C, value: 0)
        try frame.storeWord(at: 0x1C, value: 0x001C0996)
        try frame.storeWord(at: 0x20, value: 0x80A0)
        try frame.storeWord(at: 0x24, value: pc)
        try frame.storeWord(at: 0x28, value: 0x7FE8)
        return frame
    }

    static func makeJ810Source() throws -> RE4StageJ810ArchitecturalState {
        var registers = (0..<16).map { UInt32(0x1000 + $0 * 0x10) }
        registers[4] = 0x8000
        registers[15] = 0x358CF8DC
        return try RE4StageJ810ArchitecturalState(
            registers: registers,
            flags: RE4StageJ810ConditionFlags(
                negative: true, zero: false, carry: true, overflow: true
            ),
            instructionState: .arm
        )
    }

    static func main() throws {
        var passed = 0
        func test(_ name: String, _ body: () throws -> Void) throws {
            try body()
            passed += 1
            print("PASS: \(name)")
        }

        try test("01 Core captures exactly 16 GPRs and the modeled NZCV flags") {
            let core = makeCore()
            try seedCore(core)
            try core.memory.write32(0x1000, 0xE3B00000) // MOVS R0,#0
            _ = try core.step()
            let snapshot = try core.captureArchitecturalStateSnapshot()
            try check(snapshot.registers.count == 16, "snapshot must contain R0-R15")
            try check(snapshot.flags.zero && !snapshot.flags.negative,
                      "MOVS R0,#0 should set Z and clear N")
            try check(snapshot.executionMode == .arm32Interpreter,
                      "snapshot must identify the active ARM execution mode")
        }

        try test("02 Unmodeled CPSR and VFP fields are explicitly absent, not zero-filled") {
            let core = makeCore()
            let snapshot = try core.captureArchitecturalStateSnapshot()
            try check(snapshot.unmodeledCPSRState == .notRepresentedByCurrentCore,
                      "unknown CPSR fields must remain unrepresented")
            try check(snapshot.vfpStateCoverage == .d8ThroughD15NotCaptured,
                      "D8-D15 must not be synthesized")
        }

        try test("03 Full candidate preflight then commit updates all GPRs and NZCV") {
            let core = makeCore()
            try seedCore(core)
            let candidate = makeCandidate()
            let beforeSteps = core.steps
            let prepared = try core.prepareArchitecturalStateCommit(candidate)
            let receipt = try core.commitArchitecturalStateAtomically(prepared)
            let after = try core.captureArchitecturalStateSnapshot()
            try check(after.registers == candidate.registers,
                      "all 16 GPRs must match the validated candidate")
            try check(after.flags == candidate.flags, "NZCV must match the candidate")
            try check(receipt.committedGeneralRegisterCount == 16 &&
                      receipt.committedNZCV &&
                      receipt.committedExecutionMode == .arm32Interpreter,
                      "commit receipt must describe GPR, NZCV and ARM-mode writes")
            try check(!receipt.restoredFullCPSR &&
                      !receipt.restoredVFPD8ThroughD15 &&
                      !receipt.guestInstructionsExecuted,
                      "receipt must not claim unsupported state or Guest execution")
            try check(core.steps == beforeSteps, "state commit must not execute an instruction")
        }

        try test("04 Invalid register count is rejected before any live mutation") {
            let core = makeCore()
            try seedCore(core)
            let before = try core.captureArchitecturalStateSnapshot()
            do {
                _ = try core.prepareArchitecturalStateCommit(makeCandidate(count: 15))
                throw NSError(domain: "J8.11", code: 2)
            } catch RE4StageJ811CommitError.invalidRegisterFileCount(15) { }
            let after = try core.captureArchitecturalStateSnapshot()
            try check(after == before,
                      "invalid candidate partially changed the core")
        }

        try test("05 Unaligned PC is rejected before commit") {
            let core = makeCore()
            try seedCore(core)
            let before = try core.captureArchitecturalStateSnapshot()
            do {
                _ = try core.prepareArchitecturalStateCommit(makeCandidate(pc: 0x2002))
                throw NSError(domain: "J8.11", code: 3)
            } catch RE4StageJ811CommitError.programCounterNotWordAligned(0x2002) { }
            let after = try core.captureArchitecturalStateSnapshot()
            try check(after == before,
                      "unaligned PC changed the source state")
        }

        try test("06 Unaligned SP is rejected before commit") {
            let core = makeCore()
            try seedCore(core)
            let before = try core.captureArchitecturalStateSnapshot()
            do {
                _ = try core.prepareArchitecturalStateCommit(makeCandidate(sp: 0x1E002))
                throw NSError(domain: "J8.11", code: 4)
            } catch RE4StageJ811CommitError.stackPointerNotWordAligned(0x1E002) { }
            let after = try core.captureArchitecturalStateSnapshot()
            try check(after == before,
                      "unaligned SP changed the source state")
        }

        try test("07 Thumb candidate preflight accepts halfword-aligned PC without mutation") {
            let core = makeCore()
            try seedCore(core)
            let before = try core.captureArchitecturalStateSnapshot()
            let prepared = try core.prepareArchitecturalStateCommit(
                makeCandidate(mode: .thumb16Required, pc: 0x2002))
            try check(prepared.executionMode == .thumb16Required,
                      "validated token lost the requested Thumb execution mode")
            let after = try core.captureArchitecturalStateSnapshot()
            try check(after == before,
                      "preflight changed live Core state")
            do {
                _ = try core.prepareArchitecturalStateCommit(
                    makeCandidate(mode: .thumb16Required, pc: 0x2003))
                throw NSError(domain: "J8.11", code: 5)
            } catch RE4StageJ811CommitError.programCounterNotWordAligned(0x2003) { }
            try check(try core.captureArchitecturalStateSnapshot() == before,
                      "invalid Thumb PC changed the source state")
        }

        try test("08 Full CPSR restore request is rejected without inventing missing fields") {
            let core = makeCore()
            try seedCore(core)
            let before = try core.captureArchitecturalStateSnapshot()
            do {
                _ = try core.prepareArchitecturalStateCommit(
                    makeCandidate(cpsr: .fullCPSR))
                throw NSError(domain: "J8.11", code: 6)
            } catch RE4StageJ811CommitError.fullCPSRRestoreUnsupported { }
            let after = try core.captureArchitecturalStateSnapshot()
            try check(after == before,
                      "full-CPSR rejection changed the source state")
        }

        try test("09 D8-D15 restore requirement is rejected by the explicit VFP gate") {
            let core = makeCore()
            try seedCore(core)
            let before = try core.captureArchitecturalStateSnapshot()
            do {
                _ = try core.prepareArchitecturalStateCommit(
                    makeCandidate(vfp: .d8ThroughD15RequiredInCPUContext))
                throw NSError(domain: "J8.11", code: 7)
            } catch RE4StageJ811CommitError.vfpD8ThroughD15RestoreUnsupported { }
            let after = try core.captureArchitecturalStateSnapshot()
            try check(after == before,
                      "VFP rejection changed the source state")
        }

        try test("10 Prepared transaction is rejected if the Core changed before apply") {
            let core = makeCore()
            try seedCore(core)
            let prepared = try core.prepareArchitecturalStateCommit(makeCandidate())
            try core.setRegisterValue(2, value: 0xDEADBEEF)
            let changed = try core.captureArchitecturalStateSnapshot()
            do {
                _ = try core.commitArchitecturalStateAtomically(prepared)
                throw NSError(domain: "J8.11", code: 8)
            } catch RE4StageJ811CommitError.sourceStateChangedBeforeCommit { }
            let after = try core.captureArchitecturalStateSnapshot()
            try check(after == changed,
                      "stale transaction overwrote newer Core state")
        }

        try test("11 J.8.10 #101 projection carries its D8-D15 epilogue obligation") {
            let core = makeCore()
            try seedCore(core)
            let frame = try makeJ810Frame()
            let stack = try RE4StageJ89AddressRange(
                lowerBound: 0x7000, upperBoundExclusive: 0x9000)
            let code = try RE4StageJ89AddressRange(
                lowerBound: 0x5000, upperBoundExclusive: 0x6000)
            let planned = try RE4StageJ810GuestCPUContextAdapter.prepareForcedInstallContext(
                current: makeJ810Source(), frame: frame,
                stackRange: stack, codeRange: code)
            let candidate = RE4StageJ811CPUStateCandidate.from(preparedContext: planned)
            try check(candidate.executionMode == .arm32Interpreter &&
                      candidate.vfpRestoreRequirement == .d8ThroughD15RequiredByGuestEpilogue,
                      "#101 VFP obligation must be delegated to its target epilogue")
            _ = try core.prepareArchitecturalStateCommit(candidate)
            try check(core.supportsVFPD8ThroughD15StackTransfers,
                      "Core must implement the epilogue's VFP stack path")
        }

        try test("12 J.8.10 Thumb projection produces a valid mode-aware candidate") {
            let core = makeCore()
            try seedCore(core)
            let before = try core.captureArchitecturalStateSnapshot()
            let frame = try makeJ810Frame(pc: 0x55A9)
            let stack = try RE4StageJ89AddressRange(
                lowerBound: 0x7000, upperBoundExclusive: 0x9000)
            let code = try RE4StageJ89AddressRange(
                lowerBound: 0x5000, upperBoundExclusive: 0x6000)
            let planned = try RE4StageJ810GuestCPUContextAdapter.prepareForcedInstallContext(
                current: makeJ810Source(), frame: frame,
                stackRange: stack, codeRange: code)
            let candidate = RE4StageJ811CPUStateCandidate.from(preparedContext: planned)
            try check(candidate.executionMode == .thumb16Required,
                      "Thumb state was lost during J.8.10 to J.8.11 handoff")
            let prepared = try core.prepareArchitecturalStateCommit(candidate)
            try check(prepared.executionMode == .thumb16Required,
                      "Thumb mode was not carried into the validated commit token")
            try check(try core.captureArchitecturalStateSnapshot() == before,
                      "J.8.10 candidate preflight changed live Core state")
        }

        try test("13 Core snapshot refuses malformed live PC rather than normalizing it") {
            let core = makeCore()
            try seedCore(core)
            try core.setRegisterValue(15, value: 0x1002)
            do {
                _ = try core.captureArchitecturalStateSnapshot()
                throw NSError(domain: "J8.11", code: 11)
            } catch RE4StageJ811CommitError.programCounterNotWordAligned(0x1002) { }
        }

        try test("14 Atomic commit changes ARM Core to Thumb mode together with GPR/NZCV") {
            let core = makeCore()
            try seedCore(core)
            let candidate = makeCandidate(mode: .thumb16Required, pc: 0x2002)
            let prepared = try core.prepareArchitecturalStateCommit(candidate)
            try check(core.instructionSetState == .arm,
                      "preflight changed the live instruction-set state")
            let receipt = try core.commitArchitecturalStateAtomically(prepared)
            let after = try core.captureArchitecturalStateSnapshot()
            try check(core.instructionSetState == .thumb &&
                      after.executionMode == .thumb16Required &&
                      after.pc == 0x2002,
                      "ARM-to-Thumb mode/PC commit did not publish together")
            try check(after.registers == candidate.registers &&
                      after.flags == candidate.flags &&
                      receipt.committedExecutionMode == .thumb16Required,
                      "Thumb mode commit did not include the complete GPR/NZCV candidate")
            try check(!receipt.restoredFullCPSR &&
                      !receipt.restoredVFPD8ThroughD15 &&
                      !receipt.guestInstructionsExecuted,
                      "Thumb mode receipt overstated CPSR, VFP or Guest execution")
        }

        try test("15 Atomic commit switches a Thumb Core back to ARM mode") {
            let core = makeCore()
            try seedCore(core)
            let thumb = try core.prepareArchitecturalStateCommit(
                makeCandidate(mode: .thumb16Required, pc: 0x2002))
            _ = try core.commitArchitecturalStateAtomically(thumb)
            let armCandidate = makeCandidate(mode: .arm32Interpreter, pc: 0x3000)
            let arm = try core.prepareArchitecturalStateCommit(armCandidate)
            let receipt = try core.commitArchitecturalStateAtomically(arm)
            let after = try core.captureArchitecturalStateSnapshot()
            try check(core.instructionSetState == .arm &&
                      after.executionMode == .arm32Interpreter &&
                      after.pc == 0x3000,
                      "Thumb-to-ARM mode/PC commit failed")
            try check(receipt.committedExecutionMode == .arm32Interpreter,
                      "receipt did not report the committed ARM mode")
        }

        try test("16 A committed Thumb mode uses 16-bit instruction fetch and Thumb PC advance") {
            let core = makeCore()
            try seedCore(core)
            try core.memory.write16(0x2002, 0x2007) // MOVS R0,#7
            let thumb = try core.prepareArchitecturalStateCommit(
                makeCandidate(mode: .thumb16Required, pc: 0x2002))
            _ = try core.commitArchitecturalStateAtomically(thumb)
            _ = try core.step()
            let after = try core.captureArchitecturalStateSnapshot()
            try check(try core.registerValue(0) == 7,
                      "Thumb MOVS did not execute after the mode-aware commit")
            try check(after.executionMode == .thumb16Required && after.pc == 0x2004,
                      "Thumb fetch must advance the canonical PC by two bytes")
            try check(!after.flags.zero && !after.flags.negative,
                      "Thumb MOVS must update the modeled N/Z flags")
        }

        try test("17 Prepared token becomes stale when only the execution mode changes") {
            let core = makeCore()
            try seedCore(core)
            let staleARM = try core.prepareArchitecturalStateCommit(
                makeCandidate(mode: .arm32Interpreter, pc: 0x3000))
            let toThumb = try core.prepareArchitecturalStateCommit(
                makeCandidate(mode: .thumb16Required, pc: 0x2002))
            _ = try core.commitArchitecturalStateAtomically(toThumb)
            let changed = try core.captureArchitecturalStateSnapshot()
            do {
                _ = try core.commitArchitecturalStateAtomically(staleARM)
                throw NSError(domain: "J8.11", code: 12)
            } catch RE4StageJ811CommitError.sourceStateChangedBeforeCommit { }
            try check(try core.captureArchitecturalStateSnapshot() == changed &&
                      core.instructionSetState == .thumb,
                      "stale ARM token overwrote a newer Thumb execution state")
        }

        print("RESULT: \(passed)/17 passed; 0 failed")
        print("SCOPE: real Core snapshot + two-phase failure-atomic GPR/NZCV and ARM/Thumb-mode commit; no full CPSR, no CPU-context VFP injection, and no provider/Res4 BX execution.")
    }
}
