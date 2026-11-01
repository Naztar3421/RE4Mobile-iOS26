import Foundation

public struct RE4MachO32InitializerAuditRecord {
    public let index: Int
    public let slotAddress: UInt32
    public let rawPointer: UInt32
    public let targetAddress: UInt32
    public let pointerState: RE4ARMv6InstructionSet
    public let targetInTextRX: Bool
    public let initializerLabel: String
    public let directCallTargets: [UInt32]
    public let importedCallees: [String]
    public let localCalleeTargets: [UInt32]
    public let instructionWordsInspected: Int
    public let maximumCallDepth: Int
    public let returnBoundary: String
    public let scanLimitReached: Bool
    public let pointerPreserved: Bool
}

public struct RE4MachO32InitializerAuditResult {
    public let report: String
    public let auditCSV: String
    public let records: [RE4MachO32InitializerAuditRecord]
}

/// Read-only parser for S_MOD_INIT_FUNC_POINTERS and its bounded ARM direct-call evidence.
/// It never invokes an initializer, follows a provider pointer into execution, or writes Guest Memory.
public enum RE4MachO32InitializerAudit {
    private static let initializerSectionType: UInt32 = 9 // S_MOD_INIT_FUNC_POINTERS

    private struct ScanAggregate {
        var directCalls = Set<UInt32>()
        var importedSymbols = Set<String>()
        var localCallees = Set<UInt32>()
        var unresolvedTransfers = Set<String>()
        var instructions = 0
        var maximumDepth = 0
        var returnBoundary = "NOT_REACHED"
        var limitReached = false
    }

    private enum AuditError: Error, LocalizedError {
        case initializerSectionMissing
        case ambiguousInitializerSections(Int)
        case malformedInitializerSection(String)
        case initializerCountOutOfRange(UInt64)
        case memoryReadFailed(UInt32)
        case syntheticSelfTestFailed(String)

        var errorDescription: String? {
            switch self {
            case .initializerSectionMissing:
                return "Mach-O has no __DATA,__mod_init_func section of type S_MOD_INIT_FUNC_POINTERS."
            case .ambiguousInitializerSections(let count):
                return "Mach-O contains \(count) initializer sections; the audit requires one unambiguous array."
            case .malformedInitializerSection(let reason):
                return "Malformed __mod_init_func section: \(reason)."
            case .initializerCountOutOfRange(let count):
                return "Initializer array count \(count) is outside the static audit limit."
            case .memoryReadFailed(let address):
                return String(format: "Could not read initializer data at 0x%08X.", address)
            case .syntheticSelfTestFailed(let detail):
                return "Synthetic initializer audit failed: \(detail)."
            }
        }
    }

