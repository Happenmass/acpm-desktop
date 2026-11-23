import AcpmClient
import AcpmRuntimeCore
import SwiftUI

struct MenuBarPopoverView: View {
    @Bindable var viewModel: RuntimeViewModel
    let onOpenConsole: (ConsoleTab?) -> Void
    let onOpenSettings: () -> Void
    let onOpenOnboarding: () -> Void
    let onClose: () -> Void

    @State private var hoveredModelId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AcpmTheme.Spacing.m) {
            headerSection

            if let status = viewModel.status {
                heroMemoryCard(status: status)
            } else if let msg = viewModel.lastErrorMessage, !viewModel.connected {
                offlineNoticeCard(message: msg)
            }

            if !viewModel.hasCompletedOnboarding {
                onboardingHintCard
            }

            activeModelsSection

            let activeBatches = viewModel.batches.filter {
                $0.status == .running || $0.status == .queued || $0.status == .paused
            }
            let activeDownloads = viewModel.downloads.values
                .filter { $0.status == .downloading || $0.status == .verifying || $0.status == .queued }
                .sorted { $0.modelId < $1.modelId }

            if !activeBatches.isEmpty || !activeDownloads.isEmpty {
                activeWorkCard(batches: activeBatches, downloads: activeDownloads)
            }

            footerActions
        }
        .padding(AcpmTheme.Spacing.l)
        .frame(width: 348)
    }

    private var headerSection: some View {
        HStack(spacing: AcpmTheme.Spacing.s) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AcpmTheme.brandGradient)
                    .frame(width: 28, height: 28)
                Image(systemName: AcpmTheme.brandSymbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(AcpmTheme.productName)
                        .font(.headline)
                    StatusPill(
                        label: viewModel.isStartingDaemon
                            ? "启动中"
                            : (viewModel.connected ? "运行中" : "离线"),
                        color: viewModel.connected ? .green : (viewModel.isStartingDaemon ? .orange : .secondary),
                        pulsing: viewModel.isStartingDaemon
                    )
                }
                Text("\(viewModel.hardwareRecommendation.ramGB) GB 统一内存 · 右键菜单栏查看快捷命令")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                onClose()
                onOpenSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("打开设置 (⌘,)")
        }
    }

    private func heroMemoryCard(status: SystemStatusResponse) -> some View {
        GlassCard(padding: AcpmTheme.Spacing.m, useVibrancy: true) {
            HStack(spacing: AcpmTheme.Spacing.m) {
                CircularMemoryRing(
                    usedMB: status.used.totalMB,
                    budgetMB: status.budget.totalMB,
                    pressure: status.memoryPressure,
                    diameter: 70,
                    lineWidth: 8
                )

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("内存占用")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text("\(status.used.totalMB) / \(status.budget.totalMB) MB")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }

                    SegmentedMemoryBar(
                        models: viewModel.models,
                        usedMB: status.used.totalMB,
                        budgetMB: status.budget.totalMB
                    )

                    HStack(spacing: 10) {
                        Label("活跃请求 \(status.activeRequests)", systemImage: "bolt.fill")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                        if status.queuedRequests > 0 {
                            Text("排队 \(status.queuedRequests)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
    }

    private func offlineNoticeCard(message: String) -> some View {
        GlassCard(padding: AcpmTheme.Spacing.m, tint: .orange, useVibrancy: true) {
            HStack(spacing: AcpmTheme.Spacing.s) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("本地服务未连接")
                        .font(.caption.weight(.semibold))
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button(viewModel.isStartingDaemon ? "启动中…" : "启动") {
                    Task { await viewModel.ensureDaemonRunningAndRefresh() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .disabled(viewModel.isStartingDaemon)
            }
        }
    }

    private var onboardingHintCard: some View {
        GlassCard(padding: AcpmTheme.Spacing.s, tint: AcpmTheme.brandIndigo, useVibrancy: true) {
            HStack(spacing: AcpmTheme.Spacing.s) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(AcpmTheme.brandIndigo)
                Text("首次使用：快速扫描绑定本地模型")
                    .font(.caption.weight(.medium))
                Spacer()
                Button("去配置") {
                    onClose()
                    onOpenOnboarding()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            }
        }
    }

    private var activeModelsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            let loaded = viewModel.models.filter { $0.capability != "diarization" && $0.state != "STOPPED" }
            HStack {
                Text("活跃引擎")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !loaded.isEmpty {
                    Text("\(loaded.count) 个已载入")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if loaded.isEmpty {
                HStack(spacing: AcpmTheme.Spacing.s) {
                    Image(systemName: "moon.zzz")
                        .foregroundStyle(.secondary)
                    Text("引擎休眠中，言墨请求到达时自动毫秒级唤起")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(AcpmTheme.Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: AcpmTheme.innerCornerRadius, style: .continuous))
            } else {
                ForEach(loaded) { model in
                    let isPending = viewModel.pendingModelIds.contains(model.id)
                    let isHovered = hoveredModelId == model.id
                    let unified = AcpmTheme.unifiedStatus(installed: model.installed, state: model.state)

                    HStack(spacing: AcpmTheme.Spacing.s) {
                        Image(systemName: AcpmTheme.capabilityIcon(model.capability))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 16)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.displayName)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            HStack(spacing: 5) {
                                Text("\(model.memory.totalMB) MB")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .contentTransition(.numericText())
                                if model.pinPolicy == "pinned" {
                                    Text("· 常驻")
                                        .font(.caption2)
                                        .foregroundStyle(.blue)
                                } else if let rem = model.idleRemainingSec {
                                    Text("· \(HardwareAdvisor.formatIdleCountdown(rem)) 后回收")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .contentTransition(.numericText())
                                }
                            }
                        }

                        Spacer()

                        StatusPill(
                            label: unified.label,
                            color: unified.color,
                            pulsing: unified.isTransientPulsing
                        )
                        .animation(.snappy, value: model.state)

                        if isPending {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 18, height: 18)
                        } else {
                            Button {
                                Task { await viewModel.unloadModel(model.id) }
                            } label: {
                                Image(systemName: "eject.fill")
                                    .font(.caption)
                                    .symbolEffect(.bounce, value: isPending)
                            }
                            .buttonStyle(.borderless)
                            .help("卸载 \(model.displayName)")
                        }
                    }
                    .padding(.horizontal, AcpmTheme.Spacing.m)
                    .padding(.vertical, 7)
                    .background(
                        Color.primary.opacity(isHovered ? 0.08 : 0.04),
                        in: RoundedRectangle(cornerRadius: AcpmTheme.innerCornerRadius, style: .continuous)
                    )
                    .onHover { hovering in
                        hoveredModelId = hovering ? model.id : nil
                    }
                }
            }
        }
    }

    private func activeWorkCard(batches: [SpeechBatchState], downloads: [ModelDownloadState]) -> some View {
        Button {
            onClose()
            onOpenConsole(.jobs)
        } label: {
            GlassCard(padding: AcpmTheme.Spacing.m, useVibrancy: true) {
                VStack(alignment: .leading, spacing: AcpmTheme.Spacing.s) {
                    ForEach(batches.prefix(2)) { batch in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Label("批量合成 \(batch.batchId)", systemImage: "speaker.wave.2")
                                    .font(.caption2.weight(.semibold))
                                Spacer()
                                Text("\(batch.completed)/\(batch.total)")
                                    .font(.caption2.monospacedDigit())
                            }
                            ProgressView(value: Double(batch.completed), total: Double(max(batch.total, 1)))
                                .controlSize(.small)
                        }
                    }
                    ForEach(downloads.prefix(2)) { dl in
                        let total = max(Double(dl.totalBytes), 1.0)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Label("下载 \(dl.modelId)", systemImage: "arrow.down.circle")
                                    .font(.caption2.weight(.semibold))
                                Spacer()
                                Text(HardwareAdvisor.formatBytes(dl.downloadedBytes))
                                    .font(.caption2.monospacedDigit())
                            }
                            ProgressView(value: min(Double(dl.downloadedBytes), total), total: total)
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .help("点击查看任务详情")
    }

    private var footerActions: some View {
        HStack(spacing: AcpmTheme.Spacing.s) {
            Button {
                Task { await viewModel.unloadAll() }
            } label: {
                if viewModel.isUnloadingAll {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("释放内存", systemImage: "memorychip")
                }
            }
            .buttonStyle(.bordered)
            .disabled(!viewModel.connected || viewModel.isUnloadingAll)
            .help("释放所有未常驻的空闲模型内存 (⇧⌘K)")

            Button {
                onClose()
                onOpenConsole(nil)
            } label: {
                Text("打开控制台")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [])
        }
        .controlSize(.regular)
    }
}
