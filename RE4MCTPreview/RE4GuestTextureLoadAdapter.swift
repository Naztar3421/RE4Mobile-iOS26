import Foundation
import Metal
import CryptoKit

/// Arguments saved at the original Load_Obj callsite; consume after the original guest function returns.
public struct RE4NativeLoadObjCallContext {
    public let guestObjectAddress: UInt32
    public let sourceMCTAddress: UInt32
    public let sourceMCTByteCount: Int
    public let resourceName: String
    public init(guestObjectAddress: UInt32, sourceMCTAddress: UInt32,
                sourceMCTByteCount: Int, resourceName: String) {
        self.guestObjectAddress = guestObjectAddress
        self.sourceMCTAddress = sourceMCTAddress
        self.sourceMCTByteCount = sourceMCTByteCount
        self.resourceName = resourceName
    }
}

public enum RE4GuestLoadObjAdapterError: Error, LocalizedError {
    case invalidContext, missingTextureTable, emptyTextureTable, invalidMCETexture
    case addressOverflow, unmappedMemory(address: UInt32, count: Int), capturedFixtureMismatch
    public var errorDescription: String? {
        switch self {
        case .invalidContext: return "Load_Obj return context has an invalid address or MCT byte count."
        case .missingTextureTable: return "Guest texture object has no MCE texture table."
        case .emptyTextureTable: return "Guest MCE texture table is empty."
        case .invalidMCETexture: return "Native MCE texture entry has invalid metadata."
        case .addressOverflow: return "Guest virtual address arithmetic overflowed UInt32."
        case .unmappedMemory(let a, let n): return String(format: "Guest memory 0x%08X (+%d bytes) is not mapped.", a, n)
        case .capturedFixtureMismatch: return "Imported MCT is not the known MVP-18 2d_fnt_00.mct capture."
        }
    }
}

/// Called after original ERP_Obj_Tex::Load_Obj returns. Offsets derive from the observed MVP-18
/// interpreter memory snapshot: object+4 -> table; table+0x28 -> count; table+0x2C -> pointer array;
/// first array entry -> MCE texture; MCE+44/+46 -> width/height; MCE+0x30 -> pixel format.
@MainActor
public final class RE4GuestTextureLoadAdapter {
    private let bridge: RE4GuestTextureUploadBridge
    public init(bridge: RE4GuestTextureUploadBridge) { self.bridge = bridge }

    @discardableResult
    public func didReturnFromNativeLoadObj(_ context: RE4NativeLoadObjCallContext,
                                           guestMemory: RE4GuestMemoryReading) throws -> MTLTexture {
        guard context.guestObjectAddress != 0, context.sourceMCTAddress != 0,
              context.sourceMCTByteCount > 0, context.sourceMCTByteCount <= 64 * 1024 * 1024 else {
            throw RE4GuestLoadObjAdapterError.invalidContext
        }
        let sourceMCT = try guestMemory.copyBytes(at: context.sourceMCTAddress, count: context.sourceMCTByteCount)
        guard sourceMCT.count == context.sourceMCTByteCount else { throw RE4GuestLoadObjAdapterError.invalidContext }

        let table = try read32(guestMemory, try add(context.guestObjectAddress, 4))
        guard table != 0 else { throw RE4GuestLoadObjAdapterError.missingTextureTable }
        guard try read16(guestMemory, try add(table, 0x28)) > 0 else {
            throw RE4GuestLoadObjAdapterError.emptyTextureTable
        }
        let array = try read32(guestMemory, try add(table, 0x2C))
        guard array != 0 else { throw RE4GuestLoadObjAdapterError.emptyTextureTable }
        let mce = try read32(guestMemory, array)
        guard mce != 0 else { throw RE4GuestLoadObjAdapterError.invalidMCETexture }

        let width = Int(try read16(guestMemory, try add(mce, 44)))
        let height = Int(try read16(guestMemory, try add(mce, 46)))
        let format = try read32(guestMemory, try add(mce, 0x30))
        let mipCount = try read8(guestMemory, try add(mce, 0x36))
        let dataAddress = try read32(guestMemory, try add(mce, 0x68))
        let dataSize = try read32(guestMemory, try add(mce, 0x6C))
        guard width > 0, height > 0, format > 0, mipCount > 0, dataAddress != 0, dataSize > 0 else {
            throw RE4GuestLoadObjAdapterError.invalidMCETexture
        }

        return try bridge.registerCompletedNativeLoad(RE4NativeGuestTextureSnapshot(
            guestObjectAddress: context.guestObjectAddress,
            guestMceTextureAddress: mce,
            name: context.resourceName,
            sourceMCTBytes: sourceMCT,
            nativeWidth: width,
            nativeHeight: height,
            nativePixelFormat: format
        ))
    }

    public func guestObjectDestroyed(_ address: UInt32) { bridge.guestObjectDestroyed(address) }

