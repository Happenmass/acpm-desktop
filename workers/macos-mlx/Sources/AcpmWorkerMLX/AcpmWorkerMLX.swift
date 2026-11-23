import EngineASR
import EngineLLM
import EngineTTS
import Foundation
import MLX
import WorkerCore

private actor GPUSlot {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T: Sendable>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        if busy {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        busy = true
        defer {
            if waiters.isEmpty {
                busy = false
            } else {
                let next = waiters.removeFirst()
                next.resume()
            }
        }
        return try await operation()
    }
}

private actor ShutdownLatch {
    private var triggered = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func trigger() {
        guard !triggered else { return }
        triggered = true
        for cont in continuations {
            cont.resume()
        }
        continuations.removeAll()
    }

    func wait() async {
        if triggered { return }
        await withCheckedContinuation { continuation in
            if triggered {
                continuation.resume()
            } else {
                continuations.append(continuation)
            }
        }
    }
}

private final class WorkerRuntimeDelegate: WorkerServerDelegate, @unchecked Sendable {
    private let llmEngine: MLXLLMEngine?
    private let asrEngine: MLXASREngine?
    private let ttsEngine: MLXTTSEngine?
    private let gpuSlot = GPUSlot()
    private let shutdownLatch: ShutdownLatch
    private let lock = NSLock()
    private var currentState: String = WorkerState.warm.rawValue

    init(
        llmEngine: MLXLLMEngine?,
        asrEngine: MLXASREngine?,
        ttsEngine: MLXTTSEngine?,
        shutdownLatch: ShutdownLatch
    ) {
        self.llmEngine = llmEngine
        self.asrEngine = asrEngine
        self.ttsEngine = ttsEngine
        self.shutdownLatch = shutdownLatch
    }

    func serverState() async -> String {
        lock.withLock { currentState }
    }

    private func setRunning(_ running: Bool) {
        lock.withLock {
            currentState = running ? WorkerState.running.rawValue : WorkerState.warm.rawValue
        }
    }

    func loadedModelsInfo() async -> [[String: Any]] {
        let state = await serverState()
        let memMB = ProcessMemory.currentUnifiedMB()
        var list: [[String: Any]] = []
        if let llmEngine {
            list.append([
                "id": llmEngine.modelId,
                "capability": "llm",
                "state": state,
                "kv_cache_entries": await llmEngine.cachedPrefixCount(),
                "memory": ["unified_mb": memMB],
            ])
        }
        if let asrEngine {
            list.append([
                "id": asrEngine.modelId,
                "capability": "asr",
                "state": state,
                "memory": ["unified_mb": memMB],
            ])
        }
        if let ttsEngine {
            list.append([
                "id": ttsEngine.modelId,
                "capability": "tts",
                "state": state,
                "voice_cache_entries": await ttsEngine.cachedVoiceCount(),
                "memory": ["unified_mb": memMB],
            ])
        }
        return list
    }

    func generateChat(_ request: HTTPChatRequest) async throws -> HTTPChatResponse {
        guard let llmEngine else {
            throw WorkerHTTPError.engineUnavailable("LLM engine is not loaded in this worker")
        }
        return try await gpuSlot.withLock {
            setRunning(true)
            defer { setRunning(false) }
            let result = try await llmEngine.generate(
                LLMGenerationRequest(
                    prompt: request.prompt,
                    systemPrompt: request.systemPrompt,
                    promptCacheKey: request.promptCacheKey,
                    temperature: request.temperature,
                    maxTokens: request.maxTokens,
                    enableThinking: request.enableThinking
                )
            )
            return HTTPChatResponse(model: request.model ?? llmEngine.modelId, result: result)
        }
    }

