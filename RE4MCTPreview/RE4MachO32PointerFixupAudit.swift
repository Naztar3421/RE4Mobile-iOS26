import Foundation

public enum RE4MachO32PointerFixupAudit {
    private struct SlotRecord {
        let address: UInt32
        let mappedWord: UInt32
        let rawFileWord: UInt32?
        let fileOffset: UInt32?
        let segment: RE4MachO32Segment?
        let section: RE4MachO32Section?
        let indirect: RE4MachO32IndirectImport?
        let sectionRelocations: [RE4MachO32Relocation]
        let externalDynamicRelocations: [RE4MachO32Relocation]
        let localDynamicRelocations: [RE4MachO32Relocation]
        let dyldBinds: [RE4MachO32BindRecord]
    }

    private static func readWord(_ bytes: Data) -> UInt32? {
        guard bytes.count == 4 else { return nil }
        let b = [UInt8](bytes)
        return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
    }

    private static func makeRecord(_ address: UInt32, image: RE4MachO32Image,
                                   memory: RE4GuestARMv6Memory) throws -> SlotRecord {
        guard let mapped = readWord(try memory.copyBytes(at: address, count: 4)) else {
            throw RE4MachO32PointerFixupAuditError.badRead(address)
        }
        let segment = image.segments.first {
            !$0.isPageZero &&
            UInt64(address) >= UInt64($0.vmAddress) &&
            UInt64(address) + 4 <= UInt64($0.vmAddress) + UInt64($0.vmSize)
        }
        var fileOffset: UInt32?
        var rawFileWord: UInt32?
        if let segment,
           UInt64(address) - UInt64(segment.vmAddress) + 4 <= UInt64(segment.fileSize) {
            let offset64 = UInt64(segment.fileOffset) + UInt64(address) - UInt64(segment.vmAddress)
            if offset64 + 4 <= UInt64(image.fileBytes.count), offset64 <= UInt64(UInt32.max) {
                fileOffset = UInt32(offset64)
                rawFileWord = readWord(image.fileBytes.subdata(in: Int(offset64)..<(Int(offset64) + 4)))
            }
        }

        let section = image.segments.flatMap { $0.sections }.first {
            UInt64(address) >= UInt64($0.address) &&
            UInt64(address) + 4 <= UInt64($0.address) + UInt64($0.size)
        }
        let indirect = image.indirectImports.first { $0.slotAddress == address && !$0.isStub }
        let sectionRelocations = image.relocations.filter { relocation in
            guard let section else { return false }
            let relative = Int64(address) - Int64(section.address)
            return relocation.sectionName == section.name &&
                (Int64(relocation.address) == relative || Int64(relocation.address) == Int64(address))
        }
        func matchesAddress(_ relocation: RE4MachO32Relocation) -> Bool {
            let relocationAddress = Int64(relocation.address)
            let absolute = Int64(address)
            if relocationAddress == absolute { return true }
            if let section {
                return relocationAddress == absolute - Int64(section.address)
            }
            return false
        }
        let external = image.dynamicExternalRelocations.filter(matchesAddress)
        let local = image.dynamicLocalRelocations.filter(matchesAddress)
        let binds = image.bindRecords.filter { $0.vmAddress == address }

        return SlotRecord(
            address: address, mappedWord: mapped, rawFileWord: rawFileWord,
            fileOffset: fileOffset, segment: segment, section: section, indirect: indirect,
            sectionRelocations: sectionRelocations, externalDynamicRelocations: external,
            localDynamicRelocations: local, dyldBinds: binds
        )
    }

