import AcpmClient
import AcpmRuntimeCore
import AppKit
import SwiftUI

struct ModelsTabView: View {
    @Bindable var viewModel: RuntimeViewModel

    private enum CapabilityFilter: String, CaseIterable, Identifiable {
        case all = "全部"
        case llm = "LLM"
        case asr = "ASR"
        case tts = "TTS"
        case vad = "VAD"

        var id: String { rawValue }
    }

    @State private var filter: CapabilityFilter = .all
    @State private var searchText = ""
    @State private var selectedModelId: String?
    @State private var showInspector = true
    @State private var deleteTargetModel: ModelStatusInfo?

    var body: some View {
        VStack(spacing: 0) {
            filterHeaderBar
            Divider()

            let activeModels = filteredModels
            if activeModels.isEmpty {
                ScrollView {
                    EmptyStateCard(
                        systemImage: "cube.box",
                        title: "没有匹配的模型",
                        subtitle: viewModel.connected ? "请调整筛选条件或点击右上角「扫描本地模型」。" : "请先启动本地 AI 服务。"
                    )
                    .padding(AcpmTheme.Spacing.xl)
                }
            } else {
                List(activeModels, selection: $selectedModelId) { model in
                    ModelListRow(
                        model: model,
                        downloadState: viewModel.downloads[model.id],
                        isPending: viewModel.pendingModelIds.contains(model.id),
                        managedModelsDir: viewModel.config?.modelsDir,
                        viewModel: viewModel,
                        onRequestDelete: { deleteTargetModel = model }
                    )
                    .tag(model.id)
                }
                .listStyle(.inset)
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "搜索模型")
        .inspector(isPresented: $showInspector) {
            Group {
                if let selected = selectedModel {
                    ModelInspectorView(
                        model: selected,
                        downloadState: viewModel.downloads[selected.id],
                        viewModel: viewModel,
                        onRequestDelete: { deleteTargetModel = selected }
                    )
                } else {
                    ContentUnavailableView(
                        "选择一个模型",
                        systemImage: "cube.box",
                        description: Text("在左侧列表选择模型以调整量化、驻留策略与权重路径")
                    )
                }
            }
            .inspectorColumnWidth(min: 280, ideal: 310, max: 360)
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button {
                    let found = viewModel.scanLocalModels()
                    if found.isEmpty {
                        viewModel.showToast("未扫描到新的预置缓存，可在右侧检查器手动绑定目录", kind: .info)
                    } else {
                        Task { _ = await viewModel.bindDetectedModels(found) }
                    }
                } label: {
                    Label("扫描本地模型", systemImage: "magnifyingglass")
                }
                .disabled(!viewModel.connected)
                .help("扫描 ~/.cache 与内置目录并自动绑定模型权重")

                Button {
                    showInspector.toggle()
                } label: {
                    Label("检查器", systemImage: "sidebar.right")
                }
                .help(showInspector ? "隐藏详情面板" : "显示详情面板")
            }
        }
        .confirmationDialog(
            "删除本地托管模型文件？",
            isPresented: Binding(
                get: { deleteTargetModel != nil },
                set: { if !$0 { deleteTargetModel = nil } }
            ),
            presenting: deleteTargetModel
        ) { target in
            Button("删除权重文件", role: .destructive) {
                Task { await viewModel.deleteModel(target.id) }
            }
            Button("取消", role: .cancel) {}
        } message: { target in
            Text("将删除托管目录中 \(target.displayName) (\(target.id)) 的权重文件，如需再次使用需重新下载或绑定。")
        }
        .onAppear {
            if selectedModelId == nil {
                selectedModelId = filteredModels.first?.id
            }
        }
        .onChange(of: viewModel.models) { _, _ in
            if let cur = selectedModelId,
               !viewModel.models.contains(where: { $0.id == cur && $0.capability != "diarization" })
            {
                selectedModelId = filteredModels.first?.id
            } else if selectedModelId == nil {
                selectedModelId = filteredModels.first?.id
            }
        }
    }

