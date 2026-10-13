import Foundation

public enum RE4MachO32Error: Error, LocalizedError {
    case truncatedFile
    case unsupportedMagic(UInt32)
    case invalidFatHeader
    case noArm32Slice
    case invalidFatSlice
    case wrongCPU(UInt32)
    case malformedHeader
    case malformedLoadCommand(index: Int)
    case malformedSegment(String)
    case malformedSymbolTable
    case malformedDylibCommand
    case malformedBindStream(String)
    case noSegments
    case segmentOutOfBounds(name: String, end: UInt64, memorySize: Int)
    case overlappingSegments(String, String)
    case syntheticSelfTestFailed(String)

    public var errorDescription: String? {
        switch self {
        case .truncatedFile: return "File is too short to be a Mach-O header."
        case .unsupportedMagic(let value): return String(format: "Unsupported file magic 0x%08X. Select the raw Mach-O executable, not the IPA ZIP.", value)
        case .invalidFatHeader: return "Malformed universal Mach-O header."
        case .noArm32Slice: return "Universal Mach-O contains no 32-bit ARM slice."
        case .invalidFatSlice: return "Universal Mach-O slice is outside the file or truncated."
        case .wrongCPU(let cpu): return String(format: "Mach-O CPU type 0x%08X is not 32-bit ARM.", cpu)
        case .malformedHeader: return "Malformed 32-bit Mach-O header or load-command region."
        case .malformedLoadCommand(let i): return "Malformed Mach-O load command at index \(i)."
        case .malformedSegment(let name): return "Malformed Mach-O segment \(name)."
        case .malformedSymbolTable: return "Mach-O symbol or string table is outside the file."
        case .malformedDylibCommand: return "Malformed dylib load command."
        case .malformedBindStream(let why): return "Malformed dyld bind stream: \(why)"
        case .noSegments: return "Mach-O has no usable LC_SEGMENT commands."
        case .segmentOutOfBounds(let name, let end, let memorySize):
            return String(format: "Segment %@ ends at 0x%llX, outside guest memory size 0x%X.", name, end, memorySize)
        case .overlappingSegments(let a, let b): return "Guest VM segments overlap: \(a) and \(b)."
        case .syntheticSelfTestFailed(let why): return "Synthetic Mach-O parser self-test failed: \(why)"
        }
    }
}

public struct RE4MachO32Section {
    public let name: String
    public let segmentName: String
    public let address: UInt32
    public let size: UInt32
    public let fileOffset: UInt32
    public let alignment: UInt32
    public let relocationOffset: UInt32
    public let relocationCount: UInt32
    public let flags: UInt32
    public let reserved1: UInt32
    public let reserved2: UInt32
    public var type: UInt32 { flags & 0xFF }
}

public struct RE4MachO32Segment {
    public let name: String
    public let vmAddress: UInt32
    public let vmSize: UInt32
    public let fileOffset: UInt32
    public let fileSize: UInt32
    public let maxProtection: Int32
    public let initialProtection: Int32
    public let flags: UInt32
    public let sections: [RE4MachO32Section]
    public var vmEnd: UInt64 { UInt64(vmAddress) + UInt64(vmSize) }
    public var fileEnd: UInt64 { UInt64(fileOffset) + UInt64(fileSize) }
    public var isPageZero: Bool { name == "__PAGEZERO" }
}

public struct RE4MachO32Symbol {
    public let name: String
    public let type: UInt8
    public let section: UInt8
    public let description: UInt16
    public let value: UInt32
    public var isExternal: Bool { type & 0x01 != 0 }
    /// N_STAB records share some low type bits with N_UNDF; exclude them explicitly.
    public var isUndefined: Bool { (type & 0xE0) == 0 && (type & 0x0E) == 0 }
    public var isWeakReference: Bool { description & 0x0040 != 0 }
    public var isWeakDefinition: Bool { description & 0x0080 != 0 }
}

public struct RE4MachO32DylibDependency {
    public let name: String
    public let command: UInt32
    public let currentVersion: UInt32
    public let compatibilityVersion: UInt32
}

public struct RE4MachO32Relocation {
    public let sectionName: String
    public let address: Int32
    public let symbolIndex: UInt32
    public let isExternal: Bool
    public let isPCRelative: Bool
    public let length: UInt8
    public let type: UInt8
    public let scattered: Bool
    public let symbolName: String?
}

public struct RE4MachO32IndirectImport {
    public let symbolName: String
    public let sectionName: String
    public let slotAddress: UInt32
    public let isStub: Bool
    /// Mach-O section type: 6=non-lazy pointers, 7=lazy pointers, 8=symbol stubs.
    public let sectionType: UInt32
    /// Bytes per pointer slot or stub, as declared by the section.
    public let entrySize: UInt32
}

public struct RE4MachO32BindRecord {
    public let symbolName: String
    public let dylibOrdinal: Int
    public let bindType: UInt8
    public let addend: Int64
    public let segmentIndex: Int?
    public let segmentName: String?
    public let vmAddress: UInt32?
    public let stream: String
}

public struct RE4MachO32LoadSegment {
    public let name: String
    public let vmAddress: UInt32
    public let vmSize: UInt32
    public let fileOffset: UInt32
    public let fileSize: UInt32
    public let initialProtection: Int32
}

public struct RE4MachO32LoadPlan {
    public let segments: [RE4MachO32LoadSegment]
    public let requiredMemorySize: UInt64
    public let entryPoint: UInt32?
    public let unmappedPageZero: UInt64
}

