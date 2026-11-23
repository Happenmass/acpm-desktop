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
    public let enableThinking: Bool

    public init(
        prompt: String,
        systemPrompt: String? = nil,
        promptCacheKey: String? = nil,
        temperature: Float = 0.0,
        maxTokens: Int = 512,
        enableThinking: Bool = true
    ) {
        self.prompt = prompt
        self.systemPrompt = systemPrompt
        self.promptCacheKey = promptCacheKey
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.enableThinking = enableThinking
    }
}

public struct LLMGenerationResult: Sendable {
    /// Raw tokens including `<think>...</think>`. Splitting is performed centrally by `acpmd`.
    public let rawText: String
    public let promptTokens: Int
    public let completionTokens: Int
    public let kvCacheHit: Bool
    public let ttftMs: Double
    public let prefillMs: Double
    public let decodeMs: Double
    public let promptStartsThink: Bool

    public init(
        rawText: String,
        promptTokens: Int,
        completionTokens: Int,
        kvCacheHit: Bool,
        prefillMs: Double,
        decodeMs: Double,
        ttftMs: Double? = nil,
        promptStartsThink: Bool = false
    ) {
        self.rawText = rawText
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.kvCacheHit = kvCacheHit
        self.prefillMs = prefillMs
        self.decodeMs = decodeMs
        self.ttftMs = ttftMs ?? prefillMs
        self.promptStartsThink = promptStartsThink
    }
}

public enum LLMStreamEvent: Sendable {
    case start(promptTokens: Int, kvCacheHit: Bool, promptStartsThink: Bool)
    case delta(text: String)
    case done(result: LLMGenerationResult)
}

public protocol LLMEngine: InferenceEngine {
    func generate(_ request: LLMGenerationRequest) async throws -> LLMGenerationResult
    func generateStream(
        _ request: LLMGenerationRequest,
        onEvent: @Sendable (LLMStreamEvent) -> Bool
    ) async throws -> LLMGenerationResult
}

public extension LLMEngine {
    func generateStream(
        _ request: LLMGenerationRequest,
        onEvent: @Sendable (LLMStreamEvent) -> Bool
    ) async throws -> LLMGenerationResult {
        let result = try await generate(request)
        if onEvent(.start(
            promptTokens: result.promptTokens,
            kvCacheHit: result.kvCacheHit,
            promptStartsThink: result.promptStartsThink
        )) {
            let deltaText: String
            if result.promptStartsThink && result.rawText.hasPrefix("<think>\n") {
                deltaText = String(result.rawText.dropFirst("<think>\n".count))
            } else {
                deltaText = result.rawText
            }
            if onEvent(.delta(text: deltaText)) {
                _ = onEvent(.done(result: result))
            }
        }
        return result
    }
}

public struct ASRSegment: Sendable, Codable, Equatable {
    public let startMs: Int64
    public let endMs: Int64
    public let text: String

    enum CodingKeys: String, CodingKey {
        case startMs = "start_ms"
        case endMs = "end_ms"
        case text
    }

    public init(startMs: Int64, endMs: Int64, text: String) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
    }
}

public struct ASRTranscriptionResult: Sendable {
    public let text: String
    public let language: String?
    public let durationMs: Int64
    public let segments: [ASRSegment]
    public let decodeMs: Double

    public init(
        text: String,
        language: String?,
        durationMs: Int64,
        segments: [ASRSegment] = [],
        decodeMs: Double
    ) {
        self.text = text
        self.language = language
        self.durationMs = durationMs
        self.segments = segments
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
    public let language: String?
    public let temperature: Float?
    public let maxTokens: Int?
    public let outputURL: URL

    public init(
        text: String,
        voice: String? = nil,
        instruct: String? = nil,
        referenceAudioURL: URL? = nil,
        referenceText: String? = nil,
        xVectorOnly: Bool = false,
        language: String? = nil,
        temperature: Float? = nil,
        maxTokens: Int? = nil,
        outputURL: URL
    ) {
        self.text = text
        self.voice = voice
        self.instruct = instruct
        self.referenceAudioURL = referenceAudioURL
        self.referenceText = referenceText
        self.xVectorOnly = xVectorOnly
        self.language = language
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.outputURL = outputURL
    }
}

public struct TTSSynthesisResult: Sendable {
    public let outputURL: URL
    public let sampleRate: Int
    public let durationMs: Int64
    public let voiceCacheHit: Bool
    public let voiceEncodeMs: Double
    public let decodeMs: Double

