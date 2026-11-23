import Foundation

public struct HealthResponse: Codable, Sendable, Equatable {
    public let status: String
    public let version: String
    public let platform: String
    public let mdnsHostname: String?
    public let mdnsBaseUrl: String?

    enum CodingKeys: String, CodingKey {
        case status
        case version
        case platform
        case mdnsHostname = "mdns_hostname"
        case mdnsBaseUrl = "mdns_base_url"
    }
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

    public static func fromMdns(
        host: String = "acpm.local",
        port: Int = 18790,
        token: String,
        caller: String = "swift-client",
        session: URLSession = .shared
    ) throws -> AcpmClient {
        let normalizedHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard let url = URL(string: "http://\(normalizedHost):\(port)") else {
            throw URLError(.badURL)
        }
        return AcpmClient(baseURL: url, token: token, caller: caller, session: session)
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

    public func chatCompletionsStream(
        _ payload: ChatCompletionRequest,
        priority: Priority = .interactive
    ) -> AsyncThrowingStream<ChatStreamDelta, Error> {
        let streamPayload = ChatCompletionRequest(
            model: payload.model,
            messages: payload.messages,
            stream: true,
            temperature: payload.temperature,
            maxTokens: payload.maxTokens,
            separateReasoning: payload.separateReasoning,
            promptCacheKey: payload.promptCacheKey
        )
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = URL(string: "/v1/chat/completions", relativeTo: baseURL) else {
                        throw URLError(.badURL)
                    }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue(priority.rawValue, forHTTPHeaderField: "X-AI-Priority")
                    request.setValue(caller, forHTTPHeaderField: "X-AI-Caller")
                    request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-AI-Request-Id")
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONEncoder().encode(streamPayload)

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw URLError(.badServerResponse)
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var bodyData = Data()
                        for try await byte in bytes {
                            bodyData.append(byte)
                        }
                        if let envelope = try? JSONDecoder().decode(ApiErrorEnvelope.self, from: bodyData) {
                            throw envelope.error
                        }
                        throw URLError(.badServerResponse)
                    }

                    for try await line in bytes.lines {
                        if line.trimmingCharacters(in: .whitespacesAndNewlines) == "data: [DONE]" {
                            break
                        }
                        if let delta = Self.parseSSEDataLine(line) {
                            continuation.yield(delta)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public static func parseSSEDataLine(_ line: String) -> ChatStreamDelta? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return nil }
        let jsonStr = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        guard !jsonStr.isEmpty, jsonStr != "[DONE]",
              let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first
        else {
            return nil
        }
        let delta = first["delta"] as? [String: Any] ?? [:]
        let reasoning = delta["reasoning_content"] as? String
        let content = delta["content"] as? String
        let finishReason = first["finish_reason"] as? String
        if reasoning == nil && content == nil && finishReason == nil {
            return nil
        }
        return ChatStreamDelta(
            reasoningContent: reasoning,
            content: content,
            finishReason: finishReason
        )
    }

    public func prewarm(
        models: [String],
        promptCacheKeys: [String]? = nil
    ) async throws -> [ModelStatusInfo] {
        let req = PrewarmRequest(models: models, promptCacheKeys: promptCacheKeys)
        let res: ModelsListResponse = try await sendJSON(
            method: "POST",
            path: "/v1/models/prewarm",
            body: req,
            priority: .normal
        )
        return res.models
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

    public func speechAudio(
        _ payload: SpeechRequest,
        priority: Priority = .normal
    ) async throws -> Data {
        let req = SpeechRequest(
            model: payload.model,
            input: payload.input,
            voice: payload.voice,
            instruct: payload.instruct,
            referenceAudio: payload.referenceAudio,
            referenceText: payload.referenceText,
            xVectorOnlyMode: payload.xVectorOnlyMode,
            speed: payload.speed,
            responseFormat: payload.responseFormat,
            outputPath: nil
        )
        return try await sendRaw(method: "POST", path: "/v1/audio/speech", body: req, priority: priority)
    }

    public func vad(
        _ payload: VadRequest,
        priority: Priority = .normal
    ) async throws -> VadResponse {
        try await sendJSON(method: "POST", path: "/v1/audio/vad", body: payload, priority: priority)
    }

    public func listVoices() async throws -> [VoiceProfile] {
        let res: VoicesListResponse = try await sendJSON(
            method: "GET",
            path: "/v1/audio/voices",
            body: Optional<Int>.none,
            priority: .normal
        )
        return res.voices
    }

    public func registerVoice(_ payload: CreateVoiceRequest) async throws -> VoiceProfile {
        try await sendJSON(method: "POST", path: "/v1/audio/voices", body: payload, priority: .normal)
    }

    public func getVoice(_ voiceId: String) async throws -> VoiceProfile {
        try await sendJSON(
            method: "GET",
            path: "/v1/audio/voices/\(voiceId)",
            body: Optional<Int>.none,
            priority: .normal
        )
    }

    public func downloadVoiceSample(_ voiceId: String) async throws -> Data {
        try await sendRaw(
            method: "GET",
            path: "/v1/audio/voices/\(voiceId)/sample",
            body: Optional<Int>.none,
            priority: .normal
        )
    }

    public func deleteVoice(_ voiceId: String) async throws {
        _ = try await sendRaw(
            method: "DELETE",
            path: "/v1/audio/voices/\(voiceId)",
            body: Optional<Int>.none,
            priority: .normal
        )
    }

    public func createSpeechBatch(
        _ payload: CreateSpeechBatchRequest,
        priority: Priority = .batch
    ) async throws -> SpeechBatchState {
        try await sendJSON(
            method: "POST",
            path: "/v1/audio/speech/batches",
            body: payload,
            priority: priority
        )
    }

    public func listSpeechBatches() async throws -> [SpeechBatchState] {
        let res: SpeechBatchesListResponse = try await sendJSON(
            method: "GET",
            path: "/v1/audio/speech/batches",
            body: Optional<Int>.none,
            priority: .normal
        )
        return res.batches
    }

    public func getSpeechBatch(_ batchId: String) async throws -> SpeechBatchState {
        try await sendJSON(
            method: "GET",
            path: "/v1/audio/speech/batches/\(batchId)",
            body: Optional<Int>.none,
            priority: .normal
        )
    }

    public func pauseSpeechBatch(_ batchId: String) async throws -> SpeechBatchState {
        try await sendJSON(
            method: "POST",
            path: "/v1/audio/speech/batches/\(batchId)/pause",
            body: Optional<Int>.none,
            priority: .normal
        )
    }

    public func resumeSpeechBatch(_ batchId: String) async throws -> SpeechBatchState {
        try await sendJSON(
            method: "POST",
            path: "/v1/audio/speech/batches/\(batchId)/resume",
            body: Optional<Int>.none,
            priority: .normal
        )
    }

    public func cancelSpeechBatch(_ batchId: String) async throws -> SpeechBatchState {
        try await sendJSON(
            method: "POST",
            path: "/v1/audio/speech/batches/\(batchId)/cancel",
            body: Optional<Int>.none,
            priority: .normal
        )
    }

    public func loadModel(_ modelId: String) async throws -> ModelStatusInfo {
        try await sendJSON(method: "POST", path: "/v1/models/\(modelId)/load", body: EmptyBody(), priority: .normal)
    }

    public func unloadModel(_ modelId: String) async throws -> ModelStatusInfo {
        try await sendJSON(method: "POST", path: "/v1/models/\(modelId)/unload", body: EmptyBody(), priority: .normal)
    }

    public func unloadAll(includePinned: Bool = false) async throws {
        _ = try await sendRaw(
            method: "POST",
            path: "/v1/system/unload-all",
            body: UnloadAllRequest(includePinned: includePinned),
            priority: .normal
        )
    }

    public func systemConfig() async throws -> SystemConfigResponse {
        try await sendJSON(
            method: "GET",
            path: "/v1/system/config",
            body: Optional<Int>.none,
            priority: .normal
        )
    }

    public func updateSystemConfig(_ update: UpdateSystemConfigRequest) async throws -> SystemConfigResponse {
        try await sendJSON(
            method: "PATCH",
            path: "/v1/system/config",
            body: update,
            priority: .normal
        )
    }

    public func updateModelConfig(
        _ modelId: String,
        update: UpdateModelConfigRequest
    ) async throws -> ModelStatusInfo {
        try await sendJSON(
            method: "PATCH",
            path: "/v1/models/\(modelId)/config",
            body: update,
            priority: .normal
        )
    }

    public func listDownloads() async throws -> [ModelDownloadState] {
        let res: ModelDownloadsListResponse = try await sendJSON(
            method: "GET",
            path: "/v1/models/downloads",
            body: Optional<Int>.none,
            priority: .normal
        )
        return res.downloads
    }

    public func startModelDownload(
        _ modelId: String,
        quant: String? = nil
    ) async throws -> ModelDownloadState {
        try await sendJSON(
            method: "POST",
            path: "/v1/models/\(modelId)/download",
            body: StartDownloadRequest(quant: quant),
            priority: .normal
        )
    }

    public func getModelDownload(_ modelId: String) async throws -> ModelDownloadState {
        try await sendJSON(
            method: "GET",
            path: "/v1/models/\(modelId)/download",
            body: Optional<Int>.none,
            priority: .normal
        )
    }

    public func cancelModelDownload(_ modelId: String) async throws -> ModelDownloadState {
        try await sendJSON(
            method: "POST",
            path: "/v1/models/\(modelId)/download/cancel",
            body: Optional<Int>.none,
            priority: .normal
        )
    }

    public func deleteModel(_ modelId: String, quant: String? = nil) async throws {
        var path = "/v1/models/\(modelId)"
        if let quant, !quant.isEmpty,
           let encoded = quant.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        {
            path += "?quant=\(encoded)"
        }
        _ = try await sendRaw(
            method: "DELETE",
            path: path,
            body: Optional<Int>.none,
            priority: .normal
        )
    }

    public func systemEventsStream() -> AsyncThrowingStream<SystemEventEnvelope, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try buildURLRequest(
                        method: "GET",
                        path: "/v1/system/events",
                        body: Optional<Int>.none,
                        priority: .normal,
                        authenticated: true
                    )
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw URLError(.badServerResponse)
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        throw URLError(.badServerResponse)
                    }
                    for try await line in bytes.lines {
                        if let ev = Self.parseSystemEventSSELine(line) {
                            continuation.yield(ev)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public static func parseSystemEventSSELine(_ line: String) -> SystemEventEnvelope? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return nil }
        let jsonStr = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        guard !jsonStr.isEmpty, let data = jsonStr.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(SystemEventEnvelope.self, from: data)
    }

    private func buildURLRequest<Req: Encodable>(
        method: String,
        path: String,
        body: Req?,
        priority: Priority,
        authenticated: Bool
    ) throws -> URLRequest {
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
        return request
    }

    private func sendJSON<Req: Encodable, Res: Decodable>(
        method: String,
        path: String,
        body: Req?,
        priority: Priority,
        authenticated: Bool = true
    ) async throws -> Res {
        let data = try await sendRaw(
            method: method,
            path: path,
            body: body,
            priority: priority,
            authenticated: authenticated
        )
        return try JSONDecoder().decode(Res.self, from: data)
    }

    private func sendRaw<Req: Encodable>(
        method: String,
        path: String,
        body: Req?,
        priority: Priority,
        authenticated: Bool = true
    ) async throws -> Data {
        let request = try buildURLRequest(
            method: method,
            path: path,
            body: body,
            priority: priority,
            authenticated: authenticated
        )

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
        return data
    }

    private struct EmptyBody: Codable, Sendable {}
}
