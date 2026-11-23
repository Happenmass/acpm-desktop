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

public struct ChatStreamDelta: Sendable, Equatable {
    public let reasoningContent: String?
    public let content: String?
    public let finishReason: String?

    public init(
        reasoningContent: String? = nil,
        content: String? = nil,
        finishReason: String? = nil
    ) {
        self.reasoningContent = reasoningContent
        self.content = content
        self.finishReason = finishReason
    }
}

public struct PrewarmRequest: Codable, Sendable, Equatable {
    public let models: [String]
    public let promptCacheKeys: [String]?

    enum CodingKeys: String, CodingKey {
        case models
        case promptCacheKeys = "prompt_cache_keys"
    }

    public init(models: [String], promptCacheKeys: [String]? = nil) {
        self.models = models
        self.promptCacheKeys = promptCacheKeys
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
    public let notes: String?
    public let durationMs: Int64
    public let sha256: String
    public let createdAt: String

    enum CodingKeys: String, CodingKey {
        case voiceId = "voice_id"
        case name
        case referenceText = "reference_text"
        case language
        case notes
        case durationMs = "duration_ms"
        case sha256
        case createdAt = "created_at"
    }
}

public struct VoicesListResponse: Codable, Sendable, Equatable {
    public let voices: [VoiceProfile]
}

public struct CreateVoiceRequest: Codable, Sendable, Equatable {
    public let name: String
    public let referenceAudio: String
    public let referenceText: String?
    public let language: String?
    public let notes: String?

    enum CodingKeys: String, CodingKey {
        case name
        case referenceAudio = "reference_audio"
        case referenceText = "reference_text"
        case language
        case notes
    }

    public init(
        name: String,
        referenceAudio: String,
        referenceText: String? = nil,
        language: String? = nil,
        notes: String? = nil
    ) {
        self.name = name
        self.referenceAudio = referenceAudio
        self.referenceText = referenceText
        self.language = language
        self.notes = notes
    }
}

public struct VadRequest: Codable, Sendable, Equatable {
    public let model: String
    public let filePath: String
    public let minSpeechMs: Int64?
    public let minSilenceMs: Int64?

    enum CodingKeys: String, CodingKey {
        case model
        case filePath = "file_path"
        case minSpeechMs = "min_speech_ms"
        case minSilenceMs = "min_silence_ms"
    }

    public init(
        model: String = "speech-vad-pyannote",
        filePath: String,
        minSpeechMs: Int64? = nil,
        minSilenceMs: Int64? = nil
    ) {
        self.model = model
        self.filePath = filePath
        self.minSpeechMs = minSpeechMs
        self.minSilenceMs = minSilenceMs
    }
}

public struct VadSegment: Codable, Sendable, Equatable {
    public let startMs: Int64
    public let endMs: Int64

    enum CodingKeys: String, CodingKey {
        case startMs = "start_ms"
        case endMs = "end_ms"
    }

    public init(startMs: Int64, endMs: Int64) {
        self.startMs = startMs
        self.endMs = endMs
    }
}

public struct VadResponse: Codable, Sendable, Equatable {
    public let segments: [VadSegment]
    public let durationMs: Int64
    public let xAcpmTiming: TimingMetrics?

    enum CodingKeys: String, CodingKey {
        case segments
        case durationMs = "duration_ms"
        case xAcpmTiming = "x_acpm_timing"
    }
}

public enum SpeechBatchStatus: String, Codable, Sendable {
    case queued
    case running
    case paused
    case completed
    case completedWithErrors = "completed_with_errors"
    case cancelled
}

public enum SpeechBatchItemState: String, Codable, Sendable {
    case pending
    case running
    case completed
    case failed
    case cancelled
}

public struct SpeechBatchItemInput: Codable, Sendable, Equatable {
    public let id: String
    public let text: String
    public let outputFile: String
    public let instruct: String?

    enum CodingKeys: String, CodingKey {
        case id
        case text
        case outputFile = "output_file"
        case instruct
    }

    public init(id: String, text: String, outputFile: String, instruct: String? = nil) {
        self.id = id
        self.text = text
        self.outputFile = outputFile
        self.instruct = instruct
    }
}

public struct CreateSpeechBatchRequest: Codable, Sendable, Equatable {
    public let model: String
    public let voice: String?
    public let instruct: String?
    public let referenceAudio: String?
    public let referenceText: String?
    public let xVectorOnlyMode: Bool
    public let speed: Float?
    public let outputDir: String
    public let items: [SpeechBatchItemInput]

