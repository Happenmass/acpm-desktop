import AcpmClient
import Foundation
import Testing

struct AcpmClientTests {
    @Test func decodesRuntimeDiscoveryAndApiError() throws {
        let discoveryJSON = """
        {
          "version": 1,
          "pid": 12345,
          "started_at": "2026-11-23T12:40:00Z",
          "http_base_url": "http://127.0.0.1:18790",
          "native_ipc_path": "/tmp/daemon.sock",
          "token": "secret",
          "platform": "darwin-arm64",
          "capabilities": ["llm", "asr", "tts"],
          "mdns_hostname": "acpm.local",
          "mdns_base_url": "http://acpm.local:18790"
        }
        """
        let discovery = try JSONDecoder().decode(RuntimeDiscovery.self, from: Data(discoveryJSON.utf8))
        #expect(discovery.pid == 12345)
        #expect(discovery.baseURL?.absoluteString == "http://127.0.0.1:18790")
        #expect(discovery.mdnsHostname == "acpm.local")
        #expect(discovery.mdnsURL?.absoluteString == "http://acpm.local:18790")

        let mdnsClient = try AcpmClient.fromMdns(token: "secret")
        #expect(mdnsClient.baseURL.absoluteString == "http://acpm.local:18790")

        let errorJSON = """
        {
          "error": {
            "code": "MODEL_NOT_INSTALLED",
            "message": "Missing model",
            "request_id": "req-1",
            "stage": "MODEL_PREPARE",
            "detail": "MISSING_WEIGHT_FILES",
            "native_code": null,
            "elapsed_ms": 5,
            "retryable": false
          }
        }
        """
        let envelope = try JSONDecoder().decode(ApiErrorEnvelope.self, from: Data(errorJSON.utf8))
        #expect(envelope.error.code == .modelNotInstalled)
        #expect(envelope.error.stage == "MODEL_PREPARE")
    }

    @Test func encodesVoiceCloningSpeechRequestAndDecodesReasoningResponse() throws {
        let req = SpeechRequest(
            model: "qwen3-tts-1.7b",
            input: "测试配音",
            referenceAudio: "/tmp/ref.wav",
            referenceText: "参考录音文本",
            outputPath: "/tmp/out.wav"
        )
        let encoded = try JSONEncoder().encode(req)
        let jsonObject = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(jsonObject["reference_audio"] as? String == "/tmp/ref.wav")
        #expect(jsonObject["reference_text"] as? String == "参考录音文本")
        #expect(jsonObject["output_path"] as? String == "/tmp/out.wav")

        let chatJSON = """
        {
          "id": "chatcmpl-1",
          "object": "chat.completion",
          "created": 1763872800,
          "model": "yanmo-correct-4b-cot",
          "choices": [
            {
              "index": 0,
              "message": {
                "role": "assistant",
                "reasoning_content": "纠错思考",
                "content": "纠错结果"
              },
              "finish_reason": "stop"
            }
          ]
        }
        """
        let chat = try JSONDecoder().decode(ChatCompletionResponse.self, from: Data(chatJSON.utf8))
        #expect(chat.choices.first?.message.reasoningContent == "纠错思考")
        #expect(chat.choices.first?.message.content == "纠错结果")
    }

