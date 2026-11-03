import Foundation

@main
struct StageJ810GuestCPUContextAdapterTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw NSError(domain: "J8.10", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    static func makeFrame(pc: UInt32 = 0x55A8, sp: UInt32 = 0x7FE8,
                          r7: UInt32 = 0x80A0) throws -> RE4StageJ89SJLJFrame {
        var frame = try RE4StageJ89SJLJFrame(baseAddress: 0x8000)
        try frame.storeWord(at: 0x08, value: 0xA0F00000)
        try frame.storeWord(at: 0x0C, value: 0)
        try frame.storeWord(at: 0x1C, value: 0x001C0996)
        try frame.storeWord(at: 0x20, value: r7)
        try frame.storeWord(at: 0x24, value: pc)
        try frame.storeWord(at: 0x28, value: sp)
        return frame
    }

    static func makeState(
        frameAddress: UInt32 = 0x8000,
        instructionState: RE4ARMv6InstructionSet = .arm
    ) throws -> RE4StageJ810ArchitecturalState {
        var registers = (0..<16).map { UInt32(0x1000 + $0 * 0x10) }
        registers[4] = frameAddress
        registers[15] = 0x358CF8DC
        let flags = RE4StageJ810ConditionFlags(
            negative: true, zero: false, carry: true, overflow: true)
        return try RE4StageJ810ArchitecturalState(
            registers: registers, flags: flags, instructionState: instructionState)
    }

    static func main() throws {
        let stack = try RE4StageJ89AddressRange(lowerBound: 0x7000, upperBoundExclusive: 0x9000)
        let text = try RE4StageJ89AddressRange(lowerBound: 0x5000, upperBoundExclusive: 0x6000)
        var passed = 0
        func test(_ name: String, _ body: () throws -> Void) throws {
            try body(); passed += 1; print("PASS: \(name)")
        }

        try test("01 16-register architectural state requires a valid ARM source PC") {
            let badCount = (0..<15).map { UInt32($0 * 4) }
            do {
                _ = try RE4StageJ810ArchitecturalState(
                    registers: badCount,
                    flags: RE4StageJ810ConditionFlags(negative: false, zero: false, carry: false, overflow: false),
                    instructionState: .arm)
                throw NSError(domain: "J8.10", code: 2)
            } catch RE4StageJ810AdapterError.invalidRegisterFileCount(15) { }
            var badPC = (0..<16).map { UInt32($0 * 4) }
            badPC[15] = 0x1002
            do {
                _ = try RE4StageJ810ArchitecturalState(
                    registers: badPC,
                    flags: RE4StageJ810ConditionFlags(negative: false, zero: false, carry: false, overflow: false),
                    instructionState: .arm)
                throw NSError(domain: "J8.10", code: 3)
            } catch RE4StageJ810AdapterError.invalidCanonicalPC(state: .arm, value: 0x1002) { }
        }

        try test("02 adapter accepts only the ARM provider execution state") {
            let frame = try makeFrame()
            let thumb = try makeState(instructionState: .thumb)
            do {
                _ = try RE4StageJ810GuestCPUContextAdapter.prepareForcedInstallContext(
                    current: thumb, frame: frame, stackRange: stack, codeRange: text)
                throw NSError(domain: "J8.10", code: 4)
            } catch RE4StageJ810AdapterError.sourceStateMustBeARM { }
        }

        try test("03 R4 must identify the exact selected SJLJ frame") {
            let frame = try makeFrame()
            let wrong = try makeState(frameAddress: 0x8100)
            do {
                _ = try RE4StageJ810GuestCPUContextAdapter.prepareForcedInstallContext(
                    current: wrong, frame: frame, stackRange: stack, codeRange: text)
                throw NSError(domain: "J8.10", code: 5)
            } catch RE4StageJ810AdapterError.providerFrameRegisterMismatch(
                expected: 0x8000, actual: 0x8100) { }
        }

        try test("04 forced Resume uses the forced provider restore instruction addresses") {
            try check(RE4StageJ810GuestCPUContextAdapter.forcedInstallRestoreInstructionAddresses ==
                      [0x358CF8DC, 0x358CF8E0, 0x358CF8E4, 0x358CF8E8],
                      "forced provider instruction addresses mismatch")
            try check(RE4StageJ810GuestCPUContextAdapter.normalInstallRestoreInstructionAddresses ==
                      [0x358CF9D0, 0x358CF9D4, 0x358CF9D8, 0x358CF9DC],
                      "normal provider instruction addresses mismatch")
        }

        try test("05 planned transfer writes R0 scratch, R7, SP and canonical PC only") {
            let frame = try makeFrame()
            let current = try makeState()
            let prepared = try RE4StageJ810GuestCPUContextAdapter.prepareForcedInstallContext(
                current: current, frame: frame, stackRange: stack, codeRange: text)
            try check(prepared.changedRegisterIndices == [0, 7, 13, 15],
                      "wrong set of architectural register changes")
            try check(prepared.r0AfterBX == 0x55A8 && prepared.targetPC == 0x55A8 &&
                      prepared.stateAfterPlannedTransfer.r7 == 0x80A0 &&
                      prepared.stateAfterPlannedTransfer.sp == 0x7FE8,
                      "#101 ARM successor register values mismatch")
        }

        try test("06 non-target GPRs including R4/R5/R6/R8/R12/LR are preserved at BX boundary") {
            let frame = try makeFrame()
            let current = try makeState()
            let prepared = try RE4StageJ810GuestCPUContextAdapter.prepareForcedInstallContext(
                current: current, frame: frame, stackRange: stack, codeRange: text)
            for index in 0..<16 where ![0, 7, 13, 15].contains(index) {
                try check(prepared.stateAfterPlannedTransfer.registers[index] == current.registers[index],
                          "register R\(index) changed unexpectedly")
            }
        }

        try test("07 N/Z/C/V flags are preserved, not restored from SJLJ frame") {
            let frame = try makeFrame()
            let current = try makeState()
            let prepared = try RE4StageJ810GuestCPUContextAdapter.prepareForcedInstallContext(
                current: current, frame: frame, stackRange: stack, codeRange: text)
            try check(prepared.stateAfterPlannedTransfer.flags == current.flags &&
                      prepared.preservedConditionFlags && !prepared.fullCPSRRestored,
                      "condition flags or CPSR claim mismatch")
        }

        try test("08 BX Thumb target keeps raw bit in R0 but clears it from canonical PC") {
            let frame = try makeFrame(pc: 0x55A9)
            let current = try makeState()
            let prepared = try RE4StageJ810GuestCPUContextAdapter.prepareForcedInstallContext(
                current: current, frame: frame, stackRange: stack, codeRange: text)
            try check(prepared.rawBXOperand == 0x55A9 &&
                      prepared.r0AfterBX == 0x55A9 && prepared.targetPC == 0x55A8 &&
                      prepared.targetState == .thumb,
                      "BX Thumb state/R0 scratch semantics mismatch")
        }

        try test("09 invalid ARM BX low bits 10 fail closed") {
            let frame = try makeFrame(pc: 0x55AA)
            let current = try makeState()
            do {
                _ = try RE4StageJ810GuestCPUContextAdapter.prepareForcedInstallContext(
                    current: current, frame: frame, stackRange: stack, codeRange: text)
                throw NSError(domain: "J8.10", code: 6)
            } catch RE4StageJ89Error.armBXOperandUnpredictable(0x55AA) { }
        }

        try test("10 current CPU snapshot remains immutable and no BX is performed") {
            let frame = try makeFrame()
            let current = try makeState()
            let before = current
            let prepared = try RE4StageJ810GuestCPUContextAdapter.prepareForcedInstallContext(
                current: current, frame: frame, stackRange: stack, codeRange: text)
            try check(current == before && prepared.stateBefore == before &&
                      !prepared.liveCPUStateMutated && !prepared.bxExecuted &&
                      !prepared.guestInstructionsExecuted && prepared.guestMemoryWrites == 0,
                      "adapter mutated source state or executed a transfer")
        }

        try test("11 prepared contract identifies the forced phase-2 path") {
            let frame = try makeFrame()
            let prepared = try RE4StageJ810GuestCPUContextAdapter.prepareForcedInstallContext(
                current: makeState(), frame: frame, stackRange: stack, codeRange: text)
            try check(prepared.providerPath == .forcedPhase2InstallContext &&
                      prepared.frameAddress == 0x8000,
                      "provider path/frame identity mismatch")
        }

        try test("12 #101 target epilogue responsibilities are separate from provider restores") {
            let frame = try makeFrame()
            let prepared = try RE4StageJ810GuestCPUContextAdapter.prepareForcedInstallContext(
                current: makeState(), frame: frame, stackRange: stack, codeRange: text)
            try check(prepared.targetFunctionEpilogueMustRestoreCoreRegisters ==
                      ["R4", "R5", "R6", "R7", "LR", "R8", "R10", "R11"] &&
                      prepared.targetFunctionEpilogueMustRestoreVFPRegisters ==
                      ["D8", "D9", "D10", "D11", "D12", "D13", "D14", "D15"],
                      "target function epilogue obligation list mismatch")
        }

        try test("13 current core gap is Thumb only; D8-D15 stack transfers are implemented") {
            let frame = try makeFrame()
            let prepared = try RE4StageJ810GuestCPUContextAdapter.prepareForcedInstallContext(
                current: makeState(), frame: frame, stackRange: stack, codeRange: text)
            try check(!prepared.guestCoreHasThumbExecution &&
                      prepared.guestCoreImplementsVFPStackTransfers,
                      "adapter capability report does not match Core implementation")
        }

        print("RESULT: \(passed)/13 passed; 0 failed")
        print("SCOPE: host-only immutable Guest CPU successor-state projection; no live core mutation, Guest instruction, memory write, CPSR write or BX.")
    }
}
