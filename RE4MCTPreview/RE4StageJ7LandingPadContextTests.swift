import Foundation

public enum RE4StageJ7LandingPadContextTests {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    public static func run(evidenceURL: URL, crosswalkURL: URL) throws -> String {
        let model = try RE4StageJ7LandingPadContextModel(evidenceURL: evidenceURL, crosswalkURL: crosswalkURL)
        var passed = 0, failed = 0
        var lines: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw Failure(description: message) }
        }
        func test(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; lines.append("PASS — \(name)") }
            catch { failed += 1; lines.append("FAIL — \(name): \(error)") }
        }

        test("01 function reserves 0x60 bytes before constructing the SJLJ frame") {
            try check(model.evidence["RES4_STACK_FRAME_ALLOCATION"]?.observedValue == "0x00000060",
                      "stack allocation must be pinned before calculating frame offsets")
        }
        test("02 pinned Res4 frame base is post-prologue SP+0x18") {
            try check(RE4StageJ7LandingPadContextModel.frameBaseOffset == 0x18, "frame base offset")
        }
        test("03 LSDA pointer is reconstructed from literal plus ARM PC") {
            try check(RE4StageJ7LandingPadContextModel.lsdaVA == 0x001C0996, "LSDA VA")
        }
        test("04 continuation literal 0x3D4 plus architectural PC 0x51D4 equals 0x55A8") {
            try check(0x000051D4 + 0x000003D4 == RE4StageJ7LandingPadContextModel.cleanupContinuationPC,
                      "PC-relative literal arithmetic")
        }
        test("05 saved context words map to frame offsets +0x20/+0x24/+0x28") {
            try check(RE4StageJ7LandingPadContextModel.frameSavedR7Offset == 0x20 &&
                      RE4StageJ7LandingPadContextModel.frameSavedPCOffset == 0x24 &&
                      RE4StageJ7LandingPadContextModel.frameSavedSPOffset == 0x28,
                      "saved context frame offsets")
        }
        test("06 personality zero-action BGE skips context+0x24 PC overwrite") {
            let row = model.evidence["PERSONALITY_PC_OVERWRITE_BLOCK"]
            try check(row?.observedValue == "SKIPPED", "PC overwrite block must be bypassed")
        }
        test("07 personality returns INSTALL_CONTEXT code 7") {
            try check(RE4StageJ7LandingPadContextModel.personalityInstallContextCode == 7,
                      "personality code")
        }
        test("08 SetGR register zero writes frame+0x08") {
            try check(RE4StageJ7LandingPadContextModel.frameGR0Offset == 0x08, "GR0 offset")
        }
        test("09 SetGR register one writes frame+0x0C") {
            try check(RE4StageJ7LandingPadContextModel.frameGR1Offset == 0x0C, "GR1 offset")
        }
        test("10 SetIP uses frame+0x04, not saved continuation frame+0x24") {
            try check(RE4StageJ7LandingPadContextModel.frameSelectorOffset == 0x04 &&
                      RE4StageJ7LandingPadContextModel.frameSavedPCOffset == 0x24,
                      "selector and branch PC must remain separate")
        }
        test("11 TSD top is explicitly reset to the current frame before context restore") {
            try check(model.evidence["PHASE2_TSD_CURRENT_FRAME"]?.observedValue == "R1=R4" &&
                      model.evidence["PHASE2_PTHREAD_SET_SPECIFIC"]?.observedValue == "0x358CFD5C",
                      "pthread_setspecific current-frame evidence")
        }
        test("12 phase2 restores R7/SP/PC from exact SJLJ frame offsets") {
            try check(model.evidence["PHASE2_RESTORE_R7"]?.observedValue == "0x00000020" &&
                      model.evidence["PHASE2_RESTORE_SP"]?.observedValue == "0x00000028" &&
                      model.evidence["PHASE2_RESTORE_PC"]?.observedValue == "0x00000024" &&
                      model.evidence["PHASE2_BRANCH_PC"]?.observedValue == "BX R0",
                      "phase2 context restore sequence")
        }
        test("13 cleanup trampoline reads GR0 through SP+0x20") {
            try check(model.evidence["RES4_CLEANUP_ENTRY"]?.observedValue == "0x00000008",
                      "cleanup entry source offset should resolve to frame+8")
        }
        test("14 cleanup trampoline saves the same exception pointer for Resume") {
            try check(model.evidence["RES4_SAVE_EXCEPTION_PTR"]?.observedValue == "0x00000010" &&
                      model.evidence["RES4_RESUME_LOAD_EXCEPTION"]?.observedValue == "0x00000010",
                      "exception pointer local slot")
        }
        test("15 normal epilogue unregister path is bypassed on exceptional cleanup branch") {
            try check(model.evidence["RES4_NORMAL_PATH_BRANCH"]?.observedValue == "0x00005614" &&
                      model.evidence["RES4_NORMAL_UNREGISTER"]?.va == "0x00005618",
                      "normal unregister target")
        }
        test("16 cleanup Resume writes selector sentinel -1 before re-entry") {
            try check(model.evidence["RES4_RESUME_SET_SENTINEL"]?.observedValue == "0x00000004" &&
                      RE4StageJ7LandingPadContextModel.resumeSelectorSentinel == UInt32.max,
                      "selector sentinel write")
        }
        test("17 GetIP(-1) wraps to zero and Resume continues past this frame") {
            try check(RE4StageJ7LandingPadContextModel.resumeSelectorSentinel &+ 1 == 0,
                      "32-bit GetIP sentinel wrap")
        }
        test("18 J.1 crosswalk preserves 20 rows, 19 matched rows and 20 correlations") {
            try check(model.crosswalk.count == 20 && model.crosswalk.filter { !$0.matchedCallVAs.isEmpty }.count == 19 &&
                      model.crosswalk.reduce(0, { $0 + $1.matchedCallVAs.count }) == 20,
                      "J.1 correlation totals")
        }
        test("19 row 1 remains unmatched and row 2 retains both static callsites") {
            try check(model.crosswalk[0].matchedCallVAs.isEmpty &&
                      model.crosswalk[1].matchedCallVAs == [0x555C, 0x5588],
                      "first two crosswalk rows")
        }
        test("20 row 20 resolves to cleanup count 19 and shared continuation 0x55A8") {
            let p = try model.contextPlan(row: 20, frameAddress: 0xA1010000,
                                          savedR7: 0xA1020000, savedSP: 0xA1030000,
                                          unwindExceptionPointer: 0xA1040000)
            try check(p.selector == 19 && p.dispatchIndex == 20 && p.cleanupObjectCount == 19 &&
                      p.cleanupContinuationPC == 0x55A8 && p.savedContinuationPC == 0x55A8,
                      "row 20 plan")
        }
        test("21 row 2 preserves duplicate callsites but shares the same cleanup PC") {
            let p = try model.contextPlan(row: 2, frameAddress: 0xB1010000,
                                          savedR7: 0xB1020000, savedSP: 0xB1030000,
                                          unwindExceptionPointer: 0xB1040000)
            try check(p.matchedCallVAs == [0x555C, 0x5588] && p.cleanupContinuationPC == 0x55A8,
                      "row 2 duplicate callsite plan")
        }
        test("22 all nonzero cleanup selectors share one continuation target") {
            let plans = try (2...20).map { row in
                try model.contextPlan(row: row, frameAddress: UInt32(0xC0000000 + row),
                                      savedR7: 0xC1000000, savedSP: 0xC2000000,
                                      unwindExceptionPointer: 0xC3000000)
            }
            try check(Set(plans.map(\.cleanupContinuationPC)) == [0x55A8], "cleanup target must be invariant")
        }
        test("23 plan maps GR0 to exception pointer and GR1 to zero") {
            let p = try model.contextPlan(row: 7, frameAddress: 0xD1000000,
                                          savedR7: 0xD2000000, savedSP: 0xD3000000,
                                          unwindExceptionPointer: 0xD4000000)
            try check(p.setGR0Offset == 8 && p.setGR0Value == 0xD4000000 &&
                      p.setGR1Offset == 12 && p.setGR1Value == 0,
                      "GR0/GR1 context plan")
        }
        test("24 SetIP stores selector in frame+4 while saved PC remains 0x55A8") {
            let p = try model.contextPlan(row: 10, frameAddress: 0xE1000000,
                                          savedR7: 0xE2000000, savedSP: 0xE3000000,
                                          unwindExceptionPointer: 0xE4000000)
            try check(p.setIPArgument == 10 && p.setIPStoredSelector == 9 &&
                      p.cleanupContinuationPC == 0x55A8 && p.contextPCOverwriteSkipped,
                      "SetIP vs continuation PC")
        }
        test("25 plan records retained TSD frame, Resume argument, and no control transfer") {
            let p = try model.contextPlan(row: 3, frameAddress: 0xF1000000,
                                          savedR7: 0xF2000000, savedSP: 0xF3000000,
                                          unwindExceptionPointer: 0xF4000000)
            try check(p.frameRetainedAtTSDTop && p.resumeExceptionArgument == 0xF4000000 &&
                      p.resumeSelectorSentinel == UInt32.max && p.resumeGetIPAfterCleanup == 0 &&
                      p.resumeContinuesPastCurrentFrame && !p.controlTransferPerformed,
                      "resume metadata contract")
        }
        test("26 selector-zero row has no cleanup request") {
            do {
                _ = try model.contextPlan(row: 1, frameAddress: 1, savedR7: 2, savedSP: 3,
                                          unwindExceptionPointer: 4)
                throw Failure(description: "row 1 must not request cleanup context")
            } catch RE4StageJ7Error.noCleanupForZeroSelector { }
        }

        lines.append("RESULT: \(passed)/\(passed + failed) passed; \(failed) failed")
        lines.append("SCOPE: pinned static evidence plus host-only data model. No target function, personality, unwinder, pthread TSD, landing pad, ARM instruction, Guest Memory or CPU context was executed or modified.")
        lines.append("LIMIT: #101 cleanup-only profile only. The model resolves the saved cleanup continuation (0x55A8), not a generic LSDA landing-pad address; it does not install the context or perform BX.")
        if failed != 0 { throw Failure(lines.joined(separator: "\n")) }
        return lines.joined(separator: "\n")
    }
}
