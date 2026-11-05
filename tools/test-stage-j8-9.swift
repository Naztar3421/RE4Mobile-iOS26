import Foundation

@main
struct StageJ89ContextRestoreTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "J8.9", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func makeFrame(base: UInt32 = 0x8000, sp: UInt32 = 0x7FE8,
                          r7: UInt32 = 0x80A0, pc: UInt32 = 0x55A8,
                          gr0: UInt32 = 0xA0F00000, gr1: UInt32 = 0,
                          lsda: UInt32 = 0x001C0996) throws -> RE4StageJ89SJLJFrame {
        var frame = try RE4StageJ89SJLJFrame(baseAddress: base)
        try frame.storeWord(at: 0x08, value: gr0)
        try frame.storeWord(at: 0x0C, value: gr1)
        try frame.storeWord(at: 0x1C, value: lsda)
        try frame.storeWord(at: 0x20, value: r7)
        try frame.storeWord(at: 0x24, value: pc)
        try frame.storeWord(at: 0x28, value: sp)
        return frame
    }
    static func main() throws {
        let stack = try RE4StageJ89AddressRange(lowerBound: 0x7000, upperBoundExclusive: 0x9000)
        let text = try RE4StageJ89AddressRange(lowerBound: 0x5000, upperBoundExclusive: 0x6000)
        var passed = 0
        func test(_ name: String, _ body: () throws -> Void) throws {
            try body(); passed += 1; print("PASS: \(name)")
        }
        try test("01 #101 prologue stack delta preserves AAPCS 8-byte alignment") {
            try check(RE4StageJ89ContextRestorePreconditions.coreSaveBytes == 20 &&
                      RE4StageJ89ContextRestorePreconditions.extendedCoreSaveBytes == 12 &&
                      RE4StageJ89ContextRestorePreconditions.vfpSaveBytes == 64 &&
                      RE4StageJ89ContextRestorePreconditions.localAllocationBytes == 96 &&
                      RE4StageJ89ContextRestorePreconditions.totalPrologueStackDelta == 192 &&
                      (192 % 8) == 0, "prologue stack movement/alignment mismatch")
        }
        try test("02 frame base, saved SP and saved R7 offsets match #101") {
            let p = try RE4StageJ89ContextRestorePreconditions.inspect(
                frame: makeFrame(), stackRange: stack, codeRange: text)
            try check(p.savedSP == 0x7FE8 && p.savedR7 == 0x80A0 &&
                      p.savedSP + 0x18 == 0x8000 && p.savedSP + 0xB8 == p.savedR7,
                      "saved register/frame arithmetic mismatch")
        }
        try test("03 provider restores only R7, SP and PC before BX") {
            let p = try RE4StageJ89ContextRestorePreconditions.inspect(
                frame: makeFrame(), stackRange: stack, codeRange: text)
            try check(p.providerRestoresR7 && p.providerRestoresSP && p.providerRestoresPC &&
                      !p.providerRestoresOtherGPRs && !p.providerRestoresLR &&
                      !p.providerRestoresFullCPSR && p.bxDerivesInstructionStateFromPCBit0,
                      "provider restore scope was overstated")
        }
        try test("04 #101 LR and callee-saved registers return through stack epilogue") {
            let p = try RE4StageJ89ContextRestorePreconditions.inspect(
                frame: makeFrame(), stackRange: stack, codeRange: text)
            try check(p.targetStackSavedCoreRegisters ==
                      ["R4", "R5", "R6", "R7", "LR", "R8", "R10", "R11"] &&
                      p.targetEpiloguePopsSavedLRIntoPC &&
                      p.targetStackSavedVFPRegisters == ["D8","D9","D10","D11","D12","D13","D14","D15"] &&
                      p.targetEpilogueRestoresVFPRegisters,
                      "target epilogue save/restore inventory mismatch")
        }
        try test("05 personality GR0/GR1 are context data slots, not CPU R0/R1 restores") {
            let p = try RE4StageJ89ContextRestorePreconditions.inspect(
                frame: makeFrame(gr0: 0xA0F00000, gr1: 0), stackRange: stack, codeRange: text)
            try check(p.personalityGR0ExceptionPointer == 0xA0F00000 && p.personalityGR1 == 0,
                      "personality data slots changed")
        }
        try test("06 unaligned saved SP is rejected") {
            do {
                _ = try RE4StageJ89ContextRestorePreconditions.inspect(
                    frame: makeFrame(sp: 0x7FEC), stackRange: stack, codeRange: text)
                throw NSError(domain: "J8.9", code: 2)
            } catch RE4StageJ89Error.savedSPNotEightByteAligned(0x7FEC) { }
        }
        try test("07 inconsistent R7/SP relation is rejected") {
            do {
                _ = try RE4StageJ89ContextRestorePreconditions.inspect(
                    frame: makeFrame(r7: 0x80A4), stackRange: stack, codeRange: text)
                throw NSError(domain: "J8.9", code: 3)
            } catch RE4StageJ89Error.savedR7Relation(expected: 0x80A0, actual: 0x80A4) { }
        }
        try test("08 #101 continuation PC is ARM-aligned and executable") {
            let p = try RE4StageJ89ContextRestorePreconditions.inspect(
                frame: makeFrame(pc: 0x55A8), stackRange: stack, codeRange: text)
            try check(p.rawContinuationPC == 0x55A8 && p.continuationPC == 0x55A8 &&
                      p.instructionState == .arm, "#101 BX target should be ARM 0x55A8")
        }
        try test("09 BX bit zero selects Thumb without claiming full CPSR restore") {
            let p = try RE4StageJ89ContextRestorePreconditions.inspect(
                frame: makeFrame(pc: 0x55A9), stackRange: stack, codeRange: text)
            try check(p.rawContinuationPC == 0x55A9 && p.continuationPC == 0x55A8 &&
                      p.instructionState == .thumb && !p.providerRestoresFullCPSR,
                      "BX interworking classification mismatch")
        }
        try test("10 ARM BX low bits 10 are rejected") {
            do {
                _ = try RE4StageJ89ContextRestorePreconditions.inspect(
                    frame: makeFrame(pc: 0x55AA), stackRange: stack, codeRange: text)
                throw NSError(domain: "J8.9", code: 4)
            } catch RE4StageJ89Error.armBXOperandUnpredictable(0x55AA) { }
        }
        try test("11 restore inspection never applies context or transfers control") {
            let p = try RE4StageJ89ContextRestorePreconditions.inspect(
                frame: makeFrame(), stackRange: stack, codeRange: text)
            try check(!p.guestInstructionsExecuted && p.guestMemoryWrites == 0 &&
                      !p.cpuContextApplied && !p.controlTransferPerformed,
                      "J.8.9 must remain a data-only preflight")
        }
        print("RESULT: \(passed)/11 passed; 0 failed")
        print("SCOPE: static ARMv6 frame/ABI preconditions only; no Guest instruction, memory write, CPU restore, or BX executed.")
    }
}
