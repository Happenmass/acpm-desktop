import Foundation

public enum Priority: String, Codable, Sendable {
    case interactive
    case normal
    case batch
}

public enum AcpmErrorCode: String, Codable, Sendable {
    case invalidRequest = "INVALID_REQUEST"
    case unauthorized = "UNAUTHORIZED"
    case forbidden = "FORBIDDEN"
    case notFound = "NOT_FOUND"
    case audioValidationFailed = "AUDIO_VALIDATION_FAILED"
    case modelNotInstalled = "MODEL_NOT_INSTALLED"
    case unsupportedPlatform = "UNSUPPORTED_PLATFORM"
    case insufficientMemory = "INSUFFICIENT_MEMORY"
    case schedulerBusy = "SCHEDULER_BUSY"
    case queueTimeout = "QUEUE_TIMEOUT"
    case workerCrashed = "WORKER_CRASHED"
    case inferenceFailed = "INFERENCE_FAILED"
    case cancelled = "CANCELLED"
    case notImplemented = "NOT_IMPLEMENTED"
}

public struct AcpmError: Error, Codable, Sendable, Equatable {
    public let code: AcpmErrorCode
    public let message: String
    public let requestId: String
    public let stage: String
    public let detail: String
    public let nativeCode: String?
    public let elapsedMs: Int64
    public let retryable: Bool

    enum CodingKeys: String, CodingKey {
        case code
        case message
        case requestId = "request_id"
        case stage
        case detail
        case nativeCode = "native_code"
        case elapsedMs = "elapsed_ms"
        case retryable
    }
}

public struct ApiErrorEnvelope: Codable, Sendable {
    public let error: AcpmError
}

public struct TimingMetrics: Codable, Sendable, Equatable {
    public let queueMs: Double?
    public let modelLoadMs: Double?
    public let prefillMs: Double?
    public let decodeMs: Double?
    public let kvCacheHit: Bool?
    public let voiceCacheHit: Bool?

    enum CodingKeys: String, CodingKey {
        case queueMs = "queue_ms"
        case modelLoadMs = "model_load_ms"
        case prefillMs = "prefill_ms"
        case decodeMs = "decode_ms"
        case kvCacheHit = "kv_cache_hit"
        case voiceCacheHit = "voice_cache_hit"
    }
}

public struct ChatMessage: Codable, Sendable, Equatable {
    public let role: String
    public let content: String
    public let reasoningContent: String?

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case reasoningContent = "reasoning_content"
    }

    public init(role: String, content: String, reasoningContent: String? = nil) {
        self.role = role
        self.content = content
        self.reasoningContent = reasoningContent
    }
}

public struct ChatCompletionRequest: Codable, Sendable {
    public let model: String
    public let messages: [ChatMessage]
    public let stream: Bool
    public let temperature: Float?
    public let maxTokens: Int?
    public let separateReasoning: Bool
    public let promptCacheKey: String?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case stream
        case temperature
        case maxTokens = "max_tokens"
        case separateReasoning = "separate_reasoning"
        case promptCacheKey = "prompt_cache_key"
    }

    public init(
        model: String = "yanmo-correct-4b-cot",
        messages: [ChatMessage],
        stream: Bool = false,
        temperature: Float? = 0.0,
        maxTokens: Int? = 512,
        separateReasoning: Bool = true,
        promptCacheKey: String? = nil
    ) {
        self.model = model
        self.messages = messages
        self.stream = stream
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.separateReasoning = separateReasoning
        self.promptCacheKey = promptCacheKey
    }
}

public struct ChatChoice: Codable, Sendable, Equatable {
    public let index: Int
    public let message: ChatMessage
    public let finishReason: String

    enum CodingKeys: String, CodingKey {
        case index
        case message
        case finishReason = "finish_reason"
    }
}

public struct ChatCompletionResponse: Codable, Sendable, Equatable {
    public let id: String
    public let object: String
    public let created: Int64
    public let model: String
    public let choices: [ChatChoice]
    public let xAcpmTiming: TimingMetrics?

    enum CodingKeys: String, CodingKey {
        case id
        case object
        case created
        case model
        case choices
        case xAcpmTiming = "x_acpm_timing"
    }
}

public struct TranscriptionRequest: Codable, Sendable {
    public let model: String
    public let filePath: String
    public let language: String?
    public let vadFilter: Bool
    public let timestamps: Bool
    public let prompt: String?

    enum CodingKeys: String, CodingKey {
        case model
        case filePath = "file_path"
        case language
        case vadFilter = "vad_filter"
        case timestamps
        case prompt
    }

    public init(
        model: String = "qwen3-asr-0.6b",
        filePath: String,
        language: String? = "auto",
        vadFilter: Bool = true,
        timestamps: Bool = true,
        prompt: String? = nil
    ) {
        self.model = model
        self.filePath = filePath
        self.language = language
        self.vadFilter = vadFilter
        self.timestamps = timestamps
        self.prompt = prompt
    }
}

public struct TranscriptSegment: Codable, Sendable, Equatable {
    public let startMs: Int64
    public let endMs: Int64
    public let text: String

    enum CodingKeys: String, CodingKey {
        case startMs = "start_ms"
        case endMs = "end_ms"
        case text
    }
}