    private var filterHeaderBar: some View {
        HStack {
            Picker("能力筛选", selection: $filter) {
                ForEach(CapabilityFilter.allCases) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)

            Spacer()

            Text("\(filteredModels.count) 项")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, AcpmTheme.Spacing.l)
        .padding(.vertical, AcpmTheme.Spacing.s)
    }

    private var selectedModel: ModelStatusInfo? {
        guard let id = selectedModelId else { return nil }
        return viewModel.models.first(where: { $0.id == id && $0.capability != "diarization" })
    }

    private var filteredModels: [ModelStatusInfo] {
        viewModel.models
            .filter { $0.capability != "diarization" }
            .filter { m in
                switch filter {
                case .all: return true
                case .llm: return m.capability == "llm"
                case .asr: return m.capability == "asr"
                case .tts: return m.capability == "tts"
                case .vad: return m.capability == "vad"
                }
            }
            .filter { m in
                let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if q.isEmpty { return true }
                return m.id.lowercased().contains(q) || m.displayName.lowercased().contains(q)
            }
    }
}

private struct ModelListRow: View {
    let model: ModelStatusInfo
    let downloadState: ModelDownloadState?
    let isPending: Bool
    let managedModelsDir: String?
    @Bindable var viewModel: RuntimeViewModel
    let onRequestDelete: () -> Void

    @State private var isHovered = false

    private var compactMetadata: String {
        let quantLabel = extractQuantLabel(model: model)
        if model.state != "STOPPED" && model.memory.totalMB > 0 {
            let memStr = HardwareAdvisor.formatBytes(model.memory.totalMB * 1_048_576)
            return "\(quantLabel) · \(memStr)"
        }
        if model.pinPolicy == "pinned" && model.installed {
            return "\(quantLabel) · 常驻策略"
        }
        return quantLabel
    }