    @Test func parsesSSEChunksAndEncodesPrewarmRequest() throws {
        let rLine = #"data: {"id":"c1","object":"chat.completion.chunk","created":1,"model":"yanmo-correct-4b-cot","choices":[{"index":0,"delta":{"role":"assistant","reasoning_content":"先分析"},"finish_reason":null}]}"#
        let cLine = #"data: {"id":"c1","object":"chat.completion.chunk","created":1,"model":"yanmo-correct-4b-cot","choices":[{"index":0,"delta":{"content":"明天去北京"},"finish_reason":null}]}"#
        let stopLine = #"data: {"id":"c1","object":"chat.completion.chunk","created":1,"model":"yanmo-correct-4b-cot","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#
        let doneLine = "data: [DONE]"

        let rDelta = AcpmClient.parseSSEDataLine(rLine)
        #expect(rDelta == ChatStreamDelta(reasoningContent: "先分析", content: nil, finishReason: nil))

        let cDelta = AcpmClient.parseSSEDataLine(cLine)
        #expect(cDelta == ChatStreamDelta(reasoningContent: nil, content: "明天去北京", finishReason: nil))

        let stopDelta = AcpmClient.parseSSEDataLine(stopLine)
        #expect(stopDelta == ChatStreamDelta(reasoningContent: nil, content: nil, finishReason: "stop"))

        #expect(AcpmClient.parseSSEDataLine(doneLine) == nil)
        #expect(AcpmClient.parseSSEDataLine(": keep-alive") == nil)

        let prewarm = PrewarmRequest(
            models: ["qwen3-asr-1.7b", "yanmo-correct-4b-cot"],
            promptCacheKeys: ["yanmo-default"]
        )
        let data = try JSONEncoder().encode(prewarm)
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((obj["models"] as? [String])?.count == 2)
        #expect(obj["prompt_cache_keys"] as? [String] == ["yanmo-default"])
    }

    @Test func encodesAndDecodesVadVoicesAndSpeechBatchTypes() async throws {
        final class MockURLProtocol: URLProtocol, @unchecked Sendable {
            private static let lock = NSLock()
            nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, [String: String], Data))?
            nonisolated(unsafe) static var recorded: [(String, String)] = []

            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

