import Foundation

public struct HealthResponse: Codable, Sendable, Equatable {
    public let status: String
    public let version: String
    public let platform: String
}

public struct ModelsListResponse: Codable, Sendable, Equatable {
    public let models: [ModelStatusInfo]
}

public struct FailuresListResponse: Codable, Sendable, Equatable {
    public let failures: [DiagnosticFailure]
}

public final class AcpmClient: Sendable {
    public let baseURL: URL
    public let token: String
    public let caller: String
    private let session: URLSession

    public init(
        baseURL: URL,
        token: String,
        caller: String = "swift-client",
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.token = token
        self.caller = caller
        self.session = session
    }

    public convenience init(discovery: RuntimeDiscovery, caller: String = "swift-client") throws {
        guard let url = discovery.baseURL else {
            throw URLError(.badURL)
        }
        self.init(baseURL: url, token: discovery.token, caller: caller)
    }

    public static func fromDefaultDiscovery(caller: String = "swift-client") throws -> AcpmClient {
        let info = try RuntimeDiscovery.discover()
        return try AcpmClient(discovery: info, caller: caller)
    }

    public func health() async throws -> HealthResponse {
        try await sendJSON(method: "GET", path: "/healthz", body: Optional<Int>.none, priority: .normal, authenticated: false)
    }

    public func models() async throws -> [ModelStatusInfo] {
        let res: ModelsListResponse = try await sendJSON(method: "GET", path: "/v1/models", body: Optional<Int>.none, priority: .normal)
        return res.models
    }

    public func systemStatus() async throws -> SystemStatusResponse {
        try await sendJSON(method: "GET", path: "/v1/system/status", body: Optional<Int>.none, priority: .normal)
    }

    public func recentFailures() async throws -> [DiagnosticFailure] {
        let res: FailuresListResponse = try await sendJSON(method: "GET", path: "/v1/system/failures", body: Optional<Int>.none, priority: .normal)
        return res.failures
    }

    public func chatCompletions(
        _ payload: ChatCompletionRequest,
        priority: Priority = .interactive
    ) async throws -> ChatCompletionResponse {
        try await sendJSON(method: "POST", path: "/v1/chat/completions", body: payload, priority: priority)
    }

    public func transcribe(
        _ payload: TranscriptionRequest,
        priority: Priority = .interactive
    ) async throws -> TranscriptionResponse {
        try await sendJSON(method: "POST", path: "/v1/audio/transcriptions", body: payload, priority: priority)
    }

    public func speechToFile(
        _ payload: SpeechRequest,
        priority: Priority = .batch
    ) async throws -> SpeechFileResponse {
        try await sendJSON(method: "POST", path: "/v1/audio/speech", body: payload, priority: priority)
    }

    public func loadModel(_ modelId: String) async throws -> ModelStatusInfo {
        try await sendJSON(method: "POST", path: "/v1/models/\(modelId)/load", body: EmptyBody(), priority: .normal)
    }

    public func unloadModel(_ modelId: String) async throws -> ModelStatusInfo {
        try await sendJSON(method: "POST", path: "/v1/models/\(modelId)/unload", body: EmptyBody(), priority: .normal)
    }

    public func unloadAll() async throws {
        let _: EmptyBody = try await sendJSON(method: "POST", path: "/v1/system/unload-all", body: EmptyBody(), priority: .normal)
    }

    private func sendJSON<Req: Encodable, Res: Decodable>(
        method: String,
        path: String,
        body: Req?,
        priority: Priority,
        authenticated: Bool = true
    ) async throws -> Res {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(priority.rawValue, forHTTPHeaderField: "X-AI-Priority")
        request.setValue(caller, forHTTPHeaderField: "X-AI-Caller")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-AI-Request-Id")
        if authenticated {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if !(200..<300).contains(http.statusCode) {
            if let envelope = try? JSONDecoder().decode(ApiErrorEnvelope.self, from: data) {
                throw envelope.error
            }
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Res.self, from: data)
    }

    private struct EmptyBody: Codable, Sendable {}
}
