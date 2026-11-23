import Foundation
import WorkerCore

/// MLX-Swift 4B CoT LLM engine skeleton.
/// Phase 0 will wire `MLXLLM` / `MLXLMCommon` (`ModelContainer` + LRU `KVCache` prefix snapshots)
/// and emit raw `<think>...</think>` tokens for `acpmd` splitting.
public actor MLXLLMEngine: LLMEngine {
    public nonisolated let modelId: String
    private var loadedDirectory: URL?
    private var prefixCacheKeys: [String] = []
    private let maxCacheSlots: Int

    public init(modelId: String, maxCacheSlots: Int = 4) {
        self.modelId = modelId
        self.maxCacheSlots = maxCacheSlots
    }

    public func load(from directory: URL) async throws -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        self.loadedDirectory = directory
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
        return elapsedMs
    }

    public func generate(_ request: LLMGenerationRequest) async throws -> LLMGenerationResult {
        guard loadedDirectory != nil else {
            throw EngineSkeletonError.notWiredForPhase0("LLM engine not loaded")
        }
        if let key = request.promptCacheKey, !prefixCacheKeys.contains(key) {
            if prefixCacheKeys.count >= maxCacheSlots {
                prefixCacheKeys.removeFirst()
            }
            prefixCacheKeys.append(key)
        }
        throw EngineSkeletonError.notWiredForPhase0("Phase 0: wire MLXLLM ModelContainer & prefix KVCache")
    }

    public func trimCaches() async {
        prefixCacheKeys.removeAll()
    }

    public func unload() async {
        prefixCacheKeys.removeAll()
        loadedDirectory = nil
    }
}
