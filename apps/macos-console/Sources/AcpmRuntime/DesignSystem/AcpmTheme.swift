import AcpmClient
import AcpmRuntimeCore
import AppKit
import SwiftUI

public extension AppAppearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

struct UnifiedModelStatus: Sendable, Equatable {
    let label: String
    let color: Color
    let isTransientPulsing: Bool
}

enum AcpmTheme {
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    static let productName = "AcpmRuntime"
    static let brandSymbol = "waveform.circle.fill"

    static let cardCornerRadius: CGFloat = 11
    static let innerCornerRadius: CGFloat = 8
    static let chipCornerRadius: CGFloat = 6

    static let brandIndigo = Color(red: 0.31, green: 0.27, blue: 0.90)
    static let brandCyan = Color(red: 0.02, green: 0.71, blue: 0.83)

    static let brandGradient = LinearGradient(
        colors: [brandIndigo, brandCyan],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static func capabilitySegmentColor(_ capability: String) -> Color {
        switch capability.lowercased() {
        case "llm": return .indigo
        case "asr": return .teal
        case "tts": return .purple
        case "vad": return .cyan
        default: return .secondary
        }
    }

    static func capabilityIcon(_ capability: String) -> String {
        switch capability.lowercased() {
        case "llm": return "brain.head.profile"
        case "asr": return "waveform"
        case "tts": return "speaker.wave.2"
        case "vad": return "waveform.badge.mic"
        default: return "cpu"
        }
    }

    static func capabilityShortLabel(_ capability: String) -> String {
        switch capability.lowercased() {
        case "llm": return "LLM"
        case "asr": return "ASR"
        case "tts": return "TTS"
        case "vad": return "VAD"
        default: return capability.uppercased()
        }
    }

    static func unifiedStatus(
        installed: Bool,
        state: String,
        downloadStatus: ModelDownloadStatus? = nil
    ) -> UnifiedModelStatus {
        if let dl = downloadStatus {
            switch dl {
            case .queued, .downloading:
                return UnifiedModelStatus(label: "下载中", color: .blue, isTransientPulsing: true)
            case .verifying:
                return UnifiedModelStatus(label: "校验中", color: .orange, isTransientPulsing: true)
            case .failed:
                return UnifiedModelStatus(label: "下载失败", color: .red, isTransientPulsing: false)
            case .cancelled, .completed:
                break
            }
        }
        if !installed {
            return UnifiedModelStatus(label: "未安装", color: .orange, isTransientPulsing: false)
        }
        switch state.uppercased() {
        case "RUNNING":
            return UnifiedModelStatus(label: "运行中", color: .green, isTransientPulsing: false)
        case "WARM":
            return UnifiedModelStatus(label: "热驻留", color: .blue, isTransientPulsing: false)
        case "LOADING":
            return UnifiedModelStatus(label: "加载中", color: .orange, isTransientPulsing: true)
        case "UNLOADING":
            return UnifiedModelStatus(label: "释放中", color: .yellow, isTransientPulsing: true)
        case "FAILED":
            return UnifiedModelStatus(label: "异常", color: .red, isTransientPulsing: false)
        default:
            return UnifiedModelStatus(label: "休眠", color: .secondary, isTransientPulsing: false)
        }
    }

    static func pressureColor(_ pressure: String) -> Color {
        switch pressure.lowercased() {
        case "normal", "nominal": return .green
        case "warning", "fair": return .orange
        case "critical", "serious", "heavy": return .red
        default: return .secondary
        }
    }

    static func pressureLabel(_ pressure: String) -> String {
        switch pressure.lowercased() {
        case "normal": return "正常"
        case "warning": return "偏高"
        case "critical": return "紧张"
        default: return pressure
        }
    }

    static func thermalLabel(_ thermal: String) -> String {
        switch thermal.lowercased() {
        case "nominal": return "凉爽"
        case "fair": return "温热"
        case "serious": return "较热"
        case "critical": return "过热"
        default: return thermal
        }
    }

    static func cardFill(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.045)
            : Color(nsColor: .controlBackgroundColor).opacity(0.88)
    }

    static func hairlineBorder(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.08)
    }

    static func cardShadow(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .clear : Color.black.opacity(0.04)
    }
}