    enum CodingKeys: String, CodingKey {
        case model
        case voice
        case instruct
        case referenceAudio = "reference_audio"
        case referenceText = "reference_text"
        case xVectorOnlyMode = "x_vector_only_mode"
        case speed
        case outputDir = "output_dir"
        case items
    }

    public init(
        model: String = "qwen3-tts-1.7b",
        voice: String? = nil,
        instruct: String? = nil,
        referenceAudio: String? = nil,
        referenceText: String? = nil,
        xVectorOnlyMode: Bool = false,
        speed: Float? = nil,
        outputDir: String,
        items: [SpeechBatchItemInput]
    ) {
        self.model = model
        self.voice = voice
        self.instruct = instruct
        self.referenceAudio = referenceAudio
        self.referenceText = referenceText
        self.xVectorOnlyMode = xVectorOnlyMode
        self.speed = speed
        self.outputDir = outputDir
        self.items = items
    }
}

public struct SpeechBatchItemStatus: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let outputPath: String
    public let status: SpeechBatchItemState
    public let bytes: UInt64?
    public let durationMs: Int64?
    public let voiceCacheHit: Bool?
    public let error: String?

    enum CodingKeys: String, CodingKey {
        case id
        case outputPath = "output_path"
        case status
        case bytes
        case durationMs = "duration_ms"
        case voiceCacheHit = "voice_cache_hit"
        case error
    }

    public init(
        id: String,
        outputPath: String,
        status: SpeechBatchItemState,
        bytes: UInt64? = nil,
        durationMs: Int64? = nil,
        voiceCacheHit: Bool? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.outputPath = outputPath
        self.status = status
        self.bytes = bytes
        self.durationMs = durationMs
        self.voiceCacheHit = voiceCacheHit
        self.error = error
    }
}

public struct SpeechBatchState: Codable, Sendable, Equatable, Identifiable {
    public var id: String { batchId }
    public let batchId: String
    public let model: String
    public let status: SpeechBatchStatus
    public let total: Int
    public let completed: Int
    public let failed: Int
    public let createdAt: String
    public let updatedAt: String
    public let items: [SpeechBatchItemStatus]

    enum CodingKeys: String, CodingKey {
        case batchId = "batch_id"
        case model
        case status
        case total
        case completed
        case failed
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case items
    }

    public init(
        batchId: String,
        model: String,
        status: SpeechBatchStatus,
        total: Int,
        completed: Int,
        failed: Int,
        createdAt: String,
        updatedAt: String,
        items: [SpeechBatchItemStatus]
    ) {
        self.batchId = batchId
        self.model = model
        self.status = status
        self.total = total
        self.completed = completed
        self.failed = failed
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.items = items
    }
}

public struct SpeechBatchesListResponse: Codable, Sendable, Equatable {
    public let batches: [SpeechBatchState]
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

    public init(
        unifiedMB: UInt64? = nil,
        systemRamMB: UInt64? = nil,
        gpuVramMB: [String: UInt64]? = nil
    ) {
        self.unifiedMB = unifiedMB
        self.systemRamMB = systemRamMB
        self.gpuVramMB = gpuVramMB
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
    public let idleRemainingSec: UInt64?
    public let availableQuants: [String]?
    public let modelPath: String?
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
        case idleRemainingSec = "idle_remaining_sec"
        case availableQuants = "available_quants"
        case modelPath = "model_path"
        case memory
    }

    public init(
        id: String,
        capability: String,
        displayName: String,
        selectedVariant: String? = nil,
        installed: Bool,
        state: String,
        pinPolicy: String,
        idleTimeoutSec: UInt64,
        idleRemainingSec: UInt64? = nil,
        availableQuants: [String]? = nil,
        modelPath: String? = nil,
        memory: ResourceVectorDTO
    ) {
        self.id = id
        self.capability = capability
        self.displayName = displayName
        self.selectedVariant = selectedVariant
        self.installed = installed
        self.state = state
        self.pinPolicy = pinPolicy
        self.idleTimeoutSec = idleTimeoutSec
        self.idleRemainingSec = idleRemainingSec
        self.availableQuants = availableQuants
        self.modelPath = modelPath
        self.memory = memory
    }
}

public enum ModelDownloadStatus: String, Codable, Sendable {
    case queued
    case downloading
    case verifying
    case completed
    case failed
    case cancelled
}

public struct StartDownloadRequest: Codable, Sendable, Equatable {
    public let quant: String?

    public init(quant: String? = nil) {
        self.quant = quant
    }
}

