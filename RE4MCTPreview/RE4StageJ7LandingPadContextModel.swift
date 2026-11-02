import Foundation

// Stage J.7: pinned static reconstruction of Res4 initializer #101's SJLJ
// cleanup continuation. Addresses and values are treated strictly as data.
public enum RE4StageJ7Error: Error, CustomStringConvertible {
    case malformedEvidence(String)
    case duplicateEvidence(String)
    case missingEvidence(String)
    case evidenceMismatch(String, String, String)
    case malformedCrosswalk(String)
    case crosswalkCount(Int)
    case invalidRow(Int)
    case noCleanupForZeroSelector

    public var description: String {
        switch self {
        case .malformedEvidence(let s): return "Malformed evidence row: \(s)"
        case .duplicateEvidence(let s): return "Duplicate evidence key: \(s)"
        case .missingEvidence(let s): return "Missing evidence key: \(s)"
        case .evidenceMismatch(let k, let e, let a): return "Evidence mismatch \(k): expected \(e), got \(a)"
        case .malformedCrosswalk(let s): return "Malformed J.1 crosswalk row: \(s)"
        case .crosswalkCount(let n): return "Expected 20 J.1 crosswalk rows, got \(n)"
        case .invalidRow(let n): return "Crosswalk row \(n) is outside 1...20"
        case .noCleanupForZeroSelector: return "Selector zero has no cleanup objects and does not request a cleanup context"
        }
    }
}

public struct RE4StageJ7EvidenceRow: Equatable {
    public let key: String
    public let va: String
    public let rawWord: String
    public let observedValue: String
    public let interpretation: String
}

public struct RE4StageJ7CrosswalkRow: Equatable {
    public let row: Int
    public let dispatchIndex: Int
    public let selector: UInt32
    public let actionOffset: UInt32
    public let matchedCallVAs: [UInt32]
    public let matchStatus: String
}

/// The plan is intentionally data-only. It mirrors the target's field arithmetic
/// but never writes CPU registers, performs TSD operations, or branches to a PC.
public struct RE4StageJ7CleanupContextPlan: Equatable {
    public let initializerVA: UInt32
    public let frameAddress: UInt32
    public let frameBaseOffsetFromPostPrologueSP: UInt32
    public let lsdaVA: UInt32
    public let row: Int
    public let selector: UInt32
    public let dispatchIndex: UInt32
    public let cleanupObjectCount: UInt32
    public let actionOffset: UInt32
    public let matchedCallVAs: [UInt32]
    public let matchStatus: String
    public let savedR7: UInt32
    public let savedSP: UInt32
    public let savedContinuationPC: UInt32
    public let cleanupContinuationPC: UInt32
    public let setGR0Offset: UInt32
    public let setGR0Value: UInt32
    public let setGR1Offset: UInt32
    public let setGR1Value: UInt32
    public let setIPArgument: UInt32
    public let setIPStoredSelector: UInt32
    public let contextPCOverwriteSkipped: Bool
    public let personalityReturnCode: UInt32
    public let frameRetainedAtTSDTop: Bool
    public let cleanupEntryReadsGR0: Bool
    public let resumeExceptionArgument: UInt32
    public let resumeSelectorSentinel: UInt32
    public let resumeGetIPAfterCleanup: UInt32
    public let resumeContinuesPastCurrentFrame: Bool
    public let controlTransferPerformed: Bool
}

public struct RE4StageJ7LandingPadContextModel {
    public static let initializerVA: UInt32 = 0x00005188
    public static let personalityVA: UInt32 = 0x374EF9F8
    public static let lsdaVA: UInt32 = 0x001C0996
    public static let frameBaseOffset: UInt32 = 0x18
    public static let frameLSDAOffset: UInt32 = 0x1C
    public static let frameGR0Offset: UInt32 = 0x08
    public static let frameGR1Offset: UInt32 = 0x0C
    public static let frameSelectorOffset: UInt32 = 0x04
    public static let frameSavedR7Offset: UInt32 = 0x20
    public static let frameSavedPCOffset: UInt32 = 0x24
    public static let frameSavedSPOffset: UInt32 = 0x28
    public static let cleanupContinuationPC: UInt32 = 0x000055A8
    public static let personalityInstallContextCode: UInt32 = 7
    public static let resumeSelectorSentinel: UInt32 = UInt32.max

    public let evidence: [String: RE4StageJ7EvidenceRow]
    public let crosswalk: [RE4StageJ7CrosswalkRow]

    public init(evidenceURL: URL, crosswalkURL: URL) throws {
        let rows = try Self.readEvidence(evidenceURL)
        var byKey: [String: RE4StageJ7EvidenceRow] = [:]
        for row in rows {
            guard byKey[row.key] == nil else { throw RE4StageJ7Error.duplicateEvidence(row.key) }
            byKey[row.key] = row
        }
        try Self.validatePinnedEvidence(byKey)
        let cw = try Self.readCrosswalk(crosswalkURL)
        guard cw.count == 20 else { throw RE4StageJ7Error.crosswalkCount(cw.count) }
        try Self.validateCrosswalk(cw)
        evidence = byKey
        crosswalk = cw
    }

