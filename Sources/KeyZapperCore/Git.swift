import Foundation

enum Git {
    /// Runs `git -C dir args…`; returns trimmed stdout on exit 0, nil otherwise (also when git is unavailable).
    static func run(_ args: [String], in dir: String) -> String? {
        let (code, out) = exec(args, in: dir)
        return code == 0 ? out.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    static func status(_ args: [String], in dir: String) -> Int32 { exec(args, in: dir).0 }

    private static func exec(_ args: [String], in dir: String) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", dir] + args
        var env = ProcessInfo.processInfo.environment
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR"] { env[key] = nil }
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

public func canonicalPath(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    guard let resolved = realpath(expanded, nil) else { return URL(fileURLWithPath: expanded).standardizedFileURL.path }
    defer { free(resolved) }
    return String(cString: resolved)
}
