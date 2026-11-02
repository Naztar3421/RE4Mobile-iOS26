import Foundation

public enum RE4StageJ84SJLJResumeChainTests {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private final class Runner {
        var passed = 0
        var failed = 0
        var lines: [String] = []
        func test(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; lines.append("PASS: \(name)") }
            catch { failed += 1; lines.append("FAIL: \(name): \(error)") }
        }
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw Failure(description: message) }
        }
        func expectJ84(_ body: () throws -> Void,
                       matching predicate: (RE4StageJ84Error) -> Bool,
                       message: String) throws {
            do { try body(); throw Failure(description: "Expected J.8.4 error: \(message)") }
            catch let error as RE4StageJ84Error {
                guard predicate(error) else { throw Failure(description: "Wrong J.8.4 error for \(message): \(error)") }
            }
        }
    }

    private struct Environment {
        let lsda: RE4StageJ6ExtraProductListLSDA
        let j7: RE4StageJ7LandingPadContextModel
    }
    private struct Fixture {
        let machine: RE4StageJ6SJLJStateMachine
        let handoff: RE4StageJ83HandoffInput
        let cleanup: UInt32
        let middleInner: UInt32
        let middleOuter: UInt32
        let handler: UInt32
        let row: Int
    }

    public static func run(lsdaHexURL: URL, evidenceURL: URL,
                           crosswalkURL: URL) throws -> String {
        let env = try makeEnvironment(lsdaHexURL: lsdaHexURL,
                                      evidenceURL: evidenceURL,
                                      crosswalkURL: crosswalkURL)
        let runner = Runner()

        runner.test("01 Resume walks cleanup, two intermediate frames, and the enclosing handler in stack order") {
            let f = try makeFixture(env: env, row: 20)
            let result = try complete(f)
            try runner.check(result.resumeVisitAddresses == [f.cleanup, f.middleInner, f.middleOuter, f.handler],
                             "unexpected multi-frame SJLJ visit order")
        }
        runner.test("02 cleanup sentinel is written before Resume and GetIP wraps to zero") {
            let f = try makeFixture(env: env, row: 20)
            let result = try complete(f)
            try runner.check(result.selectorBeforeCleanup == 19 &&
                             result.selectorAfterCleanup == UInt32.max &&
                             result.getIPAfterCleanup == 0,
                             "cleanup completion must transition raw selector 19 -> FFFFFFFF -> GetIP 0")
        }
        runner.test("03 TSD top remains the cleanup frame across sentinel write") {
            let f = try makeFixture(env: env, row: 8)
            let result = try complete(f)
            try runner.check(result.tsdTopBeforeCleanup == f.cleanup &&
                             result.tsdTopAfterSentinelWrite == f.cleanup,
                             "sentinel write must not unlink the selected cleanup frame")
        }
        runner.test("04 each intermediate frame is visited as ordinary cleanup and continues") {
            let f = try makeFixture(env: env, row: 14)
            let result = try complete(f)
            try runner.check(result.intermediateFrameAddresses == [f.middleInner, f.middleOuter] &&
                             result.intermediateDecisions == [.continueUnwind, .continueUnwind],
                             "every intermediate frame must continue without selecting a handler")
        }
        runner.test("05 intermediate frames are not classified as the private_2 handler") {
            let f = try makeFixture(env: env, row: 3)
            let result = try complete(f)
            try runner.check(result.handlerFrameAddress == f.handler &&
                             result.resumeVisitAddresses.last == f.handler &&
                             result.intermediateFrameAddresses.allSatisfy { $0 != f.handler },
                             "only the frame named by private_2 may receive handler cleanup actions")
        }
        runner.test("06 the outer handler receives handlerCleanup and the synthetic install decision") {
            let f = try makeFixture(env: env, row: 10)
            let result = try complete(f)
            try runner.check(result.handlerAction == .handlerCleanup &&
                             result.handlerDecision == .installCleanupContext(row: 0, landingPadIndex: 0),
                             "outer handler did not receive the expected handler action/result")
        }
        runner.test("07 INSTALL_CONTEXT metadata matches the selected outer handler frame") {
            let f = try makeFixture(env: env, row: 18)
            let result = try complete(f)
            let handler = f.machine.frame(threadID: 1, address: f.handler)
            try runner.check(result.installFrameAddress == f.handler &&
                             result.installLSDArow == 0 && result.installLandingPadIndex == 0 &&
                             result.installSavedR7 == handler?.savedR7 &&
                             result.installSavedSP == handler?.savedSP &&
                             result.installSavedPC == handler?.continuationPC,
                             "INSTALL_CONTEXT fields do not match the enclosing handler")
        }
        runner.test("08 post-Resume synthetic TSD top becomes the selected handler") {
            let f = try makeFixture(env: env, row: 4)
            let result = try complete(f)
            try runner.check(result.finalTSDTopAddress == f.handler &&
                             f.machine.top(threadID: 1) == f.handler,
                             "phase 2 must retain the selected outer handler at synthetic TSD top")
        }
        runner.test("09 completed cleanup record remains inspectable with the sentinel") {
            let f = try makeFixture(env: env, row: 7)
            let result = try complete(f)
            let cleanup = f.machine.frame(threadID: 1, address: f.cleanup)
            try runner.check(result.completedCleanupFrameRemainsRegistered &&
                             result.completedCleanupFrameHasSentinel &&
                             cleanup?.selectorRaw == UInt32.max && cleanup?.callSiteIP == 0,
                             "completed host frame record must preserve the sentinel for audit")
        }
        runner.test("10 every audited nonzero #101 selector row 2...20 can traverse the chain") {
            for row in 2...20 {
                let f = try makeFixture(env: env, row: row)
                let result = try complete(f)
                try runner.check(result.selectorBeforeCleanup == UInt32(row - 1) &&
                                 result.selectorAfterCleanup == UInt32.max &&
                                 result.resumeVisitAddresses == [f.cleanup, f.middleInner, f.middleOuter, f.handler],
                                 "row \(row) did not complete through the same multi-frame path")
            }
        }
        runner.test("11 private_2 handler absent from chain is rejected as end-of-stack") {
            let f = try makeFixture(env: env, row: 20)
            try runner.expectJ84({
                _ = try RE4StageJ84SJLJResumeChainModel.completeCleanupAndResumeAcrossChain(
                    machine: f.machine, threadID: 1, handoff: f.handoff,
                    exception: RE4StageJ6SJLJException(private1: 0, private2: 0x7990))
            }, matching: { if case .handlerNotInChain(0x7990) = $0 { return true }; return false },
               message: "nonexistent handler must not be fabricated")
            try runner.check(f.machine.frame(threadID: 1, address: f.cleanup)?.selectorRaw == UInt32.max,
                             "failed traversal should record the host sentinel before the missing target is discovered")
        }
        runner.test("12 private_2 pointing to an intermediate non-handler frame is rejected") {
            let f = try makeFixture(env: env, row: 12)
            try runner.expectJ84({
                _ = try RE4StageJ84SJLJResumeChainModel.completeCleanupAndResumeAcrossChain(
                    machine: f.machine, threadID: 1, handoff: f.handoff,
                    exception: RE4StageJ6SJLJException(private1: 0, private2: f.middleOuter))
            }, matching: { if case .handlerAddressIsNotHandler(f.middleOuter) = $0 { return true }; return false },
               message: "registered intermediate frame is not a handler")
        }
        runner.test("13 missing intermediate frame record is reported as corrupt chain") {
            let f = try makeFixture(env: env, row: 16)
            try runner.check(f.machine.removeFrameRecordForTesting(threadID: 1, address: f.middleOuter),
                             "fault injection could not remove the synthetic intermediate record")
            try runner.expectJ84({
                _ = try RE4StageJ84SJLJResumeChainModel.completeCleanupAndResumeAcrossChain(
                    machine: f.machine, threadID: 1, handoff: f.handoff,
                    exception: RE4StageJ6SJLJException(private1: 0, private2: f.handler))
            }, matching: { if case .corruptFrameChain(f.middleOuter) = $0 { return true }; return false },
               message: "dangling predecessor must not be silently skipped")
        }
        runner.test("14 mismatched J.8.2/J.7 frame contract is rejected before sentinel mutation") {
            let f = try makeFixture(env: env, row: 9)
            let badPlan = RE4StageJ6ContextInstallPlan(
                frameAddress: f.cleanup + 4, action: f.handoff.phase2Plan.action,
                lsdaRow: f.handoff.phase2Plan.lsdaRow,
                landingPadIndex: f.handoff.phase2Plan.landingPadIndex,
                savedR7: f.handoff.phase2Plan.savedR7,
                savedSP: f.handoff.phase2Plan.savedSP,
                savedContinuationPC: f.handoff.phase2Plan.savedContinuationPC,
                landingPadPC: f.handoff.phase2Plan.landingPadPC,
                frameRetainedAtTSDTop: true, controlTransferPerformed: false)
            let badHandoff = RE4StageJ83HandoffInput(phase2Plan: badPlan,
                j7Plan: f.handoff.j7Plan, finalTSDTopAddress: f.cleanup,
                controlTransferPerformed: false)
            try runner.expectJ84({
                _ = try RE4StageJ84SJLJResumeChainModel.completeCleanupAndResumeAcrossChain(
                    machine: f.machine, threadID: 1, handoff: badHandoff,
                    exception: RE4StageJ6SJLJException(private1: 0, private2: f.handler))
            }, matching: { if case .handoffMismatch = $0 { return true }; return false },
               message: "J.6/J.7 identity mismatch")
            try runner.check(f.machine.frame(threadID: 1, address: f.cleanup)?.selectorRaw == 8,
                             "invalid handoff must be rejected before sentinel write")
        }
        runner.test("15 forced Resume route is rejected without invoking a stop callback") {
            let f = try makeFixture(env: env, row: 5)
            try runner.expectJ84({
                _ = try RE4StageJ84SJLJResumeChainModel.completeCleanupAndResumeAcrossChain(
                    machine: f.machine, threadID: 1, handoff: f.handoff,
                    exception: RE4StageJ6SJLJException(private1: 0xFEED0001, private2: f.handler))
            }, matching: { if case .invalidResumeRoute(0xFEED0001) = $0 { return true }; return false },
               message: "J.8.4 is bounded to ordinary Resume")
            try runner.check(f.machine.frame(threadID: 1, address: f.cleanup)?.selectorRaw == 4,
                             "forced route rejection must leave cleanup selector unchanged")
        }
        runner.test("16 no Guest instruction, Guest Memory write, CPU restore, or real Resume occurs") {
            let f = try makeFixture(env: env, row: 20)
            let result = try complete(f)
            try runner.check(!result.guestInstructionsExecuted && result.guestMemoryWrites == 0 &&
                             !result.cpuContextApplied && !result.controlTransferPerformed &&
                             !result.targetResumeFunctionInvoked,
                             "J.8.4 scope boundary flags changed")
        }

        runner.lines.append("RESULT: \(runner.passed)/\(runner.passed + runner.failed) passed; \(runner.failed) failed")
        runner.lines.append("SCOPE: J.8.2 handoff -> #101 sentinel -> 32-bit GetIP zero -> host J.6 Resume traversal through two intermediate frames -> synthetic outer handler INSTALL_CONTEXT.")
        runner.lines.append("LIMIT: Host synthetic state only. No target Resume/personality/unwinder, stop callback, pthread TSD, Guest instruction, Guest Memory write, CPU context application, or control transfer is performed.")
        if runner.failed != 0 { throw Failure(description: runner.lines.joined(separator: "\n")) }
        return runner.lines.joined(separator: "\n")
    }

    private static func complete(_ fixture: Fixture) throws -> RE4StageJ84ResumeChainSnapshot {
        try RE4StageJ84SJLJResumeChainModel.completeCleanupAndResumeAcrossChain(
            machine: fixture.machine, threadID: 1, handoff: fixture.handoff,
            exception: RE4StageJ6SJLJException(private1: 0, private2: fixture.handler))
    }

    private static func makeEnvironment(lsdaHexURL: URL, evidenceURL: URL,
                                        crosswalkURL: URL) throws -> Environment {
        let text = try String(contentsOf: lsdaHexURL, encoding: .utf8)
        let hex = text.filter { !$0.isWhitespace }
        guard hex.count % 2 == 0 else { throw Failure(description: "odd LSDA hex fixture") }
        var bytes = Data()
        var cursor = hex.startIndex
        while cursor < hex.endIndex {
            let next = hex.index(cursor, offsetBy: 2)
            guard let value = UInt8(hex[cursor..<next], radix: 16) else {
                throw Failure(description: "invalid LSDA fixture byte")
            }
            bytes.append(value)
            cursor = next
        }
        return Environment(
            lsda: try RE4StageJ6ExtraProductListLSDA.parse(bytes),
            j7: try RE4StageJ7LandingPadContextModel(evidenceURL: evidenceURL,
                                                      crosswalkURL: crosswalkURL))
    }

    private static func makeFixture(env: Environment, row: Int) throws -> Fixture {
        guard (2...20).contains(row) else { throw Failure(description: "row outside #101 cleanup range") }
        let machine = RE4StageJ6SJLJStateMachine(lsda: env.lsda)
        let handler: UInt32 = 0x7000
        let middleOuter: UInt32 = 0x7200
        let middleInner: UInt32 = 0x7300
        let cleanup: UInt32 = 0x7100
        _ = try machine.register(threadID: 1, address: handler, selectorRaw: 0,
            personality: .syntheticOuterHandler, savedR7: 0xA2020000,
            continuationPC: 0x2220, savedSP: 0xA2030000)
        _ = try machine.register(threadID: 1, address: middleOuter, selectorRaw: 3,
            personality: .none, savedR7: 0xA2120000,
            continuationPC: 0x2230, savedSP: 0xA2130000)
        _ = try machine.register(threadID: 1, address: middleInner, selectorRaw: 5,
            personality: .none, savedR7: 0xA2220000,
            continuationPC: 0x2240, savedSP: 0xA2230000)
        _ = try machine.register(threadID: 1, address: cleanup,
            selectorRaw: UInt32(row - 1), personality: .extraProductListCleanupOnly,
            savedR7: 0xA1020000, continuationPC: RE4StageJ7LandingPadContextModel.cleanupContinuationPC,
            savedSP: 0xA1030000)

        let initialPhase2 = machine.phase2(threadID: 1, handlerFrame: handler)
        guard case .installContextPending(_, let visits) = initialPhase2,
              visits.last?.frameAddress == cleanup,
              machine.top(threadID: 1) == cleanup else {
            throw Failure(description: "initial phase 2 did not select #101 cleanup")
        }
        let handoff = try RE4StageJ82SJLJContextBridge.makeHandoff(
            from: initialPhase2, exceptionPointer: 0xA1040000,
            finalTSDTopAddress: machine.top(threadID: 1), j7Model: env.j7)
        return Fixture(machine: machine,
            handoff: RE4StageJ83HandoffInput(phase2Plan: handoff.phase2Plan,
                j7Plan: handoff.j7Plan, finalTSDTopAddress: handoff.finalTSDTopAddress,
                controlTransferPerformed: handoff.controlTransferPerformed),
            cleanup: cleanup, middleInner: middleInner, middleOuter: middleOuter,
            handler: handler, row: row)
    }
}
