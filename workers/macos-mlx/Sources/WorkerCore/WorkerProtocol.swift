import Foundation

public enum WorkerMode: String, Codable, Sendable, CaseIterable {
    case llm
    case asr
    case tts
}

public enum WorkerState: String, Codable, Sendable {
    case stopped = "STOPPED"
    case starting = "STARTING"
    case loading = "LOADING"
    case warm = "WARM"
    case running = "RUNNING"
    case unloading = "UNLOADING"
    case failed = "FAILED"
}

public struct WorkerMemorySnapshot: Codable, Sendable, Equatable {
    public let unifiedMB: UInt64

    enum CodingKeys: String, CodingKey {
        case unifiedMB = "unified_mb"
    }

    public init(unifiedMB: UInt64) {
        self.unifiedMB = unifiedMB
    }
}

public struct WorkerFrameEnvelope: Codable, Sendable, Equatable {
    public let type: String
    public let state: WorkerState?
    public let tsMs: Int64?
    public let modelLoadMs: Double?
    public let memory: WorkerMemorySnapshot?
    public let ipcEndpoint: String?
    public let kvCacheEntries: Int?
    public let voiceCacheEntries: Int?
    public let stage: String?
    public let detail: String?
    public let nativeCode: String?
    public let fatal: Bool?

    enum CodingKeys: String, CodingKey {
        case type
        case state
        case tsMs = "ts_ms"
        case modelLoadMs = "model_load_ms"
        case memory
        case ipcEndpoint = "ipc_endpoint"
        case kvCacheEntries = "kv_cache_entries"
        case voiceCacheEntries = "voice_cache_entries"
        case stage
        case detail
        case nativeCode = "native_code"
        case fatal
    }

    public static func stateFrame(
        _ state: WorkerState,
        tsMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        modelLoadMs: Double? = nil,
        memory: WorkerMemorySnapshot? = nil,
        ipcEndpoint: String? = nil
    ) -> WorkerFrameEnvelope {
        WorkerFrameEnvelope(
            type: "state",
            state: state,
            tsMs: tsMs,
            modelLoadMs: modelLoadMs,
            memory: memory,
            ipcEndpoint: ipcEndpoint,
            kvCacheEntries: nil,
            voiceCacheEntries: nil,
            stage: nil,
            detail: nil,
            nativeCode: nil,
            fatal: nil
        )
    }

    public static func errorFrame(
        stage: String,
        detail: String,
        nativeCode: String? = nil,
        fatal: Bool = true
    ) -> WorkerFrameEnvelope {
        WorkerFrameEnvelope(
            type: "error",
            state: nil,
            tsMs: nil,
            modelLoadMs: nil,
            memory: nil,
            ipcEndpoint: nil,
            kvCacheEntries: nil,
            voiceCacheEntries: nil,
            stage: stage,
            detail: detail,
            nativeCode: nativeCode,
            fatal: fatal
        )
    }
}

public enum WorkerCommandKind: String, Codable, Sendable {
    case shutdown
    case trimCache = "trim_cache"
}

public struct WorkerCommand: Codable, Sendable, Equatable {
    public let cmd: WorkerCommandKind
}

public struct WorkerCLIOptions: Sendable, Equatable {
    public let mode: WorkerMode
    public let modelId: String
    public let modelDir: String?
    public let ipcPath: String?
    public let memoryLimitMB: UInt64
    public let threads: Int
    public let probe: Bool
    public let showHelp: Bool

    public static func parse(arguments: [String]) throws -> WorkerCLIOptions {
        var mode: WorkerMode = .llm
        var modelId = ""
        var modelDir: String?
        var ipcPath: String?
        var memoryLimitMB: UInt64 = 4096
        var threads = 4
        var probe = false
        var showHelp = false

        var idx = 1
        while idx < arguments.count {
            let arg = arguments[idx]
            switch arg {
            case "-h", "--help":
                showHelp = true
            case "--probe":
                probe = true
            case "--mode":
                idx += 1
                guard idx < arguments.count, let parsed = WorkerMode(rawValue: arguments[idx]) else {
                    throw WorkerConfigError.invalidArgument("--mode")
                }
                mode = parsed
            case "--model-id":
                idx += 1
                guard idx < arguments.count else { throw WorkerConfigError.invalidArgument("--model-id") }
                modelId = arguments[idx]
            case "--model-dir":
                idx += 1
                guard idx < arguments.count else { throw WorkerConfigError.invalidArgument("--model-dir") }
                modelDir = arguments[idx]
            case "--ipc-path":
                idx += 1
                guard idx < arguments.count else { throw WorkerConfigError.invalidArgument("--ipc-path") }
                ipcPath = arguments[idx]
            case "--memory-limit-mb":
                idx += 1
                guard idx < arguments.count, let val = UInt64(arguments[idx]) else {
                    throw WorkerConfigError.invalidArgument("--memory-limit-mb")
                }
                memoryLimitMB = val
            case "--threads":
                idx += 1
                guard idx < arguments.count, let val = Int(arguments[idx]), val > 0 else {
                    throw WorkerConfigError.invalidArgument("--threads")
                }
                threads = val
            case "--auth-token-env":
                idx += 1
            default:
                throw WorkerConfigError.unknownArgument(arg)
            }
            idx += 1
        }

        if !showHelp && modelId.isEmpty {
            throw WorkerConfigError.missingRequired("--model-id")
        }

        return WorkerCLIOptions(
            mode: mode,
            modelId: modelId,
            modelDir: modelDir,
            ipcPath: ipcPath,
            memoryLimitMB: memoryLimitMB,
            threads: threads,
            probe: probe,
            showHelp: showHelp
        )
    }
}

public enum WorkerConfigError: Error, Equatable, Sendable {
    case missingRequired(String)
    case invalidArgument(String)
    case unknownArgument(String)
}

public enum WorkerFrameEmitter {
    public static let prefix = "ACPM_FRAME\t"

    public static func encodeLine(_ frame: WorkerFrameEnvelope) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(frame)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return prefix + json
    }

    public static func emit(_ frame: WorkerFrameEnvelope) {
        guard let line = try? encodeLine(frame) else { return }
        if let data = (line + "\n").data(using: .utf8) {
            FileHandle.standardOutput.write(data)
        }
    }
}
