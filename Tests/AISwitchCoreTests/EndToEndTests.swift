@testable import AISwitchCore
import Foundation
import Testing

/// Opt-in: AISWITCH_E2E_CLAUDE=/path/to/claude swift test --filter EndToEnd
/// Uses the real login keychain (fake sk-test-* keys, removed afterwards), the built helper, the binder,
/// real Claude Code with an isolated CLAUDE_CONFIG_DIR, and spike/mock_gateway.py on 127.0.0.1.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["AISWITCH_E2E_CLAUDE"] != nil))
struct EndToEndTests {
    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func start(_ exe: String, _ args: [String], cwd: String = "/", env: [String: String]) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try p.run()
        return p
    }

    @discardableResult
    func run(_ exe: String, _ args: [String], cwd: String = "/", env: [String: String], stdin: String = "") throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        p.environment = env
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = inp
        try p.run()
        inp.fileHandleForWriting.write(Data(stdin.utf8))
        try inp.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test func twoProjectsUseTheirOwnKeysWithoutFallback() throws {
        let claude = ProcessInfo.processInfo.environment["AISWITCH_E2E_CLAUDE"]!
        let helper = Self.repoRoot.appendingPathComponent(".build/debug/aiswitch-key-helper").path
        try #require(FileManager.default.isExecutableFile(atPath: helper))
        let work = makeTempDir("e2e")
        let port = 18472
        let a = Profile(name: "E2E A", endpoint: URL(string: "http://127.0.0.1:\(port)/projA")!, modelAlias: "")
        let b = Profile(name: "E2E B", endpoint: URL(string: "http://127.0.0.1:\(port)/projB")!, modelAlias: "")
        try MetadataStore(fileURL: URL(fileURLWithPath: work + "/home/state.json")).save(AppState(profiles: [a, b]))
        let env = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "AISWITCH_HOME": work + "/home"]
        defer {
            for p in [a, b] { _ = try? run(helper, ["delete", "--profile", p.id.uuidString], env: env) }
        }
        #expect(try run(helper, ["store", "--profile", a.id.uuidString], env: env, stdin: "sk-test-e2e-A\n").0 == 0)
        #expect(try run(helper, ["store", "--profile", b.id.uuidString], env: env, stdin: "sk-test-e2e-B").0 == 0)

        let projA = work + "/projA", projB = work + "/proj B"
        for dir in [projA, projB] { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        gitInit(projA)
        let binder = ClaudeSettingsBinder(helperPath: helper, managedSettingsPaths: [], userSettingsPath: "/nonexistent")
        _ = try binder.apply(profile: a, folder: projA, previous: nil)
        _ = try binder.apply(profile: b, folder: projB, previous: nil)

        let log = work + "/mock.log"
        let mock = Process()
        mock.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        mock.arguments = ["python3", Self.repoRoot.appendingPathComponent("spike/mock_gateway.py").path, "\(port)"]
        mock.environment = ["PATH": "/usr/bin:/bin:/opt/homebrew/bin", "MOCK_LOG": log]
        try mock.run()
        defer { mock.terminate() }
        Thread.sleep(forTimeInterval: 0.7)

        // Inherited IDE/shell credentials must be neutralised by the binding.
        let claudeEnv = env.merging(["CLAUDE_CONFIG_DIR": work + "/cfg", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
                                     "ANTHROPIC_API_KEY": "sk-test-inherited", "ANTHROPIC_AUTH_TOKEN": "sk-test-inherited"]) { $1 }
        let sessions = try [projA, projB].map { try start(claude, ["-p", "say OK", "--max-turns", "1"], cwd: $0, env: claudeEnv) }
        sessions.forEach { $0.waitUntilExit() }
        #expect(sessions.allSatisfy { $0.terminationStatus == 0 })

        // Missing credential: request must carry no other credential.
        _ = try run(helper, ["delete", "--profile", a.id.uuidString], env: env)
        _ = try run(claude, ["-p", "say OK", "--max-turns", "1"], cwd: projA, env: claudeEnv)

        let lines = try String(contentsOfFile: log, encoding: .utf8).split(separator: "\n").map { String($0.split(separator: " ", maxSplits: 1)[1]) }
        #expect(lines.contains("/projA/v1/messages x-api-key=sk-test-e2e-A authorization=sk-test-e2e-A"))
        #expect(lines.contains("/projB/v1/messages x-api-key=sk-test-e2e-B authorization=sk-test-e2e-B"))
        #expect(lines.last == "/projA/v1/messages x-api-key=EMPTY authorization=OTHER(len=6)")
        #expect(!lines.contains { $0.contains("inherited") || $0.contains("e2e-B") && $0.hasPrefix("/projA") })
    }
}
