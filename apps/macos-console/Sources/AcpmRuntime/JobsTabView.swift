import AcpmClient
import AcpmRuntimeCore
import AppKit
import SwiftUI

struct JobsTabView: View {
    @Bindable var viewModel: RuntimeViewModel

    @State private var showQuickBatchSheet = false
    @State private var expandedBatches: Set<String> = []
    @State private var eventFilter: String = "全部"
    @State private var cancelTargetBatch: SpeechBatchState?

    private let eventFilterOptions = ["全部", "模型状态", "批量合成", "模型下载", "诊断告警"]

    var body: some View {
        VStack(alignment: .leading, spacing: AcpmTheme.Spacing.l) {
            activeDownloadsSection
            batchesSection
            liveEventsSection
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    showQuickBatchSheet = true
                } label: {
                    Label("新建批量合成", systemImage: "plus")
                }
                .disabled(!viewModel.connected)
                .help("提交多句文本生成批量 WAV 配音任务")
            }
        }
        .sheet(isPresented: $showQuickBatchSheet) {
            QuickBatchSheet(viewModel: viewModel)
        }
        .confirmationDialog(
            "取消批量合成任务？",
            isPresented: Binding(
                get: { cancelTargetBatch != nil },
                set: { if !$0 { cancelTargetBatch = nil } }
            ),
            presenting: cancelTargetBatch
        ) { target in
            Button("确认取消任务", role: .destructive) {
                Task { await viewModel.cancelBatch(target.batchId) }
            }
            Button("保留继续运行", role: .cancel) {}
        } message: { target in
            Text("将中止批量任务 \(target.batchId)，未完成句段不再继续生成。")
        }
    }

    @ViewBuilder
    private var activeDownloadsSection: some View {
        let downloads = viewModel.downloads.values.sorted { $0.modelId < $1.modelId }
        if !downloads.isEmpty {
            VStack(alignment: .leading, spacing: AcpmTheme.Spacing.s) {
                Text("模型下载与校验队列")
                    .font(.headline)

                ForEach(downloads) { dl in
                    let total = max(Double(dl.totalBytes), 1.0)
                    GlassCard(padding: AcpmTheme.Spacing.m) {
                        VStack(alignment: .leading, spacing: AcpmTheme.Spacing.s) {
                            HStack {
                                Text("\(dl.modelId) (\(dl.variantId))")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                StatusPill(
                                    label: RuntimeViewModel.localizedDownloadStatus(dl.status),
                                    color: dl.status == .completed ? .green : (dl.status == .failed ? .red : .blue),
                                    pulsing: dl.status == .downloading || dl.status == .verifying
                                )
                                if dl.status == .downloading || dl.status == .queued || dl.status == .verifying {
                                    Button("取消") {
                                        Task { await viewModel.cancelDownload(dl.modelId) }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                }
                            }
                            ProgressView(value: min(Double(dl.downloadedBytes), total), total: total)
                                .controlSize(.small)
                            HStack {
                                Text("文件 \(dl.filesCompleted)/\(dl.filesTotal)")
                                Spacer()
                                Text("\(HardwareAdvisor.formatBytes(dl.downloadedBytes)) / \(HardwareAdvisor.formatBytes(dl.totalBytes))")
                            }
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var batchesSection: some View {
        VStack(alignment: .leading, spacing: AcpmTheme.Spacing.s) {
            Text("批量语音合成 (TTS) 作业")
                .font(.headline)

            if viewModel.batches.isEmpty {
                EmptyStateCard(
                    systemImage: "list.bullet.rectangle.portrait",
                    title: "暂无批量合成作业",
                    subtitle: "点击顶部工具栏「+」提交多句文本，或通过 API `/v1/audio/speech/batches` 投递任务。",
                    actionTitle: viewModel.connected ? "提交批量合成任务" : nil,
                    action: viewModel.connected ? { showQuickBatchSheet = true } : nil
                )
            } else {
                ForEach(viewModel.batches) { batch in
                    let isExpanded = expandedBatches.contains(batch.batchId)
                    GlassCard(padding: AcpmTheme.Spacing.m) {
                        VStack(alignment: .leading, spacing: AcpmTheme.Spacing.s) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: AcpmTheme.Spacing.s) {
                                        Text(verbatim: batch.batchId)
                                            .font(.subheadline.weight(.bold).monospaced())
                                        StatusPill(
                                            label: RuntimeViewModel.localizedBatchStatus(batch.status),
                                            color: batchColor(batch.status),
                                            pulsing: batch.status == .running
                                        )
                                        Text(batch.model)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    Text("完成 \(batch.completed)/\(batch.total) · 失败 \(batch.failed)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .contentTransition(.numericText())
                                }
                                Spacer()

                                HStack(spacing: 6) {
                                    if batch.status == .paused {
                                        Button("恢复") {
                                            Task { await viewModel.resumeBatch(batch.batchId) }
                                        }
                                    } else if batch.status == .running || batch.status == .queued {
                                        Button("暂停") {
                                            Task { await viewModel.pauseBatch(batch.batchId) }
                                        }
                                    }
                                    if batch.status == .running || batch.status == .queued || batch.status == .paused {
                                        Button("取消", role: .destructive) {
                                            cancelTargetBatch = batch
                                        }
                                    }
                                    if batch.items.count > 4 {
                                        Button(isExpanded ? "收起明细" : "展开 \(batch.items.count) 句") {
                                            if isExpanded { expandedBatches.remove(batch.batchId) }
                                            else { expandedBatches.insert(batch.batchId) }
                                        }
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            ProgressView(value: Double(batch.completed), total: Double(max(batch.total, 1)))
                                .controlSize(.small)

                            if isExpanded || batch.items.count <= 4 {
                                VStack(alignment: .leading, spacing: AcpmTheme.Spacing.xs) {
                                    ForEach(batch.items) { item in
                                        HStack(spacing: AcpmTheme.Spacing.s) {
                                            Text(verbatim: item.id)
                                                .font(.caption2.monospaced())
                                                .frame(width: 52, alignment: .leading)
                                            StatusPill(
                                                label: RuntimeViewModel.localizedBatchItemState(item.status),
                                                color: item.status == .completed ? .green : (item.status == .failed ? .red : .blue)
                                            )
                                            Text(RuntimeViewModel.abbreviateHomePath(item.outputPath))
                                                .font(.caption2.monospaced())
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.head)
                                            Spacer()
                                            if let dur = item.durationMs {
                                                Text("\(dur) ms")
                                                    .font(.caption2.monospacedDigit())
                                                    .foregroundStyle(.secondary)
                                            }
                                            if let err = item.error {
                                                Text(err)
                                                    .font(.caption2)
                                                    .foregroundStyle(.red)
                                            }
                                        }
                                    }
                                }
                                .padding(.top, AcpmTheme.Spacing.xs)
                            }
                        }
                    }
                }
            }
        }
    }

    private var liveEventsSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: AcpmTheme.Spacing.s) {
                HStack {
                    Label("实时调度事件流", systemImage: "dot.radiowaves.left.and.right")
                        .font(.headline)
                    Spacer()
                    Picker("事件筛选", selection: $eventFilter) {
                        ForEach(eventFilterOptions, id: \.self) { opt in
                            Text(opt).tag(opt)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)
                }

                let events = viewModel.liveEvents.filter { ev in
                    eventFilter == "全部" || ev.kind == eventFilter
                }

                if events.isEmpty {
                    Text("正在监听 /v1/system/events…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(events.prefix(25)) { ev in
                        HStack(spacing: AcpmTheme.Spacing.s) {
                            Text(ev.timestamp, style: .time)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(ev.kind)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, AcpmTheme.Spacing.s)
                                .padding(.vertical, 2)
                                .background(eventColor(ev.kind).opacity(0.14), in: Capsule())
                                .foregroundStyle(eventColor(ev.kind))
                            Text(ev.summary)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private func batchColor(_ status: SpeechBatchStatus) -> Color {
        switch status {
        case .completed: return .green
        case .completedWithErrors, .paused: return .orange
        case .cancelled: return .red
        case .running, .queued: return .purple
        }
    }

    private func eventColor(_ kind: String) -> Color {
        switch kind {
        case "模型状态": return .indigo
        case "批量合成": return .purple
        case "模型下载": return .blue
        case "诊断告警": return .red
        default: return .secondary
        }
    }
}

private struct QuickBatchSheet: View {
    @Bindable var viewModel: RuntimeViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedVoiceId = ""
    @State private var outputDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("acpm-batch-output").path
    @State private var linesText = "第一句：欢迎使用苹果芯片本地语音引擎。\n第二句：交互请求随时可以插队抢占。\n第三句：支持断点恢复与句级状态追踪。"
    @State private var submitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: AcpmTheme.Spacing.m) {
            Text("新建批量语音合成作业")
                .font(.title3.bold())

            if viewModel.voices.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text("尚未注册参考音色，可在「音色库」添加后选中，或留空使用默认声线。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Picker("参考音色", selection: $selectedVoiceId) {
                    Text("默认音色").tag("")
                    ForEach(viewModel.voices) { v in
                        Text(v.name).tag(v.voiceId)
                    }
                }
            }

            HStack {
                TextField("输出目录", text: $outputDir)
                    .textFieldStyle(.roundedBorder)
                Button("选择目录…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    if panel.runModal() == .OK, let url = panel.url {
                        outputDir = url.path
                    }
                }
            }

            VStack(alignment: .leading, spacing: AcpmTheme.Spacing.xs) {
                Text("台词列表（每行一句，生成 001.wav / 002.wav …）")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextEditor(text: $linesText)
                    .font(.body)
                    .frame(height: 130)
                    .padding(6)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: AcpmTheme.innerCornerRadius))
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button(submitting ? "提交中…" : "提交批量任务") {
                    submitting = true
                    let lines = linesText.components(separatedBy: .newlines)
                    let ttsModelId = viewModel.preferredInstalledTtsModel?.id ?? "qwen3-tts-1.7b"
                    Task {
                        let ok = await viewModel.submitSpeechBatch(
                            voiceId: selectedVoiceId,
                            lines: lines,
                            outputDir: outputDir,
                            modelId: ttsModelId
                        )
                        submitting = false
                        if ok { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(submitting || outputDir.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(AcpmTheme.Spacing.xl)
        .frame(width: 520)
        .onAppear {
            if selectedVoiceId.isEmpty, let first = viewModel.voices.first {
                selectedVoiceId = first.voiceId
            }
        }
    }
}