    func generateChatStream(
        _ request: HTTPChatRequest,
        onEvent: @Sendable (LLMStreamEvent) -> Bool
    ) async throws -> HTTPChatResponse {
        guard let llmEngine else {
            throw WorkerHTTPError.engineUnavailable("LLM engine is not loaded in this worker")
        }
        return try await gpuSlot.withLock {
            setRunning(true)
            defer { setRunning(false) }
            let result = try await llmEngine.generateStream(
                LLMGenerationRequest(
                    prompt: request.prompt,
                    systemPrompt: request.systemPrompt,
                    promptCacheKey: request.promptCacheKey,
                    temperature: request.temperature,
                    maxTokens: request.maxTokens,
                    enableThinking: request.enableThinking
                ),
                onEvent: onEvent
            )
            return HTTPChatResponse(model: request.model ?? llmEngine.modelId, result: result)
        }
    }

    func transcribeAudio(_ request: HTTPASRRequest) async throws -> ASRTranscriptionResult {
        guard let asrEngine else {
            throw WorkerHTTPError.engineUnavailable("ASR engine is not loaded in this worker")
        }
        return try await gpuSlot.withLock {
            setRunning(true)
            defer { setRunning(false) }
            return try await asrEngine.transcribe(
                audioURL: request.audioURL,
                language: request.language,
                prompt: request.prompt
            )
        }
    }

    func synthesizeSpeech(_ request: HTTPTTSRequest) async throws -> TTSSynthesisResult {
        guard let ttsEngine else {
            throw WorkerHTTPError.engineUnavailable("TTS engine is not loaded in this worker")
        }
        let targetURL = request.outputURL
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("acpm-tts-\(UUID().uuidString).wav")
        return try await gpuSlot.withLock {
            setRunning(true)
            defer { setRunning(false) }
            return try await ttsEngine.synthesize(
                TTSSynthesisRequest(
                    text: request.text,
                    voice: request.voice,
                    instruct: request.instruct,
                    referenceAudioURL: request.referenceAudioURL,
                    referenceText: request.referenceText,
                    xVectorOnly: request.xVectorOnly,
                    language: request.language,
                    temperature: request.temperature,
                    maxTokens: request.maxTokens,
                    outputURL: targetURL
                )
            )
        }
    }

    func clearCaches() async {
        await llmEngine?.trimCaches()
        await asrEngine?.trimCaches()
        await ttsEngine?.trimCaches()
    }

    func requestShutdown() async {
        await shutdownLatch.trigger()
    }
}

private struct BenchmarkCorpus: Decodable {
    struct CaseItem: Decodable {
        let id: String
        let input: String
    }

    let systemPrompt: String
    let cases: [CaseItem]

    enum CodingKeys: String, CodingKey {
        case systemPrompt = "system_prompt"
        case cases
    }
}

@main
struct AcpmWorkerMLXEntry {
    static func main() async {
        do {
            if let metallibURL = MetallibLocator.resolveMetallibURL() {
                GPU.metallib = metallibURL
            }

            let options = try WorkerCLIOptions.parse(arguments: CommandLine.arguments)
            if options.showHelp {
                printUsage()
                return
            }

            switch options.mode {
            case .llm, .asr, .tts:
                try await runSingleWorkerMode(options)
            case .serveAll:
                try await runServeAllMode(options)
            case .benchmark:
                try await runBenchmarkMode(options)
            }
        } catch {
            WorkerFrameEmitter.emit(
                .errorFrame(stage: "WORKER_START", detail: String(describing: error), fatal: true)
            )
            Foundation.exit(1)
        }
    }

    private static func resolveToken(options: WorkerCLIOptions) -> String {
        if let explicit = options.explicitToken, !explicit.isEmpty {
            return explicit
        }
        if let envToken = ProcessInfo.processInfo.environment[options.authTokenEnv], !envToken.isEmpty {
            return envToken
        }
        return "acpm-local-dev-token"
    }

    private static func startStdinControlReader(
        shutdownLatch: ShutdownLatch,
        onTrimCache: @Sendable @escaping () async -> Void
    ) {
        let thread = Thread {
            while let rawLine = readLine(strippingNewline: true) {
                let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                guard let data = trimmed.data(using: .utf8),
                      let cmd = try? JSONDecoder().decode(WorkerCommand.self, from: data)
                else {
                    continue
                }
                switch cmd.cmd {
                case .trimCache:
                    Task { await onTrimCache() }
                case .shutdown:
                    Task { await shutdownLatch.trigger() }
                    return
                }
            }
            // Parent death / EOF self-termination invariant.
            Task { await shutdownLatch.trigger() }
        }
        thread.name = "acpm-stdin-control"
        thread.start()
    }

