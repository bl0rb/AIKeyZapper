@testable import KeyZapperCore
import Foundation

final class InMemoryCredentialStore: CredentialStore {
    var items: [String: String] = [:]
    var failure: KeyZapperError?

    func read(_ ref: CredentialReference) throws -> String {
        if let failure { throw failure }
        guard let value = items[ref.account] else { throw KeyZapperError.missingCredential(UUID(uuidString: ref.account)!) }
        return value
    }
    func write(_ secret: String, label: String, for ref: CredentialReference) throws {
        if let failure { throw failure }
        guard !secret.isEmpty else { throw KeyZapperError.emptyCredential }
        items[ref.account] = secret
    }
    func delete(_ ref: CredentialReference) throws { items[ref.account] = nil }
    func exists(_ ref: CredentialReference) throws -> Bool { items[ref.account] != nil }
}

func makeTempDir(_ name: String = "work dir") -> String {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("keyzapper-tests-\(UUID().uuidString)/\(name)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return canonicalPath(url.path)
}

@discardableResult
func sh(_ command: String, in dir: String) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", command]
    p.currentDirectoryURL = URL(fileURLWithPath: dir)
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try! p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

func gitInit(_ dir: String) {
    sh("git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init", in: dir)
}

func readJSON(_ path: String) -> [String: Any]? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

func writeJSON(_ object: [String: Any], to path: String) {
    try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try! JSONSerialization.data(withJSONObject: object).write(to: URL(fileURLWithPath: path))
}

let sampleProfile = Profile(name: "Alpha", endpoint: URL(string: "https://litellm.example.test/")!, modelAlias: "claude-alpha")
let otherProfile = Profile(name: "Beta", endpoint: URL(string: "https://litellm-b.example.test")!, modelAlias: "")
