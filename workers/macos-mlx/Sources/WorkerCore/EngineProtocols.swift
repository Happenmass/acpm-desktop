import CryptoKit
import Foundation

public struct VoicePromptCacheKey: Hashable, Sendable {
    public let modelId: String
    public let digestHex: String

    public init(modelId: String, referenceAudioSHA256: String, referenceText: String?, xVectorOnly: Bool) {
        self.modelId = modelId
        var hasher = SHA256()
        hasher.update(data: Data(modelId.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: Data(referenceAudioSHA256.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: Data((referenceText ?? "").utf8))
        hasher.update(data: Data([xVectorOnly ? 1 : 0]))
        self.digestHex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public protocol InferenceEngine: Sendable {
    var modelId: String { get }
    func load(from directory: URL) async throws -> Double
    func trimCaches() async
    func unload() async
}

public struct LLMGenerationRequest: Sendable {
    public let prompt: String
    public let systemPrompt: String?
    public let promptCacheKey: String?
    public let temperature: Float
    public let maxTokens: Int

    public init(
        prompt: String,
        systemPrompt: String? = nil,
        promptCacheKey: String? = nil,
        temperature: Float = 0.0,
        maxTokens: Int = 512
    ) {
        self.prompt = prompt
        self.systemPrompt = systemPrompt
        self.promptCacheKey = promptCacheKey
        self.temperature = temperature
        self.maxTokens = maxTokens
    }
}

public struct LLMGenerationResult: Sendable {
    /// Raw tokens including `<think>...</think>`. Splitting is performed centrally by `acpmd`.
    public let rawText: String
    public let promptTokens: Int
    public let completionTokens: Int
    public let kvCacheHit: Bool
    public let prefillMs: Double
    public let decodeMs: Double

    public init(
        rawText: String,
        promptTokens: Int,
        completionTokens: Int,
        kvCacheHit: Bool,
        prefillMs: Double,
        decodeMs: Double
    ) {
        self.rawText = rawText
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.kvCacheHit = kvCacheHit
        self.prefillMs = prefillMs
        self.decodeMs = decodeMs
    }
}

public protocol LLMEngine: InferenceEngine {
    func generate(_ request: LLMGenerationRequest) async throws -> LLMGenerationResult
}

public struct ASRTranscriptionResult: Sendable {
    public let text: String
    public let language: String?
    public let durationMs: Int64
    public let decodeMs: Double

    public init(text: String, language: String?, durationMs: Int64, decodeMs: Double) {
        self.text = text
        self.language = language
        self.durationMs = durationMs
        self.decodeMs = decodeMs
    }
}

public protocol ASREngine: InferenceEngine {
    func transcribe(audioURL: URL, language: String?, prompt: String?) async throws -> ASRTranscriptionResult
}

public struct TTSSynthesisRequest: Sendable {
    public let text: String
    public let voice: String?
    public let instruct: String?
    public let referenceAudioURL: URL?
    public let referenceText: String?
    public let xVectorOnly: Bool
    public let outputURL: URL

    public init(
        text: String,
        voice: String? = nil,
        instruct: String? = nil,
        referenceAudioURL: URL? = nil,
        referenceText: String? = nil,
        xVectorOnly: Bool = false,
        outputURL: URL
    ) {
        self.text = text
        self.voice = voice
        self.instruct = instruct
        self.referenceAudioURL = referenceAudioURL
        self.referenceText = referenceText
        self.xVectorOnly = xVectorOnly
        self.outputURL = outputURL
    }
}

public struct TTSSynthesisResult: Sendable {
    public let outputURL: URL
    public let sampleRate: Int
    public let durationMs: Int64
    public let voiceCacheHit: Bool
    public let decodeMs: Double

    public init(outputURL: URL, sampleRate: Int, durationMs: Int64, voiceCacheHit: Bool, decodeMs: Double) {
        self.outputURL = outputURL
        self.sampleRate = sampleRate
        self.durationMs = durationMs
        self.voiceCacheHit = voiceCacheHit
        self.decodeMs = decodeMs
    }
}

public protocol TTSEngine: InferenceEngine {
    func synthesize(_ request: TTSSynthesisRequest) async throws -> TTSSynthesisResult
}

public enum EngineSkeletonError: Error, Sendable {
    case notWiredForPhase0(String)
}
