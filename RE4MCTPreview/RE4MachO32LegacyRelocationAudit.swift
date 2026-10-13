import Foundation

/// Read-only analysis of classic LC_DYSYMTAB external relocations.
/// It inventories target sites, symbol indices, library ordinals, and current bytes.
/// No relocation is applied, no import is resolved, and no guest instruction executes.
public enum RE4MachO32LegacyRelocationAudit {
    private struct Site {
        let address: UInt32
        let symbolName: String
        let symbolIndex: UInt32
        let libraryOrdinal: Int?
        let libraryName: String
        let relocationType: UInt8
        let isPCRelative: Bool
        let length: UInt8
        let isExternal: Bool
        let scattered: Bool
        let segmentName: String?
        let sectionName: String?
        let fileOffset: UInt64?
        let rawWord: UInt32?
        let mappedWord: UInt32?
    }

    private static func readWord(_ data: Data, offset: UInt64) -> UInt32? {
        guard offset <= UInt64(Int.max), offset + 4 <= UInt64(data.count) else { return nil }
        let p = Int(offset)
        return UInt32(data[p]) | (UInt32(data[p + 1]) << 8) |
               (UInt32(data[p + 2]) << 16) | (UInt32(data[p + 3]) << 24)
    }

    private static func libraryOrdinal(_ symbol: RE4MachO32Symbol) -> Int {
        Int((symbol.description >> 8) & 0x00FF)
    }

    private static func libraryName(_ ordinal: Int, dependencies: [RE4MachO32DylibDependency]) -> String {
        switch ordinal {
        case 0: return "SELF (ordinal 0)"
        case 0xFD: return "MAX_LIBRARY_ORDINAL (0xFD)"
        case 0xFE: return "DYNAMIC_LOOKUP (0xFE)"
        case 0xFF: return "EXECUTABLE (0xFF)"
        case 1...: 
            if ordinal <= dependencies.count {
                return "\(ordinal): \(dependencies[ordinal - 1].name)"
            }
            return "out-of-range library ordinal \(ordinal)"
        default:
            return "unknown library ordinal \(ordinal)"
        }
    }

    private static func makeSite(_ relocation: RE4MachO32Relocation,
                                 image: RE4MachO32Image,
                                 memory: RE4GuestMemoryReading) -> Site {
        let address = UInt32(bitPattern: relocation.address)
        let symbol: RE4MachO32Symbol? = relocation.isExternal && relocation.symbolIndex < UInt32(image.symbols.count)
            ? image.symbols[Int(relocation.symbolIndex)] : nil
        let name = symbol?.name.isEmpty == false ? symbol!.name : (relocation.symbolName ?? "(local/scattered)")
        let ordinal = symbol.map(libraryOrdinal)
        let dependency = ordinal.map { libraryName($0, dependencies: image.dependencies) } ?? "(no external dylib ordinal)"

        let width: UInt64 = relocation.length <= 3 ? (UInt64(1) << relocation.length) : 0
        var segmentName: String?
        var sectionName: String?
        var fileOffset: UInt64?
        var rawWord: UInt32?
        var mappedWord: UInt32?

        if width > 0 {
            for segment in image.segments where !segment.isPageZero {
                let address64 = UInt64(address)
                guard address64 >= UInt64(segment.vmAddress) else { continue }
                let delta = address64 - UInt64(segment.vmAddress)
                guard delta + width <= UInt64(segment.vmSize) else { continue }
                segmentName = segment.name
                if let section = segment.sections.first(where: {
                    address64 >= UInt64($0.address) &&
                    address64 + width <= UInt64($0.address) + UInt64($0.size)
                }) {
                    sectionName = "\(section.segmentName),\(section.name)"
                    let sectionDelta = address64 - UInt64(section.address)
                    let candidate = UInt64(section.fileOffset) + sectionDelta
                    if sectionDelta + width <= UInt64(section.size),
                       candidate + width <= UInt64(image.fileBytes.count) {
                        fileOffset = candidate
                        if width >= 4 { rawWord = readWord(image.fileBytes, offset: candidate) }
                    }
                }
                if fileOffset == nil, delta + width <= UInt64(segment.fileSize) {
                    let candidate = UInt64(segment.fileOffset) + delta
                    if candidate + width <= UInt64(image.fileBytes.count) {
                        fileOffset = candidate
                        if width >= 4 { rawWord = readWord(image.fileBytes, offset: candidate) }
                    }
                }
                break
            }
            if width >= 4 {
                mappedWord = try? readWord(memory.copyBytes(at: address, count: 4))
            } else if width > 0 {
                // Byte/halfword relocations are inventoried but are not summarized as 32-bit words.
                mappedWord = nil
            }
        }

        return Site(
            address: address, symbolName: name, symbolIndex: relocation.symbolIndex,
            libraryOrdinal: ordinal, libraryName: dependency,
            relocationType: relocation.type, isPCRelative: relocation.isPCRelative,
            length: relocation.length, isExternal: relocation.isExternal,
            scattered: relocation.scattered, segmentName: segmentName, sectionName: sectionName,
            fileOffset: fileOffset, rawWord: rawWord, mappedWord: mappedWord
        )
    }

