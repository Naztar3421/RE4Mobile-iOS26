import Foundation

public protocol RE4GuestMemoryMapping: AnyObject {
    var size: Int { get }
    func copyBytes(at guestAddress: UInt32, count: Int) throws -> Data
    func writeBytes(at guestAddress: UInt32, data: Data) throws
    func zeroBytes(at guestAddress: UInt32, count: Int) throws
}
public enum RE4MachO32LoaderError: Error, LocalizedError {
    case noEntryPoint, entryPointNotExecutable(UInt32)
    case invalidFileRange(segment: String), invalidMemoryRange(segment: String)
    public var errorDescription: String? {
        switch self {
        case .noEntryPoint: return "Mach-O has no supported executable entry point."
        case .entryPointNotExecutable(let pc): return String(format:"Entry PC 0x%08X is not in an executable segment.",pc)
        case .invalidFileRange(let s): return "File range for segment \(s) is outside the selected Mach-O slice."
        case .invalidMemoryRange(let s): return "Guest memory range for segment \(s) is invalid."
        }
    }
}
public struct RE4MachO32MappedSegment {
    public let name: String
    public let vmAddress: UInt32
    public let vmSize: UInt32
    public let fileOffset: UInt32
    public let fileSize: UInt32
    public let zeroFillBytes: UInt64
    public let initialProtection: Int32
}
public struct RE4MachO32MapResult {
    public let architectureName: String
    public let entryPoint: UInt32
    public let segments: [RE4MachO32MappedSegment]
    public let requiredMemorySize: UInt64
    public let fileBytesCopied: UInt64
    public let zeroFillBytes: UInt64
    public let undefinedImportCount: Int
    public let dependencyCount: Int
    public let relocationCount: Int
    public let bindRecordCount: Int
    public var report: String {
        var lines = [
            "Mach-O segment mapping PASS",
            "Architecture: \(architectureName)",
            String(format:"Entry PC: 0x%08X",entryPoint),
            String(format:"Lowest guest memory size required: 0x%llX",requiredMemorySize),
            "Mapped segments: \(segments.count)",
            "File-backed bytes copied: \(fileBytesCopied)",
            "Zero-fill bytes initialized: \(zeroFillBytes)",
            "Undefined imports pending HLE/bind: \(undefinedImportCount)",
            "Dylib dependencies (not loaded): \(dependencyCount)",
            "Section relocations (not applied): \(relocationCount)",
            "dyld bind records (not applied): \(bindRecordCount)",
            "",
            "[Mapped segments]"
        ]
        for s in segments {
            lines.append(String(format:"%@ VM=0x%08X +0x%X file=0x%X +0x%X zero=0x%llX prot=%d",
                                s.name,s.vmAddress,s.vmSize,s.fileOffset,s.fileSize,s.zeroFillBytes,s.initialProtection))
        }
        lines += ["","No relocations, symbol binding, HLE, initializers, or guest instruction execution was performed."]
        return lines.joined(separator:"\n")
    }
}

/// Maps the validated segment VM ranges at their declared addresses; skips __PAGEZERO.
/// Protections are reported but not enforced; this does not apply relocations/binds or execute code.
public enum RE4MachO32Loader {
    public static func map(_ image: RE4MachO32Image, into memory: RE4GuestMemoryMapping) throws -> RE4MachO32MapResult {
        let plan = try image.makeLoadPlan(guestMemorySize: memory.size)
        guard let pc = plan.entryPoint else { throw RE4MachO32LoaderError.noEntryPoint }
        guard let text = plan.segments.first(where: {
            UInt64(pc) >= UInt64($0.vmAddress) && UInt64(pc) < UInt64($0.vmAddress) + UInt64($0.vmSize)
        }), (text.initialProtection & 4) != 0 else {
            throw RE4MachO32LoaderError.entryPointNotExecutable(pc)
        }

        // Validate all ranges before modifying guest memory.
        for s in plan.segments {
            let memEnd = UInt64(s.vmAddress) + UInt64(s.vmSize)
            let fileEnd = UInt64(s.fileOffset) + UInt64(s.fileSize)
            guard memEnd <= UInt64(memory.size), memEnd >= UInt64(s.vmAddress) else {
                throw RE4MachO32LoaderError.invalidMemoryRange(segment:s.name)
            }
            guard fileEnd <= UInt64(image.fileBytes.count), fileEnd >= UInt64(s.fileOffset),
                  s.fileSize <= s.vmSize else {
                throw RE4MachO32LoaderError.invalidFileRange(segment:s.name)
            }
        }

        var mapped:[RE4MachO32MappedSegment]=[]
        var copied:UInt64=0, zeroed:UInt64=0
        for s in plan.segments {
            try memory.zeroBytes(at:s.vmAddress,count:Int(s.vmSize))
            if s.fileSize > 0 {
                let start=Int(s.fileOffset), count=Int(s.fileSize)
                try memory.writeBytes(at:s.vmAddress,data:image.fileBytes.subdata(in:start..<(start+count)))
            }
            let tail=UInt64(s.vmSize)-UInt64(s.fileSize)
            copied += UInt64(s.fileSize); zeroed += tail
            mapped.append(RE4MachO32MappedSegment(
                name:s.name,vmAddress:s.vmAddress,vmSize:s.vmSize,fileOffset:s.fileOffset,
                fileSize:s.fileSize,zeroFillBytes:tail,initialProtection:s.initialProtection
            ))
        }
        return RE4MachO32MapResult(
            architectureName:image.architectureName,entryPoint:pc,segments:mapped,
            requiredMemorySize:plan.requiredMemorySize,fileBytesCopied:copied,zeroFillBytes:zeroed,
            undefinedImportCount:image.undefinedSymbols.count,dependencyCount:image.dependencies.count,
            relocationCount:image.relocations.count,bindRecordCount:image.bindRecords.count
        )
    }