public struct ModelDownloadState: Codable, Sendable, Equatable, Identifiable {
    public var id: String { modelId }
    public let modelId: String
    public let variantId: String
    public let status: ModelDownloadStatus
    public let downloadedBytes: UInt64
    public let totalBytes: UInt64
    public let currentFile: String?
    public let filesCompleted: Int
    public let filesTotal: Int
    public let sha256Verified: Bool
    public let error: String?
    public let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case modelId = "model_id"
        case variantId = "variant_id"
        case status
        case downloadedBytes = "downloaded_bytes"
        case totalBytes = "total_bytes"
        case currentFile = "current_file"
        case filesCompleted = "files_completed"
        case filesTotal = "files_total"
        case sha256Verified = "sha256_verified"
        case error
        case updatedAt = "updated_at"
    }

    public init(
        modelId: String,
        variantId: String,
        status: ModelDownloadStatus,
        downloadedBytes: UInt64,
        totalBytes: UInt64,
        currentFile: String? = nil,
        filesCompleted: Int,
        filesTotal: Int,
        sha256Verified: Bool,
        error: String? = nil,
        updatedAt: String
    ) {
        self.modelId = modelId
        self.variantId = variantId
        self.status = status
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.currentFile = currentFile
        self.filesCompleted = filesCompleted
        self.filesTotal = filesTotal
        self.sha256Verified = sha256Verified
        self.error = error
        self.updatedAt = updatedAt
    }
}

public struct ModelDownloadsListResponse: Codable, Sendable, Equatable {
    public let downloads: [ModelDownloadState]
}

public struct ModelConfigOverrideSummary: Codable, Sendable, Equatable {
    public let path: String?
    public let quant: String?
    public let idleTimeoutSec: UInt64?
    public let pinPolicy: String?

    enum CodingKeys: String, CodingKey {
        case path
        case quant
        case idleTimeoutSec = "idle_timeout_sec"
        case pinPolicy = "pin_policy"
    }

    public init(
        path: String? = nil,
        quant: String? = nil,
        idleTimeoutSec: UInt64? = nil,
        pinPolicy: String? = nil
    ) {
        self.path = path
        self.quant = quant
        self.idleTimeoutSec = idleTimeoutSec
        self.pinPolicy = pinPolicy
    }
}

public struct SystemConfigResponse: Codable, Sendable, Equatable {
    public let budgetTier: String
    public let budgetOverrideMb: UInt64?
    public let effectiveBudget: ResourceVectorDTO
    public let dataDir: String
    public let modelsDir: String
    public let voicesDir: String
    public let configPath: String
    public let mdnsHostname: String?
    public let mdnsBaseUrl: String?
    public let httpBaseUrl: String
    public let modelOverrides: [String: ModelConfigOverrideSummary]

    enum CodingKeys: String, CodingKey {
        case budgetTier = "budget_tier"
        case budgetOverrideMb = "budget_override_mb"
        case effectiveBudget = "effective_budget"
        case dataDir = "data_dir"
        case modelsDir = "models_dir"
        case voicesDir = "voices_dir"
        case configPath = "config_path"
        case mdnsHostname = "mdns_hostname"
        case mdnsBaseUrl = "mdns_base_url"
        case httpBaseUrl = "http_base_url"
        case modelOverrides = "model_overrides"
    }

    public init(
        budgetTier: String,
        budgetOverrideMb: UInt64? = nil,
        effectiveBudget: ResourceVectorDTO,
        dataDir: String,
        modelsDir: String,
        voicesDir: String,
        configPath: String,
        mdnsHostname: String? = nil,
        mdnsBaseUrl: String? = nil,
        httpBaseUrl: String,
        modelOverrides: [String: ModelConfigOverrideSummary] = [:]
    ) {
        self.budgetTier = budgetTier
        self.budgetOverrideMb = budgetOverrideMb
        self.effectiveBudget = effectiveBudget
        self.dataDir = dataDir
        self.modelsDir = modelsDir
        self.voicesDir = voicesDir
        self.configPath = configPath
        self.mdnsHostname = mdnsHostname
        self.mdnsBaseUrl = mdnsBaseUrl
        self.httpBaseUrl = httpBaseUrl
        self.modelOverrides = modelOverrides
    }
}

public struct UpdateSystemConfigRequest: Codable, Sendable, Equatable {
    public let budgetTier: String?
    public let budgetOverrideMb: UInt64?
    public let clearBudgetOverride: Bool

    enum CodingKeys: String, CodingKey {
        case budgetTier = "budget_tier"
        case budgetOverrideMb = "budget_override_mb"
        case clearBudgetOverride = "clear_budget_override"
    }

