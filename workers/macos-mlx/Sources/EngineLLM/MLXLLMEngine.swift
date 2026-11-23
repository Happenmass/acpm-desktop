import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers
import WorkerCore

private struct TransformersTokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages,
                tools: tools,
                additionalContext: additionalContext
            )
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

private struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        return TransformersTokenizerBridge(upstream)
    }
}

private final class PrefixCacheEntry {
    let key: String
    let systemPrompt: String
    let enableThinking: Bool
    let prefixTokens: [Int]
    let cache: [KVCache]

    init(
        key: String,
        systemPrompt: String,
        enableThinking: Bool,
        prefixTokens: [Int],
        cache: [KVCache]
    ) {
        self.key = key
        self.systemPrompt = systemPrompt
        self.enableThinking = enableThinking
        self.prefixTokens = prefixTokens
        self.cache = cache
    }
}

/// Thread-safe only when accessed inside `ModelContainer.perform` (which serializes context access).
private final class PrefixCacheBox: @unchecked Sendable {
    private let maxSlots: Int
    private var entries: [String: PrefixCacheEntry] = [:]
    private var lruOrder: [String] = []

    init(maxSlots: Int) {
        self.maxSlots = max(1, maxSlots)
    }

    var count: Int { entries.count }

    func get(_ key: String) -> PrefixCacheEntry? {
        guard let entry = entries[key] else { return nil }
        lruOrder.removeAll { $0 == key }
        lruOrder.append(key)
        return entry
    }

    func put(_ entry: PrefixCacheEntry) {
        if entries[entry.key] == nil, lruOrder.count >= maxSlots {
            let evicted = lruOrder.removeFirst()
            entries.removeValue(forKey: evicted)
        }
        entries[entry.key] = entry
        lruOrder.removeAll { $0 == entry.key }
        lruOrder.append(entry.key)
    }

    func clear() {
        entries.removeAll()
        lruOrder.removeAll()
    }
}

