import Foundation

/// Decodes the MCT texture layouts observed in RE4 Mobile Edition 1.04.10.
/// Output pixels are tightly packed RGBA8, top-to-bottom.
public struct RE4MCTTextureData {
    public let width: Int
    public let height: Int
    public let rgba8: Data
    public let sourcePixelFormat: UInt16
    public let sourceCompression: UInt16
    public var bytesPerRow: Int { width * 4 }
}

public enum RE4MCTDecodeError: Error, CustomStringConvertible {
    case truncatedHeader, badMagic, badVersion(UInt16)
    case bodyLengthMismatch(declared: UInt32, expected: Int)
    case badDimensions(Int, Int)
    case unsupportedFormat(format: UInt16, compression: UInt16, field30: UInt16, field32: UInt16)
    case payloadLengthMismatch(expected: Int, actual: Int)
    case invalidSubBlock(String), invalidLZW(String)

    public var description: String {
        switch self {
        case .truncatedHeader: return "MCT header is truncated"
        case .badMagic: return "MCT signature is not MCT_"
        case .badVersion(let v): return "Unsupported MCT version \(v)"
        case .bodyLengthMismatch(let d, let e): return "MCT body length mismatch: declared \(d), expected \(e)"
        case .badDimensions(let w, let h): return "Invalid MCT dimensions \(w)x\(h)"
        case .unsupportedFormat(let f, let c, let a, let b): return "Unsupported MCT format=\(f), compression=\(c), field30=\(a), field32=\(b)"
        case .payloadLengthMismatch(let e, let a): return "MCT payload length mismatch: expected \(e), got \(a)"
        case .invalidSubBlock(let s): return "Invalid MCT LZW sub-block framing: \(s)"
        case .invalidLZW(let s): return "Invalid MCT LZW stream: \(s)"
        }
    }
}

public enum RE4MCTTextureDecoder {
    private static let headerSize = 42
    private static let maxDimension = 16_384
    private static let maxPixels = 64 * 1024 * 1024

    private static func u16(_ b: [UInt8], _ p: Int) -> UInt16 {
        UInt16(b[p]) | (UInt16(b[p + 1]) << 8)
    }
    private static func u32(_ b: [UInt8], _ p: Int) -> UInt32 {
        UInt32(b[p]) | (UInt32(b[p + 1]) << 8) | (UInt32(b[p + 2]) << 16) | (UInt32(b[p + 3]) << 24)
    }

    public static func decode(_ data: Data) throws -> RE4MCTTextureData {
        let b = [UInt8](data)
        guard b.count >= headerSize else { throw RE4MCTDecodeError.truncatedHeader }
        guard Array(b[0..<4]) == Array("MCT_".utf8) else { throw RE4MCTDecodeError.badMagic }
        let version = u16(b, 8)
        guard version == 1 else { throw RE4MCTDecodeError.badVersion(version) }
        let declared = u32(b, 10)
        guard UInt64(declared) == UInt64(b.count - 10) else {
            throw RE4MCTDecodeError.bodyLengthMismatch(declared: declared, expected: b.count - 10)
        }
        let field30 = u16(b, 30), field32 = u16(b, 32)
        let width = Int(u16(b, 34)), height = Int(u16(b, 36))
        let compression = u16(b, 38), format = u16(b, 40)
        guard width > 0, height > 0, width <= maxDimension, height <= maxDimension,
              width * height <= maxPixels else { throw RE4MCTDecodeError.badDimensions(width, height) }
        let count = width * height
        let payload = Array(b[headerSize..<b.count])
        let rgba: [UInt8]

        if compression == 1 && format == 6 && field30 == 768 && field32 == 2 {
            let (minCodeSize, stream) = try stripSubBlocks(payload)
            let decoded = try decodeLZW(stream, minimumCodeSize: minCodeSize, expectedBytes: 768 + count)
            rgba = try indexedRGBToRGBA(decoded, pixelCount: count)
        } else if compression != 0 {
            throw RE4MCTDecodeError.unsupportedFormat(format: format, compression: compression, field30: field30, field32: field32)
        } else {
            switch format {
            case 2:
                let expected = count * 4
                guard payload.count == expected else {
                    throw RE4MCTDecodeError.payloadLengthMismatch(expected: expected, actual: payload.count)
                }
                rgba = payload
            case 6:
                rgba = try indexedRGBToRGBA(payload, pixelCount: count)
            case 7:
                let paletteBytes = 256 * 4
                let expected = paletteBytes + count
                guard payload.count == expected else {
                    throw RE4MCTDecodeError.payloadLengthMismatch(expected: expected, actual: payload.count)
                }
                var out = [UInt8](repeating: 0, count: count * 4)
                for i in 0..<count {
                    let p = Int(payload[paletteBytes + i]) * 4, q = i * 4
                    out[q] = payload[p]; out[q + 1] = payload[p + 1]
                    out[q + 2] = payload[p + 2]; out[q + 3] = payload[p + 3]
                }
                rgba = out
            default:
                throw RE4MCTDecodeError.unsupportedFormat(format: format, compression: compression, field30: field30, field32: field32)
            }
        }
        guard rgba.count == count * 4 else {
            throw RE4MCTDecodeError.payloadLengthMismatch(expected: count * 4, actual: rgba.count)
        }
        return RE4MCTTextureData(width: width, height: height, rgba8: Data(rgba),
                                 sourcePixelFormat: format, sourceCompression: compression)
    }