/// A read-only analysis of a thin or universal little-endian 32-bit ARM Mach-O file.
/// It reports load commands, segments, symbols, imports, dyld binds and section relocations.
/// It does not apply relocations or invoke code.
public struct RE4MachO32Image {
    public let cpuType: UInt32
    public let cpuSubtype: UInt32
    public let fileType: UInt32
    public let flags: UInt32
    public let commandCount: UInt32
    public let wasUniversal: Bool
    public let selectedSliceOffset: UInt64
    public let segments: [RE4MachO32Segment]
    public let dependencies: [RE4MachO32DylibDependency]
    public let symbols: [RE4MachO32Symbol]
    public let bindRecords: [RE4MachO32BindRecord]
    public let indirectImports: [RE4MachO32IndirectImport]
    public let relocations: [RE4MachO32Relocation]
    public let entryPoint: UInt32?
    public let entryPointFileOffset: UInt64?
    public let fileBytes: Data

    public var architectureName: String {
        switch cpuSubtype & 0x00FF_FFFF {
        case 6: return "ARMv6"
        case 9: return "ARMv7"
        case 11: return "ARMv7s"
        case 12: return "ARMv7k"
        case 13: return "ARMv8 (32-bit ARM)"
        default: return "ARM32 subtype \(cpuSubtype & 0x00FF_FFFF)"
        }
    }

    public var undefinedSymbols: [RE4MachO32Symbol] {
        var seen = Set<String>()
        return symbols.filter {
            $0.isUndefined && $0.isExternal && !$0.name.isEmpty && seen.insert($0.name).inserted
        }
    }

    public var importNames: [String] {
        Array(Set(undefinedSymbols.map(\.name) + bindRecords.map(\.symbolName) + indirectImports.map(\.symbolName))).sorted()
    }

    public func makeLoadPlan(guestMemorySize: Int) throws -> RE4MachO32LoadPlan {
        guard !segments.isEmpty else { throw RE4MachO32Error.noSegments }
        var planned: [RE4MachO32LoadSegment] = []
        for segment in segments where !segment.isPageZero && (segment.vmSize > 0) {
            let end = UInt64(segment.vmAddress) + UInt64(segment.vmSize)
            guard end >= UInt64(segment.vmAddress), end <= UInt64(guestMemorySize) else {
                throw RE4MachO32Error.segmentOutOfBounds(name: segment.name, end: end, memorySize: guestMemorySize)
            }
            let fileEnd = UInt64(segment.fileOffset) + UInt64(segment.fileSize)
            guard fileEnd >= UInt64(segment.fileOffset), fileEnd <= UInt64(fileBytes.count),
                  segment.fileSize <= segment.vmSize else {
                throw RE4MachO32Error.malformedSegment(segment.name)
            }
            planned.append(RE4MachO32LoadSegment(
                name: segment.name,
                vmAddress: segment.vmAddress,
                vmSize: segment.vmSize,
                fileOffset: segment.fileOffset,
                fileSize: segment.fileSize,
                initialProtection: segment.initialProtection
            ))
        }
        let sorted = planned.sorted { $0.vmAddress < $1.vmAddress }
        for i in 1..<sorted.count {
            if UInt64(sorted[i - 1].vmAddress) + UInt64(sorted[i - 1].vmSize) > UInt64(sorted[i].vmAddress) {
                throw RE4MachO32Error.overlappingSegments(sorted[i - 1].name, sorted[i].name)
            }
        }
        let required = sorted.map { UInt64($0.vmAddress) + UInt64($0.vmSize) }.max() ?? 0
        let pageZero = segments.filter(\.isPageZero).map { UInt64($0.vmSize) }.max() ?? 0
        return RE4MachO32LoadPlan(
            segments: sorted,
            requiredMemorySize: required,
            entryPoint: entryPoint,
            unmappedPageZero: pageZero
        )
    }

    public var inspectionReport: String {
        var lines = [
            "Mach-O 32-bit ARM：解析成功",
            "架構：\(architectureName)",
            String(format: "CPU subtype：0x%08X；filetype：0x%08X；flags：0x%08X", cpuSubtype, fileType, flags),
            "Universal binary：\(wasUniversal ? "是" : "否")；load commands：\(commandCount)",
            entryPoint.map { String(format: "入口 PC：0x%08X", $0) } ?? "入口 PC：未在支援的 thread/main load command 中找到",
            "Segments：\(segments.count)；依賴 dylib：\(dependencies.count)",
            "Undefined symbols：\(undefinedSymbols.count)；dyld bind records：\(bindRecords.count)",
            "Indirect imports：\(indirectImports.count)；section relocations：\(relocations.count)",
            "",
            "[Segments]"
        ]
        for s in segments {
            lines.append(String(format: "%@ VM=0x%08X +0x%X file=0x%X +0x%X prot=%d sections=%d",
                                s.name, s.vmAddress, s.vmSize, s.fileOffset, s.fileSize,
                                s.initialProtection, s.sections.count))
        }
        if !dependencies.isEmpty {
            lines += ["", "[Dylib dependencies]"]
            lines += dependencies.map { $0.name }
        }
        if !importNames.isEmpty {
            lines += ["", "[Imports / HLE inventory]"]
            lines += importNames.prefix(48)
            if importNames.count > 48 { lines.append("…（另有 \(importNames.count - 48) 個）") }
        }
        if !bindRecords.isEmpty {
            lines += ["", "[First dyld binds]"]
            lines += bindRecords.prefix(16).map { b in
                let at = b.vmAddress.map { String(format: " @0x%08X", $0) } ?? ""
                return "\(b.symbolName) ordinal=\(b.dylibOrdinal)\(at) [\(b.stream)]"
            }
        }
        do {
            let plan = try makeLoadPlan(guestMemorySize: 0x0500_0000)
            lines += ["", String(format: "Guest load plan：可容納，最低 guest memory end = 0x%llX", plan.requiredMemorySize)]
        } catch {
            lines += ["", "Guest load plan：尚未通過目前 80 MiB guest memory 邊界", error.localizedDescription]
        }
        lines += ["", "注意：本工具只解析與規劃映射，尚未套用 relocation/bind 或執行 Mach-O。"]
        return lines.joined(separator: "\n")
    }
}

