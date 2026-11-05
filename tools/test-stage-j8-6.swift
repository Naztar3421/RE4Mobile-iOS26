import Foundation

@main
struct StageJ86TestRunner {
    static func main() throws {
        guard CommandLine.arguments.count == 4 else {
            fputs("Usage: test-stage-j8-6 <lsda.hex> <frame-evidence.csv> <lsda-crosswalk.csv>\n", stderr)
            exit(2)
        }
        print(try RE4StageJ86ForcedResumeChainTests.run(
            lsdaHexURL: URL(fileURLWithPath: CommandLine.arguments[1]),
            evidenceURL: URL(fileURLWithPath: CommandLine.arguments[2]),
            crosswalkURL: URL(fileURLWithPath: CommandLine.arguments[3])))
    }
}
