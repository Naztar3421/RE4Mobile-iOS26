import Foundation

@main
struct StageJ816SyntheticInitializerEpilogueReplayTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw NSError(domain: "J8.16", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    static func makeMemory() -> RE4GuestARMv6Memory {
        RE4GuestARMv6Memory(
            size: 0x20000, heapBase: 0x10000,
            stackTop: 0x1F000, returnSentinel: 0xFFF000
        )
    }

    static func makeSavedDValues() -> [UInt64] {
        (0..<8).map { 0xA0B0C0D000000000 | UInt64($0 + 1) }
    }

    static func populateEpilogueImage(
        memory: RE4GuestARMv6Memory,
        core: RE4GuestARMv6Core
    ) throws -> (vfp: [UInt64], extended: [UInt32], core: [UInt32], clobberedLR: UInt32) {
        // The four A32 instructions are copied from the pinned 8C148 evidence CSV,
        // but the bytes written here are the test fixture, not the original Res4 image.
        try memory.write32(0x561C, 0xE247D058) // SUB SP,R7,#0x58
        try memory.write32(0x5620, 0xECBD8B10) // VPOP {D8-D15}
        try memory.write32(0x5624, 0xE247D018) // SUB SP,R7,#0x18
        try memory.write32(0x5628, 0xE8BD0D00) // POP {R8,R10,R11}
        try memory.write32(0x562C, 0xE8BD80F0) // POP {R4,R5,R6,R7,PC}

        let savedVFP = makeSavedDValues()
        let vfpStackBase: UInt32 = 0x8048 // R7 - 0x58
        for (index, value) in savedVFP.enumerated() {
            let address = vfpStackBase + UInt32(index * 8)
            try memory.write32(address, UInt32(truncatingIfNeeded: value))
            try memory.write32(address + 4, UInt32(truncatingIfNeeded: value >> 32))
            try core.setVFPDoubleRegisterValue(
                8 + index, value: 0xDEAD000000000000 | UInt64(index + 1)
            )
        }

        let savedExtended: [UInt32] = [
            0x88888888, // R8
            0xAAAAAAAA, // R10
            0xBBBBBBBB  // R11
        ]
        for (index, value) in savedExtended.enumerated() {
            try memory.write32(0x8088 + UInt32(index * 4), value)
        }

        // At the final POP the saved LR is loaded directly into PC, not LR.
        let savedCoreAndReturn: [UInt32] = [
            0x44444444, // R4
            0x55555555, // R5
            0x66666666, // R6
            0x00007004, // caller's original R7
            0x00004A40  // caller return address (saved LR -> PC)
        ]
        for (index, value) in savedCoreAndReturn.enumerated() {
            try memory.write32(0x8094 + UInt32(index * 4), value)
        }

        // Values live at the provider's InstallContext continuation boundary.
        for index in 0..<16 {
            try core.setRegisterValue(index, value: 0xCCCC0000 + UInt32(index * 0x10))
        }
        try core.setRegisterValue(7, value: 0x80A0)   // restored frame pointer
        try core.setRegisterValue(13, value: 0x7FE8)  // saved body SP
        try core.setRegisterValue(15, value: 0x561C)  // #101 epilogue entry
        let clobberedLR = try core.registerValue(14)
        return (savedVFP, savedExtended, savedCoreAndReturn, clobberedLR)
    }

    static func main() throws {
        var passed = 0
        func test(_ name: String, _ body: () throws -> Void) throws {
            try body()
            passed += 1
            print("PASS: \(name)")
        }

        try test("01 exact #101 epilogue restores VFP, extended/core GPRs, saved LR into PC and entry SP") {
            let memory = makeMemory()
            let core = RE4GuestARMv6Core(memory: memory)
            let saved = try populateEpilogueImage(memory: memory, core: core)

            _ = try core.step() // 0x561C: SUB SP,R7,#0x58
            let spAfterVFPRebase = try core.registerValue(13)
            let pcAfterVFPRebase = try core.registerValue(15)
            try check(spAfterVFPRebase == 0x8048 && pcAfterVFPRebase == 0x5620,
                      "first epilogue instruction must rebase SP to R7-0x58")

            _ = try core.step() // 0x5620: VPOP {D8-D15}
            let spAfterVPOP = try core.registerValue(13)
            let restoredVFP = try core.captureVFPD8ThroughD15Snapshot()
            try check(spAfterVPOP == 0x8088 && restoredVFP.d8ThroughD15 == saved.vfp,
                      "VPOP must restore all eight D registers and advance SP by 64")

            _ = try core.step() // 0x5624: SUB SP,R7,#0x18
            let spBeforeExtendedPOP = try core.registerValue(13)
            try check(spBeforeExtendedPOP == 0x8088,
                      "second SP rebase must select the R8/R10/R11 save block")

            _ = try core.step() // 0x5628: POP {R8,R10,R11}
            let spAfterExtendedPOP = try core.registerValue(13)
            let r8 = try core.registerValue(8)
            let r10 = try core.registerValue(10)
            let r11 = try core.registerValue(11)
            try check(spAfterExtendedPOP == 0x8094 &&
                      [r8, r10, r11] == saved.extended,
                      "extended callee-saved register pop/order mismatch")

            _ = try core.step() // 0x562C: POP {R4,R5,R6,R7,PC}
            let spAtCaller = try core.registerValue(13)
            let r4 = try core.registerValue(4)
            let r5 = try core.registerValue(5)
            let r6 = try core.registerValue(6)
            let r7 = try core.registerValue(7)
            let pc = try core.registerValue(15)
            let lr = try core.registerValue(14)
            try check(spAtCaller == 0x80A8,
                      "final POP must restore the entry SP after consuming five words")
            try check([r4, r5, r6, r7, pc] == saved.core,
                      "core register pop order or saved-LR-to-PC mapping mismatch")
            try check(lr == saved.clobberedLR,
                      "POP-to-PC must consume the saved LR slot into PC, not write LR")
            try check(core.instructionSetState == .arm,
                      "the #101 A32 epilogue must remain in ARM state")

            // The caller return PC is a hook-only boundary. No instruction bytes
            // are installed at 0x4A40, so success proves we stop before the next fetch.
            var stopReached = false
            core.instructionHook = { currentPC, _ in
                guard currentPC == 0x4A40 else { return false }
                stopReached = true
                return true
            }
            let stoppedBeforeReturnFetch = try core.step()
            let finalPC = try core.registerValue(15)
            try check(stoppedBeforeReturnFetch && stopReached && finalPC == 0x4A40,
                      "epilogue replay must stop at caller PC before fetching caller code")
            try check(core.steps == 6,
                      "expected five epilogue instructions plus one stop-hook boundary")
        }

        try test("02 failed synthetic VPOP leaves D8-D15 and the rebased SP unchanged") {
            let memory = makeMemory()
            let core = RE4GuestARMv6Core(memory: memory)
            let saved = try populateEpilogueImage(memory: memory, core: core)
            try memory.setProtectionRange(
                address: 0x8048, length: 64, protection: [.write],
                name: "j8-16-unreadable-vfp-save"
            )
            _ = try core.step() // first SUB is valid
            let vfp = try core.captureVFPD8ThroughD15Snapshot()
            let spBeforeFault = try core.registerValue(13)
            do {
                _ = try core.step() // VPOP attempts one complete read and fails
                throw NSError(domain: "J8.16", code: 2)
            } catch RE4GuestRuntimeError.memoryProtectionViolation(
                address: 0x8048, count: 64, access: "read",
                region: "j8-16-unreadable-vfp-save"
            ) { }
            let vfpAfterFault = try core.captureVFPD8ThroughD15Snapshot()
            let spAfterFault = try core.registerValue(13)
            try check(vfpAfterFault == vfp && spAfterFault == spBeforeFault &&
                      vfp.d8ThroughD15.allSatisfy { !saved.vfp.contains($0) },
                      "failed VPOP must not partially restore the VFP bank or publish SP")
            try check(try core.registerValue(15) == 0x5624,
                      "faulting VPOP should leave the Core at its pre-advanced next PC")
        }

        print("RESULT: \(passed)/2 passed; 0 failed")
        print("SCOPE: exact 8C148 #101 epilogue instruction words replayed over synthetic Guest Memory; D8-D15 plus R8/R10/R11 and R4-R7/PC stack restoration; stop before caller fetch.")
        print("LIMIT: no original Res4 bytes, original initializer, provider function, real SJLJ Resume, callback, personality, unwinder, pthread TSD, or application code is executed.")
    }
}
