import Foundation

public enum RE4StageJ8SyntheticContextRestoreTests {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private final class Runner {
        var passed = 0
        var failed = 0
        var lines: [String] = []

        func test(_ name: String, _ body: () throws -> Void) {
            do {
                try body()
                passed += 1
                lines.append("PASS: \(name)")
            } catch {
                failed += 1
                lines.append("FAIL: \(name): \(error)")
            }
        }

        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw Failure(description: message) }
        }

        func expectJ8Error(_ body: () throws -> Void,
                           matching predicate: (RE4StageJ8Error) -> Bool,
                           message: String) throws {
            do {
                try body()
                throw Failure(description: "Expected error: \(message)")
            } catch let error as RE4StageJ8Error {
                guard predicate(error) else {
                    throw Failure(description: "Wrong J.8 error for \(message): \(error)")
                }
            }
        }
    }

    public static func run(evidenceURL: URL, crosswalkURL: URL) throws -> String {
        let j7 = try RE4StageJ7LandingPadContextModel(evidenceURL: evidenceURL, crosswalkURL: crosswalkURL)
        let range = try RE4StageJ8SyntheticCodeRange(lowerBound: 0x00005000,
                                                      upperBoundExclusive: 0x00006000)
        let runner = Runner()

        func samplePlan(row: Int = 20,
                        savedSP: UInt32 = 0xA1030000,
                        savedR7: UInt32 = 0xA1020000,
                        frameAddress: UInt32 = 0xA1010000,
                        exception: UInt32 = 0xA1040000) throws -> RE4StageJ7CleanupContextPlan {
            try j7.contextPlan(row: row, frameAddress: frameAddress,
                               savedR7: savedR7, savedSP: savedSP,
                               unwindExceptionPointer: exception)
        }

        runner.test("01 frame has exact 0x2C-byte synthetic span and word-aligned base") {
            let frame = try RE4StageJ8SyntheticContextRestoreHarness.makeSyntheticFrame(from: samplePlan())
            try runner.check(frame.byteCount == 0x2C && frame.baseAddress == 0xA1010000,
                             "frame span or base address")
        }
        runner.test("02 GR0 and GR1 are read from frame offsets +0x08/+0x0C") {
            let frame = try RE4StageJ8SyntheticContextRestoreHarness.makeSyntheticFrame(from: samplePlan(exception: 0x12345678))
            let gr0 = try frame.loadWord(at: 0x08)
            let gr1 = try frame.loadWord(at: 0x0C)
            try runner.check(gr0 == 0x12345678 && gr1 == 0,
                             "GR0/GR1 frame words")
        }
        runner.test("03 LSDA is preserved at frame offset +0x1C") {
            let frame = try RE4StageJ8SyntheticContextRestoreHarness.makeSyntheticFrame(from: samplePlan())
            let lsda = try frame.loadWord(at: 0x1C)
            try runner.check(lsda == RE4StageJ7LandingPadContextModel.lsdaVA,
                             "LSDA frame word")
        }
        runner.test("04 selector word at +0x04 remains SetIP dispatch-index minus one") {
            let plan = try samplePlan(row: 20)
            let frame = try RE4StageJ8SyntheticContextRestoreHarness.makeSyntheticFrame(from: plan)
            let selector = try frame.loadWord(at: 0x04)
            try runner.check(selector == 19 && plan.setIPArgument == 20,
                             "selector and SetIP mapping")
        }
        runner.test("05 R7/SP/PC are read from the three pinned restore slots") {
            let plan = try samplePlan(savedSP: 0xA1030000, savedR7: 0xA1021000)
            let frame = try RE4StageJ8SyntheticContextRestoreHarness.makeSyntheticFrame(from: plan)
            let result = try RE4StageJ8SyntheticContextRestoreHarness.inspectRestore(frame: frame, codeRange: range)
            try runner.check(result.restoredR7 == 0xA1021000 &&
                             result.restoredSP == 0xA1030000 &&
                             result.rawBXOperand == 0x55A8 && result.targetPC == 0x55A8,
                             "R7/SP/PC snapshot")
        }
        runner.test("06 valid restored SP satisfies the 8-byte alignment gate") {
            let frame = try RE4StageJ8SyntheticContextRestoreHarness.makeSyntheticFrame(from: samplePlan(savedSP: 0xA1030008))
            let result = try RE4StageJ8SyntheticContextRestoreHarness.inspectRestore(frame: frame, codeRange: range)
            try runner.check((result.restoredSP & 7) == 0, "SP must be 8-byte aligned")
        }
        runner.test("07 misaligned restored SP is rejected") {
            var frame = try RE4StageJ8SyntheticContextRestoreHarness.makeSyntheticFrame(from: samplePlan())
            try frame.storeWord(at: 0x28, value: 0xA1030004)
            try runner.expectJ8Error({ _ = try RE4StageJ8SyntheticContextRestoreHarness.inspectRestore(frame: frame, codeRange: range) },
                                     matching: { if case .stackPointerNotEightByteAligned = $0 { return true }; return false },
                                     message: "SP alignment")
        }
        runner.test("08 the audited 0x55A8 cleanup continuation is classified as ARM state") {
            let frame = try RE4StageJ8SyntheticContextRestoreHarness.makeSyntheticFrame(from: samplePlan())
            let result = try RE4StageJ8SyntheticContextRestoreHarness.inspectRestore(frame: frame, codeRange: range)
            try runner.check(result.targetPC == 0x55A8 && result.targetState == .arm,
                             "0x55A8 must remain an ARM-state target")
        }
        runner.test("09 an odd BX operand selects Thumb and clears only bit zero") {
            let target = try RE4StageJ8SyntheticContextRestoreHarness.interpretBXOperand(0x5203, codeRange: range)
            try runner.check(target.state == .thumb && target.address == 0x5202,
                             "Thumb interworking normalization")
        }
        runner.test("10 an aligned even BX operand selects ARM without address rewriting") {
            let target = try RE4StageJ8SyntheticContextRestoreHarness.interpretBXOperand(0x5204, codeRange: range)
            try runner.check(target.state == .arm && target.address == 0x5204,
                             "ARM word-aligned target")
        }
        runner.test("11 an ARM BX operand with low bits 10 is rejected as UNPREDICTABLE") {
            try runner.expectJ8Error({ _ = try RE4StageJ8SyntheticContextRestoreHarness.interpretBXOperand(0x5206, codeRange: range) },
                                     matching: { if case .unpredictableARMBranchAlignment(0x5206) = $0 { return true }; return false },
                                     message: "ARM low-bit pattern 10")
        }
        runner.test("12 ARM lower boundary is inclusive") {
            let target = try RE4StageJ8SyntheticContextRestoreHarness.interpretBXOperand(0x5000, codeRange: range)
            try runner.check(target.address == 0x5000 && target.state == .arm, "ARM lower bound")
        }
        runner.test("13 Thumb lower boundary is inclusive") {
            let target = try RE4StageJ8SyntheticContextRestoreHarness.interpretBXOperand(0x5001, codeRange: range)
            try runner.check(target.address == 0x5000 && target.state == .thumb, "Thumb lower bound")
        }
        runner.test("14 last word-aligned ARM address remains inside the upper boundary") {
            let target = try RE4StageJ8SyntheticContextRestoreHarness.interpretBXOperand(0x5FFC, codeRange: range)
            try runner.check(target.address == 0x5FFC && target.state == .arm, "last ARM slot")
        }
        runner.test("15 last halfword-aligned Thumb address remains inside the upper boundary") {
            let target = try RE4StageJ8SyntheticContextRestoreHarness.interpretBXOperand(0x5FFF, codeRange: range)
            try runner.check(target.address == 0x5FFE && target.state == .thumb, "last Thumb slot")
        }
        runner.test("16 ARM target at the exclusive upper boundary is rejected") {
            try runner.expectJ8Error({ _ = try RE4StageJ8SyntheticContextRestoreHarness.interpretBXOperand(0x6000, codeRange: range) },
                                     matching: { if case .branchTargetOutOfRange(_, 0x6000, .arm) = $0 { return true }; return false },
                                     message: "ARM upper bound")
        }
        runner.test("17 Thumb target at the exclusive upper boundary is rejected") {
            try runner.expectJ8Error({ _ = try RE4StageJ8SyntheticContextRestoreHarness.interpretBXOperand(0x6001, codeRange: range) },
                                     matching: { if case .branchTargetOutOfRange(_, 0x6000, .thumb) = $0 { return true }; return false },
                                     message: "Thumb upper bound")
        }
        runner.test("18 ARM target below the lower boundary is rejected") {
            try runner.expectJ8Error({ _ = try RE4StageJ8SyntheticContextRestoreHarness.interpretBXOperand(0x4FFC, codeRange: range) },
                                     matching: { if case .branchTargetOutOfRange(_, 0x4FFC, .arm) = $0 { return true }; return false },
                                     message: "ARM lower underflow")
        }
        runner.test("19 Thumb target below the lower boundary is rejected") {
            try runner.expectJ8Error({ _ = try RE4StageJ8SyntheticContextRestoreHarness.interpretBXOperand(0x4FFF, codeRange: range) },
                                     matching: { if case .branchTargetOutOfRange(_, 0x4FFE, .thumb) = $0 { return true }; return false },
                                     message: "Thumb lower underflow")
        }
        runner.test("20 UInt32.max Thumb pointer is rejected without address wrap") {
            try runner.expectJ8Error({ _ = try RE4StageJ8SyntheticContextRestoreHarness.interpretBXOperand(UInt32.max, codeRange: range) },
                                     matching: { if case .branchTargetOutOfRange(_, 0xFFFFFFFE, .thumb) = $0 { return true }; return false },
                                     message: "UInt32.max target")
        }
        runner.test("21 unaligned synthetic frame base is rejected") {
            try runner.expectJ8Error({ _ = try RE4StageJ8SyntheticFrame(baseAddress: 0xA1010002) },
                                     matching: { if case .misalignedFrameBase = $0 { return true }; return false },
                                     message: "frame alignment")
        }
        runner.test("22 malformed synthetic frame length is rejected") {
            try runner.expectJ8Error({ _ = try RE4StageJ8SyntheticFrame(baseAddress: 0xA1010000, bytes: [UInt8](repeating: 0, count: 8)) },
                                     matching: { if case .invalidFrameLength(8) = $0 { return true }; return false },
                                     message: "frame length")
        }
        runner.test("23 no Guest execution, Guest Memory write, CPU apply or control transfer is reported") {
            let frame = try RE4StageJ8SyntheticContextRestoreHarness.makeSyntheticFrame(from: samplePlan())
            let result = try RE4StageJ8SyntheticContextRestoreHarness.inspectRestore(frame: frame, codeRange: range)
            try runner.check(!result.guestInstructionsExecuted && result.guestMemoryWrites == 0 &&
                             !result.cpuContextApplied && !result.controlTransferPerformed,
                             "the harness must remain data-only")
        }
        runner.test("24 every cleanup selector uses the same audited ARM continuation") {
            let snapshots = try (2...20).map { row -> RE4StageJ8SyntheticRestoreSnapshot in
                let plan = try samplePlan(row: row)
                let frame = try RE4StageJ8SyntheticContextRestoreHarness.makeSyntheticFrame(from: plan)
                return try RE4StageJ8SyntheticContextRestoreHarness.inspectRestore(frame: frame, codeRange: range)
            }
            try runner.check(Set(snapshots.map(\.targetPC)) == [0x55A8] &&
                             Set(snapshots.map(\.targetState)) == [.arm],
                             "cleanup rows must converge on 0x55A8 in ARM state")
        }
        runner.test("25 the harness does not reinterpret the dispatch selector as a PC") {
            let plan = try samplePlan(row: 10)
            let frame = try RE4StageJ8SyntheticContextRestoreHarness.makeSyntheticFrame(from: plan)
            let result = try RE4StageJ8SyntheticContextRestoreHarness.inspectRestore(frame: frame, codeRange: range)
            try runner.check(result.selectorWord == 9 && result.rawBXOperand == 0x55A8 &&
                             result.selectorWord != result.rawBXOperand,
                             "selector word and saved branch operand must remain independent")
        }
        runner.test("26 malformed synthetic code range is rejected") {
            try runner.expectJ8Error({ _ = try RE4StageJ8SyntheticCodeRange(lowerBound: 0x6000, upperBoundExclusive: 0x5000) },
                                     matching: { if case .invalidCodeRange = $0 { return true }; return false },
                                     message: "reversed code range")
        }

        runner.lines.append("RESULT: \(runner.passed)/\(runner.passed + runner.failed) passed; \(runner.failed) failed")
        runner.lines.append("SCOPE: Stage J.7 plan -> local 0x2C-byte synthetic frame -> immutable restore snapshot. ARMv6 BX operand state/address is classified as data only. No Guest code, CPU context, Guest Memory, branch, callback, personality, unwinder or pthread TSD operation was executed.")
        runner.lines.append("LIMIT: stack alignment is validated on synthetic inputs; code-range bounds are caller-supplied synthetic bounds. This does not prove the live process stack, mapped executable ranges, or real instruction fetch behavior.")
        if runner.failed != 0 { throw Failure(description: runner.lines.joined(separator: "\n")) }
        return runner.lines.joined(separator: "\n")
    }
}