    private static func runSingleWorkerMode(_ options: WorkerCLIOptions) async throws {
        WorkerFrameEmitter.emit(.stateFrame(.starting, ipcEndpoint: options.ipcPath))

        if options.probe {
            WorkerFrameEmitter.emit(
                .stateFrame(
                    .warm,
                    modelLoadMs: 0.0,
                    memory: WorkerMemorySnapshot(unifiedMB: ProcessMemory.currentUnifiedMB()),
                    ipcEndpoint: options.ipcPath
                )
            )
            return
        }

        guard let modelDirPath = options.modelDir else {
            WorkerFrameEmitter.emit(
                .errorFrame(stage: "WORKER_START", detail: "MISSING_MODEL_DIR", fatal: true)
            )
            Foundation.exit(2)
        }

        var llmEngine: MLXLLMEngine?
        var asrEngine: MLXASREngine?
        var ttsEngine: MLXTTSEngine?
        let engine: any InferenceEngine

        switch options.mode {
        case .llm:
            let e = MLXLLMEngine(modelId: options.modelId)
            llmEngine = e
            engine = e
        case .asr:
            let e = MLXASREngine(modelId: options.modelId)
            asrEngine = e
            engine = e
        case .tts:
            let e = MLXTTSEngine(modelId: options.modelId)
            ttsEngine = e
            engine = e
        case .benchmark, .serveAll:
            fatalError("unreachable")
        }

        WorkerFrameEmitter.emit(.stateFrame(.loading))
        let loadMs = try await engine.load(from: URL(fileURLWithPath: modelDirPath))

        let shutdownLatch = ShutdownLatch()
        let delegate = WorkerRuntimeDelegate(
            llmEngine: llmEngine,
            asrEngine: asrEngine,
            ttsEngine: ttsEngine,
            shutdownLatch: shutdownLatch
        )

        var endpoints: [ServerEndpoint] = []
        if let ipcPath = options.ipcPath, !ipcPath.isEmpty {
            endpoints.append(.unix(path: ipcPath))
        }
        if let listen = options.listenAddress, !listen.isEmpty {
            let parsed = try WorkerHTTPServer.parseListenAddress(listen)
            endpoints.append(.tcp(host: parsed.host, port: parsed.port))
        }

        var mdnsBroadcaster: MdnsBroadcaster?
        var httpServer: WorkerHTTPServer?

        if !endpoints.isEmpty {
            let provisionalPort: UInt16? = endpoints.compactMap {
                if case .tcp(_, let p) = $0 { return p }
                return nil
            }.first
            let normalizedMdns = options.mdnsHost.map(MdnsBroadcaster.normalizeHostname)
            if let normalizedMdns, let port = provisionalPort, port > 0 {
                let adv = MdnsBroadcaster(
                    serviceName: options.mdnsServiceName,
                    hostname: normalizedMdns,
                    port: port,
                    capabilities: [options.mode.rawValue]
                )
                adv.start()
                mdnsBroadcaster = adv
            }
            let capturedMdns = mdnsBroadcaster

            let server = WorkerHTTPServer(
                config: WorkerHTTPServerConfig(
                    endpoints: endpoints,
                    token: resolveToken(options: options),
                    mdnsHost: normalizedMdns,
                    activeLanIPProvider: { capturedMdns?.activeIP ?? MdnsBroadcaster.detectLanIPv4() },
                    capabilities: [options.mode.rawValue]
                ),
                delegate: delegate
            )
            try server.start()
            httpServer = server

            if mdnsBroadcaster == nil, let normalizedMdns, let boundPort = server.boundTCPPort {
                let adv = MdnsBroadcaster(
                    serviceName: options.mdnsServiceName,
                    hostname: normalizedMdns,
                    port: boundPort,
                    capabilities: [options.mode.rawValue]
                )
                adv.start()
                mdnsBroadcaster = adv
            }
        }

        let endpointReport = options.ipcPath
            ?? httpServer?.boundTCPPort.map { "http://127.0.0.1:\($0)" }

        WorkerFrameEmitter.emit(
            .stateFrame(
                .warm,
                modelLoadMs: loadMs,
                memory: WorkerMemorySnapshot(unifiedMB: ProcessMemory.currentUnifiedMB()),
                ipcEndpoint: endpointReport
            )
        )

        startStdinControlReader(shutdownLatch: shutdownLatch) {
            await engine.trimCaches()
        }

        let sigIntSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        signal(SIGINT, SIG_IGN)
        sigIntSource.setEventHandler {
            Task { await shutdownLatch.trigger() }
        }
        sigIntSource.resume()

        let sigTermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        signal(SIGTERM, SIG_IGN)
        sigTermSource.setEventHandler {
            Task { await shutdownLatch.trigger() }
        }
        sigTermSource.resume()

        await shutdownLatch.wait()

        sigIntSource.cancel()
        sigTermSource.cancel()
        WorkerFrameEmitter.emit(.stateFrame(.unloading))
        httpServer?.stop()
        mdnsBroadcaster?.stop()
        await engine.unload()
    }