/// MLX-Swift 4B CoT LLM engine (`Qwen3.5`, `Qwen3`, etc.) with `ModelContainer`,
/// LRU prefix `KVCache` + `MambaCache` snapshots, and raw `<think>...</think>` output.
public actor MLXLLMEngine: LLMEngine {
    public nonisolated let modelId: String
    private var container: ModelContainer?
    private var loadedDirectory: URL?
    private let prefixCacheBox: PrefixCacheBox
    private let maxCacheSlots: Int

    public init(modelId: String, maxCacheSlots: Int = 4) {
        self.modelId = modelId
        self.maxCacheSlots = max(1, maxCacheSlots)
        self.prefixCacheBox = PrefixCacheBox(maxSlots: self.maxCacheSlots)
    }

    public func load(from directory: URL) async throws -> Double {
        if GPU.metallib == nil, let metallibURL = MetallibLocator.resolveMetallibURL() {
            GPU.metallib = metallibURL
        }

        let start = DispatchTime.now().uptimeNanoseconds
        let loaded = try await LLMModelFactory.shared.loadContainer(
            from: directory,
            using: TransformersTokenizerLoader()
        )
        self.container = loaded
        self.loadedDirectory = directory
        self.prefixCacheBox.clear()
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
        return elapsedMs
    }

    public func cachedPrefixCount() -> Int {
        prefixCacheBox.count
    }

    public func generate(_ request: LLMGenerationRequest) async throws -> LLMGenerationResult {
        try await generateStream(request) { _ in true }
    }

    public func generateStream(
        _ request: LLMGenerationRequest,
        onEvent: @Sendable (LLMStreamEvent) -> Bool
    ) async throws -> LLMGenerationResult {
        guard let container else {
            throw EngineSkeletonError.notWiredForPhase0("LLM engine not loaded")
        }

        let box = self.prefixCacheBox
        let startNs = DispatchTime.now().uptimeNanoseconds

        return try await container.perform { context in
            let messages = Self.buildMessages(
                systemPrompt: request.systemPrompt,
                userPrompt: request.prompt
            )
            let fullTokens: [Int]
            do {
                fullTokens = try context.tokenizer.applyChatTemplate(
                    messages: messages,
                    tools: nil,
                    additionalContext: ["enable_thinking": request.enableThinking]
                )
            } catch {
                let rawText = [request.systemPrompt, request.prompt]
                    .compactMap { $0 }
                    .joined(separator: "\n\n")
                fullTokens = context.tokenizer.encode(text: rawText)
            }

            let promptStartsThink = Self.detectPromptStartsInsideThink(
                fullTokens: fullTokens,
                tokenizer: context.tokenizer
            )

            let params = GenerateParameters(
                maxTokens: request.maxTokens,
                temperature: request.temperature,
                topP: request.temperature <= 0 ? 1.0 : 0.95
            )

            var workingCache: [KVCache]? = nil
            var input = LMInput(tokens: MLXArray(fullTokens))
            var kvCacheHit = false

            if let cacheKey = request.promptCacheKey,
               !cacheKey.isEmpty,
               let sysPrompt = request.systemPrompt,
               !sysPrompt.isEmpty
            {
                if let cached = box.get(cacheKey),
                   cached.systemPrompt == sysPrompt,
                   cached.enableThinking == request.enableThinking,
                   fullTokens.starts(with: cached.prefixTokens),
                   fullTokens.count > cached.prefixTokens.count
                {
                    workingCache = cached.cache.map { $0.copy() }
                    let suffix = Array(fullTokens[cached.prefixTokens.count...])
                    input = LMInput(tokens: MLXArray(suffix))
                    kvCacheHit = true
                } else if let prefixTokens = Self.resolveSystemPrefixTokens(
                    systemPrompt: sysPrompt,
                    enableThinking: request.enableThinking,
                    fullTokens: fullTokens,
                    tokenizer: context.tokenizer
                ) {
                    let prefixCache = try context.model.newCache(parameters: params)
                    let prefixInput = LMInput(tokens: MLXArray(prefixTokens))
                    let prep = try context.model.prepare(
                        prefixInput,
                        cache: prefixCache,
                        state: nil,
                        prefill: params.prefill
                    )
                    if case .tokens(let remaining) = prep {
                        _ = withPreparedCache(prefixCache, lengths: remaining.sequenceLengths) {
                            context.model.nextTokenLogits(
                                remaining[text: .newAxis],
                                cache: prefixCache,
                                state: nil
                            )
                        }
                    }
                    eval(prefixCache)
                    Stream.defaultStream.synchronize()

                    box.put(
                        PrefixCacheEntry(
                            key: cacheKey,
                            systemPrompt: sysPrompt,
                            enableThinking: request.enableThinking,
                            prefixTokens: prefixTokens,
                            cache: prefixCache
                        )
                    )

                    workingCache = prefixCache.map { $0.copy() }
                    let suffix = Array(fullTokens[prefixTokens.count...])
                    input = LMInput(tokens: MLXArray(suffix))
                    kvCacheHit = false
                }
            }

            let stopTokenIds = Self.buildStopTokenIds(
                configuration: context.configuration,
                tokenizer: context.tokenizer
            )

            let shouldContinue = onEvent(
                .start(
                    promptTokens: fullTokens.count,
                    kvCacheHit: kvCacheHit,
                    promptStartsThink: promptStartsThink
                )
            )
            var iterator = try TokenIterator(
                input: input,
                model: context.model,
                cache: workingCache,
                parameters: params
            )

            var generatedTokens: [Int] = []
            generatedTokens.reserveCapacity(min(request.maxTokens, 512))
            var firstTokenNs: UInt64?
            var emittedText = ""
            var cancelled = !shouldContinue

            while !cancelled, let token = autoreleasepool(invoking: { iterator.next() }) {
                if firstTokenNs == nil {
                    firstTokenNs = DispatchTime.now().uptimeNanoseconds
                }
                if stopTokenIds.contains(token) {
                    break
                }
                generatedTokens.append(token)

                let decoded = Self.stripSpecialTokens(
                    context.tokenizer.decode(tokenIds: generatedTokens, skipSpecialTokens: false)
                )
                if !decoded.hasSuffix("\u{FFFD}"),
                   decoded.hasPrefix(emittedText),
                   decoded.count > emittedText.count
                {
                    let chunk = String(decoded.dropFirst(emittedText.count))
                    emittedText = decoded
                    if !chunk.isEmpty && !onEvent(.delta(text: chunk)) {
                        cancelled = true
                        break
                    }
                }
            }

            Stream.defaultStream.synchronize()
            let endNs = DispatchTime.now().uptimeNanoseconds
            let ttftNs = (firstTokenNs ?? endNs) - startNs
            let decodeNs = firstTokenNs.map { endNs - $0 } ?? 0
            let ttftMs = Double(ttftNs) / 1_000_000.0
            let decodeMs = Double(decodeNs) / 1_000_000.0

            var rawText = Self.stripSpecialTokens(
                context.tokenizer.decode(tokenIds: generatedTokens, skipSpecialTokens: false)
            )
            if !cancelled,
               rawText.hasPrefix(emittedText),
               rawText.count > emittedText.count
            {
                let tailChunk = String(rawText.dropFirst(emittedText.count))
                if !tailChunk.isEmpty {
                    _ = onEvent(.delta(text: tailChunk))
                }
            }

            if promptStartsThink {
                let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.hasPrefix("<think>") {
                    rawText = "<think>\n" + rawText
                }
            }

            let result = LLMGenerationResult(
                rawText: rawText,
                promptTokens: fullTokens.count,
                completionTokens: generatedTokens.count,
                kvCacheHit: kvCacheHit,
                prefillMs: ttftMs,
                decodeMs: decodeMs,
                ttftMs: ttftMs,
                promptStartsThink: promptStartsThink
            )
            if !cancelled {
                _ = onEvent(.done(result: result))
            }
            return result
        }
    }

    public func trimCaches() async {
        if let container {
            let box = self.prefixCacheBox
            await container.perform { _ in
                box.clear()
                Memory.clearCache()
            }
        } else {
            prefixCacheBox.clear()
            Memory.clearCache()
        }
    }

    public func unload() async {
        prefixCacheBox.clear()
        container = nil
        loadedDirectory = nil
        Memory.clearCache()
    }

    private static func stripSpecialTokens(_ text: String) -> String {
        var cleaned = text
        for eosStr in ["<|im_end|>", "<|endoftext|>"] {
            cleaned = cleaned.replacingOccurrences(of: eosStr, with: "")
        }
        return cleaned
    }

    private static func buildMessages(systemPrompt: String?, userPrompt: String) -> [[String: any Sendable]] {
        var messages: [[String: any Sendable]] = []
        if let systemPrompt, !systemPrompt.isEmpty {
            messages.append(["role": "system", "content": systemPrompt])
        }
        messages.append(["role": "user", "content": userPrompt])
        return messages
    }

    private static func detectPromptStartsInsideThink(
        fullTokens: [Int],
        tokenizer: any MLXLMCommon.Tokenizer
    ) -> Bool {
        guard !fullTokens.isEmpty else { return false }
        let tail = Array(fullTokens.suffix(12))
        let tailText = tokenizer.decode(tokenIds: tail, skipSpecialTokens: false)
        guard let openRange = tailText.range(of: "<think>", options: .backwards) else {
            return false
        }
        let afterOpen = tailText[openRange.upperBound...]
        return !afterOpen.contains("</think>")
    }

    private static func resolveSystemPrefixTokens(
        systemPrompt: String,
        enableThinking: Bool,
        fullTokens: [Int],
        tokenizer: any MLXLMCommon.Tokenizer
    ) -> [Int]? {
        let msgsA: [[String: any Sendable]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": "alpha_probe_1"],
        ]
        let msgsB: [[String: any Sendable]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": "zeta_probe_9"],
        ]
        guard let tokensA = try? tokenizer.applyChatTemplate(
            messages: msgsA,
            tools: nil,
            additionalContext: ["enable_thinking": enableThinking]
        ),
              let tokensB = try? tokenizer.applyChatTemplate(
                  messages: msgsB,
                  tools: nil,
                  additionalContext: ["enable_thinking": enableThinking]
              )
        else {
            return nil
        }

        let commonLen = zip(tokensA, tokensB).prefix(while: { $0 == $1 }).count
        guard commonLen >= 4, fullTokens.count > commonLen else {
            return nil
        }
        let prefix = Array(tokensA.prefix(commonLen))
        guard fullTokens.starts(with: prefix) else {
            return nil
        }
        return prefix
    }

    private static func buildStopTokenIds(
        configuration: ModelConfiguration,
        tokenizer: any MLXLMCommon.Tokenizer
    ) -> Set<Int> {
        var ids = configuration.eosTokenIds
        if let eosId = tokenizer.eosTokenId {
            ids.insert(eosId)
        }
        if let unkId = tokenizer.unknownTokenId {
            ids.insert(unkId)
        }
        for tok in configuration.extraEOSTokens {
            if let id = tokenizer.convertTokenToId(tok) {
                ids.insert(id)
            }
        }
        for special in ["<|im_end|>", "<|endoftext|>"] {
            if let id = tokenizer.convertTokenToId(special) {
                ids.insert(id)
            }
        }
        return ids
    }
}
