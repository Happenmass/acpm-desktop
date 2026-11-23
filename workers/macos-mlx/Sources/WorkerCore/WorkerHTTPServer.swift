import Darwin
import Foundation

public enum ServerEndpoint: Sendable, Equatable {
    case tcp(host: String, port: UInt16)
    case unix(path: String)
}

public protocol WorkerServerDelegate: Sendable {
    func serverState() async -> String
    func loadedModelsInfo() async -> [[String: Any]]
    func generateChat(_ request: HTTPChatRequest) async throws -> HTTPChatResponse
    func generateChatStream(
        _ request: HTTPChatRequest,
        onEvent: @Sendable (LLMStreamEvent) -> Bool
    ) async throws -> HTTPChatResponse
    func transcribeAudio(_ request: HTTPASRRequest) async throws -> ASRTranscriptionResult
    func synthesizeSpeech(_ request: HTTPTTSRequest) async throws -> TTSSynthesisResult
    func clearCaches() async
    func requestShutdown() async
}

public extension WorkerServerDelegate {
    func generateChatStream(
        _ request: HTTPChatRequest,
        onEvent: @Sendable (LLMStreamEvent) -> Bool
    ) async throws -> HTTPChatResponse {
        let response = try await generateChat(request)
        let res = response.result
        if onEvent(.start(
            promptTokens: res.promptTokens,
            kvCacheHit: res.kvCacheHit,
            promptStartsThink: res.promptStartsThink
        )) {
            let deltaText: String
            if res.promptStartsThink && res.rawText.hasPrefix("<think>\n") {
                deltaText = String(res.rawText.dropFirst("<think>\n".count))
            } else {
                deltaText = res.rawText
            }
            if onEvent(.delta(text: deltaText)) {
                _ = onEvent(.done(result: res))
            }
        }
        return response
    }
}

public struct HTTPChatRequest: Sendable {
    public let model: String?
    public let prompt: String
    public let systemPrompt: String?
    public let promptCacheKey: String?
    public let temperature: Float
    public let maxTokens: Int
    public let separateReasoning: Bool
    public let enableThinking: Bool
    public let stream: Bool
}

public struct HTTPChatResponse: Sendable {
    public let model: String
    public let result: LLMGenerationResult

    public init(model: String, result: LLMGenerationResult) {
        self.model = model
        self.result = result
    }
}

public struct HTTPASRRequest: Sendable {
    public let model: String?
    public let audioURL: URL
    public let language: String?
    public let prompt: String?
}

public struct HTTPTTSRequest: Sendable {
    public let model: String?
    public let text: String
    public let voice: String?
    public let instruct: String?
    public let referenceAudioURL: URL?
    public let referenceText: String?
    public let xVectorOnly: Bool
    public let language: String?
    public let temperature: Float?
    public let maxTokens: Int?
    public let outputURL: URL?
}

public struct WorkerHTTPServerConfig: Sendable {
    public let endpoints: [ServerEndpoint]
    public let token: String
    public let mdnsHost: String?
    public let activeLanIPProvider: (@Sendable () -> String?)?
    public let capabilities: [String]

    public init(
        endpoints: [ServerEndpoint],
        token: String,
        mdnsHost: String? = nil,
        activeLanIPProvider: (@Sendable () -> String?)? = nil,
        capabilities: [String] = ["llm", "asr", "tts"]
    ) {
        self.endpoints = endpoints
        self.token = token
        self.mdnsHost = mdnsHost
        self.activeLanIPProvider = activeLanIPProvider
        self.capabilities = capabilities
    }
}

public enum WorkerHTTPError: Error, Sendable {
    case bindFailed(String)
    case invalidRequest(String)
    case engineUnavailable(String)
}

private final class ListenerBox: @unchecked Sendable {
    let fd: Int32
    let isUnix: Bool
    let unixPath: String?
    let port: UInt16
    var thread: Thread?

    init(fd: Int32, isUnix: Bool, unixPath: String?, port: UInt16) {
        self.fd = fd
        self.isUnix = isUnix
        self.unixPath = unixPath
        self.port = port
    }
}

/// Lightweight dependency-free HTTP/1.1 server supporting both LAN/loopback TCP
/// and Unix Domain Sockets with Host allowlist, Origin rejection, and Bearer/Worker token auth.
public final class WorkerHTTPServer: @unchecked Sendable {
    private let config: WorkerHTTPServerConfig
    private let delegate: any WorkerServerDelegate
    private let lock = NSLock()
    private var listeners: [ListenerBox] = []
    private var stopped = false

    public private(set) var boundTCPPort: UInt16?

