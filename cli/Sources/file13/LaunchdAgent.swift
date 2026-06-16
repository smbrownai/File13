import ArgumentParser
import Foundation

/// Schedule cadence for the launchd agent that runs `file13 rules run` headlessly.
enum LaunchdInterval: String {
    case every5Minutes
    case hourly
    case daily
}

/// LaunchAgent helper for `file13 rules schedule install/remove/status`.
///
/// Writes a plist to `~/Library/LaunchAgents/com.shawnbrown.file13.rules.plist` and
/// drives `launchctl bootstrap|bootout|print` to load/unload it. The agent runs as
/// the current user (not root), which is what we want — it inherits Keychain access
/// and the App Group container the same way a hand-typed CLI invocation does.
@MainActor
enum LaunchdAgent {
    static let agentLabel = "com.shawnbrown.file13.rules"

    /// Path to the per-user LaunchAgent plist.
    static var plistURL: URL {
        let agents = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        return agents.appendingPathComponent("\(agentLabel).plist")
    }

    /// Domain target launchctl uses for per-user LaunchAgents (`gui/<uid>`).
    static var domainTarget: String { "gui/\(getuid())" }

    /// Service target inside the user's GUI domain.
    static var serviceTarget: String { "\(domainTarget)/\(agentLabel)" }

    static func install(interval: LaunchdInterval, dryRun: Bool) throws {
        let cliPath = currentExecutablePath()
        let plistDict = makePlist(cliPath: cliPath, interval: interval)
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plistDict,
            format: .xml,
            options: 0
        )
        if dryRun {
            print("would write to: \(plistURL.path)")
            print("would load via:  launchctl bootstrap \(domainTarget) \"\(plistURL.path)\"")
            print("---")
            FileHandle.standardOutput.write(plistData)
            print("")
            return
        }
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // If an old version of the agent is loaded, unload first so bootstrap doesn't error.
        if isLoaded() {
            _ = run("/bin/launchctl", ["bootout", serviceTarget])
        }
        try plistData.write(to: plistURL, options: .atomic)
        let bootstrapResult = run("/bin/launchctl", ["bootstrap", domainTarget, plistURL.path])
        guard bootstrapResult.exitCode == 0 else {
            FileHandle.standardError.write(Data("launchctl bootstrap failed (exit \(bootstrapResult.exitCode)):\n\(bootstrapResult.combinedOutput)\n".utf8))
            throw ExitCode(3)
        }
        print("installed launchd agent at \(plistURL.path)")
        print("interval: \(interval.rawValue)")
        print("runs as: \(NSUserName()) (uid \(getuid()))")
        print("logs:    \(logsDirectory().path)")
    }

    static func remove() throws {
        var didSomething = false
        if isLoaded() {
            let result = run("/bin/launchctl", ["bootout", serviceTarget])
            if result.exitCode != 0 {
                FileHandle.standardError.write(Data("launchctl bootout exited \(result.exitCode):\n\(result.combinedOutput)\n".utf8))
            }
            didSomething = true
        }
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
            print("deleted plist at \(plistURL.path)")
            didSomething = true
        }
        if !didSomething {
            print("(no launchd agent installed)")
        }
    }

    static func status() throws {
        let exists = FileManager.default.fileExists(atPath: plistURL.path)
        let loaded = isLoaded()
        print("plist:  \(exists ? "present at \(plistURL.path)" : "absent")")
        print("loaded: \(loaded ? "yes" : "no")")
        if loaded {
            // launchctl print shows next-fire time, last exit, etc.
            let result = run("/bin/launchctl", ["print", serviceTarget])
            print("---")
            print(result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: - Internals

    private static func makePlist(cliPath: String, interval: LaunchdInterval) -> [String: Any] {
        let logs = logsDirectory()
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let stdoutPath = logs.appendingPathComponent("rules.run.out").path
        let stderrPath = logs.appendingPathComponent("rules.run.err").path

        var plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [cliPath, "rules", "run"],
            "RunAtLoad": false,
            "StandardOutPath": stdoutPath,
            "StandardErrorPath": stderrPath,
            // ProcessType=Background asks launchd to throttle if the system is busy —
            // appropriate for a periodic cleanup task.
            "ProcessType": "Background"
        ]
        switch interval {
        case .every5Minutes:
            plist["StartInterval"] = 300
        case .hourly:
            plist["StartInterval"] = 3600
        case .daily:
            // 3 AM local. StartCalendarInterval lets launchd skew a bit if the Mac was
            // asleep at the exact minute; the next wake-up gets the firing.
            plist["StartCalendarInterval"] = ["Hour": 3, "Minute": 0]
        }
        return plist
    }

    private static func logsDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/File13", isDirectory: true)
    }

    /// Best-effort check via `launchctl print-disabled` — but the simpler shape is to
    /// run `launchctl print <service-target>` and look at the exit code.
    private static func isLoaded() -> Bool {
        let result = run("/bin/launchctl", ["print", serviceTarget])
        return result.exitCode == 0
    }

    /// Resolve the path to the *current* `file13` binary, so the plist points at the
    /// exact build the user just `install`ed from. Falls back to `/usr/local/bin/file13`
    /// when `_NSGetExecutablePath` fails (vanishingly unlikely on macOS).
    private static func currentExecutablePath() -> String {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else {
            return "/usr/local/bin/file13"
        }
        // `String(cString:)` was deprecated in favor of an explicit
        // UTF-8-decoding initializer that doesn't trust the C string's
        // null termination. Strip the trailing null byte (if any) before
        // decoding.
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let raw = String(decoding: bytes, as: UTF8.self)
        // Resolve symlinks so the plist embeds a concrete path even if the user
        // installed `file13` as a symlink in their PATH. `resolvingSymlinksInPath`
        // is non-throwing — drop the spurious `try?` that strict-mode flagged.
        return URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
    }

    // MARK: - Process helper

    private struct ProcessResult {
        let exitCode: Int32
        let combinedOutput: String
    }

    @discardableResult
    private static func run(_ executable: String, _ args: [String]) -> ProcessResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return ProcessResult(exitCode: -1, combinedOutput: "couldn't launch \(executable): \(error.localizedDescription)")
        }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        let output = String(data: data, encoding: .utf8) ?? ""
        return ProcessResult(exitCode: p.terminationStatus, combinedOutput: output)
    }
}
