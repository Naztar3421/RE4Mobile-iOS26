import Foundation

@main
struct StageJ815SyntheticInstallContextCoreApplyTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw NSError(domain: "J8.15", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    static func makeFrame(rawContinuationPC: UInt32) throws -> RE4StageJ89SJLJFrame {
        var frame = try RE4StageJ89SJLJFrame(baseAddress: 0x8000)
        try frame.storeWord(at: 0x08, value: 0xA0F00000) // nonzero exception object
        try frame.storeWord(at: 0x0C, value: 0)          // #101 GR1
        try frame.storeWord(at: 0x1C, value: 0x001C0996) // pinned LSDA
        try frame.storeWord(at: 0x20, value: 0x80A0)     // saved R7
        try frame.storeWord(at: 0x24, value: rawContinuationPC)
        try frame.storeWord(at: 0x28, value: 0x7FE8)     // saved SP
        return frame
    }

    static func makeCurrentState(frameAddress: UInt32 = 0x8000) throws -> RE4StageJ810ArchitecturalState {
        var registers = (0..<16).map { UInt32(0x1000 + $0 * 0x10) }
        registers[4] = frameAddress
        registers[13] = 0x1F000
        registers[15] = 0x4000
        return try RE4StageJ810ArchitecturalState(
            registers: registers,
            flags: RE4StageJ810ConditionFlags(
                negative: false, zero: false, carry: false, overflow: false
            ),
            instructionState: .arm
        )
    }

    static func makeCore(
        memory: RE4GuestARMv6Memory,
        matching state: RE4StageJ810ArchitecturalState
    ) throws -> RE4GuestARMv6Core {
        let core = RE4GuestARMv6Core(memory: memory)
        for index in 0..<16 {
            try core.setRegisterValue(index, value: state.registers[index])
        }
        // The source state uses N=Z=C=V=0, matching the fresh Core flags.
        return core
    }

    static func makeMemory() -> RE4GuestARMv6Memory {
        RE4GuestARMv6Memory(
            size: 0x20000, heapBase: 0x10000,
            stackTop: 0x1F000, returnSentinel: 0xFFF000
        )
    }

    static func main() throws {
        let stackRange = try RE4StageJ89AddressRange(
            lowerBound: 0x7000, upperBoundExclusive: 0x9000)
        let codeRange = try RE4StageJ89AddressRange(
            lowerBound: 0x5000, upperBoundExclusive: 0x6000)
        var passed = 0
        func test(_ name: String, _ body: () throws -> Void) throws {
            try body()
            passed += 1
            print("PASS: \(name)")
        }

        try test("01 forced ARM InstallContext candidate applies atomically and executes one synthetic marker") {
            let frame = try makeFrame(rawContinuationPC: 0x55A8)
            let current = try makeCurrentState()
            let memory = makeMemory()
            let core = try makeCore(memory: memory, matching: current)
            let before = try core.captureArchitecturalStateSnapshot()
            let projection = try RE4StageJ810GuestCPUContextAdapter.prepareForcedInstallContext(
                current: current, frame: frame,
                stackRange: stackRange, codeRange: codeRange
            )
            try check(!projection.guestInstructionsExecuted &&
                      projection.guestMemoryWrites == 0 &&
                      !projection.liveCPUStateMutated &&
                      !projection.bxExecuted,
                      "J.8.10 projection must remain data-only")
            let candidate = RE4StageJ811CPUStateCandidate.from(preparedContext: projection)
            let token = try core.prepareArchitecturalStateCommit(candidate)
            let afterPreflight = try core.captureArchitecturalStateSnapshot()
            try check(afterPreflight == before && core.steps == 0,
                      "preflight changed live Core state or executed code")
            let receipt = try core.commitArchitecturalStateAtomically(token)
            let applied = try core.captureArchitecturalStateSnapshot()
            try check(applied.registers == projection.stateAfterPlannedTransfer.registers &&
                      applied.executionMode == .arm32Interpreter &&
                      applied.pc == 0x55A8 && applied.sp == 0x7FE8,
                      "ARM InstallContext successor registers/mode were not applied")
            try check(applied.registers[0] == 0x55A8 && applied.registers[7] == 0x80A0,
                      "raw BX operand/R7 values were not transferred")
            try check(receipt.committedExecutionMode == .arm32Interpreter &&
                      !receipt.restoredFullCPSR &&
                      !receipt.restoredVFPD8ThroughD15 &&
                      !receipt.guestInstructionsExecuted,
                      "commit receipt overstated architectural state or Guest execution")
            try check(core.steps == 0, "state commit must not execute a Guest instruction")

            // Synthetic marker only: no Res4/IPA bytes are loaded at this VA.
            try core.memory.write32(0x55A8, 0xE3A0202A) // MOV R2,#0x2A
            var stopReached = false
            core.instructionHook = { pc, _ in
                guard pc == 0x55AC else { return false }
                stopReached = true
                return true
            }
            let executedMarker = try core.step()
            let stoppedBeforeNextFetch = try core.step()
            let final = try core.captureArchitecturalStateSnapshot()
            let r2 = try core.registerValue(2)
            try check(executedMarker && stoppedBeforeNextFetch && stopReached,
                      "synthetic ARM marker did not execute/stop at the boundary")
            try check(r2 == 0x2A && final.pc == 0x55AC &&
                      final.executionMode == .arm32Interpreter && core.steps == 2,
                      "synthetic ARM execution crossed or missed the stop boundary")
        }

        try test("02 forced Thumb InstallContext candidate applies and fetches one synthetic halfword") {
            let frame = try makeFrame(rawContinuationPC: 0x55A9)
            let current = try makeCurrentState()
            let memory = makeMemory()
            let core = try makeCore(memory: memory, matching: current)
            let before = try core.captureArchitecturalStateSnapshot()
            let projection = try RE4StageJ810GuestCPUContextAdapter.prepareForcedInstallContext(
                current: current, frame: frame,
                stackRange: stackRange, codeRange: codeRange
            )
            try check(projection.rawBXOperand == 0x55A9 &&
                      projection.targetPC == 0x55A8 &&
                      projection.targetState == .thumb,
                      "raw BX operand and canonical Thumb PC were not preserved separately")
            let candidate = RE4StageJ811CPUStateCandidate.from(preparedContext: projection)
            let token = try core.prepareArchitecturalStateCommit(candidate)
            let afterPreflight = try core.captureArchitecturalStateSnapshot()
            try check(afterPreflight == before && core.steps == 0,
                      "Thumb preflight changed live Core state")
            let receipt = try core.commitArchitecturalStateAtomically(token)
            let applied = try core.captureArchitecturalStateSnapshot()
            try check(applied.executionMode == .thumb16Required &&
                      core.instructionSetState == .thumb &&
                      applied.pc == 0x55A8 && applied.sp == 0x7FE8,
                      "Thumb InstallContext successor state was not applied")
            try check(applied.registers[0] == 0x55A9 &&
                      applied.registers[7] == 0x80A0 &&
                      receipt.committedExecutionMode == .thumb16Required,
                      "Thumb raw operand/R7 or receipt mode mismatch")
            try check(!receipt.restoredFullCPSR &&
                      !receipt.restoredVFPD8ThroughD15 &&
                      !receipt.guestInstructionsExecuted,
                      "Thumb commit receipt claimed unsupported state")

            // Synthetic marker only: the Core fetches exactly one T16 halfword.
            try core.memory.write16(0x55A8, 0x222A) // MOVS R2,#0x2A
            var stopReached = false
            core.instructionHook = { pc, _ in
                guard pc == 0x55AA else { return false }
                stopReached = true
                return true
            }
            let executedMarker = try core.step()
            let stoppedBeforeNextFetch = try core.step()
            let final = try core.captureArchitecturalStateSnapshot()
            let r2 = try core.registerValue(2)
            try check(executedMarker && stoppedBeforeNextFetch && stopReached,
                      "synthetic Thumb marker did not execute/stop at the boundary")
            try check(r2 == 0x2A && final.pc == 0x55AA &&
                      final.executionMode == .thumb16Required && core.steps == 2,
                      "synthetic Thumb fetch did not advance by two bytes or stop correctly")
        }

        try test("03 frame identity failure is rejected before any Core mutation") {
            let frame = try makeFrame(rawContinuationPC: 0x55A8)
            let current = try makeCurrentState(frameAddress: 0x8100)
            let core = try makeCore(memory: makeMemory(), matching: current)
            let before = try core.captureArchitecturalStateSnapshot()
            do {
                _ = try RE4StageJ810GuestCPUContextAdapter.prepareForcedInstallContext(
                    current: current, frame: frame,
                    stackRange: stackRange, codeRange: codeRange
                )
                throw NSError(domain: "J8.15", code: 2)
            } catch RE4StageJ810AdapterError.providerFrameRegisterMismatch(
                expected: 0x8000, actual: 0x8100
            ) { }
            let after = try core.captureArchitecturalStateSnapshot()
            try check(after == before && core.steps == 0,
                      "frame identity failure changed the Core")
        }

        try test("04 unpredictable ARM BX operand is rejected before any Core mutation") {
            let frame = try makeFrame(rawContinuationPC: 0x55AA)
            let current = try makeCurrentState()
            let core = try makeCore(memory: makeMemory(), matching: current)
            let before = try core.captureArchitecturalStateSnapshot()
            do {
                _ = try RE4StageJ810GuestCPUContextAdapter.prepareForcedInstallContext(
                    current: current, frame: frame,
                    stackRange: stackRange, codeRange: codeRange
                )
                throw NSError(domain: "J8.15", code: 3)
            } catch RE4StageJ89Error.armBXOperandUnpredictable(0x55AA) { }
            let after = try core.captureArchitecturalStateSnapshot()
            try check(after == before && core.steps == 0,
                      "invalid BX operand changed the Core")
        }

        print("RESULT: \(passed)/4 passed; 0 failed")
        print("SCOPE: J.8.10 immutable #101 projection -> J.8.11 Core state transaction -> one synthetic ARM/Thumb marker instruction -> instruction-hook stop before any subsequent fetch.")
        print("LIMIT: no original Res4/provider code, real BX, SJLJ runtime, pthread TSD, callback, personality, unwinder, destructor, or initializer is executed.")
    }
}