    private static func runServeAllMode(_ options: WorkerCLIOptions) async throws {
        WorkerFrameEmitter.emit(.stateFrame(.starting))
        WorkerFrameEmitter.emit(.stateFrame(.loading))

        var llmEngine: MLXLLMEngine?
        var asrEngine: MLXASREngine?
        var ttsEngine: MLXTTSEngine?
        var caps: [String] = []
        var totalLoadMs = 0.0

        if let llmDir = options.llmDir {
            let e = MLXLLMEngine(modelId: "yanmo-correct-4b-cot")
            totalLoadMs += try await e.load(from: URL(fileURLWithPath: llmDir))
            llmEngine = e
            caps.append("llm")
        }
        if let asrDir = options.asrDir {
            let e = MLXASREngine(modelId: "qwen3-asr-1.7b")
            totalLoadMs += try await e.load(from: URL(fileURLWithPath: asrDir))
            asrEngine = e
            caps.append("asr")
        }
        if let ttsDir = options.ttsDir {
            let e = MLXTTSEngine(modelId: "qwen3-tts-1.7b")
            totalLoadMs += try await e.load(from: URL(fileURLWithPath: ttsDir))
            ttsEngine = e
            caps.append("tts")
        }

        guard !caps.isEmpty else {
            throw WorkerConfigError.missingRequired("--llm-dir / --asr-dir / --tts-dir")
        }

        let listenRaw = options.listenAddress ?? "0.0.0.0:18790"
        let parsedListen = try WorkerHTTPServer.parseListenAddress(listenRaw)
        var endpoints: [ServerEndpoint] = [.tcp(host: parsedListen.host, port: parsedListen.port)]
        if let ipcPath = options.ipcPath, !ipcPath.isEmpty {
            endpoints.append(.unix(path: ipcPath))
        }

        let mdnsHost = MdnsBroadcaster.normalizeHostname(options.mdnsHost ?? "acpm.local")
        var mdnsBroadcaster: MdnsBroadcaster?
        if parsedListen.port > 0 {
            let adv = MdnsBroadcaster(
                serviceName: options.mdnsServiceName,
                hostname: mdnsHost,
                port: parsedListen.port,
                capabilities: caps
            )
            adv.start()
            mdnsBroadcaster = adv
        }
        let capturedMdns = mdnsBroadcaster
        let capturedLLM = llmEngine
        let capturedASR = asrEngine
        let capturedTTS = ttsEngine

        let shutdownLatch = ShutdownLatch()
        let delegate = WorkerRuntimeDelegate(
            llmEngine: capturedLLM,
            asrEngine: capturedASR,
            ttsEngine: capturedTTS,
            shutdownLatch: shutdownLatch
        )

        let server = WorkerHTTPServer(
            config: WorkerHTTPServerConfig(
                endpoints: endpoints,
                token: resolveToken(options: options),
                mdnsHost: mdnsHost,
                activeLanIPProvider: { capturedMdns?.activeIP ?? MdnsBroadcaster.detectLanIPv4() },
                capabilities: caps
            ),
            delegate: delegate
        )
        try server.start()

        let boundPort = server.boundTCPPort ?? parsedListen.port
        if mdnsBroadcaster == nil {
            let adv = MdnsBroadcaster(
                serviceName: options.mdnsServiceName,
                hostname: mdnsHost,
                port: boundPort,
                capabilities: caps
            )
            adv.start()
            mdnsBroadcaster = adv
        }

        WorkerFrameEmitter.emit(
            .stateFrame(
                .warm,
                modelLoadMs: totalLoadMs,
                memory: WorkerMemorySnapshot(unifiedMB: ProcessMemory.currentUnifiedMB()),
                ipcEndpoint: "http://\(mdnsHost):\(boundPort)"
            )
        )

        startStdinControlReader(shutdownLatch: shutdownLatch) {
            await capturedLLM?.trimCaches()
            await capturedASR?.trimCaches()
            await capturedTTS?.trimCaches()
        }

        let sigIntSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        signal(SIGINT, SIG_IGN)
        sigIntSource.setEventHandler {
            Task { await shutdownLatch.trigger() }
        }
        sigIntSource.resume()

        let sigTermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        signal(SIGTERM, SIG_IGN)
        sigTermSource.setEventHandler {
            Task { await shutdownLatch.trigger() }
        }
        sigTermSource.resume()

        await shutdownLatch.wait()

        sigIntSource.cancel()
        sigTermSource.cancel()
        WorkerFrameEmitter.emit(.stateFrame(.unloading))
        server.stop()
        mdnsBroadcaster?.stop()
        await llmEngine?.unload()
        await asrEngine?.unload()
        await ttsEngine?.unload()
    }