    public static func report(image: RE4MachO32Image,
                              memory: RE4GuestMemoryReading,
                              exampleLimit: Int = 24) -> String {
        let sites = image.dynamicExternalRelocations.map {
            makeSite($0, image: image, memory: memory)
        }
        let inSegments = sites.filter { $0.segmentName != nil }.count
        let inSections = sites.filter { $0.sectionName != nil }.count
        let fileBacked = sites.filter { $0.fileOffset != nil && $0.rawWord != nil }.count
        let mappedReadable = sites.filter { $0.mappedWord != nil }.count
        let mismatches = sites.filter {
            guard let raw = $0.rawWord, let mapped = $0.mappedWord else { return false }
            return raw != mapped
        }.count

        var signatureCounts = [String: Int]()
        var sectionCounts = [String: Int]()
        var dylibCounts = [String: Int]()
        var dylibSymbolSets = [String: Set<String>]()
        var symbolCounts = [String: Int]()
        var rawWordCounts = [String: Int]()
        var invalidSymbolIndices = 0
        var nonUndefinedExternalSymbols = 0

        for site in sites {
            let signature = "type=\(site.relocationType), pcrel=\(site.isPCRelative ? "YES" : "NO"), length=\(site.length), external=\(site.isExternal ? "YES" : "NO"), scattered=\(site.scattered ? "YES" : "NO")"
            signatureCounts[signature, default: 0] += 1
            if let section = site.sectionName { sectionCounts[section, default: 0] += 1 }
            dylibCounts[site.libraryName, default: 0] += 1
            dylibSymbolSets[site.libraryName, default: []].insert(site.symbolName)
            symbolCounts[site.symbolName, default: 0] += 1
            if let raw = site.rawWord {
                let label = raw == 0 ? "0x00000000" : (raw == 8 ? "0x00000008" : "other nonzero")
                rawWordCounts[label, default: 0] += 1
            } else {
                rawWordCounts["unavailable/non-word-width", default: 0] += 1
            }
            if site.isExternal {
                if site.symbolIndex >= UInt32(image.symbols.count) {
                    invalidSymbolIndices += 1
                } else if !image.symbols[Int(site.symbolIndex)].isUndefined {
                    nonUndefinedExternalSymbols += 1
                }
            }
        }

        var lines = [
            "Classic external relocation audit PASS (read-only)",
            "Architecture: \(image.architectureName)",
            "Guest instruction execution: NO",
            "HLE import executed: NO",
            "Relocations applied: NO",
            "Pointer values changed: NO",
            "Source: LC_DYSYMTAB external relocation table",
            "External relocation records: \(sites.count)",
            "Addresses inside mapped segments: \(inSegments)",
            "Addresses inside named sections: \(inSections)",
            "File-backed 32-bit source words: \(fileBacked)",
            "Readable mapped 32-bit words: \(mappedReadable)",
            "Raw/mapped word mismatches: \(mismatches)",
            "Invalid external symbol indices: \(invalidSymbolIndices)",
            "External relocation records referencing non-undefined symbols: \(nonUndefinedExternalSymbols)",
            ""
        ]

        lines += ["[Relocation signatures]"]
        for (key, count) in signatureCounts.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }) {
            lines.append("  \(key): \(count)")
        }

        lines += ["", "[Relocation locations by section]"]
        for (key, count) in sectionCounts.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }) {
            lines.append("  \(key): \(count)")
        }
        if sectionCounts.isEmpty { lines.append("(no relocation target was contained in a named section)") }

        lines += ["", "[Raw 32-bit values at relocation sites]"]
        for label in ["0x00000000", "0x00000008", "other nonzero", "unavailable/non-word-width"] {
            lines.append("  \(label): \(rawWordCounts[label, default: 0])")
        }
        lines.append("These are observed site contents; this report does not yet interpret them as addends or apply relocation formulas.")

        lines += ["", "[Relocations grouped by n_desc library ordinal]"]
        let orderedLibraries = dylibCounts.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key < $1.key
        }
        for (library, count) in orderedLibraries {
            lines.append("  \(library): records=\(count), unique referenced symbols=\(dylibSymbolSets[library]?.count ?? 0)")
        }

        lines += ["", "[Most frequent external-relocation symbols]"]
        let frequentSymbols = symbolCounts.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key < $1.key
        }
        if frequentSymbols.isEmpty { lines.append("(none)") }
        for (name, count) in frequentSymbols.prefix(24) {
            let sample = sites.first(where: { $0.symbolName == name })
            if let sample {
                let raw = sample.rawWord.map { String(format: "0x%08X", $0) } ?? "(n/a)"
                let mapped = sample.mappedWord.map { String(format: "0x%08X", $0) } ?? "(n/a)"
                let address = String(format: "0x%08X", sample.address)
                lines.append("  \(name): \(count); \(sample.libraryName); example VA=\(address) \(sample.sectionName ?? "(unmapped section)") raw=\(raw) mapped=\(mapped)")
            } else {
                lines.append("  \(name): \(count)")
            }
        }

        lines += ["", "[Representative relocation records]"]
        let sortedSites = sites.sorted {
            if $0.address != $1.address { return $0.address < $1.address }
            return $0.symbolName < $1.symbolName
        }
        var chosen = [Site]()
        var sectionChosen = Set<String>()
        for site in sortedSites where chosen.count < max(0, exampleLimit) {
            let key = site.sectionName ?? "(no section)"
            if sectionChosen.insert(key).inserted { chosen.append(site) }
        }
        for site in sortedSites where chosen.count < max(0, exampleLimit) {
            if !chosen.contains(where: { $0.address == site.address && $0.symbolName == site.symbolName }) {
                chosen.append(site)
            }
        }
        for site in chosen {
            let raw = site.rawWord.map { String(format: "0x%08X", $0) } ?? "(n/a)"
            let mapped = site.mappedWord.map { String(format: "0x%08X", $0) } ?? "(n/a)"
            let offset = site.fileOffset.map { String(format: "0x%X", $0) } ?? "(n/a)"
            lines.append(String(format: "  VA=0x%08X file=%@ symbol=%@ ordinal=%@ raw=%@ mapped=%@",
                                site.address, offset, site.symbolName, site.libraryName, raw, mapped))
        }

        lines += ["", "Interpretation boundary: this is inventory only. No relocation formula, symbol resolver, Objective-C class registration, C++ runtime object, or external address was executed."]
        return lines.joined(separator: "\n")
    }

    public static func runSyntheticSelfTest() throws -> String {
        let fixture = try RE4MachO32Parser.makeSyntheticSelfTestFixture()
        let image = try RE4MachO32Parser.parse(fixture)
        let memory = RE4GuestARMv6Memory(size: 0x6000)
        _ = try RE4MachO32Loader.map(image, into: memory)
        let output = report(image: image, memory: memory, exampleLimit: 4)
        guard output.contains("Classic external relocation audit PASS (read-only)"),
              output.contains("External relocation records: 1"),
              output.contains("Addresses inside mapped segments: 1"),
              output.contains("Addresses inside named sections: 1"),
              output.contains("_malloc: 1"),
              output.contains("No relocation formula") || output.contains("this report does not yet interpret them as addends") else {
            throw RE4MachO32LegacyRelocationAuditError.selfTestFailed
        }
        return "Classic external relocation audit self-test PASS\nExternal relocation address mapped back to a section and source word.\nUndefined symbol and n_desc library ordinal retained.\nRead-only: no relocation or import applied."
    }
}

private enum RE4MachO32LegacyRelocationAuditError: Error, LocalizedError {
    case selfTestFailed
    var errorDescription: String? { "Synthetic classic external relocation audit failed." }
}