    public static func runSyntheticSelfTest() throws -> String {
        let fixture=try RE4MachO32Parser.makeSyntheticSelfTestFixture()
        let image=try RE4MachO32Parser.parse(fixture)
        let memory=RE4MachO32MapperTestMemory(size:0x6000)
        try memory.writeBytes(at:0x3100,data:Data([0xA5]))
        let result=try map(image,into:memory)
        guard result.entryPoint==0x1270,
              result.segments.map(\.name)==["__TEXT","__DATA","__LINKEDIT"],
              result.fileBytesCopied==0x340,result.zeroFillBytes==0x2CC0 else {
            throw RE4MachO32LoaderTestError.failed("segment order, entry PC, or byte counts")
        }
        guard try memory.copyBytes(at:result.entryPoint,count:4)==Data([0x01,0x00,0xA0,0xE3]) else {
            throw RE4MachO32LoaderTestError.failed("entry instruction mapped to wrong address")
        }
        guard try memory.copyBytes(at:0x3100,count:1)==Data([0]) else {
            throw RE4MachO32LoaderTestError.failed("stale BSS/tail bytes were not cleared")
        }
        guard try memory.copyBytes(at:0x4000,count:4)==image.fileBytes.subdata(in:0x2C0..<0x2C4) else {
            throw RE4MachO32LoaderTestError.failed("__LINKEDIT offset mapping")
        }
        do {
            _=try map(image,into:RE4MachO32MapperTestMemory(size:0x4000))
            throw RE4MachO32LoaderTestError.failed("out-of-range memory plan accepted")
        } catch RE4MachO32Error.segmentOutOfBounds { }
          catch RE4MachO32LoaderTestError.failed(let why) where why=="out-of-range memory plan accepted" {
            throw RE4MachO32LoaderTestError.failed(why)
        }
        return "Mach-O segment mapper self-test PASS\nMapped __TEXT/__DATA/__LINKEDIT at guest VAs.\nEntry opcode verified at PC 0x00001270.\nFile-backed bytes: 0x340; zero-fill bytes: 0x2CC0.\nStale BSS/tail bytes cleared; __LINKEDIT file offsets preserved.\nOut-of-range memory plan rejected.\nNo game assets or original IPA used."
    }
}
private enum RE4MachO32LoaderTestError: Error { case failed(String) }
private final class RE4MachO32MapperTestMemory: RE4GuestMemoryMapping {
    let size:Int
    private var bytes:[UInt8]
    init(size:Int){self.size=size;self.bytes=[UInt8](repeating:0,count:size)}
    func copyBytes(at address:UInt32,count:Int)throws->Data{
        guard count>=0,UInt64(address)+UInt64(count)<=UInt64(size) else {
            throw RE4MachO32Error.syntheticSelfTestFailed("test read out of bounds")
        }
        return Data(bytes[Int(address)..<(Int(address)+count)])
    }
    func writeBytes(at address:UInt32,data:Data)throws{
        guard UInt64(address)+UInt64(data.count)<=UInt64(size) else {
            throw RE4MachO32Error.syntheticSelfTestFailed("test write out of bounds")
        }
        bytes.replaceSubrange(Int(address)..<(Int(address)+data.count),with:data)
    }
    func zeroBytes(at address:UInt32,count:Int)throws{
        guard count>=0,UInt64(address)+UInt64(count)<=UInt64(size) else {
            throw RE4MachO32Error.syntheticSelfTestFailed("test zero out of bounds")
        }
        for i in Int(address)..<(Int(address)+count){bytes[i]=0}
    }
}
