import Foundation

/// Read-only inventory for classic dyld helper/lazy-symbol-pointer state.
/// It deliberately does not invoke the helper, patch a pointer, or emulate dyld.
public enum RE4MachO32LegacyDyldAudit {
    private struct SlotState {
        let item: RE4MachO32IndirectImport
        let fileOffset: UInt32?
        let rawWord: UInt32?
        let mappedWord: UInt32
        let bindRecords: [RE4MachO32BindRecord]
    }

    private static func readWord(_ data: Data) -> UInt32? {
        guard data.count == 4 else { return nil }
        let b = [UInt8](data)
        return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
    }

    private static func readWord(_ data: Data, offset: UInt64) -> UInt32? {
        guard offset + 4 <= UInt64(data.count), offset <= UInt64(Int.max) else { return nil }
        return readWord(data.subdata(in: Int(offset)..<(Int(offset) + 4)))
    }

    private static func sourceWord(_ address: UInt32, image: RE4MachO32Image) -> (UInt32?, UInt32?) {
        for segment in image.segments where !segment.isPageZero {
            guard UInt64(address) >= UInt64(segment.vmAddress) else { continue }
            let delta = UInt64(address) - UInt64(segment.vmAddress)
            guard delta + 4 <= UInt64(segment.fileSize) else { continue }
            let offset = UInt64(segment.fileOffset) + delta
            guard offset + 4 <= UInt64(image.fileBytes.count), offset <= UInt64(UInt32.max) else { continue }
            return (UInt32(offset), readWord(image.fileBytes, offset: offset))
        }
        return (nil, nil)
    }

    private static func isImageAddress(_ address: UInt32, image: RE4MachO32Image) -> Bool {
        image.segments.contains { segment in
            !segment.isPageZero &&
            UInt64(address) >= UInt64(segment.vmAddress) &&
            UInt64(address) < UInt64(segment.vmAddress) + UInt64(segment.vmSize)
        }
    }

    private static func slotState(_ item: RE4MachO32IndirectImport,
                                  image: RE4MachO32Image,
                                  memory: RE4GuestMemoryReading) throws -> SlotState {
        guard let mappedWord = readWord(try memory.copyBytes(at: item.slotAddress, count: 4)) else {
            throw RE4MachO32LegacyDyldAuditError.badRead(item.slotAddress)
        }
        let (fileOffset, rawWord) = sourceWord(item.slotAddress, image: image)
        return SlotState(item: item, fileOffset: fileOffset, rawWord: rawWord,
                         mappedWord: mappedWord,
                         bindRecords: image.bindRecords.filter { $0.vmAddress == item.slotAddress })
    }


    private struct SymtabInfo {
        let symoff: UInt32; let nsyms: UInt32; let stroff: UInt32; let strsize: UInt32
    }
    private struct DysymtabInfo {
        let ilocalsym: UInt32; let nlocalsym: UInt32
        let iextdefsym: UInt32; let nextdefsym: UInt32
        let iundefsym: UInt32; let nundefsym: UInt32
        let tocoff: UInt32; let ntoc: UInt32
        let modtaboff: UInt32; let nmodtab: UInt32
        let extrefsymoff: UInt32; let nextrefsyms: UInt32
        let indirectsymoff: UInt32; let nindirectsyms: UInt32
        let extreloff: UInt32; let nextrel: UInt32
        let locreloff: UInt32; let nlocrel: UInt32
    }
    private struct DyldInfo {
        let command: UInt32
        let rebaseOff: UInt32; let rebaseSize: UInt32
        let bindOff: UInt32; let bindSize: UInt32
        let weakOff: UInt32; let weakSize: UInt32
        let lazyOff: UInt32; let lazySize: UInt32
        let exportOff: UInt32; let exportSize: UInt32
    }
    private struct LoadCommandInventory {
        let symtab: SymtabInfo?
        let dysymtab: DysymtabInfo?
        let dyldInfos: [DyldInfo]
        let commandCount: UInt32
    }

