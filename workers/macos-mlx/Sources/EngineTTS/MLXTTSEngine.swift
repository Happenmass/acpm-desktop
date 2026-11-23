import Foundation
import WorkerCore

/// MLX-Audio-Swift Qwen3-TTS engine skeleton with content-hashed reference voice prompt cache.
/// Phase 0 will wire `MLXAudioTTS` (`Qwen3TTSModel`) for single-utterance synthesis and cloning.
public actor MLXTTSEngine: TTSEngine {
    public nonisolated let modelId: String
    private var loadedDirectory: URL?
    private var cachedVoiceDigests: [String] = []
    private let maxVoiceCacheSlots: Int

    public init(modelId: String, maxVoiceCacheSlots: Int = 8) {
        self.modelId = modelId
        self.maxVoiceCacheSlots = maxVoiceCacheSlots
    }

    public func load(from directory: URL) async throws -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        self.loadedDirectory = directory
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
        return elapsedMs
    }

    public func synthesize(_ request: TTSSynthesisRequest) async throws -> TTSSynthesisResult {
        guard loadedDirectory != nil else {
            throw EngineSkeletonError.notWiredForPhase0("TTS engine not loaded")
        }
        throw EngineSkeletonError.notWiredForPhase0("Phase 0: wire MLXAudioTTS Qwen3TTSModel & VoicePrompt LRU")
    }

    public func recordVoiceCacheHit(digestHex: String) -> Bool {
        if cachedVoiceDigests.contains(digestHex) {
            return true
        }
        if cachedVoiceDigests.count >= maxVoiceCacheSlots {
            cachedVoiceDigests.removeFirst()
        }
        cachedVoiceDigests.append(digestHex)
        return false
    }

    public func trimCaches() async {
        cachedVoiceDigests.removeAll()
    }

    public func unload() async {
        cachedVoiceDigests.removeAll()
        loadedDirectory = nil
    }
}
