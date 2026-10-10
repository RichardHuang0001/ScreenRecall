import Foundation

@main
enum ProbeCLI {
    static func main() async {
        do {
            let repeats = max(1, min(Int(CommandLine.arguments.dropFirst().first ?? "1") ?? 1, 20))
            for _ in 0..<repeats {
                let report = try await PlatformProbe.run()
                let output = try JSONEncoder().encode(report)
                FileHandle.standardOutput.write(output)
                FileHandle.standardOutput.write(Data([0x0a]))
            }
        } catch {
            FileHandle.standardError.write(Data("probe failed: \(error)\n".utf8))
            exit(1)
        }
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
