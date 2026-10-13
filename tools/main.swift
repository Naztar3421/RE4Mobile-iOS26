import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    fputs("usage: TestMCTDecoder input.mct output.rgba\n", stderr)
    exit(2)
}
do {
    let input = try Data(contentsOf: URL(fileURLWithPath: args[1]))
    let decoded = try RE4MCTTextureDecoder.decode(input)
    try decoded.rgba8.write(to: URL(fileURLWithPath: args[2]), options: .atomic)
    guard decoded.width == 8 && decoded.height == 8 && decoded.sourcePixelFormat == 2 &&
          decoded.sourceCompression == 0 && decoded.rgba8.count == 8 * 8 * 4 else {
        fputs("FAIL unexpected dimensions, format or RGBA length\n", stderr)
        exit(1)
    }
    print("PASS width=\(decoded.width) height=\(decoded.height) format=\(decoded.sourcePixelFormat) compression=\(decoded.sourceCompression) rgba_bytes=\(decoded.rgba8.count)")
} catch {
    fputs("FAIL \(error)\n", stderr)
    exit(1)
}