public struct TranscriptionResponse: Codable, Sendable, Equatable {
    public let text: String
    public let language: String?
    public let durationMs: Int64
    public let segments: [TranscriptSegment]
    public let xAcpmTiming: TimingMetrics?

    enum CodingKeys: String, CodingKey {
        case text
        case language
        case durationMs = "duration_ms"
        case segments
        case xAcpmTiming = "x_acpm_timing"
    }
}

public struct SpeechRequest: Codable, Sendable {
    public let model: String
    public let input: String
    public let voice: String?
    public let instruct: String?
    public let referenceAudio: String?
    public let referenceText: String?
    public let xVectorOnlyMode: Bool
    public let speed: Float?
    public let responseFormat: String
    public let outputPath: String?

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case voice
        case instruct
        case referenceAudio = "reference_audio"
        case referenceText = "reference_text"
        case xVectorOnlyMode = "x_vector_only_mode"
        case speed
        case responseFormat = "response_format"
        case outputPath = "output_path"
    }

    public init(
        model: String = "qwen3-tts-1.7b",
        input: String,
        voice: String? = nil,
        instruct: String? = nil,
        referenceAudio: String? = nil,
        referenceText: String? = nil,
        xVectorOnlyMode: Bool = false,
        speed: Float? = 1.0,
        responseFormat: String = "wav",
        outputPath: String? = nil
    ) {
        self.model = model
        self.input = input
        self.voice = voice
        self.instruct = instruct
        self.referenceAudio = referenceAudio
        self.referenceText = referenceText
        self.xVectorOnlyMode = xVectorOnlyMode
        self.speed = speed
        self.responseFormat = responseFormat
        self.outputPath = outputPath
    }
}

public struct SpeechFileResponse: Codable, Sendable, Equatable {
    public let outputPath: String
    public let bytes: UInt64
    public let sampleRate: Int
    public let durationMs: Int64
    public let voiceCacheHit: Bool
    public let xAcpmTiming: TimingMetrics?

    enum CodingKeys: String, CodingKey {
        case outputPath = "output_path"
        case bytes
        case sampleRate = "sample_rate"
        case durationMs = "duration_ms"
        case voiceCacheHit = "voice_cache_hit"
        case xAcpmTiming = "x_acpm_timing"
    }
}

public struct VoiceProfile: Codable, Sendable, Equatable, Identifiable {
    public var id: String { voiceId }
    public let voiceId: String
    public let name: String
    public let referenceText: String?
    public let language: String?
    public let durationMs: Int64
    public let sha256: String
    public let createdAt: String

    enum CodingKeys: String, CodingKey {
        case voiceId = "voice_id"
        case name
        case referenceText = "reference_text"
        case language
        case durationMs = "duration_ms"
        case sha256
        case createdAt = "created_at"
    }
}

public struct ResourceVectorDTO: Codable, Sendable, Equatable {
    public let unifiedMB: UInt64?
    public let systemRamMB: UInt64?
    public let gpuVramMB: [String: UInt64]?

    enum CodingKeys: String, CodingKey {
        case unifiedMB = "unified_mb"
        case systemRamMB = "system_ram_mb"
        case gpuVramMB = "gpu_vram_mb"
    }

    public var totalMB: UInt64 {
        let gpu = gpuVramMB?.values.reduce(0, +) ?? 0
        return (unifiedMB ?? 0) + (systemRamMB ?? 0) + gpu
    }
}

public struct ModelStatusInfo: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let capability: String
    public let displayName: String
    public let selectedVariant: String?
    public let installed: Bool
    public let state: String
    public let pinPolicy: String
    public let idleTimeoutSec: UInt64
    public let memory: ResourceVectorDTO

    enum CodingKeys: String, CodingKey {
        case id
        case capability
        case displayName = "display_name"
        case selectedVariant = "selected_variant"
        case installed
        case state
        case pinPolicy = "pin_policy"
        case idleTimeoutSec = "idle_timeout_sec"
        case memory
    }
}

public struct SystemStatusResponse: Codable, Sendable, Equatable {
    public let platform: String
    public let pid: UInt32
    public let budget: ResourceVectorDTO
    public let used: ResourceVectorDTO
    public let memoryPressure: String
    public let thermalState: String
    public let loadedModels: [ModelStatusInfo]
    public let activeRequests: Int
    public let queuedRequests: Int
    public let callerCounts: [String: UInt64]

    enum CodingKeys: String, CodingKey {
        case platform
        case pid
        case budget
        case used
        case memoryPressure = "memory_pressure"
        case thermalState = "thermal_state"
        case loadedModels = "loaded_models"
        case activeRequests = "active_requests"
        case queuedRequests = "queued_requests"
        case callerCounts = "caller_counts"
    }
}

public struct DiagnosticFailure: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(timestampMs)-\(requestId)" }
    public let timestampMs: Int64
    public let requestId: String
    public let caller: String
    public let modelId: String?
    public let operation: String
    public let stage: String
    public let code: AcpmErrorCode
    public let detail: String
    public let nativeCode: String?
    public let elapsedMs: Int64

    enum CodingKeys: String, CodingKey {
        case timestampMs = "timestamp_ms"
        case requestId = "request_id"
        case caller
        case modelId = "model_id"
        case operation
        case stage
        case code
        case detail
        case nativeCode = "native_code"
        case elapsedMs = "elapsed_ms"
    }
}
