import AcpmClient
import AcpmRuntimeCore
import SwiftUI

struct GlassCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    var padding: CGFloat = AcpmTheme.Spacing.l
    var tint: Color? = nil
    var useVibrancy: Bool = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AcpmTheme.cardCornerRadius, style: .continuous)
        ZStack(alignment: .topLeading) {
            if useVibrancy {
                shape.fill(.regularMaterial)
            } else {
                shape.fill(AcpmTheme.cardFill(for: colorScheme))
            }
            if let tint {
                shape.fill(tint.opacity(colorScheme == .dark ? 0.10 : 0.055))
            }
            content()
                .padding(padding)
        }
        .overlay(
            shape.strokeBorder(
                tint?.opacity(0.24) ?? AcpmTheme.hairlineBorder(for: colorScheme),
                lineWidth: 0.5
            )
        )
        .shadow(color: AcpmTheme.cardShadow(for: colorScheme), radius: 4, x: 0, y: 1)
    }
}

struct PulsingStatusDot: View {
    let color: Color
    var isPulsing: Bool = false
    var size: CGFloat = 7
    @State private var pulse = false

    var body: some View {
        ZStack {
            if isPulsing {
                Circle()
                    .fill(color.opacity(0.35))
                    .frame(width: size * 2.0, height: size * 2.0)
                    .scaleEffect(pulse ? 1.15 : 0.75)
                    .opacity(pulse ? 0.0 : 0.7)
                    .animation(.easeOut(duration: 1.3).repeatForever(autoreverses: false), value: pulse)
            }
            Circle()
                .fill(color)
                .frame(width: size, height: size)
        }
        .frame(width: size * 2.0, height: size * 2.0)
        .onAppear { pulse = isPulsing }
        .onChange(of: isPulsing) { _, next in pulse = next }
    }
}

struct StatusPill: View {
    let label: String
    let color: Color
    var systemImage: String? = nil
    var pulsing: Bool = false

    var body: some View {
        HStack(spacing: AcpmTheme.Spacing.xs) {
            if pulsing {
                PulsingStatusDot(color: color, isPulsing: true, size: 6)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(color)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
            }
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, AcpmTheme.Spacing.s)
        .padding(.vertical, 3)
        .background(color.opacity(0.13), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.22), lineWidth: 0.5))
    }
}

struct CapabilityBadge: View {
    let capability: String

