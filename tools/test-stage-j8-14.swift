import Foundation

@main
struct StageJ814BXBLXInterworkingTests {
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw NSError(domain: "J8.14", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    static func makeMemory() -> RE4GuestARMv6Memory {
        RE4GuestARMv6Memory(size: 0x20000, heapBase: 0x10000,
                            stackTop: 0x1F000, returnSentinel: 0xFFF000)
    }

    static func runToStop(
        memory: RE4GuestARMv6Memory,
        entry: UInt32,
        arguments: [UInt32] = [],
        initialState: RE4ARMv6InstructionSet = .arm,
        stopPC: UInt32,
        maxSteps: Int = 32
    ) throws -> (RE4GuestARMv6Core, RE4GuestARMv6RunResult) {
        let core = RE4GuestARMv6Core(
            memory: memory,
            instructionHook: { pc, cpu in
                guard pc == stopPC else { return false }
                cpu.requestTermination(exitCode: 0)
                return true
            }
        )
        let result = try core.run(
            entry: entry, arguments: arguments, maxSteps: maxSteps,
            initialInstructionSetState: initialState
        )
        return (core, result)
    }

    static func main() throws {
        var passed = 0
        func test(_ name: String, _ body: () throws -> Void) throws {
            try body()
            passed += 1
            print("PASS: \(name)")
        }
        let sentinel: UInt32 = 0xFFF000

        try test("01 ARM BX to Thumb canonicalizes bit 0 and executes Thumb code") {
            let memory = makeMemory()
            try memory.write32(0x1000, 0xE12FFF10) // BX R0
            try memory.write16(0x2000, 0x2107) // MOVS R1,#7
            let (core, result) = try runToStop(
                memory: memory, entry: 0x1000, arguments: [0x2001], stopPC: 0x2002
            )
            try check(result.instructionSetState == .thumb && result.programCounter == 0x2002,
                      "ARM BX did not select Thumb or canonicalize the target")
            let r1 = try core.registerValue(1)
            let lr = try core.registerValue(14)
            try check(r1 == 7, "Thumb target instruction was not executed")
            try check(lr == sentinel, "BX must preserve LR")
        }

        try test("02 ARM BX to ARM remains ARM and preserves LR") {
            let memory = makeMemory()
            try memory.write32(0x1000, 0xE12FFF10)
            try memory.write32(0x2000, 0xE3A0102A) // MOV R1,#42
            let (core, result) = try runToStop(
                memory: memory, entry: 0x1000, arguments: [0x2000], stopPC: 0x2004
            )
            try check(result.instructionSetState == .arm && result.programCounter == 0x2004,
                      "ARM-to-ARM BX changed state or PC")
            let r1 = try core.registerValue(1)
            let lr = try core.registerValue(14)
            try check(r1 == 42, "ARM BX target instruction was not executed")
            try check(lr == sentinel, "BX must not write LR")
        }

        try test("03 Thumb BX to ARM clears the state bit and executes ARM code") {
            let memory = makeMemory()
            try memory.write16(0x1000, 0x4700) // BX R0
            try memory.write32(0x2000, 0xE3A0102A) // MOV R1,#42
            let (core, result) = try runToStop(
                memory: memory, entry: 0x1000, arguments: [0x2000],
                initialState: .thumb, stopPC: 0x2004
            )
            try check(result.instructionSetState == .arm && result.programCounter == 0x2004,
                      "Thumb BX did not switch to ARM at the aligned address")
            let r1 = try core.registerValue(1)
            let lr = try core.registerValue(14)
            try check(r1 == 42, "ARM target instruction was not executed")
            try check(lr == sentinel, "Thumb BX must preserve LR")
        }

        try test("04 Thumb BX to Thumb remains Thumb") {
            let memory = makeMemory()
            try memory.write16(0x1000, 0x4700) // BX R0
            try memory.write16(0x2000, 0x2109) // MOVS R1,#9
            let (core, result) = try runToStop(
                memory: memory, entry: 0x1000, arguments: [0x2001],
                initialState: .thumb, stopPC: 0x2002
            )
            try check(result.instructionSetState == .thumb && result.programCounter == 0x2002,
                      "Thumb BX to Thumb lost T state")
            let r1 = try core.registerValue(1)
            try check(r1 == 9, "Thumb target instruction was not executed")
        }

        try test("05 ARM BLX to Thumb links to A32 next word and BX LR returns to ARM") {
            let memory = makeMemory()
            try memory.write32(0x1000, 0xE12FFF30) // BLX R0
            try memory.write16(0x2000, 0x4770) // Thumb BX LR
            try memory.write32(0x1004, 0xE3A0202A) // MOV R2,#42 (return site)
            let (core, result) = try runToStop(
                memory: memory, entry: 0x1000, arguments: [0x2001], stopPC: 0x1008
            )
            try check(result.instructionSetState == .arm && result.programCounter == 0x1008,
                      "Thumb callee did not return to the ARM continuation")
            let lr = try core.registerValue(14)
            let r2 = try core.registerValue(2)
            try check(lr == 0x1004,
                      "A32 BLX LR must equal the address of the next ARM instruction")
            try check(r2 == 42, "ARM continuation did not execute")
        }

        try test("06 ARM BLX to ARM links and returns without changing state") {
            let memory = makeMemory()
            try memory.write32(0x1000, 0xE12FFF30) // BLX R0
            try memory.write32(0x3000, 0xE12FFF1E) // ARM BX LR
            try memory.write32(0x1004, 0xE3A0202A)
            let (core, result) = try runToStop(
                memory: memory, entry: 0x1000, arguments: [0x3000], stopPC: 0x1008
            )
            try check(result.instructionSetState == .arm && result.programCounter == 0x1008,
                      "same-state A32 BLX return failed")
            let lr = try core.registerValue(14)
            let r2 = try core.registerValue(2)
            try check(lr == 0x1004, "A32 BLX link value mismatch")
            try check(r2 == 42, "A32 return site did not execute")
        }

        try test("07 Thumb BLX to ARM sets an odd Thumb return token; BX LR returns to Thumb") {
            let memory = makeMemory()
            try memory.write16(0x1000, 0x4780) // BLX R0
            try memory.write32(0x3000, 0xE12FFF1E) // ARM BX LR
            try memory.write16(0x1002, 0x2109) // MOVS R1,#9 (return site)
            let (core, result) = try runToStop(
                memory: memory, entry: 0x1000, arguments: [0x3000],
                initialState: .thumb, stopPC: 0x1004
            )
            try check(result.instructionSetState == .thumb && result.programCounter == 0x1004,
                      "ARM callee did not return to the Thumb continuation")
            let lr = try core.registerValue(14)
            let r1 = try core.registerValue(1)
            try check(lr == 0x1003,
                      "T16 BLX LR must be (instruction address + 2) | 1")
            try check(r1 == 9, "Thumb continuation did not execute")
        }

        try test("08 Thumb BLX to Thumb links and returns within Thumb state") {
            let memory = makeMemory()
            try memory.write16(0x1000, 0x4780) // BLX R0
            try memory.write16(0x2000, 0x4770) // Thumb BX LR
            try memory.write16(0x1002, 0x2109)
            let (core, result) = try runToStop(
                memory: memory, entry: 0x1000, arguments: [0x2001],
                initialState: .thumb, stopPC: 0x1004
            )
            try check(result.instructionSetState == .thumb && result.programCounter == 0x1004,
                      "same-state Thumb BLX return failed")
            let lr = try core.registerValue(14)
            let r1 = try core.registerValue(1)
            try check(lr == 0x1003, "T16 BLX link value mismatch")
            try check(r1 == 9, "Thumb return site did not execute")
        }

        try test("09 BLX preserves NZCV while updating LR") {
            let memory = makeMemory()
            try memory.write32(0x1000, 0xE3B02000) // MOVS R2,#0 -> Z=1
            try memory.write32(0x1004, 0xE12FFF30) // BLX R0
            let (core, result) = try runToStop(
                memory: memory, entry: 0x1000, arguments: [0x2001], stopPC: 0x2000
            )
            let state = try core.captureArchitecturalStateSnapshot()
            let lr = try core.registerValue(14)
            try check(result.instructionSetState == .thumb, "BLX did not select Thumb")
            try check(state.flags.zero && !state.flags.negative,
                      "BLX must not modify NZCV")
            try check(lr == 0x1008, "A32 BLX link should be next ARM word")
        }

        try test("10 Conditional A32 BLX that fails its condition does not link or branch") {
            let memory = makeMemory()
            try memory.write32(0x1000, 0x012FFF30) // BLXEQ R0; initial Z=0
            try memory.write32(0x1004, 0xE3A0102A) // MOV R1,#42
            let (core, result) = try runToStop(
                memory: memory, entry: 0x1000, arguments: [0x2001], stopPC: 0x1008
            )
            try check(result.instructionSetState == .arm && result.programCounter == 0x1008,
                      "untaken conditional BLX changed control flow")
            let lr = try core.registerValue(14)
            let r1 = try core.registerValue(1)
            try check(lr == sentinel, "untaken conditional BLX changed LR")
            try check(r1 == 42, "conditional fallthrough did not execute")
        }

        try test("11 Non-word-aligned ARM target fails closed before publishing LR or mode") {
            let memory = makeMemory()
            try memory.write32(0x1000, 0xE12FFF30) // BLX R0
            let core = RE4GuestARMv6Core(memory: memory)
            do {
                _ = try core.run(entry: 0x1000, arguments: [0x2002], maxSteps: 8)
                throw NSError(domain: "J8.14", code: 2)
            } catch RE4GuestRuntimeError.unsupportedARMBranchTargetAlignment(0x2002) { }
            try check(core.instructionSetState == .arm, "invalid ARM target changed T state")
            let lr = try core.registerValue(14)
            try check(lr == sentinel, "invalid BLX target partially published LR")
            try check(try core.registerValue(15) == 0x1004, "failed decode PC behavior changed")
        }

        try test("12 Non-word-aligned ARM target from Thumb BLX fails before publishing LR") {
            let memory = makeMemory()
            try memory.write16(0x1000, 0x4780) // BLX R0
            let core = RE4GuestARMv6Core(memory: memory)
            do {
                _ = try core.run(
                    entry: 0x1000, arguments: [0x3002], maxSteps: 8,
                    initialInstructionSetState: .thumb
                )
                throw NSError(domain: "J8.14", code: 3)
            } catch RE4GuestRuntimeError.unsupportedARMBranchTargetAlignment(0x3002) { }
            try check(core.instructionSetState == .thumb, "invalid T16 BLX target changed T state")
            let lr = try core.registerValue(14)
            try check(lr == sentinel, "invalid T16 BLX partially wrote LR")
            try check(try core.registerValue(15) == 0x1002, "failed T16 BLX PC behavior changed")
        }

        try test("13 Reserved low bits in Thumb BX encoding fail closed") {
            let memory = makeMemory()
            try memory.write16(0x1000, 0x4701) // Reserved low encoding bit set
            let core = RE4GuestARMv6Core(memory: memory)
            do {
                _ = try core.run(
                    entry: 0x1000, maxSteps: 4, initialInstructionSetState: .thumb
                )
                throw NSError(domain: "J8.14", code: 4)
            } catch RE4GuestRuntimeError.unsupportedThumbInstruction(0x1000, 0x4701) { }
            try check(core.instructionSetState == .thumb, "reserved BX encoding changed state")
            let lr = try core.registerValue(14)
            try check(lr == sentinel, "reserved BX encoding changed LR")
        }

        try test("14 Thumb BX with R15 is rejected by the bounded register subset") {
            let memory = makeMemory()
            try memory.write16(0x1000, 0x4778) // BX PC
            let core = RE4GuestARMv6Core(memory: memory)
            do {
                _ = try core.run(
                    entry: 0x1000, maxSteps: 4, initialInstructionSetState: .thumb
                )
                throw NSError(domain: "J8.14", code: 5)
            } catch RE4GuestRuntimeError.unsupportedThumbInstruction(0x1000, 0x4778) { }
            try check(core.instructionSetState == .thumb, "BX PC fail-closed gate changed state")
        }

        try test("15 Pure resolver validates state, canonical PC and ARM target alignment") {
            let thumb = try RE4ARMv6InstructionSetState.resolveBX(
                from: .arm, registerTarget: 0x2001)
            try check(thumb.targetState == .thumb && thumb.targetAddress == 0x2000,
                      "odd register target did not select canonical Thumb")
            let arm = try RE4ARMv6InstructionSetState.resolveBLXRegister(
                from: .thumb, registerTarget: 0x3000)
            try check(arm.targetState == .arm && arm.targetAddress == 0x3000,
                      "word-aligned even target did not select ARM")
            do {
                _ = try RE4ARMv6InstructionSetState.resolveBX(
                    from: .thumb, registerTarget: 0x3002)
                throw NSError(domain: "J8.14", code: 6)
            } catch RE4ARMv6InstructionSetStateError.unsupportedARMTargetAlignment(0x3002) { }
        }

        print("RESULT: \(passed)/15 passed; 0 failed")
        print("SCOPE: real A32/T16 BX/BLX-register state changes and return links; no BXJ, exception return, full CPSR, provider execution or live SJLJ context application.")
    }
}
