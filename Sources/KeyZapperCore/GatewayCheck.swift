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
        await get("v1/models", endpoint: endpoint, key: key, timeout: 10, session: session).map { data in
            struct Models: Decodable { struct Model: Decodable { var id: String }; var data: [Model] }
            return ((try? JSONDecoder().decode(Models.self, from: data))?.data.map(\.id) ?? []).sorted()
        }
    }

    /// LiteLLM's `GET /key/info` without `key` parameter describes the calling key: spend, limit and next reset.
    public static func budget(endpoint: URL, key: String, timeout: TimeInterval = 10,
                              session: URLSession = .shared) async -> Result<KeyBudget, GatewayFailure> {
        await get("key/info", endpoint: endpoint, key: key, timeout: timeout, session: session).flatMap { data in
            struct Response: Decodable {
                struct Info: Decodable { var spend: Double?; var max_budget: Double?; var budget_reset_at: String? }
                var info: Info
            }
            guard let info = try? JSONDecoder().decode(Response.self, from: data).info else {
                return .failure(GatewayFailure(result: .httpError(200)))
            }
            return .success(KeyBudget(spend: info.spend ?? 0, maxBudget: info.max_budget, resetAt: info.budget_reset_at.flatMap(parseDate)))
        }
    }

    /// Synchronous remaining budget for `keyzapper-helper`: nil if unknown, 0 if exhausted, `.infinity` without limit.
    public static func remainingBudget(endpoint: URL, key: String) -> Double? {
        final class Box: @unchecked Sendable { var value: Double? }
        let box = Box(), done = DispatchSemaphore(value: 0)
        Task {
            switch await budget(endpoint: endpoint, key: key, timeout: 5) {
            case .success(let budget): box.value = budget.remaining
            case .failure(let failure): box.value = failure.result == .budgetExceeded ? 0 : nil
            }
            done.signal()
        }
        done.wait()
        return box.value
    }

    /// LiteLLM writes Python ISO dates, e.g. `2026-11-01T00:00:00.123456+00:00`, sometimes without zone (UTC).
    static func parseDate(_ text: String) -> Date? {
        var value = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        if value.range(of: #"(Z|[+-]\d\d:?\d\d)$"#, options: .regularExpression) == nil { value += "Z" }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func get(_ path: String, endpoint: URL, key: String, timeout: TimeInterval,
                            session: URLSession) async -> Result<Data, GatewayFailure> {
        var request = URLRequest(url: endpoint.appendingPathComponent(path), timeoutInterval: timeout)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch {
            return .failure(GatewayFailure(result: .unreachable(error.localizedDescription)))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(decoding: data, as: UTF8.self).lowercased()
        switch status {
        case 200: return .success(data)
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

/// Budget of a LiteLLM key in USD, as reported by `/key/info`.
public struct KeyBudget: Equatable, Sendable {
    public var spend: Double
    /// Nil when the key has no budget limit.
    public var maxBudget: Double?
    public var resetAt: Date?

    /// Remaining budget; `.infinity` without a limit.
    public var remaining: Double { maxBudget.map { max(0, $0 - spend) } ?? .infinity }
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