    public func contextPlan(row: Int,
                            frameAddress: UInt32,
                            savedR7: UInt32,
                            savedSP: UInt32,
                            unwindExceptionPointer: UInt32) throws -> RE4StageJ7CleanupContextPlan {
        guard (1...20).contains(row), let cw = crosswalk.first(where: { $0.row == row }) else {
            throw RE4StageJ7Error.invalidRow(row)
        }
        guard cw.selector > 0 else { throw RE4StageJ7Error.noCleanupForZeroSelector }

        // Personality calls SetGR(context, 0, exception), SetGR(context, 1, 0),
        // and SetIP(context, dispatchIndex). SetIP stores dispatchIndex-1 at frame+4.
        // It does not overwrite the frame+0x24 continuation word.
        let selectorStoredBySetIP = UInt32(cw.dispatchIndex - 1)
        let getIPAfterCleanup = Self.resumeSelectorSentinel &+ 1
        return RE4StageJ7CleanupContextPlan(
            initializerVA: Self.initializerVA,
            frameAddress: frameAddress,
            frameBaseOffsetFromPostPrologueSP: Self.frameBaseOffset,
            lsdaVA: Self.lsdaVA,
            row: cw.row,
            selector: cw.selector,
            dispatchIndex: UInt32(cw.dispatchIndex),
            cleanupObjectCount: cw.selector,
            actionOffset: cw.actionOffset,
            matchedCallVAs: cw.matchedCallVAs,
            matchStatus: cw.matchStatus,
            savedR7: savedR7,
            savedSP: savedSP,
            savedContinuationPC: Self.cleanupContinuationPC,
            cleanupContinuationPC: Self.cleanupContinuationPC,
            setGR0Offset: Self.frameGR0Offset,
            setGR0Value: unwindExceptionPointer,
            setGR1Offset: Self.frameGR1Offset,
            setGR1Value: 0,
            setIPArgument: UInt32(cw.dispatchIndex),
            setIPStoredSelector: selectorStoredBySetIP,
            contextPCOverwriteSkipped: true,
            personalityReturnCode: Self.personalityInstallContextCode,
            frameRetainedAtTSDTop: true,
            cleanupEntryReadsGR0: true,
            resumeExceptionArgument: unwindExceptionPointer,
            resumeSelectorSentinel: Self.resumeSelectorSentinel,
            resumeGetIPAfterCleanup: getIPAfterCleanup,
            resumeContinuesPastCurrentFrame: getIPAfterCleanup == 0,
            controlTransferPerformed: false)
    }

    public func rowsWithCleanup() -> [RE4StageJ7CrosswalkRow] {
        crosswalk.filter { $0.selector > 0 }
    }

