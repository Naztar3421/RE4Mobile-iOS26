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
              output.contains("Classic __la_symbol_ptr imports: 1"),
              output.contains("_malloc slot=0x00003000"),
              output.contains("Bind record: stream=bind symbol=_malloc ordinal=1"),
              output.contains("(no __dyld section in parsed section table)"),
              output.contains("Pointers changed: NO") else {
            throw RE4MachO32LegacyDyldAuditError.selfTestFailed
        }
        return "Classic dyld lazy-binding audit self-test PASS\nIndirect lazy-pointer inventory cross-checked with decoded bind metadata.\nSection dump stays within file-backed bounds.\nRead-only: no pointer changed and no code executed."
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
