import Foundation

public enum RE4ARMv6InstructionClass: String {
    case branchExchange = "BX/BLX register"
    case branch = "B/BL relative"
    case blockTransfer = "LDM/STM block transfer"
    case singleTransfer = "LDR/STR single transfer"
    case extraTransfer = "LDRH/STRH/LDRSB/LDRSH family"
    case dataProcessing = "data-processing / miscellaneous"
    case softwareInterrupt = "SVC/software interrupt"
    case coprocessor = "coprocessor/VFP family"
    case unclassified = "unclassified instruction"
}

public struct RE4ARMv6InstructionRecord {
    public let address: UInt32
    public let word: UInt32
    public let condition: String
    public let instructionClass: RE4ARMv6InstructionClass
    public let corePath: String
    public let branchTarget: UInt32?
}

public enum RE4ARMv6EntryPreflight {
    private static let conditions = [
        "EQ", "NE", "CS", "CC", "MI", "PL", "VS", "VC",
        "HI", "LS", "GE", "LT", "GT", "LE", "AL", "NV"
    ]

    public static func classify(_ word: UInt32, at pc: UInt32) -> RE4ARMv6InstructionRecord {
        let condition = conditions[Int((word >> 28) & 0xF)]
        let branchTarget: UInt32?
        let kind: RE4ARMv6InstructionClass
        let corePath: String

        let registerBranch = word & 0x0FFFFFF0
        if registerBranch == 0x012FFF10 || registerBranch == 0x012FFF30 {
            kind = .branchExchange
            corePath = "CPU handler exists"
            branchTarget = nil
        } else if (word & 0x0F000000) == 0x0F000000 {
            kind = .softwareInterrupt
            corePath = "requires SVC/HLE implementation"
            branchTarget = nil
        } else if ((word >> 25) & 7) == 5 {
            var displacement = Int32(word & 0x00FFFFFF)
            if (displacement & 0x00800000) != 0 {
                displacement |= Int32(bitPattern: 0xFF000000)
            }
            let target64 = Int64(pc) + 8 + (Int64(displacement) << 2)
            branchTarget = UInt32(truncatingIfNeeded: target64)
            kind = .branch
            corePath = "CPU handler exists"
        } else if ((word >> 25) & 7) == 4 {
            kind = .blockTransfer
            corePath = "CPU handler exists; address-mode correctness still needs trace tests"
            branchTarget = nil
        } else if ((word >> 26) & 3) == 1 {
            kind = .singleTransfer
            corePath = "CPU handler exists; addressing modes need instruction-level validation"
            branchTarget = nil
        } else if ((word >> 25) & 7) == 0 &&
                  ((word >> 7) & 1) != 0 &&
                  ((word >> 4) & 1) != 0 &&
                  ((word >> 5) & 3) != 0 {
            kind = .extraTransfer
            corePath = "CPU handler exists"
            branchTarget = nil
        } else if ((word >> 26) & 3) == 0 {
            kind = .dataProcessing
            corePath = "generic path exists; instruction encoding requires audit"
            branchTarget = nil
        } else if ((word >> 25) & 7) == 6 || ((word >> 25) & 7) == 7 {
            kind = .coprocessor
            corePath = "NOT safe to execute: generic coprocessor path is not emulated"
            branchTarget = nil
        } else {
            kind = .unclassified
            corePath = "not verified by current interpreter"
            branchTarget = nil
        }

        return RE4ARMv6InstructionRecord(
            address: pc, word: word, condition: condition,
            instructionClass: kind, corePath: corePath, branchTarget: branchTarget
        )
    }