    var body: some View {
        HStack(spacing: AcpmTheme.Spacing.xs) {
            Image(systemName: AcpmTheme.capabilityIcon(capability))
                .font(.caption2.weight(.medium))
            Text(AcpmTheme.capabilityShortLabel(capability))
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, AcpmTheme.Spacing.s)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

struct CircularMemoryRing: View {
    let usedMB: UInt64
    let budgetMB: UInt64
    let pressure: String
    var diameter: CGFloat = 90
    var lineWidth: CGFloat = 9

    private var ratio: Double {
        guard budgetMB > 0 else { return 0 }
        return min(1.0, Double(usedMB) / Double(budgetMB))
    }

    var body: some View {
        let tint = AcpmTheme.pressureColor(pressure)
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: ratio)
                .stroke(
                    AngularGradient(
                        colors: [AcpmTheme.brandIndigo, AcpmTheme.brandCyan, tint],
                        center: .center,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(270)
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.snappy(duration: 0.45), value: ratio)

            VStack(spacing: 1) {
                Text(String(format: "%.1f", Double(usedMB) / 1024.0))
                    .font(.system(size: diameter * 0.22, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(String(format: "/ %.0f GB", Double(max(budgetMB, 1024)) / 1024.0))
                    .font(.system(size: max(9, diameter * 0.105), weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

struct SegmentedMemoryBar: View {
    let models: [ModelStatusInfo]
    let usedMB: UInt64
    let budgetMB: UInt64

    var body: some View {
        let loaded = models
            .filter { $0.state != "STOPPED" && $0.capability != "diarization" && $0.memory.totalMB > 0 }
            .sorted { $0.memory.totalMB > $1.memory.totalMB }
        let denom = max(Double(budgetMB), Double(usedMB), 1.0)

        VStack(alignment: .leading, spacing: AcpmTheme.Spacing.s) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    if loaded.isEmpty && usedMB > 0 {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(AcpmTheme.brandCyan)
                            .frame(width: max(4, geo.size.width * CGFloat(Double(usedMB) / denom)))
                    } else {
                        ForEach(loaded) { model in
                            let w = geo.size.width * CGFloat(Double(model.memory.totalMB) / denom)
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(AcpmTheme.capabilitySegmentColor(model.capability))
                                .frame(width: max(6, w - 2))
                                .help("\(model.displayName): \(model.memory.totalMB) MB")
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .frame(height: 12)

            if !loaded.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AcpmTheme.Spacing.m) {
                        ForEach(loaded) { model in
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(AcpmTheme.capabilitySegmentColor(model.capability))
                                    .frame(width: 6, height: 6)
                                Text("\(model.displayName) \(model.memory.totalMB) MB")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                Text("当前无常驻模型，推理请求到达时自动按需加载")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ToastOverlay: View {
    let toast: ToastNotification
    let onDismiss: () -> Void

    private var iconAndColor: (String, Color) {
        switch toast.kind {
        case .success: return ("checkmark.circle.fill", .green)
        case .info: return ("info.circle.fill", .blue)
        case .warning: return ("exclamationmark.triangle.fill", .orange)
        case .error: return ("xmark.octagon.fill", .red)
        }
    }

    var body: some View {
        let (icon, color) = iconAndColor
        HStack(spacing: AcpmTheme.Spacing.s) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.callout.weight(.semibold))
            Text(toast.message)
                .font(.callout)
                .lineLimit(2)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("关闭提示")
        }
        .padding(.horizontal, AcpmTheme.Spacing.l)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.35), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

struct InlineSavedBadge: View {
    let visible: Bool

    var body: some View {
        if visible {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                Text("已保存")
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.green)
            .transition(.opacity.combined(with: .scale(scale: 0.92)))
        }
    }
}

struct EmptyStateCard: View {
    let systemImage: String
    let title: String
    let subtitle: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        GlassCard {
            VStack(spacing: AcpmTheme.Spacing.s) {
                Image(systemName: systemImage)
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
                    .padding(AcpmTheme.Spacing.m)
                    .background(Color.primary.opacity(0.06), in: Circle())
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(.bordered)
                        .padding(.top, AcpmTheme.Spacing.xs)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, AcpmTheme.Spacing.m)
        }
    }
}

struct QuickCopyField: View {
    let label: String
    let value: String
    let copyValue: String
    var isSecret: Bool = false
    var onCopy: (String) -> Void
    @State private var copied = false
    @State private var revealed = false

    var body: some View {
        let displayValue: String = {
            if isSecret && !revealed {
                guard copyValue.count > 10 else { return "••••••••" }
                return "\(copyValue.prefix(6))••••••••\(copyValue.suffix(4))"
            }
            return isSecret ? copyValue : value
        }()

        HStack(spacing: AcpmTheme.Spacing.s) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(verbatim: displayValue)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if isSecret {
                Button {
                    revealed.toggle()
                } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .help(revealed ? "隐藏" : "显示")
            }
            Button {
                onCopy(copyValue)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption2)
                    .foregroundStyle(copied ? .green : .primary)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(.horizontal, AcpmTheme.Spacing.m)
        .padding(.vertical, 7)
        .background(
            Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: AcpmTheme.innerCornerRadius, style: .continuous)
        )
    }
}

struct VadTimelineView: View {
    let vadResponse: VadResponse

    var body: some View {
        let totalMs = max(Double(vadResponse.durationMs), 1.0)
        let speechMs = vadResponse.segments.reduce(Int64(0)) { $0 + max(0, $1.endMs - $1.startMs) }
        let ratio = min(100, Int((Double(speechMs) / totalMs * 100.0).rounded()))

        VStack(alignment: .leading, spacing: AcpmTheme.Spacing.s) {
            HStack {
                Label("CPU VAD 语音活动时间轴", systemImage: "waveform.badge.mic")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("检出 \(vadResponse.segments.count) 段 · 有效人声 \(speechMs) ms / \(vadResponse.durationMs) ms (\(ratio)%)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.08))

                    ForEach(Array(vadResponse.segments.enumerated()), id: \.offset) { _, seg in
                        let startFrac = max(0.0, min(1.0, Double(seg.startMs) / totalMs))
                        let lenFrac = max(0.01, min(1.0 - startFrac, Double(seg.endMs - seg.startMs) / totalMs))
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(AcpmTheme.brandCyan)
                            .frame(width: max(4, geo.size.width * lenFrac))
                            .offset(x: geo.size.width * startFrac)
                            .help("\(seg.startMs) ms - \(seg.endMs) ms")
                    }
                }
            }
            .frame(height: 16)

            if !vadResponse.segments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(vadResponse.segments.enumerated()), id: \.offset) { idx, seg in
                            Text(verbatim: "#\(idx + 1) \(seg.startMs)–\(seg.endMs)ms")
                                .font(.caption2.monospacedDigit())
                                .padding(.horizontal, AcpmTheme.Spacing.s)
                                .padding(.vertical, 3)
                                .background(Color.primary.opacity(0.06), in: Capsule())
                        }
                    }
                }
            }
        }
    }
}