    private static func indexedRGBToRGBA(_ payload: [UInt8], pixelCount: Int) throws -> [UInt8] {
        let paletteBytes = 256 * 3
        let expected = paletteBytes + pixelCount
        guard payload.count == expected else {
            throw RE4MCTDecodeError.payloadLengthMismatch(expected: expected, actual: payload.count)
        }
        var out = [UInt8](repeating: 255, count: pixelCount * 4)
        for i in 0..<pixelCount {
            let p = Int(payload[paletteBytes + i]) * 3, q = i * 4
            out[q] = payload[p]; out[q + 1] = payload[p + 1]; out[q + 2] = payload[p + 2]
            out[q + 3] = 255
        }
        return out
    }

    private static func stripSubBlocks(_ payload: [UInt8]) throws -> (Int, [UInt8]) {
        guard let first = payload.first, first >= 2, first <= 8 else {
            throw RE4MCTDecodeError.invalidSubBlock("missing/invalid LZW minimum code size")
        }
        var pos = 1, stream: [UInt8] = [], sawTerminator = false
        while pos < payload.count {
            let length = Int(payload[pos]); pos += 1
            if length == 0 { sawTerminator = true; break }
            guard pos + length <= payload.count else {
                throw RE4MCTDecodeError.invalidSubBlock("block overruns payload at offset \(pos - 1)")
            }
            stream.append(contentsOf: payload[pos..<(pos + length)])
            pos += length
        }
        if sawTerminator && pos < payload.count && payload[pos...].contains(where: { $0 != 0 }) {
            throw RE4MCTDecodeError.invalidSubBlock("non-zero bytes after zero terminator")
        }
        guard !stream.isEmpty else { throw RE4MCTDecodeError.invalidSubBlock("no data blocks") }
        return (Int(first), stream)
    }

    private static func decodeLZW(_ stream: [UInt8], minimumCodeSize: Int, expectedBytes: Int) throws -> [UInt8] {
        let clear = 1 << minimumCodeSize, end = clear + 1
        var prefix = [Int](repeating: -1, count: 4096)
        var suffix = [UInt8](repeating: 0, count: 4096)
        var stack = [UInt8](repeating: 0, count: 4096)
        for i in 0..<clear { suffix[i] = UInt8(i) }
        var codeWidth = minimumCodeSize + 1, nextCode = end + 1, oldCode = -1
        var firstCharacter: UInt8 = 0, bitPosition = 0
        let totalBits = stream.count * 8
        var output = [UInt8](); output.reserveCapacity(expectedBytes)
        var sawEnd = false
        while bitPosition + codeWidth <= totalBits {
            var code = 0
            for bit in 0..<codeWidth {
                let absolute = bitPosition + bit
                if (stream[absolute >> 3] & (UInt8(1) << (absolute & 7))) != 0 { code |= 1 << bit }
            }
            bitPosition += codeWidth
            if code == clear {
                for i in clear..<4096 { prefix[i] = -1 }
                codeWidth = minimumCodeSize + 1; nextCode = end + 1
                oldCode = -1; firstCharacter = 0
                continue
            }
            if code == end { sawEnd = true; break }
            let incomingCode = code
            var stackCount = 0
            if code == nextCode {
                guard oldCode >= 0 else { throw RE4MCTDecodeError.invalidLZW("KwKwK code without previous code") }
                stack[stackCount] = firstCharacter; stackCount += 1
                code = oldCode
            } else if code > nextCode || code >= 4096 {
                throw RE4MCTDecodeError.invalidLZW("invalid code \(code), next=\(nextCode), width=\(codeWidth)")
            }
            var walk = code, guardCount = 0
            while walk >= clear {
                guard walk < nextCode, stackCount < stack.count, prefix[walk] >= 0 else {
                    throw RE4MCTDecodeError.invalidLZW("broken prefix chain at code \(walk)")
                }
                stack[stackCount] = suffix[walk]; stackCount += 1
                walk = prefix[walk]; guardCount += 1
                if guardCount > 4096 { throw RE4MCTDecodeError.invalidLZW("prefix cycle") }
            }
            guard walk >= 0 && walk < clear else { throw RE4MCTDecodeError.invalidLZW("invalid base code \(walk)") }
            firstCharacter = suffix[walk]
            guard stackCount < stack.count else { throw RE4MCTDecodeError.invalidLZW("decode stack overflow") }
            stack[stackCount] = firstCharacter; stackCount += 1
            guard output.count + stackCount <= expectedBytes else {
                throw RE4MCTDecodeError.invalidLZW("output exceeds expected \(expectedBytes) bytes")
            }
            while stackCount > 0 { stackCount -= 1; output.append(stack[stackCount]) }
            if oldCode >= 0 && nextCode < 4096 {
                prefix[nextCode] = oldCode; suffix[nextCode] = firstCharacter; nextCode += 1
                if nextCode == (1 << codeWidth) && codeWidth < 12 { codeWidth += 1 }
            }
            oldCode = incomingCode
        }
        guard sawEnd else { throw RE4MCTDecodeError.invalidLZW("end code not found") }
        guard output.count == expectedBytes else {
            throw RE4MCTDecodeError.invalidLZW("decoded \(output.count) bytes, expected \(expectedBytes)")
        }
        return output
    }
}
