import ArgumentParser
import Foundation

struct Version: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the CLI version and basic build info."
    )

    @Flag(name: .long, help: "Emit JSON instead of plain text.")
    var json: Bool = false

    func run() throws {
        let info: [String: String] = [
            "version": file13Version,
            "swiftVersion": swiftVersion,
            "platform": platformString
        ]
        if json {
            let data = try JSONSerialization.data(withJSONObject: info, options: [.sortedKeys, .prettyPrinted])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } else {
            for key in info.keys.sorted() {
                print("\(key): \(info[key] ?? "")")
            }
        }
    }

    private var swiftVersion: String {
        #if swift(>=6.0)
        return "6.0+"
        #else
        return "<6.0"
        #endif
    }

    private var platformString: String {
        #if os(macOS)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #else
        return "non-macOS (unsupported)"
        #endif
    }
}
