import Foundation

public enum RE4StageJ85ForcedResumeCompletionTests {
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
        func expectJ85(_ body: () throws -> Void,
                       matching predicate: (RE4StageJ85Error) -> Bool,
                       message: String) throws {
            do { try body(); throw Failure(description: "Expected J.8.5 error: \(message)") }
            catch let error as RE4StageJ85Error {
                guard predicate(error) else { throw Failure(description: "Wrong J.8.5 error for \(message): \(error)") }
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
        let completedCleanup: UInt32
        let middleInner: UInt32
        let middleOuter: UInt32
        let nextCleanup: UInt32?
        let bottomFrame: UInt32
        let initialStopEvents: [RE4StageJ6ForcedStopEvent]
        let exceptionPointerForGR0: UInt32
    }

    public static func run(lsdaHexURL: URL, evidenceURL: URL,
                           crosswalkURL: URL) throws -> String {
        let env = try makeEnvironment(lsdaHexURL: lsdaHexURL,
                                      evidenceURL: evidenceURL,
                                      crosswalkURL: crosswalkURL)
        let runner = Runner()
        let stopToken: UInt32 = 0xFEED0001
        let stopParameter: UInt32 = 0xCAFE1234

        func fixture(row: Int = 20, nextRow: Int? = 3,
                     stopParameter: UInt32 = 0xCAFE1234) throws -> Fixture {
            try makeFixture(env: env, row: row, nextRow: nextRow,
                            stopToken: stopToken, stopParameter: stopParameter)
        }
        func run(_ f: Fixture, stop: ((RE4StageJ6ForcedStopEvent) -> Int32)? = { _ in 0 }) throws -> RE4StageJ85ForcedResumeSnapshot {
            try RE4StageJ85ForcedResumeCompletionModel.completeCleanupAndResume(
                machine: f.machine, threadID: 1, handoff: f.handoff,
                exception: RE4StageJ6SJLJException(private1: stopToken, private2: stopParameter),
                syntheticStop: stop)
        }

        runner.test("01 initial forced phase 2 builds a forced-cleanup J.8.2/J.7 handoff") {
            let f = try fixture()
            try runner.check(f.handoff.phase2Plan.action == .forcedCleanup &&
                             f.handoff.phase2Plan.frameAddress == f.completedCleanup &&
                             f.handoff.j7Plan.frameAddress == f.completedCleanup &&
                             f.handoff.finalTSDTopAddress == f.completedCleanup,
                             "initial forced cleanup handoff identity/action mismatch")
            try runner.check(f.initialStopEvents == [RE4StageJ6ForcedStopEvent(
                stopFunctionRaw: stopToken, stopParameter: stopParameter,
                frameAddress: f.completedCleanup, reason: 10)],
                "initial forced stop callback metadata mismatch")
        }
        runner.test("02 cleanup completion writes sentinel and wraps GetIP to zero") {
            let f = try fixture(row: 9)
            let result = try run(f)
            try runner.check(result.selectorBeforeCleanup == 8 &&
                             result.selectorAfterCleanup == UInt32.max &&
                             result.getIPAfterCleanup == 0,
                             "forced cleanup selector completion transition mismatch")
        }
        runner.test("03 selected cleanup remains TSD top between sentinel write and Resume") {
            let f = try fixture()
            let result = try run(f)
            try runner.check(result.tsdTopBeforeCleanup == f.completedCleanup &&
                             result.tsdTopAfterSentinelWrite == f.completedCleanup,
                             "sentinel write must not unlink the current forced cleanup frame")
        }
        runner.test("04 Resume invokes the synthetic stop callback for the completed frame first") {
            let f = try fixture()
            var events: [RE4StageJ6ForcedStopEvent] = []
            let result = try run(f) { event in events.append(event); return 0 }
            try runner.check(events.first?.frameAddress == f.completedCleanup &&
                             result.resumeVisits.first?.frameAddress == f.completedCleanup &&
                             result.resumeVisits.first?.decision == .continueUnwind &&
                             result.resumeVisits.first?.actions == .forcedCleanup,
                             "forced Resume must re-visit the sentinel-marked cleanup frame first")
        }
        runner.test("05 stop callback receives unchanged token, opaque parameter, and force reason 10") {
            let f = try fixture()
            var events: [RE4StageJ6ForcedStopEvent] = []
            _ = try run(f) { event in events.append(event); return 0 }
            try runner.check(events.count == 4 && events.allSatisfy {
                $0.stopFunctionRaw == stopToken && $0.stopParameter == stopParameter && $0.reason == 10
            }, "stop callback arguments/reason were not preserved for every visited frame")
        }
        runner.test("06 Resume callback/frame order is completed cleanup, inner, outer, next cleanup") {
            let f = try fixture()
            var events: [RE4StageJ6ForcedStopEvent] = []
            let result = try run(f) { event in events.append(event); return 0 }
            try runner.check(result.callbackVisitAddresses == [f.completedCleanup, f.middleInner,
                                                                f.middleOuter, f.nextCleanup!],
                             "forced Resume callback order mismatch")
            try runner.check(events.map(\.frameAddress) == result.callbackVisitAddresses,
                             "callback invocation log differs from phase-2 visit order")
        }
        runner.test("07 every intervening frame receives forcedCleanup and continueUnwind") {
            let f = try fixture()
            let result = try run(f)
            let middle = result.resumeVisits.filter {
                $0.frameAddress == f.middleInner || $0.frameAddress == f.middleOuter
            }
            try runner.check(middle.count == 2 && middle.allSatisfy {
                $0.actions == .forcedCleanup && $0.decision == .continueUnwind && $0.stopCallbackReturn == 0
            }, "intermediate forced-unwind visits must all continue")
        }
        runner.test("08 next #101 cleanup receives forcedCleanup and installs its context") {
            let f = try fixture(nextRow: 7)
            let result = try run(f)
            try runner.check(result.disposition == .nextCleanupInstalled(
                frameAddress: f.nextCleanup!, row: 7, landingPadIndex: 6),
                "next #101 forced cleanup was not selected")
            try runner.check(result.nextCleanupInstallPlan?.action == .forcedCleanup &&
                             result.nextCleanupInstallPlan?.landingPadPC == RE4StageJ7LandingPadContextModel.cleanupContinuationPC,
                             "next cleanup install plan action/continuation mismatch")
        }
        runner.test("09 next cleanup plan matches its synthetic frame and becomes model TSD top") {
            let f = try fixture(nextRow: 11)
            let result = try run(f)
            let next = f.machine.frame(threadID: 1, address: f.nextCleanup!)
            try runner.check(result.nextCleanupInstallPlan?.frameAddress == f.nextCleanup &&
                             result.nextCleanupInstallPlan?.savedR7 == next?.savedR7 &&
                             result.nextCleanupInstallPlan?.savedSP == next?.savedSP &&
                             result.nextCleanupInstallPlan?.savedContinuationPC == next?.continuationPC &&
                             result.modelTSDTopAfterResume == f.nextCleanup,
                             "next cleanup saved context or retained top mismatch")
        }
        runner.test("10 private_2 is treated only as stop parameter, not a handler-frame address") {
            let f = try fixture()
            let result = try run(f)
            try runner.check(result.stopParameter == stopParameter &&
                             f.machine.frame(threadID: 1, address: stopParameter) == nil &&
                             result.disposition == .nextCleanupInstalled(
                                frameAddress: f.nextCleanup!, row: 3, landingPadIndex: 2),
                             "forced private_2 was misinterpreted as a frame pointer")
        }
        runner.test("11 zero is a valid opaque stop parameter and remains unchanged") {
            let f = try fixture(stopParameter: 0)
            var events: [RE4StageJ6ForcedStopEvent] = []
            let result = try RE4StageJ85ForcedResumeCompletionModel.completeCleanupAndResume(
                machine: f.machine, threadID: 1, handoff: f.handoff,
                exception: RE4StageJ6SJLJException(private1: stopToken, private2: 0),
                syntheticStop: { event in events.append(event); return 0 })
            try runner.check(result.stopParameter == 0 && events.allSatisfy { $0.stopParameter == 0 },
                             "zero opaque stop parameter was changed or rejected")
        }
        runner.test("12 nonzero stop callback return on completed frame aborts before predecessor visits") {
            let f = try fixture()
            var events: [RE4StageJ6ForcedStopEvent] = []
            let result = try run(f) { event in events.append(event); return 7 }
            try runner.check(result.disposition == .stopCallbackRejected(
                frameAddress: f.completedCleanup, returnCode: 7) &&
                result.resumeVisits.count == 1 && events.count == 1,
                "nonzero stop result must abort forced Resume at the current frame")
        }
        runner.test("13 stop callback rejection on an intermediate frame prevents later cleanup install") {
            let f = try fixture()
            var events: [RE4StageJ6ForcedStopEvent] = []
            let result = try run(f) { event in
                events.append(event)
                return event.frameAddress == f.middleOuter ? 9 : 0
            }
            try runner.check(result.disposition == .stopCallbackRejected(
                frameAddress: f.middleOuter, returnCode: 9) &&
                result.callbackVisitAddresses == [f.completedCleanup, f.middleInner, f.middleOuter] &&
                !result.resumeVisits.contains(where: { $0.frameAddress == f.nextCleanup }),
                "stop callback rejection did not prevent deeper personality/cleanup processing")
        }
        runner.test("14 stop callback rejection at the next cleanup frame occurs before personality install") {
            let f = try fixture()
            let result = try run(f) { event in event.frameAddress == f.nextCleanup ? 3 : 0 }
            guard case .stopCallbackRejected(let address, let code) = result.disposition else {
                throw Failure(description: "expected stop callback rejection at next cleanup")
            }
            try runner.check(address == f.nextCleanup && code == 3 &&
                             result.nextCleanupInstallPlan == nil &&
                             result.resumeVisits.last?.decision == .fatalPhase2Error,
                             "stop callback must run before next frame's personality decision")
        }
        runner.test("15 every audited nonzero current-cleanup selector row 2...20 can Resume") {
            for row in 2...20 {
                let f = try fixture(row: row)
                let result = try run(f)
                try runner.check(result.selectorBeforeCleanup == UInt32(row - 1) &&
                                 result.getIPAfterCleanup == 0 &&
                                 result.disposition == .nextCleanupInstalled(
                                    frameAddress: f.nextCleanup!, row: 3, landingPadIndex: 2),
                                 "current cleanup row \(row) did not Resume through forced route")
            }
        }
        runner.test("16 every audited nonzero next-cleanup selector row 2...20 can be selected") {
            for row in 2...20 {
                let f = try fixture(nextRow: row)
                let result = try run(f)
                try runner.check(result.disposition == .nextCleanupInstalled(
                    frameAddress: f.nextCleanup!, row: row, landingPadIndex: UInt32(row - 1)),
                    "next cleanup row \(row) was not selected by forced phase 2")
            }
        }
        runner.test("17 forced Resume with only ordinary frames reaches the modeled end-of-stack") {
            let f = try fixture(nextRow: nil)
            let result = try run(f)
            try runner.check(result.disposition == .endOfStack &&
                             result.resumeVisits.map(\.frameAddress) == [f.completedCleanup,
                                 f.middleInner, f.middleOuter, f.bottomFrame] &&
                             result.resumeVisits.allSatisfy {
                                 $0.actions == .forcedCleanup && $0.decision == .continueUnwind &&
                                 $0.stopCallbackReturn == 0
                             }, "forced Resume should continue through every remaining ordinary frame")
        }
        runner.test("18 missing synthetic stop callback fails closed before sentinel mutation") {
            let f = try fixture()
            try runner.expectJ85({
                _ = try RE4StageJ85ForcedResumeCompletionModel.completeCleanupAndResume(
                    machine: f.machine, threadID: 1, handoff: f.handoff,
                    exception: RE4StageJ6SJLJException(private1: stopToken, private2: stopParameter),
                    syntheticStop: nil)
            }, matching: { if case .missingSyntheticStopCallback(stopToken) = $0 { return true }; return false },
               message: "missing host stop callback")
            try runner.check(f.machine.frame(threadID: 1, address: f.completedCleanup)?.selectorRaw == 19,
                             "missing callback must not mark cleanup complete")
        }
        runner.test("19 private_1 zero cannot enter forced Resume and leaves selector intact") {
            let f = try fixture()
            try runner.expectJ85({
                _ = try RE4StageJ85ForcedResumeCompletionModel.completeCleanupAndResume(
                    machine: f.machine, threadID: 1, handoff: f.handoff,
                    exception: RE4StageJ6SJLJException(private1: 0, private2: stopParameter),
                    syntheticStop: { _ in 0 })
            }, matching: { if case .invalidForcedRoute(0) = $0 { return true }; return false },
               message: "normal Resume private_1")
            try runner.check(f.machine.frame(threadID: 1, address: f.completedCleanup)?.selectorRaw == 19,
                             "wrong Resume route must not mutate selector")
        }
        runner.test("20 zero stop-function token is rejected before cleanup completion") {
            let f = try fixture()
            try runner.expectJ85({
                _ = try RE4StageJ85ForcedResumeCompletionModel.completeCleanupAndResume(
                    machine: f.machine, threadID: 1, handoff: f.handoff,
                    exception: RE4StageJ6SJLJException(private1: 0, private2: stopParameter),
                    syntheticStop: { _ in 0 })
            }, matching: { if case .invalidForcedRoute = $0 { return true }; return false },
               message: "zero raw stop token")
        }
        runner.test("21 normal-cleanup handoff cannot be passed as a forced cleanup handoff") {
            let f = try fixture()
            let normalResult = f.machine.phase2(threadID: 1, handlerFrame: f.bottomFrame)
            let normalHandoff = try RE4StageJ82SJLJContextBridge.makeHandoff(
                from: normalResult, exceptionPointer: f.exceptionPointerForGR0,
                finalTSDTopAddress: f.machine.top(threadID: 1), j7Model: env.j7)
            let bad = RE4StageJ83HandoffInput(phase2Plan: normalHandoff.phase2Plan,
                j7Plan: normalHandoff.j7Plan, finalTSDTopAddress: normalHandoff.finalTSDTopAddress,
                controlTransferPerformed: normalHandoff.controlTransferPerformed)
            try runner.expectJ85({
                _ = try RE4StageJ85ForcedResumeCompletionModel.completeCleanupAndResume(
                    machine: f.machine, threadID: 1, handoff: bad,
                    exception: RE4StageJ6SJLJException(private1: stopToken, private2: stopParameter),
                    syntheticStop: { _ in 0 })
            }, matching: { if case .handoffMismatch = $0 { return true }; return false },
               message: "ordinary cleanup handoff supplied to forced route")
        }
#if RE4_HOST_TESTING
        runner.test("22 missing intermediate frame record is reported as a corrupt forced chain") {
            let f = try fixture()
            try runner.check(f.machine.removeFrameRecordForTesting(threadID: 1, address: f.middleOuter),
                             "fault injection did not remove the intermediate record")
            var events: [RE4StageJ6ForcedStopEvent] = []
            let result = try run(f) { event in events.append(event); return 0 }
            try runner.check(result.disposition == .corruptFrameChain(missingFrame: f.middleOuter) &&
                             result.callbackVisitAddresses == [f.completedCleanup, f.middleInner] &&
                             events.map(\.frameAddress) == result.callbackVisitAddresses,
                             "corrupt forced chain should stop at the missing predecessor")
        }
#endif
        runner.test("23 an out-of-profile next cleanup selector stays unresolved") {
            let f = try fixture(nextRow: 21)
            let result = try run(f)
            try runner.check(result.disposition == .unresolvedCallSite(
                frameAddress: f.nextCleanup!, callSiteIP: 21) &&
                result.nextCleanupInstallPlan == nil &&
                result.resumeVisits.last?.decision == .unresolvedCallSiteIndex(21),
                "out-of-profile selector must not invent a cleanup landing-pad target")
        }
        runner.test("24 negative nonzero stop callback return also aborts forced Resume") {
            let f = try fixture()
            let result = try run(f) { event in event.frameAddress == f.middleInner ? -1 : 0 }
            try runner.check(result.disposition == .stopCallbackRejected(
                frameAddress: f.middleInner, returnCode: -1),
                "any nonzero stop callback result must abort, including negative values")
        }
        runner.test("25 raw stop function token is never invoked; no Guest runtime operation occurs") {
            let f = try fixture()
            let result = try run(f)
            try runner.check(!result.targetStopFunctionInvoked &&
                             !result.targetResumeFunctionInvoked &&
                             !result.guestInstructionsExecuted && result.guestMemoryWrites == 0 &&
                             !result.cpuContextApplied && !result.controlTransferPerformed,
                             "J.8.5 must remain a host-only metadata model")
        }

        runner.lines.append("RESULT: \(runner.passed)/\(runner.passed + runner.failed) passed; \(runner.failed) failed")
        runner.lines.append("SCOPE: forced J.6 Resume route -> completed #101 sentinel -> synthetic stop callback (reason 10) -> forced cleanup traversal -> next #101 INSTALL_CONTEXT or modeled end-of-stack.")
        runner.lines.append("LIMIT: The raw stop-function token is never invoked. Only a caller-supplied host closure models stop results. No target Resume/personality/unwinder, pthread TSD, Guest instruction, Guest Memory write, CPU context application, or control transfer occurs.")
        if runner.failed != 0 { throw Failure(description: runner.lines.joined(separator: "\n")) }
        return runner.lines.joined(separator: "\n")
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
        return Environment(lsda: try RE4StageJ6ExtraProductListLSDA.parse(bytes),
            j7: try RE4StageJ7LandingPadContextModel(evidenceURL: evidenceURL,
                                                      crosswalkURL: crosswalkURL))
    }

    private static func makeFixture(env: Environment, row: Int, nextRow: Int?,
                                    stopToken: UInt32, stopParameter: UInt32) throws -> Fixture {
        guard (2...20).contains(row), nextRow.map({ (2...21).contains($0) }) ?? true else {
            throw Failure(description: "current cleanup row or next-row test selector outside supported test range")
        }
        let machine = RE4StageJ6SJLJStateMachine(lsda: env.lsda)
        let bottom: UInt32 = 0x7000
        let middleOuter: UInt32 = 0x7200
        let middleInner: UInt32 = 0x7300
        let nextCleanup: UInt32? = nextRow == nil ? nil : 0x7400
        let completedCleanup: UInt32 = 0x7600
        _ = try machine.register(threadID: 1, address: bottom, selectorRaw: 0,
            personality: .syntheticOuterHandler, savedR7: 0xA2020000,
            continuationPC: 0x2220, savedSP: 0xA2030000)
        if let nextCleanup, let nextRow {
            _ = try machine.register(threadID: 1, address: nextCleanup,
                selectorRaw: UInt32(nextRow - 1), personality: .extraProductListCleanupOnly,
                savedR7: 0xA2420000, continuationPC: RE4StageJ7LandingPadContextModel.cleanupContinuationPC,
                savedSP: 0xA2430000)
        }
        _ = try machine.register(threadID: 1, address: middleOuter, selectorRaw: 3,
            personality: .none, savedR7: 0xA2220000, continuationPC: 0x2230, savedSP: 0xA2230000)
        _ = try machine.register(threadID: 1, address: middleInner, selectorRaw: 5,
            personality: .none, savedR7: 0xA2320000, continuationPC: 0x2240, savedSP: 0xA2330000)
        _ = try machine.register(threadID: 1, address: completedCleanup,
            selectorRaw: UInt32(row - 1), personality: .extraProductListCleanupOnly,
            savedR7: 0xA1020000, continuationPC: RE4StageJ7LandingPadContextModel.cleanupContinuationPC,
            savedSP: 0xA1030000)

        var initialEvents: [RE4StageJ6ForcedStopEvent] = []
        let initial = machine.phase2Forced(threadID: 1, stopFunctionRaw: stopToken,
            stopParameter: stopParameter, syntheticStop: { event in
                initialEvents.append(event)
                return 0
            })
        guard case .installContextPending(let plan, let visits) = initial,
              plan.action == .forcedCleanup,
              plan.frameAddress == completedCleanup,
              visits.map(\.frameAddress) == [completedCleanup],
              machine.top(threadID: 1) == completedCleanup else {
            throw Failure(description: "initial forced phase 2 did not install the selected #101 frame")
        }
        let gr0ExceptionPointer: UInt32 = 0xA1040000
        let j82 = try RE4StageJ82SJLJContextBridge.makeHandoff(from: initial,
            exceptionPointer: gr0ExceptionPointer,
            finalTSDTopAddress: machine.top(threadID: 1), j7Model: env.j7)
        let handoff = RE4StageJ83HandoffInput(phase2Plan: j82.phase2Plan,
            j7Plan: j82.j7Plan, finalTSDTopAddress: j82.finalTSDTopAddress,
            controlTransferPerformed: j82.controlTransferPerformed)
        return Fixture(machine: machine, handoff: handoff,
            completedCleanup: completedCleanup, middleInner: middleInner,
            middleOuter: middleOuter, nextCleanup: nextCleanup,
            bottomFrame: bottom, initialStopEvents: initialEvents,
            exceptionPointerForGR0: gr0ExceptionPointer)
    }
}
