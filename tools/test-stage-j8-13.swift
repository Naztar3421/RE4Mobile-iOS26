import Foundation

@main
struct StageJ813ARMThumbExecutionTests {
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw NSError(domain: "J8.13", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    static func makeMemory(size: Int = 0x20000) -> RE4GuestARMv6Memory {
        RE4GuestARMv6Memory(size: size, heapBase: 0x10000,
                            stackTop: 0x1F000, returnSentinel: 0xFFF000)
    }

    static func runThumb(
        memory: RE4GuestARMv6Memory,
        entry: UInt32 = 0x1000,
        stopPC: UInt32,
        arguments: [UInt32] = [],
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
            initialInstructionSetState: .thumb
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

        try test("01 Thumb fetch reads one halfword and advances PC by two") {
            let memory = makeMemory(size: 0x1002)
            try memory.write16(0x1000, 0x2007) // MOVS R0,#7
            let (core, result) = try runThumb(memory: memory, stopPC: 0x1002)
            try check(try core.registerValue(0) == 7, "MOVS immediate did not write R0")
            try check(result.programCounter == 0x1002, "Thumb PC must advance by two bytes")
            try check(result.instructionSetState == .thumb, "run result lost Thumb state")
            try check(result.steps == 2, "expected one instruction plus stop hook")
            try check(try memory.readInstruction16(0x1000) == 0x2007,
                      "16-bit executable fetch returned the wrong halfword")
            do {
                _ = try memory.readInstruction32(0x1000)
                throw NSError(domain: "J8.13", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "32-bit fetch unexpectedly fit"])
            } catch RE4GuestRuntimeError.invalidMemoryRange { }
        }

        try test("02 Thumb MOVS, ADDS, SUBS and CMP immediate update registers and NZCV") {
            let memory = makeMemory()
            try memory.write16(0x1000, 0x2005) // MOVS R0,#5
            try memory.write16(0x1002, 0x3003) // ADDS R0,#3
            try memory.write16(0x1004, 0x3802) // SUBS R0,#2
            try memory.write16(0x1006, 0x2806) // CMP R0,#6
            let (core, result) = try runThumb(memory: memory, stopPC: 0x1008)
            let state = try core.captureArchitecturalStateSnapshot()
            try check(try core.registerValue(0) == 6, "Thumb immediate arithmetic result mismatch")
            try check(state.flags.zero && state.flags.carry &&
                      !state.flags.negative && !state.flags.overflow,
                      "CMP #6 should produce Z=1,C=1,N=0,V=0")
            try check(state.executionMode == .thumb16Required,
                      "architectural snapshot must retain the current Thumb state")
            try check(result.programCounter == 0x1008, "Thumb sequential PC mismatch")
        }

        try test("03 Thumb ADD sets 32-bit carry and signed overflow correctly") {
            let memory = makeMemory()
            try memory.write16(0x1000, 0x3001) // ADDS R0,#1
            let (core, _) = try runThumb(
                memory: memory, stopPC: 0x1002, arguments: [0x7FFFFFFF]
            )
            let state = try core.captureArchitecturalStateSnapshot()
            try check(try core.registerValue(0) == 0x80000000,
                      "ADDS did not wrap at 32 bits")
            try check(state.flags.negative && state.flags.overflow &&
                      !state.flags.zero && !state.flags.carry,
                      "0x7fffffff + 1 must set N and V only")
        }

        try test("04 Thumb conditional B takes the branch using PC+4") {
            let memory = makeMemory()
            try memory.write16(0x1000, 0x2000) // MOVS R0,#0 => Z=1
            try memory.write16(0x1002, 0xD001) // BEQ +2 -> 0x1008
            try memory.write16(0x1004, 0x2101) // skipped: MOVS R1,#1
            try memory.write16(0x1006, 0x2102) // skipped
            try memory.write16(0x1008, 0x2202) // MOVS R2,#2
            let (core, result) = try runThumb(memory: memory, stopPC: 0x100A)
            try check(try core.registerValue(1) == 0, "taken BEQ executed fallthrough")
            try check(try core.registerValue(2) == 2, "taken BEQ did not reach target")
            try check(result.programCounter == 0x100A, "taken BEQ target/PC base is wrong")
        }

        try test("05 Thumb conditional B falls through when the condition is false") {
            let memory = makeMemory()
            try memory.write16(0x1000, 0x2001) // MOVS R0,#1 => Z=0
            try memory.write16(0x1002, 0xD001) // BEQ not taken
            try memory.write16(0x1004, 0x2101) // MOVS R1,#1
            let (core, result) = try runThumb(memory: memory, stopPC: 0x1006)
            try check(try core.registerValue(1) == 1, "false BEQ did not fall through")
            try check(result.programCounter == 0x1006, "fallthrough PC mismatch")
        }

        try test("06 Thumb unconditional B sign-extends its 11-bit displacement") {
            let memory = makeMemory()
            try memory.write16(0x1000, 0x2009) // MOVS R0,#9
            try memory.write16(0x1002, 0xE7FD) // B -6: target 0x1000
            var visits = 0
            let core = RE4GuestARMv6Core(memory: memory, instructionHook: { pc, cpu in
                guard pc == 0x1002 else { return false }
                visits += 1
                if visits == 2 {
                    cpu.requestTermination(exitCode: 0)
                    return true
                }
                return false
            })
            let result = try core.run(
                entry: 0x1002, maxSteps: 8, initialInstructionSetState: .thumb
            )
            try check(visits == 2, "backward branch did not return to its own address")
            try check(try core.registerValue(0) == 9, "instruction before backward branch did not execute")
            try check(result.programCounter == 0x1002, "backward branch target is not PC-relative to PC+4")
        }

        try test("07 ARM entry requires word alignment; Thumb entry requires halfword alignment") {
            let core = RE4GuestARMv6Core(memory: makeMemory())
            do {
                _ = try core.run(entry: 0x1002, maxSteps: 1)
                throw NSError(domain: "J8.13", code: 3)
            } catch RE4GuestRuntimeError.instructionAddressMisaligned(_, "ARM") { }
            do {
                _ = try core.run(
                    entry: 0x1001, maxSteps: 1, initialInstructionSetState: .thumb
                )
                throw NSError(domain: "J8.13", code: 4)
            } catch RE4GuestRuntimeError.instructionAddressMisaligned(_, "Thumb") { }
        }

        try test("08 Thumb instruction fetch requires executable Guest Memory") {
            let memory = makeMemory()
            try memory.setProtectionRange(
                address: 0x1000, length: 2, protection: [.read, .write],
                name: "non-executable-thumb-test"
            )
            try memory.write16(0x1000, 0x2001)
            do {
                _ = try memory.readInstruction16(0x1000)
                throw NSError(domain: "J8.13", code: 5)
            } catch RE4GuestRuntimeError.memoryProtectionViolation(
                0x1000, 2, "--X", "non-executable-thumb-test"
            ) { }
        }

        try test("09 Thumb BX is decoded and can branch to a Thumb target") {
            let memory = makeMemory()
            try memory.write16(0x1000, 0x4700) // BX R0
            try memory.write16(0x2000, 0x2107) // MOVS R1,#7
            let core = RE4GuestARMv6Core(
                memory: memory,
                instructionHook: { pc, cpu in
                    guard pc == 0x2002 else { return false }
                    cpu.requestTermination(exitCode: 0)
                    return true
                }
            )
            let result = try core.run(
                entry: 0x1000, arguments: [0x2001], maxSteps: 8,
                initialInstructionSetState: .thumb
            )
            let r1 = try core.registerValue(1)
            try check(result.instructionSetState == .thumb && result.programCounter == 0x2002,
                      "Thumb-to-Thumb BX did not preserve state/canonicalize target")
            try check(r1 == 7, "Thumb BX target instruction was not executed")
        }

        try test("10 ARM BX to a Thumb target switches mode and executes Thumb code") {
            let memory = makeMemory()
            try memory.write32(0x1000, 0xE12FFF10) // BX R0
            try memory.write16(0x2000, 0x2107) // MOVS R1,#7
            let core = RE4GuestARMv6Core(
                memory: memory,
                instructionHook: { pc, cpu in
                    guard pc == 0x2002 else { return false }
                    cpu.requestTermination(exitCode: 0)
                    return true
                }
            )
            let result = try core.run(entry: 0x1000, arguments: [0x2001], maxSteps: 8)
            let r1 = try core.registerValue(1)
            try check(result.instructionSetState == .thumb && result.programCounter == 0x2002,
                      "ARM-to-Thumb BX did not publish the selected mode/canonical PC")
            try check(r1 == 7, "Thumb instruction after ARM BX did not execute")
        }

        try test("11 ARM stepping remains 32-bit and preserves its existing PC increment") {
            let memory = makeMemory()
            try memory.write32(0x1000, 0xE3A0002A) // MOV R0,#42
            let core = RE4GuestARMv6Core(memory: memory)
            try core.setRegisterValue(15, value: 0x1000)
            _ = try core.step()
            try check(try core.registerValue(0) == 42, "ARM MOV immediate regression")
            try check(try core.registerValue(15) == 0x1004, "ARM PC must advance by four")
            try check(core.instructionSetState == .arm, "ARM instruction changed state")
        }

        try test("12 J.8.11 architectural snapshot keeps Thumb state separate from canonical PC") {
            let memory = makeMemory()
            try memory.write16(0x1000, 0x2001)
            let (core, result) = try runThumb(memory: memory, stopPC: 0x1002)
            let snapshot = try core.captureArchitecturalStateSnapshot()
            try check(snapshot.executionMode == .thumb16Required,
                      "snapshot must not collapse Thumb state into ARM")
            try check(snapshot.pc == 0x1002 && (snapshot.pc & 1) == 0,
                      "snapshot PC must be canonical and halfword aligned")
            try check(result.instructionSetState == .thumb,
                      "run result must report the executed instruction set")
        }

        try test("13 Thumb PC-relative literal LDR uses Align(PC+4,4)") {
            let memory = makeMemory()
            try memory.write16(0x1002, 0x4801) // LDR R0,[PC,#4]
            try memory.write32(0x1008, 0xDEADBEEF)
            let (core, result) = try runThumb(
                memory: memory, entry: 0x1002, stopPC: 0x1004
            )
            try check(try core.registerValue(0) == 0xDEADBEEF,
                      "Thumb literal LDR did not align PC+4 before adding its scaled immediate")
            try check(result.programCounter == 0x1004,
                      "Thumb literal LDR sequential PC must advance by two")
        }

        print("RESULT: \(passed)/13 passed; 0 failed")
        print("SCOPE: ARM/Thumb fetch width, PC alignment/advance, bounded Thumb-1 arithmetic, branches and BX state selection. BLX link semantics are covered by J.8.14.")
    }
}