    private static func runBenchmarkMode(_ options: WorkerCLIOptions) async throws {
        let artifactsDir = URL(
            fileURLWithPath: options.artifactsDir
                ?? FileManager.default.temporaryDirectory
                    .appendingPathComponent("acpm-phase0-\(UUID().uuidString)").path,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)

        var report: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "metallib_path": GPU.metallib?.path ?? "default",
            "baseline_process_mb": ProcessMemory.currentUnifiedMB(),
        ]

        // 1. LLM 4B CoT + KV Prefix Cache Benchmark
        if let llmDir = options.llmDir {
            let llmEngine = MLXLLMEngine(modelId: "yanmo-correct-4b-cot", maxCacheSlots: 4)
            let preLoadMB = ProcessMemory.currentUnifiedMB()
            let loadMs = try await llmEngine.load(from: URL(fileURLWithPath: llmDir))
            let warmMB = ProcessMemory.currentUnifiedMB()
            var peakMB = warmMB

            let corpus: BenchmarkCorpus
            if let corpusPath = options.corpusPath {
                let data = try Data(contentsOf: URL(fileURLWithPath: corpusPath))
                corpus = try JSONDecoder().decode(BenchmarkCorpus.self, from: data)
            } else {
                corpus = BenchmarkCorpus(
                    systemPrompt: "你是专业的语音识别后纠错助手。请先在 <think> 中简短分析同音错别字和标点问题，并在 </think> 后只输出修正后的最终文本。",
                    cases: [
                        .init(id: "case_01", input: "明天去北静出差定一张机票")
                    ]
                )
            }

            var coldResults: [[String: Any]] = []
            for item in corpus.cases {
                let res = try await llmEngine.generate(
                    LLMGenerationRequest(
                        prompt: item.input,
                        systemPrompt: corpus.systemPrompt,
                        promptCacheKey: nil,
                        temperature: 0.0,
                        maxTokens: 512,
                        enableThinking: true
                    )
                )
                peakMB = max(peakMB, ProcessMemory.currentUnifiedMB())
                let (reasoning, content) = CotSplitter.split(rawText: res.rawText, enabled: true)
                let thinkClosed = res.rawText.contains("<think>") && res.rawText.contains("</think>")
                coldResults.append([
                    "id": item.id,
                    "input": item.input,
                    "raw_text": res.rawText,
                    "reasoning": reasoning,
                    "content": content,
                    "think_closed": thinkClosed,
                    "prompt_tokens": res.promptTokens,
                    "completion_tokens": res.completionTokens,
                    "ttft_ms": res.ttftMs,
                    "prefill_ms": res.prefillMs,
                    "decode_ms": res.decodeMs,
                    "kv_cache_hit": res.kvCacheHit,
                ])
            }

            // KV prefix cache test across first 5 cases (miss on #1, hits on #2..5, plus repeat #1 cold vs warm check)
            var prefixCases = Array(corpus.cases.prefix(5))
            if let first = corpus.cases.first {
                prefixCases.append(first)
            }
            var kvCacheResults: [[String: Any]] = []
            for (idx, item) in prefixCases.enumerated() {
                let res = try await llmEngine.generate(
                    LLMGenerationRequest(
                        prompt: item.input,
                        systemPrompt: corpus.systemPrompt,
                        promptCacheKey: "phase0-yanmo-sys-v1",
                        temperature: 0.0,
                        maxTokens: 512,
                        enableThinking: true
                    )
                )
                peakMB = max(peakMB, ProcessMemory.currentUnifiedMB())
                let (_, content) = CotSplitter.split(rawText: res.rawText, enabled: true)
                kvCacheResults.append([
                    "run_index": idx,
                    "id": item.id,
                    "kv_cache_hit": res.kvCacheHit,
                    "ttft_ms": res.ttftMs,
                    "decode_ms": res.decodeMs,
                    "raw_text": res.rawText,
                    "content": content,
                ])
            }

            report["llm"] = [
                "model_dir": llmDir,
                "load_ms": loadMs,
                "pre_load_unified_mb": preLoadMB,
                "warm_unified_mb": warmMB,
                "running_peak_unified_mb": peakMB,
                "delta_warm_mb": Int64(warmMB) - Int64(preLoadMB),
                "delta_peak_mb": Int64(peakMB) - Int64(preLoadMB),
                "cold_cases": coldResults,
                "kv_prefix_cache_runs": kvCacheResults,
            ]
            await llmEngine.unload()
        }

