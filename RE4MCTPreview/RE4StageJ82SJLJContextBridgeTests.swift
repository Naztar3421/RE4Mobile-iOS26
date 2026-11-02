import Foundation

public enum RE4StageJ82SJLJContextBridgeTests {
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
                    matching predicate: (RE4StageJ82BridgeError) -> Bool,
                    message: String) throws {
            do { try body(); throw Failure(description: "Expected bridge error: \(message)") }
            catch let error as RE4StageJ82BridgeError {
                guard predicate(error) else { throw Failure(description: "Wrong bridge error for \(message): \(error)") }
            }
        }
    }

    private struct Environment {
        let lsda: RE4StageJ6ExtraProductListLSDA
        let j7: RE4StageJ7LandingPadContextModel
    }

    private struct Generated {
        let machine: RE4StageJ6SJLJStateMachine
        let result: RE4StageJ6Phase2Result
        let selectedFrame: UInt32
        let expectedVisitFrames: [UInt32]
        let exceptionPointer: UInt32
    }

    public static func run(lsdaHexURL: URL, evidenceURL: URL,
                           crosswalkURL: URL) throws -> String {
        let env = try makeEnvironment(lsdaHexURL: lsdaHexURL, evidenceURL: evidenceURL,
                                      crosswalkURL: crosswalkURL)
        let range = try RE4StageJ8SyntheticCodeRange(lowerBound: 0x5000, upperBoundExclusive: 0x6000)
        let runner = Runner()

        func generated(row: Int = 20, forced: Bool = false,
                       exception: UInt32 = 0xA1040000,
                       savedSP: UInt32 = 0xA1030000,
                       savedR7: UInt32 = 0xA1020000) throws -> Generated {
            try makeGenerated(env: env, row: row, forced: forced,
                              exception: exception, savedSP: savedSP, savedR7: savedR7)
        }

        runner.test("J8.2-01 normal phase 2 walks synthetic frames and selects #101 cleanup") {
            let g = try generated(row: 20)
            guard case .installContextPending(let plan, let visits) = g.result else {
                throw Failure(description: "expected INSTALL_CONTEXT")
            }
            try runner.check(visits.map(\.frameAddress) == [0x7300, 0x7200, 0x7100],
                             "phase-2 traversal order must be newest to selected cleanup frame")
            try runner.check(plan.frameAddress == 0x7100 && plan.lsdaRow == 20 &&
                             plan.landingPadIndex == 19,
                             "wrong selected frame/LSDA mapping")
            try runner.check(g.machine.top(threadID: 1) == 0x7100,
                             "TSD top must be the selected frame at INSTALL_CONTEXT")
        }
        runner.test("J8.2-02 J.6 plan and J.7 plan agree on frame, saved R7/SP, selector and PC") {
            let g = try generated(row: 20, savedSP: 0xA1030008, savedR7: 0xA1021010)
            let h = try makeHandoff(g, env: env)
            try runner.check(h.phase2Plan.frameAddress == h.j7Plan.frameAddress &&
                             h.phase2Plan.savedR7 == h.j7Plan.savedR7 &&
                             h.phase2Plan.savedSP == h.j7Plan.savedSP &&
                             h.phase2Plan.savedContinuationPC == h.j7Plan.savedContinuationPC &&
                             h.phase2Plan.lsdaRow == h.j7Plan.row &&
                             h.phase2Plan.landingPadIndex == h.j7Plan.selector,
                             "J.6 -> J.7 field contract mismatch")
        }
        runner.test("J8.2-03 exception pointer is explicit and becomes J.7 GR0") {
            let g = try generated(exception: 0xDEADBEEF)
            let h = try makeHandoff(g, env: env)
            try runner.check(h.exceptionPointerSuppliedForGR0 == 0xDEADBEEF &&
                             h.j7Plan.setGR0Value == 0xDEADBEEF &&
                             h.j7Plan.resumeExceptionArgument == 0xDEADBEEF,
                             "explicit GR0 pointer not carried through")
        }
        runner.test("J8.2-04 J.6 plan is converted into a J.8.1-validated frame and BX snapshot") {
            let g = try generated(row: 9, exception: 0x13579BDF)
            let h = try makeHandoff(g, env: env)
            let frame = try RE4StageJ8SyntheticContextIntegrityGuard.makeSyntheticFrame(from: h.j7Plan)
            let snapshot = try RE4StageJ8SyntheticContextIntegrityGuard.inspectRestore(
                frame: frame, codeRange: range,
                expected: RE4StageJ8IntegrityExpectedFields(plan: h.j7Plan))
            try runner.check(snapshot.frameBaseAddress == h.phase2Plan.frameAddress &&
                             snapshot.selectorWord == 8 && snapshot.unwindGR0 == 0x13579BDF &&
                             snapshot.restoredPC == 0x55A8 && snapshot.targetState == .arm &&
                             !snapshot.controlTransferPerformed,
                             "end-to-end synthetic handoff snapshot mismatch")
        }
        runner.test("J8.2-05 all 19 cleanup rows bridge from J.6 selector to J.7 crosswalk") {
            for row in 2...20 {
                let g = try generated(row: row)
                let h = try makeHandoff(g, env: env)
                try runner.check(h.j7Plan.row == row && h.j7Plan.selector == UInt32(row - 1) &&
                                 h.j7Plan.dispatchIndex == UInt32(row) &&
                                 h.phase2Plan.landingPadIndex == UInt32(row - 1),
                                 "row \(row) did not preserve row/index relationship")
            }
        }
        runner.test("J8.2-06 selector value remains distinct from the saved PC") {
            let g = try generated(row: 12)
            let h = try makeHandoff(g, env: env)
            try runner.check(h.j7Plan.selector == 11 &&
                             h.j7Plan.savedContinuationPC == 0x55A8 &&
                             h.j7Plan.selector != h.j7Plan.savedContinuationPC,
                             "selector was confused with PC")
        }
        runner.test("J8.2-07 forced phase 2 can bridge using only a host synthetic stop closure") {
            let g = try generated(row: 6, forced: true)
            let h = try makeHandoff(g, env: env)
            try runner.check(h.phase2Plan.action == .forcedCleanup &&
                             h.j7Plan.row == 6 && h.j7Plan.savedContinuationPC == 0x55A8 &&
                             h.controlTransferPerformed == false,
                             "forced cleanup handoff mismatch")
        }
        runner.test("J8.2-08 frame visitation order is retained in the handoff") {
            let g = try generated(row: 4)
            let h = try makeHandoff(g, env: env)
            try runner.check(h.phase2VisitAddresses == [0x7300, 0x7200, 0x7100] &&
                             h.finalTSDTopAddress == 0x7100,
                             "phase-2 visit/top evidence lost")
        }
        runner.test("J8.2-09 zero exception pointer is accepted as an explicit GR0 data value") {
            let g = try generated(exception: 0)
            let h = try makeHandoff(g, env: env)
            try runner.check(h.j7Plan.setGR0Value == 0 &&
                             h.j7Plan.resumeExceptionArgument == 0,
                             "bridge must preserve explicit GR0=0")
        }
        runner.test("J8.2-10 caller-supplied final TSD top must equal selected frame") {
            let g = try generated()
            guard case .installContextPending(let plan, let visits) = g.result else {
                throw Failure(description: "missing install plan")
            }
            try runner.expect({
                _ = try RE4StageJ82SJLJContextBridge.makeHandoff(
                    from: .installContextPending(plan: plan, visits: visits),
                    exceptionPointer: g.exceptionPointer, finalTSDTopAddress: 0x7300, j7Model: env.j7)
            }, matching: { if case .unexpectedFrameAddress(0x7100) = $0 { return true }; return false },
               message: "wrong final TSD top")
        }
        runner.test("J8.2-11 phase 2 end-of-stack is not accepted as install context") {
            let machine = RE4StageJ6SJLJStateMachine(lsda: env.lsda)
            _ = try machine.register(threadID: 1, address: 0x7000, selectorRaw: UInt32.max,
                personality: .none, savedR7: 0, continuationPC: 0, savedSP: 0)
            let result = machine.phase2(threadID: 1, handlerFrame: 0)
            try runner.expect({
                _ = try RE4StageJ82SJLJContextBridge.makeHandoff(from: result,
                    exceptionPointer: 1, finalTSDTopAddress: 0, j7Model: env.j7)
            }, matching: { if case .phase2DidNotRequestInstall = $0 { return true }; return false },
               message: "end of stack")
        }
        runner.test("J8.2-12 out-of-profile selector is propagated as unresolved, not coerced") {
            let machine = RE4StageJ6SJLJStateMachine(lsda: env.lsda)
            _ = try machine.register(threadID: 1, address: 0x7100, selectorRaw: 20,
                personality: .extraProductListCleanupOnly, savedR7: 1,
                continuationPC: 0x55A8, savedSP: 0xA1030000)
            let result = machine.phase2(threadID: 1, handlerFrame: 0)
            try runner.expect({
                _ = try RE4StageJ82SJLJContextBridge.makeHandoff(from: result,
                    exceptionPointer: 1, finalTSDTopAddress: 0x7100, j7Model: env.j7)
            }, matching: { if case .unresolvedPhase2(0x7100, 21) = $0 { return true }; return false },
               message: "unresolved callSiteIP=21")
        }
        runner.test("J8.2-13 #101 selected as handler frame is not misclassified as ordinary cleanup") {
            let machine = RE4StageJ6SJLJStateMachine(lsda: env.lsda)
            _ = try machine.register(threadID: 1, address: 0x7100, selectorRaw: 19,
                personality: .extraProductListCleanupOnly, savedR7: 1,
                continuationPC: 0x55A8, savedSP: 0xA1030000)
            let result = machine.phase2(threadID: 1, handlerFrame: 0x7100)
            try runner.expect({
                _ = try RE4StageJ82SJLJContextBridge.makeHandoff(from: result,
                    exceptionPointer: 1, finalTSDTopAddress: 0x7100, j7Model: env.j7)
            }, matching: { if case .phase2DidNotRequestInstall = $0 { return true }; return false },
               message: "handler cleanup path")
        }
        runner.test("J8.2-14 handlerCleanup action is rejected in a fabricated install plan") {
            let p = try generated()
            let invalid = replacePlan(try installPlan(p.result), action: .handlerCleanup)
            try expectSyntheticPlan(invalid, visits: p.expectedVisitFrames, env: env,
                                    error: { if case .unsupportedAction(.handlerCleanup) = $0 { return true }; return false },
                                    message: "handlerCleanup action")
        }
        runner.test("J8.2-15 forced cleanup plan retains its action distinction") {
            let g = try generated(forced: true)
            let h = try makeHandoff(g, env: env)
            try runner.check(h.phase2Plan.action == .forcedCleanup, "forced action was lost")
        }
        runner.test("J8.2-16 LSDA row zero is rejected") {
            let g = try generated()
            let invalid = replacePlan(try installPlan(g.result), row: 0, index: 0)
            try expectSyntheticPlan(invalid, visits: g.expectedVisitFrames, env: env,
                                    error: { if case .rowOutOfRange(0) = $0 { return true }; return false },
                                    message: "row zero")
        }
        runner.test("J8.2-17 row 21 is rejected") {
            let g = try generated()
            let invalid = replacePlan(try installPlan(g.result), row: 21, index: 20)
            try expectSyntheticPlan(invalid, visits: g.expectedVisitFrames, env: env,
                                    error: { if case .rowOutOfRange(21) = $0 { return true }; return false },
                                    message: "row 21")
        }
        runner.test("J8.2-18 mismatched row/index mapping is rejected") {
            let g = try generated()
            let invalid = replacePlan(try installPlan(g.result), index: 18)
            try expectSyntheticPlan(invalid, visits: g.expectedVisitFrames, env: env,
                                    error: { if case .rowIndexMismatch(row: 20, expected: 19, actual: 18) = $0 { return true }; return false },
                                    message: "row/index mismatch")
        }
        runner.test("J8.2-19 missing landing-pad row is rejected") {
            let g = try generated()
            let invalid = replacePlan(try installPlan(g.result), row: nil)
            try expectSyntheticPlan(invalid, visits: g.expectedVisitFrames, env: env,
                                    error: { if case .missingLSDArow = $0 { return true }; return false },
                                    message: "missing row")
        }
        runner.test("J8.2-20 missing landing-pad index is rejected") {
            let g = try generated()
            let invalid = replacePlan(try installPlan(g.result), index: nil)
            try expectSyntheticPlan(invalid, visits: g.expectedVisitFrames, env: env,
                                    error: { if case .missingLandingPadIndex = $0 { return true }; return false },
                                    message: "missing index")
        }
        runner.test("J8.2-21 saved continuation must equal the audited 0x55A8") {
            let g = try generated()
            let invalid = replacePlan(try installPlan(g.result), savedPC: 0x55AC)
            try expectSyntheticPlan(invalid, visits: g.expectedVisitFrames, env: env,
                                    error: { if case .savedContinuationMismatch(expected: 0x55A8, actual: 0x55AC) = $0 { return true }; return false },
                                    message: "saved continuation mismatch")
        }
        runner.test("J8.2-22 landingPadPC must equal the audited 0x55A8") {
            let g = try generated()
            let invalid = replacePlan(try installPlan(g.result), landingPC: nil)
            try expectSyntheticPlan(invalid, visits: g.expectedVisitFrames, env: env,
                                    error: { if case .landingPadMismatch(expected: 0x55A8, actual: nil) = $0 { return true }; return false },
                                    message: "missing landingPadPC")
        }
        runner.test("J8.2-23 frame-retention evidence is mandatory") {
            let g = try generated()
            let invalid = replacePlan(try installPlan(g.result), retained: false)
            try expectSyntheticPlan(invalid, visits: g.expectedVisitFrames, env: env,
                                    error: { if case .frameNotRetained = $0 { return true }; return false },
                                    message: "frame not retained")
        }
        runner.test("J8.2-24 a plan claiming control transfer is rejected") {
            let g = try generated()
            let invalid = replacePlan(try installPlan(g.result), transferred: true)
            try expectSyntheticPlan(invalid, visits: g.expectedVisitFrames, env: env,
                                    error: { if case .controlTransferAlreadyPerformed = $0 { return true }; return false },
                                    message: "control transfer flag")
        }
        runner.test("J8.2-25 final visit must identify the selected install frame") {
            let g = try generated()
            let plan = try installPlan(g.result)
            let badVisits = [RE4StageJ6Phase2Visit(frameAddress: plan.frameAddress + 4,
                actions: plan.action, decision: .installCleanupContext(row: 20, landingPadIndex: 19),
                stopCallbackReturn: nil)]
            try runner.expect({
                _ = try RE4StageJ82SJLJContextBridge.makeHandoff(
                    from: .installContextPending(plan: plan, visits: badVisits),
                    exceptionPointer: g.exceptionPointer, finalTSDTopAddress: plan.frameAddress, j7Model: env.j7)
            }, matching: { if case .bridgeInvariant = $0 { return true }; return false },
               message: "last visit mismatch")
        }
        runner.test("J8.2-26 frame address zero is rejected") {
            let g = try generated()
            let invalid = replacePlan(try installPlan(g.result), frameAddress: 0)
            try expectSyntheticPlan(invalid, visits: g.expectedVisitFrames, env: env,
                                    finalTop: 0,
                                    error: { if case .unexpectedFrameAddress(0) = $0 { return true }; return false },
                                    message: "zero frame address")
        }
        runner.test("J8.2-27 final handoff stays data-only and reports no context application") {
            let g = try generated()
            let h = try makeHandoff(g, env: env)
            try runner.check(!h.controlTransferPerformed && !h.j7Plan.controlTransferPerformed,
                             "handoff must not perform a transfer")
        }

        runner.lines.append("RESULT: \(runner.passed)/\(runner.passed + runner.failed) passed; \(runner.failed) failed")
        runner.lines.append("SCOPE: J.6 SJLJ phase-2 synthetic metadata -> J.8.2 bridge -> J.7 plan -> J.8.1 frame integrity. All pointers/registers are host values only.")
        runner.lines.append("LIMIT: exceptionPointer is an explicit bridge input because J.6 plan does not carry the exception-object address. No personality, unwinder, callback pointer, pthread TSD, CPU context, Guest instruction or Guest Memory operation is executed.")
        if runner.failed != 0 { throw Failure(description: runner.lines.joined(separator: "\n")) }
        return runner.lines.joined(separator: "\n")
    }

    private static func makeEnvironment(lsdaHexURL: URL, evidenceURL: URL,
                                        crosswalkURL: URL) throws -> Environment {
        let text = try String(contentsOf: lsdaHexURL, encoding: .utf8)
        let hex = text.filter { !$0.isWhitespace }
        guard hex.count % 2 == 0 else { throw Failure(description: "odd LSDA hex length") }
        var bytes = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let value = UInt8(hex[i..<j], radix: 16) else { throw Failure(description: "invalid LSDA hex") }
            bytes.append(value); i = j
        }
        return Environment(lsda: try RE4StageJ6ExtraProductListLSDA.parse(bytes),
                           j7: try RE4StageJ7LandingPadContextModel(evidenceURL: evidenceURL,
                                                                     crosswalkURL: crosswalkURL))
    }

    private static func makeGenerated(env: Environment, row: Int, forced: Bool,
                                      exception: UInt32, savedSP: UInt32,
                                      savedR7: UInt32) throws -> Generated {
        guard (2...20).contains(row) else { throw Failure(description: "test row out of range") }
        let machine = RE4StageJ6SJLJStateMachine(lsda: env.lsda)
        _ = try machine.register(threadID: 1, address: 0x7000, selectorRaw: UInt32.max,
            personality: .none, savedR7: 0, continuationPC: 0, savedSP: 0)
        _ = try machine.register(threadID: 1, address: 0x7100, selectorRaw: UInt32(row - 1),
            personality: .extraProductListCleanupOnly, savedR7: savedR7,
            continuationPC: RE4StageJ7LandingPadContextModel.cleanupContinuationPC, savedSP: savedSP)
        _ = try machine.register(threadID: 1, address: 0x7200, selectorRaw: UInt32.max,
            personality: .none, savedR7: 0, continuationPC: 0, savedSP: 0)
        _ = try machine.register(threadID: 1, address: 0x7300, selectorRaw: UInt32.max,
            personality: .none, savedR7: 0, continuationPC: 0, savedSP: 0)

        let result: RE4StageJ6Phase2Result
        if forced {
            result = machine.phase2Forced(threadID: 1, stopFunctionRaw: 0xF00D0001,
                                          stopParameter: 0xCAFE1234, syntheticStop: { _ in 0 })
        } else {
            result = machine.phase2(threadID: 1, handlerFrame: 0)
        }
        return Generated(machine: machine, result: result, selectedFrame: 0x7100,
                         expectedVisitFrames: [0x7300, 0x7200, 0x7100],
                         exceptionPointer: exception)
    }

    private static func installPlan(_ result: RE4StageJ6Phase2Result) throws -> RE4StageJ6ContextInstallPlan {
        guard case .installContextPending(let plan, _) = result else {
            throw Failure(description: "phase 2 result is not INSTALL_CONTEXT")
        }
        return plan
    }

    private static func makeHandoff(_ generated: Generated, env: Environment) throws -> RE4StageJ82ContextHandoff {
        guard case .installContextPending(_, _) = generated.result else {
            throw Failure(description: "phase 2 did not install context")
        }
        return try RE4StageJ82SJLJContextBridge.makeHandoff(
            from: generated.result, exceptionPointer: generated.exceptionPointer,
            finalTSDTopAddress: generated.machine.top(threadID: 1), j7Model: env.j7)
    }

    private static func replacePlan(_ p: RE4StageJ6ContextInstallPlan,
                                    frameAddress: UInt32? = nil,
                                    action: RE4StageJ6UnwindActions? = nil,
                                    row: Int?? = nil,
                                    index: UInt32?? = nil,
                                    savedPC: UInt32? = nil,
                                    landingPC: UInt32?? = nil,
                                    retained: Bool? = nil,
                                    transferred: Bool? = nil) -> RE4StageJ6ContextInstallPlan {
        RE4StageJ6ContextInstallPlan(
            frameAddress: frameAddress ?? p.frameAddress,
            action: action ?? p.action,
            lsdaRow: row ?? p.lsdaRow,
            landingPadIndex: index ?? p.landingPadIndex,
            savedR7: p.savedR7, savedSP: p.savedSP,
            savedContinuationPC: savedPC ?? p.savedContinuationPC,
            landingPadPC: landingPC ?? p.landingPadPC,
            frameRetainedAtTSDTop: retained ?? p.frameRetainedAtTSDTop,
            controlTransferPerformed: transferred ?? p.controlTransferPerformed)
    }

    private static func expectSyntheticPlan(_ plan: RE4StageJ6ContextInstallPlan,
                                            visits: [UInt32],
                                            env: Environment,
                                            finalTop: UInt32 = 0x7100,
                                            error: (RE4StageJ82BridgeError) -> Bool,
                                            message: String) throws {
        let visitList = visits.map { address in
            RE4StageJ6Phase2Visit(frameAddress: address,
                actions: plan.action,
                decision: address == plan.frameAddress
                    ? .installCleanupContext(row: plan.lsdaRow ?? 0, landingPadIndex: plan.landingPadIndex ?? 0)
                    : .continueUnwind,
                stopCallbackReturn: nil)
        }
        do {
            _ = try RE4StageJ82SJLJContextBridge.makeHandoff(
                from: .installContextPending(plan: plan, visits: visitList),
                exceptionPointer: 0xA1040000,
                finalTSDTopAddress: finalTop,
                j7Model: env.j7)
            throw Failure(description: "Expected bridge error: \(message)")
        } catch let failure as Failure { throw failure }
        catch let actual as RE4StageJ82BridgeError {
            guard error(actual) else { throw Failure(description: "Wrong bridge error for \(message): \(actual)") }
        }
    }
}