    public init(config: WorkerHTTPServerConfig, delegate: any WorkerServerDelegate) {
        self.config = config
        self.delegate = delegate
    }

    deinit {
        stop()
    }

    public static func parseListenAddress(_ raw: String) throws -> (host: String, port: UInt16) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") {
            guard let closeIdx = trimmed.firstIndex(of: "]") else {
                throw WorkerHTTPError.invalidRequest("Invalid IPv6 listen address: \(raw)")
            }
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closeIdx])
            let rest = trimmed[trimmed.index(after: closeIdx)...]
            guard rest.hasPrefix(":"), let port = UInt16(rest.dropFirst()) else {
                throw WorkerHTTPError.invalidRequest("Missing port in listen address: \(raw)")
            }
            return (host, port)
        }
        guard let colonIdx = trimmed.lastIndex(of: ":"),
              let port = UInt16(trimmed[trimmed.index(after: colonIdx)...])
        else {
            throw WorkerHTTPError.invalidRequest("Invalid listen address (expected host:port): \(raw)")
        }
        let host = String(trimmed[..<colonIdx])
        return (host.isEmpty ? "0.0.0.0" : host, port)
    }

    public static func extractHostName(_ rawHost: String) -> String? {
        let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("[") {
            guard let closeIdx = trimmed.firstIndex(of: "]") else { return nil }
            let inner = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closeIdx])
            let rest = String(trimmed[trimmed.index(after: closeIdx)...])
            guard rest.isEmpty || rest.hasPrefix(":") else { return nil }
            return inner.lowercased()
        }
        if let colonIdx = trimmed.lastIndex(of: ":") {
            let portPart = trimmed[trimmed.index(after: colonIdx)...]
            guard !portPart.isEmpty, portPart.allSatisfy(\.isNumber) else { return nil }
            let name = String(trimmed[..<colonIdx])
            return name.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    }

    public static func isAllowedHostHeader(
        _ rawHost: String,
        mdnsHost: String?,
        activeLanIP: String?
    ) -> Bool {
        guard let name = extractHostName(rawHost) else {
            return false
        }
        if name == "127.0.0.1" || name == "localhost" || name == "::1" {
            return true
        }
        if let mdnsHost {
            let normalized = mdnsHost.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            if !normalized.isEmpty && name == normalized {
                return true
            }
        }
        if let activeLanIP, !activeLanIP.isEmpty, name == activeLanIP.lowercased() {
            return true
        }
        return false
    }

    public func start() throws {
        _ = signal(SIGPIPE, SIG_IGN)
        for endpoint in config.endpoints {
            let box: ListenerBox
            switch endpoint {
            case .tcp(let host, let port):
                box = try bindTCP(host: host, port: port)
                if boundTCPPort == nil {
                    boundTCPPort = box.port
                }
            case .unix(let path):
                box = try bindUnix(path: path)
            }

            let thread = Thread { [weak self] in
                self?.acceptLoop(box)
            }
            thread.name = "acpm-http-accept-\(box.isUnix ? "uds" : "\(box.port)")"
            box.thread = thread
            lock.withLock {
                listeners.append(box)
            }
            thread.start()
        }
    }

    public func stop() {
        let toClose = lock.withLock { () -> [ListenerBox] in
            stopped = true
            let list = listeners
            listeners.removeAll()
            return list
        }
        for box in toClose {
            Darwin.close(box.fd)
            if let unixPath = box.unixPath {
                try? FileManager.default.removeItem(atPath: unixPath)
            }
        }
    }

    private func isStopped() -> Bool {
        lock.withLock { stopped }
    }

    private func bindTCP(host: String, port: UInt16) throws -> ListenerBox {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw WorkerHTTPError.bindFailed("socket(AF_INET) failed: errno=\(errno)")
        }
        var yes: Int32 = 1
        Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        if host == "0.0.0.0" || host.isEmpty {
            addr.sin_addr.s_addr = INADDR_ANY.bigEndian
        } else {
            let rc = host.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
            guard rc == 1 else {
                Darwin.close(fd)
                throw WorkerHTTPError.bindFailed("Invalid IPv4 bind address '\(host)'")
            }
        }

        let bindRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRes == 0 else {
            let err = errno
            Darwin.close(fd)
            throw WorkerHTTPError.bindFailed("bind(\(host):\(port)) failed: errno=\(err)")
        }
        guard Darwin.listen(fd, 64) == 0 else {
            let err = errno
            Darwin.close(fd)
            throw WorkerHTTPError.bindFailed("listen failed: errno=\(err)")
        }

        var actualAddr = sockaddr_in()
        var actualLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameRes = withUnsafeMutablePointer(to: &actualAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.getsockname(fd, sockPtr, &actualLen)
            }
        }
        let actualPort = nameRes == 0 ? UInt16(bigEndian: actualAddr.sin_port) : port
        return ListenerBox(fd: fd, isUnix: false, unixPath: nil, port: actualPort)
    }

    private func bindUnix(path: String) throws -> ListenerBox {
        let fm = FileManager.default
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        if fm.fileExists(atPath: path) {
            try? fm.removeItem(atPath: path)
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw WorkerHTTPError.bindFailed("socket(AF_UNIX) failed: errno=\(errno)")
        }
        var yes: Int32 = 1
        Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < maxLen else {
            Darwin.close(fd)
            throw WorkerHTTPError.bindFailed("Unix socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { rawBuf in
            rawBuf.initializeMemory(as: UInt8.self, repeating: 0)
            for (i, b) in pathBytes.enumerated() {
                rawBuf[i] = b
            }
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let bindRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindRes == 0 else {
            let err = errno
            Darwin.close(fd)
            throw WorkerHTTPError.bindFailed("bind(\(path)) failed: errno=\(err)")
        }
        Darwin.chmod(path, 0o600)
        guard Darwin.listen(fd, 64) == 0 else {
            let err = errno
            Darwin.close(fd)
            throw WorkerHTTPError.bindFailed("listen(\(path)) failed: errno=\(err)")
        }
        return ListenerBox(fd: fd, isUnix: true, unixPath: path, port: 0)
    }

    private func acceptLoop(_ box: ListenerBox) {
        while !isStopped() {
            var pfd = pollfd(fd: box.fd, events: Int16(POLLIN), revents: 0)
            let pr = Darwin.poll(&pfd, 1, 200)
            if pr < 0 {
                if errno == EINTR { continue }
                break
            }
            if pr == 0 { continue }

            var storage = sockaddr_storage()
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let clientFd = withUnsafeMutablePointer(to: &storage) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.accept(box.fd, sockPtr, &len)
                }
            }
            if clientFd < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                break
            }
            var yes: Int32 = 1
            Darwin.setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            let isUnix = box.isUnix
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else {
                    Darwin.close(clientFd)
                    return
                }
                await self.handleClientConnection(clientFd, isUnixSocket: isUnix)
            }
        }
    }

    private func handleClientConnection(_ fd: Int32, isUnixSocket: Bool) async {
        defer { Darwin.close(fd) }

        guard let request = Self.readHTTPRequest(fd: fd) else {
            return
        }
        let requestID = request.headers["x-ai-request-id"].flatMap { $0.isEmpty ? nil : $0 }
            ?? UUID().uuidString.lowercased()

        if !isUnixSocket, let hostHeader = request.headers["host"] {
            let lanIP = config.activeLanIPProvider?()
            if !Self.isAllowedHostHeader(hostHeader, mdnsHost: config.mdnsHost, activeLanIP: lanIP) {
                Self.writeAPIError(
                    fd: fd,
                    status: 403,
                    code: "FORBIDDEN",
                    stage: "HTTP_ADMISSION",
                    detail: "INVALID_HOST_HEADER",
                    message: "Rejected non-loopback or non-LAN Host header.",
                    requestID: requestID
                )
                return
            }
        }

        if let origin = request.headers["origin"], !origin.isEmpty {
            Self.writeAPIError(
                fd: fd,
                status: 403,
                code: "FORBIDDEN",
                stage: "HTTP_ADMISSION",
                detail: "ORIGIN_HEADER_REJECTED",
                message: "Browser cross-origin requests are blocked.",
                requestID: requestID
            )
            return
        }

        let isHealth = request.method == "GET" && (request.path == "/healthz" || request.path == "/health")
        if !isHealth {
            let bearer = request.headers["authorization"]
            let workerToken = request.headers["x-worker-token"]
            let expectedBearer = "Bearer \(config.token)"
            if bearer != expectedBearer && workerToken != config.token {
                Self.writeAPIError(
                    fd: fd,
                    status: 401,
                    code: "UNAUTHORIZED",
                    stage: "HTTP_ADMISSION",
                    detail: "INVALID_OR_MISSING_TOKEN",
                    message: "Missing or invalid Bearer / X-Worker-Token.",
                    requestID: requestID
                )
                return
            }
        }

        await routeRequest(request, fd: fd, requestID: requestID)
    }

    private func routeRequest(_ req: ParsedHTTPRequest, fd: Int32, requestID: String) async {
        do {
            switch (req.method, req.path) {
            case ("GET", "/healthz"), ("GET", "/health"):
                let state = await delegate.serverState()
                let models = await delegate.loadedModelsInfo()
                var payload: [String: Any] = [
                    "status": "ok",
                    "state": state,
                    "capabilities": config.capabilities,
                    "models": models,
                    "memory": ["unified_mb": ProcessMemory.currentUnifiedMB()],
                ]
                if let mdnsHost = config.mdnsHost, let port = boundTCPPort {
                    payload["mdns_hostname"] = mdnsHost
                    payload["mdns_base_url"] = "http://\(mdnsHost):\(port)"
                }
                Self.writeJSONResponse(fd: fd, status: 200, object: payload, requestID: requestID)

            case ("GET", "/v1/models"):
                let models = await delegate.loadedModelsInfo()
                Self.writeJSONResponse(fd: fd, status: 200, object: ["models": models], requestID: requestID)

            case ("POST", "/v1/chat/completions"), ("POST", "/infer/chat"):
                try await handleChat(req, fd: fd, requestID: requestID)

            case ("POST", "/v1/audio/transcriptions"), ("POST", "/infer/asr"):
                try await handleASR(req, fd: fd, requestID: requestID)

            case ("POST", "/v1/audio/speech"), ("POST", "/infer/tts"):
                try await handleTTS(req, fd: fd, requestID: requestID)

            case ("POST", "/cache/clear"):
                await delegate.clearCaches()
                Self.writeJSONResponse(fd: fd, status: 200, object: ["status": "ok"], requestID: requestID)

            case ("POST", "/shutdown"):
                Self.writeJSONResponse(fd: fd, status: 200, object: ["status": "shutting_down"], requestID: requestID)
                await delegate.requestShutdown()

            default:
                Self.writeAPIError(
                    fd: fd,
                    status: 404,
                    code: "NOT_FOUND",
                    stage: "HTTP_ADMISSION",
                    detail: "ROUTE_NOT_FOUND",
                    message: "Unknown endpoint \(req.method) \(req.path)",
                    requestID: requestID
                )
            }
        } catch let err as WorkerHTTPError {
            switch err {
            case .invalidRequest(let msg):
                Self.writeAPIError(
                    fd: fd,
                    status: 400,
                    code: "INVALID_REQUEST",
                    stage: "HTTP_ADMISSION",
                    detail: "INVALID_REQUEST",
                    message: msg,
                    requestID: requestID
                )
            case .engineUnavailable(let msg):
                Self.writeAPIError(
                    fd: fd,
                    status: 404,
                    code: "MODEL_NOT_INSTALLED",
                    stage: "MODEL_PREPARE",
                    detail: "ENGINE_NOT_LOADED",
                    message: msg,
                    requestID: requestID
                )
            case .bindFailed(let msg):
                Self.writeAPIError(
                    fd: fd,
                    status: 500,
                    code: "INFERENCE_FAILED",
                    stage: "WORKER_START",
                    detail: "BIND_FAILED",
                    message: msg,
                    requestID: requestID
                )
            }
        } catch {
            Self.writeAPIError(
                fd: fd,
                status: 500,
                code: "INFERENCE_FAILED",
                stage: "INFERENCE",
                detail: "ENGINE_EXECUTION_FAILED",
                message: String(describing: error),
                requestID: requestID
            )
        }
    }

    private func handleChat(_ req: ParsedHTTPRequest, fd: Int32, requestID: String) async throws {
        guard let json = try JSONSerialization.jsonObject(with: req.body) as? [String: Any] else {
            throw WorkerHTTPError.invalidRequest("Expected JSON object body")
        }

        let model = json["model"] as? String
        let temperature = (json["temperature"] as? NSNumber)?.floatValue ?? 0.0
        let maxTokens = (json["max_tokens"] as? NSNumber)?.intValue ?? 512
        let separateReasoning = (json["separate_reasoning"] as? Bool) ?? true
        let promptCacheKey = json["prompt_cache_key"] as? String
        let enableThinking = (json["enable_thinking"] as? Bool) ?? true
        let stream = (json["stream"] as? Bool) ?? false

        var systemPrompt = json["system_prompt"] as? String
        var userPrompt = json["prompt"] as? String ?? ""

        if let messages = json["messages"] as? [[String: Any]], !messages.isEmpty {
            var sysParts: [String] = []
            var userParts: [String] = []
            for msg in messages {
                let role = (msg["role"] as? String ?? "").lowercased()
                let content = msg["content"] as? String ?? ""
                if role == "system" {
                    sysParts.append(content)
                } else if role == "user" {
                    userParts.append(content)
                } else if !content.isEmpty {
                    userParts.append("\(role): \(content)")
                }
            }
            if !sysParts.isEmpty {
                systemPrompt = sysParts.joined(separator: "\n")
            }
            if !userParts.isEmpty {
                userPrompt = userParts.joined(separator: "\n")
            }
        }

        guard !userPrompt.isEmpty else {
            throw WorkerHTTPError.invalidRequest("Missing prompt or user message")
        }

        let chatReq = HTTPChatRequest(
            model: model,
            prompt: userPrompt,
            systemPrompt: systemPrompt,
            promptCacheKey: promptCacheKey,
            temperature: temperature,
            maxTokens: maxTokens,
            separateReasoning: separateReasoning,
            enableThinking: enableThinking,
            stream: stream
        )
        let isInternalRoute = req.path == "/infer/chat"

        if isInternalRoute && stream {
            let headLines = [
                "HTTP/1.1 200 OK",
                "Content-Type: application/x-ndjson; charset=utf-8",
                "Connection: close",
                "Cache-Control: no-cache",
                "X-AI-Request-Id: \(requestID)",
            ].joined(separator: "\r\n") + "\r\n\r\n"
            guard Self.sendAll(fd: fd, data: Data(headLines.utf8)) else {
                return
            }

            @Sendable
            func sendNDJSON(_ obj: [String: Any]) -> Bool {
                guard let jsonData = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else {
                    return true
                }
                var line = jsonData
                line.append(0x0A)
                return Self.sendAll(fd: fd, data: line)
            }

            do {
                _ = try await delegate.generateChatStream(chatReq) { event in
                    switch event {
                    case .start(let promptTokens, let kvCacheHit, let promptStartsThink):
                        return sendNDJSON([
                            "type": "start",
                            "prompt_tokens": promptTokens,
                            "kv_cache_hit": kvCacheHit,
                            "prompt_starts_think": promptStartsThink,
                        ])
                    case .delta(let text):
                        return sendNDJSON([
                            "type": "delta",
                            "text": text,
                        ])
                    case .done(let res):
                        return sendNDJSON([
                            "type": "done",
                            "prompt_tokens": res.promptTokens,
                            "completion_tokens": res.completionTokens,
                            "kv_cache_hit": res.kvCacheHit,
                            "ttft_ms": res.ttftMs,
                            "prefill_ms": res.prefillMs,
                            "decode_ms": res.decodeMs,
                            "prompt_starts_think": res.promptStartsThink,
                        ])
                    }
                }
            } catch {
                _ = sendNDJSON([
                    "type": "error",
                    "detail": "ENGINE_EXECUTION_FAILED",
                    "message": String(describing: error),
                ])
            }
            return
        }

        let response = try await delegate.generateChat(chatReq)
        let res = response.result

        let (reasoning, content) = CotSplitter.split(
            rawText: res.rawText,
            enabled: separateReasoning && !isInternalRoute
        )

        if stream && !isInternalRoute {
            let created = Int64(Date().timeIntervalSince1970)
            let chatID = "chatcmpl-\(UUID().uuidString.prefix(12))"
            var sseEvents = Data()
            func appendChunk(_ delta: [String: Any], finishReason: String? = nil) {
                let obj: [String: Any] = [
                    "id": chatID,
                    "object": "chat.completion.chunk",
                    "created": created,
                    "model": response.model,
                    "choices": [[
                        "index": 0,
                        "delta": delta,
                        "finish_reason": finishReason as Any,
                    ]],
                ]
                if let d = try? JSONSerialization.data(withJSONObject: obj) {
                    sseEvents.append(contentsOf: "data: ".utf8)
                    sseEvents.append(d)
                    sseEvents.append(contentsOf: "\n\n".utf8)
                }
            }
            if !reasoning.isEmpty {
                appendChunk(["role": "assistant", "reasoning_content": reasoning])
            }
            if !content.isEmpty {
                appendChunk(["content": content])
            }
            appendChunk([:], finishReason: "stop")
            sseEvents.append(contentsOf: "data: [DONE]\n\n".utf8)
            Self.writeRawResponse(
                fd: fd,
                status: 200,
                contentType: "text/event-stream; charset=utf-8",
                body: sseEvents,
                extraHeaders: ["X-AI-Request-Id": requestID, "Cache-Control": "no-cache"]
            )
            return
        }

        var messageObj: [String: Any] = [
            "role": "assistant",
            "content": isInternalRoute ? res.rawText : content,
        ]
        if !isInternalRoute && separateReasoning && !reasoning.isEmpty {
            messageObj["reasoning_content"] = reasoning
        }

        var payload: [String: Any] = [
            "id": "chatcmpl-\(UUID().uuidString.prefix(12))",
            "object": "chat.completion",
            "created": Int64(Date().timeIntervalSince1970),
            "model": response.model,
            "choices": [[
                "index": 0,
                "message": messageObj,
                "finish_reason": "stop",
            ]],
            "usage": [
                "prompt_tokens": res.promptTokens,
                "completion_tokens": res.completionTokens,
                "total_tokens": res.promptTokens + res.completionTokens,
            ],
            "x_acpm_timing": [
                "ttft_ms": res.ttftMs,
                "prefill_ms": res.prefillMs,
                "decode_ms": res.decodeMs,
                "kv_cache_hit": res.kvCacheHit,
            ],
        ]
        if isInternalRoute {
            payload["raw_text"] = res.rawText
            payload["prompt_starts_think"] = res.promptStartsThink
        }
        Self.writeJSONResponse(fd: fd, status: 200, object: payload, requestID: requestID)
    }

    private func handleASR(_ req: ParsedHTTPRequest, fd: Int32, requestID: String) async throws {
        let contentType = (req.headers["content-type"] ?? "").lowercased()
        var model: String?
        var language: String?
        var prompt: String?
        var audioURL: URL?
        var tempFileToDelete: URL?
        defer {
            if let tempFileToDelete {
                try? FileManager.default.removeItem(at: tempFileToDelete)
            }
        }

        if contentType.contains("multipart/form-data"),
           let boundary = Self.extractBoundary(contentType)
        {
            let parts = Self.parseMultipart(body: req.body, boundary: boundary)
            for part in parts {
                switch part.name {
                case "model":
                    model = String(data: part.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                case "language":
                    language = String(data: part.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                case "prompt":
                    prompt = String(data: part.data, encoding: .utf8)
                case "file":
                    let ext = part.filename.flatMap { URL(fileURLWithPath: $0).pathExtension }.flatMap { $0.isEmpty ? nil : $0 } ?? "wav"
                    let tmp = FileManager.default.temporaryDirectory
                        .appendingPathComponent("acpm-asr-\(UUID().uuidString).\(ext)")
                    try part.data.write(to: tmp)
                    audioURL = tmp
                    tempFileToDelete = tmp
                default:
                    break
                }
            }
        } else {
            guard let json = try JSONSerialization.jsonObject(with: req.body) as? [String: Any] else {
                throw WorkerHTTPError.invalidRequest("Expected JSON or multipart/form-data")
            }
            model = json["model"] as? String
            language = json["language"] as? String
            prompt = json["prompt"] as? String
            if let filePath = json["file_path"] as? String, !filePath.isEmpty {
                audioURL = URL(fileURLWithPath: filePath)
            } else if let b64 = json["audio_base64"] as? String,
                      let decoded = Data(base64Encoded: b64)
            {
                let ext = (json["audio_format"] as? String) ?? "wav"
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("acpm-asr-\(UUID().uuidString).\(ext)")
                try decoded.write(to: tmp)
                audioURL = tmp
                tempFileToDelete = tmp
            }
        }

        guard let resolvedAudioURL = audioURL,
              FileManager.default.fileExists(atPath: resolvedAudioURL.path)
        else {
            throw WorkerHTTPError.invalidRequest("Missing or unreadable audio file_path / file upload")
        }

        let result = try await delegate.transcribeAudio(
            HTTPASRRequest(model: model, audioURL: resolvedAudioURL, language: language, prompt: prompt)
        )
        let segmentObjs: [[String: Any]] = result.segments.map { seg in
            ["start_ms": seg.startMs, "end_ms": seg.endMs, "text": seg.text]
        }
        let payload: [String: Any] = [
            "text": result.text,
            "language": result.language as Any,
            "duration_ms": result.durationMs,
            "segments": segmentObjs,
            "x_acpm_timing": [
                "decode_ms": result.decodeMs,
            ],
        ]
        Self.writeJSONResponse(fd: fd, status: 200, object: payload, requestID: requestID)
    }

    private func handleTTS(_ req: ParsedHTTPRequest, fd: Int32, requestID: String) async throws {
        guard let json = try JSONSerialization.jsonObject(with: req.body) as? [String: Any] else {
            throw WorkerHTTPError.invalidRequest("Expected JSON object body")
        }

        let model = json["model"] as? String
        let text = (json["input"] as? String) ?? (json["text"] as? String) ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkerHTTPError.invalidRequest("Missing 'input' text for synthesis")
        }

        let voice = json["voice"] as? String
        let instruct = json["instruct"] as? String
        let referenceText = json["reference_text"] as? String
        let xVectorOnly = (json["x_vector_only_mode"] as? Bool) ?? false
        let language = json["language"] as? String
        let temperature = (json["temperature"] as? NSNumber)?.floatValue
        let maxTokens = (json["max_tokens"] as? NSNumber)?.intValue
        let explicitOutputPath = (json["output_path"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        var refAudioURL: URL?
        var tempRefToDelete: URL?
        defer {
            if let tempRefToDelete {
                try? FileManager.default.removeItem(at: tempRefToDelete)
            }
        }
        if let refPath = json["reference_audio"] as? String, !refPath.isEmpty {
            refAudioURL = URL(fileURLWithPath: refPath)
        } else if let refB64 = json["reference_audio_base64"] as? String,
                  let decoded = Data(base64Encoded: refB64)
        {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("acpm-tts-ref-\(UUID().uuidString).wav")
            try decoded.write(to: tmp)
            refAudioURL = tmp
            tempRefToDelete = tmp
        }

        let tempOutURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("acpm-tts-out-\(UUID().uuidString).wav")
        let targetOutURL = explicitOutputPath.map { URL(fileURLWithPath: $0) } ?? tempOutURL
        defer {
            if explicitOutputPath == nil {
                try? FileManager.default.removeItem(at: tempOutURL)
            }
        }

        let ttsReq = HTTPTTSRequest(
            model: model,
            text: text,
            voice: voice,
            instruct: instruct,
            referenceAudioURL: refAudioURL,
            referenceText: referenceText,
            xVectorOnly: xVectorOnly,
            language: language,
            temperature: temperature,
            maxTokens: maxTokens,
            outputURL: targetOutURL
        )
        let result = try await delegate.synthesizeSpeech(ttsReq)

        if let explicitOutputPath {
            let fileAttrs = try? FileManager.default.attributesOfItem(atPath: result.outputURL.path)
            let bytes = (fileAttrs?[.size] as? NSNumber)?.uint64Value ?? 0
            let payload: [String: Any] = [
                "output_path": explicitOutputPath,
                "bytes": bytes,
                "sample_rate": result.sampleRate,
                "duration_ms": result.durationMs,
                "voice_cache_hit": result.voiceCacheHit,
                "x_acpm_timing": [
                    "voice_encode_ms": result.voiceEncodeMs,
                    "decode_ms": result.decodeMs,
                ],
            ]
            Self.writeJSONResponse(fd: fd, status: 200, object: payload, requestID: requestID)
        } else {
            let wavData = try Data(contentsOf: result.outputURL)
            Self.writeRawResponse(
                fd: fd,
                status: 200,
                contentType: "audio/wav",
                body: wavData,
                extraHeaders: [
                    "X-AI-Request-Id": requestID,
                    "X-AI-Audio-Duration-Ms": "\(result.durationMs)",
                    "X-AI-Timing-Decode-Ms": String(format: "%.2f", result.decodeMs),
                    "X-AI-Voice-Cache-Hit": result.voiceCacheHit ? "true" : "false",
                ]
            )
        }
    }

    // MARK: - Low-level HTTP/1.1 Parsing & Writing

    private struct ParsedHTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private struct MultipartField {
        let name: String
        let filename: String?
        let data: Data
    }

    private static func readHTTPRequest(fd: Int32) -> ParsedHTTPRequest? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16_384)
        let headerSeparator = Data("\r\n\r\n".utf8)
        let maxHeaderSize = 64 * 1024
        let maxBodySize = 128 * 1024 * 1024

        var headerEndRange: Range<Data.Index>?
        while headerEndRange == nil {
            let n = chunk.withUnsafeMutableBytes { ptr in
                Darwin.recv(fd, ptr.baseAddress, ptr.count, 0)
            }
            if n <= 0 { break }
            buffer.append(chunk, count: n)
            if buffer.count > maxHeaderSize && buffer.range(of: headerSeparator) == nil {
                return nil
            }
            headerEndRange = buffer.range(of: headerSeparator)
        }

        guard let separatorRange = headerEndRange else { return nil }
        let headerData = buffer[..<separatorRange.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let rawTarget = String(parts[1])
        let path = rawTarget.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawTarget

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = val
        }

        var body = Data(buffer[separatorRange.upperBound...])
        if let contentLengthStr = headers["content-length"], let expectedLen = Int(contentLengthStr) {
            if expectedLen > maxBodySize || expectedLen < 0 { return nil }
            while body.count < expectedLen {
                let remaining = expectedLen - body.count
                let toRead = min(remaining, chunk.count)
                let n = chunk.withUnsafeMutableBytes { ptr in
                    Darwin.recv(fd, ptr.baseAddress, toRead, 0)
                }
                if n <= 0 { break }
                body.append(chunk, count: n)
            }
            if body.count > expectedLen {
                body = body.prefix(expectedLen)
            }
        }

        return ParsedHTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    private static func extractBoundary(_ contentType: String) -> String? {
        for component in contentType.split(separator: ";") {
            let trimmed = component.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("boundary=") {
                var val = String(trimmed.dropFirst("boundary=".count))
                val = val.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                return val
            }
        }
        return nil
    }

    private static func parseMultipart(body: Data, boundary: String) -> [MultipartField] {
        let delimiter = Data("--\(boundary)".utf8)
        let headerSep = Data("\r\n\r\n".utf8)
        var fields: [MultipartField] = []

        var searchStart = body.startIndex
        while let startRange = body.range(of: delimiter, in: searchStart..<body.endIndex) {
            let partStart = startRange.upperBound
            guard partStart < body.endIndex else { break }
            if body[partStart...].starts(with: Data("--".utf8)) { break }

            let contentStart: Data.Index
            if body[partStart...].starts(with: Data("\r\n".utf8)) {
                contentStart = body.index(partStart, offsetBy: 2)
            } else {
                contentStart = partStart
            }

            guard let nextBoundary = body.range(of: delimiter, in: contentStart..<body.endIndex) else {
                break
            }
            var partEnd = nextBoundary.lowerBound
            if partEnd >= body.index(contentStart, offsetBy: 2),
               body[body.index(partEnd, offsetBy: -2)..<partEnd] == Data("\r\n".utf8)
            {
                partEnd = body.index(partEnd, offsetBy: -2)
            }

            if let sepRange = body.range(of: headerSep, in: contentStart..<partEnd) {
                let headerStr = String(data: body[contentStart..<sepRange.lowerBound], encoding: .utf8) ?? ""
                let fieldData = Data(body[sepRange.upperBound..<partEnd])
                var fieldName = ""
                var filename: String?
                for line in headerStr.components(separatedBy: "\r\n") {
                    if line.lowercased().hasPrefix("content-disposition:") {
                        if let nRange = line.range(of: "name=\"") {
                            let rest = line[nRange.upperBound...]
                            if let endQuote = rest.firstIndex(of: "\"") {
                                fieldName = String(rest[..<endQuote])
                            }
                        }
                        if let fRange = line.range(of: "filename=\"") {
                            let rest = line[fRange.upperBound...]
                            if let endQuote = rest.firstIndex(of: "\"") {
                                filename = String(rest[..<endQuote])
                            }
                        }
                    }
                }
                if !fieldName.isEmpty {
                    fields.append(MultipartField(name: fieldName, filename: filename, data: fieldData))
                }
            }
            searchStart = nextBoundary.lowerBound
        }
        return fields
    }

    private static func writeAPIError(
        fd: Int32,
        status: Int,
        code: String,
        stage: String,
        detail: String,
        message: String,
        requestID: String
    ) {
        let obj: [String: Any] = [
            "error": [
                "code": code,
                "message": message,
                "request_id": requestID,
                "stage": stage,
                "detail": detail,
                "native_code": NSNull(),
                "elapsed_ms": 0,
                "retryable": false,
            ]
        ]
        writeJSONResponse(fd: fd, status: status, object: obj, requestID: requestID)
    }

    private static func writeJSONResponse(
        fd: Int32,
        status: Int,
        object: Any,
        requestID: String
    ) {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        writeRawResponse(
            fd: fd,
            status: status,
            contentType: "application/json; charset=utf-8",
            body: data,
            extraHeaders: ["X-AI-Request-Id": requestID]
        )
    }

    private static func writeRawResponse(
        fd: Int32,
        status: Int,
        contentType: String,
        body: Data,
        extraHeaders: [String: String] = [:]
    ) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        default: reason = "Internal Server Error"
        }

        var headerLines = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Connection: close",
        ]
        for (k, v) in extraHeaders.sorted(by: { $0.key < $1.key }) {
            headerLines.append("\(k): \(v)")
        }
        let head = headerLines.joined(separator: "\r\n") + "\r\n\r\n"
        var full = Data(head.utf8)
        full.append(body)
        _ = sendAll(fd: fd, data: full)
    }

    @discardableResult
    private static func sendAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return true }
            var offset = 0
            while offset < data.count {
                let sent = Darwin.send(fd, base.advanced(by: offset), data.count - offset, 0)
                if sent <= 0 {
                    if sent < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                    return false
                }
                offset += sent
            }
            return true
        }
    }
}