        // 2. TTS Voice Cloning + Cache Benchmark (run before ASR or capture ASR round-trip too)
        var synthesizedWavs: [(id: String, url: URL, text: String)] = []
        if let ttsDir = options.ttsDir {
            let ttsEngine = MLXTTSEngine(modelId: "qwen3-tts-1.7b", maxVoiceCacheSlots: 8)
            let preLoadMB = ProcessMemory.currentUnifiedMB()
            let loadMs = try await ttsEngine.load(from: URL(fileURLWithPath: ttsDir))
            let warmMB = ProcessMemory.currentUnifiedMB()
            var peakMB = warmMB

            let sentences = [
                "欢迎来到本期本地推理架构实战。",
                "系统会根据设备内存自动调节缓存策略。",
                "高优先级输入法请求可以抢占后台批量配音任务。",
                "同一参考音色连续合成时不需要重复编码参考音频。",
                "测试完成，所有视频配音片段已经安全落盘。",
            ]

            let refURL = options.refAudioPath.map { URL(fileURLWithPath: $0) }
            var ttsRuns: [[String: Any]] = []
            for (idx, sentence) in sentences.enumerated() {
                let outURL = artifactsDir.appendingPathComponent(String(format: "tts_%02d.wav", idx + 1))
                let res = try await ttsEngine.synthesize(
                    TTSSynthesisRequest(
                        text: sentence,
                        referenceAudioURL: refURL,
                        referenceText: options.refText,
                        xVectorOnly: (options.refText ?? "").isEmpty,
                        language: "chinese",
                        temperature: 0.7,
                        maxTokens: 1024,
                        outputURL: outURL
                    )
                )
                peakMB = max(peakMB, ProcessMemory.currentUnifiedMB())
                synthesizedWavs.append((id: String(format: "tts_%02d", idx + 1), url: outURL, text: sentence))
                ttsRuns.append([
                    "index": idx + 1,
                    "text": sentence,
                    "output_path": outURL.path,
                    "sample_rate": res.sampleRate,
                    "duration_ms": res.durationMs,
                    "voice_cache_hit": res.voiceCacheHit,
                    "voice_encode_ms": res.voiceEncodeMs,
                    "decode_ms": res.decodeMs,
                ])
            }

            report["tts"] = [
                "model_dir": ttsDir,
                "load_ms": loadMs,
                "pre_load_unified_mb": preLoadMB,
                "warm_unified_mb": warmMB,
                "running_peak_unified_mb": peakMB,
                "delta_warm_mb": Int64(warmMB) - Int64(preLoadMB),
                "delta_peak_mb": Int64(peakMB) - Int64(preLoadMB),
                "runs": ttsRuns,
            ]
            await ttsEngine.unload()
        }