    private func add(_ base: UInt32, _ offset: UInt32) throws -> UInt32 {
        let (v, overflow) = base.addingReportingOverflow(offset)
        guard !overflow else { throw RE4GuestLoadObjAdapterError.addressOverflow }
        return v
    }
    private func read8(_ m: RE4GuestMemoryReading, _ a: UInt32) throws -> UInt8 {
        let b = [UInt8](try m.copyBytes(at: a, count: 1))
        guard b.count == 1 else { throw RE4GuestLoadObjAdapterError.unmappedMemory(address: a, count: 1) }
        return b[0]
    }
    private func read16(_ m: RE4GuestMemoryReading, _ a: UInt32) throws -> UInt16 {
        let b = [UInt8](try m.copyBytes(at: a, count: 2))
        guard b.count == 2 else { throw RE4GuestLoadObjAdapterError.unmappedMemory(address: a, count: 2) }
        return UInt16(b[0]) | (UInt16(b[1]) << 8)
    }
    private func read32(_ m: RE4GuestMemoryReading, _ a: UInt32) throws -> UInt32 {
        let b = [UInt8](try m.copyBytes(at: a, count: 4))
        guard b.count == 4 else { throw RE4GuestLoadObjAdapterError.unmappedMemory(address: a, count: 4) }
        return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
    }
}

/// Sparse captured memory for testing the adapter contract; this is not a live emulator.
public final class RE4CapturedGuestMemoryReplay: RE4GuestMemoryReading {
    private var bytes: [UInt32: UInt8] = [:]
    public init() {}
    public func writeBytes(at address: UInt32, data: Data) throws {
        guard !data.isEmpty else { return }
        let end = UInt64(address) + UInt64(data.count) - 1
        guard address != 0, end <= UInt64(UInt32.max) else { throw RE4GuestLoadObjAdapterError.addressOverflow }
        for (i, b) in data.enumerated() { bytes[address &+ UInt32(i)] = b }
    }
    public func copyBytes(at address: UInt32, count: Int) throws -> Data {
        guard count >= 0, count <= 64 * 1024 * 1024 else { throw RE4GuestLoadObjAdapterError.invalidContext }
        if count == 0 { return Data() }
        let end = UInt64(address) + UInt64(count) - 1
        guard address != 0, end <= UInt64(UInt32.max) else { throw RE4GuestLoadObjAdapterError.addressOverflow }
        var result = [UInt8](); result.reserveCapacity(count)
        for i in 0..<count {
            let current = address &+ UInt32(i)
            guard let b = bytes[current] else {
                throw RE4GuestLoadObjAdapterError.unmappedMemory(address: current, count: 1)
            }
            result.append(b)
        }
        return Data(result)
    }
    public func write8(_ value: UInt8, at a: UInt32) throws {
        try writeBytes(at: a, data: Data([value]))
    }
    public func write16(_ value: UInt16, at a: UInt32) throws {
        try writeBytes(at: a, data: Data([UInt8(value & 0xFF), UInt8(value >> 8)]))
    }
    public func write32(_ value: UInt32, at a: UInt32) throws {
        try writeBytes(at: a, data: Data([
            UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)
        ]))
    }
}

/// Reconstructs only the memory fields in the observed MVP-18 capture. It accepts no other MCT.
public enum RE4CapturedMVP18LoadObjReplay {
    public static let mctSHA256 = "4d59a527c44bc8b3a701eeae778564d169cf4e88d7ffa97b0161c8c6c124d00d"
    public static let mctByteCount = 17_450
    public static let guestObject: UInt32 = 0x0310_3100
    public static let mctInput: UInt32 = 0x0310_95B8
    public static let textureTable: UInt32 = 0x0311_1E70
    public static let textureArray: UInt32 = 0x0311_1EA0
    public static let appearance: UInt32 = 0x0311_1EB0
    public static let mceTexture: UInt32 = 0x0310_DA00
    public static let level0Data: UInt32 = 0x0310_DB70

    public static func make(sourceMCT: Data) throws -> (memory: RE4CapturedGuestMemoryReplay, context: RE4NativeLoadObjCallContext) {
        let hash = SHA256.hash(data: sourceMCT).map { String(format: "%02x", $0) }.joined()
        guard sourceMCT.count == mctByteCount, hash == mctSHA256 else {
            throw RE4GuestLoadObjAdapterError.capturedFixtureMismatch
        }
        let m = RE4CapturedGuestMemoryReplay()
        try m.writeBytes(at: mctInput, data: sourceMCT)
        try m.write32(textureTable, at: guestObject &+ 4)
        try m.write32(appearance, at: guestObject &+ 8)
        try m.write16(1, at: textureTable &+ 0x28)
        try m.write32(textureArray, at: textureTable &+ 0x2C)
        try m.write32(mceTexture, at: textureArray)
        try m.write16(128, at: mceTexture &+ 44)
        try m.write16(128, at: mceTexture &+ 46)
        try m.write32(7, at: mceTexture &+ 0x30)
        try m.write8(1, at: mceTexture &+ 0x36)
        try m.write32(level0Data, at: mceTexture &+ 0x68)
        try m.write32(17_152, at: mceTexture &+ 0x6C)
        let context = RE4NativeLoadObjCallContext(
            guestObjectAddress: guestObject, sourceMCTAddress: mctInput,
            sourceMCTByteCount: mctByteCount, resourceName: "2d_fnt_00.mct"
        )
        return (m, context)
    }
}
