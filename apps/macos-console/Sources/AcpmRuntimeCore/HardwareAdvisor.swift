import AcpmClient
import Foundation

public enum HardwareTier: String, Sendable, Equatable {
    case compact8GB
    case balanced16GB
    case pro24GBPlus

    public var badgeTitle: String {
        switch self {
        case .compact8GB: return "8 GB 轻量轮替档"
        case .balanced16GB: return "16 GB 均衡双驻留档"
        case .pro24GBPlus: return "24 GB+ 多引擎常驻档"
        }
    }
}

public struct HardwareRecommendation: Sendable, Equatable {
    public let ramGB: Int
    public let tier: HardwareTier
    public let recommendedModels: [String]
    public let summary: String

    public init(ramGB: Int, tier: HardwareTier, recommendedModels: [String], summary: String) {
        self.ramGB = ramGB
        self.tier = tier
        self.recommendedModels = recommendedModels
        self.summary = summary
    }
}

public enum HardwareAdvisor {
    public static func advise(
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> HardwareRecommendation {
        let ramGB = max(1, Int((Double(physicalMemoryBytes) / 1_073_741_824.0).rounded()))
        if ramGB < 12 {
            return HardwareRecommendation(
                ramGB: ramGB,
                tier: .compact8GB,
                recommendedModels: ["qwen3-asr-0.6b", "yanmo-correct-4b-cot (4bit)", "speech-vad-pyannote"],
                summary: "建议启用「节能」或「均衡」档位，ASR 0.6B 与 4B 纠错模型按需单模型轮替加载，避免触发系统内存压力。"
            )
        }
        if ramGB < 22 {
            return HardwareRecommendation(
                ramGB: ramGB,
                tier: .balanced16GB,
                recommendedModels: ["qwen3-asr-0.6b", "yanmo-correct-4b-cot (4bit)", "speech-vad-pyannote"],
                summary: "推荐将 ASR 0.6B 与 4B CoT (4bit) 双模型常驻热态（约 3.8-4.2 GB）；TTS 批量配音采用句级释放，言墨输入法可随时抢占。"
            )
        }
        return HardwareRecommendation(
            ramGB: ramGB,
            tier: .pro24GBPlus,
            recommendedModels: ["yanmo-correct-4b-cot (8bit)", "qwen3-asr-1.7b", "qwen3-tts-1.7b", "speech-vad-pyannote"],
            summary: "统一内存充裕，可同时保留 4B CoT + Qwen3-ASR 1.7B + Qwen3-TTS 1.7B + CPU VAD 热态并发推理。"
        )
    }

    public static func formatIdleCountdown(_ seconds: UInt64) -> String {
        if seconds >= 3600 {
            let h = seconds / 3600
            let m = (seconds % 3600) / 60
            return "\(h)h \(m)m"
        }
        if seconds >= 60 {
            let m = seconds / 60
            let s = seconds % 60
            return "\(m)m \(s)s"
        }
        return "\(seconds)s"
    }

    public static func formatBytes(_ bytes: UInt64) -> String {
        if bytes >= 1_073_741_824 {
            return String(format: "%.2f GB", Double(bytes) / 1_073_741_824.0)
        }
        if bytes >= 1_048_576 {
            return String(format: "%.1f MB", Double(bytes) / 1_048_576.0)
        }
        if bytes >= 1024 {
            return String(format: "%.0f KB", Double(bytes) / 1024.0)
        }
        return "\(bytes) B"
    }

    public static func formatFailureDiagnostic(_ failure: DiagnosticFailure) -> String {
        let model = failure.modelId ?? "-"
        let native = failure.nativeCode ?? "-"
        return "request_id=\(failure.requestId) caller=\(failure.caller) op=\(failure.operation) model=\(model) stage=\(failure.stage) code=\(failure.code.rawValue) detail=\(failure.detail) native=\(native) elapsed_ms=\(failure.elapsedMs)"
    }
}
