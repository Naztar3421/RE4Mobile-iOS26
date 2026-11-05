import Foundation

public enum RE4StageJ8SyntheticContextIntegrityTests {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private final class Runner {
        var passed = 0, failed = 0
        var lines: [String] = []
        func test(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; lines.append("PASS: \(name)") }
            catch { failed += 1; lines.append("FAIL: \(name): \(error)") }
        }
        func check(_ ok: @autoclosure () -> Bool, _ message: String) throws {
            guard ok() else { throw Failure(description: message) }
        }
        func expect(_ body: () throws -> Void,
                    matching predicate: (RE4StageJ8IntegrityError) -> Bool,
                    message: String) throws {
            do { try body(); throw Failure(description: "Expected error: \(message)") }
            catch let error as RE4StageJ8IntegrityError {
                guard predicate(error) else { throw Failure(description: "Wrong integrity error for \(message): \(error)") }
            }
        }
        func expectJ8(_ body: () throws -> Void,
                      matching predicate: (RE4StageJ8Error) -> Bool,
                      message: String) throws {
            do { try body(); throw Failure(description: "Expected J.8 error: \(message)") }
            catch let error as RE4StageJ8Error {
                guard predicate(error) else { throw Failure(description: "Wrong J.8 error for \(message): \(error)") }
            }
        }
    }

    public static func run(evidenceURL: URL, crosswalkURL: URL) throws -> String {
        let j7 = try RE4StageJ7LandingPadContextModel(evidenceURL: evidenceURL, crosswalkURL: crosswalkURL)
        let range = try RE4StageJ8SyntheticCodeRange(lowerBound: 0x5000, upperBoundExclusive: 0x6000)
        let runner = Runner()

        func plan(row: Int = 20, sp: UInt32 = 0xA1030000,
                  r7: UInt32 = 0xA1020000, base: UInt32 = 0xA1010000,
                  gr0: UInt32 = 0xA1040000) throws -> RE4StageJ7CleanupContextPlan {
            try j7.contextPlan(row: row, frameAddress: base, savedR7: r7,
                               savedSP: sp, unwindExceptionPointer: gr0)
        }
        func replacing(_ p: RE4StageJ7CleanupContextPlan,
                       initializerVA: UInt32? = nil, frameBaseOffset: UInt32? = nil,
                       lsdaVA: UInt32? = nil, row: Int? = nil,
                       selector: UInt32? = nil, dispatchIndex: UInt32? = nil,
                       cleanupObjectCount: UInt32? = nil, actionOffset: UInt32? = nil,
                       savedPC: UInt32? = nil, cleanupPC: UInt32? = nil,
                       gr0Offset: UInt32? = nil, gr1Offset: UInt32? = nil,
                       gr1Value: UInt32? = nil, setIPArgument: UInt32? = nil,
                       setIPStoredSelector: UInt32? = nil, pcOverwriteSkipped: Bool? = nil,
                       personalityReturnCode: UInt32? = nil, frameRetained: Bool? = nil,
                       cleanupReadsGR0: Bool? = nil, resumeGR0: UInt32? = nil,
                       resumeSentinel: UInt32? = nil, resumeGetIP: UInt32? = nil,
                       resumeContinues: Bool? = nil, controlTransfer: Bool? = nil) -> RE4StageJ7CleanupContextPlan {
            RE4StageJ7CleanupContextPlan(
                initializerVA: initializerVA ?? p.initializerVA,
                frameAddress: p.frameAddress,
                frameBaseOffsetFromPostPrologueSP: frameBaseOffset ?? p.frameBaseOffsetFromPostPrologueSP,
                lsdaVA: lsdaVA ?? p.lsdaVA, row: row ?? p.row,
                selector: selector ?? p.selector, dispatchIndex: dispatchIndex ?? p.dispatchIndex,
                cleanupObjectCount: cleanupObjectCount ?? p.cleanupObjectCount,
                actionOffset: actionOffset ?? p.actionOffset,
                matchedCallVAs: p.matchedCallVAs, matchStatus: p.matchStatus,
                savedR7: p.savedR7, savedSP: p.savedSP,
                savedContinuationPC: savedPC ?? p.savedContinuationPC,
                cleanupContinuationPC: cleanupPC ?? p.cleanupContinuationPC,
                setGR0Offset: gr0Offset ?? p.setGR0Offset, setGR0Value: p.setGR0Value,
                setGR1Offset: gr1Offset ?? p.setGR1Offset, setGR1Value: gr1Value ?? p.setGR1Value,
                setIPArgument: setIPArgument ?? p.setIPArgument,
                setIPStoredSelector: setIPStoredSelector ?? p.setIPStoredSelector,
                contextPCOverwriteSkipped: pcOverwriteSkipped ?? p.contextPCOverwriteSkipped,
                personalityReturnCode: personalityReturnCode ?? p.personalityReturnCode,
                frameRetainedAtTSDTop: frameRetained ?? p.frameRetainedAtTSDTop,
                cleanupEntryReadsGR0: cleanupReadsGR0 ?? p.cleanupEntryReadsGR0,
                resumeExceptionArgument: resumeGR0 ?? p.resumeExceptionArgument,
                resumeSelectorSentinel: resumeSentinel ?? p.resumeSelectorSentinel,
                resumeGetIPAfterCleanup: resumeGetIP ?? p.resumeGetIPAfterCleanup,
                resumeContinuesPastCurrentFrame: resumeContinues ?? p.resumeContinuesPastCurrentFrame,
                controlTransferPerformed: controlTransfer ?? p.controlTransferPerformed)
        }

        runner.test("J8.1-01 baseline J.7 cleanup plan passes strict cross-stage validation") {
            try RE4StageJ8SyntheticContextIntegrityGuard.validatePlan(plan())
        }
        runner.test("J8.1-02 all seven known data words round-trip against the expected plan") {
            let p = try plan(row: 7, sp: 0xA1030010, r7: 0xA5A55A5A, gr0: 0xDEADBEEF)
            let frame = try RE4StageJ8SyntheticContextIntegrityGuard.makeSyntheticFrame(from: p)
            let expected = RE4StageJ8IntegrityExpectedFields(plan: p)
            let snap = try RE4StageJ8SyntheticContextIntegrityGuard.inspectRestore(frame: frame, codeRange: range, expected: expected)
            try runner.check(snap.selectorWord == p.selector && snap.unwindGR0 == p.setGR0Value &&
                snap.unwindGR1 == p.setGR1Value && snap.lsdaVA == p.lsdaVA &&
                snap.restoredR7 == p.savedR7 && snap.restoredSP == p.savedSP &&
                snap.rawBXOperand == p.savedContinuationPC, "known frame fields were not preserved")
        }
        runner.test("J8.1-03 every frame word uses little-endian byte order") {
            var frame = try RE4StageJ8SyntheticFrame(baseAddress: 0xA1010000)
            try frame.storeWord(at: 0x08, value: 0x12345678)
            let readback = try frame.loadWord(at: 0x08)
            try runner.check(Array(frame.rawBytes[0x08...0x0B]) == [0x78, 0x56, 0x34, 0x12] &&
                readback == 0x12345678, "little-endian byte order")
        }
        runner.test("J8.1-04 bit-flip fault injection in each of the seven defined slots is detected") {
            let p = try plan(row: 20, sp: 0xA1030008, r7: 0xA1021000, gr0: 0xA1040010)
            let frame = try RE4StageJ8SyntheticContextIntegrityGuard.makeSyntheticFrame(from: p)
            let expected = RE4StageJ8IntegrityExpectedFields(plan: p)
            let mutations: [(String, Int, UInt32)] = [
                ("selectorWord", 0x04, p.selector ^ 1), ("unwindGR0", 0x08, p.setGR0Value ^ 1),
                ("unwindGR1", 0x0C, p.setGR1Value ^ 1), ("lsdaVA", 0x1C, p.lsdaVA ^ 1),
                ("savedR7", 0x20, p.savedR7 ^ 1), ("savedPC", 0x24, p.savedContinuationPC ^ 4),
                ("savedSP", 0x28, p.savedSP ^ 8)]
            for (field, offset, value) in mutations {
                var bad = frame
                try bad.storeWord(at: offset, value: value)
                try runner.expect({
                    _ = try RE4StageJ8SyntheticContextIntegrityGuard.inspectRestore(frame: bad, codeRange: range, expected: expected)
                }, matching: { if case .fieldMismatch(let actual, _, _) = $0 { return actual == field }; return false },
                   message: "fault-injected \(field)")
            }
        }
        runner.test("J8.1-05 changed frame base is detected as a context identity mismatch") {
            let p = try plan()
            let frame = try RE4StageJ8SyntheticContextIntegrityGuard.makeSyntheticFrame(from: p)
            let moved = try RE4StageJ8SyntheticFrame(baseAddress: frame.baseAddress + 4, bytes: frame.rawBytes)
            try runner.expect({
                _ = try RE4StageJ8SyntheticContextIntegrityGuard.inspectRestore(frame: moved, codeRange: range,
                    expected: RE4StageJ8IntegrityExpectedFields(plan: p))
            }, matching: { if case .fieldMismatch("frameBaseAddress", _, _) = $0 { return true }; return false },
               message: "frame base mismatch")
        }
        runner.test("J8.1-06 zero GR0 is preserved without inventing a nonzero constraint") {
            let p = try plan(gr0: 0)
            let frame = try RE4StageJ8SyntheticContextIntegrityGuard.makeSyntheticFrame(from: p)
            let snap = try RE4StageJ8SyntheticContextIntegrityGuard.inspectRestore(frame: frame, codeRange: range,
                expected: RE4StageJ8IntegrityExpectedFields(plan: p))
            try runner.check(snap.unwindGR0 == 0, "GR0 zero must round-trip as data")
        }
        runner.test("J8.1-07 selector zero is rejected for the cleanup-context path") {
            var frame = try RE4StageJ8SyntheticContextIntegrityGuard.makeSyntheticFrame(from: plan())
            try frame.storeWord(at: 0x04, value: 0)
            let changed = replacing(try plan(), selector: 0, setIPStoredSelector: 0)
            try runner.expect({
                _ = try RE4StageJ8SyntheticContextIntegrityGuard.inspectRestore(frame: frame, codeRange: range,
                    expected: RE4StageJ8IntegrityExpectedFields(plan: changed))
            }, matching: { if case .invalidSelector(0) = $0 { return true }; return false }, message: "selector zero")
        }
        runner.test("J8.1-08 selector 20 is rejected outside the 1...19 cleanup range") {
            var frame = try RE4StageJ8SyntheticContextIntegrityGuard.makeSyntheticFrame(from: plan())
            try frame.storeWord(at: 0x04, value: 20)
            let changed = replacing(try plan(), selector: 20, setIPStoredSelector: 20)
            try runner.expect({
                _ = try RE4StageJ8SyntheticContextIntegrityGuard.inspectRestore(frame: frame, codeRange: range,
                    expected: RE4StageJ8IntegrityExpectedFields(plan: changed))
            }, matching: { if case .invalidSelector(20) = $0 { return true }; return false }, message: "selector 20")
        }
        runner.test("J8.1-09 nonzero GR1 is rejected by the audited zero-action profile") {
            var frame = try RE4StageJ8SyntheticContextIntegrityGuard.makeSyntheticFrame(from: plan())
            try frame.storeWord(at: 0x0C, value: 1)
            let changed = replacing(try plan(), gr1Value: 1)
            try runner.expect({
                _ = try RE4StageJ8SyntheticContextIntegrityGuard.inspectRestore(frame: frame, codeRange: range,
                    expected: RE4StageJ8IntegrityExpectedFields(plan: changed))
            }, matching: { if case .invalidGR1(1) = $0 { return true }; return false }, message: "GR1 nonzero")
        }
        runner.test("J8.1-10 wrong LSDA is rejected against the pinned 8C148 value") {
            var frame = try RE4StageJ8SyntheticContextIntegrityGuard.makeSyntheticFrame(from: plan())
            try frame.storeWord(at: 0x1C, value: 0x001C099A)
            let changed = replacing(try plan(), lsdaVA: 0x001C099A)
            try runner.expect({
                _ = try RE4StageJ8SyntheticContextIntegrityGuard.inspectRestore(frame: frame, codeRange: range,
                    expected: RE4StageJ8IntegrityExpectedFields(plan: changed))
            }, matching: { if case .invalidLSDA(0x001C099A) = $0 { return true }; return false }, message: "LSDA corruption")
        }
        runner.test("J8.1-11 an in-range but wrong saved PC is rejected") {
            var frame = try RE4StageJ8SyntheticContextIntegrityGuard.makeSyntheticFrame(from: plan())
            try frame.storeWord(at: 0x24, value: 0x55AC)
            let changed = replacing(try plan(), savedPC: 0x55AC)
            try runner.expect({
                _ = try RE4StageJ8SyntheticContextIntegrityGuard.inspectRestore(frame: frame, codeRange: range,
                    expected: RE4StageJ8IntegrityExpectedFields(plan: changed))
            }, matching: { if case .invalidSavedPC(0x55AC) = $0 { return true }; return false }, message: "wrong in-range PC")
        }
        runner.test("J8.1-12 Thumb-tagged PC is rejected for the audited ARM cleanup continuation") {
            var frame = try RE4StageJ8SyntheticContextIntegrityGuard.makeSyntheticFrame(from: plan())
            try frame.storeWord(at: 0x24, value: 0x55A9)
            let changed = replacing(try plan(), savedPC: 0x55A9)
            try runner.expect({
                _ = try RE4StageJ8SyntheticContextIntegrityGuard.inspectRestore(frame: frame, codeRange: range,
                    expected: RE4StageJ8IntegrityExpectedFields(plan: changed))
            }, matching: { if case .invalidSavedPC(0x55A9) = $0 { return true }; return false }, message: "Thumb-tagged PC")
        }
        runner.test("J8.1-13 unknown frame bytes remain opaque and are preserved") {
            let p = try plan()
            let opaque = [UInt8](repeating: 0xA5, count: RE4StageJ8SyntheticFrame.byteCount)
            var frame = try RE4StageJ8SyntheticFrame(baseAddress: p.frameAddress, bytes: opaque)
            try frame.storeWord(at: 0x04, value: p.setIPStoredSelector)
            try frame.storeWord(at: 0x08, value: p.setGR0Value)
            try frame.storeWord(at: 0x0C, value: p.setGR1Value)
            try frame.storeWord(at: 0x1C, value: p.lsdaVA)
            try frame.storeWord(at: 0x20, value: p.savedR7)
            try frame.storeWord(at: 0x24, value: p.savedContinuationPC)
            try frame.storeWord(at: 0x28, value: p.savedSP)
            let before = Array(opaque[0x00...0x03]) + Array(opaque[0x10...0x1B])
            _ = try RE4StageJ8SyntheticContextIntegrityGuard.inspectRestore(frame: frame, codeRange: range,
                expected: RE4StageJ8IntegrityExpectedFields(plan: p))
            let after = Array(frame.rawBytes[0x00...0x03]) + Array(frame.rawBytes[0x10...0x1B])
            try runner.check(after == before, "opaque/unmodeled bytes were altered")
        }
        runner.test("J8.1-14 frame ending at 0x1_0000_0000 is accepted") {
            let base = UInt32.max - UInt32(RE4StageJ8SyntheticFrame.byteCount) + 1
            let p = try plan(base: base)
            let frame = try RE4StageJ8SyntheticContextIntegrityGuard.makeSyntheticFrame(from: p)
            try runner.check(UInt64(frame.baseAddress) + UInt64(frame.byteCount) == UInt64(UInt32.max) + 1,
                             "exact 32-bit exclusive-end boundary")
        }
        runner.test("J8.1-15 frame range extending beyond UInt32.max is rejected") {
            let p = try plan(base: 0xFFFFFFD8)
            try runner.expect({
                _ = try RE4StageJ8SyntheticContextIntegrityGuard.makeSyntheticFrame(from: p)
            }, matching: { if case .frameAddressRangeOverflow(0xFFFFFFD8, 0x2C) = $0 { return true }; return false },
               message: "frame range wrap")
        }
        runner.test("J8.1-16 word reads reject negative, unaligned and exclusive-end offsets") {
            let frame = try RE4StageJ8SyntheticFrame(baseAddress: 0xA1010000)
            for offset in [-4, 0x05, 0x2C, Int.max] {
                try runner.expectJ8({ _ = try frame.loadWord(at: offset) },
                    matching: { if case .frameWordOutOfBounds(offset) = $0 { return true }; return false },
                    message: "read offset \(offset)")
            }
        }
        runner.test("J8.1-17 word writes reject negative, unaligned and exclusive-end offsets") {
            var frame = try RE4StageJ8SyntheticFrame(baseAddress: 0xA1010000)
            for offset in [-4, 0x05, 0x2C, Int.max] {
                try runner.expectJ8({ try frame.storeWord(at: offset, value: 1) },
                    matching: { if case .frameWordOutOfBounds(offset) = $0 { return true }; return false },
                    message: "write offset \(offset)")
            }
        }
        runner.test("J8.1-18 invalid J.7 frame offsets and SetIP arithmetic are rejected before frame creation") {
            let p = try plan()
            let bad = [replacing(p, gr0Offset: 0x0C), replacing(p, gr1Offset: 0x08),
                replacing(p, setIPArgument: p.setIPArgument + 1),
                replacing(p, setIPStoredSelector: p.setIPStoredSelector + 1),
                replacing(p, gr1Value: 1), replacing(p, selector: p.selector - 1),
                replacing(p, dispatchIndex: p.dispatchIndex + 1)]
            for item in bad {
                try runner.expect({
                    _ = try RE4StageJ8SyntheticContextIntegrityGuard.makeSyntheticFrame(from: item)
                }, matching: { if case .invalidPlanField = $0 { return true }; return false },
                   message: "corrupt frame offset / SetIP plan")
            }
        }
        runner.test("J8.1-19 wrong target identity and personality facts are rejected") {
            let p = try plan()
            let bad = [replacing(p, initializerVA: 0x518C), replacing(p, frameBaseOffset: 0x1C),
                replacing(p, lsdaVA: 0x001C099A), replacing(p, savedPC: 0x55AC),
                replacing(p, cleanupPC: 0x55AC), replacing(p, personalityReturnCode: 6),
                replacing(p, pcOverwriteSkipped: false), replacing(p, actionOffset: 1),
                replacing(p, cleanupObjectCount: p.cleanupObjectCount + 1)]
            for item in bad {
                try runner.expect({
                    _ = try RE4StageJ8SyntheticContextIntegrityGuard.makeSyntheticFrame(from: item)
                }, matching: { if case .invalidPlanField = $0 { return true }; return false },
                   message: "corrupt target/personality plan")
            }
        }
        runner.test("J8.1-20 SJLJ Resume and current-frame retention invariants are enforced") {
            let p = try plan()
            let bad = [replacing(p, frameRetained: false), replacing(p, cleanupReadsGR0: false),
                replacing(p, resumeGR0: p.resumeExceptionArgument ^ 1),
                replacing(p, resumeSentinel: 0xFFFFFFFE), replacing(p, resumeGetIP: 1),
                replacing(p, resumeContinues: false), replacing(p, controlTransfer: true)]
            for item in bad {
                try runner.expect({
                    _ = try RE4StageJ8SyntheticContextIntegrityGuard.makeSyntheticFrame(from: item)
                }, matching: { if case .invalidPlanField = $0 { return true }; return false },
                   message: "corrupt SJLJ Resume plan")
            }
        }
        runner.test("J8.1-21 all 19 nonzero cleanup selectors validate and converge on 0x55A8") {
            for row in 2...20 {
                let p = try plan(row: row)
                try RE4StageJ8SyntheticContextIntegrityGuard.validatePlan(p)
                let frame = try RE4StageJ8SyntheticContextIntegrityGuard.makeSyntheticFrame(from: p)
                let snap = try RE4StageJ8SyntheticContextIntegrityGuard.inspectRestore(frame: frame, codeRange: range,
                    expected: RE4StageJ8IntegrityExpectedFields(plan: p))
                try runner.check(snap.selectorWord == UInt32(row - 1) && snap.targetPC == 0x55A8 &&
                    snap.targetState == .arm, "row \(row) did not converge")
            }
        }
        runner.test("J8.1-22 misaligned saved SP still fails after exact field comparison") {
            let p = try plan(sp: 0xA1030004)
            let frame = try RE4StageJ8SyntheticContextIntegrityGuard.makeSyntheticFrame(from: p)
            try runner.expectJ8({
                _ = try RE4StageJ8SyntheticContextIntegrityGuard.inspectRestore(frame: frame, codeRange: range,
                    expected: RE4StageJ8IntegrityExpectedFields(plan: p))
            }, matching: { if case .stackPointerNotEightByteAligned(0xA1030004) = $0 { return true }; return false },
               message: "misaligned saved SP")
        }
        runner.test("J8.1-23 code interval boundaries remain delegated to the original J.8 BX checker") {
            let p = try plan()
            let frame = try RE4StageJ8SyntheticContextIntegrityGuard.makeSyntheticFrame(from: p)
            let narrow = try RE4StageJ8SyntheticCodeRange(lowerBound: 0x5600, upperBoundExclusive: 0x5700)
            try runner.expectJ8({
                _ = try RE4StageJ8SyntheticContextIntegrityGuard.inspectRestore(frame: frame, codeRange: narrow,
                    expected: RE4StageJ8IntegrityExpectedFields(plan: p))
            }, matching: { if case .branchTargetOutOfRange(_, 0x55A8, .arm) = $0 { return true }; return false },
               message: "synthetic range excludes cleanup target")
        }
        runner.test("J8.1-24 strict snapshot explicitly remains data-only") {
            let p = try plan()
            let frame = try RE4StageJ8SyntheticContextIntegrityGuard.makeSyntheticFrame(from: p)
            let snap = try RE4StageJ8SyntheticContextIntegrityGuard.inspectRestore(frame: frame, codeRange: range,
                expected: RE4StageJ8IntegrityExpectedFields(plan: p))
            try runner.check(!snap.guestInstructionsExecuted && snap.guestMemoryWrites == 0 &&
                !snap.cpuContextApplied && !snap.controlTransferPerformed,
                "J.8.1 must not apply a real context or branch")
        }

        runner.lines.append("RESULT: \(runner.passed)/\(runner.passed + runner.failed) passed; \(runner.failed) failed")
        runner.lines.append("SCOPE: 24 supplemental J.8.1 integrity tests. Together with the original J.8 26 tests, the suite contains 50 top-level host tests.")
        runner.lines.append("SCOPE: copied J.7 plans and local synthetic byte arrays only; no Guest instructions, CPU context, Guest Memory, branch, callback, personality, unwinder, or pthread TSD operation.")
        runner.lines.append("LIMIT: opaque frame bytes remain uninterpreted; exact range/SP assertions use supplied synthetic values and do not prove live memory mappings or stack state.")
        if runner.failed != 0 { throw Failure(description: runner.lines.joined(separator: "\n")) }
        return runner.lines.joined(separator: "\n")
    }
}