    public init(
        outputURL: URL,
        sampleRate: Int,
        durationMs: Int64,
        voiceCacheHit: Bool,
        voiceEncodeMs: Double = 0.0,
        decodeMs: Double
    ) {
        self.outputURL = outputURL
        self.sampleRate = sampleRate
        self.durationMs = durationMs
        self.voiceCacheHit = voiceCacheHit
        self.voiceEncodeMs = voiceEncodeMs
        self.decodeMs = decodeMs
    }
}

public protocol TTSEngine: InferenceEngine {
    func synthesize(_ request: TTSSynthesisRequest) async throws -> TTSSynthesisResult
}

public enum EngineSkeletonError: Error, Sendable {
    case notWiredForPhase0(String)
}

/// Writes 16-bit mono PCM WAV files atomically (for TTS output & HTTP responses).
public enum WAVWriter {
    public static func encodePCM16MonoData(samples: [Float], sampleRate: Int) -> Data {
        let clampedRate = UInt32(max(8000, sampleRate))
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let blockAlign: UInt16 = numChannels * (bitsPerSample / 8)
        let byteRate: UInt32 = clampedRate * UInt32(blockAlign)
        let dataSize = UInt32(samples.count * Int(blockAlign))
        let chunkSize = UInt32(36) + dataSize

        var data = Data()
        data.reserveCapacity(44 + Int(dataSize))

        func appendASCII(_ str: String) {
            data.append(contentsOf: str.utf8)
        }
        func appendLE32(_ value: UInt32) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        func appendLE16(_ value: UInt16) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }

        appendASCII("RIFF")
        appendLE32(chunkSize)
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendLE32(16)
        appendLE16(1) // PCM
        appendLE16(numChannels)
        appendLE32(clampedRate)
        appendLE32(byteRate)
        appendLE16(blockAlign)
        appendLE16(bitsPerSample)
        appendASCII("data")
        appendLE32(dataSize)

        for sample in samples {
            let clamped = max(-1.0 as Float, min(1.0 as Float, sample))
            let scaled = Int16((clamped * 32767.0).rounded())
            var le = scaled.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        return data
    }

    @discardableResult
    public static func writePCM16Mono(samples: [Float], sampleRate: Int, to outputURL: URL) throws -> Int {
        let fm = FileManager.default
        let parent = outputURL.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let wavData = encodePCM16MonoData(samples: samples, sampleRate: sampleRate)
        let tmpURL = outputURL.appendingPathExtension("part.\(ProcessInfo.processInfo.processIdentifier)")
        try wavData.write(to: tmpURL, options: .atomic)
        if fm.fileExists(atPath: outputURL.path) {
            _ = try fm.replaceItemAt(outputURL, withItemAt: tmpURL)
        } else {
            try fm.moveItem(at: tmpURL, to: outputURL)
        }
        return wavData.count
    }
}

/// Splits `<think>...</think>` blocks into `(reasoning, content)` matching `acpm-scheduler`.
public enum CotSplitter {
    public static func split(
        rawText: String,
        enabled: Bool,
        startsInThink: Bool = false
    ) -> (reasoning: String, content: String) {
        guard enabled else {
            return ("", rawText)
        }

        let openTag = "<think>"
        let closeTag = "</think>"

        if startsInThink {
            if let closeRange = rawText.range(of: closeTag) {
                var reasoning = String(rawText[..<closeRange.lowerBound])
                if reasoning.hasPrefix(openTag) {
                    reasoning = String(reasoning.dropFirst(openTag.count))
                }
                let content = String(rawText[closeRange.upperBound...])
                    .trimmingLeadingWhitespaceAndNewlines()
                return (reasoning.trimmingCharacters(in: .whitespacesAndNewlines), content)
            }
            let cleaned = rawText.hasPrefix(openTag) ? String(rawText.dropFirst(openTag.count)) : rawText
            return (cleaned.trimmingCharacters(in: .whitespacesAndNewlines), "")
        }

        let trimmed = rawText.trimmingLeadingWhitespaceAndNewlines()
        if trimmed.hasPrefix(openTag) {
            let afterOpen = String(trimmed.dropFirst(openTag.count))
            if let closeRange = afterOpen.range(of: closeTag) {
                let reasoning = String(afterOpen[..<closeRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let content = String(afterOpen[closeRange.upperBound...])
                    .trimmingLeadingWhitespaceAndNewlines()
                return (reasoning, content)
            }
            return (afterOpen.trimmingCharacters(in: .whitespacesAndNewlines), "")
        }

        return ("", rawText)
    }
}

private extension String {
    func trimmingLeadingWhitespaceAndNewlines() -> String {
        guard let firstNonWS = firstIndex(where: { !$0.isWhitespace && !$0.isNewline }) else {
            return ""
        }
        return String(self[firstNonWS...])
    }
}