    var body: some View {
        let unified = AcpmTheme.unifiedStatus(
            installed: model.installed,
            state: model.state,
            downloadStatus: downloadState?.status
        )
        HStack(spacing: AcpmTheme.Spacing.m) {
            CapabilityBadge(capability: model.capability)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(verbatim: compactMetadata)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let rem = model.idleRemainingSec, model.state == "WARM", model.pinPolicy != "pinned" {
                        Text(verbatim: "· \(HardwareAdvisor.formatIdleCountdown(rem)) 后回收")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                }

                if let dl = downloadState,
                   dl.status == .downloading || dl.status == .verifying || dl.status == .queued
                {
                    let total = max(Double(dl.totalBytes), 1.0)
                    ProgressView(value: min(Double(dl.downloadedBytes), total), total: total)
                        .controlSize(.small)
                }
            }
            .help(model.modelPath.map { RuntimeViewModel.abbreviateHomePath($0) } ?? model.id)

            Spacer(minLength: AcpmTheme.Spacing.s)

            StatusPill(
                label: unified.label,
                color: unified.color,
                pulsing: unified.isTransientPulsing
            )
            .animation(.snappy, value: unified)

            primaryActionControl

            overflowMenu
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var primaryActionControl: some View {
        if isPending {
            ProgressView()
                .controlSize(.small)
                .frame(width: 56)
        } else if let dl = downloadState,
                  dl.status == .queued || dl.status == .downloading || dl.status == .verifying
        {
            Button("取消") {
                Task { await viewModel.cancelDownload(model.id) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else if !model.installed {
            Button("下载") {
                Task { await viewModel.startDownload(model.id) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        } else if model.state == "STOPPED" {
            Button("预热") {
                Task { await viewModel.loadModel(model.id) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else {
            Button("卸载") {
                Task { await viewModel.unloadModel(model.id) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var overflowMenu: some View {
        Menu {
            Button("更换权重目录…") {
                pickModelDirectory()
            }

            if let path = model.modelPath {
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                Button("复制路径") {
                    viewModel.copyToPasteboard(path, notice: "已复制模型路径")
                }
            }

            if model.installed,
               let modelsDir = managedModelsDir,
               let path = model.modelPath,
               path.hasPrefix(modelsDir)
            {
                Divider()
                Button("删除本地权重…", role: .destructive) {
                    onRequestDelete()
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(isHovered ? .primary : .secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("更多操作")
    }

    private func pickModelDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择 \(model.displayName) (\(model.id)) 的本地权重目录"
        if panel.runModal() == .OK, let url = panel.url {
            Task { _ = await viewModel.updateModelPath(model.id, path: url.path) }
        }
    }
}

private struct ModelInspectorView: View {
    let model: ModelStatusInfo
    let downloadState: ModelDownloadState?
    @Bindable var viewModel: RuntimeViewModel
    let onRequestDelete: () -> Void

    @State private var selectedQuant: String = ""
    @State private var selectedPinPolicy: String = "auto"
    @State private var idleMinutes: Int = 20
    @State private var showSavedIndicator = false

    private let timeoutPresets = [1, 3, 5, 10, 20, 30, 60]

    var body: some View {
        let unified = AcpmTheme.unifiedStatus(
            installed: model.installed,
            state: model.state,
            downloadStatus: downloadState?.status
        )
        let isPending = viewModel.pendingModelIds.contains(model.id)

        Form {
            Section {
                VStack(alignment: .leading, spacing: AcpmTheme.Spacing.s) {
                    HStack {
                        CapabilityBadge(capability: model.capability)
                        Spacer()
                        StatusPill(
                            label: unified.label,
                            color: unified.color,
                            pulsing: unified.isTransientPulsing
                        )
                    }
                    Text(model.displayName)
                        .font(.headline)
                    Text(verbatim: model.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            if model.state != "STOPPED" {
                Section("实时运行指标") {
                    LabeledContent("内存占用") {
                        Text("\(model.memory.totalMB) MB")
                            .font(.callout.monospacedDigit())
                            .contentTransition(.numericText())
                    }
                    if let rem = model.idleRemainingSec, model.pinPolicy != "pinned" {
                        LabeledContent("回收倒计时") {
                            Text(HardwareAdvisor.formatIdleCountdown(rem))
                                .font(.callout.monospacedDigit())
                                .contentTransition(.numericText())
                        }
                    }
                }
            }

            if let dl = downloadState {
                Section("下载状态") {
                    let total = max(Double(dl.totalBytes), 1.0)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(RuntimeViewModel.localizedDownloadStatus(dl.status))
                                .font(.caption.weight(.semibold))
                            Spacer()
                            if dl.sha256Verified {
                                Label("SHA-256 校验通过", systemImage: "checkmark.seal.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                            }
                        }
                        ProgressView(value: min(Double(dl.downloadedBytes), total), total: total)
                            .controlSize(.small)
                        Text("\(HardwareAdvisor.formatBytes(dl.downloadedBytes)) / \(HardwareAdvisor.formatBytes(dl.totalBytes))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if let err = dl.error {
                            Text(err)
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }

            Section {
                if let quants = model.availableQuants, !quants.isEmpty {
                    LabeledContent("量化版本") {
                        Picker("", selection: $selectedQuant) {
                            ForEach(quants, id: \.self) { q in
                                Text(q).tag(q)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .onChange(of: selectedQuant) { _, next in
                            let currentVariant = model.selectedVariant ?? ""
                            guard !next.isEmpty, !currentVariant.contains(next) else { return }
                            applyPolicyChange(quant: next)
                        }
                    }
                }

                LabeledContent("驻留策略") {
                    Picker("", selection: $selectedPinPolicy) {
                        Text("自动").tag("auto")
                        Text("常驻内存").tag("pinned")
                        Text("用完即释放").tag("ephemeral")
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("自动：空闲超时后卸载；常驻内存：尽量保持热态；用完即释放：请求结束后快速回收")
                    .onChange(of: selectedPinPolicy) { _, next in
                        guard next != model.pinPolicy else { return }
                        applyPolicyChange()
                    }
                }

                if selectedPinPolicy != "pinned" {
                    LabeledContent("空闲回收") {
                        Picker("", selection: $idleMinutes) {
                            ForEach(timeoutPresets, id: \.self) { m in
                                Text("\(m) 分钟").tag(m)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .onChange(of: idleMinutes) { _, next in
                            guard UInt64(next) * 60 != nearestPresetSeconds(model.idleTimeoutSec) else { return }
                            applyPolicyChange()
                        }
                    }
                }

                if showSavedIndicator {
                    HStack {
                        Spacer()
                        InlineSavedBadge(visible: showSavedIndicator)
                    }
                }
            } header: {
                Text("调度策略（即时生效）")
            }

            Section("权重路径") {
                if let path = model.modelPath {
                    Text(RuntimeViewModel.abbreviateHomePath(path))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .help(path)
                } else {
                    Text("尚未绑定本地目录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: AcpmTheme.Spacing.s) {
                    Button("更换目录…") {
                        pickDirectoryForInspector()
                    }
                    .disabled(isPending)

                    if let path = model.modelPath {
                        Button("在 Finder 中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                    }
                }

                if model.installed,
                   let modelsDir = viewModel.config?.modelsDir,
                   let path = model.modelPath,
                   path.hasPrefix(modelsDir)
                {
                    Button("删除本地权重…", role: .destructive) {
                        onRequestDelete()
                    }
                    .disabled(isPending)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { syncFieldsFromModel() }
        .onChange(of: model.id) { _, _ in syncFieldsFromModel() }
        .onChange(of: model.pinPolicy) { _, _ in syncFieldsFromModel() }
        .onChange(of: model.idleTimeoutSec) { _, _ in syncFieldsFromModel() }
        .onChange(of: model.selectedVariant) { _, _ in syncFieldsFromModel() }
    }

    private func syncFieldsFromModel() {
        selectedPinPolicy = model.pinPolicy
        let mins = max(1, Int((Double(model.idleTimeoutSec) / 60.0).rounded()))
        idleMinutes = timeoutPresets.min(by: { abs($0 - mins) < abs($1 - mins) }) ?? 20
        if let quants = model.availableQuants {
            if let variant = model.selectedVariant,
               let matched = quants.first(where: { variant.contains($0) })
            {
                selectedQuant = matched
            } else if let first = quants.first {
                selectedQuant = first
            }
        }
    }

    private func nearestPresetSeconds(_ sec: UInt64) -> UInt64 {
        let mins = max(1, Int((Double(sec) / 60.0).rounded()))
        let nearest = timeoutPresets.min(by: { abs($0 - mins) < abs($1 - mins) }) ?? 20
        return UInt64(nearest) * 60
    }

    private func applyPolicyChange(quant: String? = nil) {
        let q = quant ?? (selectedQuant.isEmpty ? nil : selectedQuant)
        let sec = UInt64(idleMinutes) * 60
        Task {
            let ok = await viewModel.updateModelConfig(
                model.id,
                pinPolicy: selectedPinPolicy,
                idleTimeoutSec: sec,
                quant: q,
                silent: true
            )
            if ok {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showSavedIndicator = true
                }
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(.easeInOut(duration: 0.25)) {
                    showSavedIndicator = false
                }
            }
        }
    }

    private func pickDirectoryForInspector() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择 \(model.displayName) (\(model.id)) 的本地权重目录"
        if panel.runModal() == .OK, let url = panel.url {
            Task { _ = await viewModel.updateModelPath(model.id, path: url.path) }
        }
    }
}

private func extractQuantLabel(model: ModelStatusInfo) -> String {
    if let variant = model.selectedVariant, !variant.isEmpty {
        if let last = variant.split(separator: "-").last {
            return String(last)
        }
        return variant
    }
    return model.capability.uppercased()
}