public enum RE4MachO32Parser {
    private static let mhMagic: UInt32 = 0xFEEDFACE
    private static let fatMagic32: UInt32 = 0xCAFEBABE
    private static let fatMagic64: UInt32 = 0xCAFEBABF
    private static let cpuTypeARM: UInt32 = 12
    private static let mhExecute: UInt32 = 2
    private static let lcSegment: UInt32 = 0x1
    private static let lcSymtab: UInt32 = 0x2
    private static let lcThread: UInt32 = 0x4
    private static let lcUnixThread: UInt32 = 0x5
    private static let lcDysymtab: UInt32 = 0xB
    private static let lcLoadDylib: UInt32 = 0xC
    private static let lcLoadWeakDylib: UInt32 = 0x80000018
    private static let lcReexportDylib: UInt32 = 0x8000001F
    private static let lcLazyLoadDylib: UInt32 = 0x20
    private static let lcLoadUpwardDylib: UInt32 = 0x80000023
    private static let lcDyldInfo: UInt32 = 0x22
    private static let lcDyldInfoOnly: UInt32 = 0x80000022
    private static let lcMain: UInt32 = 0x80000028

    private struct SymtabCommand { let symoff: UInt32; let nsyms: UInt32; let stroff: UInt32; let strsize: UInt32 }
    private struct DysymtabCommand { let indirectOffset: UInt32; let indirectCount: UInt32 }
    private struct BindStream { let offset: UInt32; let size: UInt32; let name: String }
    private struct FatSlice { let offset: UInt64; let size: UInt64; let cpu: UInt32; let subtype: UInt32 }

    public static func parse(_ input: Data) throws -> RE4MachO32Image {
        let bytes = [UInt8](input)
        guard bytes.count >= 4 else { throw RE4MachO32Error.truncatedFile }
        let magicBE = be32(bytes, 0)
        if magicBE == fatMagic32 || magicBE == fatMagic64 {
            return try parseUniversal(bytes, fat64: magicBE == fatMagic64)
        }
        return try parseThin(bytes, wasUniversal: false, sliceOffset: 0)
    }

    private static func parseUniversal(_ bytes: [UInt8], fat64: Bool) throws -> RE4MachO32Image {
        guard bytes.count >= 8 else { throw RE4MachO32Error.invalidFatHeader }
        let count = be32(bytes, 4)
        guard count > 0 && count <= 4096 else { throw RE4MachO32Error.invalidFatHeader }
        let entrySize = fat64 ? 32 : 20
        let tableEnd = UInt64(8) + UInt64(count) * UInt64(entrySize)
        guard tableEnd <= UInt64(bytes.count) else { throw RE4MachO32Error.invalidFatHeader }
        var choices: [FatSlice] = []
        for i in 0..<Int(count) {
            let p = 8 + i * entrySize
            let cpu = be32(bytes, p)
            let subtype = be32(bytes, p + 4)
            let offset: UInt64
            let size: UInt64
            if fat64 {
                offset = be64(bytes, p + 8)
                size = be64(bytes, p + 16)
            } else {
                offset = UInt64(be32(bytes, p + 8))
                size = UInt64(be32(bytes, p + 12))
            }
            guard offset <= UInt64(bytes.count), size <= UInt64(bytes.count) - offset else {
                throw RE4MachO32Error.invalidFatSlice
            }
            guard cpu == cpuTypeARM else { continue }
            choices.append(FatSlice(offset: offset, size: size, cpu: cpu, subtype: subtype))
        }
        guard !choices.isEmpty else { throw RE4MachO32Error.noArm32Slice }
        choices.sort {
            func rank(_ value: UInt32) -> Int {
                switch value & 0x00FF_FFFF {
                case 6: return 0
                case 9: return 1
                default: return 2
                }
            }
            let a = rank($0.subtype), b = rank($1.subtype)
            return a == b ? $0.offset < $1.offset : a < b
        }
        for choice in choices {
            let start = Int(choice.offset), end = Int(choice.offset + choice.size)
            let slice = Array(bytes[start..<end])
            do {
                return try parseThin(slice, wasUniversal: true, sliceOffset: choice.offset)
            } catch {
                // Prefer a valid ARMv6 slice, but allow a universal's ARMv7 slice if the
                // first ARM slice uses an unsupported encoding.
                continue
            }
        }
        throw RE4MachO32Error.invalidFatSlice
    }