    private static func readWord(_ address: UInt32,
                                 memory: RE4GuestMemoryReading) throws -> UInt32 {
        let data: Data
        do {
            data = try memory.copyBytes(at: address, count: 4)
        } catch {
            throw AuditError.memoryReadFailed(address)
        }
        guard data.count == 4 else { throw AuditError.memoryReadFailed(address) }
        let b = [UInt8](data)
        return UInt32(b[0]) | (UInt32(b[1]) << 8) |
            (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
    }

    private static func isTextRX(_ address: UInt32,
                                 image: RE4MachO32Image) -> Bool {
        image.segments.contains {
            $0.name == "__TEXT" && !$0.isPageZero &&
            ($0.initialProtection & 4) != 0 &&
            UInt64(address) >= UInt64($0.vmAddress) &&
            UInt64(address) < UInt64($0.vmAddress) + UInt64($0.vmSize)
        }
    }

    private static func containsExecutableWord(_ address: UInt32,
                                               image: RE4MachO32Image) -> Bool {
        image.segments.contains {
            !$0.isPageZero && ($0.initialProtection & 4) != 0 &&
            UInt64(address) >= UInt64($0.vmAddress) &&
            UInt64(address) + 4 <= UInt64($0.vmAddress) + UInt64($0.vmSize)
        }
    }

    private static func exactLabels(at address: UInt32,
                                    image: RE4MachO32Image) -> [String] {
        Array(Set(image.symbols.filter {
            !$0.isUndefined && !$0.name.isEmpty && $0.value == address
        }.map(\.name))).sorted()
    }

    private static func branchTarget(_ word: UInt32, pc: UInt32) -> UInt32? {
        var displacement = Int32(word & 0x00FF_FFFF)
        if (displacement & 0x0080_0000) != 0 {
            displacement |= Int32(bitPattern: 0xFF00_0000)
        }
        let target = Int64(pc) + 8 + (Int64(displacement) << 2)
        guard target >= 0 && target <= Int64(UInt32.max) else { return nil }
        return UInt32(target)
    }

    private static func scanFunction(
        at startAddress: UInt32,
        image: RE4MachO32Image,
        memory: RE4GuestMemoryReading,
        stubSymbolByAddress: [UInt32: String],
        maxInstructionsPerFunction: Int,
        maxCallDepth: Int,
        depth: Int,
        visited: inout Set<UInt32>,
        remainingBudget: inout Int,
        aggregate: inout ScanAggregate
    ) throws {
        guard depth <= maxCallDepth,
              containsExecutableWord(startAddress, image: image),
              visited.insert(startAddress).inserted else { return }
        aggregate.maximumDepth = max(aggregate.maximumDepth, depth)

        var pc = startAddress
        for _ in 0..<maxInstructionsPerFunction {
            guard remainingBudget > 0 else {
                aggregate.limitReached = true
                aggregate.returnBoundary = "TOTAL_INSTRUCTION_BUDGET"
                return
            }
            guard containsExecutableWord(pc, image: image) else {
                if aggregate.returnBoundary == "NOT_REACHED" {
                    aggregate.returnBoundary = "EXECUTABLE_SEGMENT_BOUNDARY"
                }
                return
            }

            let word = try readWord(pc, memory: memory)
            remainingBudget -= 1
            aggregate.instructions += 1

            // BX LR is a return. Other BX forms are indirect control transfers and are not followed.
            let registerBranch = word & 0x0FFF_FFF0
            if registerBranch == 0x012F_FF10 {
                if (word & 0xF) == 14 {
                    if aggregate.returnBoundary == "NOT_REACHED" { aggregate.returnBoundary = "BX_LR" }
                } else {
                    aggregate.unresolvedTransfers.insert(String(format: "BX r%u at 0x%08X", word & 0xF, pc))
                    if aggregate.returnBoundary == "NOT_REACHED" { aggregate.returnBoundary = "INDIRECT_BX" }
                }
                return
            }
            if registerBranch == 0x012F_FF30 {
                aggregate.unresolvedTransfers.insert(String(format: "BLX register r%u at 0x%08X", word & 0xF, pc))
                pc = pc &+ 4
                continue
            }

            // ARM B/BL immediate. BL records a possible call edge; direct local callees are scanned
            // recursively, while an exact symbol-stub match is recorded as an imported dependency.
            if ((word >> 25) & 7) == 5 {
                guard let target = branchTarget(word, pc: pc) else {
                    aggregate.unresolvedTransfers.insert(String(format: "ARM branch target overflow at 0x%08X", pc))
                    return
                }
                let condition = (word >> 28) & 0xF
                let links = (word & (1 << 24)) != 0
                if links {
                    aggregate.directCalls.insert(target)
                    if let imported = stubSymbolByAddress[target] {
                        aggregate.importedSymbols.insert(imported)
                    } else if containsExecutableWord(target, image: image) {
                        aggregate.localCallees.insert(target)
                        if depth < maxCallDepth {
                            try scanFunction(
                                at: target, image: image, memory: memory,
                                stubSymbolByAddress: stubSymbolByAddress,
                                maxInstructionsPerFunction: maxInstructionsPerFunction,
                                maxCallDepth: maxCallDepth, depth: depth + 1,
                                visited: &visited, remainingBudget: &remainingBudget,
                                aggregate: &aggregate
                            )
                        } else {
                            aggregate.limitReached = true
                            aggregate.unresolvedTransfers.insert(
                                String(format: "call-depth limit at 0x%08X -> 0x%08X", pc, target)
                            )
                        }
                    } else {
                        aggregate.unresolvedTransfers.insert(
                            String(format: "external direct call 0x%08X -> 0x%08X", pc, target)
                        )
                    }
                    if condition != 0xE {
                        aggregate.unresolvedTransfers.insert(
                            String(format: "conditional BL%X at 0x%08X", condition, pc)
                        )
                    }
                    pc = pc &+ 4
                    continue
                }

                // Conditional B has both taken and fall-through paths. This bounded linear parser
                // records the un-followed edge and continues only along fall-through.
                if condition != 0xE {
                    aggregate.unresolvedTransfers.insert(
                        String(format: "conditional B%X at 0x%08X -> 0x%08X (not followed)", condition, pc, target)
                    )
                    pc = pc &+ 4
                    continue
                }
                if aggregate.returnBoundary == "NOT_REACHED" { aggregate.returnBoundary = "UNCONDITIONAL_B" }
                return
            }

            // LDM with PC in the register list transfers through stack data; stack contents are unknown.
            if ((word >> 25) & 7) == 4,
               word & (1 << 20) != 0,
               word & (1 << 15) != 0 {
                if aggregate.returnBoundary == "NOT_REACHED" { aggregate.returnBoundary = "LDM_PC_TRANSFER" }
                return
            }

            // An unconditional word LDR into PC is an indirect transfer. Do not follow provider code.
            if (word >> 28) == 0xE,
               ((word >> 26) & 3) == 1,
               word & (1 << 20) != 0,
               word & (1 << 22) == 0,
               ((word >> 12) & 0xF) == 15 {
                aggregate.unresolvedTransfers.insert(String(format: "LDR pc indirect transfer at 0x%08X", pc))
                if aggregate.returnBoundary == "NOT_REACHED" { aggregate.returnBoundary = "INDIRECT_LDR_PC" }
                return
            }

            // MOV pc, lr is a common return sequence.
            if (word >> 28) == 0xE,
               ((word >> 26) & 3) == 0,
               ((word >> 21) & 0xF) == 13,
               ((word >> 12) & 0xF) == 15,
               (word & 0xF) == 14 {
                if aggregate.returnBoundary == "NOT_REACHED" { aggregate.returnBoundary = "MOV_PC_LR" }
                return
            }

            pc = pc &+ 4
        }

        if aggregate.returnBoundary == "NOT_REACHED" {
            aggregate.returnBoundary = "FUNCTION_INSTRUCTION_LIMIT"
        }
        aggregate.limitReached = true
    }

    private static func csv(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    public static func inspect(
        image: RE4MachO32Image,
        memory: RE4GuestMemoryReading,
        maxInstructionsPerFunction: Int = 48,
        maxCallDepth: Int = 3,
        totalInstructionBudgetPerInitializer: Int = 192
    ) throws -> RE4MachO32InitializerAuditResult {
        let matches = image.segments.flatMap { segment in
            segment.sections.filter {
                $0.name == "__mod_init_func" &&
                $0.segmentName == segment.name &&
                $0.type == initializerSectionType
            }.map { (segment, $0) }
        }
        guard !matches.isEmpty else { throw AuditError.initializerSectionMissing }
        guard matches.count == 1 else {
            throw AuditError.ambiguousInitializerSections(matches.count)
        }

        let (owner, section) = matches[0]
        guard owner.name == "__DATA",
              section.address & 3 == 0,
              section.size > 0,
              section.size & 3 == 0,
              UInt64(section.address) >= UInt64(owner.vmAddress),
              UInt64(section.address) + UInt64(section.size) <= UInt64(owner.vmAddress) + UInt64(owner.vmSize),
              UInt64(section.fileOffset) + UInt64(section.size) <= UInt64(image.fileBytes.count) else {
            throw AuditError.malformedInitializerSection(
                "expected aligned, file-backed __DATA section with a size divisible by four"
            )
        }

        let count64 = UInt64(section.size) / 4
        guard count64 > 0 && count64 <= 4096 else {
            throw AuditError.initializerCountOutOfRange(count64)
        }
        let count = Int(count64)
        let stubSymbolByAddress = Dictionary(
            image.indirectImports.filter(\.isStub).map { ($0.slotAddress, $0.symbolName) },
            uniquingKeysWith: { first, _ in first }
        )

        var records: [RE4MachO32InitializerAuditRecord] = []
        records.reserveCapacity(count)
        var armCount = 0
        var thumbCount = 0
        var executableCount = 0
        var preservedCount = 0
        var aggregateImportCounts: [String: Int] = [:]
        var aggregateLocalCallCount = 0
        var scansWithLimit = 0

        for index in 0..<count {
            let slot64 = UInt64(section.address) + UInt64(index) * 4
            guard slot64 <= UInt64(UInt32.max) else {
                throw AuditError.malformedInitializerSection("slot address overflow")
            }
            let slot = UInt32(slot64)
            let rawPointer = try readWord(slot, memory: memory)
            let stateResult = RE4ARMv6InstructionSetState.resolveBX(
                from: .arm, registerTarget: rawPointer
            )
            let target = stateResult.targetAddress
            let state = stateResult.targetState
            if state == .arm { armCount += 1 } else { thumbCount += 1 }
            let textRX = isTextRX(target, image: image)
            if textRX { executableCount += 1 }

            let fileOffset = Int(section.fileOffset) + index * 4
            let originalPointer: UInt32
            if fileOffset + 4 <= image.fileBytes.count {
                let b = [UInt8](image.fileBytes[fileOffset..<(fileOffset + 4)])
                originalPointer = UInt32(b[0]) | (UInt32(b[1]) << 8) |
                    (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
            } else {
                originalPointer = ~rawPointer
            }
            let pointerPreserved = rawPointer == originalPointer
            if pointerPreserved { preservedCount += 1 }

            let labels = exactLabels(at: target, image: image)
            var aggregate = ScanAggregate()
            if state == .arm && textRX && containsExecutableWord(target, image: image) {
                var visited = Set<UInt32>()
                var budget = max(1, min(totalInstructionBudgetPerInitializer, 2048))
                try scanFunction(
                    at: target, image: image, memory: memory,
                    stubSymbolByAddress: stubSymbolByAddress,
                    maxInstructionsPerFunction: max(1, min(maxInstructionsPerFunction, 128)),
                    maxCallDepth: max(0, min(maxCallDepth, 8)),
                    depth: 0, visited: &visited,
                    remainingBudget: &budget, aggregate: &aggregate
                )
            } else if state == .thumb {
                aggregate.returnBoundary = "THUMB_DECODER_NOT_IMPLEMENTED"
                aggregate.unresolvedTransfers.insert("Thumb initializer identified; body not decoded")
            } else if !textRX {
                aggregate.returnBoundary = "TARGET_NOT_IN_TEXT_RX"
                aggregate.unresolvedTransfers.insert("initializer target is not inside __TEXT RX")
            }

            for name in aggregate.importedSymbols {
                aggregateImportCounts[name, default: 0] += 1
            }
            aggregateLocalCallCount += aggregate.localCallees.count
            if aggregate.limitReached { scansWithLimit += 1 }

            records.append(RE4MachO32InitializerAuditRecord(
                index: index + 1, slotAddress: slot, rawPointer: rawPointer,
                targetAddress: target, pointerState: state, targetInTextRX: textRX,
                initializerLabel: labels.joined(separator: ";"),
                directCallTargets: aggregate.directCalls.sorted(),
                importedCallees: aggregate.importedSymbols.sorted(),
                localCalleeTargets: aggregate.localCallees.sorted(),
                instructionWordsInspected: aggregate.instructions,
                maximumCallDepth: aggregate.maximumDepth,
                returnBoundary: aggregate.returnBoundary,
                scanLimitReached: aggregate.limitReached,
                pointerPreserved: pointerPreserved
            ))
        }

        let header = [
            "Index", "Initializer_Slot_VA", "Raw_Pointer_Value", "Target_VA",
            "Pointer_State", "Target_In_TEXT_RX", "Initializer_Label",
            "Direct_Call_Targets", "Imported_Callees", "Local_Callee_Targets",
            "Instruction_Words_Inspected", "Maximum_Call_Depth", "Return_Boundary",
            "Static_Analysis_Limit", "Pointer_Preserved", "Execution_Performed"
        ]
        var csvLines = [header.joined(separator: ",")]
        for r in records {
            csvLines.append([
                String(r.index),
                String(format: "0x%08X", r.slotAddress),
                String(format: "0x%08X", r.rawPointer),
                String(format: "0x%08X", r.targetAddress),
                r.pointerState.rawValue,
                r.targetInTextRX ? "YES" : "NO",
                csv(r.initializerLabel),
                csv(r.directCallTargets.map { String(format: "0x%08X", $0) }.joined(separator: ";")),
                csv(r.importedCallees.joined(separator: ";")),
                csv(r.localCalleeTargets.map { String(format: "0x%08X", $0) }.joined(separator: ";")),
                String(r.instructionWordsInspected),
                String(r.maximumCallDepth),
                r.returnBoundary,
                r.scanLimitReached ? "YES" : "NO",
                r.pointerPreserved ? "YES" : "NO",
                "NO"
            ].joined(separator: ","))
        }

        let uniqueTargets = Set(records.map(\.targetAddress)).count
        let importedNames = Set(records.flatMap(\.importedCallees)).sorted()
        var lines = [
            "Mach-O initializer dependency audit PASS (read-only)",
            "Initializer section: __DATA,__mod_init_func (S_MOD_INIT_FUNC_POINTERS)",
            String(format: "Section VA: 0x%08X; size: 0x%X", section.address, section.size),
            "Initializer entries in original section order: \(records.count)",
            "Unique target addresses: \(uniqueTargets)",
            "ARM-state entries: \(armCount); Thumb-state entries: \(thumbCount)",
            "Targets inside __TEXT RX: \(executableCount)/\(records.count)",
            "Pointer values preserved against original thin-slice bytes: \(preservedCount)/\(records.count)",
            "Initializer labels found: \(records.filter { !$0.initializerLabel.isEmpty }.count)",
            "Distinct imported callees statically reached through symbol stubs: \(importedNames.count)",
            "Local direct-call targets recorded: \(aggregateLocalCallCount)",
            "Initializer scans hitting a static-analysis bound: \(scansWithLimit)",
            "Guest instructions executed: NO",
            "Initializer / constructor / dyld helper invoked: NO",
            "",
            "[Imported callees observed]"
        ]
        if importedNames.isEmpty { lines.append("(none observed in bounded direct-call scans)") }
        else { lines += importedNames }
        lines += [
            "",
            "[Interpretation limits]",
            "The parser follows bounded direct ARM BL call edges and exact symbol-stub addresses only.",
            "It does not infer indirect calls, complete conditional control flow, function extents, data-dependent calls, or provider implementation readiness.",
            "Thumb initializer bodies are identified but not decoded because a Thumb instruction decoder is not part of this audit.",
            "A missing dependency in this report is not proof that the initializer has no such dependency.",
            "",
            "Read-only guarantee: only Guest Memory copyBytes reads were used; no write API or CPU execution path was called."
        ]

        return RE4MachO32InitializerAuditResult(
            report: lines.joined(separator: "\n"),
            auditCSV: csvLines.joined(separator: "\n") + "\n",
            records: records
        )
    }

    private static func put32(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt32) {
        bytes[offset] = UInt8(value & 0xFF)
        bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    private static func putFixed(_ bytes: inout [UInt8], _ offset: Int,
                                 _ value: String, length: Int) {
        let encoded = Array(value.utf8.prefix(length))
        for i in 0..<length {
            bytes[offset + i] = i < encoded.count ? encoded[i] : 0
        }
    }

    /// Generated Mach-O fixture only. It contains one initializer pointer and a local BL edge.
    public static func runSyntheticSelfTest() throws -> String {
        var bytes = [UInt8](try RE4MachO32Parser.makeSyntheticSelfTestFixture())
        let textSectionOffset = 28 + 56
        let dataSectionOffset = 28 + 124 + 56

        // Give the synthetic __text section enough room for two tiny generated routines.
        put32(&bytes, textSectionOffset + 36, 16)
        // Convert the fixture's data pointer section into a one-entry initializer array.
        putFixed(&bytes, dataSectionOffset, "__mod_init_func", length: 16)
        put32(&bytes, dataSectionOffset + 56, initializerSectionType)
        put32(&bytes, 0x280, 0x00001270)

        // Entry: BL 0x1278; BX LR. Local callee: MOV r0,#1; BX LR.
        put32(&bytes, 0x270, 0xEB000000)
        put32(&bytes, 0x274, 0xE12FFF1E)
        put32(&bytes, 0x278, 0xE3A00001)
        put32(&bytes, 0x27C, 0xE12FFF1E)

        let image = try RE4MachO32Parser.parse(Data(bytes))
        let memory = RE4GuestARMv6Memory(
            size: 0x6000, heapBase: 0x5000, stackTop: 0x5800, returnSentinel: 0x5F00
        )
        _ = try RE4MachO32Loader.map(image, into: memory)
        let beforeSlot = try memory.copyBytes(at: 0x3000, count: 4)
        let beforeCode = try memory.copyBytes(at: 0x1270, count: 16)

        let result = try inspect(image: image, memory: memory)
        let afterSlot = try memory.copyBytes(at: 0x3000, count: 4)
        let afterCode = try memory.copyBytes(at: 0x1270, count: 16)
        guard result.records.count == 1,
              result.records[0].targetAddress == 0x1270,
              result.records[0].pointerState == .arm,
              result.records[0].targetInTextRX,
              result.records[0].directCallTargets == [0x1278],
              result.records[0].localCalleeTargets == [0x1278],
              result.records[0].instructionWordsInspected == 4,
              result.records[0].pointerPreserved,
              beforeSlot == afterSlot,
              beforeCode == afterCode,
              result.report.contains("Guest instructions executed: NO") else {
            throw AuditError.syntheticSelfTestFailed("ordered pointer, direct call graph, or read-only invariant")
        }

        // A Thumb-tagged synthetic pointer must be recognized, but its body must remain unscanned.
        try memory.write32(0x3000, 0x00001271)
        let thumbResult = try inspect(image: image, memory: memory)
        guard thumbResult.records.count == 1,
              thumbResult.records[0].pointerState == .thumb,
              thumbResult.records[0].targetAddress == 0x1270,
              thumbResult.records[0].instructionWordsInspected == 0,
              thumbResult.records[0].returnBoundary == "THUMB_DECODER_NOT_IMPLEMENTED" else {
            throw AuditError.syntheticSelfTestFailed("Thumb initializer detection / no ARM misdecode")
        }

        return "Mach-O initializer dependency audit synthetic self-test PASS\n" +
            "S_MOD_INIT_FUNC_POINTERS order / ARM target / executable mapping: PASS\n" +
            "Direct BL edge and bounded local-callee scan: PASS\n" +
            "Memory read-only invariant: PASS\n" +
            "Thumb-tagged initializer identified without ARM decoding: PASS\n" +
            "Generated fixture only; no game code, initializer, or constructor executed."
    }
}
