import Foundation
import MLX
import MLXAudioCore
import MLXAudioSTT
import WorkerCore

/// MLX-Audio-Swift Qwen3-ASR engine (`qwen3-asr-0.6b` / `qwen3-asr-1.7b`).
public actor MLXASREngine: ASREngine {
    public nonisolated let modelId: String
    private var model: Qwen3ASRModel?
    private var loadedDirectory: URL?

    public init(modelId: String) {
        self.modelId = modelId
    }

    public func load(from directory: URL) async throws -> Double {
        if GPU.metallib == nil, let metallibURL = MetallibLocator.resolveMetallibURL() {
            GPU.metallib = metallibURL
        }

        let start = DispatchTime.now().uptimeNanoseconds
        let stagedDir = try ModelDirectoryStager.stageIfMissingTokenizerJSON(directory)
        let loaded = try await Qwen3ASRModel.fromModelDirectory(stagedDir)
        self.model = loaded
        self.loadedDirectory = directory
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
        return elapsedMs
    }

    public func transcribe(audioURL: URL, language: String?, prompt: String?) async throws -> ASRTranscriptionResult {
        guard let model else {
            throw EngineSkeletonError.notWiredForPhase0("ASR engine not loaded")
        }

        let (_, audio) = try loadAudioArray(from: audioURL, sampleRate: model.sampleRate)
        let sampleCount = audio.dim(0)
        let durationMs = Int64((Double(sampleCount) / Double(model.sampleRate) * 1000.0).rounded())

        let effectiveLanguage: String?
        if let lang = language?.trimmingCharacters(in: .whitespacesAndNewlines),
           !lang.isEmpty,
           lang.lowercased() != "auto"
        {
            effectiveLanguage = lang
        } else {
            effectiveLanguage = nil
        }

        let decodeStart = DispatchTime.now().uptimeNanoseconds
        let output = model.generate(
            audio: audio,
            maxTokens: 4096,
            temperature: 0.0,
            context: prompt ?? "",
            language: effectiveLanguage
        )
        Stream.defaultStream.synchronize()
        let decodeMs = Double(DispatchTime.now().uptimeNanoseconds - decodeStart) / 1_000_000.0

        var parsedSegments: [ASRSegment] = []
        if let rawSegments = output.segments {
            for seg in rawSegments {
                let text = (seg["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let startSec = (seg["start"] as? NSNumber)?.doubleValue ?? 0.0
                let endSec = (seg["end"] as? NSNumber)?.doubleValue ?? (Double(durationMs) / 1000.0)
                parsedSegments.append(
                    ASRSegment(
                        startMs: Int64((startSec * 1000.0).rounded()),
                        endMs: Int64((endSec * 1000.0).rounded()),
                        text: text
                    )
                )
            }
        }

        return ASRTranscriptionResult(
            text: output.text.trimmingCharacters(in: .whitespacesAndNewlines),
            language: output.language,
            durationMs: durationMs,
            segments: parsedSegments,
            decodeMs: decodeMs
        )
    }

    public func trimCaches() async {
        Memory.clearCache()
    }

    public func unload() async {
        model = nil
        loadedDirectory = nil
        Memory.clearCache()
    }
}