    /// Parse only classic binding-related load-command fields from the selected thin slice.
    /// This does not apply fixups or interpret any external address as callable.
    private static func loadCommandInventory(_ data: Data) -> LoadCommandInventory? {
        guard readWord(data, offset: 0) == 0xFEEDFACE,
              let commandCount = readWord(data, offset: 16),
              let commandBytes = readWord(data, offset: 20),
              commandCount <= 16_384 else { return nil }
        let commandEnd64 = UInt64(28) + UInt64(commandBytes)
        guard commandEnd64 <= UInt64(data.count) else { return nil }
        let commandEnd = Int(commandEnd64)
        var position = 28
        var symtab: SymtabInfo?
        var dysymtab: DysymtabInfo?
        var dyldInfos = [DyldInfo]()

        func word(_ offset: Int) -> UInt32? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            return readWord(data, offset: UInt64(offset))
        }

        for _ in 0..<Int(commandCount) {
            guard position + 8 <= commandEnd,
                  let command = word(position),
                  let size = word(position + 4),
                  size >= 8, size % 4 == 0,
                  UInt64(position) + UInt64(size) <= UInt64(commandEnd) else { return nil }
            let end = position + Int(size)
            if command == 0x2, size >= 24 {
                guard let a = word(position + 8), let b = word(position + 12),
                      let c = word(position + 16), let d = word(position + 20) else { return nil }
                symtab = SymtabInfo(symoff: a, nsyms: b, stroff: c, strsize: d)
            } else if command == 0xB, size >= 80 {
                let values = (0..<18).compactMap { word(position + 8 + $0 * 4) }
                guard values.count == 18 else { return nil }
                dysymtab = DysymtabInfo(
                    ilocalsym: values[0], nlocalsym: values[1],
                    iextdefsym: values[2], nextdefsym: values[3],
                    iundefsym: values[4], nundefsym: values[5],
                    tocoff: values[6], ntoc: values[7],
                    modtaboff: values[8], nmodtab: values[9],
                    extrefsymoff: values[10], nextrefsyms: values[11],
                    indirectsymoff: values[12], nindirectsyms: values[13],
                    extreloff: values[14], nextrel: values[15],
                    locreloff: values[16], nlocrel: values[17]
                )
            } else if (command == 0x22 || command == 0x80000022), size >= 48 {
                let values = (0..<10).compactMap { word(position + 8 + $0 * 4) }
                guard values.count == 10 else { return nil }
                dyldInfos.append(DyldInfo(
                    command: command,
                    rebaseOff: values[0], rebaseSize: values[1],
                    bindOff: values[2], bindSize: values[3],
                    weakOff: values[4], weakSize: values[5],
                    lazyOff: values[6], lazySize: values[7],
                    exportOff: values[8], exportSize: values[9]
                ))
            }
            position = end
        }
        guard position == commandEnd else { return nil }
        return LoadCommandInventory(symtab: symtab, dysymtab: dysymtab,
                                    dyldInfos: dyldInfos, commandCount: commandCount)
    }

    private static func appendBindingMetadata(_ inventory: LoadCommandInventory?,
                                              image: RE4MachO32Image,
                                              lines: inout [String]) {
        lines += ["", "[Classic binding load-command inventory]"]
        guard let inventory else {
            lines.append("Could not safely parse binding-related load commands from this image slice.")
            return
        }
        lines.append("Load commands parsed: \(inventory.commandCount)")
        if let sym = inventory.symtab {
            lines.append(String(format: "LC_SYMTAB symoff=0x%X nsyms=%u stroff=0x%X strsize=0x%X",
                                sym.symoff, sym.nsyms, sym.stroff, sym.strsize))
            let symbolEnd = UInt64(sym.symoff) + UInt64(sym.nsyms) * 12
            let stringEnd = UInt64(sym.stroff) + UInt64(sym.strsize)
            lines.append("  symbol/string table file bounds: \(symbolEnd <= UInt64(image.fileBytes.count) && stringEnd <= UInt64(image.fileBytes.count) ? "IN RANGE" : "OUT OF RANGE")")
        } else {
            lines.append("LC_SYMTAB: absent")
        }
        if let dysym = inventory.dysymtab {
            lines.append(String(format: "LC_DYSYMTAB indirectsymoff=0x%X nindirectsyms=%u", dysym.indirectsymoff, dysym.nindirectsyms))
            lines.append(String(format: "  external relocations: off=0x%X count=%u; local relocations: off=0x%X count=%u",
                                dysym.extreloff, dysym.nextrel, dysym.locreloff, dysym.nlocrel))
            lines.append(String(format: "  symbol partitions: local=%u, defined-external=%u, undefined-external=%u",
                                dysym.nlocalsym, dysym.nextdefsym, dysym.nundefsym))
            let indirectEnd = UInt64(dysym.indirectsymoff) + UInt64(dysym.nindirectsyms) * 4
            let extEnd = UInt64(dysym.extreloff) + UInt64(dysym.nextrel) * 8
            let localEnd = UInt64(dysym.locreloff) + UInt64(dysym.nlocrel) * 8
            lines.append("  indirect-symbol table bounds: \(indirectEnd <= UInt64(image.fileBytes.count) ? "IN RANGE" : "OUT OF RANGE")")
            lines.append("  external relocation table bounds: \(extEnd <= UInt64(image.fileBytes.count) ? "IN RANGE" : "OUT OF RANGE")")
            lines.append("  local relocation table bounds: \(localEnd <= UInt64(image.fileBytes.count) ? "IN RANGE" : "OUT OF RANGE")")
            lines.append("  parser cross-checks: indirect imports=\(image.indirectImports.count), external relocations=\(image.dynamicExternalRelocations.count), local relocations=\(image.dynamicLocalRelocations.count)")
        } else {
            lines.append("LC_DYSYMTAB: absent")
        }
        if inventory.dyldInfos.isEmpty {
            lines.append("LC_DYLD_INFO / LC_DYLD_INFO_ONLY: absent")
        } else {
            for (index, info) in inventory.dyldInfos.enumerated() {
                let commandName = info.command == 0x22 ? "LC_DYLD_INFO" : "LC_DYLD_INFO_ONLY"
                lines.append(String(format: "%@[%u] rebase off=0x%X size=0x%X; bind off=0x%X size=0x%X",
                                    commandName, UInt32(index), info.rebaseOff, info.rebaseSize, info.bindOff, info.bindSize))
                lines.append(String(format: "  weak-bind off=0x%X size=0x%X; lazy-bind off=0x%X size=0x%X; export off=0x%X size=0x%X",
                                    info.weakOff, info.weakSize, info.lazyOff, info.lazySize, info.exportOff, info.exportSize))
            }
        }
        let totalBindOpcodeBytes = inventory.dyldInfos.reduce(UInt64(0)) {
            $0 + UInt64($1.bindSize) + UInt64($1.weakSize) + UInt64($1.lazySize)
        }
        lines.append("Total bind/weak/lazy opcode bytes declared by LC_DYLD_INFO: \(totalBindOpcodeBytes)")
        if totalBindOpcodeBytes == 0, let dysym = inventory.dysymtab,
           dysym.nindirectsyms > 0, dysym.nextrel > 0, !image.indirectImports.isEmpty {
            lines.append("Format evidence: bind opcode streams are empty while LC_DYSYMTAB indirect-symbol and external-relocation tables are populated.")
            lines.append("Interpretation: consistent with the classic symbol/relocation metadata path; no dyld bind opcodes were available to decode.")
        }
        lines += ["", "[LC_DYSYMTAB external relocation summary]"]
        lines.append("Parsed external relocations: \(image.dynamicExternalRelocations.count)")
        var typeCounts = [UInt8: Int]()
        for relocation in image.dynamicExternalRelocations { typeCounts[relocation.type, default: 0] += 1 }
        for type in typeCounts.keys.sorted() {
            lines.append(String(format: "  relocation type=%u count=%d", UInt32(type), typeCounts[type] ?? 0))
        }
        let namedRelocs = image.dynamicExternalRelocations.filter { $0.isExternal && $0.symbolName != nil }
        let symbolCounts = Dictionary(grouping: namedRelocs, by: { $0.symbolName ?? "" }).mapValues { $0.count }
        lines += ["", "[Most frequent external-relocation symbols]"]
        let frequent = symbolCounts.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key < $1.key
        }
        if frequent.isEmpty { lines.append("(no named external relocation symbols)") }
        for (name, count) in frequent.prefix(24) {
            lines.append("  \(name): \(count)")
        }
        lines += ["", "[Indirect-import sections by kind]"]
        let sectionGroups = Dictionary(grouping: image.indirectImports, by: { "\($0.sectionName) type=\($0.sectionType)" })
        for key in sectionGroups.keys.sorted() {
            lines.append("  \(key): \(sectionGroups[key]?.count ?? 0)")
        }
    }

    public static func report(image: RE4MachO32Image,
                              memory: RE4GuestMemoryReading,
                              dyldSectionWordLimit: Int = 16,
                              lazySlotLimit: Int = 40) throws -> String {
        let helperSymbols = image.symbols.filter {
            !$0.isUndefined && $0.name == "dyld_stub_binding_helper"
        }
        let dyldSections = image.segments.flatMap { segment in
            segment.sections.filter { $0.name == "__dyld" || ($0.segmentName == "__DATA" && $0.name == "__dyld") }
        }
        let lazyImports = image.indirectImports
            .filter { $0.sectionType == 7 }
            .sorted {
                let priority: (String) -> Int = {
                    switch $0 {
                    case "_objc_msgSend": return 0
                    case "_UIApplicationMain": return 1
                    default: return 2
                    }
                }
                if priority($0.symbolName) != priority($1.symbolName) {
                    return priority($0.symbolName) < priority($1.symbolName)
                }
                if $0.slotAddress != $1.slotAddress { return $0.slotAddress < $1.slotAddress }
                return $0.symbolName < $1.symbolName
            }

        let states = try lazyImports.map { try slotState($0, image: image, memory: memory) }
        let helperCount = states.filter { $0.mappedWord == 0x00008DD0 }.count
        let zeroCount = states.filter { $0.mappedWord == 0 }.count
        let otherCount = states.count - helperCount - zeroCount
        let recordsByStream = Dictionary(grouping: image.bindRecords, by: \.stream)

        var lines = [
            "Classic dyld lazy-binding audit PASS (read-only)",
            "Guest execution performed: NO",
            "dyld helper invoked: NO",
            "Pointers changed: NO",
            "dyld stub binding helper symbols: \(helperSymbols.count)"
        ]
        for symbol in helperSymbols.prefix(8) {
            lines.append(String(format: "  %@ value=0x%08X", symbol.name, symbol.value))
        }
        lines += [
            "Classic __la_symbol_ptr imports: \(lazyImports.count)",
            "Mapped lazy slots pointing to 0x00008DD0: \(helperCount)",
            "Mapped lazy slots equal to zero: \(zeroCount)",
            "Mapped lazy slots with another value: \(otherCount)",
            "Decoded dyld bind records: \(image.bindRecords.count)",
            "  bind=\(recordsByStream["bind"]?.count ?? 0); weak=\(recordsByStream["weak"]?.count ?? 0); lazy=\(recordsByStream["lazy"]?.count ?? 0)",
            ""
        ]

        appendBindingMetadata(loadCommandInventory(image.fileBytes), image: image, lines: &lines)
        lines.append("[__DATA,__dyld section contents]")
        if dyldSections.isEmpty {
            lines.append("(no __dyld section in parsed section table)")
        } else {
            for section in dyldSections {
                lines.append(String(format: "Section %@,%@ address=0x%08X size=0x%X fileOffset=0x%X type=%u",
                                    section.segmentName, section.name, section.address, section.size,
                                    section.fileOffset, section.type))
                let wordLimit = min(max(0, dyldSectionWordLimit), Int((section.size + 3) / 4))
                if wordLimit == 0 {
                    lines.append("  (empty section)")
                }
                for index in 0..<wordLimit {
                    let delta = UInt64(index) * 4
                    let address64 = UInt64(section.address) + delta
                    let file64 = UInt64(section.fileOffset) + delta
                    guard address64 <= UInt64(UInt32.max), delta + 4 <= UInt64(section.size) else { continue }
                    let address = UInt32(address64)
                    let raw = readWord(image.fileBytes, offset: file64)
                    let mapped = readWord(try memory.copyBytes(at: address, count: 4))
                    if let raw, let mapped {
                        lines.append(String(format: "  +0x%X VA=0x%08X file=0x%X raw=0x%08X mapped=0x%08X",
                                            delta, address, file64, raw, mapped))
                        if !isImageAddress(mapped, image: image) && mapped != 0 {
                            lines.append("    loaded word points outside the executable's mapped image segments; target identity is not inferred.")
                        }
                    } else {
                        lines.append(String(format: "  +0x%X VA=0x%08X raw/mapped word unavailable", delta, address))
                    }
                }
            }
        }

        lines += ["", "[Classic lazy symbol-pointer slots]"]
        if lazyImports.isEmpty {
            lines.append("(none found from indirect-symbol metadata)")
        } else {
            let selected: [SlotState]
            if states.count <= max(0, lazySlotLimit) {
                selected = states
            } else {
                let keyNames: Set<String> = ["_objc_msgSend", "_UIApplicationMain"]
                let important = states.filter { keyNames.contains($0.item.symbolName) }
                let other = states.filter { !keyNames.contains($0.item.symbolName) }
                selected = Array((important + other).prefix(max(max(0, lazySlotLimit), important.count)))
            }
            for state in selected {
                let source = state.fileOffset.map { String(format: "0x%X", $0) } ?? "(no file-backed word)"
                let raw = state.rawWord.map { String(format: "0x%08X", $0) } ?? "(n/a)"
                lines.append(String(format: "%@ slot=0x%08X type=%u file=%@ raw=%@ mapped=0x%08X",
                                    state.item.symbolName, state.item.slotAddress,
                                    state.item.sectionType, source, raw, state.mappedWord))
                if state.mappedWord == 0x00008DD0 {
                    lines.append("  State: points to in-image dyld_stub_binding_helper (classic lazy-resolution path).")
                } else if !isImageAddress(state.mappedWord, image: image) && state.mappedWord != 0 {
                    lines.append("  State: target lies outside this image; not invoked by this report.")
                }
                if state.bindRecords.isEmpty {
                    lines.append("  Dyld bind opcode record at this exact slot: none decoded.")
                } else {
                    for record in state.bindRecords.prefix(4) {
                        lines.append("  Bind record: stream=\(record.stream) symbol=\(record.symbolName) ordinal=\(record.dylibOrdinal)")
                    }
                }
            }
            if selected.count < states.count {
                lines.append("… \(states.count - selected.count) additional lazy slots omitted from detail listing; counts above include all slots.")
            }
        }

        lines += [
            "",
            "[Interpretation]",
            "The lazy slots that still contain 0x00008DD0 are expected to enter the image's classic dyld_stub_binding_helper before first-call resolution.",
            "That helper consults the image's __DATA,__dyld state and may transfer control outside the game image. This audit reports bytes and metadata only; it does not execute the helper or treat an external target as callable."
        ]
        return lines.joined(separator: "\n")
    }

    public static func runSyntheticSelfTest() throws -> String {
        let fixture = try RE4MachO32Parser.makeSyntheticSelfTestFixture()
        let image = try RE4MachO32Parser.parse(fixture)
        let memory = RE4GuestARMv6Memory(size: 0x6000)
        _ = try RE4MachO32Loader.map(image, into: memory)
        let output = try report(image: image, memory: memory, dyldSectionWordLimit: 4, lazySlotLimit: 4)
        guard output.contains("Classic dyld lazy-binding audit PASS"),
              output.contains("[Classic binding load-command inventory]"),
              output.contains("LC_SYMTAB symoff="),
              output.contains("LC_DYSYMTAB indirectsymoff="),
              output.contains("LC_DYLD_INFO[0]"),
              output.contains("Total bind/weak/lazy opcode bytes declared by LC_DYLD_INFO:"),
              output.contains("[LC_DYSYMTAB external relocation summary]"),
              output.contains("Classic __la_symbol_ptr imports: 1"),
              output.contains("_malloc slot=0x00003000"),
              output.contains("Bind record: stream=bind symbol=_malloc ordinal=1"),
              output.contains("(no __dyld section in parsed section table)"),
              output.contains("Pointers changed: NO") else {
            throw RE4MachO32LegacyDyldAuditError.selfTestFailed
        }
        return "Classic dyld lazy-binding audit self-test PASS\nLoad-command metadata and classic relocation tables cross-checked.\nIndirect lazy-pointer inventory cross-checked with decoded bind metadata.\nSection dump stays within file-backed bounds.\nRead-only: no pointer changed and no code executed."
    }
}

private enum RE4MachO32LegacyDyldAuditError: Error, LocalizedError {
    case selfTestFailed
    case badRead(UInt32)
    var errorDescription: String? {
        switch self {
        case .selfTestFailed: return "Synthetic classic dyld audit self-test failed."
        case .badRead(let address): return String(format: "Could not read lazy pointer slot at 0x%08X.", address)
        }
    }
}
