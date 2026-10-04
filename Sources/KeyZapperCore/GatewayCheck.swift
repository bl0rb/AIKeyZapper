import Foundation

public enum GatewayCheckResult: Equatable, Sendable {
    /// `missingModels` is nil when no model is configured, empty when all configured models are available.
    case ok(missingModels: [String]?)
    case unauthorized
    case rateLimited
    case budgetExceeded
    case unreachable(String)
    case httpError(Int)

    public var message: String {
        switch self {
        case .ok(nil): L("Verbindung erfolgreich.")
        case .ok(let missing?) where missing.isEmpty: L("Verbindung erfolgreich, alle Modelle sind verfügbar.")
        case .ok(let missing?): L("Verbindung erfolgreich, aber diese Modelle sind für den Key nicht freigegeben: \(missing.joined(separator: ", "))")
        case .unauthorized: L("Key wird vom Gateway abgelehnt (ungültig oder gesperrt).")
        case .rateLimited: L("Rate-Limit erreicht. Später erneut versuchen.")
        case .budgetExceeded: L("Budget dieses Keys ist ausgeschöpft.")
        case .unreachable(let reason): L("Gateway nicht erreichbar (VPN?): \(reason)")
        case .httpError(let code): L("Unerwartete Antwort vom Gateway (HTTP \(String(code))).")
        }
    }

    public var isSuccess: Bool {
        if case .ok(let missing) = self { return missing?.isEmpty != false }
        return false
    }
}

/// LiteLLM's OpenAI-compatible `GET /v1/models`: lists the model names the key may use.
public enum GatewayCheck {
    /// Model IDs available to the key, or the failure as a check result.
    public static func models(endpoint: URL, key: String, session: URLSession = .shared) async -> Result<[String], GatewayFailure> {
        var request = URLRequest(url: endpoint.appendingPathComponent("v1/models"), timeoutInterval: 10)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch {
            return .failure(GatewayFailure(result: .unreachable(error.localizedDescription)))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(decoding: data, as: UTF8.self).lowercased()
        switch status {
        case 200:
            struct Models: Decodable { struct Model: Decodable { var id: String }; var data: [Model] }
            return .success(((try? JSONDecoder().decode(Models.self, from: data))?.data.map(\.id) ?? []).sorted())
        case 401, 403: return .failure(GatewayFailure(result: .unauthorized))
        case 429: return .failure(GatewayFailure(result: body.contains("budget") ? .budgetExceeded : .rateLimited))
        case 400 where body.contains("budget"): return .failure(GatewayFailure(result: .budgetExceeded))
        default: return .failure(GatewayFailure(result: .httpError(status)))
        }
    }

    /// Connection test; also reports configured models the key may not use.
    public static func run(endpoint: URL, key: String, models wanted: [String], session: URLSession = .shared) async -> GatewayCheckResult {
        switch await models(endpoint: endpoint, key: key, session: session) {
        case .failure(let failure): return failure.result
        case .success(let available):
            guard !wanted.isEmpty else { return .ok(missingModels: nil) }
            return .ok(missingModels: wanted.filter { !available.contains($0) })
        }
    }
}

public struct GatewayFailure: Error, Equatable, Sendable {
    public var result: GatewayCheckResult
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
