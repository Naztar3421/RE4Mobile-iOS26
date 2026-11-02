import Foundation

public enum RE4StageJ83SJLJResumeCompletionTests {
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
        func expectJ83(_ body: () throws -> Void,
                       matching predicate: (RE4StageJ83Error) -> Bool,
                       message: String) throws {
            do { try body(); throw Failure(description: "Expected J.8.3 error: \(message)") }
            catch let error as RE4StageJ83Error {
                guard predicate(error) else { throw Failure(description: "Wrong J.8.3 error for \(message): \(error)") }
            }
        }
        func expectJ6(_ body: () throws -> Void,
                      matching predicate: (RE4StageJ6StateError) -> Bool,
                      message: String) throws {
            do { try body(); throw Failure(description: "Expected J.6 state error: \(message)") }
            catch let error as RE4StageJ6StateError {
                guard predicate(error) else { throw Failure(description: "Wrong J.6 error for \(message): \(error)") }
            }
        }
    }

    private struct Fixture {
        let machine: RE4StageJ6SJLJStateMachine
        let phase2Plan: RE4StageJ6ContextInstallPlan
        let j7Plan: RE4StageJ7CleanupContextPlan
        let handoff: RE4StageJ83HandoffInput
        let row: Int
        let cleanupAddress: UInt32
        let handlerAddress: UInt32
        let exceptionPointer: UInt32
    }

    public static func run(lsdaHexURL: URL, evidenceURL: URL,
                           crosswalkURL: URL) throws -> String {
        let env = try makeEnvironment(lsdaHexURL: lsdaHexURL,
                                      evidenceURL: evidenceURL,
                                      crosswalkURL: crosswalkURL)
        let runner = Runner()

        func fixture(row: Int = 20, exceptionPointer: UInt32 = 0xA1040000,
                     savedSP: UInt32 = 0xA1030000,
                     savedR7: UInt32 = 0xA1020000) throws -> Fixture {
            try makeFixture(env: env, row: row, exceptionPointer: exceptionPointer,
                            savedSP: savedSP, savedR7: savedR7)
        }

        runner.test("01 J.6 INSTALL_CONTEXT retains the selected #101 frame at TSD top") {
            let f = try fixture()
            try runner.check(f.phase2Plan.frameAddress == f.cleanupAddress &&
                             f.phase2Plan.frameRetainedAtTSDTop &&
                             f.machine.top(threadID: 1) == f.cleanupAddress,
                             "selected cleanup frame must remain the current TSD top")
        }
        runner.test("02 the J.8.2 bridge handoff agrees with the J.7 plan before completion") {
            let f = try fixture(row: 9, savedSP: 0xA1030008, savedR7: 0xA1021010)
            try runner.check(f.handoff.phase2Plan.frameAddress == f.handoff.j7Plan.frameAddress &&
                             f.handoff.phase2Plan.lsdaRow == f.handoff.j7Plan.row &&
                             f.handoff.phase2Plan.landingPadIndex == f.handoff.j7Plan.selector &&
                             f.handoff.phase2Plan.savedR7 == f.handoff.j7Plan.savedR7 &&
                             f.handoff.phase2Plan.savedSP == f.handoff.j7Plan.savedSP &&
                             f.handoff.finalTSDTopAddress == f.cleanupAddress,
                             "J.8.2 handoff fields do not match the J.7 context plan")
        }
        runner.test("03 cleanup frame starts with the nonzero selector selected by the LSDA row") {
            let f = try fixture(row: 20)
            let frame = f.machine.frame(threadID: 1, address: f.cleanupAddress)
            try runner.check(frame?.selectorRaw == 19 && frame?.callSiteIP == 20,
                             "row 20 must start with raw selector 19 / GetIP 20")
        }
        runner.test("04 exceptional cleanup writes exactly 0xFFFFFFFF to selector") {
            let f = try fixture()
            let result = try RE4StageJ83SJLJResumeCompletionModel.completeCleanupAndResume(
                machine: f.machine, threadID: 1, handoff: f.handoff,
                exception: RE4StageJ6SJLJException(private1: 0, private2: f.handlerAddress))
            try runner.check(result.selectorAfterCleanup == UInt32.max &&
                             result.cleanupFrameStillHasSentinel,
                             "exceptional cleanup sentinel mismatch")
        }
        runner.test("05 UInt32.max plus one wraps GetIP to zero") {
            try runner.check(RE4StageJ6StaticContextHelpers.getIP(selectorRaw: UInt32.max) == 0,
                             "GetIP must use 32-bit wrapping addition")
        }
        runner.test("06 exceptional sentinel write leaves the current frame at TSD top until Resume") {
            let f = try fixture()
            let result = try RE4StageJ83SJLJResumeCompletionModel.completeCleanupAndResume(
                machine: f.machine, threadID: 1, handoff: f.handoff,
                exception: RE4StageJ6SJLJException(private1: 0, private2: f.handlerAddress))
            try runner.check(result.tsdTopBeforeCleanup == f.cleanupAddress &&
                             result.tsdTopAfterSentinelWrite == f.cleanupAddress,
                             "sentinel write must not unlink the current frame")
        }
        runner.test("07 Resume phase 2 first revisits the sentinel-marked cleanup frame") {
            let f = try fixture()
            let result = try RE4StageJ83SJLJResumeCompletionModel.completeCleanupAndResume(
                machine: f.machine, threadID: 1, handoff: f.handoff,
                exception: RE4StageJ6SJLJException(private1: 0, private2: f.handlerAddress))
            try runner.check(result.resumeVisitAddresses.first == f.cleanupAddress &&
                             result.cleanupFrameResumeDecision == .continueUnwind,
                             "Resume must see GetIP=0 and continue past the completed frame")
        }
        runner.test("08 Resume phase 2 proceeds to the immediately preceding synthetic handler") {
            let f = try fixture()
            let result = try RE4StageJ83SJLJResumeCompletionModel.completeCleanupAndResume(
                machine: f.machine, threadID: 1, handoff: f.handoff,
                exception: RE4StageJ6SJLJException(private1: 0, private2: f.handlerAddress))
            try runner.check(result.resumeVisitAddresses == [f.cleanupAddress, f.handlerAddress] &&
                             result.enclosingHandlerFrameAddress == f.handlerAddress,
                             "Resume did not traverse cleanup -> predecessor handler")
        }
        runner.test("09 Resume installs the enclosing handler frame and updates the synthetic TSD top") {
            let f = try fixture()
            let result = try RE4StageJ83SJLJResumeCompletionModel.completeCleanupAndResume(
                machine: f.machine, threadID: 1, handoff: f.handoff,
                exception: RE4StageJ6SJLJException(private1: 0, private2: f.handlerAddress))
            try runner.check(result.resumedInstallFrameAddress == f.handlerAddress &&
                             result.finalTSDTopAddress == f.handlerAddress &&
                             f.machine.top(threadID: 1) == f.handlerAddress,
                             "resumed phase 2 did not select enclosing handler")
        }
        runner.test("10 exceptional Resume retains the completed frame record with its sentinel") {
            let f = try fixture()
            let result = try RE4StageJ83SJLJResumeCompletionModel.completeCleanupAndResume(
                machine: f.machine, threadID: 1, handoff: f.handoff,
                exception: RE4StageJ6SJLJException(private1: 0, private2: f.handlerAddress))
            let frame = f.machine.frame(threadID: 1, address: f.cleanupAddress)
            try runner.check(result.cleanupFrameRemainsRegistered &&
                             frame?.selectorRaw == UInt32.max && frame?.callSiteIP == 0,
                             "frame should remain in the host registry with the completion sentinel")
        }
        runner.test("11 exceptional Resume path reports no CPU context application or Guest Memory writes") {
            let f = try fixture()
            let result = try RE4StageJ83SJLJResumeCompletionModel.completeCleanupAndResume(
                machine: f.machine, threadID: 1, handoff: f.handoff,
                exception: RE4StageJ6SJLJException(private1: 0, private2: f.handlerAddress))
            try runner.check(result.resumeWasInvokedAsMetadataModel &&
                             !result.controlTransferPerformed && result.guestMemoryWrites == 0,
                             "J.8.3 must remain data-only")
        }
        runner.test("12 normal Unregister advances TSD top to predecessor") {
            let m = try makeNormalMachine(env: env, row: 20)
            let snap = try RE4StageJ83SJLJResumeCompletionModel.finishNormallyWithUnregister(
                machine: m.machine, threadID: 1, frameAddress: m.cleanupAddress,
                expectedDispatchIndex: 20)
            try runner.check(snap.tsdTopBeforeUnregister == m.cleanupAddress &&
                             snap.tsdTopAfterUnregister == m.handlerAddress &&
                             m.machine.top(threadID: 1) == m.handlerAddress,
                             "normal unregister top transition")
        }
        runner.test("13 normal Unregister preserves the original selector and nonzero GetIP") {
            let m = try makeNormalMachine(env: env, row: 20)
            let snap = try RE4StageJ83SJLJResumeCompletionModel.finishNormallyWithUnregister(
                machine: m.machine, threadID: 1, frameAddress: m.cleanupAddress,
                expectedDispatchIndex: 20)
            try runner.check(snap.selectorBeforeUnregister == 19 &&
                             snap.selectorAfterUnregister == 19 &&
                             snap.callSiteIPAfterUnregister == 20,
                             "normal path must not write exceptional sentinel")
        }
        runner.test("14 normal path is explicitly Unregister-only and does not invoke Resume") {
            let m = try makeNormalMachine(env: env, row: 20)
            let snap = try RE4StageJ83SJLJResumeCompletionModel.finishNormallyWithUnregister(
                machine: m.machine, threadID: 1, frameAddress: m.cleanupAddress,
                expectedDispatchIndex: 20)
            try runner.check(snap.unregisterRouteTaken && !snap.exceptionalResumeInvoked &&
                             !snap.sentinelWritten && !snap.controlTransferPerformed &&
                             snap.guestMemoryWrites == 0,
                             "normal/exceptional paths were conflated")
        }
        runner.test("15 marking an already-unregistered normal frame as cleanup-complete fails") {
            let m = try makeNormalMachine(env: env, row: 20)
            _ = try RE4StageJ83SJLJResumeCompletionModel.finishNormallyWithUnregister(
                machine: m.machine, threadID: 1, frameAddress: m.cleanupAddress,
                expectedDispatchIndex: 20)
            try runner.expectJ6({
                _ = try m.machine.markCleanupContinuationComplete(threadID: 1, address: m.cleanupAddress)
            }, matching: { if case .unknownActiveFrame(m.cleanupAddress) = $0 { return true }; return false },
               message: "normal unregister removes frame from active chain")
        }
        runner.test("16 exceptional path rejects forced-stop Resume routing") {
            let f = try fixture()
            try runner.expectJ83({
                _ = try RE4StageJ83SJLJResumeCompletionModel.completeCleanupAndResume(
                    machine: f.machine, threadID: 1, handoff: f.handoff,
                    exception: RE4StageJ6SJLJException(private1: 0xFEED0001, private2: 0xCAFE1234))
            }, matching: { if case .invalidResumeRoute(0xFEED0001) = $0 { return true }; return false },
               message: "private_1 must be zero on the audited normal Resume path")
            try runner.check(f.machine.top(threadID: 1) == f.cleanupAddress &&
                             f.machine.frame(threadID: 1, address: f.cleanupAddress)?.selectorRaw == 19,
                             "rejected forced route must not mutate the cleanup frame")
        }
        runner.test("17 exceptional path rejects a handler pointer that is not the immediate predecessor") {
            let f = try fixture()
            try runner.expectJ83({
                _ = try RE4StageJ83SJLJResumeCompletionModel.completeCleanupAndResume(
                    machine: f.machine, threadID: 1, handoff: f.handoff,
                    exception: RE4StageJ6SJLJException(private1: 0, private2: 0x7770))
            }, matching: { if case .predecessorMismatch = $0 { return true }; return false },
               message: "private_2 must identify the selected predecessor in this fixture")
        }
        runner.test("18 a J.8.2/J.7 frame-address mismatch is rejected before sentinel write") {
            let f = try fixture()
            let invalidPlan = RE4StageJ6ContextInstallPlan(
                frameAddress: f.cleanupAddress + 4, action: f.phase2Plan.action,
                lsdaRow: f.phase2Plan.lsdaRow, landingPadIndex: f.phase2Plan.landingPadIndex,
                savedR7: f.phase2Plan.savedR7, savedSP: f.phase2Plan.savedSP,
                savedContinuationPC: f.phase2Plan.savedContinuationPC,
                landingPadPC: f.phase2Plan.landingPadPC,
                frameRetainedAtTSDTop: f.phase2Plan.frameRetainedAtTSDTop,
                controlTransferPerformed: false)
            let bad = RE4StageJ83HandoffInput(phase2Plan: invalidPlan, j7Plan: f.j7Plan,
                finalTSDTopAddress: f.cleanupAddress)
            try runner.expectJ83({
                _ = try RE4StageJ83SJLJResumeCompletionModel.completeCleanupAndResume(
                    machine: f.machine, threadID: 1, handoff: bad,
                    exception: RE4StageJ6SJLJException(private1: 0, private2: f.handlerAddress))
            }, matching: { if case .handoffMismatch = $0 { return true }; return false },
               message: "frame identity mismatch")
            try runner.check(f.machine.frame(threadID: 1, address: f.cleanupAddress)?.selectorRaw == 19,
                             "failed handoff must not write sentinel")
        }
        runner.test("19 wrong current TSD top is rejected before cleanup completion") {
            let f = try fixture()
            _ = try f.machine.unregister(threadID: 1, address: f.cleanupAddress)
            try runner.expectJ83({
                _ = try RE4StageJ83SJLJResumeCompletionModel.completeCleanupAndResume(
                    machine: f.machine, threadID: 1, handoff: f.handoff,
                    exception: RE4StageJ6SJLJException(private1: 0, private2: f.handlerAddress))
            }, matching: { if case .cleanupFrameNotTSDTop = $0 { return true }; return false },
               message: "cleanup frame no longer TSD top")
        }
        runner.test("20 a second Resume attempt cannot reuse a cleanup frame no longer at TSD top") {
            let f = try fixture()
            _ = try RE4StageJ83SJLJResumeCompletionModel.completeCleanupAndResume(
                machine: f.machine, threadID: 1, handoff: f.handoff,
                exception: RE4StageJ6SJLJException(private1: 0, private2: f.handlerAddress))
            try runner.expectJ83({
                _ = try RE4StageJ83SJLJResumeCompletionModel.completeCleanupAndResume(
                    machine: f.machine, threadID: 1, handoff: f.handoff,
                    exception: RE4StageJ6SJLJException(private1: 0, private2: f.handlerAddress))
            }, matching: { if case .cleanupFrameNotTSDTop = $0 { return true }; return false },
               message: "duplicate Resume")
        }
        runner.test("21 every nonzero cleanup selector 1...19 completes to sentinel and GetIP zero") {
            for row in 2...20 {
                let f = try fixture(row: row)
                let result = try RE4StageJ83SJLJResumeCompletionModel.completeCleanupAndResume(
                    machine: f.machine, threadID: 1, handoff: f.handoff,
                    exception: RE4StageJ6SJLJException(private1: 0, private2: f.handlerAddress))
                try runner.check(result.selectorBeforeCleanup == UInt32(row - 1) &&
                                 result.selectorAfterCleanup == UInt32.max &&
                                 result.callSiteIPAfterCleanup == 0,
                                 "row \(row) completion transition")
            }
        }
        runner.test("22 normal Unregister and exceptional Resume produce distinct state signatures") {
            let exceptional = try fixture(row: 11)
            let ex = try RE4StageJ83SJLJResumeCompletionModel.completeCleanupAndResume(
                machine: exceptional.machine, threadID: 1, handoff: exceptional.handoff,
                exception: RE4StageJ6SJLJException(private1: 0, private2: exceptional.handlerAddress))
            let normal = try makeNormalMachine(env: env, row: 11)
            let norm = try RE4StageJ83SJLJResumeCompletionModel.finishNormallyWithUnregister(
                machine: normal.machine, threadID: 1, frameAddress: normal.cleanupAddress,
                expectedDispatchIndex: 11)
            try runner.check(ex.selectorAfterCleanup == UInt32.max &&
                             ex.callSiteIPAfterCleanup == 0 &&
                             ex.resumeWasInvokedAsMetadataModel &&
                             norm.selectorAfterUnregister == 10 &&
                             norm.callSiteIPAfterUnregister == 11 &&
                             norm.unregisterRouteTaken && !norm.exceptionalResumeInvoked,
                             "normal and exceptional completion signatures must differ")
        }
        runner.test("23 completion audit never claims a real Resume call, branch, or memory write") {
            let f = try fixture()
            let result = try RE4StageJ83SJLJResumeCompletionModel.completeCleanupAndResume(
                machine: f.machine, threadID: 1, handoff: f.handoff,
                exception: RE4StageJ6SJLJException(private1: 0, private2: f.handlerAddress))
            try runner.check(result.resumeWasInvokedAsMetadataModel &&
                             !result.controlTransferPerformed && result.guestMemoryWrites == 0,
                             "metadata model scope flags")
        }

        runner.lines.append("RESULT: \(runner.passed)/\(runner.passed + runner.failed) passed; \(runner.failed) failed")
        runner.lines.append("SCOPE: J.8.2 bridge handoff -> J.6 synthetic frame completion -> 0xFFFFFFFF selector sentinel -> 32-bit GetIP wrap to zero -> J.6 Resume phase-2 walk to the enclosing synthetic handler. Normal Unregister is modelled separately.")
        runner.lines.append("LIMIT: This validates host metadata/state transitions only. No target Resume, destructor, Unregister function pointer, pthread TSD, personality, unwinder, CPU context, BX, Guest instruction, or Guest Memory operation is executed.")
        if runner.failed != 0 { throw Failure(description: runner.lines.joined(separator: "\n")) }
        return runner.lines.joined(separator: "\n")
    }

    private struct Environment {
        let lsda: RE4StageJ6ExtraProductListLSDA
        let j7: RE4StageJ7LandingPadContextModel
    }

    private struct NormalMachine {
        let machine: RE4StageJ6SJLJStateMachine
        let cleanupAddress: UInt32
        let handlerAddress: UInt32
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

    private static func makeFixture(env: Environment, row: Int,
                                    exceptionPointer: UInt32, savedSP: UInt32,
                                    savedR7: UInt32) throws -> Fixture {
        guard (2...20).contains(row) else { throw Failure(description: "row outside cleanup selector range") }
        let machine = RE4StageJ6SJLJStateMachine(lsda: env.lsda)
        let handler: UInt32 = 0x7000
        let cleanup: UInt32 = 0x7100
        _ = try machine.register(threadID: 1, address: handler, selectorRaw: 0,
            personality: .syntheticOuterHandler, savedR7: 0xA2020000,
            continuationPC: 0x2222, savedSP: 0xA2030000)
        _ = try machine.register(threadID: 1, address: cleanup, selectorRaw: UInt32(row - 1),
            personality: .extraProductListCleanupOnly, savedR7: savedR7,
            continuationPC: RE4StageJ7LandingPadContextModel.cleanupContinuationPC,
            savedSP: savedSP)
        let phase2 = machine.phase2(threadID: 1, handlerFrame: handler)
        guard case .installContextPending(_, let visits) = phase2 else {
            throw Failure(description: "initial phase 2 did not install #101 cleanup context")
        }
        guard visits.last?.frameAddress == cleanup && machine.top(threadID: 1) == cleanup else {
            throw Failure(description: "initial phase 2 did not retain selected frame")
        }
        let j82 = try RE4StageJ82SJLJContextBridge.makeHandoff(
            from: phase2, exceptionPointer: exceptionPointer,
            finalTSDTopAddress: machine.top(threadID: 1), j7Model: env.j7)
        let handoff = RE4StageJ83HandoffInput(phase2Plan: j82.phase2Plan,
            j7Plan: j82.j7Plan, finalTSDTopAddress: j82.finalTSDTopAddress,
            controlTransferPerformed: j82.controlTransferPerformed)
        return Fixture(machine: machine, phase2Plan: j82.phase2Plan,
            j7Plan: j82.j7Plan, handoff: handoff, row: row,
            cleanupAddress: cleanup, handlerAddress: handler,
            exceptionPointer: exceptionPointer)
    }

    private static func makeNormalMachine(env: Environment, row: Int) throws -> NormalMachine {
        guard (2...20).contains(row) else { throw Failure(description: "row outside cleanup selector range") }
        let machine = RE4StageJ6SJLJStateMachine(lsda: env.lsda)
        let handler: UInt32 = 0x7000
        let cleanup: UInt32 = 0x7100
        _ = try machine.register(threadID: 1, address: handler, selectorRaw: 0,
            personality: .none, savedR7: 0, continuationPC: 0, savedSP: 0)
        _ = try machine.register(threadID: 1, address: cleanup, selectorRaw: UInt32(row - 1),
            personality: .extraProductListCleanupOnly, savedR7: 0xA1020000,
            continuationPC: RE4StageJ7LandingPadContextModel.cleanupContinuationPC,
            savedSP: 0xA1030000)
        return NormalMachine(machine: machine, cleanupAddress: cleanup,
                             handlerAddress: handler)
    }
}
