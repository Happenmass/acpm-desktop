import CryptoKit
import Foundation
import MLX
import MLXAudioCore
import MLXAudioTTS
import WorkerCore

private struct CachedVoiceConditioning {
    let key: VoicePromptCacheKey
    let language: String
    let refAudio: MaterializedArray
    let conditioning: Qwen3TTSModel.Qwen3TTSReferenceConditioning?
}

/// MLX-Audio-Swift Qwen3-TTS engine with SHA-256 keyed LRU reference voice conditioning cache.
public actor MLXTTSEngine: TTSEngine {
    public nonisolated let modelId: String
    private var model: Qwen3TTSModel?
    private var loadedDirectory: URL?
    private var voiceCache: [String: CachedVoiceConditioning] = [:]
    private var voiceLRU: [String] = []
    private let maxVoiceCacheSlots: Int

    public init(modelId: String, maxVoiceCacheSlots: Int = 8) {
        self.modelId = modelId
        self.maxVoiceCacheSlots = max(1, maxVoiceCacheSlots)
    }

    public func load(from directory: URL) async throws -> Double {
        if GPU.metallib == nil, let metallibURL = MetallibLocator.resolveMetallibURL() {
            GPU.metallib = metallibURL
        }

        let start = DispatchTime.now().uptimeNanoseconds
        let stagedDir = try ModelDirectoryStager.stageIfMissingTokenizerJSON(directory)
        let loaded = try await Qwen3TTSModel.fromModelDirectory(stagedDir)
        self.model = loaded
        self.loadedDirectory = directory
        self.voiceCache.removeAll()
        self.voiceLRU.removeAll()
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
        return elapsedMs
    }

    public func cachedVoiceCount() -> Int {
        voiceCache.count
    }

    public func synthesize(_ request: TTSSynthesisRequest) async throws -> TTSSynthesisResult {
        guard let model else {
            throw EngineSkeletonError.notWiredForPhase0("TTS engine not loaded")
        }

        var params = model.defaultGenerationParameters
        if let temperature = request.temperature {
            params.temperature = temperature
        }
        if let maxTokens = request.maxTokens {
            params.maxTokens = maxTokens
        }

        let resolvedLanguage = (request.language?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0.lowercased()
        } ?? "auto"

        var voiceCacheHit = false
        var voiceEncodeMs = 0.0
        let audioOutput: MaterializedArray

        if let refURL = request.referenceAudioURL {
            let refSHA256 = try Self.sha256Hex(fileURL: refURL)
            let baseKey = VoicePromptCacheKey(
                modelId: modelId,
                referenceAudioSHA256: refSHA256,
                referenceText: request.referenceText,
                xVectorOnly: request.xVectorOnly
            )
            let cacheSlotKey = "\(baseKey.digestHex):\(resolvedLanguage)"
            let trimmedRefText = request.referenceText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let useICL = !request.xVectorOnly && !trimmedRefText.isEmpty

            if let cached = getCachedVoice(cacheSlotKey) {
                voiceCacheHit = true
                if useICL, let conditioning = cached.conditioning {
                    let decodeStart = DispatchTime.now().uptimeNanoseconds
                    audioOutput = try await model.generate(
                        text: request.text,
                        conditioning: conditioning,
                        generationParameters: params
                    )
                    Stream.defaultStream.synchronize()
                    let decodeMs = Double(DispatchTime.now().uptimeNanoseconds - decodeStart) / 1_000_000.0
                    return try finalizeOutput(
                        audioOutput,
                        sampleRate: model.sampleRate,
                        to: request.outputURL,
                        voiceCacheHit: true,
                        voiceEncodeMs: 0.0,
                        decodeMs: decodeMs
                    )
                } else {
                    let decodeStart = DispatchTime.now().uptimeNanoseconds
                    audioOutput = try await model.generate(
                        text: request.text,
                        voice: request.voice ?? request.instruct,
                        refAudio: cached.refAudio,
                        refText: request.referenceText,
                        language: request.language,
                        generationParameters: params
                    )
                    Stream.defaultStream.synchronize()
                    let decodeMs = Double(DispatchTime.now().uptimeNanoseconds - decodeStart) / 1_000_000.0
                    return try finalizeOutput(
                        audioOutput,
                        sampleRate: model.sampleRate,
                        to: request.outputURL,
                        voiceCacheHit: true,
                        voiceEncodeMs: 0.0,
                        decodeMs: decodeMs
                    )
                }
            } else {
                let encodeStart = DispatchTime.now().uptimeNanoseconds
                let (_, refAudio) = try loadAudioArray(from: refURL, sampleRate: model.sampleRate)
                var conditioning: Qwen3TTSModel.Qwen3TTSReferenceConditioning?
                if useICL {
                    conditioning = try model.prepareReferenceConditioning(
                        refAudio: refAudio,
                        refText: trimmedRefText,
                        language: request.language
                    )
                }
                Stream.defaultStream.synchronize()
                voiceEncodeMs = Double(DispatchTime.now().uptimeNanoseconds - encodeStart) / 1_000_000.0

                putCachedVoice(
                    slotKey: cacheSlotKey,
                    entry: CachedVoiceConditioning(
                        key: baseKey,
                        language: resolvedLanguage,
                        refAudio: refAudio,
                        conditioning: conditioning
                    )
                )

                let decodeStart = DispatchTime.now().uptimeNanoseconds
                if let conditioning {
                    audioOutput = try await model.generate(
                        text: request.text,
                        conditioning: conditioning,
                        generationParameters: params
                    )
                } else {
                    audioOutput = try await model.generate(
                        text: request.text,
                        voice: request.voice ?? request.instruct,
                        refAudio: refAudio,
                        refText: request.referenceText,
                        language: request.language,
                        generationParameters: params
                    )
                }
                Stream.defaultStream.synchronize()
                let decodeMs = Double(DispatchTime.now().uptimeNanoseconds - decodeStart) / 1_000_000.0
                return try finalizeOutput(
                    audioOutput,
                    sampleRate: model.sampleRate,
                    to: request.outputURL,
                    voiceCacheHit: false,
                    voiceEncodeMs: voiceEncodeMs,
                    decodeMs: decodeMs
                )
            }
        } else {
            let decodeStart = DispatchTime.now().uptimeNanoseconds
            audioOutput = try await model.generate(
                text: request.text,
                voice: request.voice ?? request.instruct,
                refAudio: nil,
                refText: nil,
                language: request.language,
                generationParameters: params
            )
            Stream.defaultStream.synchronize()
            let decodeMs = Double(DispatchTime.now().uptimeNanoseconds - decodeStart) / 1_000_000.0
            return try finalizeOutput(
                audioOutput,
                sampleRate: model.sampleRate,
                to: request.outputURL,
                voiceCacheHit: voiceCacheHit,
                voiceEncodeMs: 0.0,
                decodeMs: decodeMs
            )
        }
    }

    public func recordVoiceCacheHit(digestHex: String) -> Bool {
        if voiceCache[digestHex] != nil {
            voiceLRU.removeAll { $0 == digestHex }
            voiceLRU.append(digestHex)
            return true
        }
        return false
    }

    public func trimCaches() async {
        voiceCache.removeAll()
        voiceLRU.removeAll()
        Memory.clearCache()
    }

    public func unload() async {
        voiceCache.removeAll()
        voiceLRU.removeAll()
        model = nil
        loadedDirectory = nil
        Memory.clearCache()
    }

    private func getCachedVoice(_ slotKey: String) -> CachedVoiceConditioning? {
        guard let entry = voiceCache[slotKey] else { return nil }
        voiceLRU.removeAll { $0 == slotKey }
        voiceLRU.append(slotKey)
        return entry
    }

    private func putCachedVoice(slotKey: String, entry: CachedVoiceConditioning) {
        if voiceCache[slotKey] == nil, voiceLRU.count >= maxVoiceCacheSlots {
            let evicted = voiceLRU.removeFirst()
            voiceCache.removeValue(forKey: evicted)
        }
        voiceCache[slotKey] = entry
        voiceLRU.removeAll { $0 == slotKey }
        voiceLRU.append(slotKey)
    }

    private func finalizeOutput(
        _ audio: MaterializedArray,
        sampleRate: Int,
        to outputURL: URL,
        voiceCacheHit: Bool,
        voiceEncodeMs: Double,
        decodeMs: Double
    ) throws -> TTSSynthesisResult {
        let samples = audio.asArray(Float.self)
        _ = try WAVWriter.writePCM16Mono(samples: samples, sampleRate: sampleRate, to: outputURL)
        let durationMs = Int64((Double(samples.count) / Double(max(1, sampleRate)) * 1000.0).rounded())
        return TTSSynthesisResult(
            outputURL: outputURL,
            sampleRate: sampleRate,
            durationMs: durationMs,
            voiceCacheHit: voiceCacheHit,
            voiceEncodeMs: voiceEncodeMs,
            decodeMs: decodeMs
        )
    }

    private static func sha256Hex(fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
