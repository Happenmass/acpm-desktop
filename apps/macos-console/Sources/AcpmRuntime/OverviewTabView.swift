import AcpmClient
import AcpmRuntimeCore
import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

struct OverviewTabView: View {
    @Bindable var viewModel: RuntimeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: AcpmTheme.Spacing.l) {
            if let status = viewModel.status {
                heroMemoryOverviewCard(status: status)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 195), spacing: AcpmTheme.Spacing.m)],
                    spacing: AcpmTheme.Spacing.m
                ) {
                    kpiCard(
                        title: "已载入引擎",
                        value: "\(status.loadedModels.count) / \(viewModel.models.filter { $0.capability != "diarization" }.count)",
                        subtitle: "按需热加载 + 内置 VAD",
                        icon: "cube.box.fill",
                        color: .indigo
                    )
                    kpiCard(
                        title: "并发 / 排队请求",
                        value: "\(status.activeRequests) / \(status.queuedRequests)",
                        subtitle: "交互请求可随时抢占批量",
                        icon: "bolt.fill",
                        color: .teal
                    )
                    kpiCard(
                        title: "内存压力 / 热状态",
                        value: "\(AcpmTheme.pressureLabel(status.memoryPressure)) · \(AcpmTheme.thermalLabel(status.thermalState))",
                        subtitle: "平台 \(status.platform)",
                        icon: "thermometer.medium",
                        color: AcpmTheme.pressureColor(status.memoryPressure)
                    )
                    kpiCard(
                        title: "局域网 mDNS",
                        value: viewModel.config?.mdnsHostname ?? viewModel.discovery?.mdnsHostname ?? "acpm.local",
                        subtitle: viewModel.config?.mdnsBaseUrl ?? "http://acpm.local:18790",
                        icon: "bonjour",
                        color: .cyan,
                        copyText: viewModel.config?.mdnsBaseUrl ?? viewModel.discovery?.mdnsBaseUrl
                    )
                }

                memoryChartCard(status: status)
                callerStatsCard(status: status)
            } else {
                EmptyStateCard(
                    systemImage: "waveform.path.ecg",
                    title: "等待连接到本地 AI 服务",
                    subtitle: viewModel.lastErrorMessage ?? "点击下方按钮启动本地推理守护进程，或打开「配置向导」扫描本地模型。",
                    actionTitle: viewModel.isStartingDaemon ? "正在启动…" : "启动 AI 服务",
                    action: {
                        Task { await viewModel.ensureDaemonRunningAndRefresh() }
                    }
                )
            }

            hardwareAdvisorCard
            failuresSection
        }
    }

    private func heroMemoryOverviewCard(status: SystemStatusResponse) -> some View {
        GlassCard {
            HStack(spacing: AcpmTheme.Spacing.xl) {
                CircularMemoryRing(
                    usedMB: status.used.totalMB,
                    budgetMB: status.budget.totalMB,
                    pressure: status.memoryPressure,
                    diameter: 92,
                    lineWidth: 10
                )

                VStack(alignment: .leading, spacing: AcpmTheme.Spacing.s) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("统一内存调度预算")
                                .font(.headline)
                            Text("档位 \(viewModel.config?.budgetTier ?? "auto") · \(status.used.totalMB) MB / \(status.budget.totalMB) MB")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText())
                        }
                        Spacer()
                        StatusPill(
                            label: "压力\(AcpmTheme.pressureLabel(status.memoryPressure))",
                            color: AcpmTheme.pressureColor(status.memoryPressure)
                        )
                    }

                    SegmentedMemoryBar(
                        models: viewModel.models,
                        usedMB: status.used.totalMB,
                        budgetMB: status.budget.totalMB
                    )
                }
            }
        }
    }

    private func kpiCard(
        title: String,
        value: String,
        subtitle: String,
        icon: String,
        color: Color,
        copyText: String? = nil
    ) -> some View {
        GlassCard(padding: AcpmTheme.Spacing.m) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(title, systemImage: icon)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(color)
                    Spacer()
                    if let copyText {
                        CopyInlineIconButton(textToCopy: copyText) {
                            viewModel.copyToPasteboard(copyText)
                        }
                    }
                }
                Text(value)
                    .font(.title3.bold().monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .contentTransition(.numericText())
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func memoryChartCard(status: SystemStatusResponse) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: AcpmTheme.Spacing.m) {
                HStack {
                    Label("最近 5 分钟统一内存趋势", systemImage: "chart.xyaxis.line")
                        .font(.headline)
                    Spacer()
                    Text("预算参考线 \(status.budget.totalMB) MB")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.orange)
                }

                if viewModel.memoryHistory.isEmpty {
                    Text("正在采集调度器内存样本…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(height: 155)
                } else {
                    Chart(viewModel.memoryHistory) { sample in
                        AreaMark(
                            x: .value("时间", sample.timestamp),
                            y: .value("MB", Int(sample.totalMB))
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [AcpmTheme.brandCyan.opacity(0.30), AcpmTheme.brandIndigo.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                        LineMark(
                            x: .value("时间", sample.timestamp),
                            y: .value("MB", Int(sample.totalMB))
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(AcpmTheme.brandCyan)
                        .lineStyle(StrokeStyle(lineWidth: 2))

                        RuleMark(y: .value("预算上限", Int(status.budget.totalMB)))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .foregroundStyle(.orange.opacity(0.8))
                    }
                    .chartYScale(domain: 0...max(Int(status.budget.totalMB), Int(status.used.totalMB), 512))
                    .frame(height: 165)
                }
            }
        }
    }

    private func callerStatsCard(status: SystemStatusResponse) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: AcpmTheme.Spacing.s) {
                Label("接入方调用统计", systemImage: "app.connected.to.app.below.fill")
                    .font(.headline)

                if status.callerCounts.isEmpty {
                    Text("尚无请求计数（言墨输入法或外部客户端请求接入后会在此统计）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: AcpmTheme.Spacing.m) {
                            ForEach(status.callerCounts.sorted(by: { $0.value > $1.value }), id: \.key) { caller, count in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(caller)
                                        .font(.caption.weight(.semibold))
                                    Text("\(count) 次")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, AcpmTheme.Spacing.m)
                                .padding(.vertical, AcpmTheme.Spacing.s)
                                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: AcpmTheme.innerCornerRadius))
                            }
                        }
                    }
                }
            }
        }
    }

    private var hardwareAdvisorCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: AcpmTheme.Spacing.s) {
                HStack {
                    Label("硬件调度建议 · \(viewModel.hardwareRecommendation.tier.badgeTitle)", systemImage: "cpu")
                        .font(.headline)
                    Spacer()
                    Text("\(viewModel.hardwareRecommendation.ramGB) GB 统一内存")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(viewModel.hardwareRecommendation.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(viewModel.hardwareRecommendation.recommendedModels, id: \.self) { m in
                        Text(verbatim: m)
                            .font(.caption2.monospaced())
                            .padding(.horizontal, AcpmTheme.Spacing.s)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                }
            }
        }
    }

    private var failuresSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: AcpmTheme.Spacing.m) {
                HStack {
                    Label("最近结构化诊断（已脱敏）", systemImage: "stethoscope")
                        .font(.headline)
                    Spacer()
                    Button {
                        exportDiagnosticsWithSavePanel()
                    } label: {
                        Label("导出诊断包…", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if viewModel.recentFailures.isEmpty {
                    HStack(spacing: AcpmTheme.Spacing.s) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Text("最近无推理或加载失败记录")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(viewModel.recentFailures) { failure in
                        let summary = HardwareAdvisor.formatFailureDiagnostic(failure)
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    StatusPill(label: failure.code.rawValue, color: .red)
                                    Text("\(failure.operation) · \(failure.caller)")
                                        .font(.caption.weight(.semibold))
                                }
                                Text(verbatim: "req=\(failure.requestId) stage=\(failure.stage) detail=\(failure.detail) (\(failure.elapsedMs) ms)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            CopyInlineIconButton(textToCopy: summary) {
                                viewModel.copyToPasteboard(summary)
                            }
                        }
                        .padding(AcpmTheme.Spacing.s)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: AcpmTheme.innerCornerRadius))
                    }
                }
            }
        }
    }

    private func exportDiagnosticsWithSavePanel() {
        guard let data = viewModel.exportRedactedDiagnosticsJSON() else {
            viewModel.showToast("生成诊断包失败", kind: .error)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "acpm-diagnostics.json"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url, options: .atomic)
                viewModel.showToast("已导出脱敏诊断包：\(url.lastPathComponent)", kind: .success)
            } catch {
                viewModel.showToast("写入文件失败：\(error.localizedDescription)", kind: .error)
            }
        }
    }
}

private struct CopyInlineIconButton: View {
    let textToCopy: String
    let action: () -> Void
    @State private var copied = false

    var body: some View {
        Button {
            action()
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.caption2)
                .foregroundStyle(copied ? .green : .secondary)
        }
        .buttonStyle(.borderless)
        .help(copied ? "已复制" : "复制")
    }
}
