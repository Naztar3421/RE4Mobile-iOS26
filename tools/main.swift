import Foundation

let args = CommandLine.arguments
guard args.count >= 6 else {
    fputs("usage: TestMCTDecoder input.mct output.rgba expected.rgba expected-format expected-compression\n", stderr)
    exit(2)
}
do {
    let inputURL = URL(fileURLWithPath: args[1])
    let outputURL = URL(fileURLWithPath: args[2])
    let expectedURL = URL(fileURLWithPath: args[3])
    let expectedFormat = UInt16(args[4]) ?? 0
    let expectedCompression = UInt16(args[5]) ?? 0
    let input = try Data(contentsOf: inputURL)
    let expected = try Data(contentsOf: expectedURL)
    let decoded = try RE4MCTTextureDecoder.decode(input)
    guard decoded.sourcePixelFormat == expectedFormat else {
        fputs("FAIL expected format=\(expectedFormat), got \(decoded.sourcePixelFormat)\n", stderr)
        exit(1)
    }
    guard decoded.sourceCompression == expectedCompression else {
        fputs("FAIL expected compression=\(expectedCompression), got \(decoded.sourceCompression)\n", stderr)
        exit(1)
    }
    guard decoded.rgba8.count == decoded.width * decoded.height * 4 else {
        fputs("FAIL wrong RGBA byte count\n", stderr)
        exit(1)
    }
    try decoded.rgba8.write(to: outputURL, options: .atomic)
    guard decoded.rgba8 == expected else {
        fputs("FAIL decoded output differs from synthetic expected RGBA bytes\n", stderr)
        exit(1)
    }
    print("PASS width=\(decoded.width) height=\(decoded.height) format=\(decoded.sourcePixelFormat) compression=\(decoded.sourceCompression) rgba_bytes=\(decoded.rgba8.count) exact_match=true")
} catch {
    fputs("FAIL \(error)\n", stderr)
    exit(1)
}