        // 3. ASR Benchmark (explicit --audio files + synthesized TTS clips for round-trip verification)
        if let asrDir = options.asrDir {
            let asrEngine = MLXASREngine(modelId: "qwen3-asr-1.7b")
            let preLoadMB = ProcessMemory.currentUnifiedMB()
            let loadMs = try await asrEngine.load(from: URL(fileURLWithPath: asrDir))
            let warmMB = ProcessMemory.currentUnifiedMB()
            var peakMB = warmMB

            var audioInputs: [(label: String, url: URL, expected: String?)] = []
            for (idx, path) in options.audioPaths.enumerated() {
                audioInputs.append(("audio_\(idx + 1)", URL(fileURLWithPath: path), nil))
            }
            for item in synthesizedWavs {
                audioInputs.append((item.id, item.url, item.text))
            }

            var asrRuns: [[String: Any]] = []
            for item in audioInputs {
                let res = try await asrEngine.transcribe(
                    audioURL: item.url,
                    language: "auto",
                    prompt: nil
                )
                peakMB = max(peakMB, ProcessMemory.currentUnifiedMB())
                let segs: [[String: Any]] = res.segments.map {
                    ["start_ms": $0.startMs, "end_ms": $0.endMs, "text": $0.text]
                }
                var entry: [String: Any] = [
                    "label": item.label,
                    "audio_path": item.url.path,
                    "text": res.text,
                    "language": res.language as Any,
                    "duration_ms": res.durationMs,
                    "decode_ms": res.decodeMs,
                    "segments": segs,
                ]
                if let expected = item.expected {
                    entry["expected_text"] = expected
                }
                asrRuns.append(entry)
            }

            report["asr"] = [
                "model_dir": asrDir,
                "load_ms": loadMs,
                "pre_load_unified_mb": preLoadMB,
                "warm_unified_mb": warmMB,
                "running_peak_unified_mb": peakMB,
                "delta_warm_mb": Int64(warmMB) - Int64(preLoadMB),
                "delta_peak_mb": Int64(peakMB) - Int64(preLoadMB),
                "runs": asrRuns,
            ]
            await asrEngine.unload()
        }

        let jsonData = try JSONSerialization.data(
            withJSONObject: report,
            options: [.prettyPrinted, .sortedKeys]
        )
        if let outPath = options.outJSONPath {
            let outURL = URL(fileURLWithPath: outPath)
            try FileManager.default.createDirectory(
                at: outURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try jsonData.write(to: outURL, options: .atomic)
            print("Wrote Phase 0 Swift benchmark report to \(outURL.path)")
        } else if let str = String(data: jsonData, encoding: .utf8) {
            print(str)
        }
    }

    private static func printUsage() {
        print(
            """
            Usage:
              acpm-worker-mlx --mode <llm|asr|tts> --model-id <id> [--model-dir <path>] [--ipc-path <sock>] [--listen <host:port>] [--mdns-host <acpm.local>] [--probe]
              acpm-worker-mlx --mode serve-all --llm-dir <dir> --asr-dir <dir> --tts-dir <dir> [--listen 0.0.0.0:18790] [--mdns-host acpm.local] [--token <secret>]
              acpm-worker-mlx --mode benchmark --llm-dir <dir> --asr-dir <dir> --tts-dir <dir> --corpus <json> [--audio <wav>] [--ref-audio <wav>] [--ref-text <text>] --out-json <path>
            """
        )
    }
}
