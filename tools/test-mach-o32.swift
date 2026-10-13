import Foundation
@main
enum MachO32ParserTest {
    static func main() {
        do {
            print(try RE4MachO32Parser.runSyntheticSelfTest())
            print("")
            print(try RE4MachO32Loader.runSyntheticSelfTest())
            print("")
            print(try RE4MachO32ImportBindingPlanner.runSyntheticSelfTest())
            print("")
            print(try RE4MachO32HLEBinder.runSyntheticSelfTest())
            print("")
            print(try RE4ARMv6EntryPreflight.runSyntheticSelfTest())
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
