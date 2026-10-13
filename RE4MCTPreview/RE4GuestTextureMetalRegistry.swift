import Foundation
import Metal
import CryptoKit

/// Guest addresses are 32-bit virtual addresses/tokens, never host pointers.
public struct RE4GuestTextureUploadRequest {
    public let guestObjectAddress: UInt32
    public let guestMceTextureAddress: UInt32
    public let width: Int
    public let height: Int
    public let rgba8: Data
    public let bytesPerRow: Int
    public let sourceMCTSHA256: String
    public let rgbaSHA256: String
    public let label: String

    public init(guestObjectAddress: UInt32,
                guestMceTextureAddress: UInt32,
                width: Int,
                height: Int,
                rgba8: Data,
                sourceMCTSHA256: String,
                rgbaSHA256: String,
                label: String) {
        self.guestObjectAddress = guestObjectAddress
        self.guestMceTextureAddress = guestMceTextureAddress
        self.width = width
        self.height = height
        self.rgba8 = rgba8
        self.bytesPerRow = width * 4
        self.sourceMCTSHA256 = sourceMCTSHA256
        self.rgbaSHA256 = rgbaSHA256
        self.label = label
    }
}

public enum RE4GuestTextureRegistryError: Error, LocalizedError {
    case invalidGuestAddress
    case invalidDimensions
    case invalidRGBAByteCount(expected: Int, actual: Int)
    case mceAddressAlreadyOwned(address: UInt32)
    case textureCreationFailed
    case textureUploadFailed

    public var errorDescription: String? {
        switch self {
        case .invalidGuestAddress:
            return "Guest object/MCE texture addresses must be non-zero."
        case .invalidDimensions:
            return "Guest texture dimensions are outside safe bounds."
        case .invalidRGBAByteCount(let expected, let actual):
            return "RGBA buffer mismatch: expected \(expected) bytes, got \(actual)."
        case .mceAddressAlreadyOwned(let address):
            return String(format: "Guest MCE texture address 0x%08X is already bound to another object.", address)
        case .textureCreationFailed:
            return "MTLDevice.makeTexture returned nil."
        case .textureUploadFailed:
            return "RGBA8 upload buffer has no base address."
        }
    }
}

/// Registers decoded MCT surfaces as Metal textures, indexed by guest identities.
/// This is the host upload boundary, not the game's render-state pipeline.
@MainActor
public final class RE4GuestTextureMetalRegistry {
    private let device: MTLDevice
    private var byGuestObject: [UInt32: MTLTexture] = [:]
    private var guestTextureToObject: [UInt32: UInt32] = [:]

    public init(device: MTLDevice) { self.device = device }

    @discardableResult
    public func register(_ request: RE4GuestTextureUploadRequest) throws -> MTLTexture {
        guard request.guestObjectAddress != 0, request.guestMceTextureAddress != 0 else {
            throw RE4GuestTextureRegistryError.invalidGuestAddress
        }
        guard request.width > 0, request.height > 0,
              request.width <= 16_384, request.height <= 16_384,
              request.width * request.height <= 64 * 1024 * 1024 else {
            throw RE4GuestTextureRegistryError.invalidDimensions
        }
        if let owner = guestTextureToObject[request.guestMceTextureAddress],
           owner != request.guestObjectAddress {
            throw RE4GuestTextureRegistryError.mceAddressAlreadyOwned(address: request.guestMceTextureAddress)
        }
        let expected = request.width * request.height * 4
        guard request.rgba8.count == expected, request.bytesPerRow == request.width * 4 else {
            throw RE4GuestTextureRegistryError.invalidRGBAByteCount(expected: expected, actual: request.rgba8.count)
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: request.width,
            height: request.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw RE4GuestTextureRegistryError.textureCreationFailed
        }
        texture.label = request.label
        let uploaded = request.rgba8.withUnsafeBytes { raw -> Bool in
            guard let baseAddress = raw.baseAddress else { return false }
            texture.replace(
                region: MTLRegionMake2D(0, 0, request.width, request.height),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: request.bytesPerRow
            )
            return true
        }
        guard uploaded else { throw RE4GuestTextureRegistryError.textureUploadFailed }

        // Remove any previous reverse mapping for this object before rebinding it.
        guestTextureToObject = guestTextureToObject.filter { $0.value != request.guestObjectAddress }
        byGuestObject[request.guestObjectAddress] = texture
        guestTextureToObject[request.guestMceTextureAddress] = request.guestObjectAddress
        return texture
    }

    @discardableResult
    public func decodeAndRegisterMCT(_ sourceMCT: Data,
                                     guestObjectAddress: UInt32,
                                     guestMceTextureAddress: UInt32,
                                     label: String) throws -> MTLTexture {
        let decoded = try RE4MCTTextureDecoder.decode(sourceMCT)
        return try registerDecodedMCT(decoded, sourceMCT: sourceMCT,
                                      guestObjectAddress: guestObjectAddress,
                                      guestMceTextureAddress: guestMceTextureAddress,
                                      label: label)
    }

    @discardableResult
    public func registerDecodedMCT(_ decoded: RE4MCTTextureData,
                                   sourceMCT: Data,
                                   guestObjectAddress: UInt32,
                                   guestMceTextureAddress: UInt32,
                                   label: String) throws -> MTLTexture {
        let sourceHash = SHA256.hash(data: sourceMCT).map { String(format: "%02x", $0) }.joined()
        let rgbaHash = SHA256.hash(data: decoded.rgba8).map { String(format: "%02x", $0) }.joined()
        let request = RE4GuestTextureUploadRequest(
            guestObjectAddress: guestObjectAddress,
            guestMceTextureAddress: guestMceTextureAddress,
            width: decoded.width,
            height: decoded.height,
            rgba8: decoded.rgba8,
            sourceMCTSHA256: sourceHash,
            rgbaSHA256: rgbaHash,
            label: label
        )
        return try register(request)
    }

    public func texture(forGuestObject address: UInt32) -> MTLTexture? {
        byGuestObject[address]
    }

    public func texture(forMCETexture address: UInt32) -> MTLTexture? {
        guard let object = guestTextureToObject[address] else { return nil }
        return byGuestObject[object]
    }

    public func remove(guestObject address: UInt32) {
        byGuestObject.removeValue(forKey: address)
        guestTextureToObject = guestTextureToObject.filter { $0.value != address }
    }

    public func removeAll() {
        byGuestObject.removeAll(keepingCapacity: false)
        guestTextureToObject.removeAll(keepingCapacity: false)
    }
}