    private static func parseThin(_ b: [UInt8], wasUniversal: Bool, sliceOffset: UInt64) throws -> RE4MachO32Image {
        guard b.count >= 28 else { throw RE4MachO32Error.truncatedFile }
        let magic = le32(b, 0)
        guard magic == mhMagic else { throw RE4MachO32Error.unsupportedMagic(magic) }
        let cpuType = le32(b, 4)
        guard cpuType == cpuTypeARM else { throw RE4MachO32Error.wrongCPU(cpuType) }
        let subtype = le32(b, 8)
        let fileType = le32(b, 12)
        let ncmds = le32(b, 16)
        let sizeofcmds = le32(b, 20)
        let flags = le32(b, 24)
        guard ncmds <= 65_535,
              UInt64(28) + UInt64(sizeofcmds) <= UInt64(b.count) else {
            throw RE4MachO32Error.malformedHeader
        }
        let commandEnd = 28 + Int(sizeofcmds)
        var position = 28
        var segments: [RE4MachO32Segment] = []
        var dependencies: [RE4MachO32DylibDependency] = []
        var symtab: SymtabCommand?
        var dysymtab: DysymtabCommand?
        var bindStreams: [BindStream] = []
        var threadEntry: UInt32?
        var mainEntryOffset: UInt64?

        for commandIndex in 0..<Int(ncmds) {
            guard position + 8 <= commandEnd else { throw RE4MachO32Error.malformedLoadCommand(index: commandIndex) }
            let command = le32(b, position)
            let commandSize = Int(le32(b, position + 4))
            guard commandSize >= 8, commandSize % 4 == 0,
                  position + commandSize <= commandEnd else {
                throw RE4MachO32Error.malformedLoadCommand(index: commandIndex)
            }
            let commandEndPosition = position + commandSize

            if command == lcSegment {
                guard commandSize >= 56 else { throw RE4MachO32Error.malformedLoadCommand(index: commandIndex) }
                let segmentName = fixedString(b, position + 8, 16)
                let vmAddress = le32(b, position + 24)
                let vmSize = le32(b, position + 28)
                let fileOffset = le32(b, position + 32)
                let fileSize = le32(b, position + 36)
                let maxProt = Int32(bitPattern: le32(b, position + 40))
                let initProt = Int32(bitPattern: le32(b, position + 44))
                let sectionCount = le32(b, position + 48)
                let sectionBytes = UInt64(sectionCount) * 68
                guard sectionCount <= 65_535,
                      UInt64(56) + sectionBytes <= UInt64(commandSize),
                      fileSize <= vmSize,
                      UInt64(fileOffset) + UInt64(fileSize) <= UInt64(b.count) else {
                    throw RE4MachO32Error.malformedSegment(segmentName)
                }
                var sections: [RE4MachO32Section] = []
                for sectionIndex in 0..<Int(sectionCount) {
                    let p = position + 56 + sectionIndex * 68
                    sections.append(RE4MachO32Section(
                        name: fixedString(b, p, 16),
                        segmentName: fixedString(b, p + 16, 16),
                        address: le32(b, p + 32),
                        size: le32(b, p + 36),
                        fileOffset: le32(b, p + 40),
                        alignment: le32(b, p + 44),
                        relocationOffset: le32(b, p + 48),
                        relocationCount: le32(b, p + 52),
                        flags: le32(b, p + 56),
                        reserved1: le32(b, p + 60),
                        reserved2: le32(b, p + 64)
                    ))
                }
                segments.append(RE4MachO32Segment(
                    name: segmentName, vmAddress: vmAddress, vmSize: vmSize,
                    fileOffset: fileOffset, fileSize: fileSize, maxProtection: maxProt,
                    initialProtection: initProt, flags: le32(b, position + 52), sections: sections
                ))
            } else if command == lcSymtab {
                guard commandSize >= 24 else { throw RE4MachO32Error.malformedLoadCommand(index: commandIndex) }
                symtab = SymtabCommand(symoff: le32(b, position + 8), nsyms: le32(b, position + 12),
                                       stroff: le32(b, position + 16), strsize: le32(b, position + 20))
            } else if command == lcDysymtab {
                guard commandSize >= 80 else { throw RE4MachO32Error.malformedLoadCommand(index: commandIndex) }
                dysymtab = DysymtabCommand(indirectOffset: le32(b, position + 56),
                                           indirectCount: le32(b, position + 60))
            } else if [lcLoadDylib, lcLoadWeakDylib, lcReexportDylib, lcLazyLoadDylib, lcLoadUpwardDylib].contains(command) {
                guard commandSize >= 24 else { throw RE4MachO32Error.malformedDylibCommand }
                let nameOffset = Int(le32(b, position + 8))
                guard nameOffset >= 24, nameOffset < commandSize else { throw RE4MachO32Error.malformedDylibCommand }
                let name = cString(b, position + nameOffset, maxLength: commandSize - nameOffset)
                dependencies.append(RE4MachO32DylibDependency(
                    name: name, command: command, currentVersion: le32(b, position + 16),
                    compatibilityVersion: le32(b, position + 20)
                ))
            } else if command == lcDyldInfo || command == lcDyldInfoOnly {
                guard commandSize >= 48 else { throw RE4MachO32Error.malformedLoadCommand(index: commandIndex) }
                let bindOffset = le32(b, position + 16), bindSize = le32(b, position + 20)
                let weakOffset = le32(b, position + 24), weakSize = le32(b, position + 28)
                let lazyOffset = le32(b, position + 32), lazySize = le32(b, position + 36)
                if bindSize > 0 { bindStreams.append(BindStream(offset: bindOffset, size: bindSize, name: "bind")) }
                if weakSize > 0 { bindStreams.append(BindStream(offset: weakOffset, size: weakSize, name: "weak")) }
                if lazySize > 0 { bindStreams.append(BindStream(offset: lazyOffset, size: lazySize, name: "lazy")) }
            } else if command == lcThread || command == lcUnixThread {
                if commandSize >= 16 {
                    let flavor = le32(b, position + 8)
                    let count = le32(b, position + 12)
                    if flavor == 1 && count >= 17 && commandSize >= 84 {
                        threadEntry = le32(b, position + 76) // ARM thread state r15/PC
                    }
                }
            } else if command == lcMain {
                guard commandSize >= 24 else { throw RE4MachO32Error.malformedLoadCommand(index: commandIndex) }
                mainEntryOffset = le64(b, position + 8)
            }
            position = commandEndPosition
        }
        guard position == commandEnd else { throw RE4MachO32Error.malformedHeader }
        guard !segments.isEmpty else { throw RE4MachO32Error.noSegments }

        var symbols: [RE4MachO32Symbol] = []
        if let symtab {
            let symbolBytes = UInt64(symtab.nsyms) * 12
            guard UInt64(symtab.symoff) + symbolBytes <= UInt64(b.count),
                  UInt64(symtab.stroff) + UInt64(symtab.strsize) <= UInt64(b.count) else {
                throw RE4MachO32Error.malformedSymbolTable
            }
            let stringsStart = Int(symtab.stroff), stringsSize = Int(symtab.strsize)
            symbols.reserveCapacity(Int(symtab.nsyms))
            for i in 0..<Int(symtab.nsyms) {
                let p = Int(symtab.symoff) + i * 12
                let stringIndex = le32(b, p)
                let type = b[p + 4], section = b[p + 5], desc = le16(b, p + 6), value = le32(b, p + 8)
                let name: String
                if stringIndex == 0 {
                    name = ""
                } else if stringIndex < symtab.strsize {
                    name = cString(b, stringsStart + Int(stringIndex), maxLength: stringsSize - Int(stringIndex))
                } else {
                    throw RE4MachO32Error.malformedSymbolTable
                }
                symbols.append(RE4MachO32Symbol(name: name, type: type, section: section, description: desc, value: value))
            }
        }

        var relocations: [RE4MachO32Relocation] = []
        for segment in segments {
            for section in segment.sections where section.relocationCount > 0 {
                let total = UInt64(section.relocationCount) * 8
                guard UInt64(section.relocationOffset) + total <= UInt64(b.count) else {
                    throw RE4MachO32Error.malformedSegment(segment.name)
                }
                for i in 0..<Int(section.relocationCount) {
                    let p = Int(section.relocationOffset) + i * 8
                    let first = le32(b, p), second = le32(b, p + 4)
                    if first & 0x80000000 != 0 {
                        relocations.append(RE4MachO32Relocation(
                            sectionName: section.name, address: Int32(first & 0x00FF_FFFF),
                            symbolIndex: 0, isExternal: false, isPCRelative: first & 0x40000000 != 0,
                            length: UInt8((first >> 28) & 3), type: UInt8((first >> 24) & 0xF),
                            scattered: true, symbolName: nil
                        ))
                    } else {
                        let symbolIndex = second & 0x00FF_FFFF
                        let external = second & 0x08000000 != 0
                        let symbolName = external && symbolIndex < UInt32(symbols.count) ? symbols[Int(symbolIndex)].name : nil
                        relocations.append(RE4MachO32Relocation(
                            sectionName: section.name, address: Int32(bitPattern: first), symbolIndex: symbolIndex,
                            isExternal: external, isPCRelative: second & 0x01000000 != 0,
                            length: UInt8((second >> 25) & 3), type: UInt8((second >> 28) & 0xF),
                            scattered: false, symbolName: symbolName
                        ))
                    }
                }
            }
        }

        var indirectImports: [RE4MachO32IndirectImport] = []
        if let dysymtab, dysymtab.indirectCount > 0 {
            let bytesNeeded = UInt64(dysymtab.indirectCount) * 4
            guard UInt64(dysymtab.indirectOffset) + bytesNeeded <= UInt64(b.count) else {
                throw RE4MachO32Error.malformedSymbolTable
            }
            let indices = (0..<Int(dysymtab.indirectCount)).map { le32(b, Int(dysymtab.indirectOffset) + $0 * 4) }
            for segment in segments {
                for section in segment.sections where [UInt32(6), 7, 8].contains(section.type) {
                    let isStub = section.type == 8
                    let entrySize = isStub ? Int(section.reserved2) : 4
                    guard entrySize > 0 else { continue }
                    let slots = Int((section.size + UInt32(entrySize) - 1) / UInt32(entrySize))
                    for slot in 0..<slots {
                        let index = Int(section.reserved1) + slot
                        guard index < indices.count else { continue }
                        let symbolIndex = indices[index]
                        if symbolIndex & 0xC0000000 != 0 || symbolIndex >= UInt32(symbols.count) { continue }
                        let symbol = symbols[Int(symbolIndex)]
                        guard symbol.isUndefined, !symbol.name.isEmpty else { continue }
                        guard symbol.isExternal else { continue }
                        indirectImports.append(RE4MachO32IndirectImport(
                            symbolName: symbol.name, sectionName: section.name,
                            slotAddress: section.address &+ UInt32(slot * entrySize), isStub: isStub,
                            sectionType: section.type, entrySize: UInt32(entrySize)
                        ))
                    }
                }
            }
        }

        var binds: [RE4MachO32BindRecord] = []
        for stream in bindStreams {
            let end = UInt64(stream.offset) + UInt64(stream.size)
            guard end <= UInt64(b.count) else { throw RE4MachO32Error.malformedBindStream("stream outside file") }
            binds += try parseBindStream(Array(b[Int(stream.offset)..<Int(end)]),
                                         streamName: stream.name, segments: segments)
        }

        var entry = threadEntry
        if let mainEntryOffset {
            for segment in segments where mainEntryOffset >= UInt64(segment.fileOffset) &&
                                           mainEntryOffset < UInt64(segment.fileOffset) + UInt64(segment.fileSize) {
                let value = UInt64(segment.vmAddress) + mainEntryOffset - UInt64(segment.fileOffset)
                if value <= UInt64(UInt32.max) { entry = UInt32(value) }
                break
            }
        }

        return RE4MachO32Image(
            cpuType: cpuType, cpuSubtype: subtype, fileType: fileType, flags: flags,
            commandCount: ncmds, wasUniversal: wasUniversal, selectedSliceOffset: sliceOffset,
            segments: segments, dependencies: dependencies, symbols: symbols, bindRecords: binds,
            indirectImports: indirectImports, relocations: relocations, entryPoint: entry,
            entryPointFileOffset: mainEntryOffset, fileBytes: Data(b)
        )
    }

