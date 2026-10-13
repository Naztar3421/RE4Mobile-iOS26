import Foundation
import Metal
import CryptoKit

/// Snapshot emitted after the original ERP_Obj_Tex::Load_Obj returns and the native
/// MCE table is readable. Guest addresses are virtual addresses, never host pointers.
public struct RE4NativeGuestTextureSnapshot {
    public let guestObjectAddress: UInt32
    public let guestMceTextureAddress: UInt32
    public let name: String
    public let sourceMCTBytes: Data
    public let nativeWidth: Int
    public let nativeHeight: Int
    public let nativePixelFormat: UInt32

    public init(guestObjectAddress: UInt32,
                guestMceTextureAddress: UInt32,
                name: String,
                sourceMCTBytes: Data,
                nativeWidth: Int,
                nativeHeight: Int,
                nativePixelFormat: UInt32) {
        self.guestObjectAddress = guestObjectAddress
        self.guestMceTextureAddress = guestMceTextureAddress
        self.name = name
        self.sourceMCTBytes = sourceMCTBytes
        self.nativeWidth = nativeWidth
        self.nativeHeight = nativeHeight
        self.nativePixelFormat = nativePixelFormat
    }
}

public enum RE4GuestTextureUploadBridgeError: Error, LocalizedError {
    case invalidMCT(String)
    case nativeMetadataMismatch(name: String,
                                nativeWidth: Int, nativeHeight: Int, nativeFormat: UInt32,
                                decodedWidth: Int, decodedHeight: Int, decodedFormat: UInt16)

    public var errorDescription: String? {
        switch self {
        case .invalidMCT(let reason):
            return "Could not decode guest MCT payload: \(reason)"
        case .nativeMetadataMismatch(let name, let nw, let nh, let nf, let dw, let dh, let df):
            return "Native MCE metadata mismatch for \(name): guest=\(nw)x\(nh) fmt \(nf), decoded=\(dw)x\(dh) fmt \(df)."
        }
    }
}

/// Validates the completed-load snapshot, checks its metadata against the MCT header,
/// then creates/uploads an MTLTexture through the host registry.
@MainActor
public final class RE4GuestTextureUploadBridge {
    private let registry: RE4GuestTextureMetalRegistry

    public init(registry: RE4GuestTextureMetalRegistry) {
        self.registry = registry
    }

    @discardableResult
    public func registerCompletedNativeLoad(_ snapshot: RE4NativeGuestTextureSnapshot) throws -> MTLTexture {
        let decoded: RE4MCTTextureData
        do {
            decoded = try RE4MCTTextureDecoder.decode(snapshot.sourceMCTBytes)
        } catch {
            throw RE4GuestTextureUploadBridgeError.invalidMCT(String(describing: error))
        }

        guard decoded.width == snapshot.nativeWidth,
              decoded.height == snapshot.nativeHeight,
              UInt32(decoded.sourcePixelFormat) == snapshot.nativePixelFormat else {
            throw RE4GuestTextureUploadBridgeError.nativeMetadataMismatch(
                name: snapshot.name,
                nativeWidth: snapshot.nativeWidth,
                nativeHeight: snapshot.nativeHeight,
                nativeFormat: snapshot.nativePixelFormat,
                decodedWidth: decoded.width,
                decodedHeight: decoded.height,
                decodedFormat: decoded.sourcePixelFormat
            )
        }

        return try registry.registerDecodedMCT(
            decoded,
            sourceMCT: snapshot.sourceMCTBytes,
            guestObjectAddress: snapshot.guestObjectAddress,
            guestMceTextureAddress: snapshot.guestMceTextureAddress,
            label: "RE4/\(snapshot.name)"
        )
    }

    public func texture(forGuestObject address: UInt32) -> MTLTexture? {
        registry.texture(forGuestObject: address)
    }

    public func texture(forNativeMCETexture address: UInt32) -> MTLTexture? {
        registry.texture(forMCETexture: address)
    }

    public func guestObjectDestroyed(_ address: UInt32) {
        registry.remove(guestObject: address)
    }
}
