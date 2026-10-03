import Foundation

public enum GatewayCheckResult: Equatable, Sendable {
    /// `modelAvailable` is nil when no alias was configured.
    case ok(modelAvailable: Bool?)
    case unauthorized
    case rateLimited
    case budgetExceeded
    case unreachable(String)
    case httpError(Int)

    public var message: String {
        switch self {
        case .ok(let modelAvailable):
            modelAvailable == nil ? "Verbindung erfolgreich."
                : modelAvailable == true ? "Verbindung erfolgreich, Modellalias ist verfügbar."
                : "Verbindung erfolgreich, aber der Modellalias ist für diesen Key nicht freigegeben."
        case .unauthorized: "Key wird vom Gateway abgelehnt (ungültig oder gesperrt)."
        case .rateLimited: "Rate-Limit erreicht. Später erneut versuchen."
        case .budgetExceeded: "Budget dieses Keys ist ausgeschöpft."
        case .unreachable(let reason): "Gateway nicht erreichbar (VPN?): \(reason)"
        case .httpError(let code): "Unerwartete Antwort vom Gateway (HTTP \(code))."
        }
    }
}

/// Connection test against LiteLLM's OpenAI-compatible `GET /v1/models`.
public enum GatewayCheck {
    public static func run(endpoint: URL, key: String, modelAlias: String, session: URLSession = .shared) async -> GatewayCheckResult {
        var request = URLRequest(url: endpoint.appendingPathComponent("v1/models"), timeoutInterval: 10)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch {
            return .unreachable(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(decoding: data, as: UTF8.self).lowercased()
        switch status {
        case 200:
            let alias = modelAlias.trimmingCharacters(in: .whitespaces)
            guard !alias.isEmpty else { return .ok(modelAvailable: nil) }
            struct Models: Decodable { struct Model: Decodable { var id: String }; var data: [Model] }
            let ids = (try? JSONDecoder().decode(Models.self, from: data))?.data.map(\.id) ?? []
            return .ok(modelAvailable: ids.contains(alias))
        case 401, 403: return .unauthorized
        case 429: return body.contains("budget") ? .budgetExceeded : .rateLimited
        case 400 where body.contains("budget"): return .budgetExceeded
        default: return .httpError(status)
        }
    }
}

/// Detects installed `claude` CLIs (used by the JetBrains integration) older than the tested version.
public enum ClaudeCLI {
    /// Oldest version verified to resolve project settings from the main worktree root (docs/feasibility.md).
    public static let minimumTestedVersion = "2.1.288"
    static let candidates = ["~/.local/bin/claude", "~/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]

    public static func outdatedInstallations(minimum: String = minimumTestedVersion) -> [(path: String, version: String)] {
        candidates.map { ($0 as NSString).expandingTildeInPath }
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
            .compactMap { path in version(of: path).map { (path, $0) } }
            .filter { isOlder($0.1, than: minimum) }
    }

    static func version(of path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return out.split(separator: " ").first.map(String.init)
    }

    public static func isOlder(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y }
        }
        return false
    }
}