            override func startLoading() {
                Self.lock.lock()
                Self.recorded.append((request.httpMethod ?? "", request.url?.path ?? ""))
                let h = Self.handler
                Self.lock.unlock()

                guard let h else {
                    client?.urlProtocol(self, didFailWithError: URLError(.unknown))
                    return
                }
                do {
                    let (status, headers, body) = try h(request)
                    let resp = HTTPURLResponse(
                        url: request.url!,
                        statusCode: status,
                        httpVersion: "HTTP/1.1",
                        headerFields: headers
                    )!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: body)
                    client?.urlProtocolDidFinishLoading(self)
                } catch {
                    client?.urlProtocol(self, didFailWithError: error)
                }
            }

            override func stopLoading() {}
        }

        MockURLProtocol.handler = { req in
            switch (req.httpMethod ?? "", req.url?.path ?? "") {
            case ("POST", "/v1/audio/vad"):
                let json = #"{"segments":[{"start_ms":200,"end_ms":1800}],"duration_ms":2000}"#
                return (200, ["Content-Type": "application/json"], Data(json.utf8))
            case ("POST", "/v1/audio/voices"):
                let json = #"{"voice_id":"v_1","name":"Narrator","reference_text":"hi","language":"en","notes":"studio","duration_ms":1200,"sha256":"abc","created_at":"2026-11-23T12:00:00Z"}"#
                return (201, ["Content-Type": "application/json"], Data(json.utf8))
            case ("GET", "/v1/audio/voices"):
                let json = #"{"voices":[{"voice_id":"v_1","name":"Narrator","reference_text":"hi","language":"en","notes":"studio","duration_ms":1200,"sha256":"abc","created_at":"2026-11-23T12:00:00Z"}]}"#
                return (200, ["Content-Type": "application/json"], Data(json.utf8))
            case ("GET", "/v1/audio/voices/v_1/sample"):
                return (200, ["Content-Type": "audio/wav"], Data("RIFFtestWAVE".utf8))
            case ("DELETE", "/v1/audio/voices/v_1"):
                return (204, [:], Data())
            case ("POST", "/v1/audio/speech/batches"):
                let json = #"{"batch_id":"sb_1","model":"qwen3-tts-1.7b","status":"queued","total":1,"completed":0,"failed":0,"created_at":"2026-11-23T12:00:00Z","updated_at":"2026-11-23T12:00:00Z","items":[{"id":"s1","output_path":"/tmp/1.wav","status":"pending"}]}"#
                return (202, ["Content-Type": "application/json"], Data(json.utf8))
            case ("POST", "/v1/audio/speech/batches/sb_1/pause"):
                let json = #"{"batch_id":"sb_1","model":"qwen3-tts-1.7b","status":"paused","total":1,"completed":0,"failed":0,"created_at":"2026-11-23T12:00:00Z","updated_at":"2026-11-23T12:00:01Z","items":[{"id":"s1","output_path":"/tmp/1.wav","status":"pending"}]}"#
                return (200, ["Content-Type": "application/json"], Data(json.utf8))
            case ("POST", "/v1/audio/speech/batches/sb_1/resume"):
                let json = #"{"batch_id":"sb_1","model":"qwen3-tts-1.7b","status":"running","total":1,"completed":0,"failed":0,"created_at":"2026-11-23T12:00:00Z","updated_at":"2026-11-23T12:00:02Z","items":[{"id":"s1","output_path":"/tmp/1.wav","status":"running"}]}"#
                return (200, ["Content-Type": "application/json"], Data(json.utf8))
            case ("POST", "/v1/audio/speech/batches/sb_1/cancel"):
                let json = #"{"batch_id":"sb_1","model":"qwen3-tts-1.7b","status":"cancelled","total":1,"completed":0,"failed":0,"created_at":"2026-11-23T12:00:00Z","updated_at":"2026-11-23T12:00:03Z","items":[{"id":"s1","output_path":"/tmp/1.wav","status":"cancelled"}]}"#
                return (200, ["Content-Type": "application/json"], Data(json.utf8))
            default:
                return (404, [:], Data())
            }
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: cfg)
        let client = AcpmClient(
            baseURL: URL(string: "http://127.0.0.1:18790")!,
            token: "tok",
            caller: "swift-test",
            session: session
        )

        let vadResp = try await client.vad(VadRequest(filePath: "/tmp/a.wav", minSpeechMs: 250))
        #expect(vadResp.segments == [VadSegment(startMs: 200, endMs: 1800)])
        #expect(vadResp.durationMs == 2000)

        let voice = try await client.registerVoice(CreateVoiceRequest(name: "Narrator", referenceAudio: "/tmp/ref.wav", referenceText: "hi", language: "en", notes: "studio"))
        #expect(voice.voiceId == "v_1")
        #expect(voice.notes == "studio")
        let voices = try await client.listVoices()
        #expect(voices.count == 1)
        let sample = try await client.downloadVoiceSample("v_1")
        #expect(String(data: sample, encoding: .utf8) == "RIFFtestWAVE")
        try await client.deleteVoice("v_1")

        let batch = try await client.createSpeechBatch(CreateSpeechBatchRequest(
            voice: "v_1",
            outputDir: "/tmp/out",
            items: [SpeechBatchItemInput(id: "s1", text: "你好", outputFile: "1.wav")]
        ))
        #expect(batch.status == .queued)
        #expect((try await client.pauseSpeechBatch("sb_1")).status == .paused)
        #expect((try await client.resumeSpeechBatch("sb_1")).status == .running)
        #expect((try await client.cancelSpeechBatch("sb_1")).status == .cancelled)
    }

    @Test func managesConfigDownloadsAndSystemEventsSSE() async throws {
        final class Phase3MockURLProtocol: URLProtocol, @unchecked Sendable {
            private static let lock = NSLock()
            nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, [String: String], Data))?

            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

            override func startLoading() {
                Self.lock.lock()
                let h = Self.handler
                Self.lock.unlock()
                guard let h else {
                    client?.urlProtocol(self, didFailWithError: URLError(.unknown))
                    return
                }
                do {
                    let (status, headers, body) = try h(request)
                    let resp = HTTPURLResponse(
                        url: request.url!,
                        statusCode: status,
                        httpVersion: "HTTP/1.1",
                        headerFields: headers
                    )!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: body)
                    client?.urlProtocolDidFinishLoading(self)
                } catch {
                    client?.urlProtocol(self, didFailWithError: error)
                }
            }

            override func stopLoading() {}
        }

        Phase3MockURLProtocol.handler = { req in
            switch (req.httpMethod ?? "", req.url?.path ?? "") {
            case ("GET", "/v1/system/config"), ("PATCH", "/v1/system/config"):
                let json = #"{"budget_tier":"eco","budget_override_mb":null,"effective_budget":{"unified_mb":9800},"data_dir":"/tmp/data","models_dir":"/tmp/data/models","voices_dir":"/tmp/data/voices","config_path":"/tmp/data/config.json","mdns_hostname":"acpm.local","mdns_base_url":"http://acpm.local:18790","http_base_url":"http://127.0.0.1:18790","model_overrides":{}}"#
                return (200, ["Content-Type": "application/json"], Data(json.utf8))
            case ("PATCH", "/v1/models/yanmo-correct-4b-cot/config"):
                let json = #"{"id":"yanmo-correct-4b-cot","capability":"llm","display_name":"Yanmo 4B CoT","selected_variant":"darwin-arm64-mlx-8bit","installed":true,"state":"WARM","pin_policy":"pinned","idle_timeout_sec":1200,"idle_remaining_sec":1195,"available_quants":["4bit","8bit"],"model_path":"/tmp/llm","memory":{"unified_mb":5265}}"#
                return (200, ["Content-Type": "application/json"], Data(json.utf8))
            case ("POST", "/v1/models/qwen3-asr-0.6b/download"):
                let json = #"{"model_id":"qwen3-asr-0.6b","variant_id":"darwin-arm64-mlx-4bit","status":"queued","downloaded_bytes":0,"total_bytes":1024,"current_file":"config.json","files_completed":0,"files_total":1,"sha256_verified":false,"updated_at":"2026-11-23T12:00:00Z"}"#
                return (202, ["Content-Type": "application/json"], Data(json.utf8))
            case ("GET", "/v1/models/downloads"):
                let json = #"{"downloads":[{"model_id":"qwen3-asr-0.6b","variant_id":"darwin-arm64-mlx-4bit","status":"completed","downloaded_bytes":1024,"total_bytes":1024,"files_completed":1,"files_total":1,"sha256_verified":true,"updated_at":"2026-11-23T12:00:05Z"}]}"#
                return (200, ["Content-Type": "application/json"], Data(json.utf8))
            case ("POST", "/v1/models/qwen3-asr-0.6b/download/cancel"):
                let json = #"{"model_id":"qwen3-asr-0.6b","variant_id":"darwin-arm64-mlx-4bit","status":"cancelled","downloaded_bytes":512,"total_bytes":1024,"files_completed":0,"files_total":1,"sha256_verified":false,"updated_at":"2026-11-23T12:00:06Z"}"#
                return (200, ["Content-Type": "application/json"], Data(json.utf8))
            case ("DELETE", "/v1/models/qwen3-asr-0.6b"):
                return (204, [:], Data())
            default:
                return (404, [:], Data())
            }
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [Phase3MockURLProtocol.self]
        let client = AcpmClient(
            baseURL: URL(string: "http://127.0.0.1:18790")!,
            token: "tok",
            caller: "swift-test",
            session: URLSession(configuration: cfg)
        )

        let sysCfg = try await client.updateSystemConfig(UpdateSystemConfigRequest(budgetTier: "eco"))
        #expect(sysCfg.budgetTier == "eco")
        #expect(sysCfg.effectiveBudget.totalMB == 9800)

        let mCfg = try await client.updateModelConfig(
            "yanmo-correct-4b-cot",
            update: UpdateModelConfigRequest(pinPolicy: "pinned", quant: "8bit")
        )
        #expect(mCfg.pinPolicy == "pinned")
        #expect(mCfg.availableQuants == ["4bit", "8bit"])
        #expect(mCfg.idleRemainingSec == 1195)

        let dlStart = try await client.startModelDownload("qwen3-asr-0.6b", quant: "4bit")
        #expect(dlStart.status == .queued)
        #expect((try await client.listDownloads()).first?.sha256Verified == true)
        #expect((try await client.cancelModelDownload("qwen3-asr-0.6b")).status == .cancelled)
        try await client.deleteModel("qwen3-asr-0.6b")

        let dlLine = #"data: {"event":"download_progress","download":{"model_id":"qwen3-asr-0.6b","variant_id":"darwin-arm64-mlx-4bit","status":"downloading","downloaded_bytes":512,"total_bytes":1024,"files_completed":0,"files_total":1,"sha256_verified":false,"updated_at":"2026-11-23T12:00:01Z"}}"#
        let parsedEv = AcpmClient.parseSystemEventSSELine(dlLine)
        if case .downloadProgress(let state) = parsedEv {
            #expect(state.downloadedBytes == 512)
            #expect(state.status == .downloading)
        } else {
            Issue.record("Expected downloadProgress SSE event, got \(String(describing: parsedEv))")
        }

        let cfgLine = #"data: {"event":"config_changed","budget_tier":"performance","budget":{"unified_mb":20000}}"#
        if case .configChanged(let tier, let budget) = AcpmClient.parseSystemEventSSELine(cfgLine) {
            #expect(tier == "performance")
            #expect(budget.totalMB == 20000)
        } else {
            Issue.record("Expected configChanged SSE event")
        }
    }

    @Test func returnsRawWavDataForSpeechAudioAndInitsSystemStatus() async throws {
        final class SpeechAudioMockURLProtocol: URLProtocol, @unchecked Sendable {
            private static let lock = NSLock()
            nonisolated(unsafe) static var capturedBody: Data?

            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

            override func startLoading() {
                let rawBody = request.httpBody ?? {
                    guard let stream = request.httpBodyStream else { return nil }
                    stream.open()
                    defer { stream.close() }
                    var data = Data()
                    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
                    defer { buf.deallocate() }
                    while stream.hasBytesAvailable {
                        let read = stream.read(buf, maxLength: 4096)
                        if read > 0 { data.append(buf, count: read) } else { break }
                    }
                    return data
                }()
                Self.lock.withLock {
                    Self.capturedBody = rawBody
                }
                let resp = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "audio/wav"]
                )!
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data("RIFF_WAV_BYTES".utf8))
                client?.urlProtocolDidFinishLoading(self)
            }

            override func stopLoading() {}
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [SpeechAudioMockURLProtocol.self]
        let client = AcpmClient(
            baseURL: URL(string: "http://127.0.0.1:18790")!,
            token: "tok",
            caller: "swift-test",
            session: URLSession(configuration: cfg)
        )

        let wav = try await client.speechAudio(SpeechRequest(
            input: "演练台语音测试",
            voice: "v_demo",
            outputPath: "/tmp/should-be-cleared.wav"
        ))
        #expect(String(data: wav, encoding: .utf8) == "RIFF_WAV_BYTES")

        let sentData = try #require(SpeechAudioMockURLProtocol.capturedBody)
        let sentObj = try #require(JSONSerialization.jsonObject(with: sentData) as? [String: Any])
        #expect(sentObj["voice"] as? String == "v_demo")
        #expect(sentObj["output_path"] == nil)

        let status = SystemStatusResponse(
            platform: "darwin-arm64",
            pid: 42,
            budget: ResourceVectorDTO(unifiedMB: 16000),
            used: ResourceVectorDTO(unifiedMB: 3200),
            memoryPressure: "normal",
            thermalState: "nominal",
            loadedModels: [],
            activeRequests: 1,
            queuedRequests: 0,
            callerCounts: ["yanmo": 5]
        )
        let encoded = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(SystemStatusResponse.self, from: encoded)
        #expect(decoded == status)
    }
}
