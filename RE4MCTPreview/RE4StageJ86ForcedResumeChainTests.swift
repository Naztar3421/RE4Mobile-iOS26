import Foundation

public enum RE4StageJ86ForcedResumeChainTests {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }
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
    }
    private struct Environment {
        let lsda: RE4StageJ6ExtraProductListLSDA
        let j7: RE4StageJ7LandingPadContextModel
    }
    private struct Fixture {
        let machine: RE4StageJ6SJLJStateMachine
        let handoff: RE4StageJ83HandoffInput
        let cleanupAddresses: [UInt32]
        let ordinaryAddresses: [UInt32]
        let bottomAddress: UInt32
        let token: UInt32
        let parameter: UInt32
        let exceptionPointer: UInt32
    }

    public static func run(lsdaHexURL: URL, evidenceURL: URL,
                           crosswalkURL: URL) throws -> String {
        let env = try makeEnvironment(lsdaHexURL: lsdaHexURL,
                                      evidenceURL: evidenceURL,
                                      crosswalkURL: crosswalkURL)
        let runner = Runner()

        runner.test("01 three #101 cleanup frames complete in stack order across repeated Resume cycles") {
            let f = try fixture(env: env, cleanupRows: [4, 9, 20])
            var events: [RE4StageJ6ForcedStopEvent] = []
            let result = try run(f, env: env) { event in events.append(event); return 0 }
            try runner.check(result.terminal == .endOfStack &&
                             result.completedCleanupFrameAddresses == Array(f.cleanupAddresses.reversed()),
                             "three cleanup frames did not complete from newest to oldest")
            try runner.check(result.cycles.count == 3 &&
                             result.cycles.allSatisfy { $0.snapshot.completedFrameRetainsSentinel },
                             "each cleanup cycle must retain its sentinel-marked frame")
            try runner.check(result.finalModelTSDTop == f.cleanupAddresses[0],
                             "host model should retain the last frame explicitly installed as TSD top")
            try runner.check(events.map(\.frameAddress) == result.allStopEvents.map(\.frameAddress),
                             "external stop-event trace differs from chain snapshot")
        }

        runner.test("02 every cycle visits completed frame first, then intervening frames and next cleanup") {
            let f = try fixture(env: env, cleanupRows: [5, 12, 19])
            let result = try run(f, env: env) { _ in 0 }
            let addresses = result.cycles.map { $0.snapshot.callbackVisitAddresses }
            try runner.check(addresses.count == 3 &&
                             addresses[0].first == f.cleanupAddresses[2] &&
                             addresses[0].last == f.cleanupAddresses[1] &&
                             addresses[1].first == f.cleanupAddresses[1] &&
                             addresses[1].last == f.cleanupAddresses[0] &&
                             addresses[2].first == f.cleanupAddresses[0] &&
                             addresses[2].last == f.bottomAddress,
                             "repeated forced Resume visit sequence mismatch")
            try runner.check(addresses[0].contains(f.ordinaryAddresses[1]) &&
                             addresses[1].contains(f.ordinaryAddresses[0]),
                             "intervening synthetic frames were skipped")
        }

        runner.test("03 stop token, opaque parameter and reason 10 remain stable across all cycles") {
            let f = try fixture(env: env, cleanupRows: [2, 8, 14])
            let result = try run(f, env: env) { _ in 0 }
            try runner.check(!result.allStopEvents.isEmpty && result.allStopEvents.allSatisfy {
                $0.stopFunctionRaw == f.token && $0.stopParameter == f.parameter && $0.reason == 10
            }, "forced callback metadata changed between cycles")
            try runner.check(result.cycles.allSatisfy {
                $0.stopEvents.map(\.frameAddress) == $0.snapshot.callbackVisitAddresses
            }, "per-cycle callback list does not match frame visit order")
        }

        runner.test("04 rejection at the second cleanup aborts before any older frame is visited") {
            let f = try fixture(env: env, cleanupRows: [3, 10, 18])
            var rejected = false
            let result = try run(f, env: env) { event in
                if event.frameAddress == f.cleanupAddresses[1] && !rejected {
                    rejected = true
                    return -7
                }
                return 0
            }
            try runner.check(result.terminal == .stopCallbackRejected(
                frameAddress: f.cleanupAddresses[1], returnCode: -7),
                "second cleanup rejection was not terminal")
            try runner.check(result.completedCleanupFrameAddresses == [f.cleanupAddresses[2]] &&
                             result.cycles.count == 1 &&
                             result.cycles[0].snapshot.nextCleanupInstallPlan == nil,
                             "chain proceeded past the rejected second cleanup")
            try runner.check(!result.allStopEvents.contains(where: {
                $0.frameAddress == f.cleanupAddresses[0]
            }), "older cleanup frame was visited after callback rejection")
        }

        runner.test("05 unresolved next cleanup selector remains unresolved and does not fabricate install") {
            let f = try fixture(env: env, cleanupRows: [21, 9, 4])
            let result = try run(f, env: env) { _ in 0 }
            try runner.check(result.terminal == .unresolvedCallSite(
                frameAddress: f.cleanupAddresses[0], callSiteIP: 21),
                "out-of-profile selector should remain unresolved")
            try runner.check(result.cycles.count == 2 &&
                             result.cycles.last?.snapshot.nextCleanupInstallPlan == nil,
                             "unresolved frame must not be represented as installed cleanup")
        }

        runner.test("06 cleanup-frame cap returns an explicit continuation point without completing it") {
            let f = try fixture(env: env, cleanupRows: [4, 9, 16])
            let result = try RE4StageJ86ForcedResumeChainModel.completeChain(
                machine: f.machine, threadID: 1, initialHandoff: f.handoff,
                exception: RE4StageJ6SJLJException(private1: f.token, private2: f.parameter),
                exceptionPointer: f.exceptionPointer, j7Model: env.j7,
                syntheticStop: { _ in 0 }, maxCleanupFrames: 1)
            try runner.check(result.terminal == .cleanupLimitReached(
                nextCleanupFrameAddress: f.cleanupAddresses[1]) &&
                result.completedCleanupFrameAddresses == [f.cleanupAddresses[2]] &&
                result.finalModelTSDTop == f.cleanupAddresses[1],
                "frame cap must leave the next cleanup installed but uncompleted")
        }

        runner.test("07 all completed cleanup frames remain registered with 0xFFFFFFFF sentinel") {
            let f = try fixture(env: env, cleanupRows: [6, 11, 17])
            let result = try run(f, env: env) { _ in 0 }
            for address in result.completedCleanupFrameAddresses {
                let frame = f.machine.frame(threadID: 1, address: address)
                try runner.check(frame?.selectorRaw == UInt32.max,
                                 String(format: "completed cleanup 0x%08X lost its sentinel", address))
            }
        }

        runner.test("08 raw stop token, Resume pointer, Guest execution and context transfer remain unused") {
            let f = try fixture(env: env, cleanupRows: [2, 7, 15])
            let result = try run(f, env: env) { _ in 0 }
            try runner.check(!result.targetStopFunctionInvoked &&
                             !result.targetResumeFunctionInvoked &&
                             !result.guestInstructionsExecuted && result.guestMemoryWrites == 0 &&
                             !result.cpuContextApplied && !result.controlTransferPerformed &&
                             result.cycles.allSatisfy {
                                 !$0.snapshot.targetStopFunctionInvoked &&
                                 !$0.snapshot.targetResumeFunctionInvoked &&
                                 !$0.snapshot.guestInstructionsExecuted &&
                                 $0.snapshot.guestMemoryWrites == 0 &&
                                 !$0.snapshot.cpuContextApplied &&
                                 !$0.snapshot.controlTransferPerformed
                             }, "J.8.6 must remain a host-only chain model")
        }

        runner.lines.append("RESULT: \(runner.passed)/\(runner.passed + runner.failed) passed; \(runner.failed) failed")
        runner.lines.append("SCOPE: repeated J.8.5 forced Resume cycles over a synthetic #101 cleanup chain, with a fresh J.8.2/J.7 handoff for each newly selected cleanup frame.")
        runner.lines.append("LIMIT: explicit host stop closure only; no target callback, Resume, personality, unwinder, pthread TSD, Guest instruction, Guest Memory write, CPU restore, or control transfer.")
        if runner.failed != 0 { throw Failure(description: runner.lines.joined(separator: "\n")) }
        return runner.lines.joined(separator: "\n")
    }

    private static func run(_ f: Fixture, env: Environment,
                            stop: @escaping (RE4StageJ6ForcedStopEvent) -> Int32) throws
        -> RE4StageJ86ForcedResumeChainSnapshot {
        try RE4StageJ86ForcedResumeChainModel.completeChain(
            machine: f.machine, threadID: 1, initialHandoff: f.handoff,
            exception: RE4StageJ6SJLJException(private1: f.token, private2: f.parameter),
            exceptionPointer: f.exceptionPointer, j7Model: env.j7,
            syntheticStop: stop)
    }

    private static func fixture(env: Environment, cleanupRows: [Int]) throws -> Fixture {
        guard cleanupRows.count == 3,
              cleanupRows.allSatisfy({ (2...21).contains($0) }) else {
            throw Failure(description: "fixture requires exactly three cleanup rows in 2...21")
        }
        let machine = RE4StageJ6SJLJStateMachine(lsda: env.lsda)
        let bottom: UInt32 = 0x7000
        let cleanups: [UInt32] = [0x7100, 0x7300, 0x7500]
        let ordinary: [UInt32] = [0x7200, 0x7400]
        let token: UInt32 = 0xFEED0001
        let parameter: UInt32 = 0xCAFE1234
        let exceptionPointer: UInt32 = 0xA0F00000
        _ = try machine.register(threadID: 1, address: bottom, selectorRaw: 0,
            personality: .syntheticOuterHandler, savedR7: 0xA0020000,
            continuationPC: 0x2220, savedSP: 0xA0030000)

        // Register oldest to newest. The two ordinary frames separate the three
        // cleanup frames so each Resume cycle must walk real predecessor links.
        let row0 = cleanupRows[0]
        _ = try machine.register(threadID: 1, address: cleanups[0],
            selectorRaw: UInt32(row0 - 1), personality: .extraProductListCleanupOnly,
            savedR7: 0xA0120000, continuationPC: RE4StageJ7LandingPadContextModel.cleanupContinuationPC,
            savedSP: 0xA0130000)
        _ = try machine.register(threadID: 1, address: ordinary[0], selectorRaw: 2,
            personality: .none, savedR7: 0xA0220000, continuationPC: 0x2230, savedSP: 0xA0230000)
        let row1 = cleanupRows[1]
        _ = try machine.register(threadID: 1, address: cleanups[1],
            selectorRaw: UInt32(row1 - 1), personality: .extraProductListCleanupOnly,
            savedR7: 0xA0320000, continuationPC: RE4StageJ7LandingPadContextModel.cleanupContinuationPC,
            savedSP: 0xA0330000)
        _ = try machine.register(threadID: 1, address: ordinary[1], selectorRaw: 4,
            personality: .none, savedR7: 0xA0420000, continuationPC: 0x2240, savedSP: 0xA0430000)
        let row2 = cleanupRows[2]
        _ = try machine.register(threadID: 1, address: cleanups[2],
            selectorRaw: UInt32(row2 - 1), personality: .extraProductListCleanupOnly,
            savedR7: 0xA0520000, continuationPC: RE4StageJ7LandingPadContextModel.cleanupContinuationPC,
            savedSP: 0xA0530000)

        // Initial forced phase-2 selection is the preceding stage's handoff input.
        let initial = machine.phase2Forced(threadID: 1, stopFunctionRaw: token,
            stopParameter: parameter, syntheticStop: { _ in 0 })
        let bridge = try RE4StageJ82SJLJContextBridge.makeHandoff(
            from: initial, exceptionPointer: exceptionPointer,
            finalTSDTopAddress: machine.top(threadID: 1), j7Model: env.j7)
        let handoff = RE4StageJ83HandoffInput(
            phase2Plan: bridge.phase2Plan, j7Plan: bridge.j7Plan,
            finalTSDTopAddress: bridge.finalTSDTopAddress,
            controlTransferPerformed: bridge.controlTransferPerformed)
        return Fixture(machine: machine, handoff: handoff,
            cleanupAddresses: cleanups, ordinaryAddresses: ordinary,
            bottomAddress: bottom, token: token, parameter: parameter,
            exceptionPointer: exceptionPointer)
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
}
