import Foundation

public enum RE4StageJ6SJLJPersonalityTests {
    private struct TestFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private struct CrosswalkRow {
        let row: Int
        let dispatchIndex: Int
        let action: UInt32
        let calls: [UInt32]
        let status: String
    }

    public static func run(lsdaHexURL: URL, crosswalkURL: URL) throws -> String {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw TestFailure(message) }
        }
        func readHex(_ url: URL) throws -> Data {
            let text = try String(contentsOf: url, encoding: .utf8)
            let cleaned = text.filter { !$0.isWhitespace }
            guard cleaned.count % 2 == 0 else { throw TestFailure("LSDA hex fixture has an odd number of digits") }
            var data = Data(); var index = cleaned.startIndex
            while index < cleaned.endIndex {
                let next = cleaned.index(index, offsetBy: 2)
                guard let value = UInt8(cleaned[index..<next], radix: 16) else {
                    throw TestFailure("LSDA hex fixture contains a non-hex byte")
                }
                data.append(value); index = next
            }
            return data
        }
        func readCrosswalk(_ url: URL) throws -> [CrosswalkRow] {
            let text = try String(contentsOf: url, encoding: .utf8)
            let lines = text.split(whereSeparator: \.isNewline).map(String.init)
            guard lines.first == "LSDA_Table_Row,LandingPad_Dispatch_Index,Action,Matched_Call_VAs,Match_Status" else {
                throw TestFailure("Unexpected J.1 crosswalk fixture header")
            }
            return try lines.dropFirst().map { line in
                let c = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                guard c.count == 5, let row = Int(c[0]), let dispatch = Int(c[1]),
                      let action = UInt32(c[2]) else { throw TestFailure("Malformed crosswalk row: \(line)") }
                let calls = c[3].isEmpty ? [] : try c[3].split(separator: ";").map { token -> UInt32 in
                    let trimmed = token.trimmingCharacters(in: .whitespaces)
                    guard trimmed.hasPrefix("0x"), let value = UInt32(trimmed.dropFirst(2), radix: 16) else {
                        throw TestFailure("Malformed callsite address: \(trimmed)")
                    }
                    return value
                }
                return CrosswalkRow(row: row, dispatchIndex: dispatch, action: action,
                                    calls: calls, status: c[4])
            }
        }
        func makeFrame(_ machine: RE4StageJ6SJLJStateMachine, _ address: UInt32,
                       _ selector: UInt32, _ personality: RE4StageJ6FramePersonality,
                       _ previous: UInt32 = 0) throws -> RE4StageJ6SJLJFrame {
            try machine.register(threadID: 1, address: address, selectorRaw: selector,
                                 personality: personality, savedR7: address + 0x20,
                                 continuationPC: address + 0x24, savedSP: address + 0x28)
        }
        var passed = 0
        var failed = 0
        var lines: [String] = []
        func test(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; lines.append("PASS — \(name)") }
            catch { failed += 1; lines.append("FAIL — \(name): \(error)") }
        }

        let raw = try readHex(lsdaHexURL)
        let profile = try RE4StageJ6ExtraProductListLSDA.parse(raw)
        let crosswalk = try readCrosswalk(crosswalkURL)
        let machineFactory = { RE4StageJ6SJLJStateMachine(lsda: profile) }

        test("01 pinned LSDA header and bounded 0x28-byte ULEB table") {
            try check(profile.lpStartEncoding == 0xFF && profile.typeTableEncoding == 0xFF &&
                      profile.callSiteEncoding == 0x03 && profile.rawCallSiteTableLength == 40,
                      "#101 LSDA header fields mismatch")
            try check(raw.count == 44 && profile.entries.count == 20, "#101 LSDA extent/count mismatch")
        }
        test("02 all 20 LSDA pairs are selector 0...19 with action offset zero") {
            try check(profile.entries.map(\.landingPadIndex) == Array(0...19).map(UInt32.init),
                      "landing-pad selector sequence mismatch")
            try check(profile.entries.allSatisfy { $0.actionOffset == 0 },
                      "#101 action offsets must all be zero")
        }
        test("03 J.1 crosswalk preserves 19 matched rows and 20 static correlations") {
            try check(crosswalk.count == 20, "crosswalk row count mismatch")
            try check(crosswalk.filter { !$0.calls.isEmpty }.count == 19, "distinct matched row count mismatch")
            try check(crosswalk.reduce(0) { $0 + $1.calls.count } == 20, "static correlation count mismatch")
            try check(crosswalk[0].calls.isEmpty && crosswalk[0].status == "NO_STATIC_CALLSITE_MATCH",
                      "row 1 must remain unmatched")
            try check(crosswalk[1].calls == [0x555C, 0x5588] &&
                      crosswalk[1].status == "MULTIPLE_STATIC_CALLSITES_SHARE_INDEX",
                      "row 2 duplicate selector relation mismatch")
        }
        test("04 J.1 table ordinals map to the pinned 20 selector/action pairs") {
            for i in 0..<20 {
                try check(crosswalk[i].row == i + 1 && crosswalk[i].dispatchIndex == i + 1 &&
                          crosswalk[i].action == 0, "crosswalk metadata mismatch at row \(i + 1)")
                try check(profile.entries[i].row == crosswalk[i].row &&
                          profile.entries[i].landingPadIndex == UInt32(i),
                          "LSDA/crosswalk mismatch at row \(i + 1)")
            }
        }
        test("05 parser rejects unsupported encodings and trailing data") {
            var bad = raw; bad[0] = 0x00
            do { _ = try RE4StageJ6ExtraProductListLSDA.parse(bad); throw TestFailure("LPStart encoding accepted") }
            catch let e as RE4StageJ6LSDAError { try check(e == .unsupportedLPStartEncoding(0), "wrong LPStart rejection") }
            bad = raw; bad[2] = 0x01
            do { _ = try RE4StageJ6ExtraProductListLSDA.parse(bad); throw TestFailure("call-site encoding accepted") }
            catch let e as RE4StageJ6LSDAError { try check(e == .unsupportedCallSiteEncoding(1), "wrong call-site rejection") }
            bad = raw; bad.append(0)
            do { _ = try RE4StageJ6ExtraProductListLSDA.parse(bad); throw TestFailure("trailing byte accepted") }
            catch let e as RE4StageJ6LSDAError { try check(e == .unexpectedTrailingBytes(1), "wrong trailing-byte rejection") }
        }
        test("06 parser rejects a nonzero action offset in the cleanup-only profile") {
            var bad = raw
            // Row 1 occupies bytes 4-5; row 2 selector/action starts at 6-7.
            bad[7] = 1
            do { _ = try RE4StageJ6ExtraProductListLSDA.parse(bad); throw TestFailure("nonzero action accepted") }
            catch let e as RE4StageJ6LSDAError { try check(e == .nonZeroAction(row: 2, value: 1), "wrong action rejection") }
        }
        test("07 pinned SJLJ IP helpers expose selector+1 and SetIP's inverse") {
            try check((0...19).allSatisfy { selector in
                guard let ip = RE4StageJ6StaticContextHelpers.getIP(selectorRaw: UInt32(selector)),
                      let restored = RE4StageJ6StaticContextHelpers.setIP(ip: ip) else { return false }
                return restored == UInt32(selector)
            }, "GetIP/SetIP round trip mismatch")
            try check(RE4StageJ6StaticContextHelpers.regionStart == 0, "SJLJ region start must match provider helper")
            try check(RE4StageJ6StaticContextHelpers.generalRegisterWordOffset(registerNumber: 0) == 8 &&
                      RE4StageJ6StaticContextHelpers.generalRegisterWordOffset(registerNumber: 7) == 36 &&
                      RE4StageJ6StaticContextHelpers.generalRegisterWordOffset(registerNumber: UInt32.max) == nil,
                      "GetGR/SetGR indexed word-offset arithmetic mismatch")
            let frame = RE4StageJ6SJLJFrame(address: 0x1000, previousFrame: 0, selectorRaw: 4,
                                            personality: .extraProductListCleanupOnly,
                                            personalityRaw: RE4StageJ6ExtraProductListLSDA.personalityAddress,
                                            lsdaRaw: RE4StageJ6ExtraProductListLSDA.address,
                                            savedR7: 0, continuationPC: 0, savedSP: 0)
            try check(RE4StageJ6StaticContextHelpers.getLanguageSpecificData(frame: frame) == 0x001C0996,
                      "GetLanguageSpecificData frame+0x1c mismatch")
        }
        test("08 gxx personality rejects unsupported version and action combinations") {
            try check(RE4StageJ6GxxPersonalityModel.evaluate(version: 2, actions: .searchPhase,
                      callSiteIP: 2, lsda: profile) == .fatalPhase1Error, "unsupported version must fail phase 1")
            let unsupported = RE4StageJ6UnwindActions(rawValue: 0x20)
            try check(RE4StageJ6GxxPersonalityModel.evaluate(version: 1, actions: unsupported,
                      callSiteIP: 2, lsda: profile) == .fatalPhase2Error, "unsupported actions must fail closed")
        }
        test("09 all 20 #101 rows continue search; cleanup-only table never claims a catch") {
            for ip in 1...20 {
                let d = RE4StageJ6GxxPersonalityModel.evaluate(version: 1, actions: .searchPhase,
                                                               callSiteIP: UInt32(ip), lsda: profile)
                try check(d == .continueUnwind, "search unexpectedly claimed handler at IP \(ip)")
            }
        }
        test("10 cleanup phase: selector zero continues and selectors 1...19 request indexed context") {
            let empty = RE4StageJ6GxxPersonalityModel.evaluate(version: 1, actions: .ordinaryCleanup,
                                                               callSiteIP: 1, lsda: profile)
            try check(empty == .continueUnwind, "row 1 selector zero must have no cleanup landing-pad token")
            for ip in 2...20 {
                let expected = RE4StageJ6PersonalityDecision.installCleanupContext(row: ip,
                                                                                    landingPadIndex: UInt32(ip - 1))
                let got = RE4StageJ6GxxPersonalityModel.evaluate(version: 1, actions: .ordinaryCleanup,
                                                                 callSiteIP: UInt32(ip), lsda: profile)
                try check(got == expected, "cleanup decision mismatch at call-site IP \(ip)")
            }
        }
        test("11 handler-frame reason 6 does not turn #101 cleanup entries into typed catches") {
            for ip in 1...20 {
                let got = RE4StageJ6GxxPersonalityModel.evaluate(version: 1, actions: .handlerCleanup,
                                                                 callSiteIP: UInt32(ip), lsda: profile)
                try check(got == .continueUnwind, "#101 incorrectly claimed handler frame at IP \(ip)")
            }
        }
        test("12 RaiseException clears private words and finds the synthetic outer handler") {
            let m = machineFactory()
            _ = try makeFrame(m, 0x1000, 19, .syntheticOuterHandler)
            _ = try makeFrame(m, 0x2000, 19, .extraProductListCleanupOnly)
            var ex = RE4StageJ6SJLJException(private1: 0xAAAA, private2: 0xBBBB)
            let result = m.raiseException(threadID: 1, exception: &ex)
            try check(result == .handlerFound(frameAddress: 0x1000, visits: [
                RE4StageJ6Phase1Visit(frameAddress: 0x2000, callSiteIP: 20, decision: .continueUnwind),
                RE4StageJ6Phase1Visit(frameAddress: 0x1000, callSiteIP: 20, decision: .handlerFound)
            ]), "phase-1 walk/handler selection mismatch")
            try check(ex.private1 == 0 && ex.private2 == 0x1000, "normal exception private-word state mismatch")
        }
        test("13 no outer handler returns end-of-stack after #101 cleanup-only search") {
            let m = machineFactory()
            _ = try makeFrame(m, 0x2000, 7, .extraProductListCleanupOnly)
            var ex = RE4StageJ6SJLJException(private1: 9, private2: 8)
            let result = m.raiseException(threadID: 1, exception: &ex)
            try check(result == .endOfStack(visits: [
                RE4StageJ6Phase1Visit(frameAddress: 0x2000, callSiteIP: 8, decision: .continueUnwind)
            ]), "cleanup-only LSDA should not create a phase-1 handler")
            try check(ex.private1 == 0 && ex.private2 == 0, "end-of-stack must retain cleared private words")
        }
        test("14 phase 2 installs cleanup metadata, unlinks frame, then resumes at outer handler") {
            let m = machineFactory()
            _ = try makeFrame(m, 0x1000, 0, .syntheticOuterHandler)
            _ = try makeFrame(m, 0x2000, 19, .extraProductListCleanupOnly)
            let ex = RE4StageJ6SJLJException(private1: 0, private2: 0x1000)
            let first = m.resume(threadID: 1, exception: ex)
            guard case .installContextPending(let plan, let visits) = first else {
                throw TestFailure("expected #101 cleanup context request")
            }
            try check(plan.frameAddress == 0x2000 && plan.action == .ordinaryCleanup &&
                      plan.lsdaRow == 20 && plan.landingPadIndex == 19,
                      "#101 phase-2 plan mismatch")
            try check(plan.landingPadPC == nil && !plan.controlTransferPerformed,
                      "model must not invent or execute landing-pad PC")
            try check(visits.first?.actions == .ordinaryCleanup && m.top(threadID: 1) == 0x1000,
                      "phase 2 must unlink the cleanup frame before synthetic resume")
            let second = m.resume(threadID: 1, exception: ex)
            guard case .installContextPending(let handlerPlan, let handlerVisits) = second else {
                throw TestFailure("expected synthetic outer handler install request on resumed phase 2")
            }
            try check(handlerPlan.frameAddress == 0x1000 && handlerVisits.first?.actions == .handlerCleanup,
                      "selected handler frame must receive reason/action 6")
            try check(m.top(threadID: 1) == 0, "synthetic handler frame should be unlinked after install request")
        }
        test("15 CONTINUE_UNWIND at the selected handler frame is fatal phase-2 error") {
            let m = machineFactory()
            _ = try makeFrame(m, 0x3000, 19, .extraProductListCleanupOnly)
            let r = m.phase2(threadID: 1, handlerFrame: 0x3000)
            guard case .fatalPhase2Error(let frame, _) = r else {
                throw TestFailure("handler frame continue-unwind was not rejected")
            }
            try check(frame == 0x3000, "fatal handler frame address mismatch")
        }
        test("16 Resume private words distinguish normal handler frame from forced stop callback") {
            try check(RE4StageJ6ResumeRoute.route(private1: 0, private2: 0x1234) ==
                      .normalPhase2(handlerFrame: 0x1234), "normal Resume route mismatch")
            try check(RE4StageJ6ResumeRoute.route(private1: 0xABCDEF01, private2: 0x5678) ==
                      .forcedPhase2(stopFunctionRaw: 0xABCDEF01, stopParameter: 0x5678),
                      "forced Resume route must treat private_1 as stop callback and private_2 as its parameter")
        }
        test("17 forced phase 2 calls only synthetic stop closure with reason 10") {
            let m = machineFactory()
            _ = try makeFrame(m, 0x4000, 19, .extraProductListCleanupOnly)
            let ex = RE4StageJ6SJLJException(private1: 0xFEED0001, private2: 0xCAFE1234)
            var events: [RE4StageJ6ForcedStopEvent] = []
            let r = m.resume(threadID: 1, exception: ex) { event in events.append(event); return 0 }
            guard case .installContextPending(let plan, _) = r else {
                throw TestFailure("forced phase 2 should request #101 cleanup context")
            }
            try check(events == [RE4StageJ6ForcedStopEvent(stopFunctionRaw: 0xFEED0001,
                      stopParameter: 0xCAFE1234, frameAddress: 0x4000, reason: 10)],
                      "forced stop event mismatch")
            try check(plan.action == .forcedCleanup && plan.frameAddress == 0x4000,
                      "forced personality action must be 10")
            try check(plan.landingPadPC == nil && m.top(threadID: 1) == 0,
                      "forced plan must remain metadata-only and unlink frame")
        }
        test("18 forced stop callback nonzero aborts with fatal phase-2 error") {
            let m = machineFactory()
            _ = try makeFrame(m, 0x5000, 19, .extraProductListCleanupOnly)
            let r = m.phase2Forced(threadID: 1, stopFunctionRaw: 0xFEED0001,
                                   stopParameter: 0x1234, syntheticStop: { _ in 1 })
            guard case .fatalPhase2Error(let frame, let visits) = r else {
                throw TestFailure("nonzero stop result did not fail forced phase 2")
            }
            try check(frame == 0x5000 && visits.first?.stopCallbackReturn == 1,
                      "forced stop failure metadata mismatch")
        }
        test("19 forced Resume without synthetic callback fails closed") {
            let m = machineFactory()
            _ = try makeFrame(m, 0x6000, 19, .extraProductListCleanupOnly)
            let r = m.resume(threadID: 1,
                             exception: RE4StageJ6SJLJException(private1: 0xFEED0001, private2: 0xABCD))
            try check(r == .missingSyntheticStopCallback(stopFunctionRaw: 0xFEED0001, visits: []),
                      "raw stop function must never be invoked implicitly")
        }
        test("20 out-of-profile selector remains unresolved without inventing a dispatch target") {
            let m = machineFactory()
            _ = try makeFrame(m, 0x7000, 20, .extraProductListCleanupOnly) // GetIP = 21; table has 20 rows.
            let r = m.phase2(threadID: 1, handlerFrame: 0)
            try check(r == .unresolvedCallSiteIndex(frameAddress: 0x7000, callSiteIP: 21, visits: [
                RE4StageJ6Phase2Visit(frameAddress: 0x7000, actions: .ordinaryCleanup,
                                      decision: .unresolvedCallSiteIndex(21), stopCallbackReturn: nil)
            ]), "out-of-range selector must remain explicitly unresolved")
            try check(m.top(threadID: 1) == 0x7000, "unresolved mapping must not unlink the frame")
        }

        lines.append("RESULT: \(passed)/\(passed + failed) passed; \(failed) failed")
        lines.append("SCOPE: host-only synthetic SJLJ/personality/LSDA model. No shared-cache function, personality, unwinder, landing pad, ARM/Thumb instruction, Guest Memory or raw callback pointer was executed.")
        lines.append("LIMIT: #101 cleanup-only LSDA is modelled; typed catch matching, arbitrary DWARF encodings, exact landing-pad PC reconstruction and actual context transfer remain unsupported.")
        if failed != 0 { throw TestFailure(lines.joined(separator: "\n")) }
        return lines.joined(separator: "\n")
    }
}