    public init(
        budgetTier: String? = nil,
        budgetOverrideMb: UInt64? = nil,
        clearBudgetOverride: Bool = false
    ) {
        self.budgetTier = budgetTier
        self.budgetOverrideMb = budgetOverrideMb
        self.clearBudgetOverride = clearBudgetOverride
    }
}

public struct UpdateModelConfigRequest: Codable, Sendable, Equatable {
    public let pinPolicy: String?
    public let idleTimeoutSec: UInt64?
    public let quant: String?
    public let path: String?

    enum CodingKeys: String, CodingKey {
        case pinPolicy = "pin_policy"
        case idleTimeoutSec = "idle_timeout_sec"
        case quant
        case path
    }

    public init(
        pinPolicy: String? = nil,
        idleTimeoutSec: UInt64? = nil,
        quant: String? = nil,
        path: String? = nil
    ) {
        self.pinPolicy = pinPolicy
        self.idleTimeoutSec = idleTimeoutSec
        self.quant = quant
        self.path = path
    }
}

public struct UnloadAllRequest: Codable, Sendable, Equatable {
    public let includePinned: Bool

    enum CodingKeys: String, CodingKey {
        case includePinned = "include_pinned"
    }

    public init(includePinned: Bool = false) {
        self.includePinned = includePinned
    }
}

public enum SystemEventEnvelope: Decodable, Sendable, Equatable {
    case modelStateChanged(modelId: String, state: String, memory: ResourceVectorDTO, tsMs: Int64)
    case failureRecorded(DiagnosticFailure)
    case batchProgress(SpeechBatchState)
    case downloadProgress(ModelDownloadState)
    case configChanged(budgetTier: String, budget: ResourceVectorDTO)
    case unknown(String)

    private struct EventTag: Decodable {
        let event: String
    }

    private struct ModelStatePayload: Decodable {
        let modelId: String
        let state: String
        let memory: ResourceVectorDTO
        let tsMs: Int64

        enum CodingKeys: String, CodingKey {
            case modelId = "model_id"
            case state
            case memory
            case tsMs = "ts_ms"
        }
    }

    private struct FailurePayload: Decodable {
        let failure: DiagnosticFailure
    }

    private struct BatchPayload: Decodable {
        let batch: SpeechBatchState
    }

    private struct DownloadPayload: Decodable {
        let download: ModelDownloadState
    }

    private struct ConfigPayload: Decodable {
        let budgetTier: String
        let budget: ResourceVectorDTO

        enum CodingKeys: String, CodingKey {
            case budgetTier = "budget_tier"
            case budget
        }
    }

    public init(from decoder: Decoder) throws {
        let tag = try EventTag(from: decoder)
        switch tag.event {
        case "model_state_changed":
            let p = try ModelStatePayload(from: decoder)
            self = .modelStateChanged(modelId: p.modelId, state: p.state, memory: p.memory, tsMs: p.tsMs)
        case "failure_recorded":
            let p = try FailurePayload(from: decoder)
            self = .failureRecorded(p.failure)
        case "batch_progress":
            let p = try BatchPayload(from: decoder)
            self = .batchProgress(p.batch)
        case "download_progress":
            let p = try DownloadPayload(from: decoder)
            self = .downloadProgress(p.download)
        case "config_changed":
            let p = try ConfigPayload(from: decoder)
            self = .configChanged(budgetTier: p.budgetTier, budget: p.budget)
        default:
            self = .unknown(tag.event)
        }
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

    public init(
        platform: String,
        pid: UInt32,
        budget: ResourceVectorDTO,
        used: ResourceVectorDTO,
        memoryPressure: String,
        thermalState: String,
        loadedModels: [ModelStatusInfo],
        activeRequests: Int,
        queuedRequests: Int,
        callerCounts: [String: UInt64]
    ) {
        self.platform = platform
        self.pid = pid
        self.budget = budget
        self.used = used
        self.memoryPressure = memoryPressure
        self.thermalState = thermalState
        self.loadedModels = loadedModels
        self.activeRequests = activeRequests
        self.queuedRequests = queuedRequests
        self.callerCounts = callerCounts
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

    public init(
        timestampMs: Int64,
        requestId: String,
        caller: String,
        modelId: String? = nil,
        operation: String,
        stage: String,
        code: AcpmErrorCode,
        detail: String,
        nativeCode: String? = nil,
        elapsedMs: Int64
    ) {
        self.timestampMs = timestampMs
        self.requestId = requestId
        self.caller = caller
        self.modelId = modelId
        self.operation = operation
        self.stage = stage
        self.code = code
        self.detail = detail
        self.nativeCode = nativeCode
        self.elapsedMs = elapsedMs
    }
}