    private static func describe(_ slot: SlotRecord) -> [String] {
        var lines = [String(format: "Pointer slot 0x%08X", slot.address)]
        if let segment = slot.segment {
            lines.append(String(format: "  Segment: %@ (VM=0x%08X)", segment.name, segment.vmAddress))
        } else {
            lines.append("  Segment: not in a mapped segment")
        }
        if let section = slot.section {
            lines.append(String(format: "  Section: %@,%@ address=0x%08X size=0x%X type=%u reserved1=%u reserved2=%u",
                                section.segmentName, section.name, section.address, section.size,
                                section.type, section.reserved1, section.reserved2))
        } else {
            lines.append("  Section: no section contains this address")
        }
        if let fileOffset = slot.fileOffset, let raw = slot.rawFileWord {
            lines.append(String(format: "  Source file offset: 0x%X; raw file word: 0x%08X", fileOffset, raw))
        } else {
            lines.append("  Source file word: no file-backed bytes (zero-fill or unmapped)")
        }
        lines.append(String(format: "  Current mapped word: 0x%08X", slot.mappedWord))
        if let indirect = slot.indirect {
            lines.append("  Classic indirect symbol: \(indirect.symbolName), section type=\(indirect.sectionType)")
        } else {
            lines.append("  Classic indirect symbol: none at this exact slot")
        }
        lines.append("  Section relocations matching slot: \(slot.sectionRelocations.count)")
        for r in slot.sectionRelocations.prefix(4) {
            lines.append(String(format: "    %@ address=0x%08X type=%u external=%@ symbol=%@",
                                r.sectionName, UInt32(bitPattern: r.address), r.type,
                                r.isExternal ? "yes" : "no", r.symbolName ?? "(none)"))
        }
        lines.append("  LC_DYSYMTAB external relocations matching slot: \(slot.externalDynamicRelocations.count)")
        for r in slot.externalDynamicRelocations.prefix(4) {
            lines.append(String(format: "    address=0x%08X type=%u external=%@ symbol=%@",
                                UInt32(bitPattern: r.address), r.type,
                                r.isExternal ? "yes" : "no", r.symbolName ?? "(none)"))
        }
        lines.append("  LC_DYSYMTAB local relocations matching slot: \(slot.localDynamicRelocations.count)")
        lines.append("  dyld bind records matching slot: \(slot.dyldBinds.count)")
        for b in slot.dyldBinds.prefix(4) {
            lines.append("    \(b.symbolName) ordinal=\(b.dylibOrdinal) stream=\(b.stream)")
        }

        if slot.mappedWord == 0 {
            if slot.indirect != nil || !slot.sectionRelocations.isEmpty ||
                !slot.externalDynamicRelocations.isEmpty || !slot.localDynamicRelocations.isEmpty ||
                !slot.dyldBinds.isEmpty {
                lines.append("  Interpretation: zero has a known import/fixup-related record; do not treat it as a resolved null pointer.")
            } else {
                lines.append("  Interpretation: no matching fixup record was found in currently decoded tables; runtime role remains unknown.")
            }
        } else if let raw = slot.rawFileWord, raw != slot.mappedWord {
            lines.append("  Interpretation: mapped word differs from the raw file-backed word.")
        } else {
            lines.append("  Interpretation: mapped and raw file words agree; section semantics still determine whether a fixup is needed.")
        }
        return lines
    }

    public static func report(image: RE4MachO32Image, memory: RE4GuestARMv6Memory,
                              pointerSlotAddresses: [UInt32]) throws -> String {
        let unique = Array(Set(pointerSlotAddresses)).sorted()
        var lines = [
            "Mach-O pointer/fixup audit PASS (read-only)",
            "Section relocation records: \(image.relocations.count)",
            "LC_DYSYMTAB external relocation records: \(image.dynamicExternalRelocations.count)",
            "LC_DYSYMTAB local relocation records: \(image.dynamicLocalRelocations.count)",
            "dyld bind records: \(image.bindRecords.count)",
            "Slot addresses checked: \(unique.count)",
            "No pointer was changed; no guest instruction or HLE import executed.",
            ""
        ]
        for address in unique {
            lines += describe(try makeRecord(address, image: image, memory: memory))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// These slots were derived from the static control-flow report for the tested Res4 ARMv6 slice.
    /// If the executable changes, re-derive these addresses from its own static report.
    public static func auditKnownRes4Entry(image: RE4MachO32Image,
                                           memory: RE4GuestARMv6Memory) throws -> String {
        try report(image: image, memory: memory, pointerSlotAddresses: [0x001C13DC, 0x001C13E0])
    }

    public static func runSyntheticSelfTest() throws -> String {
        let fixture = try RE4MachO32Parser.makeSyntheticSelfTestFixture()
        let image = try RE4MachO32Parser.parse(fixture)
        let memory = RE4GuestARMv6Memory(size: 0x6000)
        _ = try RE4MachO32Loader.map(image, into: memory)
        let output = try report(image: image, memory: memory, pointerSlotAddresses: [0x3000])
        guard output.contains("raw file word: 0x00000000"),
              output.contains("Current mapped word: 0x00000000"),
              output.contains("Classic indirect symbol: _malloc"),
              output.contains("dyld bind records matching slot: 1"),
              output.contains("LC_DYSYMTAB external relocation records: 1"),
              output.contains("known import/fixup-related record") else {
            throw RE4MachO32PointerFixupAuditError.selfTestFailed
        }
        return "Mach-O pointer/fixup audit self-test PASS\nRaw file and mapped words compared.\nSection, indirect-symbol, LC_DYSYMTAB external/local relocation, and dyld bind sources cross-checked.\nZero import pointer is marked unresolved, not accepted as a valid target.\nRead-only: no pointer changed and no code executed."
    }
}

private enum RE4MachO32PointerFixupAuditError: Error, LocalizedError {
    case selfTestFailed
    case badRead(UInt32)
    var errorDescription: String? {
        switch self {
        case .selfTestFailed: return "Synthetic pointer/fixup audit self-test failed."
        case .badRead(let address): return String(format: "Could not read pointer slot 0x%08X.", address)
        }
    }
}
