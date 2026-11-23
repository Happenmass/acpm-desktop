import Foundation
import WorkerCore

/// MLX-Audio-Swift Qwen3-ASR engine skeleton (`qwen3-asr-0.6b` / `qwen3-asr-1.7b`).
/// Phase 0 will wire `MLXAudioSTT` (`Qwen3ASRModel`) and benchmark window latency + footprint.
public actor MLXASREngine: ASREngine {
    public nonisolated let modelId: String
    private var loadedDirectory: URL?

    public init(modelId: String) {
        self.modelId = modelId
    }

    public func load(from directory: URL) async throws -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        self.loadedDirectory = directory
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
        return elapsedMs
    }

    public func transcribe(audioURL: URL, language: String?, prompt: String?) async throws -> ASRTranscriptionResult {
        guard loadedDirectory != nil else {
            throw EngineSkeletonError.notWiredForPhase0("ASR engine not loaded")
        }
        throw EngineSkeletonError.notWiredForPhase0("Phase 0: wire MLXAudioSTT Qwen3ASRModel")
    }

    public func trimCaches() async {}

    public func unload() async {
        loadedDirectory = nil
    }
}