    private static func parseBindStream(_ bytes: [UInt8], streamName: String,
                                        segments: [RE4MachO32Segment]) throws -> [RE4MachO32BindRecord] {
        var cursor = 0
        var ordinal = 0
        var symbol = ""
        var bindType: UInt8 = 1
        var addend: Int64 = 0
        var segmentIndex: Int?
        var segmentOffset: UInt64 = 0
        var result: [RE4MachO32BindRecord] = []
        var commandCount = 0

        func resetState() {
            ordinal = 0; symbol = ""; bindType = 1; addend = 0
            segmentIndex = nil; segmentOffset = 0
        }
        func emit() {
            guard !symbol.isEmpty else { return }
            let segName = segmentIndex.flatMap { $0 >= 0 && $0 < segments.count ? segments[$0].name : nil }
            var address: UInt32?
            if let idx = segmentIndex, idx >= 0, idx < segments.count {
                let s = segments[idx]
                let candidate = UInt64(s.vmAddress) + segmentOffset
                if candidate <= UInt64(UInt32.max) { address = UInt32(candidate) }
            }
            result.append(RE4MachO32BindRecord(symbolName: symbol, dylibOrdinal: ordinal,
                                               bindType: bindType, addend: addend,
                                               segmentIndex: segmentIndex, segmentName: segName,
                                               vmAddress: address, stream: streamName))
        }

        while cursor < bytes.count {
            commandCount += 1
            if commandCount > 1_000_000 { throw RE4MachO32Error.malformedBindStream("opcode limit exceeded") }
            let byte = bytes[cursor]; cursor += 1
            let opcode = byte & 0xF0, immediate = byte & 0x0F
            switch opcode {
            case 0x00: // DONE
                if streamName == "lazy" && cursor < bytes.count {
                    resetState()
                    continue
                }
                return result
            case 0x10: ordinal = Int(immediate)
            case 0x20: ordinal = Int(try readULEB(bytes, cursor: &cursor))
            case 0x30:
                let signed = Int8(bitPattern: immediate << 4) >> 4
                ordinal = Int(signed)
            case 0x40:
                symbol = try readCString(bytes, cursor: &cursor)
            case 0x50: bindType = immediate
            case 0x60: addend = try readSLEB(bytes, cursor: &cursor)
            case 0x70:
                segmentIndex = Int(immediate)
                segmentOffset = try readULEB(bytes, cursor: &cursor)
            case 0x80:
                segmentOffset &+= try readULEB(bytes, cursor: &cursor)
            case 0x90:
                emit(); segmentOffset &+= 4
            case 0xA0:
                emit(); segmentOffset &+= (try readULEB(bytes, cursor: &cursor)) &+ 4
            case 0xB0:
                emit(); segmentOffset &+= UInt64(immediate) * 4 + 4
            case 0xC0:
                let count = try readULEB(bytes, cursor: &cursor)
                let skip = try readULEB(bytes, cursor: &cursor)
                guard count <= 1_000_000 else { throw RE4MachO32Error.malformedBindStream("repeat count exceeds limit") }
                for _ in 0..<Int(count) { emit(); segmentOffset &+= skip + 4 }
            case 0xD0:
                throw RE4MachO32Error.malformedBindStream("threaded-bind opcodes are not supported by this 32-bit parser")
            default:
                throw RE4MachO32Error.malformedBindStream(String(format: "unknown opcode 0x%02X", opcode))
            }
        }
        return result
    }