    private static func parseCSVRow(_ line: String) -> [String]? {
        let chars = Array(line)
        var cells: [String] = []
        var field = ""
        var quoted = false
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if quoted {
                if ch == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 1
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(ch)
                }
            } else if ch == "," {
                cells.append(field)
                field = ""
            } else if ch == "\"" && field.isEmpty {
                quoted = true
            } else {
                field.append(ch)
            }
            i += 1
        }
        guard !quoted else { return nil }
        cells.append(field)
        return cells
    }

    private static func readEvidence(_ url: URL) throws -> [RE4StageJ7EvidenceRow] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.first == "Evidence_ID,VA,Raw_Word,Observed_Value,Interpretation" else {
            throw RE4StageJ7Error.malformedEvidence("header")
        }
        return try lines.dropFirst().map { line in
            guard let c = parseCSVRow(line), c.count == 5 else {
                throw RE4StageJ7Error.malformedEvidence(line)
            }
            return RE4StageJ7EvidenceRow(key: c[0], va: c[1], rawWord: c[2],
                                         observedValue: c[3], interpretation: c[4])
        }
    }

    private static func readCrosswalk(_ url: URL) throws -> [RE4StageJ7CrosswalkRow] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.first == "LSDA_Table_Row,LandingPad_Dispatch_Index,Action,Matched_Call_VAs,Match_Status" else {
            throw RE4StageJ7Error.malformedCrosswalk("header")
        }
        return try lines.dropFirst().map { line in
            guard let c = parseCSVRow(line), c.count == 5,
                  let row = Int(c[0]), let dispatch = Int(c[1]),
                  let action = UInt32(c[2]) else { throw RE4StageJ7Error.malformedCrosswalk(line) }
            let calls = try c[3].isEmpty ? [] : c[3].split(separator: ";").map { token -> UInt32 in
                let s = token.trimmingCharacters(in: .whitespaces)
                guard s.hasPrefix("0x"), let value = UInt32(s.dropFirst(2), radix: 16) else {
                    throw RE4StageJ7Error.malformedCrosswalk(line)
                }
                return value
            }
            return RE4StageJ7CrosswalkRow(row: row, dispatchIndex: dispatch,
                                          selector: UInt32(row - 1), actionOffset: action,
                                          matchedCallVAs: calls, matchStatus: c[4])
        }
    }

    private static func validatePinnedEvidence(_ rows: [String: RE4StageJ7EvidenceRow]) throws {
        let expected: [String: (String, String)] = [
            "RES4_STACK_FRAME_ALLOCATION": ("0x00005198", "0x00000060"),
            "RES4_FRAME_BASE": ("0x000051A4", "0x00000018"),
            "RES4_LSDA_ADD": ("0x000051BC", "0x001C0996"),
            "RES4_LSDA_STORE": ("0x000051C0", "0x0000001C"),
            "RES4_SAVED_R7_STORE": ("0x000051B8", "0x00000020"),
            "RES4_SAVED_SP_STORE": ("0x000051C8", "0x00000028"),
            "RES4_PC_ADD": ("0x000051CC", "0x000055A8"),
            "RES4_SAVED_PC_STORE": ("0x000051D0", "0x00000024"),
            "PERSONALITY_ZERO_ACTION_BRANCH": ("0x374EFDF0", "0x374EFE20"),
            "PERSONALITY_PC_OVERWRITE_BLOCK": ("0x374EFE1C", "SKIPPED"),
            "PERSONALITY_SETGR0": ("0x374EFE34", "0x374F2B0C"),
            "PERSONALITY_SETIP": ("0x374EFE50", "0x374F2B1C"),
            "PERSONALITY_INSTALL_CONTEXT": ("0x374EFE54", "0x00000007"),
            "PHASE2_TSD_CURRENT_FRAME": ("0x358CF9C4", "R1=R4"),
            "PHASE2_PTHREAD_SET_SPECIFIC": ("0x358CF9CC", "0x358CFD5C"),
            "SETGR_IMPLEMENTATION": ("0x358CF6C0", "0x00000008"),
            "SETIP_IMPLEMENTATION": ("0x358CF6F0", "0x00000004"),
            "PHASE2_RESTORE_R7": ("0x358CF9D0", "0x00000020"),
            "PHASE2_RESTORE_SP": ("0x358CF9D4", "0x00000028"),
            "PHASE2_RESTORE_PC": ("0x358CF9D8", "0x00000024"),
            "PHASE2_BRANCH_PC": ("0x358CF9DC", "BX R0"),
            "RES4_CLEANUP_ENTRY": ("0x000055A8", "0x00000008"),
            "RES4_SAVE_EXCEPTION_PTR": ("0x000055AC", "0x00000010"),
            "RES4_RESUME_SET_SENTINEL": ("0x0000560C", "0x00000004"),
            "RES4_RESUME_CALL": ("0x00005610", "0x0019FCF4"),
            "RES4_NORMAL_UNREGISTER": ("0x00005618", "0x0019FD00")
        ]
        for (key, (va, value)) in expected {
            guard let actual = rows[key] else { throw RE4StageJ7Error.missingEvidence(key) }
            if actual.va != va { throw RE4StageJ7Error.evidenceMismatch(key + ".VA", va, actual.va) }
            if actual.observedValue != value {
                throw RE4StageJ7Error.evidenceMismatch(key + ".Value", value, actual.observedValue)
            }
        }
        let lsdaLiteral = rows["RES4_LSDA_LITERAL_LOAD"]?.observedValue
        let pcLiteral = rows["RES4_PC_LITERAL_LOAD"]?.observedValue
        guard lsdaLiteral == "0x001BB7D2" else {
            throw RE4StageJ7Error.evidenceMismatch("LSDA literal", "0x001BB7D2", lsdaLiteral ?? "missing")
        }
        guard pcLiteral == "0x000003D4" else {
            throw RE4StageJ7Error.evidenceMismatch("PC literal", "0x000003D4", pcLiteral ?? "missing")
        }
    }

    private static func validateCrosswalk(_ rows: [RE4StageJ7CrosswalkRow]) throws {
        for (i, row) in rows.enumerated() {
            guard row.row == i + 1, row.dispatchIndex == i + 1,
                  row.selector == UInt32(i), row.actionOffset == 0 else {
                throw RE4StageJ7Error.malformedCrosswalk("noncanonical row \(i + 1)")
            }
        }
        guard rows[0].matchedCallVAs.isEmpty,
              rows[1].matchedCallVAs == [0x555C, 0x5588],
              rows.filter({ !$0.matchedCallVAs.isEmpty }).count == 19,
              rows.reduce(0, { $0 + $1.matchedCallVAs.count }) == 20 else {
            throw RE4StageJ7Error.malformedCrosswalk("J.1 match totals or first two rows disagree")
        }
    }
}