    public static func inspect(entryPoint: UInt32,
                               image: RE4MachO32Image,
                               memory: RE4GuestMemoryReading,
                               instructionCount: Int = 24) throws -> String {
        let count = max(1, min(instructionCount, 64))
        guard let segment = image.segments.first(where: {
            UInt64(entryPoint) >= UInt64($0.vmAddress) &&
            UInt64(entryPoint) + 4 <= UInt64($0.vmAddress) + UInt64($0.vmSize)
        }), !segment.isPageZero, (segment.initialProtection & 4) != 0 else {
            throw RE4ARMv6EntryPreflightError.entryNotInExecutableSegment(entryPoint)
        }
        var records: [RE4ARMv6InstructionRecord] = []
        records.reserveCapacity(count)
        for index in 0..<count {
            let address64 = UInt64(entryPoint) + UInt64(index) * 4
            guard address64 + 4 <= UInt64(UInt32.max) + 1 else {
                throw RE4ARMv6EntryPreflightError.addressOverflow
            }
            let address = UInt32(address64)
            let inExecutableSegment = image.segments.contains {
                !$0.isPageZero && ($0.initialProtection & 4) != 0 &&
                UInt64(address) >= UInt64($0.vmAddress) &&
                UInt64(address) + 4 <= UInt64($0.vmAddress) + UInt64($0.vmSize)
            }
            guard inExecutableSegment else { break }
            let data = try memory.copyBytes(at: address, count: 4)
            guard data.count == 4 else { throw RE4ARMv6EntryPreflightError.shortRead(address) }
            let b = [UInt8](data)
            let word = UInt32(b[0]) | (UInt32(b[1]) << 8) |
                (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
            records.append(classify(word, at: address))
        }

        var lines = [
            "ARMv6 entry-point static preflight PASS",
            String(format: "Entry PC: 0x%08X", entryPoint),
            "Instructions inspected: \(records.count)",
            "Execution performed: NO",
            "",
            "[Instruction words]"
        ]
        for r in records {
            let target = r.branchTarget.map { String(format: " target=0x%08X", $0) } ?? ""
            lines.append(String(format: "0x%08X  0x%08X  %@  %@%@",
                                r.address, r.word, r.condition, r.instructionClass.rawValue, target))
            lines.append("    Core path: \(r.corePath)")
        }
        let unsafe = records.filter {
            $0.instructionClass == .coprocessor ||
            $0.instructionClass == .softwareInterrupt ||
            $0.instructionClass == .unclassified
        }.count
        lines += [
            "",
            "Instructions needing review: \(unsafe) of \(records.count)",
            "This is static inspection only; no entry point, HLE import, or initializer was executed."
        ]
        return lines.joined(separator: "\n")
    }

    public static func runSyntheticSelfTest() throws -> String {
        let fixture = try RE4MachO32Parser.makeSyntheticSelfTestFixture()
        let image = try RE4MachO32Parser.parse(fixture)
        let memory = RE4GuestARMv6Memory(size: 0x05000000)
        _ = try RE4MachO32Loader.map(image, into: memory)
        let report = try inspect(entryPoint: image.entryPoint!, image: image, memory: memory, instructionCount: 3)
        let first = classify(0xE3A00001, at: 0x1270)
        let second = classify(0xE2800002, at: 0x1274)
        let third = classify(0xE12FFF1E, at: 0x1278)
        guard first.instructionClass == .dataProcessing,
              second.instructionClass == .dataProcessing,
              third.instructionClass == .branchExchange,
              report.contains("0x00001270  0xE3A00001") &&
              report.contains("0x00001274  0xE2800002") &&
              report.contains("0x00001278  0xE12FFF1E") &&
              report.contains("Execution performed: NO") else {
            throw RE4ARMv6EntryPreflightError.selfTestFailed
        }
        return "ARMv6 entry-point preflight self-test PASS\nMOV/ADD/BX instruction words decoded at expected guest VAs.\nInstruction conditions and classes reported.\nStatic only: CPU state and guest memory were not executed."
    }
}

public enum RE4ARMv6EntryPreflightError: Error, LocalizedError {
    case entryNotInExecutableSegment(UInt32)
    case shortRead(UInt32)
    case addressOverflow
    case selfTestFailed

    public var errorDescription: String? {
        switch self {
        case .entryNotInExecutableSegment(let pc):
            return String(format: "Entry PC 0x%08X is not inside an executable mapped segment.", pc)
        case .shortRead(let pc):
            return String(format: "Could not read a complete instruction at 0x%08X.", pc)
        case .addressOverflow: return "Instruction inspection address overflow."
        case .selfTestFailed: return "Synthetic ARMv6 entry preflight self-test failed."
        }
    }
}