    private static func readULEB(_ bytes: [UInt8], cursor: inout Int) throws -> UInt64 {
        var value: UInt64 = 0, shift: UInt64 = 0
        while cursor < bytes.count && shift < 64 {
            let b = bytes[cursor]; cursor += 1
            value |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return value }
            shift += 7
        }
        throw RE4MachO32Error.malformedBindStream("unterminated ULEB128")
    }

    private static func readSLEB(_ bytes: [UInt8], cursor: inout Int) throws -> Int64 {
        var result: Int64 = 0, shift: UInt64 = 0
        var last: UInt8 = 0
        repeat {
            guard cursor < bytes.count && shift < 64 else { throw RE4MachO32Error.malformedBindStream("unterminated SLEB128") }
            last = bytes[cursor]; cursor += 1
            result |= Int64(last & 0x7F) << shift
            shift += 7
        } while last & 0x80 != 0
        if shift < 64 && (last & 0x40) != 0 { result |= -(1 << shift) }
        return result
    }

    private static func readCString(_ bytes: [UInt8], cursor: inout Int) throws -> String {
        guard cursor < bytes.count else { throw RE4MachO32Error.malformedBindStream("missing symbol string") }
        let start = cursor
        while cursor < bytes.count && bytes[cursor] != 0 { cursor += 1 }
        guard cursor < bytes.count else { throw RE4MachO32Error.malformedBindStream("unterminated symbol string") }
        let value = String(decoding: bytes[start..<cursor], as: UTF8.self)
        cursor += 1
        return value
    }

    private static func fixedString(_ b: [UInt8], _ start: Int, _ count: Int) -> String {
        guard start >= 0, count >= 0, start + count <= b.count else { return "" }
        let slice = b[start..<(start + count)]
        let nul = slice.firstIndex(of: 0) ?? slice.endIndex
        return String(decoding: slice[..<nul], as: UTF8.self)
    }

    private static func cString(_ b: [UInt8], _ start: Int, maxLength: Int) -> String {
        guard start >= 0, maxLength >= 0, start + maxLength <= b.count else { return "" }
        let slice = b[start..<(start + maxLength)]
        let nul = slice.firstIndex(of: 0) ?? slice.endIndex
        return String(decoding: slice[..<nul], as: UTF8.self)
    }

    private static func le16(_ b: [UInt8], _ p: Int) -> UInt16 {
        UInt16(b[p]) | (UInt16(b[p + 1]) << 8)
    }
    private static func le32(_ b: [UInt8], _ p: Int) -> UInt32 {
        UInt32(b[p]) | (UInt32(b[p + 1]) << 8) | (UInt32(b[p + 2]) << 16) | (UInt32(b[p + 3]) << 24)
    }
    private static func le64(_ b: [UInt8], _ p: Int) -> UInt64 {
        UInt64(le32(b, p)) | (UInt64(le32(b, p + 4)) << 32)
    }
    private static func be32(_ b: [UInt8], _ p: Int) -> UInt32 {
        (UInt32(b[p]) << 24) | (UInt32(b[p + 1]) << 16) | (UInt32(b[p + 2]) << 8) | UInt32(b[p + 3])
    }
    private static func be64(_ b: [UInt8], _ p: Int) -> UInt64 {
        (UInt64(be32(b, p)) << 32) | UInt64(be32(b, p + 4))
    }

    // Synthetic fixture helpers and self-test follow; the fixture has no game data.
    private static func put16(_ b: inout [UInt8], _ p: Int, _ v: UInt16) {
        b[p] = UInt8(v & 0xFF); b[p + 1] = UInt8((v >> 8) & 0xFF)
    }
    private static func put32(_ b: inout [UInt8], _ p: Int, _ v: UInt32) {
        b[p] = UInt8(v & 0xFF); b[p + 1] = UInt8((v >> 8) & 0xFF)
        b[p + 2] = UInt8((v >> 16) & 0xFF); b[p + 3] = UInt8((v >> 24) & 0xFF)
    }
    private static func putBE32(_ b: inout [UInt8], _ p: Int, _ v: UInt32) {
        b[p] = UInt8((v >> 24) & 0xFF); b[p + 1] = UInt8((v >> 16) & 0xFF)
        b[p + 2] = UInt8((v >> 8) & 0xFF); b[p + 3] = UInt8(v & 0xFF)
    }
    private static func appendLE16(_ b: inout [UInt8], _ v: UInt16) {
        b.append(UInt8(v & 0xFF)); b.append(UInt8((v >> 8) & 0xFF))
    }
    private static func appendLE32(_ b: inout [UInt8], _ v: UInt32) {
        b.append(UInt8(v & 0xFF)); b.append(UInt8((v >> 8) & 0xFF))
        b.append(UInt8((v >> 16) & 0xFF)); b.append(UInt8((v >> 24) & 0xFF))
    }
    private static func appendFixed(_ b: inout [UInt8], _ value: String, length: Int) {
        let v = Array(value.utf8.prefix(length))
        b.append(contentsOf: v)
        if v.count < length { b.append(contentsOf: repeatElement(UInt8(0), count: length - v.count)) }
    }

    private static func segmentCommand(name: String, vmAddress: UInt32, vmSize: UInt32,
                                       fileOffset: UInt32, fileSize: UInt32,
                                       protection: Int32, sections: [[UInt32]] = []) -> [UInt8] {
        var b: [UInt8] = []
        appendLE32(&b, lcSegment); appendLE32(&b, UInt32(56 + 68 * sections.count))
        appendFixed(&b, name, length: 16)
        appendLE32(&b, vmAddress); appendLE32(&b, vmSize)
        appendLE32(&b, fileOffset); appendLE32(&b, fileSize)
        appendLE32(&b, 7); appendLE32(&b, UInt32(bitPattern: protection))
        appendLE32(&b, UInt32(sections.count)); appendLE32(&b, 0)
        for s in sections {
            appendFixed(&b, s[0] == 1 ? "__text" : "__la_symbol_ptr", length: 16)
            appendFixed(&b, name, length: 16)
            appendLE32(&b, s[1]); appendLE32(&b, s[2]); appendLE32(&b, s[3])
            appendLE32(&b, s[4]); appendLE32(&b, s[5]); appendLE32(&b, s[6])
            appendLE32(&b, s[7]); appendLE32(&b, s[8]); appendLE32(&b, s[9])
        }
        return b
    }

    private static func syntheticFixture() throws -> Data {
        let textSection: [UInt32] = [1, 0x1270, 8, 0x270, 2, 0x304, 1, 0x80000400, 0, 0]
        let dataSection: [UInt32] = [2, 0x3000, 4, 0x280, 2, 0, 0, 7, 0, 0]
        var commands = [UInt8]()
        commands += segmentCommand(name: "__TEXT", vmAddress: 0x1000, vmSize: 0x1000,
                                   fileOffset: 0, fileSize: 0x280, protection: 5, sections: [textSection])
        commands += segmentCommand(name: "__DATA", vmAddress: 0x3000, vmSize: 0x1000,
                                   fileOffset: 0x280, fileSize: 0x40, protection: 3, sections: [dataSection])
        commands += segmentCommand(name: "__LINKEDIT", vmAddress: 0x4000, vmSize: 0x1000,
                                   fileOffset: 0x2C0, fileSize: 0x80, protection: 1)
        var symtab = [UInt8]()
        appendLE32(&symtab, lcSymtab); appendLE32(&symtab, 24)
        appendLE32(&symtab, 0x2C0); appendLE32(&symtab, 2)
        appendLE32(&symtab, 0x2D8); appendLE32(&symtab, 32)
        commands += symtab
        var dysym = [UInt8](repeating: 0, count: 80)
        put32(&dysym, 0, lcDysymtab); put32(&dysym, 4, 80)
        put32(&dysym, 56, 0x300); put32(&dysym, 60, 1)
        commands += dysym
        let dylibName = Array("/usr/lib/libSystem.B.dylib".utf8) + [UInt8(0)]
        let dylibSize = (24 + dylibName.count + 3) & ~3
        var dylib = [UInt8]()
        appendLE32(&dylib, lcLoadDylib); appendLE32(&dylib, UInt32(dylibSize))
        appendLE32(&dylib, 24); appendLE32(&dylib, 0)
        appendLE32(&dylib, 0x10000); appendLE32(&dylib, 0x10000)
        dylib += dylibName
        if dylib.count < dylibSize { dylib += [UInt8](repeating: 0, count: dylibSize - dylib.count) }
        commands += dylib
        var thread = [UInt8](repeating: 0, count: 84)
        put32(&thread, 0, lcUnixThread); put32(&thread, 4, 84)
        put32(&thread, 8, 1); put32(&thread, 12, 17); put32(&thread, 76, 0x1270)
        commands += thread
        let bindStream: [UInt8] = [0x11, 0x40] + Array("_malloc".utf8) + [0, 0x51, 0x71, 0, 0x90, 0]
        var dyld = [UInt8](repeating: 0, count: 48)
        put32(&dyld, 0, lcDyldInfo); put32(&dyld, 4, 48)
        put32(&dyld, 16, 0x310); put32(&dyld, 20, UInt32(bindStream.count))
        commands += dyld

        var file = [UInt8](repeating: 0, count: 0x340)
        put32(&file, 0, mhMagic); put32(&file, 4, cpuTypeARM); put32(&file, 8, 6)
        put32(&file, 12, mhExecute); put32(&file, 16, 8)
        put32(&file, 20, UInt32(commands.count)); put32(&file, 24, 0x200000)
        guard 28 + commands.count <= 0x280 else {
            throw RE4MachO32Error.syntheticSelfTestFailed("synthetic load commands overlap segment data")
        }
        file.replaceSubrange(28..<(28 + commands.count), with: commands)
        // Generated instruction stream for static inspection tests; never game code.
        put32(&file, 0x270, 0xE3A00001) // MOV r0, #1
        put32(&file, 0x274, 0xE2800002) // ADD r0, r0, #2
        put32(&file, 0x278, 0xE12FFF1E) // BX lr
        // Two nlist records at __LINKEDIT file offset 0x2C0.
        put32(&file, 0x2C0, 1); file[0x2C4] = 0x0F; file[0x2C5] = 1; put32(&file, 0x2C8, 0x1270)
        put32(&file, 0x2CC, 8); file[0x2D0] = 0x01; file[0x2D1] = 0; put32(&file, 0x2D4, 0)
        let strings = Array("\0_entry\0_malloc\0".utf8)
        file.replaceSubrange(0x2D8..<(0x2D8 + strings.count), with: strings)
        put32(&file, 0x300, 1)
        put32(&file, 0x304, 4); put32(&file, 0x308, 0x0C000001) // external ARM vanilla relocation to nlist #1
        file.replaceSubrange(0x310..<(0x310 + bindStream.count), with: bindStream)
        return Data(file)
    }

    private static func wrapFat(_ thin: Data) -> Data {
        var fat = [UInt8](repeating: 0, count: 0x100 + thin.count)
        putBE32(&fat, 0, fatMagic32); putBE32(&fat, 4, 1)
        putBE32(&fat, 8, cpuTypeARM); putBE32(&fat, 12, 6)
        putBE32(&fat, 16, 0x100); putBE32(&fat, 20, UInt32(thin.count)); putBE32(&fat, 24, 2)
        fat.replaceSubrange(0x100..<(0x100 + thin.count), with: thin)
        return Data(fat)
    }

    /// Generated test fixture with no game assets, shared by the parser and mapper tests.
    public static func makeSyntheticSelfTestFixture() throws -> Data {
        try syntheticFixture()
    }

    public static func runSyntheticSelfTest() throws -> String {
        let thinData = try syntheticFixture()
        let thin = try parse(thinData)
        guard thin.architectureName == "ARMv6" else { throw RE4MachO32Error.syntheticSelfTestFailed("CPU subtype") }
        guard thin.entryPoint == 0x1270 else { throw RE4MachO32Error.syntheticSelfTestFailed("entry PC") }
        guard thin.segments.map(\.name) == ["__TEXT", "__DATA", "__LINKEDIT"] else {
            throw RE4MachO32Error.syntheticSelfTestFailed("segment order/names")
        }
        guard thin.dependencies.contains(where: { $0.name == "/usr/lib/libSystem.B.dylib" }) else {
            throw RE4MachO32Error.syntheticSelfTestFailed("dylib dependency")
        }
        guard thin.undefinedSymbols.contains(where: { $0.name == "_malloc" }) else {
            throw RE4MachO32Error.syntheticSelfTestFailed("undefined import symbol")
        }
        guard thin.indirectImports.contains(where: { $0.symbolName == "_malloc" && $0.slotAddress == 0x3000 }) else {
            throw RE4MachO32Error.syntheticSelfTestFailed("indirect symbol pointer")
        }
        guard thin.relocations.contains(where: { $0.isExternal && $0.symbolName == "_malloc" }) else {
            throw RE4MachO32Error.syntheticSelfTestFailed("external relocation")
        }
        guard thin.bindRecords.contains(where: { $0.symbolName == "_malloc" && $0.dylibOrdinal == 1 && $0.vmAddress == 0x3000 }) else {
            throw RE4MachO32Error.syntheticSelfTestFailed("dyld bind stream")
        }
        let plan = try thin.makeLoadPlan(guestMemorySize: 0x6000)
        guard plan.requiredMemorySize == 0x5000 && plan.entryPoint == 0x1270 else {
            throw RE4MachO32Error.syntheticSelfTestFailed("guest mapping plan")
        }
        do {
            _ = try thin.makeLoadPlan(guestMemorySize: 0x4000)
            throw RE4MachO32Error.syntheticSelfTestFailed("out-of-bounds segment was accepted")
        } catch RE4MachO32Error.segmentOutOfBounds { }

        let fat = try parse(wrapFat(thinData))
        guard fat.wasUniversal, fat.selectedSliceOffset == 0x100, fat.entryPoint == 0x1270 else {
            throw RE4MachO32Error.syntheticSelfTestFailed("universal ARM32 slice selection")
        }
        return "Mach-O 32-bit ARM parser self-test PASS\nThin ARMv6 + universal FAT slice passed.\nSegments: __TEXT, __DATA, __LINKEDIT\nEntry PC: 0x00001030\nSymbols/imports: _malloc\nDylib, dyld bind, indirect symbol and relocation parsing passed.\nGuest mapping bounds check passed.\nNo game assets or original IPA used."
    }
}
